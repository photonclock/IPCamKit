// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/parse.rs parse_describe()

import Foundation

/// Parse a DESCRIBE response into a Presentation.
///
/// Ports upstream `parse_describe()` from parse.rs lines 414-499.
///
/// - Parameters:
///   - requestURL: The original DESCRIBE request URL
///   - response: The parsed RTSP response
/// - Returns: A Presentation with all parsed streams
func parseDescribe(
  requestURL: String,
  response: RTSPResponse,
  onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
) throws -> Presentation {
  // Validate content type (warn if missing, error if wrong)
  if let ct = response.contentType {
    let lower = ct.lowercased()
    if !lower.starts(with: "application/sdp") {
      throw RTSPError.invalidSDP("Unexpected Content-Type: \(ct)")
    }
  }
  // Note: upstream logs a warning for missing Content-Type but still continues

  // Determine base URL from Content-Base or Content-Location header. Some
  // cameras (e.g. Anjvision) send a scheme-less value such as
  // "192.168.1.10:554/stream0/"; resolve those against the request URL's
  // scheme instead of rejecting them. Port of retina 6972ac4.
  let baseURL: String
  if let raw = response.header("Content-Base")?.trimmingCharacters(in: .whitespaces)
    ?? response.header("Content-Location")?.trimmingCharacters(in: .whitespaces)
  {
    if hasURIScheme(raw) {
      baseURL = raw
    } else {
      let scheme = requestURL.prefix(while: { $0 != ":" })
      baseURL = scheme.isEmpty ? raw : "\(scheme)://\(raw)"
    }
  } else {
    baseURL = requestURL
  }

  // Parse SDP body
  guard !response.body.isEmpty else {
    throw RTSPError.invalidSDP("Empty SDP body")
  }

  let sdpParser = SDPParser()
  let sdp = try sdpParser.parse(response.body)

  // Extract session-level attributes
  var sessionControl = baseURL
  var tool: String?

  for attr in sdp.attributes {
    switch attr.name {
    case "control":
      if let value = attr.value {
        sessionControl = joinControl(base: baseURL, control: value)
      }
    case "tool":
      tool = attr.value
    default:
      break
    }
  }

  // Parse each media description into a Stream
  var streams: [Stream] = []
  var errors: [String] = []

  for mediaDesc in sdp.mediaDescriptions {
    do {
      let stream = try parseMedia(baseURL: baseURL, mediaDescription: mediaDesc)
      streams.append(stream)
    } catch {
      // A stream the camera offered that we can't parse (unsupported codec, bad
      // rtpmap, ...) is dropped. If at least one other stream parses the session
      // still starts, so surface the drop rather than losing it silently.
      errors.append(error.localizedDescription)
      onDiagnostic?(
        RTSPDiagnostic(
          severity: .warning,
          message: "Dropping unparseable \(mediaDesc.media) stream from SDP: "
            + error.localizedDescription))
    }
  }

  guard !streams.isEmpty else {
    throw RTSPError.invalidSDP(
      "No parseable streams in SDP. Errors: \(errors.joined(separator: "; "))")
  }

  return Presentation(
    streams: streams,
    baseURL: baseURL,
    control: sessionControl,
    tool: tool
  )
}

/// Whether `s` begins with a URI scheme (`scheme:` where the scheme starts with
/// a letter), per RFC 3986. Used to distinguish an absolute Content-Base from a
/// scheme-less one like "192.168.1.10:554/stream0/" (which has a `:` for the
/// port but no scheme). Mirrors retina's `Url::parse` succeed/fail check.
func hasURIScheme(_ s: String) -> Bool {
  guard let colon = s.firstIndex(of: ":") else { return false }
  let scheme = s[s.startIndex..<colon]
  guard let first = scheme.first, first.isLetter else { return false }
  return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
}
