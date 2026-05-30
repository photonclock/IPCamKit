// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// UDP transport for RTP/RTCP using a bound BSD socket pair.

import Darwin
import Foundation

/// A pair of connected UDP sockets for one RTP stream: RTP on an even local
/// port and RTCP on the consecutive odd port (`rtpPort + 1`), as required by
/// RFC 3550 and the `client_port=X-Y` SETUP transport parameter.
///
/// Unlike the RTSP control connection (TCP, via `RTSPTransportConnection`),
/// RTP/RTCP datagrams are read with BSD sockets so the even/odd local ports can
/// be reserved *before* SETUP and the peer connected *after* the server reports
/// its `server_port`. Receiving is event-driven via `DispatchSource` on a
/// private queue — never blocking a Swift Concurrency cooperative thread.
///
/// IPv4 only. `bind()` fails (rather than silently degrading) when no even/odd
/// pair can be reserved, and `connect()` fails on a non-IPv4 peer.
///
/// `@unchecked Sendable`: the file descriptors are immutable after `bind()`;
/// the only mutable state (`sources`, `closed`) is guarded by `lock`.
final class UDPPair: @unchecked Sendable {
  /// The bound local RTP port (even).
  let rtpPort: UInt16
  /// The bound local RTCP port (`rtpPort + 1`, odd).
  let rtcpPort: UInt16

  private let rtpFD: Int32
  private let rtcpFD: Int32
  private let queue: DispatchQueue

  private let lock = NSLock()
  private var rtpSource: DispatchSourceRead?
  private var rtcpSource: DispatchSourceRead?
  private var closed = false

  /// Max attempts to land an even RTP port with a free consecutive odd RTCP
  /// port before giving up. Ephemeral ports are ~50/50 even/odd, so a handful
  /// of tries is overwhelmingly sufficient.
  private static let maxBindTries = 20
  /// Receive buffer per socket. RTP bursts (and the gap between PLAY and the
  /// reader starting) are absorbed here; a small default buffer would drop.
  private static let receiveBufferBytes: Int32 = 4 * 1024 * 1024
  /// Largest single datagram we will read (a UDP payload never exceeds 64 KiB).
  private static let datagramCapacity = 65535
  /// Datagrams drained per readiness event. The source re-fires while data
  /// remains, so this only bounds how long one event handler runs.
  private static let maxDrainPerEvent = 1024

  private init(rtpFD: Int32, rtcpFD: Int32, rtpPort: UInt16, rtcpPort: UInt16) {
    self.rtpFD = rtpFD
    self.rtcpFD = rtcpFD
    self.rtpPort = rtpPort
    self.rtcpPort = rtcpPort
    self.queue = DispatchQueue(label: "ipcamkit.udp.\(rtpPort)")
  }

  // MARK: - Binding

  /// Reserve a local even-RTP / odd-RTCP UDP socket pair on `0.0.0.0`.
  ///
  /// Binds an ephemeral RTP socket, and if its OS-assigned port is even, binds
  /// RTCP to `port + 1`. Retries (closing partial state) until both land or
  /// `maxBindTries` is exhausted, then throws `transportNegotiationFailed`.
  static func bind() throws -> UDPPair {
    for _ in 0..<maxBindTries {
      guard let (rtpFD, rtpPort) = Self.openBound(port: 0) else { continue }
      // Need an even RTP port with a free consecutive odd RTCP port. (An even
      // port is at most 65534, so `rtpPort + 1` never overflows `UInt16`.)
      if rtpPort % 2 == 0, let (rtcpFD, _) = Self.openBound(port: rtpPort + 1) {
        return UDPPair(
          rtpFD: rtpFD, rtcpFD: rtcpFD, rtpPort: rtpPort, rtcpPort: rtpPort + 1)
      }
      Darwin.close(rtpFD)
    }
    throw RTSPError.transportNegotiationFailed
  }

