// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream rtsp_types crate parsing + tokio.rs Codec

import Foundation

/// Parses RTSP messages from a byte buffer.
///
/// Handles both RTSP responses (status line + headers + optional body)
/// and interleaved data frames ('$' + channel + length + payload).
///
/// Mirrors the parsing logic in upstream tokio.rs Codec::parse_msg.
public struct RTSPParser: Sendable {
  /// Maximum RTSP message body (`Content-Length`) we will accept. RTSP bodies —
  /// SDP, `GET_PARAMETER` lists — are KB-scale; this is generous headroom that
  /// still rejects a hostile/absurd `Content-Length` before any of it is
  /// buffered (memory-DoS guard). Kept below `RTSPTransportConnection`'s read
  /// buffer cap so a body this size still frames before the connection trips.
  static let maxBodyBytes = 2 * 1024 * 1024

  public init() {}

  /// Attempts to parse one RTSP message from the given buffer.
  ///
  /// Returns the parsed message and the number of bytes consumed,
  /// or nil if the buffer doesn't contain a complete message yet.
  ///
  /// Throws on malformed data that can't be recovered from.
  public func parse(_ buffer: inout Data) throws -> (RTSPMessage, Int)? {
    // Skip leading CRLF pairs (same as upstream)
    while buffer.count >= 2 && buffer[buffer.startIndex] == 0x0D
      && buffer[buffer.startIndex + 1] == 0x0A
    {
      buffer.removeFirst(2)
    }

    guard !buffer.isEmpty else { return nil }

    // Interleaved data: '$' + channel_id + 2-byte BE length + data
    if buffer[buffer.startIndex] == 0x24 {  // '$'
      return try parseInterleavedData(&buffer)
    }

    // RTSP response
    return try parseResponse(&buffer)
  }

  /// Parse interleaved data frame.
  /// Format: '$' (1 byte) + channel_id (1 byte) + length (2 bytes BE) + data
  func parseInterleavedData(_ buffer: inout Data) throws -> (RTSPMessage, Int)? {
    guard buffer.count >= 4 else { return nil }

    let channelId = buffer[buffer.startIndex + 1]
    let length = Int(
      UInt16(buffer[buffer.startIndex + 2]) << 8
        | UInt16(buffer[buffer.startIndex + 3]))
    let totalLength = 4 + length

    guard buffer.count >= totalLength else { return nil }

    let payload = buffer.subdata(in: (buffer.startIndex + 4)..<(buffer.startIndex + totalLength))
    buffer.removeFirst(totalLength)

    let msg = RTSPInterleavedData(channelId: channelId, data: payload)
    return (.data(msg), totalLength)
  }

