# MvmtCompositor

MVMT Studio's native video compositing engine. It renders a timeline of
trimmed video clips into **one mp4 file** with the master audio track
(the music) laid over it — the real render behind the app's Export step.

**iOS only — deliberately.** MVMT Studio is an iOS-only product, so this
module is built solely on AVFoundation (Swift). There is no Android
implementation and none is planned; `expo-module.config.json` declares
`"platforms": ["apple"]` only.

## What it does

Given a list of clips (source file + start offset + duration + its own
audio settings) and an optional master audio track, the engine:

1. Builds an `AVMutableComposition` with a single video track, inserting
   each clip's trimmed range end-to-end at a running cursor.
2. Uses the **first clip** as the canvas: its natural size and
   `preferredTransform` define the output size, and every clip's own
   `preferredTransform` is applied per segment via an
   `AVMutableVideoComposition` layer instruction, so portrait/landscape
   orientation is honoured per clip.
3. Lays audio:
   - the **master track**, trimmed from `audioStartSeconds` for the
     total video duration, at `audioVolume` (default 1) — via an
     `AVMutableAudioMix`;
   - each clip's **own audio**, at its timeline position, unless the
     clip is `muted` or its `volume` is 0, at the clip's `volume` —
     through the same audio mix.
4. Exports with `AVAssetExportSession`
   (`AVAssetExportPresetHighestQuality`, `.mp4`) to a unique file in the
   app caches directory: `mvmt-export-<uuid>.mp4`.

## API (src/index.ts)

```ts
interface CompositeClipInput {
  uri: string;             // file:// URI or absolute path
  startSeconds: number;    // trim start inside the source clip
  durationSeconds: number; // how much of the clip to use
  muted: boolean;          // true = drop the clip's own audio
  volume: number;          // clip audio volume, 0–1
}

interface CompositeRequest {
  clips: CompositeClipInput[];
  audioUri?: string | null;   // master track (music)
  audioStartSeconds?: number; // default 0
  audioVolume?: number;       // default 1
}

interface CompositeResult {
  uri: string;           // file:// URI of the rendered mp4
  durationSeconds: number;
  width: number;         // display size (rotation applied)
  height: number;
}

function isCompositorAvailable(): boolean;
function renderVideo(request: CompositeRequest): Promise<CompositeResult>;
```

- `isCompositorAvailable()` returns **true only when the native module
  is linked** into the running binary. It uses
  `requireOptionalNativeModule('MvmtCompositor')`, so it never throws.
- `renderVideo()` rejects with a clear `Error` when the native module is
  unavailable, when `clips` is empty, or when the native render fails
  (unreadable source, a clip with no video track, a master file with no
  audio track, export failure).

## Expo Go: it cannot run there

This module is custom native code, and **Expo Go only ships Expo's
bundled native modules** — so in Expo Go `isCompositorAvailable()` is
`false` and `renderVideo()` throws its "needs a development or EAS
build" error. The app is expected to check `isCompositorAvailable()`
and fall back gracefully (per-take save/share) in Expo Go. The engine
activates automatically in a **development build** (`npx expo run:ios`
or `eas build --profile development`) and in release/TestFlight builds.

## How it is picked up

No app.json or package.json changes are needed in the app. Expo
autolinking scans the project's `modules/` directory, finds
`expo-module.config.json`, and links the `MvmtCompositorModule` Swift
module (pod `MvmtCompositor`, depending only on `ExpoModulesCore`).
After adding or changing native files, regenerate the native project /
reinstall pods as usual (`npx expo prebuild`, `npx pod-install`).

## Platform notes & assumptions

- **iOS only** (product decision, 2026-11-08). No Android code exists.
- Built for **Expo SDK 58** / ExpoModulesCore (Record/`@Field`,
  `AsyncFunction`, `requireOptionalNativeModule`) and **iOS 15.5+**
  (the engine uses the modern async AVFoundation APIs:
  `load(.duration)`, `load(.naturalSize)`, `load(.preferredTransform)`,
  `loadTracks(withMediaType:)`).
- All clips are assumed to be local files (camera takes / picked
  audio). Remote URLs are not downloaded.
- The output canvas comes from the first clip; clips with different
  resolutions are not rescaled beyond their `preferredTransform`.
- The rendered file lives in the **caches** directory — iOS may purge
  it under storage pressure, so copy/share it promptly after export.
- No new JS dependencies: `expo` (for `requireOptionalNativeModule`) is
  already in the app; native side depends only on AVFoundation +
  ExpoModulesCore.
