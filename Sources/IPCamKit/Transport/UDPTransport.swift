// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// UDP transport for RTP/RTCP using Apple's Network framework.

import Foundation
import Network

/// Address family for a UDP RTP/RTCP socket pair, chosen to match the resolved
/// RTSP control-connection peer so the local bind family matches the server.
enum UDPAddressFamily: Sendable {
  case ipv4
  case ipv6

  /// Wildcard local-bind host for this family (`0.0.0.0` / `::`).
  var wildcardHost: NWEndpoint.Host {
    switch self {
    case .ipv4: return NWEndpoint.Host("0.0.0.0")
    case .ipv6: return NWEndpoint.Host("::")
    }
  }

  /// Loopback literal for this family, used as a last-resort peer fallback.
  var loopback: String {
    switch self {
    case .ipv4: return "127.0.0.1"
    case .ipv6: return "::1"
    }
  }
}

/// A pair of connected UDP flows for one RTP stream: RTP on an even local port
/// and RTCP on the consecutive odd port (`rtpPort + 1`), as required by RFC 3550
/// and the `client_port=X-Y` SETUP transport parameter.
///
/// Built on Apple's Network framework (`NWListener`/`NWConnection`) — the same
/// stack the RTSP control connection (`RTSPTransportConnection`) uses — so IPv4
/// and IPv6 peers are handled natively via `NWEndpoint`, with no `Darwin`/BSD
/// socket calls.
///
/// The lifecycle is what makes UDP awkward: the even/odd local ports must be
/// reserved and advertised in SETUP *before* the server's `server_port` is known,
/// then connected *after* it is reported. Network framework's `NWConnection`
/// requires the remote at creation, so the local port is first reserved by an
/// `NWListener` that stays bound across the whole SETUP round-trip. In
/// `connect()` that listener is released and an `NWConnection` is bound to the
/// same local port and connected to the server — a connected UDP flow, so the
/// kernel filters inbound datagrams to the peer (preserving the symmetric-RTP
/// assumption) and `holePunch()`/sends can omit the address.
///
/// There is a microsecond window between releasing the reservation and binding
/// the connection where the local port is unowned. It is far smaller than the
/// SETUP round-trip (which the held listener covers), is single-host, and mirrors
/// the TOCTOU the live-test port reservation already tolerates.
///
/// `@unchecked Sendable`: `rtpPort`/`rtcpPort`/`family`/`queue` are immutable
/// after `bind()`; all other mutable state (`rtpListener`, `rtcpListener`,
/// `rtpConn`, `rtcpConn`, `receiving`, `closed`) is guarded by `lock`. The
/// `NWListener`/`NWConnection` callbacks all run on the private serial `queue`.
final class UDPPair: @unchecked Sendable {
  /// The bound local RTP port (even).
  let rtpPort: UInt16
  /// The bound local RTCP port (`rtpPort + 1`, odd).
  let rtcpPort: UInt16

  private let family: UDPAddressFamily
  /// Private serial queue for all Network framework callbacks (reservation,
  /// connect handoff, receive loops) — never a Swift Concurrency cooperative
  /// thread.
  private let queue: DispatchQueue

  private let lock = NSLock()
  /// Reservation listeners holding the local ports from `bind()` until `connect()`
  /// hands the ports to the data connections. Nil once consumed or closed.
  private var rtpListener: NWListener?
  private var rtcpListener: NWListener?
  /// Connected data flows, set by `connect()`. Nil until connected / after close.
  private var rtpConn: NWConnection?
  private var rtcpConn: NWConnection?
  private var receiving = false
  private var closed = false

  /// Max attempts to land an even RTP port with a free consecutive odd RTCP
  /// port before giving up. Ephemeral ports are ~50/50 even/odd, so a handful
  /// of tries is overwhelmingly sufficient.
  private static let maxBindTries = 20
  /// How long to wait for a reservation listener to bind, or a data connection
  /// to become ready, before treating the attempt as failed.
  private static let reserveTimeoutSeconds: Double = 3
  private static let connectTimeoutSeconds: Double = 10

  private init(
    family: UDPAddressFamily, queue: DispatchQueue,
    rtpListener: NWListener, rtcpListener: NWListener,
    rtpPort: UInt16, rtcpPort: UInt16
  ) {
    self.family = family
    self.queue = queue
    self.rtpListener = rtpListener
    self.rtcpListener = rtcpListener
    self.rtpPort = rtpPort
    self.rtcpPort = rtcpPort
  }

