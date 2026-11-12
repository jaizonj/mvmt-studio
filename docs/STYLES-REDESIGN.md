# Styles System Redesign & Extra Styles Expansion

Authorised by Jaizon, 2026-11-12. Programme doc — the working plan, not a
spec frozen in amber. Existing behaviour is preserved unless a section
below says otherwise; projects store `animationId` / `fontId`, so IDs are
never deleted, only aliased.

## 1. Audit (2026-11-12)

### What exists today
- **50 fonts** (`src/lib/lyricFonts.ts`): 26 iOS system + 24 bundled OFL.
  The catalog is pure data + lookups; the native export resolves by
  PostScript name, the preview by React Native family. `boldPostScriptName`
  carries the real bold face where one exists.
- **50 animations** (`src/lib/lyricAnimations.ts`): ONE parametric model
  (`LyricAnimationParams`: enter/exit secs, fromOpacity, fromX/Y offsets,
  fromScale, fromRotateDeg, wordMode, wordStaggerSecs, emphasisScale).
  The JS overlay and the Swift burn-in share the resolved params, pinned
  by contract tests in `tests/lyrics.test.cjs`.
- **Lyric style** (`LyricStyle` in `src/types.ts`): one global object per
  project — fontId, sizeRatio, color, strokeColor, strokeWidthRatio,
  background, backgroundColor, position, verticalOffsetRatio,
  maxWidthRatio, animationId, bold. Everything in the Style tab edits
  this object; the export payload is `resolveLyricStyle` + the
  `LyricAnimationRecord` bridge.

### Duplicates (keep the strongest, alias the rest)
Old IDs stay resolvable (projects store them); the picker only shows the
survivor. Aliases live in the catalog module (`lyricAnimationById` /
`lyricFontById` already fall back — extend to an alias map).

Animations:
- Rise family: `rise`, `rise-fast`, `soft-rise`, `float`, `float-up`
  → keep `rise` (standard), `rise-fast` (snappy), `float` (slow/breathy).
- Slide family: `slide-left`, `slide-right`, `slide-fade-left`,
  `slide-fade-right` → keep the two full slides.
- Swing family: `swing`, `swing-left`, `swing-right` → keep `swing`.
- Zoom/Impact family: `zoom`, `zoom-far`, `impact`, `impact-soft`,
  `shrink-out` → keep `zoom`, `impact`.
- Karaoke family: `karaoke`, `karaoke-pop`, `karaoke-rise`,
  `highlight-sweep` → keep `karaoke`, `karaoke-pop`.
- Typewriter pair: `typewriter`, `typewriter-fast` → keep `typewriter`.
- Word-rise mirrors: `word-rise`, `word-drop`, `cascade`,
  `cascade-down` → keep `word-rise`, `cascade`.
- Fade pair: `fade`, `fade-slow` → keep `fade`.
- `glow-pulse` vs `pulse`: glow has no real glow in the current model
  (comment admits it) — keep `pulse`, reimplement glow properly as an
  Extra Style (real shadow/glow layer) instead.

Fonts (no deletions — fonts are faces, not duplicates — but grouped):
- Clean Sans: avenir-next, avenir-next-condensed, helvetica-neue, futura,
  gill-sans, optima, din-alternate, montserrat-extrabold,
  oswald-semibold, bebas-neue, anton, archivo-black, rubik-mono-one.
- Serif & Elegant: didot, bodoni-72, baskerville, georgia, palatino,
  cochin, playfair-display, dm-serif-display, abril-fatface, cinzel,
  superclarendon, rockwell.
- Handwritten & Playful: marker-felt, noteworthy, chalkboard-se,
  pacifico, dancing-script, permanent-marker, caveat,
  shadows-into-light, bangers, luckiest-guy, fredoka-semibold,
  party-let.
- Display & Impact: copperplate, alfa-slab-one, righteous, bungee,
  audiowide, orbitron, press-start-2p.
- Typewriter & Mono: american-typewriter, courier-new, menlo.
- Script: snell-roundhand, zapfino, papyrus.

### Animation categories (picker)
Entrances · Word by Word · Karaoke & Highlight · Big Impact ·
Soft & Cinematic · Playful & Glitch.

## 2. Extra Styles architecture

One template system, not 30 disconnected implementations.

### Template = style + decor
```ts
interface LyricTemplate {
  id: string; name: string; tagline: string;
  category: ExtraStyleCategory;   // e.g. 'story', 'chat', 'comic'
  style: Partial<LyricStyle>;     // font, size, color, stroke, position…
  decor: LyricDecor;              // the thing that makes it EXTRA
}
```
`LyricDecor` is a second parametric model with a `kind` discriminator
and numeric/string params, resolved once per project the same way the
animation params are. A template is chosen in the panel (stored as
`Project.lyrics.templateId`, optional — unset = classic style) and
**the resolved style + decor travel in the same composite payload**
the export already carries, so preview and export cannot drift.

### Decor rendering — two renderers, one contract
- **JS preview** (`LyricsOverlay`): one small component per decor kind,
  reading the same resolved decor + the same line/word timings.
- **Swift burn-in** (`makeAnimationTool` / `makeLyricLineLayer`): one
  CALayer-subtree builder per decor kind, inside the same animation
  tool as the watermark/lyrics. Decor layers are drawn from the same
  measured text images the lyric renderer already produces (never
  re-rendered text), plus shape/emoji layers where the kind needs them.
