/**
 * Node tests for the Mix & Master curve math (src/lib/mixMasterCurve.ts):
 * window layout, smoothing (moving average + slew limit), gain
 * interpolation, stage settings, and the Master EQ gain computation.
 * The Swift engine (prepareMixMasterSong) mirrors these functions
 * exactly, so these tests pin the behaviour both sides implement.
 * Plus the Stage 4 export pure half (src/lib/mixMasterExport.ts):
 * export file names, uniqueness, and the use-in-project / restore
 * state transitions.
 * Run with: npm run test:mixmaster
 * (tsc compiles the pure modules into tests/.build-mixmaster, then
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
  MM_BAND_CENTERS_HZ,
  DEFAULT_MIX_MASTER_STAGE_SETTINGS,
  mixMasterWindowStarts,
  smoothGainCurve,
  mixMasterGainAtTime,
  meanGainPerBand,
  computeMasterGains,
  scaleGainsTowardZero,
  resolveMixMasterStageSettings,
  mixMasterStageSettingsKey,
  formatBandHz,
  shortBandLabelHz,
  formatMixMasterTime,
  parseMixMasterProfile,
  summarizeMixMasterProfile,
  formatMixMasterFinding,
  formatMixMasterSummary,
  windowTotalCutDb,
  mixMasterActivityBars,
} = require('./.build-mixmaster/src/lib/mixMasterCurve.js');
const {
  MM_EXPORT_FOLDER,
  mixMasterExportBaseName,
  mixMasterExportFileName,
  mixMasterExportMimeType,
  resolveMixMasterExportFileName,
  mixMasterUseInProjectPatch,
  mixMasterRestoreOriginalPatch,
} = require('./.build-mixmaster/src/lib/mixMasterExport.js');

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

// --- Stage 3 UI: profile reading + display -------------------------------

/** A minimal valid profile, as the native engine writes it. */
function validProfile(overrides = {}) {
  return {
    version: 2,
    songKey: 'song|1|2|mmv2|c1:100|m1:100',
    sampleRate: 48000,
    durationSeconds: 10,
    windows: [
      { timeSeconds: 0, gainsDb: [0, 0, 0, 0, -2, -4, 0, 0, 0, 0] },
      { timeSeconds: 0.5, gainsDb: [0, -1, 0, 0, 0, -3, -1, 0, 0, 0] },
    ],
    findings: [
      { timeSeconds: 0, bandHz: 3000, cutDb: 4, reason: 'harshness' },
      { timeSeconds: 0.5, bandHz: 250, cutDb: 1.5, reason: 'mud' },
    ],
    masterGainsDb: [1, 0.5, 0, 0, 0, 0, 0, 0, 0.5, 1],
    stages: { correctiveEnabled: true, correctiveIntensity: 100, masterEnabled: true, masterIntensity: 100 },
    ...overrides,
  };
}

test('band centres: 10 bands, same order as Auto EQ, strictly increasing', () => {
  assert.equal(MM_BAND_CENTERS_HZ.length, 10);
  assert.equal(MM_BAND_CENTERS_HZ[0], 125);
  assert.equal(MM_BAND_CENTERS_HZ[9], 12000);
  for (let i = 1; i < MM_BAND_CENTERS_HZ.length; i++) {
    assert.ok(MM_BAND_CENTERS_HZ[i] > MM_BAND_CENTERS_HZ[i - 1]);
  }
});

test('band labels: Hz below 1 kHz, kHz at and above', () => {
  assert.equal(formatBandHz(125), '125 Hz');
  assert.equal(formatBandHz(500), '500 Hz');
  assert.equal(formatBandHz(1000), '1 kHz');
  assert.equal(formatBandHz(3000), '3 kHz');
  assert.equal(formatBandHz(12000), '12 kHz');
  assert.equal(shortBandLabelHz(125), '125');
  assert.equal(shortBandLabelHz(1000), '1k');
  assert.equal(shortBandLabelHz(12000), '12k');
});

test('profile time: m:ss, floored, never negative', () => {
  assert.equal(formatMixMasterTime(0), '0:00');
  assert.equal(formatMixMasterTime(42), '0:42');
  assert.equal(formatMixMasterTime(125), '2:05');
  assert.equal(formatMixMasterTime(-3), '0:00');
});

test('profile parse: a valid profile round-trips', () => {
  const parsed = parseMixMasterProfile(validProfile());
  assert.ok(parsed);
  assert.equal(parsed.version, 2);
  assert.equal(parsed.durationSeconds, 10);
  assert.equal(parsed.windows.length, 2);
  assert.equal(parsed.findings.length, 2);
  assert.deepEqual(parsed.masterGainsDb, [1, 0.5, 0, 0, 0, 0, 0, 0, 0.5, 1]);
  assert.deepEqual(parsed.stages, DEFAULT_MIX_MASTER_STAGE_SETTINGS);
});

