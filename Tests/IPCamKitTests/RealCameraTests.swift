// Copyright (c) 2026 Steel Brain
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import IPCamKit

@Suite("Real Camera Tests")
struct RealCameraTests {
  @Test("Start and receive frames from an env-configured camera", .timeLimit(.minutes(1)))
  func envConfiguredCamera() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let url = env["IPCAMKIT_RTSP_URL"], !url.isEmpty else {
      return
    }

    let credentials: Credentials?
    if let username = env["IPCAMKIT_RTSP_USERNAME"],
      let password = env["IPCAMKIT_RTSP_PASSWORD"]
    {
      credentials = Credentials(username: username, password: password)
    } else {
      credentials = nil
    }

    let session = RTSPClientSession(
      url: url,
      credentials: credentials,
      transport: env["IPCAMKIT_RTSP_TRANSPORT"] == "udp" ? .udp : .tcp,
      onDiagnostic: { diagnostic in
        print("diagnostic[\(diagnostic.severity)]: \(diagnostic.message)")
      })
    defer {
      Task { await session.stop() }
    }

    let desc = try await session.start()
    #expect(desc.video != nil || desc.audio != nil || desc.metadataEncoding != nil)

    var videoFrames = 0
    var audioFrames = 0
    for try await item in session.frames() {
      switch item {
      case .video:
        videoFrames += 1
      case .audio:
        audioFrames += 1
      case .metadata, .rtcp:
        break
      }
      if videoFrames + audioFrames >= 3 {
        await session.stop()
        break
      }
    }

    #expect(videoFrames + audioFrames > 0)
  }
}
