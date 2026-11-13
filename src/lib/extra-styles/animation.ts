/**
 * Extra Styles 2.0 — animation math (Phase 2 core engine).
 *
 * THE canonical spec for the evaluator's math. This module is pure
 * TypeScript, unit-tested in Node (tests/extra-styles.test.cjs),
 * and the Swift evaluator in
 * modules/mvmt-compositor/ios/ExtraStylesCompositor.swift ports
 * these formulas exactly — same seed → same scatter, same spring
 * constants → same trajectory, in preview and export.
 *
 * Rules (docs §5): deterministic, frame-addressable, no timers.
 * All animation times are integer frames on the 30fps grid; seconds
 * exist only at the boundary (frame / 30).
 */

import { EXTRA_STYLES_FPS } from './types';

// ---------------------------------------------------------------------------
// Seeded randomness — splitmix64 (docs §5.4).
//
// Seed = a 64-bit hash of (style id, project id, node id, line id
// where applicable). The generator is splitmix64: same seed → same
// sequence, forever, on every launch. Changing the seed is a
// deliberate style parameter ("reshuffle the scatter"), never an
// accident.
// ---------------------------------------------------------------------------

const SPLITMIX_INCREMENT = 0x9e3779b97f4a7c15n;
const MASK_64 = (1n << 64n) - 1n;

/** One splitmix64 step: advance the state, return the output. */
export function splitmix64Next(state: bigint): { state: bigint; value: bigint } {
  const next = (state + SPLITMIX_INCREMENT) & MASK_64;
  let z = next;
  z = ((z ^ (z >> 30n)) * 0xbf58476d1ce4e5b9n) & MASK_64;
  z = ((z ^ (z >> 27n)) * 0x94d049bb133111ebn) & MASK_64;
  return { state: next, value: (z ^ (z >> 31n)) & MASK_64 };
}

/** A seeded generator: `next()` yields the next 64-bit value. */
export function makeSeededRandom(seed: bigint): () => bigint {
  let state = seed & MASK_64;
  return () => {
    const out = splitmix64Next(state);
    state = out.state;
    return out.value;
  };
}

/** A seeded 0..1 double (top 53 bits of the next output). */
export function seededDouble(random: () => bigint): number {
  return Number(random() >> 11n) / 2 ** 53;
}

/** A seeded value in [min, max). */
export function seededRange(random: () => bigint, min: number, max: number): number {
  return min + seededDouble(random) * (max - min);
}

// ---------------------------------------------------------------------------
// Easing — closed-form curves (docs §5.2). The same family the v1
// parametric model uses, so the two systems agree on "ease".
// ---------------------------------------------------------------------------

export type ExtraStyleEasing =
  | 'linear'
  | 'easeInCubic'
  | 'easeOutCubic'
  | 'easeInOutCubic'
  | 'easeOutSine'
  | 'easeInOutSine'
  | 'easeOutBack';

export function applyEasing(easing: ExtraStyleEasing, t: number): number {
  const x = Math.max(0, Math.min(1, t));
  // Exact endpoints — easeOutBack's closed form lands a float-dust
  // epsilon from 0 at t = 0, and a keyframe at its boundary must
  // read exactly its key value.
  if (x === 0) return 0;
  if (x === 1) return 1;
  switch (easing) {
    case 'linear':
      return x;
    case 'easeInCubic':
      return x * x * x;
    case 'easeOutCubic': {
      const u = 1 - x;
      return 1 - u * u * u;
    }
    case 'easeInOutCubic':
      return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
    case 'easeOutSine':
      return Math.sin((x * Math.PI) / 2);
    case 'easeInOutSine':
      return -(Math.cos(Math.PI * x) - 1) / 2;
    case 'easeOutBack': {
      const c1 = 1.70158;
      const c3 = c1 + 1;
      const u = x - 1;
      return 1 + c3 * u * u * u + c1 * u * u;
    }
    default:
      return x;
  }
}

/**
 * A cubic-bezier easing (CSS-style control points), solved by
 * Newton iteration + bisection fallback — fixed iteration count,
 * so it is deterministic. Used only where a style declares a
 * custom curve; the named easings above are the default.
 */
