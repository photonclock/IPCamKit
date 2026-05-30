// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Replaces upstream http_auth crate with native Swift authentication

import CryptoKit
import Foundation

/// RTSP credentials.
public struct Credentials: Sendable {
  public let username: String
  public let password: String

  public init(username: String, password: String) {
    self.username = username
    self.password = password
  }
}

/// Handles RTSP Basic and Digest authentication.
///
/// Parses WWW-Authenticate headers from 401 responses and generates
/// Authorization headers for subsequent requests.
struct RTSPAuthenticator: Sendable {
  private let credentials: Credentials
  private var digestState: DigestState?

  init(credentials: Credentials) {
    self.credentials = credentials
  }

  /// Parse a WWW-Authenticate header and update internal state.
  mutating func handleChallenge(_ wwwAuthenticate: String) {
    let trimmed = wwwAuthenticate.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased().hasPrefix("digest") {
      let state = parseDigestChallenge(String(trimmed.dropFirst(6)))
      // A digest challenge without a nonce is unusable; ignore it rather than
      // emit a bogus Authorization header. Accepting a fresh challenge also
      // resets the nonce-count (nc starts at 0).
      digestState = state.nonce.isEmpty ? nil : state
    }
    // Basic auth doesn't need to parse the challenge
  }

  /// Generate an Authorization header value for the given request.
  ///
  /// Mutates internal state: Digest+qop advances the nonce-count so each
  /// authorized request carries a unique, monotonically increasing `nc`.
  mutating func authorize(method: String, uri: String) -> String? {
    if digestState != nil {
      return generateDigestAuth(method: method, uri: uri)
    }
    // Fall back to Basic auth
    return generateBasicAuth()
  }

  /// Whether we have received a challenge and can generate auth headers.
  var hasChallenge: Bool {
    digestState != nil
  }

  // MARK: - Basic Auth

  private func generateBasicAuth() -> String {
    let credString = "\(credentials.username):\(credentials.password)"
    let base64 = Data(credString.utf8).base64EncodedString()
    return "Basic \(base64)"
  }

  // MARK: - Digest Auth

  struct DigestState: Sendable {
    var realm: String
    var nonce: String
    var qop: String?
    var opaque: String?
    var algorithm: String
    var nc: UInt32 = 0
  }

  private func parseDigestChallenge(_ params: String) -> DigestState {
    var realm = ""
    var nonce = ""
    var qop: String?
    var opaque: String?
    var algorithm = "MD5"

    for param in splitAuthParams(params) {
      let kv = param.split(separator: "=", maxSplits: 1)
      guard kv.count == 2 else { continue }
      let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
      let value = kv[1].trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

      switch key {
      case "realm": realm = value
      case "nonce": nonce = value
      case "qop": qop = value
      case "opaque": opaque = value
      case "algorithm": algorithm = value
      default: break
      }
    }

    return DigestState(
      realm: realm, nonce: nonce, qop: qop,
      opaque: opaque, algorithm: algorithm)
  }

  /// Digest hash family parsed from the challenge `algorithm` token.
  private enum DigestHash { case md5, sha256 }

  /// Map an `algorithm` token to a hash family and the `-sess` flag. Unknown
  /// algorithms fall back to MD5 (RFC 7616's default).
  private func parseAlgorithm(_ algorithm: String) -> (hash: DigestHash, sess: Bool) {
    let lower = algorithm.lowercased()
    let hash: DigestHash = lower.hasPrefix("sha-256") ? .sha256 : .md5
    return (hash, lower.hasSuffix("-sess"))
  }

  /// True iff the server's `qop` list offers plain "auth" (not only "auth-int").
  private func qopOffersAuth(_ qop: String) -> Bool {
    qop.split(separator: ",").contains {
      $0.trimmingCharacters(in: .whitespaces) == "auth"
    }
  }

  private func hashHex(_ hash: DigestHash, _ input: String) -> String {
    let bytes = Data(input.utf8)
    switch hash {
    case .md5:
      return Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    case .sha256:
      return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
  }

  private mutating func generateDigestAuth(method: String, uri: String) -> String {
    guard var state = digestState else { return generateBasicAuth() }
    let (hash, sess) = parseAlgorithm(state.algorithm)
    let cnonce = generateCNonce()

    var ha1 = hashHex(hash, "\(credentials.username):\(state.realm):\(credentials.password)")
    if sess {
      ha1 = hashHex(hash, "\(ha1):\(state.nonce):\(cnonce)")
    }
    let ha2 = hashHex(hash, "\(method):\(uri)")

    var header =
      "Digest username=\"\(credentials.username)\", realm=\"\(state.realm)\", "
      + "nonce=\"\(state.nonce)\", uri=\"\(uri)\", algorithm=\(state.algorithm)"

    if let qop = state.qop, qopOffersAuth(qop) {
      state.nc &+= 1
      let nc = String(format: "%08x", state.nc)
      let response = hashHex(hash, "\(ha1):\(state.nonce):\(nc):\(cnonce):auth:\(ha2)")
      header += ", response=\"\(response)\", qop=auth, nc=\(nc), cnonce=\"\(cnonce)\""
    } else {
      let response = hashHex(hash, "\(ha1):\(state.nonce):\(ha2)")
      header += ", response=\"\(response)\""
    }
    if let opaque = state.opaque {
      header += ", opaque=\"\(opaque)\""
    }
    digestState = state  // persist the advanced nonce-count
    return header
  }

  private func generateCNonce() -> String {
    let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Split auth parameters, handling quoted strings with commas inside.
  private func splitAuthParams(_ params: String) -> [String] {
    var result: [String] = []
    var current = ""
    var inQuotes = false
    for ch in params {
      if ch == "\"" {
        inQuotes.toggle()
        current.append(ch)
      } else if ch == "," && !inQuotes {
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        current = ""
      } else {
        current.append(ch)
      }
    }
    let trimmed = current.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty { result.append(trimmed) }
    return result
  }
}
