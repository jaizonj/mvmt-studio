/**
 * Node tests for the Mix & Master Stages 1–2 curve math
 * (src/lib/mixMasterCurve.ts): window layout, smoothing (moving
 * average + slew limit), gain interpolation, stage settings, and
 * the Master EQ gain computation. The Swift engine
 * (prepareMixMasterSong) mirrors these functions exactly, so these
 * tests pin the behaviour both sides implement.
 * Run with: npm run test:mixmaster
 * (tsc compiles the pure module into tests/.build-mixmaster, then
 * node --test runs this file against the compiled JS.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  MIX_MASTER_PROFILE_VERSION,
  MM_WINDOW_SECONDS,
  MM_HOP_SECONDS,
  MM_SLEW_DB_PER_100MS,
  MM_MASTER_TARGET_DB,
  MM_MASTER_MAX_GAIN_DB,
  MM_MASTER_SILENCE_DBFS,
  DEFAULT_MIX_MASTER_STAGE_SETTINGS,
  mixMasterWindowStarts,
  smoothGainCurve,
  mixMasterGainAtTime,
  meanGainPerBand,
  computeMasterGains,
  scaleGainsTowardZero,
  resolveMixMasterStageSettings,
  mixMasterStageSettingsKey,
} = require('./.build-mixmaster/src/lib/mixMasterCurve.js');

/** Gains are computed in floating point — compare within 1e-9. */
function assertGainsClose(actual, expected, eps = 1e-9) {
  assert.equal(actual.length, expected.length, 'gain set length');
  for (let i = 0; i < expected.length; i++) {
    assert.ok(
      Math.abs(actual[i] - expected[i]) < eps,
      `band ${i}: got ${actual[i]}, expected ${expected[i]}`,
    );
  }
}

// --- Window layout -------------------------------------------------------

test('window starts: empty / non-positive durations get no windows', () => {
  assert.deepEqual(mixMasterWindowStarts(0), []);
  assert.deepEqual(mixMasterWindowStarts(-5), []);
  assert.deepEqual(mixMasterWindowStarts(NaN), []);
});

test('window starts: a sub-second song still gets one analysis point at 0', () => {
  assert.deepEqual(mixMasterWindowStarts(0.2), [0]);
  // 0.6 s: the 0.5 s start would hold only 0.1 s — dropped.
  assert.deepEqual(mixMasterWindowStarts(0.6), [0]);
  // 0.9 s: the 0.5 s start holds 0.4 s — kept.
  assert.deepEqual(mixMasterWindowStarts(0.9), [0, 0.5]);
});

test('window starts: 1.0 s windows, 50% overlap — a new point every 0.5 s', () => {
  assert.deepEqual(mixMasterWindowStarts(1.0), [0, 0.5]);
  assert.deepEqual(mixMasterWindowStarts(3.0), [0, 0.5, 1, 1.5, 2, 2.5]);
  assert.deepEqual(mixMasterWindowStarts(10), [
    0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5,
    5, 5.5, 6, 6.5, 7, 7.5, 8, 8.5, 9, 9.5,
  ]);
});

test('window starts: a trailing start with <0.25 s of audio is dropped', () => {
  // 3.1 s: start 3.0 would hold only 0.1 s — dropped.
  assert.deepEqual(mixMasterWindowStarts(3.1), [0, 0.5, 1, 1.5, 2, 2.5]);
  // 3.3 s: start 3.0 holds 0.3 s — kept.
  assert.deepEqual(mixMasterWindowStarts(3.3), [0, 0.5, 1, 1.5, 2, 2.5, 3]);
  // Exactly 0.25 s of audio is enough.
  assert.deepEqual(mixMasterWindowStarts(2.75), [0, 0.5, 1, 1.5, 2, 2.5]);
});

// --- Smoothing -----------------------------------------------------------

test('smoothing: an all-zero curve stays all-zero (no cut anywhere)', () => {
  const raw = [[0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]];
  assert.deepEqual(smoothGainCurve(raw), raw);
});

test('smoothing: the 3-point moving average softens a one-window spike', () => {
  // A single harsh window (-6 dB in band 0) between clean neighbours.
  const raw = [[0], [-6], [0], [0]];
  const out = smoothGainCurve(raw);
  // Window 0 averages windows 0+1: -3. Window 1 averages 0+1+2: -2.
  // Window 2 averages 1+2+3: -2. Window 3 averages 2+3: 0.
  assert.deepEqual(out, [[-3], [-2], [-2], [0]]);
});