export function cubicBezierEasing(x1: number, y1: number, x2: number, y2: number): (t: number) => number {
  const cx = 3 * x1;
  const bx = 3 * (x2 - x1) - cx;
  const ax = 1 - cx - bx;
  const cy = 3 * y1;
  const by = 3 * (y2 - y1) - cy;
  const ay = 1 - cy - by;
  const sampleX = (t: number) => ((ax * t + bx) * t + cx) * t;
  const sampleY = (t: number) => ((ay * t + by) * t + cy) * t;
  const sampleDerivativeX = (t: number) => (3 * ax * t + 2 * bx) * t + cx;
  return (t: number) => {
    const x = Math.max(0, Math.min(1, t));
    let u = x;
    for (let i = 0; i < 8; i += 1) {
      const err = sampleX(u) - x;
      if (Math.abs(err) < 1e-6) return sampleY(u);
      const d = sampleDerivativeX(u);
      if (Math.abs(d) < 1e-6) break;
      u -= err / d;
    }
    let lo = 0;
    let hi = 1;
    u = x;
    while (hi - lo > 1e-6) {
      if (sampleX(u) < x) lo = u;
      else hi = u;
      u = (lo + hi) / 2;
    }
    return sampleY(u);
  };
}

// ---------------------------------------------------------------------------
// Keyframes — piecewise interpolation between (frame, value) keys
// (docs §5.2). Before the first key → the first value; after the
// last key → the last value; between keys → the easing of the
// segment's END key, applied to the local fraction.
// ---------------------------------------------------------------------------

export interface ExtraStyleKeyframe {
  frame: number;
  value: number;
  easing?: ExtraStyleEasing;
}

export function interpolateKeyframes(keys: ExtraStyleKeyframe[], frame: number): number {
  if (keys.length === 0) return 0;
  const sorted = [...keys].sort((a, b) => a.frame - b.frame);
  if (frame <= sorted[0].frame) return sorted[0].value;
  const last = sorted[sorted.length - 1];
  if (frame >= last.frame) return last.value;
  for (let i = 0; i + 1 < sorted.length; i += 1) {
    const a = sorted[i];
    const b = sorted[i + 1];
    if (frame >= a.frame && frame <= b.frame) {
      const span = b.frame - a.frame;
      const f = span > 0 ? (frame - a.frame) / span : 0;
      const eased = applyEasing(b.easing ?? 'linear', f);
      return a.value + (b.value - a.value) * eased;
    }
  }
  return last.value;
}

/** A colour keyframe track: RGBA channels interpolated together. */
export interface ExtraStyleColorKeyframe {
  frame: number;
  /** [r, g, b, a], each 0..1. */
  rgba: [number, number, number, number];
  easing?: ExtraStyleEasing;
}

export function interpolateColorKeyframes(
  keys: ExtraStyleColorKeyframe[],
  frame: number,
): [number, number, number, number] {
  if (keys.length === 0) return [1, 1, 1, 1];
  const sorted = [...keys].sort((a, b) => a.frame - b.frame);
  if (frame <= sorted[0].frame) return sorted[0].rgba;
  const last = sorted[sorted.length - 1];
  if (frame >= last.frame) return last.rgba;
  for (let i = 0; i + 1 < sorted.length; i += 1) {
    const a = sorted[i];
    const b = sorted[i + 1];
    if (frame >= a.frame && frame <= b.frame) {
      const span = b.frame - a.frame;
      const f = span > 0 ? (frame - a.frame) / span : 0;
      const eased = applyEasing(b.easing ?? 'linear', f);
      return [
        a.rgba[0] + (b.rgba[0] - a.rgba[0]) * eased,
        a.rgba[1] + (b.rgba[1] - a.rgba[1]) * eased,
        a.rgba[2] + (b.rgba[2] - a.rgba[2]) * eased,
        a.rgba[3] + (b.rgba[3] - a.rgba[3]) * eased,
      ];
    }
  }
  return last.rgba;
}