  /// Parse an RTSP response message.
  ///
  /// Format:
  /// ```
  /// RTSP/1.0 <status-code> <reason>\r\n
  /// <header-name>: <header-value>\r\n
  /// ...
  /// \r\n
  /// [body]
  /// ```
  func parseResponse(_ buffer: inout Data) throws -> (RTSPMessage, Int)? {
    // Find the end of headers (double CRLF)
    guard let headerEndRange = findDoubleCRLF(in: buffer) else {
      return nil  // Need more data
    }

    let headerEnd = headerEndRange.upperBound
    let headerData = buffer[buffer.startIndex..<headerEndRange.lowerBound]

    guard let headerString = String(data: Data(headerData), encoding: .utf8) else {
      throw RTSPError.depacketizationError("Invalid UTF-8 in RTSP response headers")
    }

    // Split on either a CRLF (per RFC) or a bare LF (sloppy cameras/proxies).
    // Swift fuses "\r\n" into one grapheme `Character`, so splitting on a lone
    // "\n" would miss CRLF lines — match both grapheme separators explicitly.
    var lines = headerString.split(omittingEmptySubsequences: false) {
      $0 == "\n" || $0 == "\r\n"
    }.map(String.init)

    guard !lines.isEmpty else {
      throw RTSPError.depacketizationError("Empty RTSP response")
    }

    // Parse status line: "RTSP/1.0 200 OK"
    let statusLine = lines.removeFirst()
    let (version, statusCode, reasonPhrase) = try parseStatusLine(statusLine)

    // Parse headers
    var headers: [(String, String)] = []
    for line in lines {
      if line.isEmpty { continue }
      if let colonIdx = line.firstIndex(of: ":") {
        // Trim the field name as well as the value: some cameras emit
        // "CSeq : 1" with space before the colon. Lookups lowercase the name
        // but don't trim, so an untrimmed "CSeq " would never match "cseq" and
        // CSeq-based response routing would silently break. Trim newlines too,
        // so a stray CR from a mixed CRLF-headers/bare-LF-terminator boundary
        // (e.g. "...CSeq: 1\r\n\n") never leaves "1\r" and breaks numeric parses.
        let name = String(line[line.startIndex..<colonIdx])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStart = line.index(after: colonIdx)
        let value = String(line[valueStart...]).trimmingCharacters(
          in: .whitespacesAndNewlines)
        headers.append((name, value))
      }
    }

    // Determine body length from Content-Length header. The value is
    // attacker-controlled, so reject negatives outright.
    var bodyLength = 0
    let contentLengthKey = headers.first(where: { $0.0.lowercased() == "content-length" })
    if let cl = contentLengthKey {
      guard let len = Int(cl.1.trimmingCharacters(in: .whitespaces)), len >= 0 else {
        throw RTSPError.depacketizationError("Invalid Content-Length: \(cl.1)")
      }
      // Reject an absurd declared body up front so we never try to buffer it.
      guard len <= Self.maxBodyBytes else {
        throw RTSPError.depacketizationError(
          "Content-Length too large: \(len) (max \(Self.maxBodyBytes))")
      }
      bodyLength = len
    }

    let headerBytes = headerEnd - buffer.startIndex
    // If the body hasn't fully arrived, wait for more data. Comparing against
    // the bytes remaining (rather than computing `headerBytes + bodyLength`
    // first) keeps an absurd Content-Length such as Int.max from overflowing.
    guard bodyLength <= buffer.count - headerBytes else {
      return nil  // Need more data for body
    }
    let totalLength = headerBytes + bodyLength

    var body = Data()
    if bodyLength > 0 {
      body = buffer.subdata(in: headerEnd..<(headerEnd + bodyLength))
    }

    buffer.removeFirst(totalLength)

    let response = RTSPResponse(
      statusCode: statusCode,
      reasonPhrase: reasonPhrase,
      version: version,
      headers: headers,
      body: body
    )
    return (.response(response), totalLength)
  }

  /// Parse "RTSP/1.0 200 OK" into components.
  func parseStatusLine(_ line: String) throws -> (String, UInt16, String) {
    // Split into at most 3 parts: version, status code, reason phrase.
    // Separate on runs of spaces/tabs so a doubled space ("RTSP/1.0  200 OK")
    // or the odd tab-delimited camera still reads the code from the right field.
    let parts = line.split(
      maxSplits: 2, omittingEmptySubsequences: true,
      whereSeparator: { $0 == " " || $0 == "\t" })
    guard parts.count >= 2 else {
      throw RTSPError.depacketizationError("Invalid RTSP status line: \(line)")
    }

    let version = String(parts[0])
    // Read the leading ASCII digits of the code field so trailing junk on the
    // status code doesn't abort an otherwise usable connection.
    let digits = parts[1].prefix(while: { $0.isASCII && $0.isNumber })
    guard let statusCode = UInt16(digits) else {
      throw RTSPError.depacketizationError("Invalid status code in: \(line)")
    }
    let reasonPhrase = parts.count >= 3 ? String(parts[2]) : ""

    return (version, statusCode, reasonPhrase)
  }

  /// Find the header/body boundary (the blank line) and return its byte range:
  /// `lowerBound` is the start of the terminating line break, `upperBound` the
  /// first body byte. Recognizes `\r\n\r\n` (per RFC) and, for sloppy cameras,
  /// a bare `\n\n`. Scans the `Data` in place via `withUnsafeBytes` — no
  /// per-call full-buffer copy — so repeated calls as a body streams in stay
  /// O(n) overall rather than O(n^2).
  func findDoubleCRLF(in data: Data) -> Range<Int>? {
    let start = data.startIndex
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Range<Int>? in
      let n = raw.count
      guard n >= 2 else { return nil }
      var i = 0
      while i < n - 1 {
        if raw[i] == 0x0A && raw[i + 1] == 0x0A {
          return (start + i)..<(start + i + 2)  // bare LF + LF
        }
        if i + 3 < n && raw[i] == 0x0D && raw[i + 1] == 0x0A
          && raw[i + 2] == 0x0D && raw[i + 3] == 0x0A
        {
          return (start + i)..<(start + i + 4)  // CR LF CR LF
        }
        i += 1
      }
      return nil
    }
  }
}