test('smoothing: the slew limit caps how fast a gain may move', () => {
  // Hop 0.1 s with the 1.5 dB / 100 ms limit: at most 1.5 dB per step.
  // A raw step from 0 to -6 must ramp 0, -1.5, -3, -4.5, -6.
  // (The moving average first softens the step to 0, -2, -4, -6, -6;
  // the slew then clamps each hop to 1.5 dB.)
  const raw = [[0], [0], [-6], [-6], [-6]];
  const out = smoothGainCurve(raw, 0.1, MM_SLEW_DB_PER_100MS);
  assert.deepEqual(out, [[0], [-1.5], [-3], [-4.5], [-6]]);
});

test('smoothing: at the real 0.5 s hop the limit is 7.5 dB, so a full 6 dB cut passes', () => {
  const raw = [[0], [-6], [-6]];
  const out = smoothGainCurve(raw, MM_HOP_SECONDS, MM_SLEW_DB_PER_100MS);
  // Moving average: [-3, -4, -6]; every hop is within 7.5 dB.
  assert.deepEqual(out, [[-3], [-4], [-6]]);
});

test('smoothing: smoothing can only soften cuts, never invent a boost', () => {
  const raw = [[0, -2], [-6, -4], [0, -6], [-3, 0]];
  const out = smoothGainCurve(raw);
  for (let i = 0; i < out.length; i++) {
    for (let b = 0; b < 2; b++) {
      assert.ok(out[i][b] <= 0, `window ${i} band ${b} must stay a cut`);
      assert.ok(out[i][b] >= -6, `window ${i} band ${b} must stay within the max cut`);
    }
  }
});

test('smoothing: empty input stays empty', () => {
  assert.deepEqual(smoothGainCurve([]), []);
});

// --- Interpolation -------------------------------------------------------

function windows(times, gains) {
  return times.map((t, i) => ({ timeSeconds: t, gainsDb: gains[i] }));
}

test('gain at time: exact window times return that window, clamped outside', () => {
  const w = windows([0, 0.5, 1], [[0], [-4], [-2]]);
  assert.deepEqual(mixMasterGainAtTime(w, 0), [0]);
  assert.deepEqual(mixMasterGainAtTime(w, 0.5), [-4]);
  assert.deepEqual(mixMasterGainAtTime(w, 1), [-2]);
  assert.deepEqual(mixMasterGainAtTime(w, -1), [0]);
  assert.deepEqual(mixMasterGainAtTime(w, 99), [-2]);
});

test('gain at time: midpoints interpolate linearly between analysis points', () => {
  const w = windows([0, 0.5, 1], [[0, -6], [-4, -2], [-2, 0]]);
  assert.deepEqual(mixMasterGainAtTime(w, 0.25), [-2, -4]);
  assert.deepEqual(mixMasterGainAtTime(w, 0.75), [-3, -1]);
});

test('gain at time: no windows means no gains', () => {
  assert.deepEqual(mixMasterGainAtTime([], 1.5), []);
});

// --- Profile constants ---------------------------------------------------

test('profile constants: the documented Stage 1 shape', () => {
  // Recipe version 2 (Stage 2: the Master EQ stage joined the
  // chain, so Stage 1 renders must never be served).
  assert.equal(MIX_MASTER_PROFILE_VERSION, 2);
  assert.equal(MM_WINDOW_SECONDS, 1.0);
  assert.equal(MM_HOP_SECONDS, 0.5);
  assert.equal(MM_SLEW_DB_PER_100MS, 1.5);
});

// --- Master EQ (Stage 2) -------------------------------------------------

test('master target curve: slight low shelf, flat mids, gentle high shelf', () => {
  assert.deepEqual([...MM_MASTER_TARGET_DB], [1.5, 1.0, 0.5, 0, 0, 0, 0, 0.5, 1.0, 1.5]);
  assert.equal(MM_MASTER_MAX_GAIN_DB, 3);
  assert.equal(MM_MASTER_SILENCE_DBFS, -60);
});

test('master gains: a flat song gets the target shape (minus its mean)', () => {
  // All bands at -20 dB, no corrective cuts: the reference is
  // -20.6 (mean of level − target), so each band's gain is its
  // target value minus 0.6.
  const levels = new Array(10).fill(-20);
  const gains = computeMasterGains(levels, new Array(10).fill(0), -20);
  assertGainsClose(gains, [0.9, 0.4, -0.1, -0.6, -0.6, -0.6, -0.6, -0.1, 0.4, 0.9]);
});

