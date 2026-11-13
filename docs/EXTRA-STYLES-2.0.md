# Extra Styles 2.0 — Independent Native Motion-Graphics & Animated Lyric Engine

**Status: Phase 1 — Architecture Audit + Plan (2026-11-13). No app code changed in this phase.**
**Programme doc for the rebuild authorized by Jaizon 2026-11-13 ~01:09 MST (full brief in chat).**
**Update 2026-11-13 ~01:10 MST: build all 40 styles in one continuous run — do NOT stop after the
first 5 for a device test. The five demos are the first five built, not a gate. Load time for the
new lyric/style system is ACCEPTABLE — Jaizon knows it will be intensive.**

## How to read this doc

- §1 is the audit: what exists today, file by file, and what each piece means for the new engine.
  One line per system: **REUSE** (the new engine builds on it) or **BUILD INDEPENDENT** (the new
  engine replaces it with its own implementation).
- §2–§8 are the six layers from the brief, as concrete components with named files, data shapes,
  and responsibilities — not aspirations.
- §9–§16 cover audio reactivity, subject-awareness, assets, the iPhone interface, performance and
  load time, persistence, the v1-template question, and dependencies.
- §17 maps all 40 styles to engine capabilities — the proof the engine covers them.
- §18 is the updated phase plan. §19 lists what this audit could NOT settle. §20 maps the brief's
  acceptance criteria to where each is met.

**Decisions Jaizon still needs to make** (flagged `DECISION` in the text): the v1-template
migration (§15), the animated card-preview budget (§12), and the Metal question (§6, decided by
the Phase 2 prototype, not by opinion).

---

## 1. Audit — what exists today

### 1.1 Summary table

| System | Where it lives | Verdict for 2.0 |
|---|---|---|
| Traditional lyric system (detection, grouping, style, animations) | `src/lib/lyrics.ts`, `src/lib/lyricFonts.ts`, `src/lib/lyricAnimations.ts`, `src/types.ts` (`LyricLine`, `LyricStyle`, `ProjectLyrics`), `modules/mvmt-whisper` | **REUSE** the data (lines/words in song frames, intelligence). **BUILD INDEPENDENT** the rendering: 2.0 never touches `LyricStyle` or the animation params. |
| v1 Extra Styles (30 templates) | `src/lib/lyricTemplates.ts`, `ProjectLyrics.templateId`, `src/components/LyricsOverlay.tsx`, Swift decor builders in `modules/mvmt-compositor/ios/MvmtCompositorModule.swift`, `docs/STYLES-REDESIGN.md`, `docs/STYLES-PARITY.md` | **REUSE** the catalog UX patterns (categories, search, favorites, live preview cards) and the parity-audit discipline. **BUILD INDEPENDENT** the rendering model — templates are `Partial<LyricStyle> + LyricDecor` (a subtitle preset with decor); 2.0 styles are scene definitions. See §15 for the migration proposal. |
| Swift compositor (composition builder) | `modules/mvmt-compositor/ios/MvmtCompositorModule.swift` — `buildComposition` (line 1002), `BuiltComposition`, `LookVideoCompositor` (line 219), `LookCompositorStore` | **REUSE** the builder, the layer-instruction model, the custom-compositor pattern, and the static-slot param pattern. **BUILD INDEPENDENT** a new compositor class for scenes (§6) — do not bolt scenes onto `LookVideoCompositor`. |
| Video preview | `src/components/NativePreview.tsx`, Swift `PreviewStore` + `MvmtPreviewView` (line 6861), `createPreview` | **REUSE** the whole mechanism (one native composition + AVPlayer, rebuild on `requestKey`). **BUILD INDEPENDENT** the overlay: 2.0 scenes render natively inside the preview composition; the JS `LyricsOverlay` stays for traditional lyrics only. |
| Video export | `src/app/project/export.tsx`, Swift `render` (line 4989) → `AVAssetExportSession`, `transcodeVideoFile` (line 5566) → `transcodeAttempt` (line 5624) | **REUSE** the entire flow (same `edlToCompositeRequest`, same tiers, same transcode pump). **BUILD INDEPENDENT** nothing in the flow — the scene rides inside it (§6.4). |
| Audio analysis | `src/lib/analysis.ts`, `src/lib/loudness.ts`, `src/lib/waveform.ts`, `src/lib/mixMasterCurve.ts`, `src/lib/autoEq.ts`, native `prepareEqSong` / `prepareMixMasterSong` / `waveformPeaks` | **REUSE** the band bank, the windowed-analysis pattern, the profile-JSON cache pattern, `waveformPeaks`. **BUILD INDEPENDENT** beat/onset/energy automation — it does not exist (§9). |
| Lyric timing system | `src/lib/lyrics.ts` (`groupWhisperSegments`, `buildCompositeLyrics`, song↔timeline frame mapping), `src/lib/edl.ts` (30fps integer frames) | **REUSE** wholesale: song-absolute frames, the grouper, the mapping. This is the timing foundation 2.0 stands on. |
| Project storage | `src/lib/persistence.ts` (`projects.json`, version 1), `src/store/StudioContext.tsx`, `src/lib/songLibrary.ts` | **REUSE** the file, the versioning discipline, the failure-tolerant loader. **BUILD INDEPENDENT** the new `Project.extraStyle` field + its migration rules (§14). |
| React Native architecture | Expo Router (`src/app/`), `src/store/StudioContext.tsx`, theme (`src/theme.ts`), bridge via `modules/mvmt-compositor/src/index.ts` | **REUSE** the router, the store, the theme, and the bridge conventions (versioned `AsyncFunction`s, availability gate). **BUILD INDEPENDENT** the Extra Styles UI as its own section (§12) and a new bridge surface for scenes (§6.6). |
| Capture (context for subject-awareness) | Native capture coordinator in `MvmtCompositorModule.swift` (`startCapture`/`stopCapture`), `CapturePreview` | **REUSE** nothing directly — takes are plain video files with no depth channel. **BUILD INDEPENDENT** subject masks are computed from the finished files, ahead of time (§10). |

### 1.2 Traditional lyric system — what it is

- **Detection:** Whisper SMALL on-device (`modules/mvmt-whisper`, whisper.cpp vendored XCFramework;
  `src/lib/whisper.ts`). The ~488 MB model downloads on first Detect into app storage. Detection only —
  no lookup. DTW token timestamps give word timings in song-absolute seconds.
- **Grouping:** `groupWhisperSegments` (`src/lib/lyrics.ts`) decides lines from pauses / sentence
  breaks with hard caps (max 7 words, 3.5 s, 36 chars per line), plus a stranded-word rescue pass.
- **Timing:** lines live on the SONG timeline in integer frames at 30 fps (`LyricLine.startFrame /
  endFrame`, `LyricWord.startFrame / endFrame`). The one mapping to composition time is
  `timelineFrame = songFrame − regionStartFrame` (`buildCompositeLyrics`). Shuffle edits can never
  knock lyrics out of sync because the song plays continuously through every cut.
- **Style:** ONE global `LyricStyle` per project (font, sizeRatio, colour, stroke, background,
  position, verticalOffsetRatio, maxWidthRatio, animationId, bold). 50 fonts
  (`src/lib/lyricFonts.ts`) + 50 animation presets (`src/lib/lyricAnimations.ts`) over ONE
  parametric model (`LyricAnimationParams`: enter/exit seconds, from-opacity/scale/offset/rotate,
  wordMode `none | stagger | karaoke | typewriter`, wordStaggerSecs, emphasisScale). The native side
  has no catalog — the composite request carries resolved numbers.
- **Intelligence:** deterministic, computed ONCE at Detect (and re-computed on manual edits), stored
  on the line (`LyricLine.decor`: emoji from a ~70-entry keyword dictionary, tone from word lists
  with priority love > joy > hype > sad > anger, emphasis = ALL-CAPS ≥ 2 letters or repeated words).
  Renderers never analyse. No match = no field; nothing is guessed.
- **Editing:** line editor (seek, edit, nudge, split, merge, delete, add, shift-all), fine-offset
  drag bar (`offsetFrames` ±45 f), song library (name+duration identity, corrected lyrics saved per
  song and re-attached).

**Reuse for 2.0:** the detected lines + word timings + stored intelligence are the lyric DATA the
engine consumes. Nothing about detection, grouping, or the line editor changes. **Independent:**
2.0 never reads `LyricStyle`, never resolves an animation preset, and never renders through the
classic path. A project may carry traditional lyrics AND a 2.0 style; they are separate layers
(traditional lyrics are the subtitle layer; the 2.0 style is the motion-graphics layer — see §2).

### 1.3 v1 Extra Styles — what it is, and why it is not 2.0

- **Model:** a template is `Partial<LyricStyle> + LyricDecor` (`src/lib/lyricTemplates.ts`):
  30 templates, 20 decor kinds (`emoji-row`, `chat-bubble`, `comic-burst`, `sticker-frame`,
  `scanlines`, `glow`, `cursor`, `burst`, `pill`, `rule`, `spray`, `shadow`, `duet`, `ghost-trail`,
  `rain`, `bounce`, `wave-path`, `typing-dots`, `split-screen`, `none`). The template's style is
  MERGED INTO the project's `LyricStyle` on apply (`setLyricTemplate` in
  `src/store/StudioContext.tsx` line 753); the decor rides the same composite payload.
- **Rendering:** TWO implementations of one contract — JS overlay (`src/components/LyricsOverlay.tsx`,
  a pure function of `positionSeconds`, driven by native preview progress events) for preview, and
  Swift CALayer burn-in (`addLyricLayers` / `makeLyricLineLayer` /
  `addLyricDecorBackground` in `MvmtCompositorModule.swift`, attached via
  `AVVideoCompositionCoreAnimationTool` in `makeAnimationTool`, line 1580) for export. The
  Stage 4 parity audit (`docs/STYLES-PARITY.md`, 42 findings, all fixed) proved the two can be kept
  in agreement — and proved how much work that agreement costs: every new decor kind has to be built
  twice and audited line by line (y-up vs y-down, padding, rgba parsing, envelope sampling).
- **UI:** Extra tab in the Lyrics panel (`src/components/LyricsPanel.tsx` line 1152): search,
  category chips, favorites (heart per template, persisted on `ProjectLyrics.favoriteTemplateIds`),
  live-animating preview cards running the real JS overlay on a sample line, Classic card to clear.

**Why this is not 2.0:** a template can only change the lyric line's font, colour, position,
animation, and one decor drawn around that line. It cannot add a second element, a background, a
particle field, a panel, a portal, or a scene — because the model has exactly one visual object
(the line) and one decor kind. Every 2.0 concept in the brief needs multiple independent elements
with their own timelines. Extending `LyricDecor` with more kinds would produce 40 variations of
the same text animation — the exact outcome the brief forbids.

**What carries over:** the catalog UX (categories / search / favorites / live preview cards), the
parity-audit discipline (a contract test that pins the two renderers to the same numbers), the
deterministic-intelligence rule, and the 30 template *concepts* as creative references (several
2.0 styles are deliberate rebuilds of v1 concepts — see §17).

### 1.4 Swift compositor — what it is

`modules/mvmt-compositor/ios/MvmtCompositorModule.swift` (~8,950 lines, Swift 5.9, iOS 15.5 floor,
`ExpoModulesCore` only — no other pods). The module is the app's one media engine, and it already
contains the pattern 2.0 needs most:

