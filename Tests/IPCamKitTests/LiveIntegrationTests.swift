// Copyright (c) 2025 Steel Brain
// SPDX-License-Identifier: MIT
// Live end-to-end integration tests.
//
// `ffmpeg` publishes a synthetic stream to a `mediamtx` RTSP server, and
// `RTSPClientSession` pulls it back over RTSP-interleaved TCP — exercising the
// full DESCRIBE -> SETUP -> PLAY -> depacketize pipeline against a real,
// spec-compliant server.
//
// These tests REQUIRE `ffmpeg` and `mediamtx` on `PATH` (see README "Testing").
// They are serialized so only one server/publisher pair runs at a time.

import Darwin
import Foundation
import Testing

@testable import IPCamKit

// MARK: - Errors

private struct LiveError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

// MARK: - Loopback port helpers

/// Bind a TCP socket to 127.0.0.1:`port` (use 0 for an OS-assigned ephemeral
/// port) and return the open fd plus the bound port. The socket stays open so
/// the caller can hold the port reserved; the caller must close the fd.
private func bindLoopback(_ port: UInt16) -> (fd: Int32, port: UInt16)? {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bound == 0 else {
    close(fd)
    return nil
  }
  guard port == 0 else { return (fd, port) }
  var name = sockaddr_in()
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  let got = withUnsafeMutablePointer(to: &name) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      getsockname(fd, $0, &len)
    }
  }
  guard got == 0 else {
    close(fd)
    return nil
  }
  return (fd, UInt16(bigEndian: name.sin_port))
}

/// Reserve a free RTSP port plus a consecutive even/odd RTP/RTCP UDP pair.
/// MediaMTX requires the RTP port to be even with RTCP = RTP + 1. All sockets
/// are held open simultaneously so the ports are guaranteed distinct and free,
/// then released for the child process. There is a small TOCTOU window, but the
/// live suite is serialized and binds the ports immediately.
func reserveServerPorts() -> (rtsp: UInt16, rtp: UInt16, rtcp: UInt16)? {
  var held: [Int32] = []
  defer { for fd in held { close(fd) } }

  guard let rtsp = bindLoopback(0) else { return nil }
  held.append(rtsp.fd)

  for _ in 0..<400 {
    guard let candidate = bindLoopback(0) else { continue }
    let base = candidate.port
    if base % 2 == 0, base > 0, base + 1 != rtsp.port, let next = bindLoopback(base + 1) {
      held.append(candidate.fd)
      held.append(next.fd)
      return (rtsp.port, base, base + 1)
    }
    close(candidate.fd)
  }
  return nil
}

/// Whether a TCP connection to 127.0.0.1:`port` succeeds right now.
private func canConnectLoopback(_ port: UInt16) -> Bool {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  addr.sin_addr.s_addr = inet_addr("127.0.0.1")
  let r = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  return r == 0
}

// MARK: - Fixture

/// Owns a MediaMTX server + ffmpeg publisher for the lifetime of one test, and
/// guarantees both are killed on teardown.
final class LiveStreamFixture {
  let rtspURL: String

  private let rtspPort: UInt16
  private let configPath: String
  private let logPath: String
  private let marker: String
  private let mediamtx = Process()
  private let ffmpeg = Process()
  private var launched: [Process] = []

