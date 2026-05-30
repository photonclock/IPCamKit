// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/parse.rs parse_setup()

import Foundation

/// Parse a SETUP response.
///
/// Ports upstream `parse_setup()` from parse.rs lines 538-614.
///
/// Extracts Session header (id + timeout) and Transport header
/// (ssrc, interleaved channels, source IP, server port).
func parseSetup(response: RTSPResponse) throws -> SetupResponse {
  // Parse Session header: "id;timeout=60" or just "id"
  guard let sessionValue = response.header("Session") else {
    throw RTSPError.sessionSetupFailed(
      statusCode: Int(response.statusCode), reason: "Missing Session header")
  }

  let sessionParts = sessionValue.split(separator: ";", maxSplits: 1)
  let sessionId = String(sessionParts[0]).trimmingCharacters(in: .whitespaces)
  var timeoutSec: UInt32 = 60  // default

  if sessionParts.count > 1 {
    let params = String(sessionParts[1]).trimmingCharacters(in: .whitespaces)
    for param in params.split(separator: ";") {
      let kv = param.split(separator: "=", maxSplits: 1)
      if kv.count == 2 {
        let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
        let value = kv[1].trimmingCharacters(in: .whitespaces)
        if key == "timeout" {
          // Some cameras/proxies send timeout=0 to mean "no expiry / no
          // keepalive needed". Treat 0 (and an unparseable value) as "use the
          // default cadence" instead of aborting SETUP.
          if let t = UInt32(value), t > 0 {
            timeoutSec = t
          }
        }
      }
    }
  }

  let session = SessionHeader(id: sessionId, timeoutSec: timeoutSec)

  // Parse Transport header (required per upstream parse_setup)
  guard let transport = response.header("Transport") else {
    throw RTSPError.sessionSetupFailed(
      statusCode: Int(response.statusCode), reason: "Missing Transport header")
  }

  var ssrc: UInt32?
  var channelId: UInt8?
  var source: String?
  var serverPort: UInt16?

  for param in transport.split(separator: ";") {
    let trimmed = param.trimmingCharacters(in: .whitespaces)
    let kv = trimmed.split(separator: "=", maxSplits: 1)
    guard kv.count == 2 else { continue }

    let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
    let value = String(kv[1]).trimmingCharacters(in: .whitespaces)

    switch key {
    case "ssrc":
      // SSRC is hex, may have leading whitespace
      ssrc = UInt32(value.trimmingCharacters(in: .whitespaces), radix: 16)
    case "interleaved":
      // Format: "0-1" (RTP channel - RTCP channel). The RTCP channel is
      // optional; when present it must be consecutive (matching retina). Routing
      // is parity-based, so only the RTP channel is kept.
      let channels = value.split(separator: "-")
      guard let first = UInt8(channels.first?.trimmingCharacters(in: .whitespaces) ?? "")
      else {
        throw RTSPError.sessionSetupFailed(
          statusCode: Int(response.statusCode),
          reason: "Invalid interleaved channels: \(value)")
      }
      if channels.count >= 2 {
        guard let second = UInt8(channels[1].trimmingCharacters(in: .whitespaces)),
          Int(second) == Int(first) + 1
        else {
          throw RTSPError.sessionSetupFailed(
            statusCode: Int(response.statusCode),
            reason: "Invalid interleaved channels: \(value)")
        }
      }
      channelId = first
    case "source":
      source = value
    case "server_port":
      // Format: "49152-49153" (must be consecutive ports)
      let ports = value.split(separator: "-")
      guard ports.count == 2,
        let first = UInt16(ports[0].trimmingCharacters(in: .whitespaces)),
        let second = UInt16(ports[1].trimmingCharacters(in: .whitespaces)),
        Int(second) == Int(first) + 1
      else {
        throw RTSPError.sessionSetupFailed(
          statusCode: Int(response.statusCode),
          reason: "Invalid server_port: \(value)")
      }
      serverPort = first
    default:
      break
    }
  }

  return SetupResponse(
    session: session,
    ssrc: ssrc,
    channelId: channelId,
    source: source,
    serverPort: serverPort
  )
}