  /// One-shot resume guard for a `withChecked…Continuation`. All accesses occur
  /// on the pair's serial `queue`, so the plain `Bool` is race-free.
  private final class Settle: @unchecked Sendable {
    private var done = false
    func run(_ body: () -> Void) {
      guard !done else { return }
      done = true
      body()
    }
  }

  // MARK: - Binding

  /// Reserve a local even-RTP / odd-RTCP UDP port pair in `family`.
  ///
  /// Each port is held by an `NWListener` bound to the wildcard address; the
  /// listeners stay alive (holding the ports) until `connect()` releases them.
  /// Retries until an even RTP port with a free consecutive odd RTCP port lands
  /// or `maxBindTries` is exhausted, then throws `transportNegotiationFailed`.
  static func bind(family: UDPAddressFamily) async throws -> UDPPair {
    let queue = DispatchQueue(label: "ipcamkit.udp.\(family)")
    for _ in 0..<maxBindTries {
      guard let rtp = await reserve(family: family, requestedPort: 0, queue: queue) else {
        continue
      }
      // Need an even RTP port with a free consecutive odd RTCP port. (An even
      // port is at most 65534, so `port + 1` never overflows `UInt16`.)
      guard rtp.port % 2 == 0 else {
        rtp.listener.cancel()
        continue
      }
      if let rtcp = await reserve(family: family, requestedPort: rtp.port + 1, queue: queue) {
        if rtcp.port == rtp.port + 1 {
          return UDPPair(
            family: family, queue: queue,
            rtpListener: rtp.listener, rtcpListener: rtcp.listener,
            rtpPort: rtp.port, rtcpPort: rtcp.port)
        }
        // Honored the request with the wrong port (shouldn't happen): release it.
        rtcp.listener.cancel()
      }
      rtp.listener.cancel()
    }
    throw RTSPError.transportNegotiationFailed
  }

  private struct Reservation {
    let listener: NWListener
    let port: UInt16
  }