- **`buildComposition(_:forExport:includeAnimationTool:includeAudioMix:)` (line 1002)** — the ONE
  builder for preview and export. Lays clips end-to-end on composition video track(s) (a second
  track exists lazily for cross-dissolves), applies `scaleTimeRange` re-timing for clip speed,
  builds the audio mix (master song only by default; take audio muted), installs the Look grade
  (see below), and returns `BuiltComposition` (composition + videoComposition + audioMix + duration
  + `pendingGrade`).
- **`LookVideoCompositor` (line 219) — custom `AVVideoCompositing`.** Per request it reads the
  instruction's layer instructions, pulls each source frame by track ID, composites them in order
  with opacity/transform ramps evaluated at `request.compositionTime`, applies the CI filter-chain
  grade (`gradedImage`, same chain the export transcode uses), and renders via a reused GPU-backed
  `CIContext` (`.useSoftwareRenderer: false`) into the provided pixel buffer. This is a
  **deterministic, frame-addressable, per-request renderer** — the exact shape §6 needs. It runs in
  preview (attached to the player composition) and in the transcode (attached to a
  single-instruction composition over the finished file).
- **Grade homes (the hard-won rule):** an EDL composition is NEVER wrapped in
  `applyingCIFiltersWithHandler` (banned module-wide — it threw `AVCoreImageFilterCustomVideoCompositor`
  on EDL compositions, crash log 2026-11-10-181458). The grade therefore has two homes, both the same
  custom compositor: preview builds attach `LookVideoCompositor` to the plain EDL composition
  (params via the `LookCompositorStore` static slot); export builds leave the composition bare and
  carry the grade out as `BuiltComposition.pendingGrade`, applied in the post-render transcode.
  (As of 2026-11-13 the grade is opt-in only — Auto Enhance auto-apply was removed; no Look
  selected = no grade, identity.)
- **`render` (line 4989):** builds the export composition, runs `AVAssetExportSession`
  (HighestQuality preset) to a caches-directory mp4, then optionally transcodes
  (`transcodeVideoFile`, line 5566 → `transcodeAttempt`, line 5624): AVAssetReader → AVAssetWriter
  pump (back-pressure-correct since the 2026-11-11 fix — an input finishes only at end-of-stream),
  applying the size-control bitrate and/or the pending grade. The transcode's graded pass is a plain
  single-instruction composition whose custom compositor is `LookVideoCompositor` and whose
  animation tool (a repaired master's overlay burn-in) can ride the same composition. Ungraded
  transcodes use NO video composition at all — the file's own frames flow straight to the writer.
- **Lyric/watermark burn-in:** `makeAnimationTool` (line 1580) builds an
  `AVVideoCompositionCoreAnimationTool` (parent layer + video layer + watermark layer + one CALayer
  subtree per lyric line). **Export-only:** a composition carrying the tool throws when assigned to
  a player item, so preview compositions never carry it — this is the structural reason v1 lyrics
  are split JS/Swift, and the structural reason 2.0 must NOT use the animation tool for scenes.
- **Other native surface (bridge `AsyncFunction`s, lines 8796–8916):** `renderVideo`,
  `cancelExport`, `inspectAsset`, `measureTakeSync` (cross-correlation of take mic audio against
  the master song), `waveformPeaks` (AVAssetReader, 8 kHz mono, per-bucket max-abs), `prepareEqSong`,
  `prepareMixMasterSong`, `getMixMasterProfile`, `exportMixMasterAac`, capture
  (`startCapture`/`stopCapture`/`prepareSong`/quality/stabilization/exposure-lock), and preview
  (`createPreview`/`setPreviewPaused`/`seekPreview`/`releasePreview`).
- **Hard rules that survive into 2.0:** AVPlayer `preroll(atRate:)` banned;
  `AVVideoExpectedSourceFrameRateKey` banned; validate-and-throw AVFoundation calls wrapped in
  `avTry`/`MvmtExceptionGuard`; KVO status observations use `[.new, .initial]`; no
  `applyingCIFiltersWithHandler` on EDL compositions; media-services-reset = −11819.
- **Zero Metal. Zero Vision.** `grep` for `MTLDevice`/`MTLCommandQueue` and for `VNRequest` returns
  nothing in the module. Core Image, Core Text (via CATextLayer), Core Animation, and AVFoundation
  are the entire rendering stack today.

### 1.5 Video preview — what it is

- `NativePreview` (`src/components/NativePreview.tsx`): builds ONE native composition via
  `createPreview(request)` and plays it with a single AVPlayer behind `MvmtPreviewView`
  (AVPlayerLayer host, Swift line 6861; `PreviewStore` tracks players by previewId). Rebuilds happen
  only when `requestKey` changes — never for play/pause or seeks. Progress/status events are
  informational (playhead, labels), never drive playback.
- The editor (`src/app/project/editor.tsx` lines 745–800) builds the preview request from the SAME
  `edlToCompositeRequest` the exporter consumes (look + auto volume + EQ'd/MixMaster song URI ride
  the request, so the preview shows exactly what the export ships) — but the native request
  deliberately carries NO lyrics and NO watermark: the preview draws them through JS overlays
  (`LyricsOverlay`, `WatermarkOverlay`), so lyric edits never rebuild the composition mid-edit.
- `LyricsOverlay` is already a **pure function of time**: given the composite lyrics payload and
  `positionSeconds`, it computes which line is active and each word's envelope from the shared
  parametric model (`src/lib/lyricAnimations.ts` header is the renderer spec both sides implement).
  The 2.0 preview keeps the same outer shape (native video + native scene in one composition) but
  moves the scene evaluation native-side — see §6.3.

### 1.6 Video export — what it is

- `src/app/project/export.tsx`: builds the request from the validated EDL
  (`edlToCompositeRequest` + `lyrics: buildCompositeLyrics(...)` + look + `normalizeVolume` +
  EQ/MixMaster song URI), applies the tier (`QUALITY_CANVAS` + `TIER_DEFAULT_VIDEO_BITRATE_BPS`:
  high = project canvas / 60 fps / no transcode; tiktok = 1080×1920 / 60 fps / H.264 ~16 Mbps;
  balanced = 720×1280@30; small = 540×960@30; target sizes via `exportTargetSizeMB` → bitrate
  formula with a corrective pass on >3% overshoot), calls `renderVideo({ ...request, exportId })`,
  reports progress (export session owns the first 80% when a transcode follows), and stamps
  `exportedAt`. Cancel via `cancelExport(exportId)`.
- **2.0 impact on export: none at the flow level.** The scene is a property of the composition
  request (like the look), not a new pipeline. The export screen gains one thing: the scene's
  preparation progress (see §13.2) — the render itself is unchanged.

### 1.7 Audio analysis — what exists, what does not

| Signal | Exists? | Where | Resolution / notes |
|---|---|---|---|
| Waveform peaks (per-bucket max-abs) | Yes | Native `waveformPeaks` → `src/lib/waveform.ts` (`loadTrackPeaks`, 120 buckets, cached per session; deterministic stand-in bars when unavailable) | 120 buckets over the track. Good for UI waveforms; too coarse for beat work. |
| Band levels (10 RBJ bands, 125 Hz–12 kHz) | Yes | Auto EQ (`prepareEqSong`) + Mix & Master (`prepareMixMasterSong`): whole-song levels + per-window gains | Whole-song for Auto EQ; 1.0 s windows / 0.5 s hop for MixMaster, smoothed, stored as `MixMasterProfile` JSON beside the render, keyed by song+settings. |
| Per-window EQ findings | Yes | `MixMasterProfile.findings` (direct cuts ≥ 1 dB, deepest 100) | Usable as a coarse "where is the song harsh/muddy" signal. Not an energy curve. |
| Section energy (RMS while playing) | Yes, sparse | `src/lib/analysis.ts` `SectionEnergyAccumulator` (expo-audio RMS samples during playback/recording) | Only sections actually played get real samples; the rest fall back to the mean. Phrase-aligned at assumed 120 BPM. Not a substitute for decoded analysis. |
| Loudness (integrated LUFS + peak) | Yes | Native measurement in the compositor; decision mirrored in `src/lib/loudness.ts` (`normalizationGainDb`, −14 LUFS target, −1 dBFS peak ceiling) | Whole-song only. No loudness-over-time curve. |
| Take energy (motion proxy) | Yes, heuristic | `src/lib/analysis.ts` `estimateTakeEnergies` (bytes-per-second, normalised) | A proxy, not motion analysis. The shuffle engine is its only consumer. |
| **Beat detection (tempo, beat grid, downbeats)** | **No** | `src/lib/analysis.ts` header states it plainly: phrases are assumed 8 beats at assumed 120 BPM; "TODO(product): replace with real beat / downbeat detection (e.g. an on-device analyser over the decoded track)". | **Must be built (§9).** |
| **Onset envelope / transient detection** | **No** | — | **Must be built (§9).** |
| **Per-band energy over time (fine)** | **No** | MixMaster windows are 1.0 s / 0.5 s hop and EQ-shaped, not energy. | **Must be built (§9)** — finer hop, energy (not gain) per band. |
| **Loudness over time** | **No** | — | **Must be built (§9)** (short-term LUFS curve). |

### 1.8 Lyric timing system — what it is

Covered in §1.2. The facts 2.0 depends on: lines + words in song-absolute frames @30fps; the
song↔timeline mapping is one subtraction; word timings are optional (manual lines may have none);
`offsetFrames` shifts everything at the one boundary. **No verse/chorus sections exist.** **No
speaker/vocal-section information exists** (Whisper does not diarize). **No beat timestamps exist.**
All three are §7/§9 work, and the plan marks which are derivable and which are not.

### 1.9 Project storage — what it is

- One JSON file, `Documents/mvmt/projects.json` (`src/lib/persistence.ts`): `{ version: 1,
  projects: Project[], activeProjectId, songLibrary?: SongLibraryEntry[] }`. Failure-tolerant
  loader (bad file → null, app keeps running in memory). The store (`src/store/StudioContext.tsx`)
  debounces persist writes of the cleaned state.
- `Project` (`src/types.ts`) is plain JSON: track + region, takes (URIs + measured sync data),
  canonical EDL, shuffle state, watermark/lyrics/look/Auto EQ/MixMaster flags, `mixMasterSource`
  (original song when a processed song replaced the track), `exportedAt`. Media files live in the
  sandbox and are referenced by URI — the JSON never embeds media.
- Song library (`src/lib/songLibrary.ts`): keyed by name+duration (1.5 s tolerance); a song's
  corrected lyrics travel with the library entry and re-attach to new projects.
- **Migration discipline today:** additive optional fields with `undefined =` documented defaults;
  the loader rejects only a wrong `version` or a non-array `projects`. No migration functions exist
  yet — nothing has needed one. 2.0 needs the same discipline plus versioned style definitions
  (§14).

### 1.10 React Native architecture — what it is

- Expo SDK 58 / RN 0.88 / TypeScript, Expo Router (`src/app/`; `(tabs)` + `project/` screens),
  `expo-audio` for playback, `expo-video` where needed, `react-native-svg` (added Stage 4, for the
  JS comic starburst), `react-native-reanimated` present but the lyric overlay is plain RN views
  driven by progress events.
- Theme (`src/theme.ts`): deep graphite `#101114`, warm white `#F4F1E9`, acid-lime `#C9F36B`.
- Bridge conventions: the local Expo module exposes `AsyncFunction`s + a native view
  (`MvmtPreviewView`, `MvmtCaptureView`); JS checks `isCompositorAvailable()` / `isCaptureAvailable()`
  before calling anything and degrades honestly in Expo Go; listeners are event-based
  (`onExportProgress`, `onPreviewProgress`, `onPreviewStatus`); long work reports progress and
  supports cancellation by id.
- Tests: Node `node --test` suites (`tests/*.test.cjs`) for the pure-TS modules (shuffle 11, edl 44,
  lyrics 66, looks 15, library 4, mixmaster 46); `npx tsc --noEmit` + `npx expo lint` + `npx expo
  export --platform ios` as the local gate; CI (GitHub Actions, macOS runner, Xcode 26.6) is the
  Swift gate — Swift is never compiled locally.

---

## 2. The independence contract

"Independent" is a structural claim, not a marketing one. It is true when all of these hold:

1. **Separate project field.** A 2.0 style lives in `Project.extraStyle` (§14) — never in
   `ProjectLyrics.style`, never in `templateId`. Traditional lyrics and Extra Styles coexist as two
   layers; either can exist without the other; deleting one never touches the other.
2. **Separate data.** The scene is built from the lyric DATA (lines, words, intelligence) plus the
   style's own parameters — never from `LyricStyle`, never from an animation preset id, never from
   `LyricDecor`. The v1 template system is not a dependency of 2.0; it is a neighbour.
3. **Separate renderer.** One native scene evaluator (§6) renders 2.0 styles in preview AND export.
   The JS `LyricsOverlay` and the Swift CALayer burn-in are the traditional-lyric renderers; they
   do not render 2.0 styles, and 2.0 does not render through them.
4. **Separate UI.** Extra Styles has its own section (§12), not a tab inside the Lyrics panel. The
   Lyrics panel keeps traditional lyrics; the Extra Styles section owns styles, their previews,
   and their per-style controls.
5. **Separate failure domains.** A broken 2.0 scene (bad params, missing asset, failed subject
   mask) degrades to the video WITHOUT the scene — never a failed export, never a crashed preview,
   never lost lyrics. Traditional lyrics keep rendering when a 2.0 style fails, and vice versa.

---

## 3. Layer 1 — Extra Styles Catalog

**Responsibility:** style registration, metadata, categories, discovery, parameter schemas,
versioning. The catalog is the source of truth for "which styles exist and what they are".

### 3.1 Where the catalog lives

The registry is **Swift-native**. Each style is a Swift type conforming to `ExtraStyleDefinition`
(see §3.2), registered by id in `ExtraStyleRegistry`. Rationale: the scene builders are Swift
(they must be — §6), and a registry that lives next to its builders cannot drift from them the
way the v1 `LYRIC_DECOR_KINDS` / `SWIFT_DECOR_KINDS` hand-maintained mirror can (the parity audit
existed to police exactly that drift).

The JS side never holds the catalog. At catalog load (once per app launch, and again only when the
registry version changes) the bridge returns **style metadata only** — id, name, tagline, category,
version, parameter schema (§8), preview descriptor, and whether the style needs audio automation /
subject masks (so the UI can show preparation progress honestly). Metadata is small JSON; it
crosses the bridge once, never per frame.

### 3.2 Style definition (proposed shape)

```swift
protocol ExtraStyleDefinition {
  /// Stable id, e.g. "typography-physics". Never renamed.
  var id: String { get }
  /// Definition version. Bumped when the scene or its params change
  /// incompatibly (see §14).
  var version: Int { get }
  var name: String { get }
  var tagline: String { get }
  var category: ExtraStyleCategory { get }   // §12.1 categories
  /// The style's controls (§8). Declared, not hardcoded in the UI.
  var parameters: [ExtraStyleParameter] { get }
  /// Which lyric data the style consumes (words? lines? phrases?
  /// intelligence? audio automation? subject masks?).
  var inputs: ExtraStyleInputs { get }
  /// Build the scene for one project: lyrics + params + automation
  /// + masks in, a scene graph out. Pure: same inputs → same scene.
  func buildScene(input: ExtraStyleBuildInput) -> ExtraStyleScene
}
```

`ExtraStyleBuildInput` carries: the resolved lyric lines + words (composition-frame times),
the stored intelligence per line, the style's parameter values, the audio automation (if the
style asked for it — §9), the subject masks (if it asked for them — §10), the canvas size, and a
seed (derived from style id + project id — §5.4). `buildScene` runs **ahead of time**, not per
frame: it produces the static scene graph (nodes + animation tracks). Per-frame work is evaluation
only (§5).

