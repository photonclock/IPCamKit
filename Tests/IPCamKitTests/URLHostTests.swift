// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Unit tests for URL host normalization (IPv6 bracket stripping).

import Testing

@testable import IPCamKit

@Suite("URL host parsing")
struct URLHostTests {

  @Test("Strips brackets from an IPv6 literal host")
  func stripsIPv6Brackets() {
    #expect(unbracketedHost("[::1]") == "::1")
    #expect(unbracketedHost("[2001:db8::1]") == "2001:db8::1")
  }

  @Test("Preserves the zone id inside a link-local IPv6 host")
  func preservesZoneId() {
    #expect(unbracketedHost("[fe80::1%en0]") == "fe80::1%en0")
  }

  @Test("Leaves IPv4 and hostname hosts unchanged")
  func leavesNonBracketedUnchanged() {
    #expect(unbracketedHost("127.0.0.1") == "127.0.0.1")
    #expect(unbracketedHost("camera.local") == "camera.local")
    // A bare IPv6 literal (no brackets) is already in NWEndpoint.Host form.
    #expect(unbracketedHost("::1") == "::1")
  }

  @Test("Does not mangle a host with only one bracket")
  func toleratesUnbalancedBrackets() {
    #expect(unbracketedHost("[::1") == "[::1")
    #expect(unbracketedHost("::1]") == "::1]")
  }
}