  /// Bind a UDP `NWListener` to the wildcard address on `requestedPort`
  /// (0 = ephemeral), read back its bound port, and keep it alive. Returns `nil`
  /// on any failure (e.g. the requested port is already taken); the listener is
  /// cancelled on failure.
  private static func reserve(
    family: UDPAddressFamily, requestedPort: UInt16, queue: DispatchQueue
  ) async -> Reservation? {
    let params = NWParameters.udp
    params.allowLocalEndpointReuse = true
    let portEndpoint: NWEndpoint.Port
    if requestedPort == 0 {
      portEndpoint = .any
    } else if let p = NWEndpoint.Port(rawValue: requestedPort) {
      portEndpoint = p
    } else {
      return nil
    }
    params.requiredLocalEndpoint = .hostPort(host: family.wildcardHost, port: portEndpoint)

    guard let listener = try? NWListener(using: params) else { return nil }

    return await withCheckedContinuation { (cont: CheckedContinuation<Reservation?, Never>) in
      let guardBox = Settle()
      // UDP listeners require a new-connection handler; we never accept inbound
      // here (the reservation only holds the port), so connections are dropped.
      listener.newConnectionHandler = { $0.cancel() }
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
          if let port = listener.port?.rawValue {
            guardBox.run { cont.resume(returning: Reservation(listener: listener, port: port)) }
          } else {
            listener.cancel()
            guardBox.run { cont.resume(returning: nil) }
          }
        case .failed:
          listener.cancel()
          guardBox.run { cont.resume(returning: nil) }
        default:
          break
        }
      }
      listener.start(queue: queue)
      queue.asyncAfter(deadline: .now() + reserveTimeoutSeconds) {
        guardBox.run {
          listener.cancel()
          cont.resume(returning: nil)
        }
      }
    }
  }

  // MARK: - Connecting

  /// Connect both flows to the server's RTP (`peerRTPPort`) and RTCP
  /// (`peerRTPPort + 1`) ports. Releases each reservation listener and binds an
  /// `NWConnection` to the freed local port, connected to the peer. Connecting
  /// filters inbound datagrams to the peer (kernel drops spoofed/stray packets)
  /// and lets `holePunch()`/sends omit the address. `peerHost` must be a numeric
  /// literal of this pair's address family (or a name `NWEndpoint` can resolve);
  /// IPv4 and IPv6 (including link-local zone ids) are both supported.
  ///
  /// Known limitation: `establish()` is not Task-cancellation-aware, so a
  /// cancellation while connecting is observed only when the per-flow connect
  /// times out (`connectTimeoutSeconds`), not immediately; the `catch` here then
  /// cancels the already-established RTP flow, so nothing leaks past that point.
  func connect(peerHost: String, peerRTPPort: UInt16) async throws {
    guard peerRTPPort < UInt16.max else {
      throw RTSPError.transportNegotiationFailed
    }

    // Lock access is confined to synchronous helpers so the lock is never held
    // across an `await` (NSLock is unavailable from async contexts).
    guard let (rtpL, rtcpL) = listenersForConnect() else {
      throw RTSPError.connectionFailed("UDP connect on a closed or unbound pair")
    }

    let rtp = try await establish(
      listener: rtpL, localPort: rtpPort, peerHost: peerHost, peerPort: peerRTPPort)
    let rtcp: NWConnection
    do {
      rtcp = try await establish(
        listener: rtcpL, localPort: rtcpPort, peerHost: peerHost, peerPort: peerRTPPort + 1)
    } catch {
      rtp.cancel()
      throw error
    }

    // A concurrent close() may have raced this connect; honor it.
    guard storeConnections(rtp: rtp, rtcp: rtcp) else {
      rtp.cancel()
      rtcp.cancel()
      throw RTSPError.connectionFailed("UDP pair closed during connect")
    }
  }

  /// Snapshot the reservation listeners for `connect()`, or `nil` if the pair is
  /// closed or already connected. Synchronous so it never holds the lock across
  /// an `await`.
  private func listenersForConnect() -> (rtp: NWListener, rtcp: NWListener)? {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, let rtpListener, let rtcpListener else { return nil }
    return (rtpListener, rtcpListener)
  }

  /// Adopt the connected flows (clearing the consumed reservation listeners),
  /// returning `false` if `close()` raced in first — in which case the caller
  /// cancels the connections. Synchronous, for the same reason as above.
  private func storeConnections(rtp: NWConnection, rtcp: NWConnection) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return false }
    rtpConn = rtp
    rtcpConn = rtcp
    rtpListener = nil
    rtcpListener = nil
    return true
  }

  /// Release `listener` (it holds `localPort`), then bind an `NWConnection` to
  /// that same local port and connect it to `peerHost:peerPort`. The listener is
  /// cancelled regardless of outcome. Throws on bind/connect failure or timeout.
  private func establish(
    listener: NWListener, localPort: UInt16, peerHost: String, peerPort: UInt16
  ) async throws -> NWConnection {
    guard let nwLocalPort = NWEndpoint.Port(rawValue: localPort),
      let nwPeerPort = NWEndpoint.Port(rawValue: peerPort)
    else {
      listener.cancel()
      throw RTSPError.transportNegotiationFailed
    }

    let params = NWParameters.udp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = .hostPort(host: family.wildcardHost, port: nwLocalPort)
    let conn = NWConnection(host: NWEndpoint.Host(peerHost), port: nwPeerPort, using: params)
    let queue = self.queue

    return try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<NWConnection, Error>) in
      let guardBox = Settle()
      // All of these run on `queue` (serial), so `guardBox` is race-free.
      @Sendable func settle(_ result: Result<NWConnection, Error>) {
        guardBox.run { cont.resume(with: result) }
      }
      // Bind the data connection only once the reservation has fully released
      // the port (the listener reaches `.cancelled`).
      listener.stateUpdateHandler = { state in
        guard case .cancelled = state else { return }
        listener.stateUpdateHandler = nil
        conn.stateUpdateHandler = { connState in
          switch connState {
          case .ready:
            conn.stateUpdateHandler = nil
            settle(.success(conn))
          case .failed(let error):
            conn.cancel()
            settle(.failure(RTSPError.connectionFailed("UDP connect failed: \(error)")))
          case .cancelled:
            settle(.failure(RTSPError.connectionFailed("UDP connection cancelled before ready")))
          default:
            break
          }
        }
        conn.start(queue: queue)
      }
      listener.cancel()
      queue.asyncAfter(deadline: .now() + Self.connectTimeoutSeconds) {
        // Cancel only if the timeout actually wins the race; once the connection
        // reached `.ready` the guard is spent and the live `conn` is left alone.
        guardBox.run {
          conn.cancel()
          cont.resume(with: .failure(RTSPError.timeout))
        }
      }
    }
  }

  /// Best-effort NAT/firewall hole-punch: send one empty datagram from each
  /// local port to its connected peer so the server learns our mapping and its
  /// RTP/RTCP can return. Harmless on loopback/LAN; errors are ignored (an empty
  /// datagram is not a valid RTP/RTCP packet, so the server simply drops it).
  func holePunch() {
    lock.lock()
    let conns = closed ? [] : [rtpConn, rtcpConn].compactMap { $0 }
    lock.unlock()
    for conn in conns {
      conn.send(content: Data(), completion: .contentProcessed { _ in })
    }
  }

  // MARK: - Receiving

  /// Begin delivering datagrams: `onRTP`/`onRTCP` are invoked (on the private
  /// serial queue) once per received datagram. No-op if already closed or not
  /// yet connected, or if receiving already started.
  func startReceiving(
    onRTP: @escaping @Sendable (Data) -> Void,
    onRTCP: @escaping @Sendable (Data) -> Void,
    onError: (@Sendable (Error) -> Void)? = nil
  ) {
    lock.lock()
    guard !closed, !receiving, let rtpConn, let rtcpConn else {
      lock.unlock()
      return
    }
    receiving = true
    lock.unlock()
    receiveLoop(conn: rtpConn, handler: onRTP, onError: onError)
    receiveLoop(conn: rtcpConn, handler: onRTCP, onError: onError)
  }

  /// Receive one datagram and re-arm. For UDP, `receiveMessage` delivers exactly
  /// one datagram per call and its `isComplete` is true *per datagram* — it is
  /// NOT end-of-stream — so we re-arm regardless, stopping only on a hard error
  /// or once `close()` has run. The re-arm is event-driven (one datagram → one
  /// callback), never a busy loop.
  private func receiveLoop(
    conn: NWConnection, handler: @escaping @Sendable (Data) -> Void,
    onError: (@Sendable (Error) -> Void)?
  ) {
    conn.receiveMessage { [weak self] content, _, _, error in
      guard let self else { return }
      // Check `closed` before delivering so a datagram completing concurrently
      // with close() is neither delivered nor re-armed.
      self.lock.lock()
      let stillOpen = !self.closed
      self.lock.unlock()
      guard stillOpen else { return }
      if let data = content, !data.isEmpty {
        handler(data)
      }
      // A receive error on a connected UDP flow (e.g. an ICMP port-unreachable
      // for a NAT'd camera) is terminal for this flow — stop re-arming (re-arming
      // a .failed flow would busy-loop) but surface it so it isn't a silent
      // stall.
      guard error == nil else {
        onError?(error!)
        return
      }
      self.receiveLoop(conn: conn, handler: handler, onError: onError)
    }
  }

  // MARK: - Teardown

  /// Cancel any reservation listeners and data connections, stopping delivery.
  /// Idempotent. Setting `closed` before cancelling stops the receive loops from
  /// re-arming, so an in-flight receive completes and unwinds.
  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    let listeners = [rtpListener, rtcpListener].compactMap { $0 }
    let conns = [rtpConn, rtcpConn].compactMap { $0 }
    rtpListener = nil
    rtcpListener = nil
    rtpConn = nil
    rtcpConn = nil
    lock.unlock()
    for listener in listeners {
      listener.cancel()
    }
    for conn in conns {
      conn.cancel()
    }
  }

  // MARK: - Host classification

  /// Whether `host` is a numeric IPv4 literal (no DNS/zone handling needed).
  static func isNumericIPv4(_ host: String) -> Bool {
    IPv4Address(host) != nil
  }

  /// Whether `host` is a numeric IPv6 literal, including link-local with a zone
  /// id (e.g. `fe80::1%en0`), which `NWEndpoint.Host` resolves natively.
  static func isNumericIPv6(_ host: String) -> Bool {
    IPv6Address(host) != nil
  }
}