test('profile parse: rejects wrong version, short gain sets, bad reasons, NaN', () => {
  assert.equal(parseMixMasterProfile(null), null);
  assert.equal(parseMixMasterProfile('nope'), null);
  assert.equal(parseMixMasterProfile(validProfile({ version: 1 })), null);
  assert.equal(parseMixMasterProfile(validProfile({ version: 3 })), null);
  assert.equal(parseMixMasterProfile(validProfile({ songKey: '' })), null);
  assert.equal(parseMixMasterProfile(validProfile({ sampleRate: 0 })), null);
  assert.equal(
    parseMixMasterProfile(validProfile({ masterGainsDb: [0, 0, 0] })),
    null,
  );
  assert.equal(
    parseMixMasterProfile(
      validProfile({ windows: [{ timeSeconds: 0, gainsDb: [0, 0] }] }),
    ),
    null,
  );
  assert.equal(
    parseMixMasterProfile(
      validProfile({ findings: [{ timeSeconds: 0, bandHz: 3000, cutDb: 2, reason: 'loud' }] }),
    ),
    null,
  );
  assert.equal(
    parseMixMasterProfile(
      validProfile({ findings: [{ timeSeconds: 0, bandHz: 3000, cutDb: NaN, reason: 'harshness' }] }),
    ),
    null,
  );
  assert.equal(parseMixMasterProfile(validProfile({ windows: 'nope' })), null);
});

test('profile parse: missing stage settings resolve to the defaults', () => {
  const parsed = parseMixMasterProfile(validProfile({ stages: undefined }));
  assert.ok(parsed);
  assert.deepEqual(parsed.stages, DEFAULT_MIX_MASTER_STAGE_SETTINGS);
});

test('profile summary: counts cuts, finds the deepest, reads the master', () => {
  const summary = summarizeMixMasterProfile(parseMixMasterProfile(validProfile()));
  assert.equal(summary.totalCuts, 2);
  assert.equal(summary.deepestCutDb, 4);
  assert.equal(summary.deepestBandHz, 3000);
  assert.equal(summary.deepestTimeSeconds, 0);
  assert.equal(summary.masterMaxAbsDb, 1);
  assert.equal(summary.hasCorrections, true);
});

test('profile summary: an all-flat profile has no corrections', () => {
  const flat = validProfile({
    windows: [{ timeSeconds: 0, gainsDb: new Array(10).fill(0) }],
    findings: [],
    masterGainsDb: new Array(10).fill(0),
  });
  const summary = summarizeMixMasterProfile(parseMixMasterProfile(flat));
  assert.equal(summary.totalCuts, 0);
  assert.equal(summary.deepestCutDb, 0);
  assert.equal(summary.deepestBandHz, null);
  assert.equal(summary.masterMaxAbsDb, 0);
  assert.equal(summary.hasCorrections, false);
});

test('profile summary line: cuts + deepest, or the already-balanced line', () => {
  assert.equal(
    formatMixMasterSummary(parseMixMasterProfile(validProfile())),
    '2 cuts · deepest −4.0 dB at 3 kHz (0:00) · master up to 1.0 dB',
  );
  const flat = validProfile({
    windows: [{ timeSeconds: 0, gainsDb: new Array(10).fill(0) }],
    findings: [],
    masterGainsDb: new Array(10).fill(0),
  });
  assert.equal(
    formatMixMasterSummary(parseMixMasterProfile(flat)),
    'No corrections needed — this song is already balanced.',
  );
});

test('finding format: band, depth, time, reason', () => {
  assert.equal(
    formatMixMasterFinding({ timeSeconds: 42, bandHz: 3000, cutDb: 4.2, reason: 'harshness' }),
    '3 kHz −4.2 dB at 0:42 — harshness',
  );
  assert.equal(
    formatMixMasterFinding({ timeSeconds: 70, bandHz: 250, cutDb: 3, reason: 'mud' }),
    '250 Hz −3.0 dB at 1:10 — mud',
  );
});

test('window total cut: sums only the cuts, ignores boosts and flats', () => {
  assert.equal(windowTotalCutDb({ timeSeconds: 0, gainsDb: [0, -2, 0, 0, -4, 0, 0, 0, 0, 0] }), 6);
  assert.equal(windowTotalCutDb({ timeSeconds: 0, gainsDb: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0] }), 0);
});

test('activity bars: exact count, max-preserving, empty profile is flat', () => {
  const profile = parseMixMasterProfile(validProfile());
  const bars = mixMasterActivityBars(profile, 4);
  assert.equal(bars.length, 4);
  // Windows total 6 and 5 dB; downsampling to 4 bars keeps the max per slice.
  assert.equal(Math.max(...bars), 6);
  const flat = validProfile({
    windows: [{ timeSeconds: 0, gainsDb: new Array(10).fill(0) }],
    findings: [],
    masterGainsDb: new Array(10).fill(0),
  });
  assert.deepEqual(mixMasterActivityBars(parseMixMasterProfile(flat), 3), [0, 0, 0]);
  assert.deepEqual(mixMasterActivityBars(parseMixMasterProfile(validProfile({ windows: [] })), 3), [0, 0, 0]);
});

