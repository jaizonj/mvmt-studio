# mvmt-whisper

MVMT Studio's on-device lyrics detection engine (iOS only).

- **Engine**: whisper.cpp **v1.9.5** (ggml v0.26.0), consumed as the
  official ggml-org XCFramework build `b5454`, vendored trimmed at
  `ios/whisper.xcframework` (device + simulator slices). Swift wraps
  the C API directly (`import whisper`).
- **Model**: Whisper **small**, multilingual — `ggml-small.bin`
  (487,601,967 bytes), downloaded once on first use into
  `Application Support/MvmtWhisper/`; never bundled with the app.
- **Word timing**: DTW token timestamps (`WHISPER_AHEADS_SMALL`),
  t0/t1 fallback — the timing source for karaoke lyric animations.
- **Detection only.** No lyrics lookup, no network calls besides the
  one-time model download.

Why whisper.cpp and not WhisperKit is recorded in
[INTEGRATION.md](INTEGRATION.md) (short version: WhisperKit has no
CocoaPods distribution and Expo SDK 58 local modules integrate through
podspecs, so it cannot be consumed by this project's build).

App code should import from `src/lib/whisper.ts`, not from this
module directly — the wrapper owns the UI-facing contract
(`WhisperSegment[]`, sync `modelState()`, `WhisperUnavailableError`).
