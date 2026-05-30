// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// NWConnection-based TCP transport for RTSP

import Foundation
import Network

/// A TCP connection for RTSP communication using Apple's Network framework.
///
/// Handles:
/// - TCP connection lifecycle (connect, send, receive)
/// - RTSP message framing (responses and interleaved data)
/// - Buffered reading for partial message assembly
/// - Private dispatch queue for NWConnection callbacks
actor RTSPTransportConnection {
  private var connection: NWConnection?
  private let queue = DispatchQueue(label: "ipcamkit.rtsp.connection")
  private let parser = RTSPParser()
  private var readBuffer = Data()
  private var connectionContext: ConnectionContext?

  /// Hard cap on the unparsed read buffer. A peer that never frames a message —
  /// no header terminator, or a `$`-interleaved frame whose length is never
  /// satisfied — would otherwise grow this without bound (memory-DoS). A full
  /// interleaved frame is at most ~64 KiB and an RTSP message body is capped at
  /// `RTSPParser.maxBodyBytes`, so this leaves wide headroom for any real camera.
  private static let maxReadBufferBytes = 4 * 1024 * 1024

  /// Maximum time to wait for the TCP connection to become ready. NWConnection
  /// has no built-in connect deadline, so a half-open server would otherwise
  /// hang `connect()` forever.
  private let connectTimeoutSeconds: Double = 15

  /// Grace window for a transient `.waiting` state (e.g. connection refused /
  /// no route, which NWConnection parks in `.waiting` rather than `.failed`)
  /// before surfacing the real error, so an unreachable camera fails fast with
  /// its actual cause instead of burning the full connect timeout.
  private let waitingGraceSeconds: Double = 2

  /// Count of interleaved data frames dropped by `receiveResponse` while waiting
  /// for an RTSP response (a camera that streamed media before its PLAY reply).
  private(set) var droppedInterleavedBeforeResponse = 0

  /// One-shot guard so the connect continuation resumes exactly once across the
  /// state handler and the timeout. Both run on the serial `queue`, so plain
  /// access is race-free (hence `@unchecked Sendable`).
  private final class ConnectGuard: @unchecked Sendable {
    var settled = false
  }

  /// Connect to an RTSP server.
  func connect(host: String, port: UInt16) async throws {
    let nwHost = NWEndpoint.Host(host)
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw RTSPError.connectionFailed("Invalid port \(port)")
    }
    let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)

    self.connection = conn

    let guardState = ConnectGuard()
    let timeout = connectTimeoutSeconds
    do {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        // Resume exactly once; only ever called on the serial `queue`.
        @Sendable func settle(_ result: Result<Void, Error>) {
          guard !guardState.settled else { return }
          guardState.settled = true
          continuation.resume(with: result)
        }
        let grace = waitingGraceSeconds
        let graceQueue = queue
        conn.stateUpdateHandler = { state in
          switch state {
          case .ready:
            settle(.success(()))
          case .failed(let error):
            settle(.failure(RTSPError.connectionFailed(error.localizedDescription)))
          case .waiting(let error):
            // NWConnection parks in .waiting for ECONNREFUSED/EHOSTUNREACH
            // instead of going to .failed. Give it a brief grace window to
            // self-recover, then surface the real error rather than waiting out
            // the full connect timeout. A later .ready/.failed settles first
            // (the one-shot guard makes this deferred settle a no-op).
            graceQueue.asyncAfter(deadline: .now() + grace) {
              settle(.failure(RTSPError.connectionFailed(error.localizedDescription)))
            }
          case .cancelled:
            settle(.failure(RTSPError.unexpectedDisconnection))
          default:
            break
          }
        }
        queue.asyncAfter(deadline: .now() + timeout) {
          settle(.failure(RTSPError.timeout))
        }
        conn.start(queue: queue)
      }
    } catch {
      // On timeout/failure, tear down the half-open socket. A late `.cancelled`
      // from this is ignored by the already-settled guard.
      conn.cancel()
      connection = nil
      throw error
    }

    // Clear the state handler after connection
    conn.stateUpdateHandler = nil

    if let localEndpoint = conn.currentPath?.localEndpoint,
      let remoteEndpoint = conn.currentPath?.remoteEndpoint
    {
      connectionContext = ConnectionContext(
        localAddr: "\(localEndpoint)",
        peerAddr: "\(remoteEndpoint)",
        establishedWall: .now()
      )
    } else {
      connectionContext = .dummy()
    }
  }

  /// Send raw data over the connection.
  func send(_ data: Data) async throws {
    guard let conn = connection else {
      throw RTSPError.connectionFailed("Not connected")
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      conn.send(
        content: data,
        completion: .contentProcessed({ error in
          if let error = error {
            continuation.resume(
              throwing: RTSPError.connectionFailed("Send failed: \(error.localizedDescription)"))
          } else {
            continuation.resume()
          }
        }))
    }
  }

  /// Send an RTSP request and wait for the response.
  func sendRequest(_ request: RTSPRequest) async throws -> RTSPResponse {
    let serializer = RTSPSerializer()
    let data = serializer.serialize(request)
    try await send(data)
    return try await receiveResponse()
  }

  /// Receive the next RTSP message (response or interleaved data).
  func receiveMessage() async throws -> RTSPMessage {
    while true {
      // Try to parse from existing buffer
      var bufferCopy = readBuffer
      if let (msg, _) = try parser.parse(&bufferCopy) {
        readBuffer = bufferCopy
        return msg
      }

      // No complete message yet. Bound the buffer before reading more so a peer
      // that never frames a message can't exhaust memory. Checked here (after
      // the parse attempt) so a message that just completed still parses.
      guard readBuffer.count <= Self.maxReadBufferBytes else {
        throw RTSPError.connectionFailed(
          "RTSP read buffer exceeded \(Self.maxReadBufferBytes) bytes without a complete message")
      }

      // Need more data
      let newData = try await readData()
      readBuffer.append(newData)
    }
  }

  /// Receive the next RTSP response, skipping interleaved data.
  ///
  /// Only used on the pre-PLAY request/response path (OPTIONS/DESCRIBE/SETUP/
  /// PLAY). Per RFC 2326 the server must not stream media before the PLAY reply,
  /// so no interleaved `.data` is expected here; any that arrives (a
  /// non-conformant camera bursting media on the control channel before PLAY) is
  /// dropped and counted in `droppedInterleavedBeforeResponse` for diagnostics.
  func receiveResponse() async throws -> RTSPResponse {
    while true {
      let msg = try await receiveMessage()
      if case .response(let resp) = msg {
        return resp
      }
      // Interleaved data before the awaited response — drop and tally it.
      droppedInterleavedBeforeResponse += 1
    }
  }

  /// Read raw data from the connection.
  ///
  /// Known limitation: there is no per-read idle timeout. A peer that goes
  /// silent after setup leaves this parked until `close()` (via `stop()`) is
  /// called or the keepalive detects the dead session. An idle timeout is
  /// deliberately omitted — sizing it without killing legitimately bursty /
  /// low-FPS streams is unsafe — so liveness is the keepalive/stop() contract.
  private func readData() async throws -> Data {
    guard let conn = connection else {
      throw RTSPError.unexpectedDisconnection
    }

    return try await withCheckedThrowingContinuation { continuation in
      conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
        content, _, isComplete, error in
        if let error = error {
          continuation.resume(
            throwing: RTSPError.connectionFailed("Read error: \(error.localizedDescription)"))
        } else if let data = content, !data.isEmpty {
          continuation.resume(returning: data)
        } else if isComplete {
          continuation.resume(throwing: RTSPError.unexpectedDisconnection)
        } else {
          continuation.resume(throwing: RTSPError.unexpectedDisconnection)
        }
      }
    }
  }

  /// Close the connection.
  func close() {
    connection?.cancel()
    connection = nil
  }

  /// The connection context for error reporting.
  var ctx: ConnectionContext {
    connectionContext ?? .dummy()
  }

  /// The resolved remote address (and family) of the control connection, if
  /// available. Lets UDP transport pick its local socket family and target the
  /// server's RTP/RTCP ports without a second DNS lookup when the SETUP response
  /// omits an explicit `source`. The host is a numeric literal — a dotted IPv4
  /// address or a bare IPv6 address (with zone id for link-local) — never
  /// bracketed, so it can be handed straight to `NWEndpoint.Host`. Returns `nil`
  /// for unresolved endpoints.
  func resolvedRemote() -> ResolvedPeer? {
    guard case .hostPort(let host, _)? = connection?.currentPath?.remoteEndpoint else {
      return nil
    }
    switch host {
    case .ipv4(let addr):
      return ResolvedPeer(host: "\(addr)", isIPv6: false)
    case .ipv6(let addr):
      return ResolvedPeer(host: "\(addr)", isIPv6: true)
    case .name:
      // An unresolved hostname endpoint is not directly usable as a UDP peer
      // (no family known); callers fall back to the URL host / source instead.
      return nil
    @unknown default:
      return nil
    }
  }
}

/// The resolved remote peer of the control connection: a numeric host literal
/// plus its address family. Drives the UDP transport's local socket family and
/// RTP/RTCP peer selection.
struct ResolvedPeer: Sendable {
  /// Numeric IP literal (dotted IPv4 or bare IPv6, with zone id for link-local).
  let host: String
  /// `true` for IPv6, `false` for IPv4.
  let isIPv6: Bool
}
