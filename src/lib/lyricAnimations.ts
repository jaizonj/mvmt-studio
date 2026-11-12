/**
 * Lyric animation presets — 50 CapCut-spirit styles over ONE
 * parametric model, so the JS preview overlay and the native export
 * renderer (CATextLayer) implement every preset from the same numbers
 * and preview == export (the lyrics feature's hard constraint).
 * The native side has NO catalog: the composite request carries these
 * resolved parameters verbatim.
 *
 * RENDERER SEMANTICS (both renderers implement exactly this):
 * For a line shown from S to E (composition seconds), at time t:
 *   tIn = t − S, tOut = E − t.
 *   enterP = enterSecs <= 0 ? 1 : easeOutCubic(clamp01(tIn / enterSecs))
 *   exitP  = exitSecs  <= 0 ? 1 : easeInCubic(clamp01(tOut / exitSecs))
 *   e = min(enterP, exitP)
 *   opacity = lerp(fromOpacity, 1, e)
 *   scale   = lerp(fromScale, 1, e)        (× emphasis, below)
 *   offsetX = fromXOffsetFrac × (1 − e) × lineWidth
 *   offsetY = fromYOffsetFrac × (1 − e) × lineHeight
 *   rotate  = fromRotateDeg × (1 − e)
 * (fromXOffsetFrac: + starts shifted RIGHT. fromYOffsetFrac: +
 *  starts shifted DOWN — "Rise" therefore uses a positive value.)
 *
 * wordMode refines how the envelope is applied:
 * - 'none': the envelope applies to the whole line. While active,
 *   if emphasisScale ≠ 1 the line scale is multiplied by a breathing
 *   pulse: 1 + (emphasisScale − 1) × (0.5 − 0.5·cos(2π·tActive / P)),
 *   P = min(1.2s, active span), repeating — deterministic in both
 *   renderers.
 * - 'stagger': word i runs its OWN enter envelope, starting at
 *   S + i × wordStaggerSecs (using the line's enter params per word);
 *   the exit envelope still applies to the whole line. Untimed words
 *   are the line's space-separated tokens.
 * - 'karaoke': the line envelope applies (enter params); per word —
 *   sung (t ≥ word end): full opacity; current (word start ≤ t < end):
 *   full opacity, scaled by emphasisScale; upcoming: 45% opacity.
 *   Needs word timings; without them the line renders as 'none'.
 * - 'typewriter': words appear discretely at their word start times
 *   (evenly across the line when untimed), no per-word envelope; the
 *   line exit envelope still applies.
 *
 * Approximations (chosen so BOTH renderers can do them from params):
 * - Blur In: no blur parameter exists — faked with opacity + a slight
 *   overscale settling in, which reads as a focus pull at lyric sizes.
 * - Flip / Roll In: 2D rotation + scale stand in for the 3D flip.
 * - Glow Pulse / Shake / Jitter: the emphasis pulse + small rotation
 *   offsets carry the effect; there is no glow/shadow parameter.
 * - Expand: scale-in stands in for letter-spacing expansion.
 */
export type LyricWordMode = 'none' | 'stagger' | 'karaoke' | 'typewriter';

/** Browse categories for the Style tab picker (docs/STYLES-REDESIGN.md §1). */
export type LyricAnimationCategory =
  | 'Entrances'
  | 'Word by Word'
  | 'Karaoke & Highlight'
  | 'Big Impact'
  | 'Soft & Cinematic'
  | 'Playful & Glitch';

export const LYRIC_ANIMATION_CATEGORIES: LyricAnimationCategory[] = [
  'Entrances',
  'Word by Word',
  'Karaoke & Highlight',
  'Big Impact',
  'Soft & Cinematic',
  'Playful & Glitch',
];

