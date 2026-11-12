# Styles Parity Audit — preview == export (Stage 4)

Date: 2026-11-12. Auditors: line-by-line comparison of the two
renderers — the JS preview overlay
(`src/components/LyricsOverlay.tsx`) and the Swift export burn-in
(`modules/mvmt-compositor/ios/MvmtCompositorModule.swift`, lyric
section). Both consume the SAME resolved composite payload
(`resolveLyricStyle` + `buildCompositeLyrics` in `src/lib/lyrics.ts`),
so the data cannot drift — only the rendering can. (How a template
reaches the payload: picking one folds its style overrides into
the project style at pick time — `setLyricTemplate` in
`src/store/StudioContext.tsx` — and stores `templateId` for the
decor; the payload builder resolves style from `lyrics.style`
and decor from `templateId`. A payload built with `templateId`
alone, without the style fold, carries the default style — that
is by design, not a drift.)

## Ground rules found during the audit

- **Layer space is y-up** (bottom-left origin). A JS `translateY`
  of +1 moves a word DOWN on screen; the same visual move in Swift
  is a −1 translation, and a JS rotation of −3° (counter-clockwise
  on screen) is +3° in Swift. Every vertical offset and rotation
  in the Swift side must be negated relative to the JS value.
  `lyricFromTransform` had this wrong: every preset with a
  vertical offset or rotation ran mirrored in export (Rise fell
  instead of rising; Flip tilted the wrong way).
- **The JS line box includes padding.** Enter offsets (`fromX/Y`,
  `fromRotateDeg`) scale by the line box — text + padding — on
  the JS side, so the Swift side must pass the container size,
  not the bare content size.
- **`maxWidthRatio` caps the whole container**, text + padding,
  on both sides. The old Swift limit wrapped the text only, so a
  backed line could run past the limit by its padding.
- **The JS overlay is the reference for the intended look**
  (Jaizon sees the preview first); where the two disagreed, the
  fix aligns Swift to JS unless the JS side was the wrong one
  (glow/shadow strength, cursor blink phase, comic-burst shape —
  those were JS bugs fixed toward the Swift/intended value).

## Audit table

Status: **match** (verified identical) / **fixed** (mismatch found
and fixed in this stage) / **known limitation** (a real difference
that cannot be closed without a device or a platform capability).

### Shared model (applies to every template)