  /// - Parameters:
  ///   - transports: value for MediaMTX `rtspTransports` (e.g. `[tcp]`).
  ///   - ffmpegArgs: ffmpeg args between the program name and the output URL
  ///     (inputs + codec options); the `-f rtsp ... <url>` tail is appended.
  init(transports: [String] = ["tcp", "udp"], ffmpegArgs: [String]) throws {
    let token = UUID().uuidString.prefix(8)
    self.marker = "ipcamkit-live-\(token)"
    guard let ports = reserveServerPorts() else {
      throw LiveError("could not reserve RTSP + RTP/RTCP server ports")
    }
    self.rtspPort = ports.rtsp
    let rtpPort = ports.rtp
    let rtcpPort = ports.rtcp
    self.configPath = NSTemporaryDirectory() + "\(marker).yml"
    self.logPath = NSTemporaryDirectory() + "\(marker).log"
    self.rtspURL = "rtsp://127.0.0.1:\(rtspPort)/\(marker)"

    let config = """
      logLevel: error
      api: false
      metrics: false
      pprof: false
      playback: false
      rtmp: false
      hls: false
      webrtc: false
      srt: false
      rtsp: true
      rtspTransports: [\(transports.joined(separator: ", "))]
      rtspAddress: :\(rtspPort)
      rtpAddress: :\(rtpPort)
      rtcpAddress: :\(rtcpPort)
      paths:
        all_others:
      """
    try config.write(toFile: configPath, atomically: true, encoding: .utf8)

    let env = Self.childEnvironment()

    // Capture mediamtx output to a file (not a pipe — pipes can deadlock) so a
    // startup failure can be surfaced in the test error.
    FileManager.default.createFile(atPath: logPath, contents: nil)
    let logHandle = FileHandle(forWritingAtPath: logPath)

    mediamtx.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    mediamtx.arguments = ["mediamtx", configPath]
    mediamtx.standardOutput = logHandle ?? FileHandle.nullDevice
    mediamtx.standardError = logHandle ?? FileHandle.nullDevice
    mediamtx.environment = env

    ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ffmpeg.arguments =
      ["ffmpeg", "-hide_banner", "-loglevel", "error"]
      + ffmpegArgs
      + ["-f", "rtsp", "-rtsp_transport", "tcp", rtspURL]
    ffmpeg.standardOutput = FileHandle.nullDevice
    ffmpeg.standardError = FileHandle.nullDevice
    ffmpeg.environment = env
  }

  /// PATH that includes the usual Homebrew + system locations so `/usr/bin/env`
  /// resolves `mediamtx`/`ffmpeg` regardless of how the test runner was invoked.
  private static func childEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    env["PATH"] = env["PATH"].map { "\(extra):\($0)" } ?? extra
    return env
  }

  /// Launch MediaMTX, wait for its RTSP port, then launch the ffmpeg publisher.
  func start() async throws {
    try mediamtx.run()
    launched.append(mediamtx)

    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if canConnectLoopback(rtspPort) { break }
      try await Task.sleep(for: .milliseconds(150))
    }
    guard canConnectLoopback(rtspPort) else {
      let log = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "<no log>"
      throw LiveError(
        "mediamtx RTSP port \(rtspPort) did not open within 10s. mediamtx log:\n\(log)")
    }

    try ffmpeg.run()
    launched.append(ffmpeg)
  }

  /// Terminate both processes (SIGTERM, then SIGKILL backstop) and remove the
  /// temp config. Safe to call more than once.
  func shutDown() {
    for p in launched where p.isRunning { p.terminate() }

    // SIGKILL backstop for any straggler matching our unique marker (the config
    // path for mediamtx, the stream URL for ffmpeg).
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    pkill.arguments = ["pkill", "-9", "-f", marker]
    pkill.standardOutput = FileHandle.nullDevice
    pkill.standardError = FileHandle.nullDevice
    pkill.environment = Self.childEnvironment()
    try? pkill.run()
    pkill.waitUntilExit()

    for p in launched { p.waitUntilExit() }
    launched.removeAll()
    try? FileManager.default.removeItem(atPath: configPath)
    try? FileManager.default.removeItem(atPath: logPath)
  }
}

// MARK: - Frame collection

private actor ItemSink {
  private(set) var items: [PublicCodecItem] = []
  private(set) var finished = false
  private(set) var failure: Error?
  func add(_ item: PublicCodecItem) { items.append(item) }
  func finish(_ error: Error?) {
    finished = true
    failure = error
  }
}

