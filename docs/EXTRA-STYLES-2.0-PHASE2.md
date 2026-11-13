# Extra Styles 2.0 — Phase 2 (core engine)

Status: **built, local gate green, committed on `overhaul` (not pushed)**.
Swift is never compiled locally — **CI is the Swift gate**; the first CI
build after this commit is the first real Swift compile of this code.

Phase 2 is the engine ONLY. No Phase 3 style exists yet: the registry
holds exactly one definition, the internal harness style `__harness`
(not one of the 40, never shown in the UI). The five demos and the
remaining 35 styles are Phase 3.

## What was built

### TypeScript side — `src/lib/extra-styles/` (pure TS, no RN/Expo imports except `bridge.ts`)

| File | What |
| --- | --- |
| `types.ts` | Bridge/engine versions, param schema + value types, `ExtraStyleMetadata`/`ExtraStyleCatalog`, `ExtraStyleState` (the `Project.extraStyle` shape — defined here because `src/types.ts` is owned by another workstream), `ExtraStyleCapability` + `ENGINE_CAPABILITIES` (34 capabilities), `AudioAutomation`, `LyricInterpretation`, scene-build input types, `SubjectMaskIndex`. |
| `animation.ts` | The evaluator math spec, ported exactly to Swift: splitmix64, easings (incl. cubic-bezier), keyframe interpolation, analytic springs (3 regimes), closed-form particles, arc-length path sampling. |
| `params.ts` | `defaultParams`, `resolveExtraStyleParams` (unknown dropped, invalid → default + dropped, numbers clamped + step-snapped + float-dust rounded), `applyExtraStylePreset`, `paramsNeedSceneRebuild` — rebuild iff a changed param has `affects: 'layout'` OR is in the style's `rebuildParamIds`; density/motion/appearance swap values with no rebuild. |
| `interpretation.ts` | Semantic-tag dictionary (19 concepts), `analyzeSemanticTags`, `lyricsHash`, `detectSections` (longest repeated ≥2-line block = chorus), `buildLyricInterpretation`, syllable splitter (vowel-group heuristic). |
| `catalog.ts` | `STYLE_CAPABILITY_MAP` — all 40 styles with id/name/category/capabilities/audio/subject flags; 5 demos flagged; search/filter/favorites-first sort. |
| `automation.ts` | Sampling only (never analysis): onset, band energies, loudness, confidence-gated beat phase (threshold 0.5, onset fallback). |
| `persistence.ts` | `validateExtraStyleState` (same version → as-is; older → migrate + defaults; newer/unknown → null + notice) and the v1 migration — see §V1 retirement below. |
| `scene.ts` | `buildExtraStyleSceneInput` (song frames → composition frames, clamp, drop lines entirely outside) and `deriveExtraStyleSeed`. **The emoji rule: stored intelligence (emoji/tone/emphasis) is copied into the scene input UNCONDITIONALLY — the builder takes no template flag; a line with an emoji ALWAYS produces a payload line with that emoji, for ANY style.** |
| `bridge.ts` | Domain wrappers over the native surface: catalog, prepare scene, update params, audio automation, subject masks, preview frame, release, profile, Metal benchmark. Availability-gated, never rejects where a fallback exists. |
| `index.ts` | Barrel (note: importing it pulls in `bridge.ts` → the Expo module; the Node test bundle imports the pure modules directly, never the barrel). |

### Module bridge surface — `modules/mvmt-compositor/src/index.ts`

`CompositeRequest.extraStyleSceneHandle` + `ExtraStyleSceneBuildInput`
types + 9 native functions with wrappers:
`getExtraStyleCatalogJson`, `prepareExtraStyleSceneNative`,
`updateExtraStyleParamsNative`, `prepareAudioAutomationNative`,
`prepareSubjectMasksNative`, `renderExtraStylePreviewFrameNative`,
`releaseExtraStyleSceneNative`, `getExtraStyleProfileJson`,
`benchmarkExtraStyleNodesJson`. All follow existing conventions
(availability checks, never-reject fallbacks).