### 3.3 Categories (proposed, from the brief's seven groups)

`Cinematic`, `Typography`, `Digital`, `Design`, `Playful`, `Music`, `Experimental` — the brief's
A–G groups, renamed for the picker. A style has exactly one category; search and favorites cut
across categories (§12).

### 3.4 Versioning

Each style carries its own `version` (integer, starts at 1). The project stores `styleId +
styleVersion + params` (§14). When a style's definition changes incompatibly, its version bumps
and the loader runs the style's migration (or falls back to defaults for changed params). The
registry version (the whole catalog) is separate and only matters for the metadata cache.

---

## 4. Layer 2 — Motion Graphics Scene Graph

**Responsibility:** represent everything a style renders, as data. The scene graph is the
contract between the style author (who builds it) and the renderer (which evaluates it).

### 4.1 Node model (proposed Swift shape)

```swift
/// A scene is a flat node list + a root group; nodes reference each
/// other by id for parenting and masking.
struct ExtraStyleScene {
  var root: ExtraStyleNodeID            // a group node
  var nodes: [ExtraStyleNodeID: ExtraStyleNode]
  var canvas: CGSize                    // the EDL canvas (e.g. 1080×1920)
  var durationFrames: Int               // the composition length, @30fps
}

enum ExtraStyleNode {
  case group(ExtraStyleGroup)           // children move together
  case text(ExtraStyleText)             // a line, a word, or a character
  case shape(ExtraStyleShape)           // rect / ellipse / path / star / line
  case image(ExtraStyleImage)           // bundled asset by id (§11)
  case emoji(ExtraStyleEmoji)           // one emoji glyph, sized like text
  case particles(ExtraStyleParticles)   // an emitter, not a sprite list
  case gradient(ExtraStyleGradient)     // linear / radial fill
  case path(ExtraStylePath)             // a stroked path (trails, rules)
  // Masks are not nodes: any node may carry `mask: ExtraStyleMask`
  // (a node id, a subject mask, or a shape) — see §4.3.
}
```

Every node carries the common properties the brief requires:

```swift
struct ExtraStyleNodeProps {
  var position: ExtraStylePosition      // anchor + offset, canvas fractions
  var scale: Double                     // uniform, × base size
  var rotationDeg: Double
  var opacity: Double                   // 0...1
  var anchorPoint: CGPoint              // 0...1, rotation/scale pivot
  var zIndex: Int                       // draw order within the parent
  var blendMode: ExtraStyleBlendMode    // normal, screen, multiply, overlay, lighten, darken
  var mask: ExtraStyleMask?             // node id | subject mask | shape
  var visibleRange: ClosedRange<Int>?   // frames the node exists in (nil = whole scene)
  var animations: [ExtraStyleAnimation] // §5 — attached here, evaluated per frame
}
```

### 4.2 What the graph must do (requirements, not wishes)

- **Nested groups.** A comic panel is a group containing its own text, border, burst, and motion
  lines; the group moves as one. Groups nest arbitrarily; a group's transform composes with its
  children's.
- **Text at four granularities.** A style addresses the line, the word, the character, or the
  phrase — whichever its concept needs. The scene builder splits lines into word/character nodes
  from the lyric data (§7); the renderer never splits text itself.
- **Particles as emitters, not sprites.** A particle node declares an emitter (rate, lifetime,
  velocity, spread, size, texture, seed) and the evaluator expands it deterministically per frame
  (§5.4). No style stores a particle list; no frame allocates a sprite array from scratch — the
  evaluator reuses a fixed-size particle buffer per emitter, capped (see §13.3).
- **Blend modes and masks.** Blend modes map to Core Image blend filters in the CI renderer
  (§6.2); a mask clips the node to another node's alpha, to a subject mask (§10), or to a shape.
- **Static subtrees are cacheable.** Nodes whose props + animations are constant over a frame range
  (backgrounds, frames, static panels) are rasterized once per unique state and reused — the
  evaluator must be able to tell "this subtree did not change since frame N" without re-rendering
  it (§13.3).

### 4.3 What the graph deliberately does NOT contain

- No video nodes in Phase 2/3: the footage is the base layer the scene composites over, not a
  scene element. (A style that wants a "second video" — e.g. Parallel Worlds' mirrored footage —
  gets it from the compositor's layer model, not from the scene graph; see §6.2.)
- No audio nodes: audio automation is data the animations read (§9), not a node.
- No wall-clock state: a scene contains no timers, no "now", no frame counters. Time enters only
  as the frame being evaluated (§5.1).

---

## 5. Layer 3 — Animation Engine

**Responsibility:** turn a scene + a frame number into the exact visual state at that frame.
Deterministic, frame-addressable, no timers.

### 5.1 The evaluation contract

```swift
protocol ExtraStyleSceneEvaluator {
  /// The complete visual state of the scene at one frame.
  /// Pure: same (scene, frame, inputs) → same output, every time.
  /// `frame` is an integer on the 30fps grid; `inputs` carries the
  /// lyric data, audio automation samples, and subject masks for
  /// that frame (all precomputed — the evaluator never decodes,
  /// never analyses, never fetches).
  func evaluate(scene: ExtraStyleScene, frame: Int, inputs: ExtraStyleFrameInputs) -> ExtraStyleFrameState
}
```

- **Frame-addressable:** any frame renders directly. No "play from the start and accumulate
  state" — a requirement the export path depends on (the export session requests frames in order,
  but the transcode pump and seeks must be able to re-render any frame).
- **No wall-clock timers, no display refresh, no playback callbacks.** The evaluator's only clock
  is the frame number it is handed. (The v1 JS overlay already works this way — it is a pure
  function of `positionSeconds`. The 2.0 evaluator is the native equivalent, with the same
  property and a stronger guarantee: it runs inside the compositor, so preview and export call
  the same code.)
- **30fps integer grid:** the EDL's grid. All animation times are integer frames; seconds exist
  only at the boundary (frame / 30). A 15 s cut is 450 frames, 30 s is 900, 60 s is 1800 — the
  brief's examples hold exactly.

### 5.2 Animation behaviours (all required by the brief, all frame-evaluated)

