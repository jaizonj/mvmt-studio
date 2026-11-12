/**
 * Mix & Master — pure curve math (Stage 1, dynamic corrective EQ).
 *
 * The analysis itself runs natively (`prepareMixMasterSong` in
 * modules/mvmt-compositor): the song is measured in 1.0 s windows
 * with 50% overlap, each window's band balance turns into per-band
 * gains (cuts only), and the curve is smoothed before it is stored
 * or rendered. These functions are the pure, platform-free half of
 * that pipeline — window layout, smoothing, and gain interpolation
 * — and the Swift engine mirrors them exactly (same constants,
 * same order of operations), so the Node tests in
 * tests/mixmaster.test.cjs pin the behaviour BOTH sides implement.
 *
 * Zero runtime imports: the compiled module loads under plain
 * `node --test` with no React Native or Expo in the room.
 */

/** Recipe version for the Stage 1 analysis + render (part of the native cache key). */
export const MIX_MASTER_PROFILE_VERSION = 1;

/** Analysis window length, seconds. */
export const MM_WINDOW_SECONDS = 1.0;
/** Hop between analysis points, seconds (50% overlap). */
export const MM_HOP_SECONDS = 0.5;
/** A window holding less than this much audio is dropped (except the first). */
export const MM_MIN_WINDOW_SECONDS = 0.25;
/** Smoothing slew limit: max gain change per 100 ms of song time. */
export const MM_SLEW_DB_PER_100MS = 1.5;

/** One smoothed analysis point: the gain set that applies at this song time. */
export interface MixMasterWindow {
  timeSeconds: number;
  /** Per-band gains in dB (cuts only, 0 … −6), same band order as Auto EQ. */
  gainsDb: number[];
}

/** One reported correction: the deepest cuts, for the "what changed and why" list. */
export interface MixMasterFinding {
  timeSeconds: number;
  bandHz: number;
  /** Positive depth of the cut in dB. */
  cutDb: number;
  reason: 'harshness' | 'mud';
}

/** The stored artifact: the smoothed curve + findings for one song. */
export interface MixMasterProfile {
  version: number;
  /** Native cache key: path|size|mtime|recipe version. */
  songKey: string;
  sampleRate: number;
  durationSeconds: number;
  windows: MixMasterWindow[];
  findings: MixMasterFinding[];
}

/**
 * Analysis-point times for a song of this duration: 0, 0.5, 1.0,
 * … while the start is inside the song. A trailing start whose
 * window would hold less than `minWindowSeconds` of audio is
 * dropped — except the first window, which is always kept so a
 * sub-second song still gets one analysis point.
 */
export function mixMasterWindowStarts(
  durationSeconds: number,
  hopSeconds: number = MM_HOP_SECONDS,
  minWindowSeconds: number = MM_MIN_WINDOW_SECONDS,
): number[] {
  // The layout depends only on hop + duration; the window length
  // matters at flush time, not here.
  if (!(durationSeconds > 0)) return [];
  const starts: number[] = [];
  for (let i = 0; ; i++) {
    const t = i * hopSeconds;
    if (t >= durationSeconds) break;
    if (i === 0 || durationSeconds - t >= minWindowSeconds) starts.push(t);
  }
  return starts;
}

/**
 * Smooths raw per-window gains — this is what makes the EQ
 * dynamic instead of a per-second switch:
 * (a) a 3-point moving average across windows, per band (edge
 * windows average over their available neighbours), then
 * (b) a slew limit applied sequentially per band: no window's gain
 * may move more than `slewDbPer100ms` per 100 ms of song time from
 * the previous window's (smoothed) gain. Gains are cuts (≤ 0), so
 * smoothing can only soften a cut, never invent a boost.
 */
export function smoothGainCurve(
  rawWindows: number[][],
  hopSeconds: number = MM_HOP_SECONDS,
  slewDbPer100ms: number = MM_SLEW_DB_PER_100MS,
): number[][] {
  if (rawWindows.length === 0) return [];
  const averaged: number[][] = rawWindows.map((gains, i) =>
    gains.map((g, b) => {
      let sum = g;
      let n = 1;
      if (i > 0) {
        sum += rawWindows[i - 1][b];
        n += 1;
      }
      if (i < rawWindows.length - 1) {
        sum += rawWindows[i + 1][b];
        n += 1;
      }
      return sum / n;
    }),
  );
  const maxStep = slewDbPer100ms * (hopSeconds / 0.1);
  const out: number[][] = [averaged[0].slice()];
  for (let i = 1; i < averaged.length; i++) {
    out.push(
      averaged[i].map((g, b) => {
        const prev = out[i - 1][b];
        return Math.max(prev - maxStep, Math.min(prev + maxStep, g));
      }),
    );
  }
  return out;
}

/**
 * The smoothed gain set at a song time: linear interpolation
 * between the bracketing analysis points, clamped to the first /
 * last window outside the range. This is what the offline render
 * evaluates once per 4096-frame block.
 */
export function mixMasterGainAtTime(
  windows: MixMasterWindow[],
  timeSeconds: number,
): number[] {
  if (windows.length === 0) return [];
  const first = windows[0];
  if (timeSeconds <= first.timeSeconds) return first.gainsDb.slice();
  const last = windows[windows.length - 1];
  if (timeSeconds >= last.timeSeconds) return last.gainsDb.slice();
  for (let i = 1; i < windows.length; i++) {
    if (timeSeconds <= windows[i].timeSeconds) {
      const a = windows[i - 1];
      const b = windows[i];
      const span = b.timeSeconds - a.timeSeconds;
      const f = span > 0 ? (timeSeconds - a.timeSeconds) / span : 0;
      return a.gainsDb.map((ga, band) => ga + (b.gainsDb[band] - ga) * f);
    }
  }
  return last.gainsDb.slice();
}