### Swift side — `modules/mvmt-compositor/ios/`

| File | What |
| --- | --- |
| `ExtraStylesCompositor.swift` (~3,185 lines) | Helpers (own `extraStyleError`/`extraStyleAvTry` — the module's are file-private), bridge records, scene graph (§4), animation engine (§5, exact TS port), registry + harness style (§3), prepared scenes + compositor store + profiler (§6.6/§6.7/§13.1), evaluator (§5.1), scene renderer (§6.2), `ExtraStylesCompositor` (§6), engine entry points (§9). |
| `ExtraStylesAudio.swift` | Beat/onset/band/loudness analysis (§9): one decode + one FFT pass, cached per song. |
| `ExtraStylesMasks.swift` | Vision precompute (§10) + the runtime mask provider. |
| `ExtraStylesMetalSpike.swift` | The §6.5 benchmark (§Metal spike below). |

### Tests — `tests/extra-styles.test.cjs` + `test:extra-styles` script in `package.json`

**25/25 green.** Coverage: splitmix64 reference vectors + determinism;
easings/keyframes; springs (start/settle + RK4 agreement); particle
purity/liveness; path sampling; params (defaults/clamp/snap/invalid/
presets/rebuild rule); semantic tags; sections; hash; syllables; catalog
(40 styles, 5 demos, full coverage, every claimed capability used by
≥1 style); search/filter/favorites/internal-hidden; automation sampling
+ beat gating; persistence validation + v1 migration (incl. a synthetic
catalog proving successor mapping); scene frame mapping/clamping;
**the emoji test: for `dream-sequence`, `emoji-storytelling`,
`typography-physics`, `comic-book`, a line with emoji ❤️ ALWAYS yields
a payload line with that emoji — no gate may swallow it**; seed stability.

## How the engine is wired in

- **Preview:** `buildComposition` resolves the scene handle; a live
  scene installs `ExtraStylesCompositor` on the plain EDL composition
  (replacing `LookVideoCompositor` when both are present — the scene
  compositor folds the grade in via `ExtraStyleCompositorStore`,
  grade first, then the scene, §6.2). `PreviewStore.create` calls
  `buildComposition(request, forExport: false)`, so the scene flows
  through `createPreview` automatically.
- **Export:** the handle travels as
  `BuiltComposition.pendingExtraStyleSceneHandle` and is applied in
  the post-render transcode (`transcodeAttempt`'s
  single-instruction composition, where a custom compositor + the
  animation tool already combine freely). `render()` forces the
  transcode when a scene is pending and picks the transparent bitrate
  (same 0.22 bits/px-frame rule as grade-only) when no size was set.
  The repair ladder needs no special handling — the scene rides the
  later transcode from the original build.
- **Bridge:** 9 AsyncFunctions registered after `releasePreview` in
  `MvmtCompositorModule.swift`, calling the new Swift entry points.
  One narrow internal surface was added to that file,
  `ExtraStyleEngineSupport` (URL resolution + the Look grade
  forwarders) — `MvmtCompositorEngine` itself is file-private, so
  the two calls the scene compositor needs are forwarded rather
  than widening the whole engine.

## Metal spike (§6.5) — implemented, device measurement pending

`ExtraStylesMetalSpike.benchmarkJSON()` (via the bridge
`benchmarkExtraStyleNodes`) measures, on device, at 2,000 particles:

- **Core Image:** the REAL renderer over a spike scene (500/s emitter,
  4 s lifetime → 2,000 alive particles at frame 120) for the particle
  field, plus `CIDisplacementDistortion` on a full 1080×1920 frame for
  the distortion wave. Median of 30 runs each, forced through a
  `CIContext` render into a pixel buffer (not just graph building).
- **Metal:** a compute kernel updating 2,000 particles + a point-sprite
  render pass (same soft-circle sprite, acid-lime tint), and a
  fullscreen distortion fragment shader — median of 30 runs each,
  `waitUntilCompleted`.

Verdict rule (§6.5): adopt Metal per-node only on a **≥2× win**, or
when Core Image cannot hold 30 fps for the combined node. The JSON
reports `ciParticleMs`, `ciDistortionMs`, `metalParticleMs`,
`metalDistortionMs`, both speedups, `ciHolds30fps`, and `verdict`
(`"metal"` / `"core-image"`).

**No numbers yet.** The spike needs a device (Jaizon's iPhone) or a
simulator run through the app — this environment has no iOS runtime,
and CI is a build gate, not a benchmark harness. Run
`runExtraStyleMetalBenchmark()` on device and record the numbers here
before any Phase 4 Metal adoption. On a build without Metal it returns
the CI baseline + a note and the verdict is Core Image.

## Deviations from the audit doc (with reasons)

1. **Export via the transcode slot, NOT direct attachment** (§6.4
   preferred direct attachment, flagged unproven alongside the
   animation tool in one `AVAssetExportSession` pass). Since Swift
   can't be compiled or device-tested from here, Phase 2 wires the
   PROVEN path: preview = direct attachment (proven pattern);
   export = the scene travels as `pendingExtraStyleSceneHandle` and
   is applied in the post-render transcode (single-instruction
   composition, where a custom compositor + animation tool already
   combine freely). Cost: one extra reader→writer pass on 2.0
   exports (accepted by the doc). The compositor class is the same
   either way, so switching to direct later is a one-line change in
   `buildComposition` + removing the transcode forcing in `render()`.
2. **Band energies are STFT bin-summed per band** (§9.2's literal RBJ
   filter bank), in the SAME single FFT pass, using Auto EQ's 10 band
   edges. Cheaper, one pass, same band definitions; per-band
   normalisation makes the two agree on what a "band" is.
3. **Layer loop duplicated, not refactored:** `ExtraStylesCompositor`
   copies `LookVideoCompositor`'s layer-compositing loop (~80 lines)
   rather than extracting a shared helper — touching the proven
   compositor without a local Swift compile is the bigger risk.
   Phase 4 cleanup candidate.
4. **Static-subtree raster cache deferred to Phase 4:** glyph cache
   (colour-free layouts) + lazy sprite cache are implemented (§6.7);
   full subtree rasterization is not. The evaluator already marks
   static nodes via `isStatic`, so the hook exists; the profiler will
   say when it's needed.
5. **Face boxes are parsed/stored at prep; per-frame face-aware
   positioning lands with the Phase 3 styles that need it**
   (Surveillance System, Virtual Reality) — the mechanism (mask
   provider + `faceBoxes(at:)`) exists.
6. **Param bindings, not rebuilds (§8.2):** tracks/content carry
   optional param references evaluated per frame — `paramScale`,
   `enabledParamId`, loop `periodParamId` (period = periodFrames /
   speed), emitter `rateParamId` × multiplier + `colorParamId`,
   text/shape/gradient `colorParamId(s)`. Glyphs are laid out
   colour-free (no `.foregroundColor` in the attributed string;
   colour set in the context at draw time), so colour changes never
   stale the glyph cache. Rebuild happens ONLY for structural params
   (the style's `rebuildParamIds` + `affects: 'layout'`). The TS
   `paramsNeedSceneRebuild` was updated to match: **density alone
   does NOT rebuild** (the emitter binding covers it).
7. **The harness's emoji node is unconditional** (see §Emoji Story
   below) and the harness always adds its emitter node — even at
   rate 0, the evaluator expands no particles — so a project saved
   at density 0 regains its field when the slider rises, with no
   rebuild.

## V1 retirement (Jaizon, 2026-11-13 ~01:25 MST)

**RETIRE all 30 v1 templates when 2.0 ships.** The audit's "keep as
legacy / Classic Extra Styles" proposal is superseded: no "Classic
Extra Styles" legacy section is built, and the v1 rendering path is
NOT preserved as a supported mode. (Whether the v1 rendering code
itself gets deleted is a Phase 3/ship-time cleanup, not Phase 2.)

Migration (`src/lib/extra-styles/persistence.ts`,
`migrateV1Template`): a project storing a v1 `templateId` maps to its
2.0 successor where one exists, otherwise to classic lyrics (no
template) — with a notice, never a crash. The 15 deliberate rebuilds:
`emoji-story`→`emoji-storytelling`, `comic-book`→`comic-book`,
`hologram`→`holographic-interface`, `neon-sign`→`neon-sign-world`,
`chat`→`message-universe`, `text-message-typing`→`message-universe`,
`magazine`→`editorial-magazine`, `retro-tv`→`vhs-dream`,
`sticker-pop`→`sticker-world`, `word-explosion`→`typography-explosion`,
`scrapbook`→`memory-fragments`, `cyberpunk`→`cyber-terminal`,
`split-screen-words`→`parallel-worlds`,
`big-bold-billboard`→`brutalist-typography`,
`typewriter-classic`→`cyber-terminal`. Unlisted v1 ids → classic +
notice. A successor applies ONLY when it exists in the registry — in
Phase 2 only the harness exists, so everything maps to classic until
Phase 3 registers the styles. Emoji Storytelling and Comic Book are
2.0 rebuilds, not replacements — no special-casing.

## Emoji Story acceptance criterion (Jaizon, 2026-11-13 ~01:26 MST)

In the v1 Emoji Story template Jaizon **never saw a single emoji** —
the v1 emoji-display path was broken or gated off (the payload carried
the emoji only when a template was active, `src/lib/lyrics.ts:747`,
and both renderers displayed it only for Emoji Story; evidently that
chain never delivered a visible emoji on his phone). The music notes
on the "[upbeat music]" lines were NOT Emoji Story emojis.

The 2.0 Emoji Storytelling demo is a full rebuild and **must NOT
inherit this failure**. The engine side is designed so it can't:

- The scene-build payload carries the emoji **unconditionally**
  (no template flag anywhere in the chain — `scene.ts`, the bridge
  records, `ExtraStyleInputLine.init(record:)`, the harness's emoji
  node). A line with an emoji ALWAYS produces a payload line with
  that emoji, for ANY style.
- The harness renders an emoji node (spring pop, no gate) whenever
  the payload line has one.
- The TS test pins the payload side (a line with ❤️ yields a payload
  line with ❤️ for four styles, including `emoji-storytelling`).

**Phase 3 acceptance check (must pass before Emoji Storytelling
counts as done):** prove emoji visible end-to-end — stored
intelligence → scene → preview AND export — on Jaizon's phone, with a
line whose stored emoji is known. If any gate in the Phase 3 style
could silently swallow the emoji, that gate needs a test that fails
when the emoji is missing. Jaizon: "Hopefully fixed in 2.0."

## Integration steps left (for after the Edit-screen consolidation lands)

The `Project.extraStyle` field wiring and editor UI wiring were
deliberately left out (the owning files belong to another workstream).
Exact steps, with current line numbers (branch `overhaul`, HEAD
`e174d2a`):

1. **`src/types.ts`** — add `extraStyle?: ExtraStyleState` to the
   `Project` interface (starts line 369; the interface ends at
   `exportedAt?: number;`, ~line 465). Import the type from
   `src/lib/extra-styles/types.ts`. Place it beside `look?` — it is
   the same kind of per-project creative choice.
2. **`src/store/StudioContext.tsx`** — add `setExtraStyle` /
   clear, following the `setProjectLook` pattern (line 846) and the
   `patchActiveProject` helper (line ~403); expose it in the context
   interface beside the other setters (lines 167–259). Persistence
   is the existing debounced `saveProjects` (line ~394) — no new
   persistence code. At load (line ~369,
   `setProjects(cleanStoredLyrics(loaded.projects))`), run
   `migrateV1Template` for a stored v1 `templateId`
   (`ProjectLyrics.templateId`, `src/types.ts:328`) and
   `validateExtraStyleState` for stored 2.0 state (both in
   `src/lib/extra-styles/persistence.ts`).
3. **`src/app/project/editor.tsx`** — the preview request
   (`edlToCompositeRequest`, lines ~852–862) gains
   `extraStyleSceneHandle`: prepare the scene on style select
   (`prepareExtraStyleScene`), call `updateExtraStyleParams` on
   param change, and rebuild `previewKey` (line ~864) only on style
   switch — param changes must NOT restart playback.
4. **`src/app/project/export.tsx`** — the shared request
   (`useMemo`, lines 225+) gains `extraStyleSceneHandle`; the Export
   screen shows scene preparation state (wait, or export without the
   scene — never a silent stall). `renderVideo` (line 358) needs no
   change — it takes the same request object.
5. **New screen `src/app/project/extra-styles.tsx`** (Phase 3 UI):
   categories/search/favorites/recent/featured + animated card
   previews (`renderExtraStylePreviewFrame`, 540×960 @ 15fps
   proposed) + generated controls from the parameter schema.

## What remains for Phase 3

- All 40 styles in one continuous run (five demos first: Typography
  Physics, Dream Sequence, Comic Book, Holographic Interface, Emoji
  Storytelling — **NO stop after 5 for a device test**, per Jaizon
  2026-11-13 ~01:10 MST), each as scene builder + parameters +
  catalog entry. Load time for the new lyrics/styles is acceptable.
- **Emoji Storytelling acceptance** (above) — prove emoji visible
  end-to-end in preview AND export before it counts as done.
- Catalog UI shell (§12), card previews with the bundled sample
  clip, layer editing where declared, bundled asset pack.
- Phase 4 polish: animation quality, composition, customization,
  performance (profiler numbers per style; Metal adoption per node
  where the spike justified it), export-consistency parity pass,
  mobile editing experience.

## Things to verify on device / in CI (not provable from here)

- **CI is the Swift gate** — this code has never been compiled.
  Watch the first CI build for: the vDSP classic-API calls
  (`ExtraStylesAudio.swift`), the Metal library source string
  (`ExtraStylesMetalSpike.swift`), the Vision request setup
  (`ExtraStylesMasks.swift`), and the 9 new AsyncFunction
  registrations (record-type bridging for
  `ExtraStyleSceneBuildInputRecord`).
- **Preview/export parity for a 2.0 scene** — the harness style is
  the vehicle: prepare it on a project with real lyric lines, play
  the preview, export, and compare. The renderer is one class for
  both, but the plumbing differs (direct attachment vs transcode).
- **Beat grid quality** — the tempo DP is a heuristic (autocorrelation
  + octave correction + 4/4 downbeat assumption). Judge it on real
  songs; the confidence gate (0.5) is the safety net, and the onset
  envelope is the fallback.
- **Mask precompute time** — Vision `.accurate` segmentation at 2 fps
  is the slowest Phase 2 operation (a 60 s take is ~120 frames).
  Measure it on device; if it is too slow for the "honest progress"
  bar, `.balanced` is the documented fallback.
- **Metal spike numbers** — run `benchmarkExtraStyleNodes` on device
  and record them here (see §Metal spike).
- **The harness is internal** — it must never appear in the catalog
  UI (`internal: true` in the catalog JSON; `userVisibleStyles`
  filters it out). If it ever does, the catalog filter regressed.

## Local gate (run before this commit)

- `npx tsc --noEmit` — exit 0
- `npx expo lint` — exit 0 (1 pre-existing warning in
  `src/lib/editModes.ts`: unused `secondsToFrames` — not this work)
- `npm run test:shuffle` 11/11 · `test:edl` 46/46 · `test:lyrics`
  73/73 · `test:looks` 16/16 · `test:library` 4/4 ·
  `test:mixmaster` 46/46 · `test:extra-styles` 25/25
- `npx expo export --platform ios` — exit 0