| Behaviour | How it is evaluated (deterministically) |
|---|---|
| Position / scale / rotation / opacity keyframes | Piecewise interpolation between keyframes (frame, value, easing). Easing curves are closed-form functions (cubic-bezier, easeOutCubic, easeInCubic, easeInOut) — the same family the v1 parametric model uses, so the two systems agree on what "ease" means. |
| Colour transitions | Interpolation in a perceptual space (linear-RGB lerp; sRGB lerp is the documented fallback when a style needs the cheaper path — the choice is per-track and recorded in the scene, never implicit). |
| Path animation | A node follows a `CGPath` by arc-length parameterisation: position at progress p is a pure function of p. No integration, no accumulation. |
| Character-by-character / word-by-word | The scene builder assigns each character/word node its own start frame (stagger = base + index × delay, or the word's own sung start from the lyric data). Each node evaluates its own enter envelope from its own start. |
| Spring / elastic motion | **Analytic** spring solutions (damped harmonic oscillator closed form), not numerical integration: position at frame t is a function of (start, target, stiffness, damping, t). Numerical integration with a fixed timestep is the fallback only where a closed form does not exist — and then the timestep is fixed at the frame grid, so it is still deterministic. |
| Physics-inspired movement (gravity, bounce, collision) | Fixed-timestep deterministic integration **from a fixed initial state**: the evaluator integrates from frame 0 to the requested frame with a constant step (1 frame, or a fixed sub-step count per frame) and a fixed seed. Same inputs → same trajectory. Expensive for late frames — mitigate by caching the physics state at coarse checkpoints (e.g. every 30 frames) inside the evaluator's per-render cache, never across renders. Collision between letters is simplified to the style's declared rule (stacking order + restitution), not a general physics engine — a full rigid-body solver is out of scope for Phase 2/3. |
| Staggered animation | Per-node delay, as above. |
| Looping animation | Period + phase: value at frame f = base(f mod period). |
| Particle animation | Emitter expansion (§4.2): particle i's state at frame f is a pure function of (emitter params, i, f, seed) — birth frame, velocity, lifetime, size, opacity curves are all closed-form. No RNG calls during evaluation; all randomness is pre-seeded (§5.4). |
| Transition animation (between lines/phrases) | Exit envelope of the outgoing nodes + enter envelope of the incoming nodes, both keyed to the line boundary frames from the lyric data. |

Animation phases (entrance / continuous / reaction / transformation / exit) are not separate
systems — they are tracks on the same timeline, distinguished by which frames they cover and
which input drives them (line start → entrance; audio onset → reaction; line end → exit).

### 5.3 Reaction inputs

A track may read, at the evaluated frame: the active line/word, the audio automation samples
(§9: onset strength, beat phase, band energies, loudness), and the subject mask state (§10).
Reaction tracks declare their input so the scene builder can verify the input exists (a
Beat Reactor style without beat data is a build error, caught at scene-build time, not a silent
no-op at render time).

### 5.4 Seeded randomness

All random-looking behaviour uses a seeded generator. Seed = a 64-bit hash of
(style id, project id, node id, line id where applicable) — stable across launches, previews, and
exports. The generator is splitmix64 (or xorshift64* — either is fine; the choice is recorded in
the engine, not per style). Consequences: rendering the same frame twice produces the same result;
a style's "random" scatter is identical in preview and export; changing the seed is a deliberate
style parameter ("reshuffle the scatter"), not an accident.

---

## 6. Layer 4 — Rendering Engine

### 6.1 Recommendation (the decision this audit makes)

**Build the 2.0 renderer as a custom `AVVideoCompositing` implementation — `ExtraStylesCompositor`
— on Core Image + Core Text + Core Animation primitives, extending the `LookVideoCompositor`
pattern that already works in this project. Do NOT build it as a Metal renderer first, and do NOT
build it on the `AVVideoCompositionCoreAnimationTool` path.**

Reasons, in order of weight:

1. **It is the only approach with in-project precedent for both homes.** `LookVideoCompositor`
   already renders per-frame, deterministically, at `request.compositionTime`, in preview (attached
   to the player composition) and in export (attached to the transcode's single-instruction
   composition). The 2.0 scene renderer needs exactly those two homes. No new AVFoundation
   integration has to be invented or proven.
2. **It satisfies the brief's non-negotiable (one renderer for preview and export) by
   construction.** Preview and export call the same compositor class, which calls the same scene
   evaluator (§5.1) with the same scene, params, and frame. The v1 split (JS overlay vs Swift
   burn-in) existed because the animation tool cannot ride a preview composition — a custom
   compositor has no such restriction.
3. **It respects the hard-won rules.** A custom compositor is not `applyingCIFiltersWithHandler`,
   so the CI-filter ban does not apply. The grade keeps its two homes; the scene compositor
   subsumes the grade step (§6.3) rather than fighting it.
4. **Core Image + Core Text already cover the Phase 2/3 effect surface.** Text layout and glyph
   rendering (Core Text / CATextLayer), shapes and gradients (Core Graphics / Core Image), glows
   and blurs (CIGaussianBlur, CIGlowEffect-class filters), blend modes (CI blend filters),
   scanlines and masks (CIImage masking) — all exist today in the module or one import away. The
   v1 Swift burn-in already renders text, strokes, pills, starbursts, and scanlines this way.
5. **Metal has zero in-project precedent and the highest unproven-integration risk.** A
   Metal-backed compositor must render into the `CVPixelBuffer` AVFoundation hands it (via a
   `CVMetalTextureCache` or a Metal→CIImage bridge), keep the export session happy at 4K60, and
   survive the transcode pump — none of which has been tried in this codebase. The team has proven
   Core Image compositor experience (three shipped builds) and no proven Metal experience. Metal
   is the right tool for specific nodes (§6.5), not the right foundation to bet Phase 2 on.

**Metal's place:** behind the same `ExtraStyleSceneEvaluator` interface, as an implementation
choice for individual effect nodes — particle fields (thousands of sprites), distortion waves
(custom shaders), liquid/glitch displacement. Phase 2 includes a **Metal prototype spike**
(§6.5): implement the two hardest nodes (particle field, distortion wave) in Metal, measure
against the Core Image implementation on the target device at the export canvas, and adopt Metal
for a node only where profiling shows Core Image cannot hold the frame budget. If Core Image
holds, Metal stays out. This is a measurement decision, not an opinion — see §19.

### 6.2 What the compositor does per request

```
startRequest(request):
  time = request.compositionTime            # the frame, from AVFoundation
  frame = round(time.seconds * 30)          # the EDL grid
  base = composite the instruction's video layers in order
         (reuse LookVideoCompositor's layer loop: opacity/transform
          ramps, aspect-fill transforms, black base)
  graded = apply the Look grade to `base`   # the grade step, same chain
  overlay = sceneEvaluator.evaluate(scene, frame, inputs)
             .render()                       # CIImage, with alpha
  out = overlay.composited(over: graded)
  ciContext.render(out, to: request.renderContext.newPixelBuffer())
  request.finish(withComposedVideoFrame:)
```

Order matters and is fixed: **grade the footage first, then composite the scene over it.** Scene
graphics (text, stickers, panels) are designed colours; grading them would shift the style's own
palette. (The v1 lyric burn-in sits above the grade for the same reason — the transcode applies
the grade to the master, and the tool composites over it.)

The video-layer step reuses the existing layer-instruction loop (including the second video track
for cross-dissolves — a Parallel Worlds style that mirrors footage gets its second layer from the
compositor, not from the scene graph; see §4.3). The scene step is new. The grade step is the
existing `gradedImage` chain, moved into this compositor so preview and transcode share one class.

### 6.3 Preview integration

- The preview composition (`buildComposition(forExport: false)`) attaches `ExtraStylesCompositor`
  (with the scene + params installed via the same static-slot discipline as `LookCompositorStore` —
  install before the player starts, clear on release) **instead of** `LookVideoCompositor` when a
  2.0 style is active. When no 2.0 style is active, preview is exactly as today.
- The JS `LyricsOverlay` is NOT used for the active 2.0 style. Traditional lyrics (when enabled)
  still draw through it — the two layers coexist: native scene (below) + JS traditional lyrics
  (above) + JS watermark overlay. Layer order is fixed and documented: video → grade → 2.0 scene
  → traditional lyrics → watermark.
- **Parameter changes without a rebuild:** params live in the compositor's store, not in the
  composition. A param change (slider drag, toggle) calls a lightweight bridge method
  (`updateExtraStyleParams`) that swaps the stored params; the player keeps playing and subsequent
  frames evaluate with the new params. No `createPreview` rebuild, no playback restart. Structural
  changes (style switch, lyric set change, canvas change) still rebuild the composition via a new
  `requestKey` — the existing mechanism, unchanged.
- Preview progress events continue to drive the playhead UI only; they never drive the scene.

### 6.4 Export integration

Two candidate wirings, in preference order. Phase 2 prototypes the first; the second is the proven
fallback. **The scene evaluation code is identical in both — only the plumbing differs.**

1. **Direct (preferred, to be proven):** attach `ExtraStylesCompositor` to the export composition
   in `buildComposition(forExport: true)`, so the export session renders video + grade + scene in
   one pass. This is plausible — a custom compositor is not the CIFilter twin, and the preview
   already proves the compositor can ride an EDL composition — but it is **unproven in combination
   with `AVAssetExportSession` + the animation tool** (the tool is still needed for the watermark
   and traditional-lyric burn-in on the same composition). The prototype must verify: the session
   accepts the composition, the tool and the compositor coexist, and the output is frame-correct.
   If it verifies, exports with a 2.0 style and no size control skip the transcode entirely.
2. **Transcode slot (proven fallback):** keep the export composition bare (as today), render the
   master, then apply the scene in the post-render transcode — the transcode's single-instruction
   composition gets `ExtraStylesCompositor` (with the grade step inside it), exactly as
   `LookVideoCompositor` rides it today (`transcodeAttempt`, line 5624). Cost: one extra
   reader→writer pass on every 2.0 export. Benefit: zero new AVFoundation integration risk; the
   pattern is shipped and the pump is fixed. When a size-control transcode is requested anyway,
   the scene rides it for free.

Either way, the export's audio, duration, EDL behaviour, and tiers are untouched: the scene is a
video-composition concern only, and the transcode pump, bitrate control, and corrective pass do not
change.

### 6.5 Metal prototype spike (Phase 2, timeboxed)

Build two nodes in Metal behind the evaluator interface and measure on the target device
(iPhone 17 Pro Max) at 1080×1920 and at the 4K canvas: (a) a particle field emitter (2,000
particles), (b) a distortion-wave displacement. Compare frame time against the Core Image
implementation of the same nodes. Adopt Metal per node only where it wins by a margin that matters
(≥ 2×, or where CI cannot hold 30 fps at all). Record the result in the programme doc; do not
adopt Metal on principle.

### 6.6 Bridge surface (new `AsyncFunction`s, versioned)

All new bridge calls follow the existing conventions (availability gate, never reject where a
fallback exists, progress + cancellation by id for long work):

| Call | Purpose |
|---|---|
| `getExtraStyleCatalog()` | Returns the metadata JSON (§3.1) once per launch. |
| `prepareExtraStyleScene(request)` | Builds the scene ahead of time (style id + params + lyric payload + automation/mask references in, scene handle out). Reports progress; this is where load time lives (§13.2). |
| `updateExtraStyleParams(handle, params)` | Swaps params in the compositor store without a rebuild (§6.3). |
| `prepareAudioAutomation(uri)` | §9 — decodes once, returns the cached automation JSON. |
| `prepareSubjectMasks(takeUri)` | §10 — precomputes person masks, returns the cached mask reference. |
| `renderExtraStylePreviewFrame(handle, frame, size)` | Renders one frame (or a few keyframes) for card previews (§12.2). |
| `releaseExtraStyleScene(handle)` | Frees the scene + its caches. |

Scene data crosses the bridge **once** (at preparation), as a compact binary/JSON payload. Per-frame
evaluation is native-only; the bridge carries no per-frame traffic. The interface is versioned
(`extraStylesBridgeVersion`, starts at 1) so the JS side can refuse a build whose native engine is
older than the UI expects.

### 6.7 Caching (what is cached, where)

- **Glyph textures:** Core Text lays out text per line/word/character at scene-build time; the
  resulting glyph runs are cached per (font, size, text) and reused across frames — the evaluator
  never re-lays-out text per frame.
- **Particle textures:** each emitter's sprite texture is rendered once and reused.
- **Static subtrees:** nodes with no animation over a frame range are rasterized once per unique
  state (§4.2).
- **Prepared scenes:** a prepared scene (handle) lives for the editing session; switching away
  from a style releases it. The on-disk caches (audio automation, subject masks, card-preview
  frames) persist across launches, keyed like the MixMaster cache (song/take identity + recipe
  version).

---

## 7. Layer 5 — Lyric Intelligence

**Responsibility:** turn the lyric data into what styles consume — and do the thinking ahead of
time, once, deterministically.

### 7.1 What the engine consumes (already exists — reuse)

- Lines + words in song-absolute frames (§1.2), via `buildCompositeLyrics`'s mapping (the same
  builder, extended — see §7.3).
