# Changelog

## Upcoming

### Breaking changes

- `SessionDescription` now groups video and audio fields into `VideoStream?` and `AudioStream?` substructs. Replaces the flat `videoCodec` / `sps` / `pps` / `clockRate` / `audioCodec` / `audioSampleRate` / `audioChannels` / `audioExtraData` fields. A session is valid as long as any one of video, audio, or analytics metadata is set up — audio-only and metadata-only RTSP configurations (e.g. Axis cameras with `video=0`) now work end-to-end. Consumers branch on `desc.video != nil` (or `desc.audio != nil`) before configuring their decoders.

### New

- ONVIF analytics metadata stream support (`vnd.onvif.metadata` per the ONVIF Streaming Specification). Surfaced as `PublicCodecItem.metadata(PublicMetadataFrame)` in the `session.frames()` stream, with discoverability via `SessionDescription.metadataEncoding`. Best-effort: malformed metadata SDP or a failed application SETUP degrades to a diagnostic without aborting video/audio.
- Real UDP transport for RTP/RTCP. Selecting `Transport.udp` now streams end-to-end over a bound BSD socket pair (RTP and RTCP on adjacent ports), replacing the earlier non-functional scaffolding.
- Automatic RTSP session keepalive while streaming: sends `GET_PARAMETER` when the server advertises support, otherwise `OPTIONS`, at roughly half the negotiated session timeout, so long-running sessions aren't dropped by the camera. Each round-trip is reported via `onDiagnostic` at `.info` severity.

### Improvements

- Add visionOS 1.0 to supported platforms
- Add a connect timeout to the RTSP TCP transport so an unreachable or dead camera fails fast instead of hanging.
- Live integration test suite: drives `RTSPClientSession` end-to-end against an `ffmpeg`-published stream relayed by `mediamtx`, exercising H.264/H.265/AAC over both RTSP-interleaved TCP and UDP. CI installs `ffmpeg` and `mediamtx`.

### Fixes

- Audio depacketizer init failures now null out the audio stream state (index, encoding name, clock rate, channels), mirroring the metadata-init failure path. Previously the indices stayed set while the depacketizer was nil; packets on that channel were silently dropped by the dispatch loop but `SessionDescription` could still claim the stream existed. Required to keep the "at least one usable stream" guard honest in audio-only sessions.
- Strengthen RTSP Digest authentication.
- Harden the H.265 depacketizer and parameter-set parsing against malformed input.
- Fix and harden H.264 SPS parsing.
- Harden RTP packet and context handling, and saturate loss counters to avoid overflow traps.
- Harden the RTSP parsers against malformed server input, and harden the session start path.
- Fix the static L16 payload clock rate to 44100 Hz.
- Ignore the RTP MARK bit on H.264 SEI packets (some cameras set it on a trailing SEI, splitting the access unit early).
- Tolerate a complete (un-fragmented) NAL that arrives inside an FU wrapper instead of erroring.
- Accept a scheme-less `Content-Base` header by resolving it against the request URL.
- Normalize audio frame data to a standalone `Data`.

## 0.2.0

### Breaking changes

- Remove `SessionIdPolicy` enum and the `sessionIdPolicy:` parameter from `RTSPClientSession.init`. Audio SETUP responses that return a different session ID are now always accepted (latest wins) instead of being a configurable choice.

### New

- `onDiagnostic` callback on `RTSPClientSession.init` for observing non-fatal anomalies (e.g. cameras deviating from spec). Emits `RTSPDiagnostic` values with `info` / `warning` / `error` severity. Initial events:
  - `warning` when a camera issues a different Session ID at audio SETUP than at video SETUP.
  - `warning` when an empty video RTP payload is received and skipped.
  - `warning` when an out-of-order RTP packet is received on TCP-interleaved transport (and dropped).

### Improvements

- Add iOS 16, tvOS 16, and macCatalyst 16 to supported platforms (Thanks @brientim)
- Lower macOS minimum from 14 to 13

### Fixes

- Stop tearing down the video stream when a camera emits an empty (or, for H.265, sub-2-byte) RTP payload. Such packets are now skipped — matches GStreamer / Live555 behavior.
- Stop tearing down the session when an out-of-order RTP packet arrives on TCP-interleaved transport. Packet is now dropped to match UDP behavior, matching FFmpeg / GStreamer / Live555 / ExoPlayer (none of which abort on this case). TCP byte-stream ordering does not imply RTP-sequence ordering — buggy camera packetizers can write packets out-of-order before muxing.

## 0.1.1

### Improvements

- Use `memchr` for zero-byte scanning in H.264 depacketizer for better performance

## 0.1.0

Initial release.

### Features

- **RTSP session management** — full DESCRIBE, SETUP, PLAY, TEARDOWN lifecycle via `RTSPClientSession`
- **RTSP message parsing and serialization** — request/response framing, interleaved data, header handling
- **SDP parsing** — media descriptions, codec parameter extraction, control URL resolution
- **RTP/RTCP** — packet parsing (RFC 3550), 32-bit timestamp wraparound, sequence tracking, loss detection, TCP interleaved channel mapping
- **H.264 depacketization** (RFC 6184) — Single NAL, FU-A, STAP-A, Annex B processing
- **H.265/HEVC depacketization** (RFC 7798) — Single NAL, AP, FU (SRST mode), full SPS/PPS/VPS parsing, HEVCDecoderConfigurationRecord
- **AAC depacketization** (RFC 3640) — AAC-hbr mode, aggregation, fragmentation, AudioSpecificConfig parsing
- **Simple audio** — PCMU, PCMA, L16, G.722, G.726, DVI4 pass-through
- **G.723.1 depacketization** — frame size validation (24/20/4 bytes)
- **Authentication** — Basic and Digest (MD5) via CryptoKit
- **Transport** — TCP interleaved and UDP via NWConnection
- **Output format** — AVCC (4-byte length-prefixed NAL units) ready for VideoToolbox
- **Camera quirk handling** — Reolink, Dahua, Hikvision, Longse, GW Security, VStarcam, Tenda, Foscam, and others
- **CameraViewer example app** — live video display with audio playback, ONVIF stream discovery
- **90 tests** across 15 suites ported from the upstream Rust test suite