| # | Area | Status | Notes |
|---|------|--------|-------|
| 1 | Position anchors (top/bottom margins) | fixed (Swift) | JS pads top 0.16×W, bottom 0.20×W; Swift used 0.10×H both. Swift now uses the width fractions. |
| 2 | `maxWidthRatio` wrap | fixed (Swift) | Swift now subtracts pill + decor padding from the limit and clamps it to ≥ 0.2×W. |
| 3 | Single unbreakable word wider than the limit | known limitation | Swift shrinks the font to fit; JS lets it overflow. Rare in real lyrics (words are short); the Swift behaviour is the safer one. |
| 4 | Word gap | match (tolerance) | JS 0.24×fontSize (+ tracking both sides); Swift measured space width (~0.25–0.278em, font-dependent). Sub-pixel per word; not worth forcing. |
| 5 | Split-screen rows | match | JS `align` is centre for the only template using it; Swift centres rows. Latent only. |
| 6 | Word-row alignment (`decor.align`) | fixed (Swift) | Swift centred every row; JS left/right-aligns (Minimal Mono). Swift `rowOriginX` now follows `align` for words and ghost copies. |
| 7 | Container paddings | fixed (Swift) | Style pill 0.55/0.24 → 0.45/0.16; chat/typing 0.8/0.4 → 0.55/0.22; comic 1.0/0.55 → 0.7/0.35; sticker 0.55/0.4 → 0.4/0.28; decor pill 1.1/0.3 → 0.9/0.2 (all × font size). |
| 8 | Pill radii | fixed (Swift) | Style pill was a stadium (height/2) → 0.35×fontSize; decor pill was height/2 → 0.4×fontSize. |
| 9 | Chat/typing bubble radius | fixed (Swift) | Was height×0.35 → 0.5×fontSize. |
| 10 | Chat bubble sideways shift | fixed (Swift) | JS shifts ±0.06×W by sender/receiver; Swift never shifted. |
| 11 | Chat-bubble tail | fixed (Swift) | Was 22%-of-width in, 0.3 tall; now 0.72×fontSize from the edge, 0.22 stick-out, base 0.06 inside, 0.44 wide. |
| 12 | Comic-burst shape | fixed (JS) | JS was a rounded rect; Swift draws a 12-spike starburst (inner ratio 0.78, inset −0.35×fontSize). JS now draws the same polygon with react-native-svg. Label position fixed on the Swift side (was 0.15 inside; now 0.35 above the top, flush right +0.2). |
| 13 | Frame tilt (comic-burst / sticker-frame) | fixed (Swift) | JS rotates the whole frame −2° including text; Swift tilted only the sticker shape (wrong sign) and left the text untilted. The gate now carries +2° for both kinds. |
| 14 | Gate rotation sign (`rotationDeg`) | fixed (Swift) | Swift applied the value directly; JS −3° is 3° CCW on screen. Gate rotation is now `−rotationDeg` (+2° for the tilted frames). |
| 15 | POW label rotation | match | JS +8°, Swift −8° = 8° CW on both; net 6° CW with the gate tilt on both sides. |
| 16 | Scanlines | fixed (Swift) | JS lines sit at (i+0.5)/8 of the CONTENT height, width contentW + 1×fontSize; Swift used the container. Swift is now content-relative. Height differs (JS fixed 2pt vs Swift containerH/32) — tolerance. |
| 17 | Glow / shadow strength | fixed (JS) | JS glow radius 0.5 full opacity vs Swift 0.4 at decor.opacity; JS shadow opaque vs Swift 0.85. JS now radius 0.4×fontSize with `hexWithAlpha(decor.color, opacity)` (glow default 0.6, shadow 0.85). |
| 18 | Cursor | fixed (both) | (a) JS blinked on absolute playhead time, Swift on line-relative steps — JS is now line-relative. (b) JS height 1.1×fontSize vs Swift max(textH, fontSize)×0.8 — JS now matches. (c) Swift drew the cursor for any `cursor` decor; now gated on typewriter word mode like JS. (d) Swift put it at the content right edge at the text-block centre; now after the last word of the last row. |
| 19 | Typing dots | match | Positions verified identical (rightmost centre 0.55×fontSize from edge, leftmost 1.19×, vertical 0.5×, visible first 0.5s). |
| 20 | Emoji row | fixed (JS) | JS had no gap under the emoji; Swift 0.25×fontSize. JS now `marginBottom: fontSize × 0.25`. Size formula matches (1.15×scale). |
| 21 | Ghost trail (Echo) | match | Offset 0.5×fontSize×scale down-right, opacity, z-order, moves with the line animation, no per-word animation on either side. |
| 22 | Duet | match | Fill + position alternate by line index, sender bottom / receiver top, on both sides. |
| 23 | Wave-path | fixed (Swift) | Amplitude/phase match; JS applies the wave only in stagger mode, Swift applied it in layout for all modes. Swift now gates on `wordMode == "stagger"`. |
| 24 | Rain / Burst flight distance | fixed (Swift) | JS 2.2×fontSize×scale vs Swift max(contentW, contentH)×0.55×scale (~4× too far on a wide line — words flew off-frame). Swift now 2.2×fontSize. Direction matches (90° rain = straight up; burst fan 30°–150°). |
| 25 | Bounce curve | fixed (Swift) | JS damped sine `lerp(fromScale,1,e) × (1 + 0.3·sin(2πe)·(1−e))` vs Swift 5-stop keyframes (fromScale → 1.25 → 0.9 → 1.05 → 1). Swift now samples the JS formula at 13 stops. |
| 26 | Karaoke (3 sub-mismatches) | fixed (Swift) | (a) Unsung emphasis word rendered 1.25× at 45% in Swift, 1× in JS — base now uses the plain font in karaoke mode. (b) Highlight twin rendered 1× in Swift, 1.25× in JS for emphasis words — highlight now uses the enlarged font. (c) No scale pop on the highlight in Swift; JS current word scales by emphasisScale — new discrete `transform.scale` pop on the highlight (emphasisScale while current, 1 after). |
| 27 | 'none'-mode pulse + line envelope | fixed (Swift) | JS repeating cosine pulse `1 + (emphasisScale−1)×(0.5−0.5·cos(2π·tIn/P))`, P = min(1.2s, duration), ONLY in 'none' mode; Swift did a single midpoint swell and applied it in karaoke/per-word modes too (Karaoke Pop would have swelled the whole line mid-line in export). `addLyricLineAnimations` now samples the JS envelope at 25 stops with linear interpolation (opacity, scale, offset, rotate from e = min(enterP, exitP) using easeOutCubic/easeInCubic) and takes an `applyPulse` flag (true only for 'none'). |
| 28 | Easing (per-word) | known limitation | JS easeOutCubic vs Swift `CAMediaTimingFunction` easeOut on the per-word CABasicAnimations. Same family, sub-perceptual; the line envelope and bounce are now sampled exactly, the per-word basics are left as-is. |
| 29 | Typewriter | match | Discrete pop at word start, even slices for untimed words, on both sides. Latent: Swift would pulse if emphasisScale > 1 in typewriter mode; only typewriter presets exist there (emphasisScale 1). |
| 30 | Stagger | match | Word i enters at S + i×wordStaggerSecs, enter params per word; exit envelope on the whole line both sides. |
| 31 | `fromXOffsetFrac` | match | X is right in both spaces. |
| 32 | Font resolution | match (tolerance) | PostScript name → RN family vs `UIFont(name:)`; bold fallback differs slightly (RN synthesis vs Swift bold-trait request + hair-stroke fallback). |
| 33 | `sizeRatio` clamp | match | JS max(8, sizeRatio×width) vs Swift clamp [0.005, 0.5] + guard ≥ 4 — identical in practice (templates 0.045–0.13). |
| 34 | Style pill + decor interplay | match (latent) | JS applies the style pill whenever `background='pill'`; Swift suppresses it when a decor background kind exists. No template combines them. |
| 35 | Line height | match (tolerance) | JS lineHeight = fontSize×1.22 vs Swift measured image heights. |
| 36 | Rule decor | fixed (Swift) | JS rules sit OUTSIDE the text with a 0.25×fontSize gap; Swift drew them 0.15×fontSize inside the container edge, striking through the text on pad-less templates. Swift now reserves ruleHeight + 0.25×fontSize as decorPadY, uses ruleHeight 0.04×fontSize (was 0.05), and draws the rules at the container edges. Rule width is now the text width (Storybook has a style pill, so its container is wider than its text). |
| 37 | Spray dots | match | Same 10 deterministic spots and colours, y-flip handled in Swift. |
| 38 | Sticker-frame geometry | match | Radius 0.2, border 0.07, dots 0.22 at corners half-outside, colour order [color, secondary, secondary, color]; dots' rotation fixed via the gate (see #13). |
| 39 | Line width/height for from-offsets | fixed (Swift) | JS uses the measured lineBox size (incl. padding); Swift passed the content size. Both call sites now pass the container size. |
| 40 | Split-screen wrap | match (latent) | JS rows can wrap (flexWrap); Swift assumes no wrap. Lines are capped at 36 chars, rows stay inside the limit. |
| 41 | Tone field | match | Unused by both renderers. |
| 42 | Gate animation vs JS active-line lookup | match | Equivalent visibility ([start, end) containment both sides). |

