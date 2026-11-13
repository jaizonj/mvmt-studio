# Extra Styles 2.0 — Phase 4: Lyric-only re-scope

Record of the Phase 4 work done 2026-11-13, redefined by Jaizon's device
verdict on the 2.0 build. The plan doc (`docs/EXTRA-STYLES-2.0.md` §18)
was amended to match; this file is the per-style record.

## 0. The verdict that redefined Phase 4

Jaizon, 2026-11-13 ~10:28 MST, on the 2.0 build (CI 43419213700, headSha
4d4271a), with a screenshot of the Edit preview at 0:42/0:45 (78 cuts):

> "Words are bugged and the styles aren't high quality enough. Make it more
> high quality and cooler all around and no styles that take up the whole
> screen just lyrics with cool animations and stuff"

Two more reports the same morning (~10:30 MST) were folded into this
phase: the Look auto-apply is "not removed", and the OG v1 Extra Styles
are "in there still".

## 1. The mirror bug — root cause and fix

**What the screenshot actually shows:** the lyric band, tested against all
four transforms, is restored exactly by a **vertical flip** — the defect is
a pure vertical (upside-down) flip of the glyphs. Word order is left-to-
right and correct; each glyph is mirrored top-to-bottom. The "horizontally
mirrored / reads right-to-left" description was imprecise. The video of
Jaizon is upright, and the sparkles are near-symmetric under a vertical
flip, which is why they looked fine.

**Root cause — shared path, all styles:**
`modules/mvmt-compositor/ios/ExtraStylesCompositor.swift`, `drawText`
(`CTLineDraw` at :2526). The scene bitmap contexts are y-flipped for
y-down scene coordinates (`mainContext` :2167–2168, `tempContext`
:2188–2189: `translateBy(x: 0, y: canvas.height); scaleBy(x: 1, y: -1)`).
That flip is correct for shapes/images/particles, which are defined
directly in user space. But Core Text glyphs live in the font's y-up
space, and `drawText` drew them with the default identity `textMatrix` —
so the CTM's y-flip inverted every glyph vertically. `drawText` is the
only `CTLineDraw` call in the codebase; every text kind routes through
it (line, word, char, counter, emoji). No style file can produce this
(no negative scale exists anywhere; `resolveNode` builds translate →
rotate → uniform positive scale → anchor). The style-specific mirror
stand-ins don't match either: Parallel Worlds' `String(line.text
.reversed())` would give upright glyphs in reversed order plus two lines
and a divider; the screenshot has one line, correct word order,
upside-down glyphs. The :2826–2833 `flipSource`/`flipRender` sandwich is
not the bug (base video only; its two −1 determinants cancel).

**Fix (shared renderer, one point):** in `drawText`, before the line
loop (:2508):

```swift
context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
```

restored to `.identity` after the loop (:2528). The text-matrix flip
cancels the CTM's y-flip for glyphs only; advances stay left-to-right
and the baseline is unchanged. Shapes, gradients, images, and
particles are untouched.

**Preview vs export:** both go through the fixed path — editor preview
(`editor.tsx` → `useExtraStyleScene` → `buildComposition(forExport:
false)` installs `ExtraStylesCompositor`) and export (same scene handle
→ `buildComposition(forExport: true)` → transcode installs the same
compositor). Catalog card previews share it too (`renderPreviewFrame` /
`renderPreviewClip` via `renderer.render`).

**Regression test: none — no testable seam.** There is no Swift/XCTest
target in the repo; `tests/` is Node `.cjs` only and the bug is
Swift-only (Core Text text matrix + CGContext). No source-grep tripwire
was added (it would not test rendering). **Swift is not compiled
locally — CI is the verification gate; the real proof is Jaizon's
device test on the next build.**

## 2. The lyric-only rule (binding)

**The video is the star.** No full-screen backgrounds, washes, tunnels,
portals, or decor layers that cover the frame. No full-screen scene
compositions. Every style = lyrics with cool animations.

What "cooler / higher quality" means here: word-by-word entrances tied
to the lyric timing data, emphasis pops on key words (stored lyric
intelligence), karaoke-style current-word highlighting, kinetic
typography with proper easing (spring/ease helpers, no linear/janky
motion), better typography (weights, tracking, sizing, line spacing),
and consistent legibility — every lyric node now carries a dark outline
stroke (the engine has no blur/glow property, so stroke is the
mechanism) so words always read over any footage.

Emoji/decor stay ONLY when small and attached to the words — no
full-screen particle fields, no decor covering the video.