- Contract tests (extend `tests/lyrics.test.cjs`): every template's
  resolved style keys match the Swift records; every decor kind has a
  JS + Swift implementation (a registry test fails when a kind exists
  on one side only).

### Intelligence — deterministic, cached, stored on the line
Analysis runs ONCE at Detect time (and on manual line edits), in
`src/lib/lyrics.ts`, and is stored on the line — renderers never
analyse, they only read:
- **Emoji mapping**: a keyword dictionary (love, fire, money, night,
  dance, rain, heartbreak, party, car, phone…) → emoji per line; a
  line with no keyword match gets none (never guessed).
- **Tone**: word lists (joy / sad / anger / love / hype) → a tone tag;
  templates that adapt to tone read the tag, others ignore it.
- **Emphasis**: words in ALL CAPS or repeated within the line are
  flagged; templates may scale/stroke them.
- Word timings come from Whisper as today; every word-level animation
  in a template uses them, never invented timings.

### The 30 Extra Styles (concepts)
1. Emoji Story — relevant emoji floats above each line (dictionary).
2. Chat — lyrics as a messaging conversation, bubbles alternating sides.
3. Comic Book — speech bubbles + impact bursts ("POW" styling on emphasis).
4. Word Explosion — words burst outward and settle, staggered.
5. Scrapbook — handwritten font, sticker/doodle frames, paper texture pill.
6. Hologram — cyan glow, scanlines, flicker, floating drift.
7. Karaoke Pop — the default karaoke, but with a bold pop + color swap.
8. Neon Sign — glow shadow, dark pill, flicker on enter.
9. Typewriter Classic — monospace, cursor block, letter-by-letter.
10. Film Subtitle — clean bottom subtitle with soft black bar.
11. Magazine — big serif headline, thin rules, all-caps kicker word.
12. Graffiti — marker font, rotated, spray-dot texture, bright stroke.
13. Retro TV — scanlines, rounded frame, 4:3-ish pill, slight wobble.
14. Minimal Mono — tiny monospace, huge letter-spacing, bottom-left.
15. Big Bold Billboard — huge condensed caps, hard shadow, center.
16. Duet — two alternating colors/positions for call-and-response lines.
17. Echo — the line repeats behind itself, fading, offset (ghost trail).
18. Spotlight — line fades in under a soft radial glow pill.
19. Rain — words fall in from above with a stagger, splash settle.
20. Bounce House — each word bounces in with overshoot, playful font.
21. Elegant Script — script font, slow fade, thin underline rule.
22. Cyberpunk — Orbitron, magenta/cyan split, glitch jitter on enter.
23. Storybook — serif italic, gentle rise, soft vignette pill.
24. Sticker Pop — chunky font, thick white stroke, pill background.
25. Wave Rider — words ride a sine wave across the line.
26. Countdown — numbers/words slam in with scale, one beat apart.
27. Whisper — tiny, low-opacity, slow fade, top corner.
28. Anthem — huge caps, slow zoom, gold stroke, center.
29. Text Message Typing — bubble + typing dots, then the line appears.
30. Split Screen Words — words alternate top/bottom halves of the frame.

Decor kinds needed (shared, ~10): `emoji-row`, `chat-bubble`,
`comic-burst`, `sticker-frame`, `scanlines`, `glow`, `cursor`,
`ghost-trail`, `rule`, `pill-glow`, `wave-path`, `typing-dots`.
Several templates share a kind with different params — that is the
reuse that keeps 30 templates maintainable.

## 3. Mobile-first interface

- Style tab: horizontal category chips above the font list and above
  the animation grid; vertical scrolling lists; the font list becomes
  grouped sections with headers instead of one 50-chip row.
- New **EXTRA STYLES** section in the Lyrics panel (its own tab):
  search field, favorites (heart per card, persisted per project),
  compact preview cards that animate a sample line live (the same
  `LyricsOverlay` component, small stage), selected card ring.
- Applying a template sets `templateId` + its style in one tap and
  the preview above updates immediately; no nested scroll views
  (one vertical list, horizontal chip rows only).
- Portrait-first; landscape canvases reuse the same layout with the
  width ratios from `maxWidthRatio`.

## 4. Staging (one build per stage)
- **Stage 1 — Reorganize**: categories + aliases + search/favorites
  plumbing for the classic Style tab; no behaviour change.
- **Stage 2 — Template architecture + first 10 Extra Styles**
  (Emoji Story, Chat, Comic Book, Word Explosion, Scrapbook,
  Hologram, Karaoke Pop, Neon Sign, Typewriter Classic, Film Subtitle)
  with the decor contract + intelligence (emoji/tone/emphasis).
- **Stage 3 — Remaining 20 Extra Styles** on the same architecture.
- **Stage 4 — Parity audit**: preview vs export per template, clip
  check (maxWidthRatio respected), performance (decor layers are
  cheap CALayers; no per-frame re-render).

## 5. Acceptance (Jaizon's list, mapped)
- Existing styles reorganized → Stage 1.
- 30 genuinely different Extra Styles → Stages 2–3 (each a template
  with its own typography/palette/animation/composition/decor).
- iPhone interface → Section 3.
- Every style renders lyrics + effects over video → decor builders
  in the Swift tool, not thumbnails.
- Preview == export → shared resolved payload + contract tests.
- No placeholders, no regressions → aliases preserve old IDs;
  classic path untouched when no template is set.
