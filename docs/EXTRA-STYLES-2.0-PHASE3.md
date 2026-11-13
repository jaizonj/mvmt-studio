# Extra Styles 2.0 — Phase 3 build record

Date: 2026-11-13. Branch `overhaul`. Phase 2 (core engine) is commit
`a59a38f`; this phase builds on it, in one continuous run, with no
device-test gate in the middle (Jaizon's explicit direction
2026-11-13 ~01:10 MST: "make the 40", load time acceptable).

## What was built

**All 40 styles, each its own scene builder, all registered.**

| File | Styles | Lines |
|---|---|---|
| `modules/mvmt-compositor/ios/ExtraStyleBuilders.swift` | shared builder helpers | ~650 |
| `modules/mvmt-compositor/ios/ExtraStylesDemos.swift` | 5 demos | 1,090 |
| `modules/mvmt-compositor/ios/ExtraStylesCinematic.swift` | 4 (Memory Fragments, Floating Universe, Film Credits Reimagined, Parallel Worlds) | 1,326 |
| `modules/mvmt-compositor/ios/ExtraStylesTypography.swift` | 4 (Liquid Letters, Infinite Tunnel, Portal Typography, Typography Explosion) | 1,017 |
| `modules/mvmt-compositor/ios/ExtraStylesDigital.swift` | 4 (Digital Corruption, Cyber Terminal, Virtual Reality, Data Visualization) | 1,258 |
| `modules/mvmt-compositor/ios/ExtraStylesDesign.swift` | 5 (Editorial Magazine, Brutalist Typography, Collage Explosion, Ink and Paint, Neon Sign World) | 1,307 |
| `modules/mvmt-compositor/ios/ExtraStylesPlayful.swift` | 3 (Cartoon Universe, Message Universe, Sticker World) | 780 |
| `modules/mvmt-compositor/ios/ExtraStylesMusic.swift` | 5 (Soundwave Typography, Beat Reactor, Frequency Universe, Rhythm Typography, Audio Energy World) | 1,300 |
| `modules/mvmt-compositor/ios/ExtraStylesExperimentalA.swift` | 5 (Glitch Reality, Surveillance System, Newspaper Explosion, VHS Dream, Optical Illusion) | 1,544 |
| `modules/mvmt-compositor/ios/ExtraStylesExperimentalB.swift` | 5 (Blueprint World, Kinetic Sculpture, Mirror World, Living Typography, Reality Distortion) | 1,172 |

`ExtraStylesPhase3.registerAll(into:)` (in `ExtraStylesDemos.swift`)
registers the 5 demos + the 8 group register functions; `ExtraStyleRegistry.init()`
calls it after the harness. Verified: 41 definitions (40 + harness),
no duplicate class names, no duplicate ids, every
`needsAudioAutomation` / `needsSubjectMasks` flag matches the TS static
map in `src/lib/extra-styles/catalog.ts` (`STYLE_CAPABILITY_MAP`) —
that map is authoritative, and `prepareScene` throws when a required
input is missing, so a mismatch would fail loudly instead of silently.