- Stored intelligence per line: emoji, tone, emphasis word indices.
- The grouper's phrase structure: lines are already singable phrases (pauses / sentence breaks /
  caps). A style that wants "phrases" uses lines; a style that wants "sentences" joins lines on
  sentence-ending punctuation (a pure function over the stored lines, no new detection).

### 7.2 What must be added (new, ahead-of-time, cached)

| Signal | How it is derived | Deterministic? |
|---|---|---|
| **Verse / chorus sections** | Line-text repetition analysis over the stored lines: lines whose normalized text repeats (allowing the existing consecutive-duplicate collapse to have removed echoes) mark a repeated section; the longest repeated block is labelled chorus, the rest verses. Pure function of the lyrics — no audio needed. Confidence is reported; a song with no repetition gets no sections (styles fall back to line-by-line behaviour). | Yes — same lyrics → same sections. |
| **Semantic tags (extended)** | Extend the v1 keyword dictionary (§1.2) with the concept lists the 40 styles need (weather, time, place, motion, emotion, objects — the Emoji Storytelling dictionary generalised). Same rule as v1: first match wins, no match = no tag, nothing guessed. Computed once at Detect (or when lyrics are edited), stored on the line alongside the existing `decor`. | Yes. |
| **Speaker / vocal-section changes** | **Not available.** Whisper does not diarize, and no diarization exists in the project. Styles that need two voices use line alternation (the Duet precedent: even/odd lines) or the tone tag — not a detected speaker. Marking this as a future investigation (on-device diarization is a research project, not a Phase 2 item). | N/A — do not fake it. |
| **Beat timestamps** | From the audio automation (§9), not from the lyrics. The lyric layer exposes beat phase at any frame; styles read it as an input. | Yes, once the automation is computed. |

### 7.3 The interpretation artifact

A new derived-data artifact, `LyricInterpretation`, computed ahead of time per project (when lyrics
are detected/edited, or when a 2.0 style is first selected — whichever is first) and cached on disk
keyed by (song identity + lyrics hash + interpretation version), exactly like the MixMaster profile
cache:

```ts
interface LyricInterpretation {
  version: number;                 // interpretation recipe version
  songKey: string;                 // songLibraryKey(name, duration)
  lyricsHash: string;              // hash of the stored lines + words
  sections: { kind: 'verse' | 'chorus' | 'bridge' | 'other';
              startFrame: number; endFrame: number; confidence: number }[];
  lines: { lineId: string; semanticTags: string[]; /* + the stored decor */ }[];
}
```

The scene builder (§3.2) receives the interpretation as part of its input. The interpretation is
never computed per frame and never calls an AI API: it is dictionary + repetition analysis over
data the app already holds. If the interpretation is missing (old project, uncomputed), the scene
builder falls back to lines + stored decor only — the style still renders, with section-aware
behaviour disabled. That fallback is the deterministic behaviour, not an error path.

### 7.4 What does NOT change

Detection stays Whisper Small, detection-only, no lookup. The grouper, the line editor, the
fine-offset bar, the song library, and the profanity respelling are untouched. The v1 intelligence
fields keep their exact semantics — 2.0 adds fields beside them, it does not redefine them.

---

## 8. Layer 6 — Style-Specific Customization

**Responsibility:** each style declares its own controls; the UI generates them; changes update the
scene without a rebuild.

### 8.1 Parameter schema (declared per style, in the style definition)

```ts
type ExtraStyleParamValue = number | boolean | string | string[];  // JSON-safe only

interface ExtraStyleParameter {
  id: string;                       // stable, e.g. "gravity"
  label: string;                    // user-facing, e.g. "Gravity"
  kind: 'slider' | 'toggle' | 'color' | 'segmented' | 'select'
      | 'number' | 'asset';
  // slider/number:
  min?: number; max?: number; step?: number; unit?: string;
  // segmented/select/asset:
  options?: { value: string; label: string }[];
  default: ExtraStyleParamValue;
  // Which scene inputs this parameter feeds (for the "no full
  // rebuild" rule — the evaluator re-reads only the affected tracks).
  affects: 'layout' | 'motion' | 'appearance' | 'density';
}
```

Rules:

- **Declared, not hardcoded.** The UI renders controls from the schema; there is no per-style UI
  code in Phase 2/3. A style with no parameters declares an empty list (and gets no controls).
- **No generic font/colour/size/position controls.** A 2.0 style's parameters are its own creative
  controls (gravity, particle density, hologram colour, scanline intensity). Typography choices
  live inside the style's scene definition, not in a shared subtitle panel — that is the point of
  independence (§2).
- **Sensible defaults + presets.** Each style ships its defaults (the look Jaizon approved in the
  brief) and may ship 2–3 named presets (parameter sets, e.g. Dream Sequence "Gentle" / "Intense").
  Presets are parameter values, not separate styles.
- **Values are JSON-safe and small.** The whole parameter set crosses the bridge as one JSON blob
  on change (§6.6). No asset binaries cross the bridge — assets are referenced by id (§11).

### 8.2 How a change reaches the screen

1. User moves a control → JS stores the new param values in `Project.extraStyle.params` (persisted
   debounced, like every other project field).
2. JS calls `updateExtraStyleParams(handle, params)` (§6.6) → the compositor store swaps the values.
3. Subsequent frames evaluate with the new values. The composition is NOT rebuilt; playback does
   not restart; the preview keeps playing.
4. Structural params (a param whose `affects` is `layout` AND changes node count — e.g. density
   changing the number of emitted layers) re-run `buildScene` for that style (ahead-of-time, with
   progress) and swap the scene handle. The distinction is declared in the schema, not guessed at
   runtime.

### 8.3 Layer editing

Styles declare editable layers in their definition (`editableLayers: [{ nodeId, label, params }]`).
Where declared, the UI offers the layer's controls (e.g. Comic Book: bubble shape / position /
emphasis; Dream Sequence: particle density / colour / drift; Holographic Interface: panel depth /
scanline intensity). Where not declared, the style is edited only through its top-level parameters.
Not every layer is editable — the editing experience stays focused on the concept, per the brief.

---

## 9. Audio reactivity

### 9.1 What exists (reuse)

- `waveformPeaks` (120 buckets) — UI waveforms, too coarse for beat work.
- MixMaster 10-band windowed gains (1.0 s windows, 0.5 s hop) + findings — coarse, EQ-shaped, not
  energy; usable as a "where is the song busy/harsh" prior, not as a beat source.
- Auto EQ whole-song band levels — a static snapshot.
- Section RMS energy sampled during playback — sparse, playback-dependent, assumed 120 BPM grid.
- Integrated loudness + peak — whole-song only.

### 9.2 What must be built: audio automation (new native analysis)

A new ahead-of-time analysis, `prepareAudioAutomation(uri)`, decoding the song once (AVAssetReader,
same pattern as `waveformPeaks` / the MixMaster decode pass) and producing a cached JSON artifact
(`Application Support/MVMTStudio/automation/<key>.json`, keyed by song identity + recipe version,
same cache discipline as MixMaster):

```ts
interface AudioAutomation {
  version: number;                  // recipe version
  songKey: string;
  sampleRate: number;
  durationSeconds: number;
  /** Onset strength per hop (spectral flux, normalised 0..1). */
  onsetEnvelope: { hopSeconds: number; values: number[] };
  /** Beat grid: tempo + beat times + downbeats + confidence. */
  tempoBpm: number;
  beats: { timeSeconds: number; isDownbeat: boolean; strength: number }[];
  beatConfidence: number;           // 0..1 — styles gate reaction on this
  /** Per-band energy (same 10-band bank as Auto EQ), ~10 Hz. */
  bandEnergies: { hopSeconds: number; bandsHz: number[]; values: number[][] };
  /** Short-term loudness curve (~10 Hz), LUFS. */
  loudnessCurve: { hopSeconds: number; values: number[] };
}
```

**Method (proposed, to be validated in the Phase 2 prototype):** spectral-flux onset detection
over a short-time Fourier transform (vDSP/Accelerate), tempo estimation by autocorrelation of the
onset envelope, beat tracking by dynamic programming over the onset envelope (Ellis-style), band
energies from the same RBJ filter bank Auto EQ already uses (so the two analyses agree on what a
"band" is). Hop: 0.1 s for the envelope/bands (fine enough for beat-synced visuals, cheap enough
to store: a 3-minute song is 1,800 samples per curve). **Beat detection does not exist today and
must not be assumed to work on every song** — the artifact carries `beatConfidence`, and styles
gate their beat reactions on it: low confidence → fall back to the onset envelope (any strong
onset still triggers a reaction) → fall back to the section energy (the coarsest signal). A style
never renders a wrong beat as if it were confident.

**Cost:** one decode + FFT pass per song, cached. It runs when a 2.0 style that needs it is first
selected (or when the song is first picked, if the project already has such a style) — with honest
progress (§13.2). It never runs per frame and never runs during playback.

### 9.3 How styles use it

The scene evaluator receives automation samples for the evaluated frame (§5.3): onset strength,
beat phase (frames since/until the nearest beat), band energies, loudness. Reaction tracks declare
which inputs they read. Examples from the brief, mapped to the artifact: a kick triggers an impact
(onset strength spike in the low band); a bass hit expands typography (low-band energy); a snare
triggers a transition (mid-band onset); a build-up increases particle density (rising loudness
curve); a quiet passage reduces intensity (low loudness). All of it is sampling precomputed curves
at a frame — no analysis at render time.

---

## 10. Subject-awareness (Vision investigation)

### 10.1 What is feasible (and what is not)

- **Person segmentation:** `VNGeneratePersonSegmentationRequest` (Vision, iOS 15+) produces a
  person mask per frame. Quality levels `.fast` / `.balanced` / `.accurate` exist; `.accurate` is
  the only one worth using for a visible "text behind person" effect. It runs on-device with the
  Neural Engine. **Feasibility: yes, as a precompute** — not per frame at render time.
- **Face / subject position:** `VNDetectFaceRectanglesRequest` (face boxes) and
  `VNTrackObjectRequest` (tracking a subject across frames) are available. Face-aware positioning
  (keep text out of the face box, or anchor an effect to the face) is feasible from these.
- **Depth:** **not available from the footage.** The app's takes are plain video files; capture
  does not record depth (no LiDAR depth channel is written, and imported videos never have one).
  Any "depth-aware" effect must be faked from the 2D mask (mask size ≈ proximity, mask centroid ≈
  position) or omitted. Do not promise 3D tracking.
- **Tracking quality on real footage:** unknown until tested on Jaizon's takes (moving subject,
  stage lighting, fast cuts). This is a Phase 2 spike with a device verdict, not a design-time
  decision (§19).

### 10.2 The proposed approach (precompute, cache, interpolate)

1. When a style that needs subject data is selected, `prepareSubjectMasks(takeUri)` runs ahead of
   time: sample the take's video at a low rate (proposed: 2 fps — a mask every 15 frames), run
   person segmentation (+ face detection) on each sampled frame, and store the masks as small
   grayscale images (proposed: 270×480, 8-bit) in `Application Support/MVMTStudio/masks/`, keyed
   by take identity + recipe version.
