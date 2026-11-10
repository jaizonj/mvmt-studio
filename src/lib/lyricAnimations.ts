/**
 * Lyric animation presets — 30 CapCut-spirit styles over ONE
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

function preset(id: string, name: string, overrides: Partial<LyricAnimationParams>): LyricAnimation {
  return { id, name, ...base, ...overrides };
}

export const LYRIC_ANIMATIONS: LyricAnimation[] = [
  preset('static', 'Static', { enterSecs: 0, exitSecs: 0 }),
  preset('fade', 'Fade', { enterSecs: 0.35, fromOpacity: 0 }),
  preset('rise', 'Rise', { enterSecs: 0.4, fromOpacity: 0, fromYOffsetFrac: 0.8 }),
  preset('drop', 'Drop', { enterSecs: 0.4, fromOpacity: 0, fromYOffsetFrac: -0.8 }),
  preset('slide-left', 'Slide In Left', { enterSecs: 0.45, fromOpacity: 0, fromXOffsetFrac: -1.2 }),
  preset('slide-right', 'Slide In Right', { enterSecs: 0.45, fromOpacity: 0, fromXOffsetFrac: 1.2 }),
  preset('pop', 'Pop', { enterSecs: 0.25, exitSecs: 0.2, fromOpacity: 0, fromScale: 0.5, emphasisScale: 1.05 }),
  preset('bounce', 'Bounce', { enterSecs: 0.6, fromOpacity: 0, fromScale: 0.3, fromYOffsetFrac: 0.3 }),
  preset('zoom', 'Zoom', { enterSecs: 0.5, exitSecs: 0.4, fromOpacity: 0, fromScale: 1.6 }),
  // Blur In — approximated via opacity + overscale settle (see header).
  preset('blur-in', 'Blur In', { enterSecs: 0.55, fromOpacity: 0, fromScale: 1.12 }),
  // Flip — 2D rotation + scale stand in for the 3D flip.
  preset('flip', 'Flip', { enterSecs: 0.45, fromOpacity: 0, fromScale: 0.2, fromRotateDeg: -18 }),
  preset('spin', 'Spin', { enterSecs: 0.5, fromOpacity: 0, fromScale: 0.4, fromRotateDeg: 160 }),
  // Shake — rotation offset enter + emphasis pulse carry it.
  preset('shake', 'Shake', { enterSecs: 0.3, fromXOffsetFrac: 0.06, fromRotateDeg: 5, emphasisScale: 1.04 }),
  preset('pulse', 'Pulse', { enterSecs: 0.3, fromOpacity: 0, emphasisScale: 1.08 }),
  // Glow Pulse — emphasis pulse stands in for the glow swell.
  preset('glow-pulse', 'Glow Pulse', { enterSecs: 0.4, fromOpacity: 0, emphasisScale: 1.05 }),
  preset('typewriter', 'Typewriter', { wordMode: 'typewriter', enterSecs: 0, exitSecs: 0.25, fromOpacity: 0 }),
  preset('karaoke', 'Karaoke', { wordMode: 'karaoke', enterSecs: 0.25, fromOpacity: 0, emphasisScale: 1.18 }),
  preset('word-pop', 'Word Pop', { wordMode: 'stagger', enterSecs: 0.22, fromOpacity: 0, fromScale: 0.4, wordStaggerSecs: 0.09, emphasisScale: 1.1 }),
  preset('word-rise', 'Word Rise', { wordMode: 'stagger', enterSecs: 0.3, fromOpacity: 0, fromYOffsetFrac: 0.7, wordStaggerSecs: 0.08 }),
  preset('word-fade', 'Word Fade', { wordMode: 'stagger', enterSecs: 0.35, fromOpacity: 0, wordStaggerSecs: 0.07 }),
  preset('highlight-sweep', 'Highlight Sweep', { wordMode: 'karaoke', enterSecs: 0.2, fromOpacity: 0, emphasisScale: 1 }),
  preset('cascade', 'Cascade', { wordMode: 'stagger', enterSecs: 0.4, fromOpacity: 0, fromYOffsetFrac: 1, wordStaggerSecs: 0.14 }),
  preset('wave', 'Wave', { wordMode: 'stagger', enterSecs: 0.35, fromOpacity: 0, fromYOffsetFrac: 0.45, fromRotateDeg: 6, wordStaggerSecs: 0.06 }),
  preset('swing', 'Swing', { enterSecs: 0.55, fromOpacity: 0, fromYOffsetFrac: -0.4, fromRotateDeg: -14 }),
  // Expand — scale-in stands in for letter-spacing expansion.
  preset('expand', 'Expand', { enterSecs: 0.5, fromOpacity: 0, fromScale: 0.6 }),
  // Jitter — tiny offsets + fast emphasis pulse read as jitter.
  preset('jitter', 'Jitter', { enterSecs: 0.18, fromXOffsetFrac: 0.03, fromYOffsetFrac: 0.05, fromRotateDeg: 2, emphasisScale: 1.03 }),
  // Roll In — horizontal slide + 2D rotation.
  preset('roll-in', 'Roll In', { enterSecs: 0.5, fromOpacity: 0, fromXOffsetFrac: -1, fromRotateDeg: -24 }),
  preset('soft-rise', 'Soft Rise', { enterSecs: 0.7, exitSecs: 0.5, fromOpacity: 0, fromYOffsetFrac: 0.35 }),
  preset('impact', 'Impact', { enterSecs: 0.16, exitSecs: 0.2, fromOpacity: 0, fromScale: 2.4, emphasisScale: 1.02 }),
  preset('float', 'Float', { enterSecs: 0.9, exitSecs: 0.6, fromOpacity: 0, fromYOffsetFrac: 0.5, emphasisScale: 1.02 }),
];

export const DEFAULT_ANIMATION_ID = 'karaoke';

const byId = new Map(LYRIC_ANIMATIONS.map((a) => [a.id, a]));

/** Catalog lookup; unknown ids fall back to the default preset. */
export function lyricAnimationById(id: string): LyricAnimation {
  return byId.get(id) ?? byId.get(DEFAULT_ANIMATION_ID)!;
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