Parameter schemas per style (sliders / toggles / colours / segmented /
select / numeric / asset, per each style's §17 declaration), with
presets where declared. `rebuildParamIds` used where a param changes
layout (Cinematic: e.g. `["layout", "dissolve"]`; Design: `["columns"]`).

## Demo API verdict (audit open question #9)

**The Phase 2 builder API survived all five demos without an engine
change.** The only addition is the shared helpers file
(`ExtraStyleBuilders.swift`): scene-builder sugar, param-schema
builders, measured text/word/char node layout, spring/flicker/enter-exit
track helpers, fixed-step fall keyframes, counter nodes, face-box
tracks, shape + background-gradient helpers, tone colours + reaction
emoji sets. No change to the evaluator, renderer, registry, or bridge
was needed to build the demos — or the other 35. That is the coverage
proof the audit asked for.

Two API facts the demos established (now relied on by all 40):
- There is NO physics track kind — physics is baked at build time into
  keyframes (`extraStyleFallKeyframes`: fixed-step gravity simulation).
- `.path` tracks work ONLY on `.positionX` (absolute canvas-point
  positions); loop tracks' keys are written against the nominal period.

## Integration (Phase 2 steps, landed)

- `src/types.ts`: `Project.extraStyle?: ExtraStyleState` (beside `look?`).
  Convention: an empty `styleId` (`''`) is the favorites-only shell —
  hearted styles, none selected.
- `src/store/StudioContext.tsx`: `setExtraStyle` / clear +
  `patchActiveProject`, `updateExtraStyleParams`,
  `toggleFavoriteExtraStyle`, `extraStyleNotices` /
  `clearExtraStyleNotices`, `recentExtraStyleIds` (max 5) /
  `recordRecentExtraStyle`. Load runs the migration pass when the
  catalog is available (Expo Go: catalog null → stored v1 templates /
  2.0 state left exactly as-is). Stored 2.0 state is validated
  (unknown / newer-version drops with a notice). `recentExtraStyleIds`
  persists in `PersistedProjects`.
- `src/app/project/editor.tsx`: preview request spreads
  `extraStyleSceneHandle` from the new `useExtraStyleScene` hook
  (NOT by editing `edlToCompositeRequest` — that file is owned by
  another workstream; the spread is the documented deviation).
  `previewKey` unchanged: a style switch changes the key, a param
  change keeps it stable (native `updateParams` decides
  rebuild-vs-swap in place; the handle never changes on param edits,
  so previews never restart). "Extra Styles" collapsible section
  after Lyrics; failed state shows an honest note.
- `src/app/project/export.tsx`: shared request gains the handle;
  `handleRender` awaits `extraStyleScene.awaitReady()` when status is
  `'preparing'` and renders with the landed handle, else exports
  without the scene — never a silent stall. "Extra Style" state row
  next to Mix & Master.
- `src/app/_layout.tsx`: route `project/extra-styles`
  (`slide_from_bottom`). The typed-routes quirk fired as expected:
  tsc failed until the dev server regenerated
  `.expo/types/router.d.ts`.
- `useExtraStyleScene` (`src/lib/extra-styles/useExtraStyleScene.ts`):
  scene key = styleId/version, lyrics hash, offsetFrames,
  regionStartFrame, song URI, totalFrames, canvas, first take id,
  layers (params deliberately NOT in the key). Old handle released
  only AFTER its replacement lands; released on unmount. A song-less
  project yields status `'none'`, not `'failed'` — a scene needs a
  song (lyrics + automation key off it) and there is nothing to fail
  yet. The no-scene state reset happens during render (the
  render-time adjustment React endorses), the effect owns only the
  external handle release — this was a lint fix, see below.
- `prepare.ts` (`src/lib/extra-styles/prepare.ts`): `prepareProjectExtraStyleScene`
  (automation only when metadata asks — null → fail; masks only when
  asked — null/no first take → fail; never throws) and
  `prepareCardPreviewScene` (sample lines + synthetic automation AND
  mask index always supplied).
- `sample.ts` (`src/lib/extra-styles/sample.ts`, pure): `SAMPLE_CARD_LINES`
  (3 lines, 1s each, frames 0–30/30–60/60–90, each with emoji/tone/
  emphasis), `buildSyntheticAutomation` (120 BPM grid, beats at
  0–2.5s, downbeat every 4th, onset linear decay over 0.18s, 0.1s
  hop → 30 values, per-band breathing, loudness swell −18→−12,
  beatConfidence 1), `buildSyntheticMaskIndex` (takeKey
  `extra-styles-sample-clip`, 0.5s samples, one face box drifting
  ±4% on a full sine period, empty maskUris), `cardPreviewCacheKey`
  (FNV-1a32 of style + version + params), card geometry 540×960 @
  15fps, 3s / 90 scene frames.
- `cardPreviews.ts` / `sampleClip.ts`: `getExtraStyleCardPreview`
  (in-memory + in-flight dedup, disk index at
  `Paths.cache/mvmt/extra-style-card-previews.json`, LRU cap 8 with
  file deletion on eviction; never throws — null → static card face);
  `resolveSampleClipUri` via expo-asset (watermark pattern; null →
  cards fall back). New native `renderExtraStylePreviewClip` in
  `ExtraStylesCompositor.swift` + `MvmtCompositorModule.swift` +
  `modules/mvmt-compositor/src/index.ts` + `bridge.ts`:
  AVAssetImageGenerator base frame per output frame, scene rendered
  over it, AVAssetWriter H.264 (~4 Mbps), 150-frame cap, black
  fallback per bad frame, partial file removed on failure.

## Catalog UI shell (`src/app/project/extra-styles.tsx`, ~760 lines)

Header (back + Done), migration/validation notice banners
(dismissible), intro copy distinguishing scenes from subtitles,
search `TextInput`, category chips (All + 7), Featured (the 5 demos),
Recently used chips, FlatList of filtered styles (search + category +
favorites-first sort) with `onViewableItemsChanged` (50% threshold)
gating `VideoView` playback. `StyleCard`: 96×170 portrait preview,
name/tagline/category, heart, selected check badge; expands to preset
chips + schema-generated `ParamControl`s + "Remove style" when
selected. `ParamControl` by kind — slider (local drag state, commits
on `onSlidingComplete`, per LookPanel convention), number stepper,
toggle `Switch`, color (11 swatches), segmented
(`SegmentedControl`), select (`DropdownPicker`), asset (chips).
Selected card re-renders its preview on param change (params-key dep).
`useVideoPlayer(previewUri, { loop: true, muted: true })` with
play/pause on visibility. Honest Expo Go empty state when the catalog
is null ("Extra Styles need the native engine — this preview build
can't render them yet").

**Layer editing NOT implemented**: the catalog metadata carries no
layer schema in Phase 3, so no style declares editable layers —
Phase 4 item.

## Bundled asset pack + sample clip

- No new assets were added to `ExtraStyleAssetRegistry` — the three
  procedural assets already there cover the need:
  `paper-texture` (Memory Fragments ×2, Collage Explosion),
  `halftone-dots` (Collage Explosion, Newspaper Explosion),
  `comic-burst` (Comic Book demo, Collage Explosion). Collage
  Explosion — the most asset-dependent style — is covered by
  paper + halftone + burst + procedural sticker shapes. No generic
  stock, no new dependencies.
- `assets/extra-styles-sample-clip.mp4` (NEW, generated, ~20 KB):
  3.0s, 540×960, H.264. Procedural still (PIL): vertical gradient
  graphite→indigo, warm spotlight glow upper-centre, acid-lime floor
  glow, dark performer silhouette (head circle + shoulder ellipse,
  lime rim-light arc); ffmpeg zoompan slow push-in
  (`z='1+0.02*on/90'`, 90 frames @30fps). Still verified visually
  twice — first version's shoulders were a detached triangle (fixed
  to an overlapping ellipse); final reads as a person under a
  spotlight. A real performance clip can replace the file with no
  code change.

## Emoji Storytelling — end-to-end proof

Jaizon never saw a single emoji in the v1 Emoji Story. The 2.0
wiring is complete and tested here; pixel proof still needs his
phone.

- **Stored intelligence → scene input**: `scene.ts`
  `buildExtraStyleSceneInput` carries emoji/tone/emphasis/
  semanticTags UNCONDITIONALLY (no template flag anywhere in the
  path). Pinned by test `scene: stored intelligence crosses
  UNCONDITIONALLY` (4 styles incl. emoji-storytelling) and the new
  Phase 3 test `phase3 sample: card lines survive the scene-input
  passthrough with emoji` (all 3 card lines keep their emoji).
- **Scene**: `extraStyleEmojiNode` returns a node whenever the line
  has a stored emoji (nil ONLY when the line has none); the Emoji
  Storytelling builder puts a hero emoji node per line (float loop,
  tone-tinted radial backdrop, tone reaction bursts). Fallback to
  the tone's first reaction emoji ONLY when a line has no stored
  emoji — documented as distinct from the v1 bug (v1 showed
  nothing at all; the fallback is a deliberate design choice, not
  a gate).
- **Preview AND export**: the SAME `ExtraStylesCompositor` renders
  both (preview via `renderPreviewFrame`, export via the transcode
  slot — direct attachment deferred as unproven in Phase 2). Card
  previews render the real composition over the sample clip.
- **Tests that fail when the emoji is missing**: the two tests above
  assert `emoji` is present on the payload line; `phase3 sample:
  card lines cover the 3s card` asserts every card line carries an
  emoji. If any gate in the chain swallows an emoji, these fail.
- **Still needs Jaizon's phone**: pixel proof that the emoji is
  actually visible in preview and in an exported file (the v1 bug
  was in the display path, and no local run can render the native
  compositor). Device-test requirement: pick Emoji Storytelling,
  Detect lyrics on a song, confirm an emoji appears over the video
  in the editor preview AND in the exported file.

## V1 retirement

Jaizon decided 2026-11-13: RETIRE all 30 v1 templates when 2.0
ships. `migrateV1Template`'s 15 deliberate successors now resolve
against the full 40-style catalog — proven by test `phase3 v1: all
15 successors resolve against the full 40-style catalog` (catalog
built from `STYLE_CAPABILITY_MAP`; every successor id found,
notice mentions retirement). Everything else → classic lyrics +
notice, never a crash (also tested). No "Classic Extra Styles"
legacy section was built. The migration runs one-shot at load and
clears `templateId` either way, so it never re-runs.

## Deviations from the plan / engine limits found

Per-family notes (also in each file's header):

- **Playful**: no path-trim / draw-progress track kind — Cartoon
  Universe motion lines reveal with an opacity envelope instead.
  No rounded-rect shape kind — bubbles use a `CGPath` rounded rect
  as a `.path` shape. No sticker art in the registry — stickers are
  procedural shapes (star/heart/bolt/circle/rounded-rect) with white
  stroke + shadow layer; the `sticker-world` catalog capability
  lists `images` but the style uses none. Self-caught bug fixed
  during writing: Message Universe's group opacity track originally
  faded from 0 at line start, hiding the typing dots — group now
  stays at opacity 1.
- **Design**: no path-progress track — Ink strokes reveal with an
  opacity envelope, not a true draw-on. No node blur/glow property
  — Neon glow is layered text copies (larger, low-opacity,
  `.screen`) + a radial halo gradient. Node scale is a uniform
  CGFloat — the Neon reflection cannot be a true vertical flip
  (1, −1); it is a smaller, faded copy under a gradient fade band.
  No layout keyframes — Editorial "dynamic wrap" swaps between two
  precomputed layouts (single-column ↔ two-column) with an opacity
  crossfade at the line midpoint. No step/hold easing — Brutalist
  hard cuts are adjacent keyframes 1 frame apart (linear).
- **Experimental B**: same uniform-scale limit — Mirror World fakes
  its reflection with a smaller, faded copy under a darkening wash;
  a true vertical flip needs non-uniform scale or a
  perspective-corner flip (Phase 4). No path-progress — Blueprint
  World's draw-on is staged opacity per construction line plus a
  draw-head dot travelling the frame on a `.path` track (which works
  only on `.positionX` — it drives both axes). Perspective groups DO
  exist (Kinetic Sculpture uses one for its 2.5D tilt). Displacement
  nodes DO exist (Reality Distortion uses one; see Metal note).
- **Experimental A**: Glitch Reality + VHS Dream use the engine's
  displacement nodes (`CIDisplacementDistortion` path). A per-node
  Metal displacement shader is a Phase 2 spike candidate — adopt
  only on a measured ≥2× win; NO Metal work attempted here.
- **Typography / Music**: the only fallback in the audio styles is
  the beat-confidence gate — `beatPhase(at:)` is nil below 0.5
  confidence, so builders fall back to the onset envelope there,
  never to a missing-automation case (automation is always supplied
  at build time for styles that need it).
- **Cinematic**: Film Credits letter-spacing is faked per character
  (the engine has no tracking knob). **Parallel Worlds ships with
  scene-side mirroring only** (mirrored text groups + divider +
  beat-phase world switch) — the mirrored-footage second-video-layer
  plumbing is DEFERRED to Phase 4 as too risky without a Swift
  compile. **Dream Sequence's subject-mask glow is dropped** — its
  catalog entry has `needsSubjectMasks: false`, so masks are never
  present; the subject-mask capability is genuinely used by
  Surveillance System + Virtual Reality (+ Memory Fragments face
  avoidance).
- **Demos**: Holographic Interface HUD panel section rewritten once
  (dead helpers removed); Comic Book burst image node scaled
  `burstSize / 512` (asset is 512×512); floor path rewritten to
  positive local coords (anchor math shifts negative-coord paths);
  Emoji Storytelling inputs fixed to `["lines", "intelligence"]`
  (`semantic-tags` is not a valid `ExtraStyleInputKind`).

Integration deviations:
- `edlToCompositeRequest` NOT edited — the extra-style handle reaches
  the preview/export requests via spread, not an `edl.ts` change.
- Card previews render as **looping mp4s via a new native function**,
  not PNG frame flippers (the Phase 2 doc's proposal) — one small
  H.264 file per style, played with expo-video.
- The native `updateParams` rebuild path passes `layers: [:]` — **layer
  overrides are dropped on a native rebuild**. No UI sets layers in
  Phase 3, so nothing is lost today; Phase 4 item.
- `src/lib/extra-styles/index.ts` exports `sample` (pure) only — it
  does NOT export `prepare` / `cardPreviews` / `sampleClip` /
  `useExtraStyleScene` (they pull in the native bridge).

Additional engine limits from the category builders' full reports
(all verified against the engine source, not assumed):

- **Typography**: loop `periodParamId` reads only numeric *params*,
  never automation — tempo/loudness can only drive loop speed by
  baking it into `periodFrames` at build time (Tunnel) or via
  reaction-track amplitude (Liquid). A live loudness-driven loop
  period needs an engine change. Shape stroke colours and
  gradient-stop alphas have no live param binding (stroke is baked;
  `fillColorParamId` re-resolves to alpha 1), so accent-colour
  changes on rings/strokes/blobs need a rebuild. Displacement nodes
  distort the whole composed frame (video included), not just the
  text — Liquid's warp is deliberately modest (scale 0–12,
  toggleable) but Phase 4 should confirm on-device it reads as
  "liquid" rather than a video defect. True fluid morph is not
  expressible — stretch/merge is keyframed scale + position.
  Judgement call: Typography Explosion uses a single strongest
  accent per line (chars stagger 2 frames after it), not one
  explosion per onset peak.
- **Music**: path amplitude can't be modulated per frame — a baked
  path's points are static, so Soundwave layers three baked
  amplitude variants crossfaded by loudness instead of one morphing
  wave. Scale tracks are uniform — bars widen as they grow and
  "stretch" is a uniform scale pulse, not a true vertical stretch.
  `paramScale` multiplies the whole evaluated value, so it is unsafe
  on scale reaction tracks with base 1 (it would shrink nodes to
  the param's fraction) — scale sensitivities are baked into
  reaction gains at build time, with those params in
  `rebuildParamIds`; `paramScale` is used only on opacity tracks.
  Emitter rate has no reaction binding (only `rateParamId`) —
  audio-driven density is expressed with layered emitters whose
  opacity tracks are audio reactions. Rhythm Typography's syllable
  split is a vowel-group heuristic by design, never phonetic. Audio
  Energy World's displacement scale (8–28, frequency 3) is
  extrapolated from the Metal spike's `baseScale: 20` and needs a
  device eyeball.
- **Digital**: VR face tracking does NOT use `extraStyleFaceBoxTracks`
  — the helper emits no keys for no-face samples and returns no
  tracks at all when there are no faces, which would strand a
  (0,0)-based panel at the top-left. A local `vrFaceTracks` sampler
  falls back to canvas centre (upper-middle, y = 0.30H — a guess to
  check against real face-box heights) for any sample with no face
  box. VR perspective panels are near-full-frame trapezoids, not
  small floating cards: the engine warps a perspective group's
  entire full-canvas raster into its corner quad, so a small panel's
  quad would compress the whole raster. Waveform draw progress is
  faked via per-segment `visibleRange` reveal (no path trim).
  Animated perspective corners don't exist (warp quad static;
  movement via scale/position tracks). Mask animation doesn't exist
  (slice bands baked at build time). Data Visualization bar mapping:
  bar *i* reads band `i * bandCount / barCount` — with the default
  8 bars / 10 bands the top two bands are unused (consider a
  log-spaced band pick).
- **Experimental A**: Surveillance box size is fixed (0.34W × 0.19H)
  — no track resizes a node from the face-box size, so a near/far
  subject gets the same box. Face tracking uses the engine's 2 fps
  nearest-sample boxes, so the box holds between samples. A
  displacement node's scale can only be modulated via a scale track
  (onset reaction in Glitch, slow loop in VHS) — no per-frame
  displacement-map control. Self-caught fixes: `override var
  rebuildParamIds` is invalid for a protocol conformance (plain
  `var`, matching sibling files); `extraStyleTextNode` takes no
  `blendMode` (VHS ghost copy is a direct `ExtraStyleNode`).
- **Cinematic**: Parallel Worlds mirrored text renders reversed
  (mirror-writing) in the cool tint, mirrored in position across
  the centre line — a true horizontal glyph flip is not expressible
  (uniform scale). Split wipe via mask keyframes is not expressible
  (masks are static on a node; no track animates them) — the wipe is
  a sweeping divider bar + opacity crossfade. Displacement scale
  units are uncalibrated (no reference for what `baseScale` looks
  like visually); the spike values (6 + 34×distortion, ×1.6 at
  switches) are reasoned guesses for the device test. Memory
  Fragments face avoidance is optional/defensive: `maskIndex` read
  only when present, frame pushed clear only when it would actually
  overlap a face box.
- **Design**: self-caught fix — the Neon halo gradient node must sit
  at the canvas centre (not the sign centre) because its rect is the
  full canvas in local space.
- **Experimental B**: displacement scale tracks override `baseScale`
  — a reaction track's value is `base + gain × reaction`, ignoring
  the node's baked `baseScale` except as the fallback. Reality
  Distortion therefore bakes `waveScale` into the reaction's
  base/gain and lists `waveScale`/`waveFrequency` as rebuild params.
  A gradient *mask* fade was unavailable (masks clip, they don't
  fade), so the Mirror wash darkens rather than alpha-fading the
  copy.

Lint fixes made during the gate (all in Phase 3 files):
- `react-hooks/set-state-in-effect` (4 errors): slider sync and
  card-expand sync moved to render-time adjustment; the hook's
  no-scene reset moved to render-time adjustment (the effect keeps
  only the external handle release); the expand effect deleted
  outright (`selectStyle` already expands).
- `onViewableItemsChanged`: `useRef(fn).current` (ref read during
  render) replaced with a stable `useCallback`.
- `favoriteIds` wrapped in its own `useMemo` (was a fresh array per
  render in memo/callback deps); `listHeader` useMemo deps trimmed
  (three deps the linter flagged as unnecessary — `studio` already
  covers them).
- Two unused imports removed: `AudioAutomation` in `prepare.ts`,
  `secondsToFrames` in `src/lib/editModes.ts` (pre-existing warning,
  removed so the gate is clean).

## Gate results (all green, 2026-11-13)

- `npx tsc --noEmit` — exit 0 (after fixing 5 errors: 2 typed-routes
  quirk, 1 `songUri: string | null`, 1 spread-of-optional-lyrics,
  1 params-patch index signature).
- `npx expo lint` — exit 0 (after the fixes above).
- `npm run test:shuffle` 11/11, `test:edl` 46/46, `test:lyrics` 73/73,
  `test:looks` 16/16, `test:library` 4/4, `test:mixmaster` 46/46,
  `test:extra-styles` **32/32** (25 Phase 2 + 7 new Phase 3: card
  lines, synthetic automation, synthetic mask index, cache key,
  card-line emoji passthrough, full-catalog v1 successors,
  favorites-shell validation). Two test-authoring mistakes caught
  during the run (beats start at t=0 not 0.5s; automation hop is
  0.1s not ~30ms; loudness swells −18→−12, not −24→−12) — the
  implementation was right, the tests were corrected to it.
- `npx expo export --platform ios` — exit 0.
- `tests/.build-*` deleted after the runs.
- Swift is NOT compiled locally — **CI is the Swift gate**. Static
  checks done here instead: all 41 definitions present, no duplicate
  ids/class names, flags match the map, every `extraStyle*` helper
  called by the new files exists (4 Playful path helpers are
  file-local privates), all `ExtraStyleNode` init labels used match
  the struct's fields, no TODOs/FIXMEs.

## What remains for Phase 4 (polish)

- **Swift compile is unproven until CI runs** — the 8 new Swift files
  (~9,000 lines) have only had static checks here. Any compile error
  is a Phase 3 follow-up, not a Phase 4 item.
- Metal adoption per node only where the spike justifies it (numbers
  still pending a device run); per-node Metal displacement is the
  named candidate.
- Layer editing: needs a layer schema in metadata + UI + fixing the
  native rebuild dropping layers.
- Path draw-progress track kind (Ink strokes, Cartoon motion lines,
  Blueprint draw-on all fake it with opacity today); rounded-rect
  shape kind (or corner radius on `.rect`); optional bundled sticker
  art (Sticker World is procedural shapes today).
- Non-uniform node scale or a perspective-corner flip, for a true
  Mirror World / Neon reflection (both fake it with faded copies).
- Per-take mask switching (Phase 3 uses the cut's first take for
  masks); real performance sample clip replacing the generated one.
- Face-box-driven node **sizing** (Surveillance box/ring scaling to
  the detected face-box size) — needs an engine track kind or a
  mask-size input; per-frame displacement-map animation (currently
  only base scale/frequency settable at build time); animated
  perspective corners and mask-offset tracks (Digital); live
  loudness-driven loop period and live stroke/gradient-stop colour
  binding (Typography); independent x/y scale (Music bars, Rhythm
  stretch); a step/hold easing and a true blur/glow node property
  (Design); a gradient/alpha-fade mask (Experimental B).
- Card-preview budget measurement (540×960 @ 15fps is a Phase 4
  device decision); parallel-worlds mirrored-footage second video
  layer (deferred from this phase).
- Device verdicts: Emoji Storytelling pixel proof (preview AND
  export), all-40 visual pass, Metal spike numbers, beat-grid
  quality, mask precompute time, preview/export parity for a 2.0
  scene via the harness style.