2. At render time the evaluator samples the nearest masks and interpolates (cross-fade between
   adjacent mask frames; masks change slowly at 2 fps for a performing subject — fast movement is
   the known weak case and degrades to a softer edge, never a failure).
3. The scene graph uses masks as `ExtraStyleMask` values (§4.1): "lyrics behind the person" is
   implemented as video → scene → person cutout (the base video masked by the person mask,
   composited over the scene). Particles around the subject use the mask centroid + bounds.
4. **Graceful fallbacks, in order:** no person in a sampled frame → that frame renders without
   subject effects (full-frame layout); segmentation fails for a take → the style renders its
   non-subject behaviour for the whole take; masks unavailable (Expo Go / old build) → subject
   features are hidden in the UI with an honest note. A missing mask never blocks an export.

### 10.3 Cost honesty

Precompute is the load-time cost Jaizon accepted (§13.2): segmentation at 2 fps over a 60 s take
is 120 Vision requests — seconds to tens of seconds on device, cached forever per take. The plan
does not hide this: the first selection of a subject-aware style shows real progress
("Analysing subject…"), and the masks are reused for every style and every export of that take.

---

## 11. Visual Asset System

**Principle: procedural-first, bundled-second, no generic stock.** The visual identity must feel
intentional and professionally designed — a small, curated asset set beats a large generic one.

- **Procedural (the default):** shapes, gradients, paths, particle textures, scanlines, glows,
  and frames generated in code (Core Graphics / Core Image). Most of the 40 styles need nothing
  else — their identity comes from typography + motion + procedural graphics.
- **Bundled assets:** a small pack shipped in the app bundle — transparent PNGs (sticker art,
  paper textures, halftone dots, comic bursts, frames) and vector shapes. Vectors are converted to
  `CGPath` at authoring time (no runtime SVG parser); the JS side already has `react-native-svg`
  for any vector preview work. Each asset has an id, a manifest entry (size, anchor, intended
  styles), and a version.
- **Caching:** decoded textures live in a GPU texture cache keyed by asset id + size; particle
  textures are rendered once per emitter. Assets are referenced by id in scenes and projects —
  never embedded in project JSON, never sent across the bridge as binaries.
- **What is NOT in scope:** downloadable asset packs, user-imported stickers, or a stock library.
  If Jaizon later wants downloadable packs, the manifest + id-reference design already supports
  them; Phase 2/3 does not build the download machinery.

---

## 12. iPhone Interface

### 12.1 Discovery — a dedicated Extra Styles section

Extra Styles gets its own section, **separate from the Lyrics panel** (§2.4). Proposed home: a
dedicated screen in the project workspace (`src/app/project/extra-styles.tsx`, reached from the
Edit screen), so the section has room for categories, search, and previews without crowding the
editor. Contents:

- Categories (§3.3): Cinematic, Typography, Digital, Design, Playful, Music, Experimental.
- Search (name + tagline + category).
- Favorites (heart per style, persisted per project — same pattern as
  `ProjectLyrics.favoriteTemplateIds`, but on `Project.extraStyle.favoriteStyleIds`).
- Recently used (per device, last 5 styles, stored with the project list or in the style metadata
  cache — not per project).
- Featured (a small curated set, chosen per release — the five demos first).
- A clear visual distinction from traditional lyrics: the section is about scenes, not subtitles
  (cards show compositions, not font names).

Mobile-first: one-column card list, large touch targets, no nested scrolling traps, the preview
and timeline stay the hero of the Edit screen — the styles section is a destination, not a drawer
that covers the edit.

### 12.2 Style selection and preview

Each style card shows an **animated preview of the actual composition** — sample lyrics over a
sample video — not a static thumbnail. Implementation (proposed):

- A bundled 3-second sample clip (portrait, with a person performing — the same clip for all
  styles, so styles are comparable) + sample lyric lines.
- On demand, when a card becomes visible, the bridge renders a short looping preview
  (`renderExtraStylePreviewFrame`, §6.6) at reduced resolution (proposed: 540×960, 15 fps, 3 s)
  and caches the frames on disk. First open of a card costs a short render; after that it plays
  from cache. **DECISION for Jaizon:** the preview budget (resolution / fps / cache size) trades
  against first-open load time — the plan proposes 540×960 @ 15 fps as the starting point and
  leaves the exact numbers to the Phase 2 prototype's device measurements.
- When a style is selected: (1) load its scene definition (prepare, with progress — §13.2);
  (2) display it over the user's own video in the editor preview (the real preview, not the
  sample); (3) show the style-specific controls (§8); (4) allow real-time playback; (5) save the
  style + parameters into the project (§14). No multi-page settings maze.

### 12.3 Per-style controls and layer editing

Controls are generated from the parameter schema (§8.1) — sliders, toggles, colour pickers,
segmented controls, asset selectors — grouped under the style's name, with its presets on top.
Layer editing (§8.3) appears only where the style declares editable layers. The panel is a
bottom sheet (native-feeling, like the rest of the app), not a desktop-style inspector.

---

## 13. Performance and load time

### 13.1 Performance requirements (and how the architecture meets them)

| Requirement | How it is met |
|---|---|
| GPU-accelerated rendering | Core Image renders on the GPU (`CIContext` with `.useSoftwareRenderer: false`, the existing pattern); Metal nodes (§6.5) only where profiling demands them. |
| Texture / glyph caching | §6.7 — glyph runs cached per (font, size, text); particle textures rendered once; static subtrees rasterized once. |
| Reusable assets | §11 — assets by id, decoded once, cached in the GPU texture cache. |
| Efficient scene updates | Param changes swap values in the compositor store (§6.3) — no composition rebuild, no scene rebuild except for structural params (§8.2). |
| Memory management | Fixed-size particle buffers (capped per emitter); prepared scenes released on style switch (`releaseExtraStyleScene`); on-disk caches bounded (oldest-first eviction for card previews; automation/mask caches keyed and versioned, never unbounded). |
| Background processing | All preparation (scene build, audio automation, subject masks, card previews) runs off the main thread with progress + cancellation; the render itself is AVFoundation's queue, as today. |
| Render-time profiling | The compositor records ms/frame per style (scene-evaluation time + render time) in a lightweight in-memory log, surfaced in a debug view and included in export diagnostics. Device numbers — not simulator numbers — are the verdict. |
| No per-frame bridge traffic | §6.6 — scene + params cross once; evaluation is native-only. |
| No per-frame analysis | Audio automation, subject masks, and lyric interpretation are all precomputed (§7–§10). |
| No main-thread blocking | The JS thread never evaluates scenes; the native preview thread never waits on JS. |

**Budgets (proposed, to be confirmed by the Phase 2 prototype on device):** preview must sustain
the playback frame rate at the preview size (the player drops scene detail before it drops video
frames — a style that cannot hold the budget degrades its particle/density parameters, never the
footage); export render time is bounded by the existing export progress UI (a scene that doubles
export time is acceptable; one that makes export time unbounded is not — the profiler flags it).

### 13.2 Load time — accepted, and where it lives

Jaizon has explicitly accepted load time for the new lyric/style system (2026-11-13 ~01:10 MST).
Load time is therefore a **designed** cost, not a failure — but it must always be honest progress,
never a silent hang. Expected load points:

| When | What loads | Shown as |
|---|---|---|
| First selection of a 2.0 style | Scene preparation (build scene, lay out glyphs, warm the texture cache) | Progress bar with the style's name ("Preparing Dream Sequence…") |
| First selection of an audio-reactive style | Audio automation (§9) — one decode + FFT pass, cached per song | Progress ("Analysing the song's beat…") |
| First selection of a subject-aware style | Subject masks (§10) — Vision precompute per take, cached per take | Progress ("Analysing the subject…") |
| First view of a style card | Animated card preview render (§12.2), cached | The card shows its static keyframe until the loop is ready |
| Opening a project with a 2.0 style | Scene re-preparation from the stored params (fast — the scene definition is code, the caches persist) | Brief spinner only if a cache is cold |

Nothing loads during playback, during recording, or during an export render — preparation is
always ahead of time, and an export never waits on a preparation that has not finished (the
Export screen shows the preparation state and offers to wait or to export without the scene —
never a silent stall).

---

## 14. Project persistence

### 14.1 The new field (proposed shape)

```ts
interface ExtraStyleState {
  styleId: string;                  // e.g. "dream-sequence"
  styleVersion: number;             // the definition version it was built against
  params: Record<string, ExtraStyleParamValue>;  // the style's parameter values
  /** Editable-layer overrides, where the style declares them (§8.3). */
  layers?: Record<string, Record<string, ExtraStyleParamValue>>;
  /** Favourite 2.0 styles (per project, like favoriteTemplateIds). */
  favoriteStyleIds?: string[];
}
```

Stored as `Project.extraStyle?: ExtraStyleState` — additive, optional, beside `lyrics` (which is
untouched). The lyric interpretation cache (§7.3), audio automation (§9.2), subject masks (§10.2),
and card-preview frames are **derived caches on disk**, not project fields — the project stores
only the style choice + params; the caches are rebuilt from (song, lyrics, take) identity when
missing.

### 14.2 Migration

- **Style definitions are versioned** (§3.4). The loader checks `styleVersion` against the
  registry: same version → load as-is; older version → run the style's migration function if one
  is registered for that jump (param renames / defaults), else fill changed params with defaults
  and keep the rest; newer version than the registry (a project from a newer build) → render
  traditional lyrics only, with a notice — never crash, never drop the project.
- **Unknown style id** (retired style, corrupted field) → the project opens with no 2.0 style and
  a notice ("This Extra Style is no longer available — your video and lyrics are untouched").
- **No migration functions exist in Phase 2** (every style starts at version 1). The mechanism
  (version check + fallback) ships in Phase 2; the first real migration is written when a style
  first changes incompatibly.
- **The persistence file stays version 1** (`projects.json`, §1.9): the new field is additive and
  optional, and the loader already tolerates missing fields. A file-version bump is reserved for
  a genuinely breaking storage change, which 2.0 does not need.

### 14.3 Song library interplay

Styles are **per-project, not per-song**: the song library keeps carrying corrected lyrics (as
today), and a project that applies a library song keeps its own `extraStyle` (or none). A style
does not travel with a song — it belongs to the video it was designed for.

---

## 15. v1 templates — migration proposal

**DECIDED by Jaizon (2026-11-13 ~01:25 MST): RETIRE all 30 v1 templates when 2.0 ships.** This supersedes the keep-as-legacy proposal below, which is retained here only as the record of what was considered.

Retirement means: when 2.0 ships, the Lyrics panel's Extra tab (the 30 v1 templates) is removed; a project that stores a `templateId` opens with classic lyrics (no template) and a notice, never a crash — the §14.2 migration maps each v1 `templateId` to its 2.0 successor where one exists, otherwise to classic. The v1 rendering path (JS overlay + Swift CALayer burn-in) may be deleted once the migration is in place; the 2.0 demos already cover two v1 concepts (Emoji Storytelling, Comic Book) as rebuilds.

**Original proposal (superseded — keep-as-legacy, NOT adopted):** keep the 30 v1 templates working as legacy styles. Do not delete them, do not rebuild
them in Phase 2/3, and do not auto-migrate existing projects.

Reasons:

1. They are shipped, tested, and parity-audited (42 findings fixed, `docs/STYLES-PARITY.md`).
   Deleting them would destroy tested work Jaizon approved and break every project that already
   stores a `templateId`.
