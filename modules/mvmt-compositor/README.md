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

---

## v2 — Overhaul spec (Phase 1 contract, 2026-11-08)

The TS contract for everything below already exists in `src/index.ts`.
The Swift implementation must match it exactly. One internal builder —
`buildComposition(request) -> (composition, videoComposition, audioMix)` —
is shared by export AND preview. Nothing else in the app builds
compositions.

### Shared builder requirements
- **Project canvas**: request `canvasWidth/canvasHeight` (default
  1080×1920). EVERY segment is normalised into the canvas: apply the
  source track's `preferredTransform`, compute its display size, then
  scale ASPECT-FILL (max scale factor, never stretch) and centre.
  Compose the final per-segment layer transform from those steps —
  the v1 behaviour (raw preferredTransform, first-clip canvas) is gone.
- **Frame rate**: `videoComposition.frameDuration = 1/request.frameRate`
  (default 30).
- **Validation/clamping**: clamp every clip's range to its asset's real
  duration (load `.duration` / track timeRange). If a clip's clamped
  range is empty, throw an error naming the clip index. Never insert a
  range past the end of a source track.
- **Master audio**: inserted exactly once, from `audioStartSeconds`,
  clamped to the total video duration and to what remains of the file.
- **Clip audio**: only for clips with `muted == false && volume > 0`
  (the app mutes takes by default — song-only is the product default).

### renderVideo (export)
- Uses the shared builder + `AVAssetExportSession` (highest quality
  preset compatible with the videoComposition; keep `.mp4` output).
- **Progress + cancellation**: when the request carries `exportId`,
  register the session so `cancelExport(exportId)` can cancel it, and
  emit `onExportProgress { exportId, progress }` events (poll
  `exporter.progress` on a timer while exporting; always emit a final
  1.0 or the terminal error path cleans up without it).
- **Measured result**: after export completes, load the WRITTEN file
  and return its measured duration and display size. Never return the
  requested duration.

### inspectAsset(uri)
Return `{ durationSeconds, width, height, frameRate, hasVideo, hasAudio }`
— duration from the asset, display size = naturalSize with
preferredTransform applied, frameRate = nominalFrameRate of the first
video track.

### Native preview
- `createPreview(request) -> previewId`: build the composition with the
  shared builder, create an `AVPlayer` + `AVPlayerItem` (with the
  videoComposition and audioMix applied), store it in a registry keyed
  by a generated id. Emit `onPreviewStatus { previewId, status }`
  transitions (loading → ready; playing/paused from rate/KVO;
  ended at item end; error with message).
- `setPreviewPaused(previewId, paused)`, `seekPreview(previewId, seconds)`
  (tolerance 0 seek — cut-accurate), `releasePreview(previewId)`
  (pause, remove observers, drop from registry).
- Position: a periodic time observer (0.25s) emitting
  `onPreviewProgress { previewId, positionSeconds, durationSeconds, playing }`.
  INFORMATIONAL ONLY — playback never depends on JS.
- View: register an Expo view named `MvmtPreviewView` with a single
  prop `previewId: String`; it renders the registered player's
  `AVPlayerLayer` (resize/gravity = aspect fill) and re-attaches when
  the prop changes. Layer must size to the view's bounds.
- Module definition must declare `Events("onExportProgress",
  "onPreviewProgress", "onPreviewStatus")` and the view.

### Errors
All failures throw `NSError` in the `MvmtCompositor` domain with a
human-readable message naming the failing clip/step. No force-unwraps
on asset data.
