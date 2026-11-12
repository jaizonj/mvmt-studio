/**
 * Node tests for the Mix & Master Stage 1 curve math
 * (src/lib/mixMasterCurve.ts): window layout, smoothing (moving
 * average + slew limit), and gain interpolation. The Swift engine
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
  mixMasterWindowStarts,
  smoothGainCurve,
  mixMasterGainAtTime,
} = require('./.build-mixmaster/src/lib/mixMasterCurve.js');

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
  assert.equal(MIX_MASTER_PROFILE_VERSION, 1);
  assert.equal(MM_WINDOW_SECONDS, 1.0);
  assert.equal(MM_HOP_SECONDS, 0.5);
  assert.equal(MM_SLEW_DB_PER_100MS, 1.5);
});