  /// Open a non-blocking UDP socket bound to `0.0.0.0:port` (port 0 = ephemeral)
  /// and return its fd plus the actual bound port, or `nil` on any failure
  /// (e.g. the requested port is already taken). On failure the fd is closed.
  private static func openBound(port: UInt16) -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }

    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var rcvbuf = receiveBufferBytes
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      Darwin.close(fd)
      return nil
    }

    // Read back the OS-assigned port (only meaningful for the ephemeral case).
    var name = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &name) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &len)
      }
    }
    guard got == 0 else {
      Darwin.close(fd)
      return nil
    }

    // Non-blocking so the readiness-event drain loop terminates on EWOULDBLOCK
    // instead of blocking the dispatch queue.
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      Darwin.close(fd)
      return nil
    }

    return (fd, UInt16(bigEndian: name.sin_port))
  }

  // MARK: - Connecting

  /// Connect both sockets to the server's RTP (`peerRTPPort`) and RTCP
  /// (`peerRTPPort + 1`) ports. Connecting filters inbound datagrams to the peer
  /// (kernel drops spoofed/stray packets) and lets `holePunch()`/sends omit the
  /// address. IPv4 peers only — `peerHost` must be a numeric IPv4 address.
  func connect(peerHost: String, peerRTPPort: UInt16) throws {
    guard peerRTPPort < UInt16.max else {
      throw RTSPError.transportNegotiationFailed
    }
    try Self.connectFD(rtpFD, host: peerHost, port: peerRTPPort)
    try Self.connectFD(rtcpFD, host: peerHost, port: peerRTPPort + 1)
  }

  private static func connectFD(_ fd: Int32, host: String, port: UInt16) throws {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
      throw RTSPError.connectionFailed(
        "UDP transport supports IPv4 peers only; cannot use \"\(host)\"")
    }
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      throw RTSPError.connectionFailed("UDP connect to \(host):\(port) failed (errno \(errno))")
    }
  }

  /// Best-effort NAT/firewall hole-punch: send one empty datagram from each
  /// local port to its connected peer so the server learns our mapping and its
  /// RTP/RTCP can return. Harmless on loopback/LAN; errors are ignored (an empty
  /// datagram is not a valid RTP/RTCP packet, so the server simply drops it).
  func holePunch() {
    _ = Darwin.send(rtpFD, nil, 0, 0)
    _ = Darwin.send(rtcpFD, nil, 0, 0)
  }

  // MARK: - Receiving

  /// Begin delivering datagrams: `onRTP`/`onRTCP` are invoked (on a private
  /// serial queue) once per received datagram. No-op if already closed.
  func startReceiving(
    onRTP: @escaping @Sendable (Data) -> Void,
    onRTCP: @escaping @Sendable (Data) -> Void
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !closed, rtpSource == nil else { return }
    rtpSource = makeReadSource(fd: rtpFD, handler: onRTP)
    rtcpSource = makeReadSource(fd: rtcpFD, handler: onRTCP)
    rtpSource?.resume()
    rtcpSource?.resume()
  }

  private func makeReadSource(
    fd: Int32, handler: @escaping @Sendable (Data) -> Void
  ) -> DispatchSourceRead {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    // One reusable receive buffer per source (the handler runs serially on the
    // queue), freed in the cancel handler — avoids a 64 KiB allocation per
    // readiness event under sustained RTP.
    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: Self.datagramCapacity, alignment: MemoryLayout<UInt8>.alignment)
    source.setEventHandler {
      var drained = 0
      while drained < Self.maxDrainPerEvent {
        let n = recv(fd, buffer, Self.datagramCapacity, 0)
        if n > 0 {
          handler(Data(bytes: buffer, count: n))
          drained += 1
        } else if n == 0 {
          // An empty datagram (e.g. a peer's hole-punch) — already dequeued by
          // `recv`; skip it but keep draining.
          drained += 1
        } else if errno == EINTR {
          continue
        } else {
          // EWOULDBLOCK/EAGAIN (drained) or a real error: stop until next event.
          break
        }
      }
    }
    source.setCancelHandler {
      Darwin.close(fd)
      buffer.deallocate()
    }
    return source
  }

  // MARK: - Teardown

  /// Cancel both sources (which closes the file descriptors via their cancel
  /// handlers) and stop delivering datagrams. Idempotent.
  func close() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    closed = true
    if let rtpSource {
      rtpSource.cancel()
    } else {
      // Never started receiving: no source owns the fd, so close it directly.
      Darwin.close(rtpFD)
    }
    if let rtcpSource {
      rtcpSource.cancel()
    } else {
      Darwin.close(rtcpFD)
    }
    rtpSource = nil
    rtcpSource = nil
  }
}