test('master gains: a +6 dB bump at 3 kHz is cut, clamped to −3 dB', () => {
  const levels = new Array(10).fill(-20);
  levels[5] = -14; // 3 kHz, 6 dB hot against the rest
  const gains = computeMasterGains(levels, new Array(10).fill(0), -20);
  assert.equal(gains[5], -3); // −6 dB needed, clamped to the ±3 dB cap
  assertGainsClose([gains[0], gains[3], gains[9]], [1.5, 0, 1.5]);
});

test('master gains: a near-silent song gets no master EQ at all', () => {
  const levels = new Array(10).fill(-80);
  assert.deepEqual(computeMasterGains(levels, new Array(10).fill(0), -70), new Array(10).fill(0));
  assert.deepEqual(computeMasterGains([], [], -20), []);
});

test('master gains: a dead band stays flat and out of the reference', () => {
  // No content at 12 kHz: it must neither drag the reference
  // nor be boosted into noise.
  const levels = new Array(10).fill(-20);
  levels[9] = -120;
  const gains = computeMasterGains(levels, new Array(10).fill(0), -20);
  assert.equal(gains[9], 0);
  // Reference over the 9 live bands only: (−180 − 4.5) / 9 = −20.5.
  assertGainsClose([gains[0], gains[3]], [1.0, -0.5]);
});

test('master gains: measured on the CORRECTED balance, not the raw song', () => {
  // Flat song, but the corrective stage already cut 125 Hz by
  // 6 dB: the master sees the cut balance, so it boosts 125 Hz
  // back toward the target (clamped) instead of cutting it twice.
  const levels = new Array(10).fill(-20);
  const meanCorrective = new Array(10).fill(0);
  meanCorrective[0] = -6;
  const gains = computeMasterGains(levels, meanCorrective, -20);
  assert.equal(gains[0], 3);
  assertGainsClose([gains[3]], [-1.2]);
});

test('mean gain per band: averages the stored windows', () => {
  assert.deepEqual(
    meanGainPerBand([
      { timeSeconds: 0, gainsDb: [0, -2] },
      { timeSeconds: 0.5, gainsDb: [-4, -6] },
    ]),
    [-2, -4],
  );
  assert.deepEqual(meanGainPerBand([]), []);
});

test('intensity scaling: gains move toward 0, never past it', () => {
  assertGainsClose(scaleGainsTowardZero([3, -2, 0], 50), [1.5, -1, 0]);
  // (Compared numerically: −2 × 0 is −0 in JS, which deepStrictEqual
  // distinguishes from 0 even though the values are identical.)
  assertGainsClose(scaleGainsTowardZero([3, -2, 0], 0), [0, 0, 0]);
  assert.deepEqual(scaleGainsTowardZero([3, -2, 0], 100), [3, -2, 0]);
  assert.deepEqual(scaleGainsTowardZero([3, -2, 0], 150), [3, -2, 0]);
  assert.deepEqual(scaleGainsTowardZero([3, -2, 0], -10), [0, 0, 0]);
});

test('stage settings: unset reads as both stages ON at 100%', () => {
  assert.deepEqual(resolveMixMasterStageSettings(), DEFAULT_MIX_MASTER_STAGE_SETTINGS);
  assert.deepEqual(resolveMixMasterStageSettings({ masterIntensity: 50 }), {
    correctiveEnabled: true,
    correctiveIntensity: 100,
    masterEnabled: true,
    masterIntensity: 50,
  });
  assert.equal(resolveMixMasterStageSettings({ correctiveEnabled: false }).correctiveEnabled, false);
});

test('stage settings: intensities are clamped, non-numbers fall back to 100', () => {
  assert.equal(resolveMixMasterStageSettings({ correctiveIntensity: 150 }).correctiveIntensity, 100);
  assert.equal(resolveMixMasterStageSettings({ correctiveIntensity: -5 }).correctiveIntensity, 0);
  assert.equal(resolveMixMasterStageSettings({ masterIntensity: NaN }).masterIntensity, 100);
});

test('stage settings key: stable for identical settings, changes with any setting', () => {
  const base = mixMasterStageSettingsKey(DEFAULT_MIX_MASTER_STAGE_SETTINGS);
  assert.equal(base, 'c1:100|m1:100');
  assert.equal(mixMasterStageSettingsKey({ ...DEFAULT_MIX_MASTER_STAGE_SETTINGS }), base);
  assert.notEqual(
    mixMasterStageSettingsKey({ ...DEFAULT_MIX_MASTER_STAGE_SETTINGS, masterIntensity: 50 }),
    base,
  );
  assert.notEqual(
    mixMasterStageSettingsKey({ ...DEFAULT_MIX_MASTER_STAGE_SETTINGS, correctiveEnabled: false }),
    base,
  );
});