/// Consume `session.frames()` until `until` is satisfied, the stream ends, or
/// `deadline` elapses — never an unbounded await. Returns everything collected.
@discardableResult
private func collectItems(
  from session: RTSPClientSession,
  deadline: Duration,
  until: @escaping @Sendable ([PublicCodecItem]) -> Bool
) async -> [PublicCodecItem] {
  let sink = ItemSink()
  let consumer = Task {
    do {
      for try await item in session.frames() {
        await sink.add(item)
        if until(await sink.items) { break }
      }
      await sink.finish(nil)
    } catch {
      await sink.finish(error)
    }
  }

  let endBy = ContinuousClock.now + deadline
  while ContinuousClock.now < endBy {
    let snapshot = await sink.items
    let isFinished = await sink.finished
    if until(snapshot) || isFinished { break }
    try? await Task.sleep(for: .milliseconds(120))
  }
  consumer.cancel()
  return await sink.items
}

/// Create a fresh session and retry `start()` until it succeeds or `deadline`
/// elapses. A fresh session per attempt avoids carrying partial state across the
/// 404s MediaMTX returns until the publisher's stream is ready.
private func startSessionWithRetry(
  url: String,
  transport: Transport,
  deadline: Duration
) async throws -> (RTSPClientSession, SessionDescription) {
  let endBy = ContinuousClock.now + deadline
  var lastError: Error?
  while ContinuousClock.now < endBy {
    let session = RTSPClientSession(url: url, transport: transport)
    do {
      let desc = try await session.start()
      return (session, desc)
    } catch {
      lastError = error
      await session.stop()
      try? await Task.sleep(for: .milliseconds(400))
    }
  }
  throw lastError ?? LiveError("RTSPClientSession.start() did not succeed in time")
}

private func videoFrames(_ items: [PublicCodecItem]) -> [PublicVideoFrame] {
  items.compactMap { if case .video(let f) = $0 { return f } else { return nil } }
}

private func audioFrames(_ items: [PublicCodecItem]) -> [PublicAudioFrame] {
  items.compactMap { if case .audio(let f) = $0 { return f } else { return nil } }
}

/// A detached backstop that SIGKILLs any live test server/publisher after `cap`.
/// This bounds the *whole* test even if an await inside the library is itself
/// unbounded (e.g. an RTSP read with no timeout while the server stalls):
/// killing the server drops the TCP connection, which unblocks the pending
/// read. Cancel it (via `defer`) on normal completion. The pkill matches the
/// shared `ipcamkit-live` marker; the suite is serialized, so only the current
/// test's processes exist.
private func liveWatchdog(_ cap: Duration) -> Task<Void, Never> {
  Task.detached {
    try? await Task.sleep(for: cap)
    guard !Task.isCancelled else { return }
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    pkill.arguments = ["pkill", "-9", "-f", "ipcamkit-live"]
    pkill.standardOutput = FileHandle.nullDevice
    pkill.standardError = FileHandle.nullDevice
    try? pkill.run()
    pkill.waitUntilExit()
  }
}

// MARK: - Tests

@Suite("Live Integration Tests", .serialized)
struct LiveIntegrationTests {

