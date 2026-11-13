/**
 * Node tests for the Balanced-quality pure math:
 *  - src/lib/looks.ts     — the look preset catalog, intensity lerp,
 *                           override resolution, effective default.
 *  - src/lib/exportSize.ts — target-size → bitrate (mirrored exactly
 *                           by the Swift engine), size estimates.
 *  - src/lib/loudness.ts  — the auto-volume gain decision (mirrored
 *                           exactly by the Swift engine).
 * Run with: npm run test:looks
 * (tsc compiles the pure modules into tests/.build-looks, then
 * node --test runs this file against the compiled JS.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  IDENTITY_LOOK_PARAMS,
  LOOK_PARAM_RANGES,
  LOOK_PRESETS,
  DEFAULT_LOOK_PRESET_ID,
  lookPresetById,
  effectiveLook,
  isIdentityLookParams,
  resolveLookParams,
} = require('./.build-looks/src/lib/looks.js');
const {
  EXPORT_AUDIO_BITRATE_BPS,
  MIN_VIDEO_BITRATE_BPS,
  TIER_DEFAULT_VIDEO_BITRATE_BPS,
  videoBitrateForTargetSize,
  estimateExportBytes,
  formatFileSize,
} = require('./.build-looks/src/lib/exportSize.js');
const { normalizationGainDb } = require('./.build-looks/src/lib/loudness.js');

const approx = (actual, expected) =>
  assert.ok(Math.abs(actual - expected) < 1e-9, `expected ${actual} ≈ ${expected}`);

// ---- Looks: the catalog ------------------------------------------------

test('looks: at least 20 effect presets plus Original, all ids unique', () => {
  assert.ok(LOOK_PRESETS.length >= 21, `expected >= 21 presets, got ${LOOK_PRESETS.length}`);
  const ids = LOOK_PRESETS.map((p) => p.id);
  assert.equal(new Set(ids).size, ids.length);
  for (const id of [
    'original',
    'auto-enhance',
    'vivid',
    'punch',
    'crisp',
    'warm-glow',
    'golden-hour',
    'cool-tone',
    'daylight',
    'night-lift',
    'stage',
    'soft',
    'dream',
    'matte',
    'fade',
    'vintage',
    'sepia',
    'pastel',
    'rose',
    'noir',
    'mono',
  ]) {
    assert.ok(ids.includes(id), `missing preset ${id}`);
  }
});

test('looks: every preset stays inside the legal param ranges', () => {
  for (const preset of LOOK_PRESETS) {
    for (const [key, range] of Object.entries(LOOK_PARAM_RANGES)) {
      const value = preset.params[key];
      assert.ok(
        value >= range.min && value <= range.max,
        `${preset.id}.${key} = ${value} outside ${range.min}..${range.max}`,
      );
    }
    assert.ok(preset.name.length > 0 && preset.blurb.length > 0);
  }
});

test('looks: Original is exactly the identity set', () => {
  assert.deepEqual(lookPresetById('original').params, IDENTITY_LOOK_PARAMS);
  assert.ok(isIdentityLookParams(IDENTITY_LOOK_PARAMS));
  assert.equal(lookPresetById('no-such-preset').id, 'original');
});

// ---- Looks: resolution -------------------------------------------------

test('looks: the effective default is Original (no grade)', () => {
  assert.deepEqual(effectiveLook(null), { presetId: DEFAULT_LOOK_PRESET_ID, intensity: 1 });
  assert.deepEqual(effectiveLook({}), { presetId: 'original', intensity: 1 });
  assert.equal(DEFAULT_LOOK_PRESET_ID, 'original');
  assert.deepEqual(effectiveLook({ look: { presetId: 'noir', intensity: 0.5 } }), {
    presetId: 'noir',
    intensity: 0.5,
  });
});

test('looks: an unset look grades nothing in the shared preview/export path', () => {
  // The Editor preview and the Export request both resolve the
  // store's effective look through resolveLookParams — an untouched
  // project must resolve to null (no look rides the request) in both.
  assert.equal(resolveLookParams(effectiveLook(null)), null);
  assert.equal(resolveLookParams(effectiveLook({})), null);
  assert.equal(resolveLookParams(effectiveLook({ look: undefined })), null);
  // A stored choice still grades: Auto Enhance is a manual pick now,
  // not a default — and a stored Original is still identity.
  assert.notEqual(resolveLookParams(effectiveLook({ look: { presetId: 'auto-enhance', intensity: 1 } })), null);
  assert.equal(resolveLookParams(effectiveLook({ look: { presetId: 'original', intensity: 1 } })), null);
});

test('looks: identity results resolve to null (no filter rides the request)', () => {
  assert.equal(resolveLookParams(null), null);
  assert.equal(resolveLookParams({ presetId: 'original', intensity: 1 }), null);
  assert.equal(resolveLookParams({ presetId: 'vivid', intensity: 0 }), null);
});

test('looks: intensity lerps every param from identity toward the preset', () => {
  const half = resolveLookParams({ presetId: 'vivid', intensity: 0.5 });
  approx(half.saturation, 1 + (1.32 - 1) * 0.5);
  approx(half.contrast, 1 + (1.08 - 1) * 0.5);
  approx(half.vibrance, 0.4 * 0.5);
  approx(half.exposureEV, 0.05 * 0.5);
  const full = resolveLookParams({ presetId: 'vivid', intensity: 1 });
  for (const [key, value] of Object.entries(lookPresetById('vivid').params)) {
    approx(full[key], value);
  }
});

test('looks: overrides are absolute and win over the lerped preset', () => {
  const resolved = resolveLookParams({
    presetId: 'vivid',
    intensity: 0.5,
    overrides: { saturation: 0.9, temperature: 12 },
  });
  assert.equal(resolved.saturation, 0.9);
  assert.equal(resolved.temperature, 12);
  approx(resolved.contrast, 1.04); // untouched params still lerp
});

test('looks: resolved values clamp to the legal ranges', () => {
  const resolved = resolveLookParams({
    presetId: 'vivid',
    intensity: 1,
    overrides: { brightness: 5, vignette: -2 },
  });
  assert.equal(resolved.brightness, LOOK_PARAM_RANGES.brightness.max);
  assert.equal(resolved.vignette, LOOK_PARAM_RANGES.vignette.min);
});

// ---- Export size math ----------------------------------------------------

test('export size: tier defaults are the agreed known bitrates', () => {
  assert.equal(TIER_DEFAULT_VIDEO_BITRATE_BPS.tiktok, 16_000_000);
  assert.equal(TIER_DEFAULT_VIDEO_BITRATE_BPS.balanced, 8_000_000);
  assert.equal(TIER_DEFAULT_VIDEO_BITRATE_BPS.small, 4_500_000);
});

test('export size: target-size bitrate matches the engine formula', () => {
  // ((20 MB in bits) / 60s − 192k audio) × 0.94, floored.
  assert.equal(videoBitrateForTargetSize(20, 60), 2_326_186);
  assert.equal(videoBitrateForTargetSize(25, 15), 12_352_853);
  // A long video at a small target hits the floor, honestly.
  assert.equal(videoBitrateForTargetSize(10, 3600), MIN_VIDEO_BITRATE_BPS);
  assert.equal(videoBitrateForTargetSize(0, 60), MIN_VIDEO_BITRATE_BPS);
  assert.equal(videoBitrateForTargetSize(20, 0), MIN_VIDEO_BITRATE_BPS);
  // A target-sized render at the computed bitrate lands under target.
  const bytes = estimateExportBytes(videoBitrateForTargetSize(20, 60), 60);
  assert.ok(bytes <= 20_000_000, `estimated ${bytes} should fit 20 MB`);
});

test('export size: estimates and formatting', () => {
  assert.equal(estimateExportBytes(16_000_000, 60), ((16_000_000 + EXPORT_AUDIO_BITRATE_BPS) * 60) / 8);
  assert.equal(estimateExportBytes(16_000_000, 0), 0);
  assert.equal(formatFileSize(121_440_000), '121.4 MB');
  assert.equal(formatFileSize(812_000), '812 KB');
  assert.equal(formatFileSize(999), '1 KB');
});

// ---- Loudness gain decision ----------------------------------------------

test('loudness: quiet songs gain up, loud songs gain down', () => {
  assert.equal(normalizationGainDb(-20, -8), 6); // −14 target binds
  assert.equal(normalizationGainDb(-8, -0.2), -6); // loud master turns down
  assert.equal(normalizationGainDb(-14, -1), 0); // already at the level
});

test('loudness: the peak ceiling caps the gain', () => {
  assert.equal(normalizationGainDb(-20, -3), 2); // −1 −(−3) binds, not +6
  assert.equal(normalizationGainDb(-4, -0.5), -10); // target binds: −14 −(−4)
});

test('loudness: gain clamps to ±15 dB', () => {
  assert.equal(normalizationGainDb(-40, -20), 15);
  assert.equal(normalizationGainDb(0, -0.1), -14); // min(−14, −0.9)
});

test('loudness: silence and bad measurements get no gain', () => {
  assert.equal(normalizationGainDb(-65, -30), null);
  assert.equal(normalizationGainDb(-60, -30), 15); // boundary: −60 is not silence
  assert.equal(normalizationGainDb(Number.NaN, -3), null);
  assert.equal(normalizationGainDb(-20, Number.POSITIVE_INFINITY), null);
});