**Verification:** zero `extraStyleBackgroundGradientNode(` call sites
remain in any style file (30 at HEAD); zero displacement nodes,
face-box tracks, or subject-mask usages remain in any style file. One
full-canvas gradient rect survives in `ExtraStylesDesign.swift` (Neon
Sign World's halo) — its rect is full-canvas in local space by engine
design, but its radial falloff radius is derived from the measured
lyric width and its colours fade to alpha 0, so nothing visible extends
past the words. The `__harness` style's lime background in the
compositor is internal-only and cannot be selected.

## 3. Per-style disposition — all 40

IDs are stable throughout; nothing was renamed or deleted. "Retired +
replaced" means the old concept cannot work as lyrics-only, so a new
lyric-only concept was built under the same ID (the catalog name/tagline
may be renamed later; migration is unaffected).

### Cinematic

| Style | Disposition | Lyric-only version |
|---|---|---|
| dream-sequence | Converted | Soft-fading word-by-word entrances, gentle drift, two faint same-order echo copies, emoji small at line end; wash/particles/trail/glow gone. `needsAudioAutomation` true → false (loudness glow was its only automation consumer). |
| memory-fragments | Converted | Serif words surfacing one at a time like a developing photo, per-word dissolve, gentle drift, emoji as small stamp at line end. |
| floating-universe | Converted | Words adrift on depth layers (far/mid/near size/opacity/drift), twinkle star flickering above emphasis words only, emoji small satellite at line end. |
| film-credits-reimagined | Converted | Large tracked Didot, glyphs spreading from centre line into tracked slots, tone rule under the words, slow push-in + rise per line. |
| parallel-worlds | **Retired + replaced (same ID)** | Old mirrored/reversed text + divider + wipe + displacement cannot be lyrics-only. Replacement: each line sung in the world active on the downbeat (warm A / cool B, alternating per beat switch), faint offset echo in same reading order — never reversed. |

### Interactive / Surreal (Typography)

| Style | Disposition | Lyric-only version |
|---|---|---|
| typography-physics | Converted | Char fall/bounce kept; cascade spread across the line's sung duration from the first word's start, emphasis letters pop harder on the beat, dark outline on glyphs; floor line kept as a thin word-attached accent. |
| liquid-letters | Converted | Words ripple on a sine loop, merge toward centre on entry, stretch mid-line; blobs kept as word-attached liquid bodies; ripple stroke narrowed to the lyric line's width. Emphasized words stretch 1.3× in tone colour. |
| infinite-tunnel | Converted | Each word flies toward the viewer on a depth path (0.5× far → 1.12× overshoot → settle) at its sung start, speed from param, beat/onset pulse on top; emphasized words larger in accent colour. |
| portal-typography | Converted | One stroked ring ellipse hugging the measured lyric line springs open at line start, dashed orbit ellipse turns around it, small spark on its edge; words spring out of the ring at their sung starts; emoji at line end. |
| typography-explosion | Converted | Char explosion + spring reassembly unchanged (already lyric-only); background removed; shards shrunk to line-attached debris. |

### Digital / Futuristic

| Style | Disposition | Lyric-only version |
|---|---|---|
| holographic-interface | Converted | Mono words sliding in word-by-word with accent stroke + gentle float, thin scanline shimmer under each word, one small `HOLO //` corner chip. |
| digital-corruption | Converted | RGB-split copies + masked glitch slices of the line itself + onset pop; base copy gets a dark outline; emoji at line end. |
| cyber-terminal | Converted | Per-char typewriter reveal, travelling block caret, `>` prompt at the typed line's left edge, small system-message lines; one small `MVMT://TERM` corner tag. |
| virtual-reality | **Retired + replaced (same ID)** | Old near-full-frame perspective planes / floor grid / face-tracked HUD reticle cannot be lyrics-only. Replacement: words drift in depth (near/mid/far tiers), spring entrances, parallax float loops, emphasis words in accent, emoji at line end. `needsSubjectMasks` true → false. |
| data-visualization | Converted | Karaoke words (sung words dim to 0.6 once the next word starts), 8 tiny bars under the line reading band energies, one small `TONE · BPM · WORDS` chip under the bars, emoji at line end. |

### Graphic Design

| Style | Disposition | Lyric-only version |
|---|---|---|
| editorial-magazine | Converted | Serif headline words rising one by one at sung starts; emphasis words slam in with a spring and turn accent; paper strip sized to the words + two rule lines sized to the words. |
| brutalist-typography | Converted | Massive uppercase words hard-cutting/sliding in word by word with onset scale pop (emphasis pops harder), on one accent block sized to the line + two short bars. |
| collage-explosion | Converted | Torn-paper scraps behind each word + cutout letters; small star bursts pinned to emphasis words only; line emoji tucked at the end of the lyric line. |
| ink-and-paint | Converted | Marker words bleeding in word by word with spring scale; brush strokes under the words; blots inside the lyric line's width; small splat on emphasis words only. |
| neon-sign-world | Converted | Words buzzing in word by word with tube-activation ramp + white core stroke; layered `.screen` glow copies; halo shrunk tight around the words (radius from measured lyric width). |

### Playful / Storytelling

| Style | Disposition | Lyric-only version |
|---|---|---|
| emoji-storytelling | Converted | Words sung karaoke-style with emphasis pops; hero emoji small and attached at the end of the line (was a huge centrepiece above it); tone backdrop wash removed. Unconditional `extraStyleEmojiNode` passthrough + tone-reaction fallback preserved — the acceptance criterion (emoji visible end-to-end, preview AND export) is intact. |
| cartoon-universe | Converted | Bouncy words springing in one by one inside a word-sized speech bubble; small star bursts on emphasis words only. |
| message-universe | Converted | Words typing in one by one (each at its sung start) inside a word-sized chat bubble; typing dots + corner reaction emoji kept. |
| comic-book | **Retired + replaced (same ID)** | Old panels (88%×52% filled blocks) cannot be lyrics-only. Replacement: big bold words slamming in with springs, emphasis words as impact words (harder slam + small comic-burst behind the word + short motion rays). |
| sticker-world | Converted | Each word IS a sticker (ink text, white peel outline, seeded tilt, spring pop); theme star behind emphasis words; two small stickers at the line's ends + line emoji above the line. |

### Music-Driven

| Style | Disposition | Lyric-only version |
|---|---|---|
| soundwave-typography | Converted | Words on the lyric line with per-band wobble + onset pop; the wave is now a small lyric-width (0.82W) strip under the line, 3 baked amplitude variants crossfaded by loudness, plus a small travelling dot. |
| beat-reactor | Converted | Words spring in and pulse on the beat grid; downbeat + emphasis words in accent with a harder pop; one small beat bar under the line. |
| frequency-universe | Converted | Lyric line above a tiny spectrum strip (one small bar per band, max 0.09H) under the line. |
| rhythm-typography | Converted | Already lyric-only; background gradient removed; syllable bounce/stretch/pop, phrase bar, emoji hero kept; syllables gained outline stroke + emphasis words in accent. |
| audio-energy-world | Converted | The words themselves swell/brighten with loudness, emphasis words swell harder in accent; one small loudness meter under the line. |

### Experimental

| Style | Disposition | Lyric-only version |
|---|---|---|
| glitch-reality | Converted | Per-word jitter, RGB-split ghost copies per word (accent + magenta, flickering), scatter-settle shards on the line. |
| surveillance-system | **Retired + replaced (same ID)** | Face-box tracker / full HUD cannot work as lyrics-only. Replacement: transcript readout — mono words typed in as sung, the sung word highlighted in HUD colour with a highlight bar behind it, under a small corner "● REC CAM 01" tag. `needsSubjectMasks` true → false. |
| newspaper-explosion | Converted | Headline words bursting in/out of a scatter, kicker + lyric-width rule kept; emphasis words print kicker-red. |
| vhs-dream | Converted | Mono words with cyan ghost copy, slow wobble, word-level tracking jumps + flicker; emphasis words print cyan. |
| optical-illusion | Converted | One small pattern group (rings/checker/spiral/waves) behind the words only, sized exactly to the measured lyric block, rotating slowly; words drift in phase with it. |
| blueprint-world | Converted | Frame, diagonals, corner crosses, dimension lines/labels, draw-head dot — all sized to the lyric block; lyric is now per-word mono nodes (type shrinks to fit long lines). |
| kinetic-sculpture | Converted | Words orbit in and assemble on the line (Assemble/Tumble/Orbit entrances), with one small ring accent sized to the lyric block. |
| mirror-world | Converted | Main line now word-by-word (slide-down + spring, emphasis in accent); echo kept as a faint squashed same-direction copy below the mirror line — never reversed text. |
| living-typography | Converted | Char growth with loudness kept; vine + branches span the measured lyric block only; chars gained outline stroke. |
| reality-distortion | Converted | Words tilt/push/settle per word + baked sine wobble + onset pop; bent frame around the line kept (lyric-sized). |

**Totals: 36 converted, 4 retired+replaced** (parallel-worlds,
comic-book, virtual-reality, surveillance-system), all under the same
IDs. Scope corrections found during the work: Dream Sequence is
registered once (in `ExtraStylesDemos.swift`, not in the Cinematic
file); Typography Physics and Holographic Interface live in
`ExtraStylesDemos.swift`, not in their family files.

## 4. Flag, param, and input changes

**Flags (Swift is the source of truth — `prepare.ts` reads the Swift
bridge metadata, not the TS map):**
- `dream-sequence`: `needsAudioAutomation` true → false.
- `surveillance-system`: `needsSubjectMasks` true → false.
- `virtual-reality`: `needsSubjectMasks` true → false.
- All other flags unchanged. The TS `STYLE_CAPABILITY_MAP`
  (`src/lib/extra-styles/catalog.ts`) was synced for these three flags.

**Params:** many decor-tied params were dropped (e.g. Emoji
Storytelling `backdrop`; Dream Sequence `density`/`glow`; Infinite
Tunnel `rings`/`glow`; Portal `portalSize`/`glow`; Data Visualization
`chartStyle`/`barCount`; Surveillance `lockPulse`/`showTimestamp`/
`scanSpeed`/`targetLabel`; VHS `showTimestamp`/`tapeSpeed`/`scanlines`;
Newspaper `columns`/`paperColor`; Kinetic `perspective`; Beat Reactor
`flash`/`rings`; Frequency `glow`/`particles`; Audio Energy
`glow`/`warp`; Glitch `displacement`; VR `faceTracking`; Editorial
`columns`/`masthead`; Brutalist `paper`/`cutOnAccent`; Collage
`stickers`; Ink `splash`; Comic Book `panelStyle`; Holographic
`scanlines`; Memory Fragments `frameTint`/`showCaptions`; Film Credits
`vignette`; Parallel Worlds `distortion`; Liquid Letters `liquidWarp`;
Digital Corruption `noiseDensity`/`displacement`; Cyber Terminal
`scanlineIntensity`). One param added: Surveillance `karaoke` (toggle,
"Highlight sung word", default true). Several params were
reinterpreted under the same ID (stored values still valid):
Soundwave `waveAmplitude` (now strip height, range 4–48, default 18),
VHS `distortion` (now wobble amplitude + ghost offset), Reality
`waveScale`/`waveFrequency` (now bend strength / wobble speed),
Kinetic `shapeStyle` options relabelled (values unchanged).
Param schemas are declared in the Swift definitions, so the UI follows
automatically; stored values for dropped params are dropped by
`resolveExtraStyleParams` (never a crash).

**Inputs:** several styles added `"words"` / `"intelligence"` to their
Swift `inputs` lists (they now read word timings). The `inputs` list
is metadata only — `prepareScene` validates only
`needsAudioAutomation` / `needsSubjectMasks`, and words arrive inside
`lines[].words` in the bridge payload — so no TS-side inputs work was
needed.

**Capability-map staleness (known, not fixed here):** the per-style
`capabilities` lists in `STYLE_CAPABILITY_MAP` are Phase 2-era and now
overstate usage — `particles` is named by five styles that no longer
use particle fields, `subject-mask`/`subject-face` by styles that
dropped masks/face tracking, `second-video-layer` by Parallel Worlds
(Phase 4-deferred plumbing, unused by the replacement). They were left
in place deliberately: the extra-styles test asserts every engine
capability is used by at least one mapped style, so pruning the map
without also pruning `ENGINE_CAPABILITIES` would break the coverage
proof, and the engine still implements those capabilities. Pruning
both together is a follow-up, not part of this re-scope. The flags —
the load-bearing part — are synced (above).

## 5. Engine additions

**None.** No engine extension was made. The work stayed inside the
Phase 3 engine limits (no path-draw, no blur/glow, no non-uniform
scale, no true glyph mirror flip, no step easing, no animated
perspective corners). The recurring workaround is post-hoc stroke
mutation on helper-built word/char nodes (`extraStyleWordNodes` /
`extraStyleCharNodes` expose no stroke parameter). A one-line Builders
change (stroke params on those two helpers) would remove the
workaround — suggested as a follow-up, not done here. The single
biggest quality compromise is displacement: a displacement node
distorts the whole composed frame, video included, with uncalibrated
CI scale, so Glitch / VHS / Reality Distortion lose their displacement
waves entirely and fake the wave with word-level motion.

## 6. Look auto-apply — findings and fixes

Jaizon reported the Look is "not removed" in the 2.0 build. Diagnosis
(read-only, against HEAD 4d4271a):

- **The greenish tint in the verdict screenshot is a style wash, not
  a Look.** The active style was Emoji Storytelling; its default
  `"soft"` backdrop was a radial acid-lime (#C9F36B) wash at 0.3 alpha
  over the full frame, drawn over the video. No Look reaches the frame
  for an untouched project, and no Look preset has a green hue
  component. The wash is gone with this re-scope (Emoji Storytelling
  `backdrop` param dropped, backdrop node deleted).
- **The 4b37b81 removal holds for fresh projects.** `effectiveLook`
  defaults to Original, `resolveLookParams` returns null for identity,
  the preview and export traces carry no look, and the extra-style
  path carries only a scene handle (no grade). The extra-style slot
  grades only `if let look = slot?.look`, nil when no Look is selected.
- **Leak C (fixed):** overrides were applied as absolute values after
  the preset lerp, so a stored Original with overrides resolved
  non-null and graded. `resolveLookParams` now short-circuits to null
  when the resolved preset is Original, before overrides. Regression
  test added (`tests/looks.test.cjs`: Original + overrides → null;
  a non-Original preset with overrides still grades). Looks suite
  16 → 17.
- **Leak D (fixed, latent):** the preview builder wrote
  `LookCompositorStore.current` only when the look was non-identity
  and never cleared it on a no-look build. An `else` branch now clears
  both `LookCompositorStore.current` and
  `ExtraStyleCompositorStore.current` on preview builds with no
  look / no resolvable scene, matching the transcode's `defer`
  discipline. Unobservable today (fresh composition + fresh player
  per preview build), but the staleness is gone.
- **Leak B (known, deliberately NOT fixed):** `4b37b81` changed only
  the default; it added no migration for projects whose `look` was
  already persisted as `auto-enhance` (a LookPanel interaction before
  the removal stamped the then-effective auto-enhance look onto the
  project permanently). Such a project keeps grading. It was NOT
  blanket-cleared: a stored `auto-enhance` is indistinguishable from
  an explicit manual pick of Auto Enhance, and an explicit pick must
  keep working. The fix needs a distinguishable record (e.g. stamp
  explicit picks going forward and migrate only unstamped ones) or a
  one-time notice per affected project — a follow-up decision for
  Jaizon, not a silent data change.

## 7. v1 templates — removed

The 30 OG v1 templates are removed from every UI and selection path:
`src/lib/lyricTemplates.ts` deleted (712 lines); the "Extra" tab
removed from `LyricsPanel.tsx` (−250 lines); `setLyricTemplate` /
`toggleFavoriteLyricTemplate` removed from `StudioContext.tsx`;
`buildCompositeLyrics` is classic-only. Kept: `migrateV1Template` +
`V1_TEMPLATE_SUCCESSORS` and the load-time migration (15 successors
resolve, rest → classic + notice, never crash), the classic lyric path,
and per-line lyric intelligence (the 2.0 scenes read it directly).
The lyrics test suite's v1 contract tests were removed/rewritten as
classic-only (73 → 65 tests), including a pin that a stale stored
`templateId` changes nothing. The dead decor branches in
`LyricsOverlay.tsx` and the Swift burn-in remain as unreachable code.

## 8. Gate results

Run by the coordinator 2026-11-13 before commit — all green:

- `npx tsc --noEmit` — exit 0
- `npx expo lint` — exit 0
- `npm run test:shuffle` — 11/11
- `npm run test:edl` — 46/46
- `npm run test:lyrics` — 65/65 (was 73; 8 v1-contract tests removed, 4 payload/parity tests rewritten classic-only)
- `npm run test:looks` — 17/17 (was 16; +1 Leak C regression test)
- `npm run test:library` — 4/4
- `npm run test:mixmaster` — 46/46
- `npm run test:extra-styles` — 32/32
- `npx expo export --platform ios` — exit 0

**Swift verification: pending CI.** Swift is not compiled locally; the
first CI build on the new HEAD is the real check. The riskiest new
constructs are the post-hoc stroke mutations on helper-built nodes,
the `let words: [ExtraStyleNode]` if/else-with-`continue` pattern in
Reality Distortion, and the shared `designWordPlacements` /
`designLyricNodes` / `playfulWordPlacements` helpers — all
uncompiled until CI.