2. They cost almost nothing to keep: the v1 rendering path (JS overlay + Swift CALayer burn-in)
   is independent code that 2.0 does not touch. Keeping it is a branch in the Lyrics panel, not a
   maintenance burden on the new engine.
3. Two v1 concepts overlap the 2.0 demos by design — Emoji Storytelling and Comic Book exist in
   both systems. The 2.0 versions are rebuilds (scene-based, multi-element), not replacements, and
   the v1 versions stay until the 2.0 versions prove themselves on device.

Concretely:

- The Lyrics panel keeps its Extra tab with the 30 v1 templates, labelled **Classic Extra Styles**
  (or similar) so the distinction from 2.0 is visible.
- The new Extra Styles section (§12) carries only 2.0 styles.
- A project keeps whichever it has: `templateId` (v1) and `extraStyle` (2.0) are independent
  fields. If a project somehow has both (user tried both), the 2.0 style wins for the scene layer
  and the v1 template is ignored for rendering (but kept in storage, so switching back restores
  it) — documented, not silent.
- **Later, at Jaizon's call:** popular v1 concepts can be rebuilt as 2.0 scenes one by one (the
  2.0 demos already cover two of them), and v1 templates can be retired individually once their
  2.0 successors exist. Retirement is a per-template decision, never a bulk deletion.

**DECISION — MADE by Jaizon (2026-11-13 ~01:25 MST): "retire v1 when 2.0 ships".** The plan is now written for retiring: §14.2 carries the migration (each v1 templateId maps to its 2.0 successor or to classic) and the Lyrics panel loses the Extra tab at ship time.

---

## 16. Dependencies

| Need | Status |
|---|---|
| Metal (system framework) | Already available — no pod, no package. Used only if the §6.5 spike adopts it per node. |
| Vision (system framework) | Already available — no pod, no package. Used for §10 precompute only. |
| Core Image / Core Text / Core Animation / AVFoundation / Accelerate (vDSP) | Already in use (Core Image, Core Animation, AVFoundation) or system-available (Core Text, Accelerate). No new dependencies. |
| `react-native-svg` | Already present (added Stage 4). Used only for JS-side vector preview work, if needed. |
| New npm packages | **None expected.** If a JS-side need appears (e.g. a parameter-schema form library), it is evaluated then — the schema is designed to render with plain RN controls. |
| New CocoaPods | **None.** The module's podspec stays `ExpoModulesCore` only. |
| New native modules | **One new Swift surface inside the existing `MvmtCompositor` module** (§6.6) — no new Expo module. A separate module would split the engine; the compositor is where scenes render, so scenes live there. |
| iOS floor | 15.5 (podspec) — Vision person segmentation and the Accelerate APIs used here are available at 15.5. No floor change needed. (If a Phase 2 spike needs an iOS 16+/17+ API, that is a decision with a user-facing consequence — the floor moves only with Jaizon's agreement.) |

---

## 17. The 40 styles — capability mapping

Each style names what it needs from the engine. The five demos (Phase 3, first built) are marked
★. The mapping is the proof the engine covers all 40 — and the proof the five demos are five
different systems, not one template with different paint.

| # | Style | Scene elements | Animation behaviours | Audio | Subject | Assets / notes |
|---|---|---|---|---|---|---|
| 1 ★ | Dream Sequence | translucent text layers, particle field, light-trail paths, glow | drift (slow keyframes + loop), dissolve/reform (opacity + scale envelopes), seeded scatter | loudness curve (quiet → subtle) | optional: particles orbit the mask centroid | procedural glow + trails; no bundled assets |
| 2 | Memory Fragments | photo-frame groups (image + caption), layered compositions | slide-in (keyframed), cross-dissolve between memories, staggered entrances | — | optional: frames avoid the face box | bundled photo-frame art; uses imported stills? No — frames are procedural + bundled textures (user photos are out of scope for Phase 3) |
| 3 | Floating Universe | star field (particles), planet shapes, orbit paths, depth-scaled text | orbital paths (path animation), parallax by depth layer, slow rotation | — | — | procedural stars/planets; depth via scale + opacity |
| 4 | Film Credits Reimagined | large tracked type, letterbox bars, gradient vignette | dramatic tracking (letter-spacing keyframes), slow push-in (scale), camera-move illusion (group translate) | — | — | typography-led; no assets |
| 5 | Parallel Worlds | mirrored text groups, split-screen divider, distortion overlay | mirrored transforms, split wipe (mask keyframes), world-switch transitions | beat phase (world switch on downbeat) | — | uses the compositor's second video layer for mirrored footage (§6.2) |
| 6 ★ | Typography Physics | per-character nodes | gravity + bounce + collision (deterministic fixed-step physics, §5.2), stack/scatter on exit | onset triggers (impact on kick) | — | the physics demo — nothing else in the engine moves like this |
| 7 | Liquid Letters | text as a deformable group, ripple paths, blob shapes | stretch/merge (scale + path morph keyframes), ripple (sine displacement along the line) | loudness (flow speed) | — | procedural blobs; morph is keyframed path interpolation, not true fluid sim |
| 8 | Infinite Tunnel | concentric shape rings, perspective-scaled text | perspective scaling (scale + opacity by depth), continuous forward motion (loop) | tempo (tunnel speed follows BPM) | — | procedural rings; depth via scale |
| 9 | Portal Typography | portal rings (shape + glow), environment gradient behind the portal | portal open (scale + opacity envelope), words pass through (path + scale) | phrase boundaries (new portal per phrase) | — | procedural rings + gradients |
| 10 | Typography Explosion | per-character nodes + shard shapes | explode (radial velocity per char, seeded), reassemble (spring back to targets) | onset triggers (explosion on accent) | — | shards are procedural triangles |
| 11 ★ | Holographic Interface | HUD panels (groups: frame + label + scanline), floating labels, scanline overlay | scan (opacity sweep loop), flicker (seeded opacity noise), panel float (slow keyframes) | — | — | procedural HUD graphics; the interface demo — panels, not just text |
| 12 | Digital Corruption | RGB-split text copies (3 layers, channel offsets), glitch slices (masked bands), noise field | jitter (seeded offsets), slice displacement (keyframed mask bands), reconstruct (offsets → 0) | onset (glitch burst on accent) | — | RGB split via blend modes + channel masks; needs the Metal spike only if CI slice cost is too high |
| 13 | Cyber Terminal | terminal panel (group), typed text (per-char), cursor, system-message lines | typewriter (per-char discrete reveal), scanline sweep, panel transitions | — | — | procedural terminal chrome |
| 14 | Virtual Reality | floating 3D panels (groups with perspective transforms), depth-scaled text | depth movement (scale + translate by depth), camera-tracking illusion (group counter-move) | — | face position (panels track the face box) | perspective via CATransform3D-equivalent matrices in the evaluator |
| 15 | Data Visualization | number counters, bar/graph shapes, waveform path, diagram groups | counters (numeric keyframes), bars grow (scale keyframes), waveform draws (path progress) | band energies drive the bars; loudness drives the waveform | — | procedural charts; the only style whose primary content is data, not lyrics |
| 16 | Editorial Magazine | headline text, rule lines, multi-column text blocks, overlap groups | editorial transitions (wipe + fade), dynamic wrap (layout keyframes) | — | — | typography + rules; layout-led |
| 17 | Brutalist Typography | massive text, geometric shapes (blocks, bars), high-contrast palette | hard cuts (discrete opacity), aggressive slides, unexpected placement (per-line anchors) | onset (cut on accent) | — | shapes + type; no assets |
| 18 | Collage Explosion | cutout letter nodes, paper-texture shapes, sticker images, photo fragments | rapid collage transitions (staggered entrances, rotation, scale pops) | — | — | bundled paper/sticker textures (§11) — the most asset-dependent style |
| 19 | Ink and Paint | brush-stroke paths, ink-blot shapes, paint splashes | stroke reveal (path progress), bleed (scale + opacity), splash (particle burst) | — | — | procedural strokes + splash particles |
| 20 | Neon Sign World | neon text (glow layers), sign backings, reflection gradient | flicker (seeded), electrical activation (opacity ramp + glow swell), reflection shimmer | — | — | glow via CI blur + blend; reflection is a flipped, faded copy |
| 21 ★ | Emoji Storytelling | emoji nodes (per line, from stored intelligence), illustration groups, reaction bursts | emoji pop (spring), reactions (staggered bursts), float (slow loop) | tone tag selects the reaction set | — | emoji glyphs (system rendering, no assets); the storytelling demo — semantics drive visuals |
| 22 | Cartoon Universe | speech bubbles (shape + tail), cartoon shapes, motion lines | bubble pop (spring), motion lines (path draw), illustrated transitions | — | — | procedural cartoon shapes |
| 23 | Message Universe | chat bubbles (groups), typing dots, reaction emoji, message transitions | typing (dots loop → message reveal), bubble slide-in, reactions pop | speaker alternation via line parity (no diarization — §7.2) | — | procedural bubbles |
| 24 ★ | Comic Book | panels (groups with borders), speech bubbles, impact words, motion lines, burst shapes | panel wipe, impact scale, burst pop, motion-line draw | onset (impact on accent) | — | procedural panels/bursts; the multi-element group demo |
| 25 | Sticker World | sticker images around the text, themed sets | stickers bounce/react (spring + stagger), interact (move toward/away from words) | — | — | bundled sticker art (§11) |
| 26 | Soundwave Typography | text deformed along a waveform path, waveform line | words pulse/distort/stretch with the waveform (path + scale keyed to band energies) | band energies + onset (the style IS audio-reactive) | — | procedural waveform |
| 27 | Beat Reactor | text + graphic accents (rings, flashes) | beat-synchronized pulses (scale/opacity keyed to beat phase), transitions on downbeats | **beat grid + onset (required — fails loudly without automation)** | — | the beat demo |
| 28 | Frequency Universe | frequency-band bars, spectral particles, glow | bars follow band energies, particles rise with bass, treble flashes | **band energies + loudness (required)** | — | procedural bars/particles |
| 29 | Rhythm Typography | per-word / per-syllable nodes (syllables from word timings split by vowel groups — deterministic heuristic, documented as approximate) | each word its own rhythmic animation (bounce/stretch/pop by syllable), phrase transitions on beat phase | beat phase + onset | — | syllable split is a heuristic — the plan marks it as approximate, not phonetic |
| 30 | Audio Energy World | full-scene intensity driver (all nodes read one energy value) | global intensity scaling (density, speed, glow all follow the loudness curve) | **loudness curve (required)** | — | the whole composition is the visualizer |
| 31 | Glitch Reality | distortion overlay (full-frame displacement), fragmented text copies, offset layers | layers move independently (seeded offsets), break-apart (mask bands), reconstruct | onset (break on accent) | — | Metal-spike candidate (displacement shader) |
| 32 | Surveillance System | tracking boxes (shape + corner marks), labels, timestamps, target-lock rings | box track (follows face/subject position), lock-on (scale + opacity), label updates | — | **face/subject position (required)** | procedural HUD; the subject-tracking demo |
| 33 | Newspaper Explosion | headline text, column blocks, rule lines | headlines expand (scale), break apart (per-word scatter), columns slide | — | — | typography + columns |
| 34 | VHS Dream | timestamp overlay, tracking-error bands, analog distortion, retro type | tracking errors (seeded band jumps), timestamp tick, distortion wobble (sine offset) | — | — | procedural VHS chrome; distortion via CI displacement if cheap, else Metal spike |
| 35 | Optical Illusion | geometric pattern groups, impossible shapes, perspective text | pattern animation (rotation/loop), text interacts (moves with the pattern phase) | — | — | procedural geometry |
| 36 | Blueprint World | construction lines (paths), measurement labels, diagram shapes, dimension arrows | draw-on (path progress), assemble (staggered line draws), measurements appear | — | — | procedural linework |
| 37 | Kinetic Sculpture | rotating geometric objects (3D-ish shapes), text on paths | rotation (loop), complex paths, shape/text interaction | — | — | procedural 3D-ish shapes (2.5D transforms, not a 3D engine) |
| 38 | Mirror World | mirrored text copies, reflection gradient, symmetry groups | split into reflections (scale Y −1 + fade), mirrored transitions | — | — | reflection via transform + mask |
| 39 | Living Typography | organic letter nodes (per-character), branch shapes, growth paths | grow/stretch/branch/pulse (spring + scale envelopes, seeded variation) | loudness (growth rate) | — | procedural organic shapes |
| 40 | Reality Distortion | distortion-wave overlay, bent text | distortion waves move through the frame (displacement keyframes), words push/pull the image | onset (wave on accent) | — | **Metal-spike candidate** (displacement is a shader job; CI fallback is a coarse warp) |

**What the table proves:** the five demos (★) each need a different engine capability — physics
integration (6), particle/drift/dissolve scene (1), nested panel groups (24), HUD/interface
composition (11), semantic-driven visuals (21). No two demos share a rendering approach. The
remaining 35 each add at least one capability the demos do not already prove (audio automation,
subject tracking, displacement shaders, data visualisation, 2.5D transforms), which is why the
mapping — not the demo count — is the coverage proof.

---

## 18. Updated phase plan

Per Jaizon's direction (2026-11-13 ~01:10 MST): **build all 40 in one continuous run. Do not stop
after 5 for a device test. Load time is acceptable.**

### Phase 2 — Core engine

- Registry + catalog metadata bridge (`getExtraStyleCatalog`).
- Scene graph types + `buildScene` protocol + the five demo definitions as the first registry
  entries (their scene builders are the reference implementations for the other 35).
- Animation engine: keyframes, easing, analytic springs, deterministic physics (fixed-step),
  stagger, path, loop, particle emitters, seeded RNG.
- Renderer: `ExtraStylesCompositor` (Core Image / Core Text) + the Look grade folded in; preview
  integration (§6.3); export integration — direct-attachment prototype first, transcode-slot
  fallback (§6.4); Metal spike for particle + distortion nodes (§6.5).
- Parameter schema + generated controls + `updateExtraStyleParams` (no-rebuild updates).
- Persistence: `Project.extraStyle` + migration mechanism + legacy-v1 coexistence (§14–§15).
- Lyric intelligence v2: interpretation artifact (sections, extended semantic tags) + fallbacks.
- Audio automation v1: `prepareAudioAutomation` (onset, beat grid, band energies, loudness curve)
  + confidence gating + fallbacks.
- Vision spike: person segmentation + face detection precompute, mask cache, "text behind person"
  in one demo-adjacent prototype (not a shipped style yet — the spike proves the mechanism).
- Catalog UI shell: the Extra Styles section (§12) with the five demos wired end to end.
- Tests: Node tests for the pure-TS halves (schema, interpretation, mapping, persistence);
  contract tests pinning the bridge payload shapes; CI is the Swift gate, as always.
- **Exit criterion:** the five demos render in preview and export from the same evaluator, params
  update without a rebuild, and a project with a 2.0 style saves and reopens correctly. No device
  test gate — the run continues into Phase 3.

### Phase 3 — Creative expansion (all 40, one continuous run)

- Build the remaining 35 styles in the brief's group order (Cinematic rest, Typographic rest,
  Digital, Design, Playful, Music, Experimental), each as a scene builder + parameters + catalog
  entry, reusing the Phase 2 engine. No per-style architecture work — styles are data + builders.