export interface LyricAnimationParams {
  enterSecs: number;
  exitSecs: number;
  /** Opacity at the "from" state, 0–1. */
  fromOpacity: number;
  /** Horizontal start offset, × line width (+ = starts to the right). */
  fromXOffsetFrac: number;
  /** Vertical start offset, × line height (+ = starts lower). */
  fromYOffsetFrac: number;
  fromScale: number;
  fromRotateDeg: number;
  wordMode: LyricWordMode;
  /** Per-word delay for 'stagger' mode, seconds. */
  wordStaggerSecs: number;
  /** Karaoke current-word scale / 'none'-mode pulse peak. 1 = off. */
  emphasisScale: number;
}

export interface LyricAnimation extends LyricAnimationParams {
  id: string;
  name: string;
  /** Browse category for the Style tab picker. */
  category: LyricAnimationCategory;
}

const base: LyricAnimationParams = {
  enterSecs: 0.3,
  exitSecs: 0.25,
  fromOpacity: 1,
  fromXOffsetFrac: 0,
  fromYOffsetFrac: 0,
  fromScale: 1,
  fromRotateDeg: 0,
  wordMode: 'none',
  wordStaggerSecs: 0,
  emphasisScale: 1,
};

function preset(
  id: string,
  name: string,
  category: LyricAnimationCategory,
  overrides: Partial<LyricAnimationParams>,
): LyricAnimation {
  return { id, name, category, ...base, ...overrides };
}