### Per-template verdicts

Every template was checked against the shared-model rows above
plus its own decor kind and animation. Templates whose decor or
animation had a fix in the table above are marked **fixed**;
the rest are **match**.

| Template | Decor | Animation | Verdict |
|---|---|---|---|
| Emoji Story | emoji-row | — | fixed (#20 emoji gap, JS) |
| Chat | chat-bubble | — | fixed (#7, #9, #10, #11, Swift) |
| Comic Book | comic-burst | karaoke | fixed (#12 shape JS + label Swift, #13 tilt, #26 karaoke) |
| Word Explosion | burst | stagger | fixed (#24 flight distance) |
| Scrapbook | sticker-frame | — | fixed (#7, #13 tilt) |
| Hologram | scanlines | — | fixed (#16 scanlines) |
| Karaoke Pop | glow | karaoke | fixed (#17 glow, #26c highlight pop, #27 pulse scope) |
| Neon Sign | glow | — | fixed (#17 glow) |
| Typewriter Classic | cursor | typewriter | fixed (#18 cursor, both sides) |
| Film Subtitle | pill | — | fixed (#7, #8 decor pill radius) |
| Magazine | rule | — | fixed (#36 rules) |
| Graffiti | spray | — | fixed (#14 gate rotation sign — its −3° tilt rendered the wrong way in export) |
| Retro TV | scanlines | — | fixed (#16 scanlines) |
| Minimal Mono | none | — | fixed (#6 row alignment) |
| Big Bold Billboard | shadow | — | fixed (#17 shadow) |
| Duet | duet | — | match |
| Echo | ghost-trail | — | match |
| Spotlight | glow (+ style pill) | — | fixed (#17 glow; also the `lyricColor` rgba() parse fix — its warm-white pill rendered black in export) |
| Rain | rain | stagger | fixed (#24 flight distance) |
| Bounce House | bounce | stagger | fixed (#25 bounce curve) |
| Elegant Script | rule | — | fixed (#36 rules) |
| Cyberpunk | glow | — | fixed (#17 glow) |
| Storybook | rule (+ style pill) | — | fixed (#36 rules incl. rule width) |
| Sticker Pop | sticker-frame | — | fixed (#7, #13 tilt) |
| Wave Rider | wave-path | stagger | fixed (#23 wave-path gating) |
| Countdown | — (word-zoom) | — | match |
| Whisper | none | — | match |
| Anthem | glow | — | fixed (#17 glow) |
| Text Message Typing | typing-dots | typewriter | fixed (#7, #9 bubble radius; #18c cursor gating does not apply — no cursor decor) |
| Split Screen Words | split-screen | — | match |

Two further Swift fixes cut across templates: **`lyricColor`
now parses CSS `rgb()`/`rgba()`** in addition to `#RRGGBB` /
`#RRGGBBAA` (Neon Sign, Retro TV, Spotlight and Storybook pill
backgrounds authored as rgba() previously fell back to black
55% — Spotlight's warm-white pill rendered black in export),
and **`lyricFromTransform` negates the Y offset and rotation**
(layer space is y-up) — every preset with a vertical offset or
rotation ran mirrored in export before this fix.

## What the tests pin (no device needed)

`tests/lyrics.test.cjs`, Stage 4 block (5 tests, 66 total):

- Every decor kind has a branch in BOTH sources (JS + Swift
  literal presence).
- The resolved payload is deterministic and round-trips — one
  payload feeds both renderers; no raw template id reaches Swift.
- `maxWidthRatio` is carried in the payload for every template
  (default 0.88) and the Swift wrap limit subtracts the container
  padding.
- Every template's `animationId` resolves through the alias map
  to a word mode the Swift side handles (`stagger`, `karaoke`,
  `typewriter`, `none`).
- The audited geometry constants agree between the two renderers
  (23 constant pairs: emoji gap, glow radius, shadow offset,
  burst distance, wave amplitude, bounce wobble, chat translate /
  radius / tail, comic + sticker pads, pill radii, rule height,
  split gap, ghost offset, scanline count, cursor width, typing
  dots, pulse period, karaoke opacity, comic emphasis, starburst
  spikes).

## Known limitations remaining

1. **Single unbreakable word wider than the limit** — Swift
   shrinks the font, JS overflows. Rare in lyrics; Swift's
   behaviour is the safer one.
2. **Word gap** — JS 0.24×fontSize vs Swift measured space width.
   Sub-pixel per word; not worth forcing.
3. **Per-word easing** — JS easeOutCubic vs Swift easeOut timing
   function. Same family, sub-perceptual.
4. **Font bold fallback** — RN synthesis vs Swift bold-trait
   request + hair-stroke fallback. Slight weight difference on
   bold fonts without a true bold face.
5. **Line height** — JS 1.22×fontSize vs Swift measured image
   heights. Small vertical differences possible on exotic fonts.
6. **Scanline height** — JS fixed 2pt vs Swift containerH/32.
7. **Latent only**: split-screen row alignment (only one
   template, centre), split-screen wrap (36-char cap), style
   pill + decor interplay (no template combines them), typewriter
   pulse (emphasisScale is 1 there), tone field (unused by both).

Everything else in the audit is either verified matching or fixed
in this stage. Pixel-level parity is still only settleable by
Jaizon's iPhone test — these tests pin the numbers, not the
rendering.