// ---------------------------------------------------------------------------
// Springs — ANALYTIC damped-harmonic-oscillator solutions (docs
// §5.2), never numerical integration: position at frame t is a
// closed function of (from, to, stiffness, damping, t). The Swift
// evaluator implements the same three regimes.
// ---------------------------------------------------------------------------

export interface SpringParams {
  from: number;
  to: number;
  /** Spring constant k (stiffness). */
  stiffness: number;
  /** Damping coefficient c. */
  damping: number;
  /** Mass (default 1). */
  mass?: number;
  /** Initial velocity (units / second). */
  initialVelocity?: number;
}

/**
 * Position of a 1-D spring at `tSeconds` after release.
 * Underdamped (ζ < 1), critically damped (ζ = 1), and overdamped
 * (ζ > 1) all have closed forms; t = 0 returns `from` exactly.
 */
export function springPositionAtTime(params: SpringParams, tSeconds: number): number {
  const { from, to, stiffness, damping } = params;
  const mass = params.mass ?? 1;
  const v0 = params.initialVelocity ?? 0;
  const t = Math.max(0, tSeconds);
  if (t === 0) return from;
  const w0 = Math.sqrt(stiffness / mass);
  const zeta = damping / (2 * Math.sqrt(stiffness * mass));
  const x0 = from - to;
  if (zeta < 1) {
    // Underdamped: e^(-ζω₀t) · (A·cos(ωd·t) + B·sin(ωd·t)).
    const wd = w0 * Math.sqrt(1 - zeta * zeta);
    const a = x0;
    const b = (v0 + zeta * w0 * x0) / wd;
    return to + Math.exp(-zeta * w0 * t) * (a * Math.cos(wd * t) + b * Math.sin(wd * t));
  }
  if (Math.abs(zeta - 1) < 1e-9) {
    // Critically damped: e^(-ω₀t) · (A + B·t).
    const a = x0;
    const b = v0 + w0 * x0;
    return to + Math.exp(-w0 * t) * (a + b * t);
  }
  // Overdamped: e^(r₁t)·A + e^(r₂t)·B.
  const root = w0 * Math.sqrt(zeta * zeta - 1);
  const r1 = -zeta * w0 + root;
  const r2 = -zeta * w0 - root;
  const a = (v0 - r2 * x0) / (r1 - r2);
  const b = x0 - a;
  return to + a * Math.exp(r1 * t) + b * Math.exp(r2 * t);
}

/** Spring position at an integer frame on the 30fps grid. */
export function springPositionAtFrame(params: SpringParams, frame: number, startFrame: number): number {
  return springPositionAtTime(params, Math.max(0, frame - startFrame) / EXTRA_STYLES_FPS);
}

// ---------------------------------------------------------------------------
// Particles — closed-form per-particle state (docs §5.2, §4.2).
// Particle i's state at frame f is a pure function of (emitter,
// i, f, seed). No RNG calls during evaluation; all randomness is
// pre-seeded. Birth frame, velocity, lifetime, size, and opacity
// curves are all closed-form.
// ---------------------------------------------------------------------------

export interface ParticleEmitterParams {
  /** Particles emitted per second. */
  rate: number;
  /** Lifetime of one particle, seconds. */
  lifetimeSeconds: number;
  /** Emitter origin, canvas fractions [0..1]. */
  originX: number;
  originY: number;
  /** Base velocity, canvas-fraction / second, + spread. */
  velocityX: number;
  velocityY: number;
  spreadX: number;
  spreadY: number;
  /** Downward acceleration, canvas-fraction / second². */
  gravity: number;
  /** Base particle size, canvas-fraction of width. */
  size: number;
  sizeSpread: number;
  /** Opacity at birth → at death. */
  opacityFrom: number;
  opacityTo: number;
}

export interface ParticleState {
  /** Visible at this frame. */
  alive: boolean;
  /** Canvas fractions. */
  x: number;
  y: number;
  /** Canvas fraction of width. */
  size: number;
  opacity: number;
}

/**
 * Particle i's state at integer `frame`. The particle's random
 * draws come from a splitmix64 stream seeded by (emitterSeed, i)
 * — stable forever. Before its birth frame or after its lifetime
 * it is dead (alive = false).
 */