export const LYRIC_ANIMATIONS: LyricAnimation[] = [
  preset('static', 'Static', 'Entrances', { enterSecs: 0, exitSecs: 0 }),
  preset('fade', 'Fade', 'Entrances', { enterSecs: 0.35, fromOpacity: 0 }),
  preset('rise', 'Rise', 'Entrances', { enterSecs: 0.4, fromOpacity: 0, fromYOffsetFrac: 0.8 }),
  preset('drop', 'Drop', 'Entrances', { enterSecs: 0.4, fromOpacity: 0, fromYOffsetFrac: -0.8 }),
  preset('slide-left', 'Slide In Left', 'Entrances', { enterSecs: 0.45, fromOpacity: 0, fromXOffsetFrac: -1.2 }),
  preset('slide-right', 'Slide In Right', 'Entrances', { enterSecs: 0.45, fromOpacity: 0, fromXOffsetFrac: 1.2 }),
  preset('pop', 'Pop', 'Entrances', { enterSecs: 0.25, exitSecs: 0.2, fromOpacity: 0, fromScale: 0.5, emphasisScale: 1.05 }),
  preset('bounce', 'Bounce', 'Playful & Glitch', { enterSecs: 0.6, fromOpacity: 0, fromScale: 0.3, fromYOffsetFrac: 0.3 }),
  preset('zoom', 'Zoom', 'Big Impact', { enterSecs: 0.5, exitSecs: 0.4, fromOpacity: 0, fromScale: 1.6 }),
  // Blur In — approximated via opacity + overscale settle (see header).
  preset('blur-in', 'Blur In', 'Entrances', { enterSecs: 0.55, fromOpacity: 0, fromScale: 1.12 }),
  // Flip — 2D rotation + scale stand in for the 3D flip.
  preset('flip', 'Flip', 'Entrances', { enterSecs: 0.45, fromOpacity: 0, fromScale: 0.2, fromRotateDeg: -18 }),
  preset('spin', 'Spin', 'Big Impact', { enterSecs: 0.5, fromOpacity: 0, fromScale: 0.4, fromRotateDeg: 160 }),
  // Shake — rotation offset enter + emphasis pulse carry it.
  preset('shake', 'Shake', 'Playful & Glitch', { enterSecs: 0.3, fromXOffsetFrac: 0.06, fromRotateDeg: 5, emphasisScale: 1.04 }),
  preset('pulse', 'Pulse', 'Playful & Glitch', { enterSecs: 0.3, fromOpacity: 0, emphasisScale: 1.08 }),
  // Glow Pulse — emphasis pulse stands in for the glow swell.
  preset('glow-pulse', 'Glow Pulse', 'Playful & Glitch', { enterSecs: 0.4, fromOpacity: 0, emphasisScale: 1.05 }),
  preset('typewriter', 'Typewriter', 'Word by Word', { wordMode: 'typewriter', enterSecs: 0, exitSecs: 0.25, fromOpacity: 0 }),
  preset('karaoke', 'Karaoke', 'Karaoke & Highlight', { wordMode: 'karaoke', enterSecs: 0.25, fromOpacity: 0, emphasisScale: 1.18 }),
  preset('word-pop', 'Word Pop', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.22, fromOpacity: 0, fromScale: 0.4, wordStaggerSecs: 0.09, emphasisScale: 1.1 }),
  preset('word-rise', 'Word Rise', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.3, fromOpacity: 0, fromYOffsetFrac: 0.7, wordStaggerSecs: 0.08 }),
  preset('word-fade', 'Word Fade', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.35, fromOpacity: 0, wordStaggerSecs: 0.07 }),
  preset('highlight-sweep', 'Highlight Sweep', 'Karaoke & Highlight', { wordMode: 'karaoke', enterSecs: 0.2, fromOpacity: 0, emphasisScale: 1 }),
  preset('cascade', 'Cascade', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.4, fromOpacity: 0, fromYOffsetFrac: 1, wordStaggerSecs: 0.14 }),
  preset('wave', 'Wave', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.35, fromOpacity: 0, fromYOffsetFrac: 0.45, fromRotateDeg: 6, wordStaggerSecs: 0.06 }),
  preset('swing', 'Swing', 'Playful & Glitch', { enterSecs: 0.55, fromOpacity: 0, fromYOffsetFrac: -0.4, fromRotateDeg: -14 }),
  // Expand — scale-in stands in for letter-spacing expansion.
  preset('expand', 'Expand', 'Entrances', { enterSecs: 0.5, fromOpacity: 0, fromScale: 0.6 }),
  // Jitter — tiny offsets + fast emphasis pulse read as jitter.
  preset('jitter', 'Jitter', 'Playful & Glitch', { enterSecs: 0.18, fromXOffsetFrac: 0.03, fromYOffsetFrac: 0.05, fromRotateDeg: 2, emphasisScale: 1.03 }),
  // Roll In — horizontal slide + 2D rotation.
  preset('roll-in', 'Roll In', 'Entrances', { enterSecs: 0.5, fromOpacity: 0, fromXOffsetFrac: -1, fromRotateDeg: -24 }),
  preset('soft-rise', 'Soft Rise', 'Soft & Cinematic', { enterSecs: 0.7, exitSecs: 0.5, fromOpacity: 0, fromYOffsetFrac: 0.35 }),
  preset('impact', 'Impact', 'Big Impact', { enterSecs: 0.16, exitSecs: 0.2, fromOpacity: 0, fromScale: 2.4, emphasisScale: 1.02 }),
  preset('float', 'Float', 'Soft & Cinematic', { enterSecs: 0.9, exitSecs: 0.6, fromOpacity: 0, fromYOffsetFrac: 0.5, emphasisScale: 1.02 }),

  // ---- Expansion set (50-preset pass) — same parametric model, new
  // motion characters: faster/slower timings, opposite directions,
  // scale direction flips, and word-mode interplay. ----
  // Rise's snappy sibling: half the travel, under half the time.
  preset('rise-fast', 'Rise Fast', 'Entrances', { enterSecs: 0.18, exitSecs: 0.15, fromOpacity: 0, fromYOffsetFrac: 0.6 }),
  // Drop, but slamming: more travel than Drop, slight oversize, pulse.
  preset('drop-heavy', 'Drop Heavy', 'Big Impact', { enterSecs: 0.22, fromOpacity: 0, fromYOffsetFrac: -1.4, fromScale: 1.15, emphasisScale: 1.06 }),
  // Half-width drifts (Slide In travels a full line width; these glide).
  preset('slide-fade-left', 'Slide Fade Left', 'Entrances', { enterSecs: 0.5, fromOpacity: 0, fromXOffsetFrac: -0.5 }),
  preset('slide-fade-right', 'Slide Fade Right', 'Entrances', { enterSecs: 0.5, fromOpacity: 0, fromXOffsetFrac: 0.5 }),
  // Words rain in from above, quick stagger (Word Rise's mirror).
  preset('word-drop', 'Word Drop', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.28, fromOpacity: 0, fromYOffsetFrac: -0.9, wordStaggerSecs: 0.07 }),
  // Each word rotates 90° into place while scaling up.
  preset('word-spin', 'Word Spin', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.35, fromOpacity: 0, fromScale: 0.5, fromRotateDeg: 90, wordStaggerSecs: 0.08 }),
  // Karaoke with a bigger current-word pop than Karaoke (1.18 → 1.3).
  preset('karaoke-pop', 'Karaoke Pop', 'Karaoke & Highlight', { wordMode: 'karaoke', enterSecs: 0.15, fromOpacity: 0, emphasisScale: 1.3 }),
  // Typewriter with a fast cut out (0.12s exit vs 0.25s).
  preset('typewriter-fast', 'Typewriter Fast', 'Word by Word', { wordMode: 'typewriter', enterSecs: 0, exitSecs: 0.12, fromOpacity: 0 }),
  // The slow cinematic zoom: starts 3.2× and settles over 0.7s
  // (Zoom is 1.6×/0.5s; Impact is 2.4× but slams in 0.16s).
  preset('zoom-far', 'Zoom Far', 'Big Impact', { enterSecs: 0.7, exitSecs: 0.4, fromOpacity: 0, fromScale: 3.2 }),
  // Exit-led: pops in quick, then shrinks + fades away over 0.55s
  // (the exit replays the from-state, so it ends small and ghosted).
  preset('shrink-out', 'Shrink Out', 'Entrances', { enterSecs: 0.2, exitSecs: 0.55, fromOpacity: 0, fromScale: 0.85 }),
  // Pendulum swings from each side (Swing hangs from centre-top).
  preset('swing-left', 'Swing Left', 'Playful & Glitch', { enterSecs: 0.6, fromOpacity: 0, fromXOffsetFrac: -0.4, fromYOffsetFrac: -0.3, fromRotateDeg: 18 }),
  preset('swing-right', 'Swing Right', 'Playful & Glitch', { enterSecs: 0.6, fromOpacity: 0, fromXOffsetFrac: 0.4, fromYOffsetFrac: -0.3, fromRotateDeg: -18 }),
  // Cascade's downward mirror: words fall in sequence from above.
  preset('cascade-down', 'Cascade Down', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.32, fromOpacity: 0, fromYOffsetFrac: -0.8, wordStaggerSecs: 0.12 }),
  // Impact at half strength: 1.5× settle over 0.35s instead of a slam.
  preset('impact-soft', 'Impact Soft', 'Big Impact', { enterSecs: 0.35, exitSecs: 0.25, fromOpacity: 0, fromScale: 1.5, emphasisScale: 1.03 }),
  // Float Up: a full line-height of upward travel, quicker than Float,
  // with a stronger breathing pulse.
  preset('float-up', 'Float Up', 'Soft & Cinematic', { enterSecs: 0.55, exitSecs: 0.35, fromOpacity: 0, fromYOffsetFrac: 1.1, emphasisScale: 1.05 }),
  // Roll In's mirror: rolls in from the right, opposite rotation.
  preset('roll-down', 'Roll Down', 'Entrances', { enterSecs: 0.5, fromOpacity: 0, fromXOffsetFrac: 1, fromRotateDeg: 24 }),
  // Fade stretched to a slow cinematic crossfade (1.1s in, 0.9s out).
  preset('fade-slow', 'Fade Slow', 'Entrances', { enterSecs: 1.1, exitSecs: 0.9, fromOpacity: 0 }),
  // Words shrink down from 1.8× one by one (Word Pop grows from 0.4×).
  preset('word-zoom', 'Word Zoom', 'Word by Word', { wordMode: 'stagger', enterSecs: 0.3, fromOpacity: 0, fromScale: 1.8, wordStaggerSecs: 0.08 }),
  // Karaoke, but the whole line also rises in as the words light up.
  preset('karaoke-rise', 'Karaoke Rise', 'Karaoke & Highlight', { wordMode: 'karaoke', enterSecs: 0.35, fromOpacity: 0, fromYOffsetFrac: 0.6, emphasisScale: 1.12 }),
  // A subtle skewed settle: slight rotation + near-full scale, no travel.
  preset('tilt-in', 'Tilt In', 'Entrances', { enterSecs: 0.45, fromOpacity: 0, fromScale: 0.9, fromRotateDeg: -8 }),
];

