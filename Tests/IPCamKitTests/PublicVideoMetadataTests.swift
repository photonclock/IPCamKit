// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import IPCamKit

@Suite("Public Video Metadata Tests")
struct PublicVideoMetadataTests {
  @Test("Initial video description exposes SDP frame rate")
  func initialDescriptionUsesSDPFrameRate() throws {
    let presentation = try loadDescribe(
      url: "rtsp://127.0.0.1:554/camera",
      filename: "h264dvr_describe.txt")
    let stream = try #require(presentation.streams.first)
    let depacketizer = VideoDepacketizer.h264(
      try H264Depacketizer(clockRate: stream.clockRateHz, formatSpecificParams: nil))

    let video = depacketizer.publicVideoStream(
      clockRate: stream.clockRateHz,
      sdpFrameRate: stream.framerate)

    #expect(video.frameRate == 25)
  }

  @Test("Initial video description exposes parameter-set frame rate")
  func initialDescriptionUsesParameterSetFrameRate() throws {
    let depacketizer = VideoDepacketizer.h264(
      try H264Depacketizer(clockRate: 90_000, formatSpecificParams: dahuaFmtp))

    let video = depacketizer.publicVideoStream(clockRate: 90_000, sdpFrameRate: nil)

    #expect(video.frameRate == 15)
    #expect(video.resolution?.width == 704)
    #expect(video.resolution?.height == 480)
  }

  @Test("In-band parameter update exposes frame rate")
  func inBandParameterUpdateExposesFrameRate() throws {
    let suppliedParameters = try H264Parameters.parseFormatSpecificParams(dahuaFmtp)
    var depacketizer = try H264Depacketizer(
      clockRate: 90_000,
      formatSpecificParams: nil)

    try depacketizer.push(
      packet(sequence: 0, marked: false, payload: suppliedParameters.spsNAL))
    #expect(depacketizer.pull() == nil)
    try depacketizer.push(
      packet(sequence: 1, marked: false, payload: suppliedParameters.ppsNAL))
    #expect(depacketizer.pull() == nil)
    try depacketizer.push(
      packet(sequence: 2, marked: true, payload: Data([0x65, 0x88, 0x84])))

    guard case .success(.videoFrame(let frame)) = depacketizer.pull() else {
      Issue.record("Expected an in-band parameter update frame")
      return
    }

    let publicFrame = VideoDepacketizer.h264(depacketizer).publicVideoFrame(frame)
    #expect(publicFrame.frameRate == 15)
    #expect(publicFrame.resolution?.width == 704)
    #expect(publicFrame.resolution?.height == 480)
  }

  @Test("Initial video description rejects invalid SDP frame rates")
  func invalidSDPFrameRatesAreAbsent() throws {
    let depacketizer = VideoDepacketizer.h264(
      try H264Depacketizer(clockRate: 90_000, formatSpecificParams: nil))

    for value in [Float.zero, -1, .infinity, .nan] {
      let video = depacketizer.publicVideoStream(clockRate: 90_000, sdpFrameRate: value)
      #expect(video.frameRate == nil)
    }
  }

  private func packet(
    sequence: UInt16,
    marked: Bool,
    payload: Data
  ) -> ReceivedRTPPacket {
    let timestamp = Timestamp(timestamp: 0, clockRate: 90_000, start: 0)!
    let builder = ReceivedPacketBuilder(
      ctx: .dummy,
      streamId: 0,
      sequenceNumber: sequence,
      timestamp: timestamp,
      payloadType: 96,
      ssrc: 0,
      mark: marked,
      loss: 0)
    return try! builder.build(payload: payload).get()
  }
}
