# Upstream sync: scottlamb/retina

IPCamKit began as a Swift port of the Rust crate
[`retina`](https://github.com/scottlamb/retina). Most files carry
`// Port of retina src/...` comments with upstream line references.

This file records the last upstream commit we have reconciled against, so a
future sync only has to look at what landed in retina *after* this anchor.

## Status

- **Fork point:** retina ~late February 2026 (IPCamKit's initial commit is
  2026-02-28).
- **Upstream HEAD at last review:** `6972ac4261ce7bf5b585da9051606c7b5c0ab82c`
  ("accept scheme-less `Content-Base` header", 2026-03-30).
- **Last reconciled commit (anchor):** _in progress_ — see the porting checklist
  below. Update this to `6972ac4` once the checklist is cleared.
- **Reviewed on:** 2026-05-30

> IPCamKit has *diverged on purpose*: it is hardened against malformed/hostile
> camera input (overflow-trap guards, bounded parser loops, best-effort
> audio/metadata) and fixes several port bugs. When pulling upstream changes,
> re-apply those hardening patterns rather than reverting to retina's
> debug-panic / `assert!` style.

## Post-fork upstream commits to evaluate (fork → 6972ac4)

Relevant (behavioral) — port these:

- [ ] `ff771fe` (2026-03-13) — **H.264: ignore the RTP MARK bit on SEI packets**
      (some cameras set MARK on a trailing SEI, splitting the access unit early).
- [ ] `8ff7a0f` (2026-03-28) — **tolerate a complete (un-fragmented) NAL that
      arrives inside an FU wrapper** ("struggle on" instead of erroring).
- [ ] `6972ac4` (2026-03-30) — **accept a scheme-less `Content-Base` header**
      (resolve it against the request URL instead of rejecting).
- [ ] `6339bd6` (2026-02-27) — strip in-band H.26x parameter sets (feature;
      verify whether already present in the fork).

Likely no-op for us (API exposure / examples / Rust-only infra) — confirm, skip:

- `58f0042` FrameFormat, `93f5917` VideoParameters from SPS/PPS, `8ecbeab`
  expose audio channels, `0799d0e` coded width/height, `6a4568b` receive
  timestamps — check our public surface already covers these.
- `b6a18c4` own RTSP/1.0 parser, `f2bcec3` derive_more, `7073bb5`/`c92ff24`
  fuzz crate, `09c6175` license headers, `80abcd6` build-without-h265,
  `44042ba` flaky test, examples/docs/clippy — Rust-specific, not applicable.

## How to sync next time

```sh
git clone https://github.com/scottlamb/retina /tmp/retina
cd /tmp/retina
git log --oneline <anchor>..HEAD
git diff <anchor>..HEAD -- src/rtp.rs src/rtcp.rs src/client/ src/codec/
```

For each relevant change, port it into the matching `Sources/IPCamKit/...`
file, keep the `// Port of retina ...` line references accurate, and update the
**Last reconciled commit** above to the new anchor.