// --- Stage 4 export: file names -------------------------------------------

test('export base name: strips the extension, sanitises, falls back to Song', () => {
  assert.equal(mixMasterExportBaseName('My Song.mp3'), 'My Song');
  assert.equal(mixMasterExportBaseName('track'), 'track');
  assert.equal(mixMasterExportBaseName('a/b:c*d?e"f<g>h|i.wav'), 'abcdefghi');
  assert.equal(mixMasterExportBaseName('  spaced   out  .m4a'), 'spaced out');
  assert.equal(mixMasterExportBaseName('   .mp3'), 'Song');
  assert.equal(mixMasterExportBaseName(''), 'Song');
  assert.equal(mixMasterExportBaseName('x'.repeat(150) + '.wav').length, 100);
});

test('export file name: suffix + extension per format', () => {
  assert.equal(
    mixMasterExportFileName('My Song.mp3', 'wav'),
    'My Song (MVMT Mix & Master).wav',
  );
  assert.equal(
    mixMasterExportFileName('My Song.mp3', 'aac'),
    'My Song (MVMT Mix & Master).m4a',
  );
});

test('export file name uniqueness: first free name wins, counting up', () => {
  const taken = new Set(['My Song (MVMT Mix & Master).wav']);
  assert.equal(
    resolveMixMasterExportFileName('My Song (MVMT Mix & Master).wav', (n) => taken.has(n)),
    'My Song (MVMT Mix & Master) 2.wav',
  );
  taken.add('My Song (MVMT Mix & Master) 2.wav');
  assert.equal(
    resolveMixMasterExportFileName('My Song (MVMT Mix & Master).wav', (n) => taken.has(n)),
    'My Song (MVMT Mix & Master) 3.wav',
  );
  assert.equal(
    resolveMixMasterExportFileName('Fresh (MVMT Mix & Master).m4a', (n) => taken.has(n)),
    'Fresh (MVMT Mix & Master).m4a',
  );
});

test('export mime types: wav and aac', () => {
  assert.equal(mixMasterExportMimeType('wav'), 'audio/wav');
  assert.equal(mixMasterExportMimeType('aac'), 'audio/mp4');
});

test('export folder is the user-visible Documents/exports folder', () => {
  assert.equal(MM_EXPORT_FOLDER, 'exports');
});

// --- Stage 4 export: use-in-project / restore ----------------------------

const originalTrack = {
  uri: 'file:///tracks/song.mp3',
  name: 'My Song.mp3',
  durationSeconds: 180,
};

test('use-in-project patch: track becomes the export, original recorded, suite off', () => {
  const patch = mixMasterUseInProjectPatch(
    originalTrack,
    'file:///exports/My Song (MVMT Mix & Master).wav',
    'My Song (MVMT Mix & Master).wav',
  );
  assert.equal(patch.track.uri, 'file:///exports/My Song (MVMT Mix & Master).wav');
  assert.equal(patch.track.name, 'My Song (MVMT Mix & Master).wav');
  // The render is the exact frame count — the duration carries over,
  // so the region, the EDL and every take's sync offset stay valid.
  assert.equal(patch.track.durationSeconds, 180);
  assert.equal(patch.mixMasterEnabled, false);
  assert.equal(patch.autoEqEnabled, false);
  assert.deepEqual(patch.mixMasterSource, { uri: originalTrack.uri, name: originalTrack.name });
});

test('use-in-project patch: a second apply never overwrites the true original', () => {
  const first = mixMasterUseInProjectPatch(
    originalTrack,
    'file:///exports/My Song (MVMT Mix & Master).wav',
    'My Song (MVMT Mix & Master).wav',
  );
  const second = mixMasterUseInProjectPatch(
    first.track,
    'file:///exports/My Song (MVMT Mix & Master) 2.wav',
    'My Song (MVMT Mix & Master) 2.wav',
    first.mixMasterSource,
  );
  assert.equal(second.track.uri, 'file:///exports/My Song (MVMT Mix & Master) 2.wav');
  assert.deepEqual(second.mixMasterSource, { uri: originalTrack.uri, name: originalTrack.name });
});

test('restore patch: track back to the original, suite back on, source cleared', () => {
  const patch = mixMasterRestoreOriginalPatch(
    { uri: originalTrack.uri, name: originalTrack.name },
    180,
  );
  assert.equal(patch.track.uri, originalTrack.uri);
  assert.equal(patch.track.name, originalTrack.name);
  assert.equal(patch.track.durationSeconds, 180);
  assert.equal(patch.mixMasterEnabled, true);
  assert.equal(patch.mixMasterSource, undefined);
});

test('restore patch: a track without a known duration keeps none', () => {
  const patch = mixMasterRestoreOriginalPatch({ uri: 'file:///x.mp3', name: 'x.mp3' });
  assert.equal(patch.track.durationSeconds, undefined);
});
