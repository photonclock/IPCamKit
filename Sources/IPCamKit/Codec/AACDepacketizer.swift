// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Port of retina src/codec/aac.rs - AAC RTP depacketizer (RFC 3640)

import Foundation

/// AAC (Advanced Audio Codec) RTP depacketizer per RFC 3640.
///
/// Supports AAC-hbr mode with:
/// - Single frames per packet
/// - Aggregation (multiple AUs per packet)
/// - Fragmentation (single AU split across packets)
/// - Loss tracking (prevLoss vs lossSinceMark)
struct AACDepacketizer: Sendable {
  private let config: AudioSpecificConfig
  var parameters: AudioParameters {
    config.parameters
  }
  private var state: DepacketizerState

  init(
    clockRate: UInt32, channels: UInt16?, formatSpecificParams: String?
  ) throws {
    guard let fsp = formatSpecificParams else {
      throw DepacketizeError("AAC requires format specific params")
    }
    let config = try parseAACFormatSpecificParams(
      clockRate: clockRate, formatSpecificParams: fsp)
    // RFC 3640: the AudioSpecificConfig in `config=` is authoritative for AAC.
    // The rtpmap channel count (`channels`) is informational and frequently
    // wrong or omitted on real cameras, so do not reject on mismatch — trust
    // the ASC. `channels` is retained in the signature for API compatibility.
    self.config = config
    self.state = .idle(prevLoss: 0, lossSinceMark: false)
  }

  // MARK: - State Machine

  private enum DepacketizerState: Sendable {
    /// No buffered data.
    case idle(prevLoss: UInt16, lossSinceMark: Bool)
    /// After an RTP packet has been received (single, aggregate, or first fragment).
    case aggregated(Aggregate)
    /// Prefix of a fragmented AU has been received.
    case fragmented(Fragment)
    /// A complete frame is ready to be pulled.
    case ready(AudioFrame)
  }

  /// State holding access units within a single RTP packet.
  private struct Aggregate: Sendable {
    var pkt: ReceivedRTPPacket
    /// RTP packets lost before the next frame. Should be 0 when frameI > 0.
    var loss: UInt16
    /// True iff loss occurred since the last mark bit.
    var lossSinceMark: Bool
    /// Index of the next frame to return (0..<frameCount).
    var frameI: UInt16
    /// Total frames in this aggregate.
    var frameCount: UInt16
    /// Byte offset of frameI's data within pkt.payload.
    var dataOff: Int
  }

  /// The received prefix of an AU split across multiple packets.
  private struct Fragment: Sendable {
    var rtpTimestamp: UInt32
    /// Packets lost before this fragment started.
    var loss: UInt16
    /// True iff packets have been lost since the last mark.
    var lossSinceMark: Bool
    var size: UInt16
    var buf: Data
  }

  // MARK: - Push

  mutating func push(_ pkt: ReceivedRTPPacket) throws {
    // If there's loss and we're mid-fragment, discard the fragment.
    if pkt.loss > 0 {
      if case .fragmented(let f) = state {
        state = .idle(prevLoss: f.loss, lossSinceMark: true)
      }
    }

    let payload = pkt.payload
    guard payload.count >= 2 else {
      throw DepacketizeError("packet too short for au-header-length")
    }
    let auHeadersLengthBits =
      UInt16(payload[payload.startIndex]) << 8
      | UInt16(payload[payload.startIndex + 1])

    // AAC-hbr headers are 16 bits (13-bit size + 3-bit index), so the declared
    // AU-headers-length must be a multiple of 16. Enforce that rather than the
    // looser multiple-of-8, which would silently truncate an off-spec length.
    guard (auHeadersLengthBits & 0xF) == 0 else {
      throw DepacketizeError("bad au-headers-length \(auHeadersLengthBits)")
    }
    let auHeadersCount = auHeadersLengthBits >> 4
    let dataOff = 2 + (Int(auHeadersCount) << 1)
    guard payload.count >= dataOff else {
      throw DepacketizeError("packet too short for au-headers")
    }

    switch state {
    case .fragmented(var frag):
      guard auHeadersCount == 1 else {
        throw DepacketizeError(
          "Got \(auHeadersCount)-AU packet while fragment in progress")
      }
      // Compare the full 32-bit wire timestamp: a UInt16 narrowing could let two
      // genuinely different timestamps whose low 16 bits collide be mis-stitched.
      let pktTs = UInt32(truncatingIfNeeded: pkt.timestamp.timestamp)
      guard pktTs == frag.rtpTimestamp else {
        throw DepacketizeError(
          "Timestamp changed from 0x\(String(frag.rtpTimestamp, radix: 16)) "
            + "to 0x\(String(pktTs, radix: 16)) mid-fragment")
      }
      let auHeader =
        UInt16(payload[payload.startIndex + 2]) << 8
        | UInt16(payload[payload.startIndex + 3])
      let size = Int(auHeader >> 3)
      guard size == Int(frag.size) else {
        throw DepacketizeError(
          "size changed \(frag.size)->\(size) mid-fragment")
      }
      let data = payload[(payload.startIndex + dataOff)...]
      let totalLen = frag.buf.count + data.count
      if totalLen < size {
        // Still incomplete
        if pkt.mark {
          if frag.lossSinceMark {
            state = .idle(prevLoss: frag.loss, lossSinceMark: false)
            return
          }
          throw DepacketizeError(
            "frag marked complete when \(frag.buf.count)+\(data.count)<\(size)")
        }
        frag.buf.append(contentsOf: data)
        state = .fragmented(frag)
      } else if totalLen == size {
        guard pkt.mark else {
          throw DepacketizeError(
            "frag not marked complete when full data present")
        }
        frag.buf.append(contentsOf: data)
        state = .ready(
          AudioFrame(
            ctx: pkt.ctx,
            streamId: pkt.streamId,
            timestamp: pkt.timestamp,
            frameLength: UInt32(config.frameLength),
            loss: frag.loss,
            data: frag.buf
          ))
      } else {
        throw DepacketizeError("too much data in fragment")
      }

    case .aggregated:
      preconditionFailure("push when already in state aggregated")

    case .idle(let prevLoss, let lossSinceMark):
      guard auHeadersCount > 0 else {
        throw DepacketizeError("aggregate with no headers")
      }
      let loss = pkt.loss
      state = .aggregated(
        Aggregate(
          pkt: pkt,
          loss: UInt16(clamping: UInt32(prevLoss) + UInt32(loss)),
          lossSinceMark: lossSinceMark || loss > 0,
          frameI: 0,
          frameCount: auHeadersCount,
          dataOff: dataOff
        ))

    case .ready:
      preconditionFailure("push when in state ready")
    }
  }