export const DEFAULT_ANIMATION_ID = 'karaoke';

/**
 * Dedupe aliases (Styles Redesign Stage 1, docs/STYLES-REDESIGN.md
 * §1): near-duplicate presets are hidden from the picker but their
 * ids KEEP resolving — projects store animationId, so an old id
 * must still render, as its survivor. Never delete a catalog id;
 * alias it here instead.
 */
export const LYRIC_ANIMATION_ALIASES: Record<string, string> = {
  // Rise family → keep rise, rise-fast, float.
  'soft-rise': 'rise',
  'float-up': 'float',
  // Slide family → keep the two full slides.
  'slide-fade-left': 'slide-left',
  'slide-fade-right': 'slide-right',
  // Swing family → keep swing.
  'swing-left': 'swing',
  'swing-right': 'swing',
  // Zoom/Impact family → keep zoom, impact.
  'zoom-far': 'zoom',
  'impact-soft': 'impact',
  'shrink-out': 'zoom',
  // Karaoke family → keep karaoke, karaoke-pop.
  'karaoke-rise': 'karaoke',
  'highlight-sweep': 'karaoke',
  // Typewriter pair → keep typewriter.
  'typewriter-fast': 'typewriter',
  // Word-rise mirrors → keep word-rise, cascade.
  'word-drop': 'word-rise',
  'cascade-down': 'cascade',
  // Fade pair → keep fade.
  'fade-slow': 'fade',
  // Glow Pulse has no real glow in this model — keep pulse.
  'glow-pulse': 'pulse',
};