export function particleStateAtFrame(
  emitter: ParticleEmitterParams,
  index: number,
  frame: number,
  emitterSeed: bigint,
  fps: number = EXTRA_STYLES_FPS,
): ParticleState {
  const dead: ParticleState = { alive: false, x: 0, y: 0, size: 0, opacity: 0 };
  if (emitter.rate <= 0 || emitter.lifetimeSeconds <= 0) return dead;
  // Birth frame: particles are born rate-per-second from frame 0,
  // each offset by its seeded phase so the field is populated
  // from the first frame (a field that starts empty looks broken).
  const random = makeSeededRandom(emitterSeed ^ BigInt(index + 1) * 0x9e3779b97f4a7c15n);
  const phase = seededDouble(random);
  const birthIntervalFrames = Math.max(1, Math.round(fps / emitter.rate));
  const birthFrame = index * birthIntervalFrames - Math.floor(phase * birthIntervalFrames);
  const ageFrames = frame - birthFrame;
  const lifetimeFrames = Math.max(1, Math.round(emitter.lifetimeSeconds * fps));
  if (ageFrames < 0 || ageFrames >= lifetimeFrames) return dead;
  const ageSeconds = ageFrames / fps;
  const lifeFrac = ageFrames / lifetimeFrames;
  const vx = emitter.velocityX + (seededDouble(random) - 0.5) * 2 * emitter.spreadX;
  const vy = emitter.velocityY + (seededDouble(random) - 0.5) * 2 * emitter.spreadY;
  const sizeFrac = emitter.size + (seededDouble(random) - 0.5) * 2 * emitter.sizeSpread;
  // Fade in over the first 10% of life, fade out over the last 30%.
  const fadeIn = Math.min(1, lifeFrac / 0.1);
  const fadeOut = lifeFrac > 0.7 ? 1 - (lifeFrac - 0.7) / 0.3 : 1;
  return {
    alive: true,
    x: emitter.originX + vx * ageSeconds,
    y: emitter.originY + vy * ageSeconds + 0.5 * emitter.gravity * ageSeconds * ageSeconds,
    size: Math.max(0, sizeFrac),
    opacity: Math.max(0, Math.min(1, emitter.opacityFrom + (emitter.opacityTo - emitter.opacityFrom) * lifeFrac))
      * fadeIn * fadeOut,
  };
}

// ---------------------------------------------------------------------------
// Path animation — arc-length parameterisation (docs §5.2): position
// at progress p is a pure function of p. No integration, no
// accumulation. Points are canvas fractions; the polyline is
// pre-measured once (the Swift builder does the same).
// ---------------------------------------------------------------------------

export interface PathPoint {
  x: number;
  y: number;
}

/** Cumulative arc lengths of a polyline (first entry 0). */
export function pathCumulativeLengths(points: PathPoint[]): number[] {
  const lengths: number[] = [0];
  for (let i = 1; i < points.length; i += 1) {
    const dx = points[i].x - points[i - 1].x;
    const dy = points[i].y - points[i - 1].y;
    lengths.push(lengths[i - 1] + Math.hypot(dx, dy));
  }
  return lengths;
}

/** Point at progress p ∈ [0, 1] along the polyline. */
export function samplePath(points: PathPoint[], progress: number): PathPoint {
  if (points.length === 0) return { x: 0, y: 0 };
  if (points.length === 1 || progress <= 0) return points[0];
  if (progress >= 1) return points[points.length - 1];
  const lengths = pathCumulativeLengths(points);
  const total = lengths[lengths.length - 1];
  if (total <= 0) return points[0];
  const target = progress * total;
  for (let i = 1; i < lengths.length; i += 1) {
    if (target <= lengths[i]) {
      const span = lengths[i] - lengths[i - 1];
      const f = span > 0 ? (target - lengths[i - 1]) / span : 0;
      return {
        x: points[i - 1].x + (points[i].x - points[i - 1].x) * f,
        y: points[i - 1].y + (points[i].y - points[i - 1].y) * f,
      };
    }
  }
  return points[points.length - 1];
}