- The five demos are the first five built (brief order: Typography Physics, Dream Sequence, Comic
  Book, Holographic Interface, Emoji Storytelling) — they are the start of the run, not a gate.
- Batching: land styles in groups (a group per commit, or a few groups per commit — the
  implementer's call), each batch green through the local gate + CI Swift gate before the next
  batch starts. A failed batch is fixed in place; the run does not stop for a device verdict.
- **Exit criterion:** all 40 styles render in preview and export from the same evaluator; each
  has its parameters; the catalog, search, favorites, and card previews work; projects save and
  reopen with any of the 40.

### Phase 4 — Polish

- Animation quality pass (easing, timing, and feel per style, against device recordings).
- Visual composition pass (spacing, hierarchy, legibility at 540×960 and 4K).
- Customization pass (parameter ranges, presets, layer editing where declared).
- Performance pass (profiler numbers per style; Metal adoption per node where the spike justified
  it; cache tuning).
- Export-consistency pass (preview-vs-export comparison per style — the Stage 4 parity discipline
  applied to the new engine; pixel-level proof is still only settleable by Jaizon's device test).
- Style previews pass (card-preview budget, cache behaviour).
- Mobile editing experience pass (control layout, sheet behaviour, reachability).
- **Exit criterion:** the brief's §20 acceptance criteria, verified on device by Jaizon.

### Build and verification rhythm (all phases)

- Local gate before every commit: `npx tsc --noEmit`, `npx expo lint` (exit code), the Node
  suites, `npx expo export --platform ios`. Swift is never compiled locally — CI is the Swift
  gate (GitHub Actions workflow `build-unsigned-ipa.yml`, manual dispatch, `overhaul` branch).
- Deliver builds as consolidated IPAs with a bare-URL install link (the 2026-11-12 lesson: markdown
  link lines get dropped — send the bare URL and verify the delivered message contains it).
- Device verdicts: Jaizon's iPhone test is the only proof for visuals, performance, and feel.
  Nothing in this plan claims a visual result sight-unseen.

---

## 19. Open questions (what this audit could NOT settle)

1. **Metal vs Core Image at 4K60.** Unknown until the §6.5 spike measures on the iPhone 17 Pro
   Max at the export canvas. Core Image may hold for 35 styles and fail for 5 (particle-heavy,
   distortion-heavy). The plan does not pick a winner — the spike does.
2. **Direct export-composition attachment.** Unknown whether `ExtraStylesCompositor` can ride the
   export composition alongside the animation tool in one `AVAssetExportSession` pass. The
   transcode slot is the proven fallback (§6.4). The prototype decides.
3. **Vision segmentation quality and cost on Jaizon's footage.** Unknown until the Phase 2 spike
   runs on his takes (moving subject, stage lighting, fast cuts). Mask rate (2 fps proposed),
   storage size, and interpolation quality are all spike outputs, not design decisions.
4. **Beat detection accuracy across his songs.** Onset/tempo algorithms vary by genre (dense
   electronic vs sparse acoustic). The confidence gating (§9.2) is designed for this, but the
   actual confidence distribution is unknown until the prototype runs on his library.
5. **Animated card-preview budget.** Resolution / fps / cache size for 40 live card previews
   (§12.2) trades against first-open load time and disk. Proposed starting point (540×960 @ 15 fps,
   3 s, cached) needs device measurement. **DECISION for Jaizon** if the prototype shows the
   budget is too high: fewer live previews (featured + visible only) vs lower resolution.
6. **Syllable timing for Rhythm Typography (#29).** Word timings exist; syllable timings do not.
   The proposed vowel-group heuristic is approximate. Whether it feels right is a device verdict;
   true syllable timing would need a phoneme-level model the project does not have.
7. **Verse/chorus detection reliability.** Repetition analysis works when choruses repeat
   verbatim; it degrades on songs with varied choruses or no repetition. The confidence field
   exists for this; the actual distribution is unknown until run on his library.
8. **Particle/element budgets per style.** The per-emitter caps (§13.1) need device numbers. The
   plan proposes caps exist; the numbers come from the profiler in Phase 2.
9. **Whether the five demos' scene builders are the right reference implementations.** They are
   the plan's claim, not a proven fact — Phase 2 will show whether the builder API survives
   contact with five genuinely different scenes, and the API should be revised then, before the
   remaining 35 are built on it.

---

## 20. Acceptance criteria (brief §FINAL, mapped)

| # | Criterion | Where it is met |
|---|---|---|
| 1 | Extra Styles architecturally independent from Traditional Lyrics | §2 (contract), §3–§8 (separate layers), §14 (separate project field) |
| 2 | At least 40 genuinely distinct styles | §17 (capability mapping — each style needs different engine features) |
| 3 | Each style has its own visual composition | §4 (scene graph) + §17 (per-style elements) |
| 4 | Each style has meaningful customization controls | §8 (parameter schema, per-style declarations) |
| 5 | Multiple animated layers can interact | §4 (nested groups, blend modes, masks, z-order) |
| 6 | Typography animates at character, word, phrase, and sentence levels | §4.2 (four granularities), §5.2 (per-char/word tracks), §7.1 (phrases/sentences) |
| 7 | Audio-reactive animation works where supported | §9 (automation artifact + confidence gating) |
| 8 | Subject-aware effects work where supported | §10 (Vision precompute + fallbacks) |
| 9 | Preview and export render identically | §6 (one compositor, one evaluator, both homes) + Phase 4 parity pass |
| 10 | Projects save and reopen correctly | §14 (persistence + migration + fallbacks) |
| 11 | The native iOS renderer performs smoothly | §13 (budgets, caching, profiling) + §6.5 (Metal spike) |
| 12 | Existing recording, editing, synchronization, and export features remain functional | §1.5–§1.6 (export/preview flows untouched), §2.5 (separate failure domains), §15 (v1 kept working) |

---

## Appendix — file index (audit sources)

- Traditional lyrics: `src/lib/lyrics.ts`, `src/lib/lyricFonts.ts`, `src/lib/lyricAnimations.ts`,
  `src/types.ts` (`LyricLine`, `LyricStyle`, `ProjectLyrics`), `src/components/LyricsPanel.tsx`,
  `src/components/LyricsOverlay.tsx`, `modules/mvmt-whisper/`, `src/lib/whisper.ts`,
  `src/lib/songLibrary.ts`.
- v1 Extra Styles: `src/lib/lyricTemplates.ts`, `docs/STYLES-REDESIGN.md`,
  `docs/STYLES-PARITY.md`, `src/store/StudioContext.tsx` (`setLyricTemplate`, line 753).
- Compositor: `modules/mvmt-compositor/ios/MvmtCompositorModule.swift`
  (`buildComposition` 1002, `LookVideoCompositor` 219, `render` 4989, `transcodeVideoFile` 5566,
  `transcodeAttempt` 5624, `makeAnimationTool` 1580, `addLyricLayers` 2516, bridge registrations
  8796–8916), `modules/mvmt-compositor/src/index.ts`, `src/lib/compositor.ts`.
- Preview/export: `src/components/NativePreview.tsx`, `src/app/project/editor.tsx`,
  `src/app/project/export.tsx`, `src/lib/edl.ts`, `src/lib/editModes.ts`.
- Audio: `src/lib/analysis.ts`, `src/lib/loudness.ts`, `src/lib/waveform.ts`,
  `src/lib/mixMasterCurve.ts`, `src/lib/mixMaster.ts`, `src/lib/autoEq.ts`.
- Storage: `src/lib/persistence.ts`, `src/store/StudioContext.tsx`, `src/types.ts` (`Project`).
- Programme docs: `docs/IMPLEMENTATION.md`, `docs/EDIT-MODES.md`, `docs/MIX-MASTER.md`,
  `docs/STYLES-REDESIGN.md`, `docs/STYLES-PARITY.md`.