/** The presets the picker shows: every catalog entry except aliases. */
export const PICKER_ANIMATIONS: LyricAnimation[] = LYRIC_ANIMATIONS.filter(
  (a) => !(a.id in LYRIC_ANIMATION_ALIASES),
);

const byId = new Map(LYRIC_ANIMATIONS.map((a) => [a.id, a]));

/**
 * Catalog lookup; an aliased id resolves to its survivor, and an
 * unknown id falls back to the default preset.
 */
export function lyricAnimationById(id: string): LyricAnimation {
  const resolvedId = LYRIC_ANIMATION_ALIASES[id] ?? id;
  return byId.get(resolvedId) ?? byId.get(DEFAULT_ANIMATION_ID)!;
}

/** The plain parameter object the composite request carries. */
export function resolveAnimationParams(id: string): LyricAnimationParams {
  const { enterSecs, exitSecs, fromOpacity, fromXOffsetFrac, fromYOffsetFrac, fromScale, fromRotateDeg, wordMode, wordStaggerSecs, emphasisScale } =
    lyricAnimationById(id);
  return {
    enterSecs,
    exitSecs,
    fromOpacity,
    fromXOffsetFrac,
    fromYOffsetFrac,
    fromScale,
    fromRotateDeg,
    wordMode,
    wordStaggerSecs,
    emphasisScale,
  };
}
