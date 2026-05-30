// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/client/rtp.rs - RTP/RTCP sequence tracking and SSRC validation

import Foundation

/// Policy for handling RTCP packets with unknown/mismatched SSRC.
/// Matches upstream UnknownRtcpSsrcPolicy.
enum UnknownRtcpSsrcPolicy: Sendable {
  /// Default behavior: silently drop packets with mismatched SSRC.
  case dropPackets
  /// Error out on mismatched SSRC.
  case abortSession
  /// Accept packets regardless of SSRC.
  case processPackets
}

/// Tracks RTP packet ordering, SSRC consistency, and loss detection.
///
/// Handles:
/// - SSRC validation (reject mismatched SSRCs)
/// - Sequence number tracking and loss detection
/// - Out-of-order packet detection (drop, emit diagnostic on TCP)
/// - Geovision PT=50 quirk (silently drop)
/// - RTCP compound packet validation and SR timestamp placement
struct InorderParser: Sendable {
  private var ssrc: UInt32?
  private var nextSeq: UInt16?
  private var isTcp: Bool
  var timeline: Timeline
  private var unknownRtcpSsrcPolicy: UnknownRtcpSsrcPolicy
  private let onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)?

  /// Kinds of recurring per-packet anomaly we warn about at most once per stream,
  /// so a hostile/sloppy camera can't flood the diagnostic sink with one
  /// diagnostic per packet.
  private enum DiagKind: Sendable {
    case malformedRtp, ssrcMismatch, rtpTimeline, outOfOrderTcp
    case unknownRtcpSsrc, malformedRtcp, rtcpTimeline
  }
  private var warned: Set<DiagKind> = []

  /// Number of RTP packets seen.
  private(set) var seenRtpPackets: UInt64 = 0

  /// Number of RTCP packets seen.
  private(set) var seenRtcpPackets: UInt64 = 0

  init(
    ssrc: UInt32?, nextSeq: UInt16?, isTcp: Bool, timeline: Timeline,
    unknownRtcpSsrcPolicy: UnknownRtcpSsrcPolicy = .dropPackets,
    onDiagnostic: (@Sendable (RTSPDiagnostic) -> Void)? = nil
  ) {
    self.ssrc = ssrc
    self.nextSeq = nextSeq
    self.isTcp = isTcp
    self.timeline = timeline
    self.unknownRtcpSsrcPolicy = unknownRtcpSsrcPolicy
    self.onDiagnostic = onDiagnostic
  }

  /// Emit `message` via `onDiagnostic` only the first time `kind` occurs on this
  /// stream; later occurrences are silent (rate-limited per the diagnostic
  /// contract).
  private mutating func warnOnce(
    _ kind: DiagKind, _ severity: RTSPDiagnostic.Severity,
    _ message: @autoclosure () -> String
  ) {
    guard warned.insert(kind).inserted else { return }
    onDiagnostic?(RTSPDiagnostic(severity: severity, message: message()))
  }

  /// Process an incoming RTP packet.
  ///
  /// Returns a ReceivedRTPPacket if the packet should be processed,
  /// or nil if it should be skipped (e.g., PT=50, out-of-order on UDP).
  mutating func rtp(
    data: Data,
    ctx: PacketContext,
    streamId: Int,
    streamCtx: StreamContext
  ) throws -> ReceivedRTPPacket? {
    let raw: RawRTPPacket
    switch RawRTPPacket.parse(data) {
    case .success(let pkt):
      raw = pkt
    case .failure(let reason):
      // A malformed datagram (truncated, wrong version, bad padding/extension)
      // is dropped, never fatal: one bad packet must not tear down the stream.
      warnOnce(
        .malformedRtp, .warning,
        "Invalid RTP packet from camera; dropping: \(reason). "
          + "Further malformed RTP on this stream is dropped silently.")
      return nil
    }

    // Geovision quirk: skip PT=50 packets
    if raw.payloadType == 50 {
      return nil
    }

    // SSRC validation. A mismatch (e.g. a camera that rotated its SSRC after an
    // internal restart, or a stray/spoofed datagram) drops by default rather
    // than killing the stream; `.abortSession` is the opt-in fatal policy.
    if let expectedSSRC = ssrc, raw.ssrc != expectedSSRC {
      switch unknownRtcpSsrcPolicy {
      case .abortSession:
        throw RTSPError.depacketizationError(
          "SSRC mismatch: expected \(String(format: "%08x", expectedSSRC)), "
            + "got \(String(format: "%08x", raw.ssrc))")
      case .dropPackets:
        warnOnce(
          .ssrcMismatch, .warning,
          "RTP SSRC mismatch (expected \(String(format: "%08x", expectedSSRC)), "
            + "got \(String(format: "%08x", raw.ssrc))); dropping. "
            + "Further SSRC-mismatched RTP on this stream is dropped silently.")
        return nil
      case .processPackets:
        break
      }
    } else if ssrc == nil {
      ssrc = raw.ssrc
    }

    // Sequence number tracking and loss detection
    var loss: UInt16 = 0
    if let expected = nextSeq {
      let delta = raw.sequenceNumber &- expected
      // Top bit set (delta in 0x8000...0xFFFF) means the packet sits in the
      // backward half of the sequence space: out of order or a duplicate.
      // 0x8000 itself is maximally ambiguous; treat it as out of order rather
      // than reporting a spurious 32768-packet loss.
      if delta >= 0x8000 {
        // Out of order. UDP reordering is normal and stays silent; TCP-interleaved
        // reordering means the camera's packetizer wrote sequence-numbers out of
        // order before muxing, which is camera misbehavior worth surfacing (once).
        if isTcp {
          warnOnce(
            .outOfOrderTcp, .warning,
            "Out-of-order RTP packet on TCP-interleaved transport: "
              + "seq=\(raw.sequenceNumber), expected=\(expected); packet dropped. "
              + "Further out-of-order RTP on this stream is dropped silently.")
        }
        return nil
      }
      loss = delta
    }
    nextSeq = raw.sequenceNumber &+ 1
    seenRtpPackets += 1

    // Advance timeline. A rejected/overflowing timestamp drops this packet
    // rather than aborting the session.
    let timestamp: Timestamp
    do {
      timestamp = try timeline.advanceTo(raw.rtpTimestamp)
    } catch {
      warnOnce(
        .rtpTimeline, .warning,
        "RTP timestamp rejected (\(error)); dropping. "
          + "Further timeline errors on this stream are dropped silently.")
      return nil
    }

    return ReceivedRTPPacket(
      ctx: ctx,
      streamId: streamId,
      timestamp: timestamp,
      raw: raw,
      loss: loss
    )
  }

  /// Process an incoming RTCP compound packet.
  ///
  /// Validates the compound packet per RFC 3550 Appendix A.2, extracts
  /// the Sender Report's RTP timestamp if present, and validates SSRC.
  /// Matches upstream rtcp() method (client/rtp.rs lines 243-311).
  mutating func rtcp(
    ctx: PacketContext,
    streamId: Int,
    data: Data
  ) throws -> ReceivedCompoundPacket? {
    // A malformed RTCP compound packet is dropped, not fatal.
    let firstPkt: RTCPPacketRef
    let sr: SenderReportRef?
    do {
      firstPkt = try ReceivedCompoundPacket.validate(data)
      sr = try firstPkt.asSenderReport()
    } catch {
      warnOnce(
        .malformedRtcp, .warning,
        "Invalid RTCP packet from camera; dropping: \(error). "
          + "Further malformed RTCP on this stream is dropped silently.")
      return nil
    }

    var rtpTimestamp: Timestamp?

    if let sr = sr {
      let srSSRC = sr.ssrc
      if let knownSSRC = ssrc, knownSSRC != srSSRC {
        switch unknownRtcpSsrcPolicy {
        case .abortSession:
          throw RTSPError.depacketizationError(
            "Expected ssrc=\(String(format: "%08x", knownSSRC)), "
              + "got RTCP SR ssrc=\(String(format: "%08x", srSSRC))")
        case .dropPackets:
          // Drop BEFORE touching the timeline: place() permanently anchors the
          // timeline `start` on the first SR, so a foreign/early SR must not be
          // allowed to corrupt the origin used by every subsequent RTP packet's
          // NPT. Warn once per stream; further unknown-SSRC SRs drop silently.
          warnOnce(
            .unknownRtcpSsrc, .warning,
            "RTCP Sender Report with unexpected ssrc="
              + "\(String(format: "%08x", srSSRC)) (expected "
              + "\(String(format: "%08x", knownSSRC))); dropping. Further "
              + "unknown-SSRC RTCP on this stream is dropped silently.")
          return nil
        case .processPackets:
          break
        }
      } else if ssrc == nil && unknownRtcpSsrcPolicy != .processPackets {
        ssrc = srSSRC
      }
      // Only anchor/advance the timeline for an SR we are actually keeping. A
      // rejected/overflowing SR timestamp drops the packet rather than aborting.
      do {
        rtpTimestamp = try timeline.place(sr.rtpTimestamp)
      } catch {
        warnOnce(
          .rtcpTimeline, .warning,
          "RTCP SR timestamp rejected (\(error)); dropping. "
            + "Further RTCP timeline errors on this stream are dropped silently.")
        return nil
      }
    }

    seenRtcpPackets += 1
    return ReceivedCompoundPacket(
      ctx: ctx,
      streamId: streamId,
      rtpTimestamp: rtpTimestamp,
      raw: data
    )
  }
}