  @Test("H.264 over interleaved TCP yields a keyframe with in-band SPS/PPS")
  func h264OverTCP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    let fixture = try LiveStreamFixture(ffmpegArgs: [
      "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
      "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
      "-g", "15", "-pix_fmt", "yuv420p", "-an",
    ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(
      url: fixture.rtspURL, transport: .tcp, deadline: .seconds(20))
    #expect(desc.video?.codec == .h264)

    // Teardown is via fixture.shutDown() (defer), which kills the server and
    // drops the connection, ending the frames() producer. We deliberately do
    // NOT call session.stop() here: a graceful TEARDOWN issued while the
    // streamFrames loop is still reading the shared connection blocks until the
    // server's session timeout (~60s), because the producer consumes the
    // TEARDOWN response before stop()'s own read sees it.
    let items = await collectItems(from: session, deadline: .seconds(12)) {
      let vf = videoFrames($0)
      return vf.count >= 3 && vf.contains { $0.isKeyframe }
    }

    let vf = videoFrames(items)
    #expect(!vf.isEmpty, "expected at least one video frame")
    #expect(vf.contains { $0.isKeyframe }, "expected a keyframe (IDR)")
    // SPS/PPS are surfaced either via the SDP (sprop-parameter-sets) or in-band
    // on a frame, depending on how the server advertises them.
    let spsAvailable = desc.video?.sps != nil || vf.contains { $0.sps != nil }
    let ppsAvailable = desc.video?.pps != nil || vf.contains { $0.pps != nil }
    #expect(spsAvailable, "expected SPS via SDP or in-band")
    #expect(ppsAvailable, "expected PPS via SDP or in-band")
    #expect(vf.allSatisfy { !$0.nalus.isEmpty }, "every frame should carry NAL units")
  }

  @Test("H.265 over interleaved TCP yields a keyframe with in-band VPS/SPS/PPS")
  func h265OverTCP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    // `no-open-gop=1` forces closed-GOP IDR keyframes (libx265 defaults to
    // open-GOP CRA, which — like retina — is not treated as a random-access
    // point). `repeat-headers=1` re-sends VPS/SPS/PPS in-band before each IDR.
    let fixture = try LiveStreamFixture(ffmpegArgs: [
      "-re", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
      "-c:v", "libx265", "-tag:v", "hvc1", "-preset", "ultrafast",
      "-x265-params", "keyint=15:min-keyint=15:no-open-gop=1:repeat-headers=1",
      "-pix_fmt", "yuv420p", "-an",
    ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(
      url: fixture.rtspURL, transport: .tcp, deadline: .seconds(20))
    #expect(desc.video?.codec == .h265)

    let items = await collectItems(from: session, deadline: .seconds(12)) {
      let vf = videoFrames($0)
      return vf.count >= 3 && vf.contains { $0.isKeyframe }
    }

    let vf = videoFrames(items)
    #expect(!vf.isEmpty, "expected at least one video frame")
    #expect(vf.contains { $0.isKeyframe }, "expected a keyframe (IDR)")
    // VPS/SPS/PPS arrive either via the SDP or in-band on a keyframe.
    let vpsAvailable = desc.video?.vps != nil || vf.contains { $0.vps != nil }
    let spsAvailable = desc.video?.sps != nil || vf.contains { $0.sps != nil }
    let ppsAvailable = desc.video?.pps != nil || vf.contains { $0.pps != nil }
    #expect(vpsAvailable, "expected VPS via SDP or in-band")
    #expect(spsAvailable, "expected SPS via SDP or in-band")
    #expect(ppsAvailable, "expected PPS via SDP or in-band")
  }

  @Test("H.264 + AAC over interleaved TCP yields video and 48 kHz audio")
  func h264AacOverTCP() async throws {
    let watchdog = liveWatchdog(.seconds(45))
    defer { watchdog.cancel() }
    let fixture = try LiveStreamFixture(ffmpegArgs: [
      "-re",
      "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=15",
      "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
      "-map", "0:v", "-map", "1:a",
      "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
      "-g", "15", "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-ar", "48000",
    ])
    defer { fixture.shutDown() }
    try await fixture.start()

    let (session, desc) = try await startSessionWithRetry(
      url: fixture.rtspURL, transport: .tcp, deadline: .seconds(20))
    #expect(desc.video?.codec == .h264)
    #expect(desc.audio != nil, "expected an audio stream in the SDP")
    #expect(desc.audio?.sampleRate == 48000)

    let items = await collectItems(from: session, deadline: .seconds(12)) {
      !videoFrames($0).isEmpty && audioFrames($0).count >= 2
    }

    #expect(!videoFrames(items).isEmpty, "expected video frames")
    let af = audioFrames(items)
    #expect(!af.isEmpty, "expected audio frames")
    #expect(af.allSatisfy { $0.sampleRate == 48000 }, "audio sample rate should be 48 kHz")
  }
}