  // MARK: - Pull

  private func makeError(
    _ pkt: ReceivedRTPPacket, _ description: String
  ) -> DepacketizeError {
    DepacketizeError(
      pktCtx: pkt.ctx, ssrc: pkt.ssrc,
      sequenceNumber: pkt.sequenceNumber, description: description)
  }

  mutating func pull() -> Result<CodecItem, DepacketizeError>? {
    switch state {
    case .idle, .fragmented:
      return nil

    case .ready(let frame):
      state = .idle(prevLoss: 0, lossSinceMark: false)
      return .success(.audioFrame(frame))

    case .aggregated(var agg):
      let i = Int(agg.frameI)
      let payload = agg.pkt.payload
      let mark = agg.pkt.mark
      let auHeader =
        UInt16(payload[payload.startIndex + 2 + (i << 1)]) << 8
        | UInt16(payload[payload.startIndex + 3 + (i << 1)])
      let size = Int(auHeader >> 3)
      let index = auHeader & 0b111
      if index != 0 {
        state = .idle(prevLoss: 0, lossSinceMark: false)
        return .failure(
          makeError(agg.pkt, "interleaving not yet supported"))
      }

      let remainingData = payload.count - agg.dataOff
      if size > remainingData {
        // Start of fragment
        if agg.frameCount != 1 {
          state = .idle(prevLoss: 0, lossSinceMark: false)
          return .failure(
            makeError(
              agg.pkt, "fragmented AUs must not share packets"))
        }
        if mark {
          if agg.lossSinceMark {
            state = .idle(prevLoss: agg.loss, lossSinceMark: false)
            return nil
          }
          state = .idle(prevLoss: 0, lossSinceMark: false)
          return .failure(
            makeError(
              agg.pkt,
              "mark can't be set on beginning of fragment"))
        }
        var buf = Data(capacity: size)
        buf.append(
          contentsOf: payload[(payload.startIndex + agg.dataOff)...])
        state = .fragmented(
          Fragment(
            rtpTimestamp: UInt32(
              truncatingIfNeeded: agg.pkt.timestamp.timestamp),
            loss: agg.loss,
            lossSinceMark: agg.lossSinceMark,
            size: UInt16(size),
            buf: buf
          ))
        return nil
      }

      if !mark {
        state = .idle(prevLoss: 0, lossSinceMark: false)
        return .failure(
          makeError(
            agg.pkt, "mark must be set on non-fragmented au"))
      }

      let delta = UInt32(agg.frameI) * UInt32(config.frameLength)
      guard let adjustedTimestamp = agg.pkt.timestamp.adding(delta)
      else {
        state = .idle(prevLoss: 0, lossSinceMark: false)
        return .failure(
          makeError(
            agg.pkt,
            "aggregate timestamp \(agg.pkt.timestamp) + \(delta) overflows"
          ))
      }

      let frameData = Data(
        payload[
          (payload.startIndex + agg.dataOff)..<(payload.startIndex
            + agg.dataOff + size)
        ])
      let frame = AudioFrame(
        ctx: agg.pkt.ctx,
        streamId: agg.pkt.streamId,
        timestamp: adjustedTimestamp,
        frameLength: UInt32(config.frameLength),
        loss: agg.loss,
        data: frameData
      )
      agg.loss = 0
      agg.dataOff += size
      agg.frameI += 1
      if agg.frameI < agg.frameCount {
        state = .aggregated(agg)
      } else {
        state = .idle(prevLoss: 0, lossSinceMark: false)
      }
      return .success(.audioFrame(frame))
    }
  }
}
