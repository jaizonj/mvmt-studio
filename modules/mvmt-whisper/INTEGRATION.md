# mvmt-whisper — integration decision record

**Decision (2026-11-10): whisper.cpp, via the official ggml-org XCFramework
vendored into this module, wrapped through the C API. NOT WhisperKit.**

Detection only — this module transcribes the song file on-device. There is
no lyrics lookup anywhere in the design.

## Why not WhisperKit

Checked in this order, with evidence:

1. **CocoaPods trunk has no WhisperKit pod.**
   `GET https://trunk.cocoapods.org/api/v1/pods/WhisperKit` →
   `{"error":"No pod found with the specified name."}`
   So `s.dependency 'WhisperKit'` in a module podspec cannot resolve.
2. **WhisperKit ships no podspec at all.** The `argmaxinc/WhisperKit`
   repo root contains `Package.swift` (+ `Package@swift-6.2.swift`) and
   no `*.podspec`; distribution is SPM-only (targets `WhisperKit`,
   `ArgmaxCore`, …).
3. **Expo SDK 58 local modules have no SPM-dependency mechanism.**
   The `expo-module.config.json` reference (docs.expo.dev/modules/module-config/)
   lists only `platforms`, `apple.modules`, `apple.appDelegateSubscribers`
   and `android.modules` — no SPM field. iOS autolinking in the installed
   `expo-modules-autolinking` (SDK ~58.0.23) resolves every module to a
   **podspec** integrated through CocoaPods; this project's CI builds with
   `npx expo prebuild --platform ios` + CocoaPods + an `.xcworkspace`.
   The `spm.config.json` files inside `expo-modules-core` are Expo's own
   *precompiled-module publishing* machinery, not a way for a local
   module to declare a third-party SPM dependency. The known workaround —
   a config plugin adding the SPM package to the **app** target — does
   not make `import WhisperKit` compile inside a separate pod target,
   which is where this module's code lives. React Native's project-wide
   SPM mode (RFC 0994) is a different pipeline from this repo's
   prebuild + pods build and was not adopted for one feature.

## The whisper.cpp route

- **Artifact**: `whisper-b5454-xcframework.zip` (65,816,082 bytes) from
  the official `ggml-org/whisper.cpp` release **`b5454`** — the CI build
  matching whisper.cpp **v1.9.5** (ggml v0.26.0):
  https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip
- **Vendored form**: `ios/whisper.xcframework`, trimmed to the two slices
  this app can use — `ios-arm64` (device; the CI archive target) and
  `ios-arm64_x86_64-simulator` — with dSYMs and the macOS/tvOS/visionOS
  slices dropped (23 MB on disk instead of ~150 MB). The
  `whisper.framework` inside each slice is a **dynamic** framework with a
  proper Clang module map (`framework module whisper`, links `c++`,
  Accelerate, Metal, Foundation), so Swift consumes it with
  `import whisper` and the podspec just declares
  `s.vendored_frameworks = 'whisper.xcframework'`.
- **Metal**: the device binary contains a `__ggml_metallib` section —
  the ggml Metal library is embedded, so `use_gpu = true` needs no
  separate `.metallib` resource. The engine still falls back to CPU if
  GPU context creation ever fails (see `WhisperEngine`).
- **Word timing**: the vendored `whisper.h` (b5454) exposes DTW token
  timestamps — `whisper_context_params.dtw_token_timestamps` +
  `dtw_aheads_preset = WHISPER_AHEADS_SMALL` at context creation, and
  `whisper_token_data.t_dtw` per token (with `t0`/`t1` as fallback).
  DTW is the accurate path and is what powers the karaoke animations.
  Timestamps are int64 in 10 ms units, relative to the start of the
  decoded audio = song-absolute seconds once divided by 100.
- **Audio decode**: whisper.cpp needs 16 kHz mono float PCM.
  `WhisperEngine` decodes with `AVAssetReader` (the compositor module's
  avTry exception-guard pattern is duplicated here — pods cannot share
  it) and hands the samples to `whisper_full`.

## The model

- **Whisper small, multilingual** (`ggml-small.bin`), downloaded once on
  first use into
  `Application Support/MvmtWhisper/ggml-small.bin` (directory excluded
  from iCloud backup — the model is re-downloadable).
- URL: https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
- Size: **487,601,967 bytes** (≈ 488 MB). Readiness = the file exists at
  exactly this size (cheap, and a truncated download can never pass).
- SHA-256 (HF LFS oid, recorded for future verification work):
  `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`

## What remains CI/device-unverified (written on Linux, no Swift compiler)

1. Swift's Clang importer spelling for the C enums
   (`WHISPER_AHEADS_SMALL`, `WHISPER_SAMPLING_GREEDY` as bare constants)
   — the form used by public Swift wrappers of whisper.cpp. If the
   importer disagrees, the one-line fallback is
   `whisper_alignment_heads_preset(rawValue: 8)` /
   `whisper_sampling_strategy(rawValue: 0)`.
2. CocoaPods' handling of a dynamic vendored XCFramework inside a
   `static_framework` pod under the Expo-generated Podfile (standard
   pattern — e.g. ML Kit pods do this — but this exact combination is
   first exercised by the `build-unsigned-ipa` workflow).
3. Runtime behaviour: DTW aheads for `small` on-device, Metal init from
   the embedded metallib, and transcription speed on the A19 Pro.
