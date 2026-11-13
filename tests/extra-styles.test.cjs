/**
 * Node tests for Extra Styles 2.0 Phase 2 — the core engine's
 * pure-TypeScript halves:
 *  - src/lib/extra-styles/animation.ts  — the evaluator math spec
 *    (seeded RNG, easings, keyframes, analytic springs, particles,
 *    path sampling). The Swift evaluator ports these formulas
 *    exactly; these tests are the determinism proof.
 *  - src/lib/extra-styles/params.ts    — parameter schemas.
 *  - src/lib/extra-styles/interpretation.ts — lyric interpretation
 *    (sections, semantic tags, syllable heuristic).
 *  - src/lib/extra-styles/catalog.ts   — the 40-style capability
 *    mapping (coverage spec) + catalog helpers.
 *  - src/lib/extra-styles/automation.ts — automation sampling.
 *  - src/lib/extra-styles/persistence.ts — state validation +
 *    v1-template retirement migration.
 *  - src/lib/extra-styles/scene.ts     — scene-build input,
 *    including the unconditional intelligence passthrough (the
 *    v1 Emoji Story failure must not recur).
 * Run with: npm run test:extra-styles
 * (tsc compiles the pure modules into tests/.build-extra-styles,
 * then node --test runs this file against the compiled JS.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');

const {
  splitmix64Next,
  makeSeededRandom,
  seededDouble,
  applyEasing,
  cubicBezierEasing,
  interpolateKeyframes,
  interpolateColorKeyframes,
  springPositionAtTime,
  springPositionAtFrame,
  particleStateAtFrame,
  samplePath,
} = require('./.build-extra-styles/src/lib/extra-styles/animation.js');
const {
  defaultParams,
  resolveExtraStyleParams,
  applyExtraStylePreset,
  paramsNeedSceneRebuild,
} = require('./.build-extra-styles/src/lib/extra-styles/params.js');
const {
  analyzeSemanticTags,
  fnv1a32,
  lyricsHash,
  detectSections,
  buildLyricInterpretation,
  splitWordIntoSyllables,
} = require('./.build-extra-styles/src/lib/extra-styles/interpretation.js');
const {
  STYLE_CAPABILITY_MAP,
  missingEngineCapabilities,
  userVisibleStyles,
  searchExtraStyleCatalog,
  filterExtraStylesByCategory,
  sortExtraStylesWithFavoritesFirst,
} = require('./.build-extra-styles/src/lib/extra-styles/catalog.js');
const {
  sampleOnset,
  sampleBandEnergies,
  sampleLoudness,
  beatPhaseAtFrame,
  automationHasConfidentBeat,
  emptyAutomation,
} = require('./.build-extra-styles/src/lib/extra-styles/automation.js');
const {
  V1_TEMPLATE_SUCCESSORS,
  migrateV1Template,
  validateExtraStyleState,
} = require('./.build-extra-styles/src/lib/extra-styles/persistence.js');
const {
  deriveExtraStyleSeed,
  buildExtraStyleSceneInput,
} = require('./.build-extra-styles/src/lib/extra-styles/scene.js');
const { ENGINE_CAPABILITIES } = require('./.build-extra-styles/src/lib/extra-styles/types.js');

const approx = (actual, expected, tol = 1e-9) =>
  assert.ok(Math.abs(actual - expected) < tol, `expected ${actual} ≈ ${expected} (±${tol})`);

// ---- Animation: seeded randomness ---------------------------------------

test('animation: splitmix64 matches the reference vectors', () => {
  // Reference vectors computed from the splitmix64 definition
  // (seed 0 first output e220a8397b1dcdaf is the published vector).
  let state = 0n;
  const expected0 = ['e220a8397b1dcdaf', '6e789e6aa1b965f4', '6c45d188009454f'];
  for (const expected of expected0) {
    const out = splitmix64Next(state);
    state = out.state;
    assert.equal(out.value.toString(16), expected);
  }
  state = 1n;
  const expected1 = ['910a2dec89025cc1', 'beeb8da1658eec67', 'f893a2eefb32555e'];
  for (const expected of expected1) {
    const out = splitmix64Next(state);
    state = out.state;
    assert.equal(out.value.toString(16), expected);
  }
});

test('animation: same seed → same sequence; different seed → different', () => {
  const a = makeSeededRandom(42n);
  const b = makeSeededRandom(42n);
  const c = makeSeededRandom(43n);
  const seqA = [a(), a(), a()];
  const seqB = [b(), b(), b()];
  const seqC = [c(), c(), c()];
  assert.deepEqual(seqA, seqB);
  assert.notDeepEqual(seqA, seqC);
  for (const v of seqA) {
    assert.ok(v >= 0n && v < 2n ** 64n);
    assert.ok(seededDouble(makeSeededRandom(v)) >= 0);
    assert.ok(seededDouble(makeSeededRandom(v)) < 1);
  }
});

// ---- Animation: easings + keyframes --------------------------------------

test('animation: easings hit their endpoints and stay in range', () => {
  for (const easing of ['linear', 'easeInCubic', 'easeOutCubic', 'easeInOutCubic', 'easeOutSine', 'easeInOutSine', 'easeOutBack']) {
    assert.equal(applyEasing(easing, 0), 0);
    assert.equal(applyEasing(easing, 1), 1);
    for (let t = 0; t <= 1.001; t += 0.05) {
      const v = applyEasing(easing, t);
      assert.ok(Number.isFinite(v), `${easing}(${t}) not finite`);
    }
  }
  approx(applyEasing('easeOutCubic', 0.5), 0.875);
  approx(applyEasing('easeInCubic', 0.5), 0.125);
});

test('animation: cubic-bezier identity is identity; endpoints hold', () => {
  const identity = cubicBezierEasing(0, 0, 1, 1);
  for (const t of [0, 0.25, 0.5, 0.75, 1]) approx(identity(t), t, 1e-4);
  const ease = cubicBezierEasing(0.25, 0.1, 0.25, 1);
  assert.equal(ease(0), 0);
  assert.equal(ease(1), 1);
  assert.ok(ease(0.5) > 0.5, 'standard ease is fast in the middle');
});

test('animation: keyframes clamp outside and ease between', () => {
  const keys = [
    { frame: 10, value: 0 },
    { frame: 20, value: 10, easing: 'linear' },
    { frame: 30, value: 10 },
  ];
  assert.equal(interpolateKeyframes(keys, 0), 0);
  assert.equal(interpolateKeyframes(keys, 10), 0);
  approx(interpolateKeyframes(keys, 15), 5);
  assert.equal(interpolateKeyframes(keys, 20), 10);
  assert.equal(interpolateKeyframes(keys, 99), 10);
  assert.equal(interpolateKeyframes([], 5), 0);
  // Eased segment: easeOutCubic at midpoint is 0.875 of the way.
  const eased = [
    { frame: 0, value: 0 },
    { frame: 10, value: 100, easing: 'easeOutCubic' },
  ];
  approx(interpolateKeyframes(eased, 5), 87.5);
  const color = interpolateColorKeyframes(
    [
      { frame: 0, rgba: [1, 0, 0, 1] },
      { frame: 10, rgba: [0, 0, 1, 1], easing: 'linear' },
    ],
    5,
  );
  assert.deepEqual(color.map((v) => Math.round(v * 1000) / 1000), [0.5, 0, 0.5, 1]);
});

// ---- Animation: springs ---------------------------------------------------

test('animation: spring starts at `from` and settles at `to`', () => {
  const params = { from: 0, to: 100, stiffness: 120, damping: 12 };
  assert.equal(springPositionAtTime(params, 0), 0);
  approx(springPositionAtTime(params, 5), 100, 0.01);
  approx(springPositionAtFrame(params, 0, 0), 0);
  approx(springPositionAtFrame(params, 150, 0), 100, 0.01);
  // Critically damped and overdamped settle too.
  approx(springPositionAtTime({ from: 0, to: 10, stiffness: 100, damping: 20 }, 5), 10, 0.01);
  approx(springPositionAtTime({ from: 0, to: 10, stiffness: 100, damping: 40 }, 5), 10, 0.01);
});

test('animation: analytic spring matches numerical integration', () => {
  // RK4 reference for an underdamped spring — the closed form must
  // agree with the physics, not just with itself.
  const k = 80;
  const c = 6;
  const target = 50;
  let x = 0;
  let v = 0;
  const dt = 0.0005;
  const steps = Math.round(1.0 / dt);
  for (let i = 0; i < steps; i += 1) {
    const acc = (x0, v0) => -k * (x0 - target) - c * v0;
    const k1v = acc(x, v);
    const k1x = v;
    const k2v = acc(x + (k1x * dt) / 2, v + (k1v * dt) / 2);
    const k2x = v + (k1v * dt) / 2;
    const k3v = acc(x + (k2x * dt) / 2, v + (k2v * dt) / 2);
    const k3x = v + (k2v * dt) / 2;
    const k4v = acc(x + k3x * dt, v + k3v * dt);
    const k4x = v + k3v * dt;
    x += (dt / 6) * (k1x + 2 * k2x + 2 * k3x + k4x);
    v += (dt / 6) * (k1v + 2 * k2v + 2 * k3v + k4v);
  }
  approx(springPositionAtTime({ from: 0, to: target, stiffness: k, damping: c }, 1.0), x, 0.05);
});

// ---- Animation: particles + paths -----------------------------------------

test('animation: particle state is a pure function of (emitter, i, frame, seed)', () => {
  const emitter = {
    rate: 10, lifetimeSeconds: 2, originX: 0.5, originY: 0.5,
    velocityX: 0, velocityY: -0.1, spreadX: 0.05, spreadY: 0.02,
    gravity: 0.05, size: 0.02, sizeSpread: 0.005, opacityFrom: 1, opacityTo: 0,
  };
  const a = particleStateAtFrame(emitter, 3, 45, 123n);
  const b = particleStateAtFrame(emitter, 3, 45, 123n);
  assert.deepEqual(a, b, 'same inputs → same particle');
  assert.notDeepEqual(
    particleStateAtFrame(emitter, 3, 45, 123n),
    particleStateAtFrame(emitter, 4, 45, 123n),
  );
  // Dead before birth and after its lifetime.
  assert.equal(particleStateAtFrame(emitter, 50, 0, 123n).alive, false);
  assert.equal(particleStateAtFrame(emitter, 0, 1000, 123n).alive, false);
  // Alive mid-life, inside the canvas, opacity in range.
  const mid = particleStateAtFrame(emitter, 0, 30, 123n);
  assert.equal(mid.alive, true);
  assert.ok(mid.x >= -0.5 && mid.x <= 1.5);
  assert.ok(mid.opacity >= 0 && mid.opacity <= 1);
  assert.ok(mid.size > 0);
  // Zero rate emits nothing, ever.
  assert.equal(particleStateAtFrame({ ...emitter, rate: 0 }, 0, 30, 123n).alive, false);
});

test('animation: path sampling is arc-length pure', () => {
  const line = [{ x: 0, y: 0 }, { x: 1, y: 0 }];
  assert.deepEqual(samplePath(line, 0), { x: 0, y: 0 });
  assert.deepEqual(samplePath(line, 1), { x: 1, y: 0 });
  assert.deepEqual(samplePath(line, 0.5), { x: 0.5, y: 0 });
  // An L-shape: halfway along the length is the corner.
  const l = [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 1, y: 1 }];
  const mid = samplePath(l, 0.5);
  approx(mid.x, 1);
  approx(mid.y, 0);
  assert.deepEqual(samplePath([], 0.5), { x: 0, y: 0 });
});

// ---- Parameters -------------------------------------------------------------

const SCHEMA = [
  { id: 'gravity', label: 'Gravity', kind: 'slider', min: 0, max: 2, step: 0.1, default: 0.5, affects: 'motion' },
  { id: 'density', label: 'Density', kind: 'slider', min: 1, max: 100, step: 1, default: 50, affects: 'density' },
  { id: 'columns', label: 'Columns', kind: 'slider', min: 1, max: 4, step: 1, default: 2, affects: 'layout' },
  { id: 'glow', label: 'Glow', kind: 'toggle', default: true, affects: 'appearance' },
  { id: 'hue', label: 'Hue', kind: 'color', default: '#C9F36B', affects: 'appearance' },
  { id: 'theme', label: 'Theme', kind: 'segmented', options: [{ value: 'neon', label: 'Neon' }, { value: 'pastel', label: 'Pastel' }], default: 'neon', affects: 'appearance' },
];

test('params: defaults, clamping, step-snapping, invalid → default + dropped', () => {
  assert.deepEqual(defaultParams(SCHEMA), { gravity: 0.5, density: 50, columns: 2, glow: true, hue: '#C9F36B', theme: 'neon' });
  const { params, dropped } = resolveExtraStyleParams(SCHEMA, {
    gravity: 5, density: 33.6, glow: 'yes', hue: 'red', theme: 'nope', unknownKey: 1,
  });
  assert.equal(params.gravity, 2, 'clamped to max');
  assert.equal(params.density, 34, 'step-snapped');
  assert.equal(params.glow, true, 'invalid toggle → default');
  assert.equal(params.hue, '#C9F36B', 'invalid color → default');
  assert.equal(params.theme, 'neon', 'invalid option → default');
  assert.deepEqual([...dropped].sort(), ['glow', 'hue', 'theme', 'unknownKey']);
  const clean = resolveExtraStyleParams(SCHEMA, { gravity: 1.24, hue: '#FF00AA', theme: 'pastel' });
  assert.equal(clean.params.gravity, 1.2, 'snapped to 0.1 grid');
  assert.equal(clean.params.hue, '#FF00AA');
  assert.equal(clean.params.theme, 'pastel');
  assert.deepEqual(clean.dropped, []);
});

test('params: presets resolve through the schema; only layout / listed params need a rebuild', () => {
  const preset = { id: 'intense', label: 'Intense', values: { gravity: 1.8, density: 90, theme: 'pastel' } };
  const { params } = applyExtraStylePreset(SCHEMA, preset);
  assert.equal(params.gravity, 1.8);
  assert.equal(params.density, 90);
  assert.equal(params.theme, 'pastel');
  assert.equal(params.glow, true, 'unmentioned params keep defaults');
  const base = defaultParams(SCHEMA);
  assert.equal(paramsNeedSceneRebuild(SCHEMA, base, { ...base, gravity: 1.5 }), false, 'motion change swaps values only');
  assert.equal(paramsNeedSceneRebuild(SCHEMA, base, { ...base, density: 80 }), false, 'density re-times the emitter binding — no rebuild');
  assert.equal(paramsNeedSceneRebuild(SCHEMA, base, { ...base, glow: false }), false);
  assert.equal(paramsNeedSceneRebuild(SCHEMA, base, { ...base, columns: 3 }), true, 'layout change rebuilds');
  assert.equal(paramsNeedSceneRebuild(SCHEMA, base, { ...base, density: 80 }, ['density']), true, 'a listed param rebuilds even when its affects is not layout');
  assert.equal(paramsNeedSceneRebuild(SCHEMA, base, base), false, 'no change → no rebuild');
});

// ---- Interpretation ---------------------------------------------------------

test('interpretation: semantic tags match whole words, capped, deterministic', () => {
  assert.deepEqual(analyzeSemanticTags('dancing in the rain tonight'), ['hype', 'weather-rain', 'time']);
  assert.deepEqual(analyzeSemanticTags(''), []);
  assert.deepEqual(analyzeSemanticTags('xylophone zebra'), []);
  // "raining" is not "rain" — whole-word only.
  assert.ok(!analyzeSemanticTags('it is raining').includes('weather-rain'));
  assert.deepEqual(analyzeSemanticTags('love in the rain'), analyzeSemanticTags('love in the rain'));
});

test('interpretation: sections find the repeated chorus, none without repetition', () => {
  const lines = (texts, start = 0) =>
    texts.map((text, i) => ({ id: `l${i}`, text, startFrame: start + i * 90, endFrame: start + i * 90 + 80 }));
  const chorus = lines(['intro line', 'verse one here', 'chorus line a', 'chorus line b', 'middle verse', 'chorus line a', 'chorus line b', 'outro line']);
  const sections = detectSections(chorus);
  const found = sections.filter((s) => s.kind === 'chorus');
  assert.equal(found.length, 2, 'two chorus occurrences');
  assert.ok(found.every((s) => s.confidence >= 0.3));
  assert.ok(sections.some((s) => s.kind === 'verse'));
  assert.deepEqual(detectSections(lines(['a', 'b', 'c', 'd', 'e', 'f'])), [], 'no repetition → no sections');
  assert.deepEqual(detectSections(lines(['a', 'b'])), [], 'too few lines → no sections');
});

test('interpretation: hash is stable and changes with the lyrics', () => {
  const lines = [{ id: 'l1', text: 'hello world', startFrame: 0, endFrame: 60 }];
  assert.equal(lyricsHash(lines), lyricsHash(lines));
  assert.notEqual(
    lyricsHash(lines),
    lyricsHash([{ id: 'l1', text: 'hello worlds', startFrame: 0, endFrame: 60 }]),
  );
  assert.equal(fnv1a32(''), 0x811c9dc5);
  const interp = buildLyricInterpretation(lines, 'song|180');
  assert.equal(interp.version, 1);
  assert.equal(interp.songKey, 'song|180');
  assert.deepEqual(interp.sections, []);
  assert.deepEqual(interp.lines, [{ lineId: 'l1', semanticTags: [] }]);
});

test('interpretation: syllable heuristic splits on vowel groups', () => {
  assert.deepEqual(splitWordIntoSyllables('music'), ['mu', 'sic']);
  assert.deepEqual(splitWordIntoSyllables('hello'), ['hel', 'lo']);
  assert.deepEqual(splitWordIntoSyllables('beautiful'), ['beau', 'ti', 'ful']);
  assert.deepEqual(splitWordIntoSyllables('window'), ['win', 'dow']);
  assert.deepEqual(splitWordIntoSyllables('cat'), ['cat']);
  assert.deepEqual(splitWordIntoSyllables(''), []);
});

// ---- Catalog ------------------------------------------------------------------

test('catalog: 40 styles, 5 demos, full engine coverage', () => {
  assert.equal(STYLE_CAPABILITY_MAP.length, 40, 'all 40 styles mapped');
  const ids = STYLE_CAPABILITY_MAP.map((s) => s.id);
  assert.equal(new Set(ids).size, 40, 'ids unique');
  const demos = STYLE_CAPABILITY_MAP.filter((s) => s.demo).map((s) => s.id).sort();
  assert.deepEqual(demos, [
    'comic-book',
    'dream-sequence',
    'emoji-storytelling',
    'holographic-interface',
    'typography-physics',
  ]);
  const missing = missingEngineCapabilities();
  assert.deepEqual(missing, [], `engine must cover every mapped capability, missing: ${JSON.stringify(missing)}`);
  // Every capability the engine claims is used by at least one style
  // (no dead capability in the coverage set).
  const used = new Set(STYLE_CAPABILITY_MAP.flatMap((s) => s.capabilities));
  for (const cap of ENGINE_CAPABILITIES) {
    assert.ok(used.has(cap), `engine capability ${cap} is claimed but no style needs it`);
  }
});

test('catalog: search, category filter, favorites-first, internal hidden', () => {
  const catalog = {
    bridgeVersion: 1,
    registryVersion: 1,
    styles: [
      { id: 'dream-sequence', version: 1, name: 'Dream Sequence', tagline: 'float away', category: 'cinematic', parameters: [], inputs: [], needsAudioAutomation: false, needsSubjectMasks: false },
      { id: '__harness', version: 1, name: 'Harness', tagline: 'internal', category: 'experimental', parameters: [], inputs: [], needsAudioAutomation: false, needsSubjectMasks: false, internal: true },
      { id: 'comic-book', version: 1, name: 'Comic Book', tagline: 'pow', category: 'playful', parameters: [], inputs: [], needsAudioAutomation: false, needsSubjectMasks: false },
    ],
  };
  assert.deepEqual(userVisibleStyles(catalog).map((s) => s.id), ['dream-sequence', 'comic-book']);
  assert.deepEqual(searchExtraStyleCatalog(catalog, 'dream').map((s) => s.id), ['dream-sequence']);
  assert.deepEqual(searchExtraStyleCatalog(catalog, 'CINEMATIC').map((s) => s.id), ['dream-sequence']);
  assert.deepEqual(searchExtraStyleCatalog(catalog, '').map((s) => s.id), ['dream-sequence', 'comic-book']);
  assert.deepEqual(filterExtraStylesByCategory(catalog, 'playful').map((s) => s.id), ['comic-book']);
  assert.deepEqual(
    sortExtraStylesWithFavoritesFirst(userVisibleStyles(catalog), ['comic-book']).map((s) => s.id),
    ['comic-book', 'dream-sequence'],
  );
});

// ---- Automation sampling -------------------------------------------------------

function makeAutomation() {
  return {
    version: 1,
    songKey: 'song|120',
    sampleRate: 44100,
    durationSeconds: 120,
    onsetEnvelope: { hopSeconds: 0.1, values: [0, 0.5, 1, 0.5, 0] },
    tempoBpm: 120,
    beats: [
      { timeSeconds: 0.5, isDownbeat: true, strength: 1 },
      { timeSeconds: 1.0, isDownbeat: false, strength: 0.8 },
      { timeSeconds: 1.5, isDownbeat: false, strength: 0.8 },
      { timeSeconds: 2.0, isDownbeat: false, strength: 0.8 },
    ],
    beatConfidence: 0.9,
    bandEnergies: {
      hopSeconds: 0.1,
      bandsHz: [125, 250],
      values: [[0.2, 0.4], [0.6, 0.8], [1, 1]],
    },
    loudnessCurve: { hopSeconds: 0.1, values: [-30, -20, -14, -20, -30] },
  };
}

test('automation: sampling interpolates curves at a frame', () => {
  const auto = makeAutomation();
  approx(sampleOnset(auto, 6), 1, 1e-9); // 0.2s → hop 2 exactly = 1
  approx(sampleOnset(auto, 8), 2 / 3, 1e-9); // 8f = 0.2667s → 2/3 between hops 2 (1) and 3 (0.5)
  approx(sampleOnset(auto, 15), 0, 1e-9); // 0.5s → past the last hop, clamps to values[4] = 0
  assert.deepEqual(sampleBandEnergies(auto, 3), [0.6, 0.8]); // 0.1s → hop 1
  approx(sampleLoudness(auto, 6), -14, 1e-9);
  assert.equal(sampleOnset(null, 10), 0);
  assert.deepEqual(sampleBandEnergies(null, 10), []);
  assert.equal(sampleLoudness(null, 10), 0);
});

test('automation: beat phase is confidence-gated with onset fallback', () => {
  const auto = makeAutomation();
  const phase = beatPhaseAtFrame(auto, 30); // 1.0s — exactly on beat 2
  assert.equal(phase.hasBeat, true);
  assert.equal(phase.framesSinceBeat, 0);
  assert.equal(phase.framesUntilBeat, 15);
  assert.equal(phase.isDownbeat, false);
  assert.equal(phase.beatStrength, 0.8);
  approx(phase.phase, 0);
  const mid = beatPhaseAtFrame(auto, 37); // 1.233s — between beats 2 and 3
  assert.equal(mid.hasBeat, true);
  assert.equal(mid.framesSinceBeat, 7);
  assert.equal(mid.framesUntilBeat, 8);
  const low = { ...auto, beatConfidence: 0.2 };
  assert.equal(beatPhaseAtFrame(low, 30).hasBeat, false, 'low confidence → no beat grid');
  assert.equal(automationHasConfidentBeat(low), false);
  assert.equal(automationHasConfidentBeat(auto), true);
  assert.equal(automationHasConfidentBeat(null), false);
  assert.equal(beatPhaseAtFrame(null, 30).hasBeat, false);
});

test('automation: empty artifact is zeroed and safe', () => {
  const empty = emptyAutomation('song|60', 60);
  assert.equal(empty.beatConfidence, 0);
  assert.deepEqual(empty.beats, []);
  assert.equal(sampleOnset(empty, 100), 0);
  assert.equal(beatPhaseAtFrame(empty, 100).hasBeat, false);
});

// ---- Persistence + v1 retirement migration -------------------------------------

test('persistence: validation keeps, migrates, or drops with a notice — never crashes', () => {
  const catalog = {
    bridgeVersion: 1,
    registryVersion: 1,
    styles: [
      { id: 'dream-sequence', version: 2, name: 'Dream Sequence', tagline: '', category: 'cinematic', parameters: [{ id: 'density', label: 'Density', kind: 'slider', min: 0, max: 100, default: 50, affects: 'density' }], inputs: [], needsAudioAutomation: false, needsSubjectMasks: false },
    ],
  };
  assert.deepEqual(validateExtraStyleState(null, catalog), { state: null });
  const kept = validateExtraStyleState(
    { styleId: 'dream-sequence', styleVersion: 2, params: { density: 80 } },
    catalog,
  );
  assert.equal(kept.state.styleId, 'dream-sequence');
  assert.equal(kept.state.params.density, 80);
  assert.equal(kept.migrated, undefined);
  const migrated = validateExtraStyleState(
    { styleId: 'dream-sequence', styleVersion: 1, params: { density: 80, removedParam: 1 } },
    catalog,
  );
  assert.equal(migrated.state.styleVersion, 2);
  assert.equal(migrated.state.params.density, 80);
  assert.equal(migrated.migrated, true);
  assert.ok(migrated.notice);
  const unknown = validateExtraStyleState(
    { styleId: 'retired-style', styleVersion: 1, params: {} },
    catalog,
  );
  assert.equal(unknown.state, null);
  assert.ok(unknown.notice);
  const newer = validateExtraStyleState(
    { styleId: 'dream-sequence', styleVersion: 99, params: {} },
    catalog,
  );
  assert.equal(newer.state, null, 'a project from a newer build never crashes the loader');
  assert.ok(newer.notice);
});

test('persistence: v1 retirement maps successors, everything else goes classic', () => {
  // In Phase 2 the registry holds only the harness style, so every
  // v1 template maps to classic — the mapping activates when the
  // 40 styles land in Phase 3. Prove the mechanism with a synthetic
  // catalog that HAS the successors.
  const emptyCatalog = { bridgeVersion: 1, registryVersion: 1, styles: [] };
  const retired = migrateV1Template('emoji-story', emptyCatalog);
  assert.equal(retired.state, null);
  assert.match(retired.notice, /retired/);
  assert.match(retired.notice, /classic lyrics/);
  assert.deepEqual(migrateV1Template(undefined, emptyCatalog), { state: null, notice: '' });

  const fullCatalog = {
    bridgeVersion: 1,
    registryVersion: 1,
    styles: [
      { id: 'emoji-storytelling', version: 1, name: 'Emoji Storytelling', tagline: '', category: 'playful', parameters: [{ id: 'pop', label: 'Pop', kind: 'slider', min: 0, max: 1, default: 0.5, affects: 'motion' }], inputs: ['intelligence'], needsAudioAutomation: false, needsSubjectMasks: false },
      { id: 'comic-book', version: 1, name: 'Comic Book', tagline: '', category: 'playful', parameters: [], inputs: [], needsAudioAutomation: false, needsSubjectMasks: false },
    ],
  };
  const emoji = migrateV1Template('emoji-story', fullCatalog);
  assert.equal(emoji.state.styleId, 'emoji-storytelling');
  assert.equal(emoji.state.params.pop, 0.5, 'successor starts at its defaults');
  assert.match(emoji.notice, /Emoji Storytelling/);
  const comic = migrateV1Template('comic-book', fullCatalog);
  assert.equal(comic.state.styleId, 'comic-book');
  // A v1 template with NO 2.0 successor goes classic, not to a lookalike.
  const karaoke = migrateV1Template('karaoke-pop', fullCatalog);
  assert.equal(karaoke.state, null);
  assert.match(karaoke.notice, /classic lyrics/);
  assert.equal(migrateV1Template('not-a-template', fullCatalog).state, null);
  // The mapping table covers the 30 v1 ids (spot-check the count).
  assert.equal(Object.keys(V1_TEMPLATE_SUCCESSORS).length, 15);
});

// ---- Scene input ------------------------------------------------------------------

const SCENE_LINES = [
  {
    id: 'l1', text: 'love in the rain', startFrame: 90, endFrame: 180,
    words: [
      { text: 'love', startFrame: 90, endFrame: 120 },
      { text: 'in', startFrame: 120, endFrame: 135 },
      { text: 'the', startFrame: 135, endFrame: 150 },
      { text: 'rain', startFrame: 150, endFrame: 180 },
    ],
    decor: { emoji: '❤️', tone: 'love', emphasisWordIndices: [0, 3] },
  },
  { id: 'l2', text: 'goodbye now', startFrame: 300, endFrame: 390, decor: { tone: 'sad' } },
  { id: 'l3', text: 'straddles the region start', startFrame: 30, endFrame: 120 },
];

test('scene: song frames map to composition frames with offset + clamping', () => {
  const input = buildExtraStyleSceneInput({
    styleId: 'dream-sequence',
    projectId: 'proj-1',
    paramsJson: '{}',
    lines: SCENE_LINES,
    offsetFrames: 15,
    regionStartFrame: 60,
    canvasWidth: 1080,
    canvasHeight: 1920,
    durationFrames: 900,
  });
  assert.equal(input.lines.length, 3);
  const l1 = input.lines[0];
  approx(l1.startSeconds, (90 - 60 + 15) / 30);
  approx(l1.endSeconds, (180 - 60 + 15) / 30);
  assert.equal(l1.words.length, 4);
  approx(l1.words[0].startSeconds, (90 - 60 + 15) / 30);
  // A line straddling the region start clamps to 0, not negative.
  const l3 = input.lines.find((l) => l.text === 'straddles the region start');
  assert.equal(l3.startSeconds, 0);
  approx(l3.endSeconds, (120 - 60 + 15) / 30);
  // A line entirely before the region is dropped.
  const dropped = buildExtraStyleSceneInput({
    styleId: 'dream-sequence',
    projectId: 'proj-1',
    paramsJson: '{}',
    lines: [{ id: 'x', text: 'early', startFrame: 0, endFrame: 10 }],
    regionStartFrame: 600,
    canvasWidth: 1080,
    canvasHeight: 1920,
    durationFrames: 900,
  });
  assert.equal(dropped.lines.length, 0);
});

test('scene: stored intelligence crosses UNCONDITIONALLY — the v1 Emoji Story failure', () => {
  // The v1 bug: the payload carried the emoji only when a template
  // was active, and the renderers showed it only for Emoji Story —
  // Jaizon never saw one emoji, ever. The 2.0 builder takes NO
  // template flag at all: a line with an emoji ALWAYS produces a
  // payload line with that emoji, for ANY style.
  for (const styleId of ['dream-sequence', 'emoji-storytelling', 'typography-physics', 'comic-book']) {
    const input = buildExtraStyleSceneInput({
      styleId,
      projectId: 'proj-1',
      paramsJson: '{}',
      lines: SCENE_LINES,
      regionStartFrame: 0,
      canvasWidth: 1080,
      canvasHeight: 1920,
      durationFrames: 900,
    });
    const l1 = input.lines.find((l) => l.text === 'love in the rain');
    assert.ok(l1, `line present for ${styleId}`);
    assert.equal(l1.emoji, '❤️', `emoji survives for ${styleId} — no gate may swallow it`);
    assert.equal(l1.tone, 'love');
    assert.deepEqual(l1.emphasisWordIndices, [0, 3]);
    const l2 = input.lines.find((l) => l.text === 'goodbye now');
    assert.equal(l2.tone, 'sad');
    assert.equal(l2.emoji, undefined, 'a line with no emoji carries none — nothing invented');
  }
  // Semantic tags ride the same payload when an interpretation exists.
  const interp = buildLyricInterpretation(
    SCENE_LINES.map((l) => ({ id: l.id, text: l.text, startFrame: l.startFrame, endFrame: l.endFrame })),
    'song|30',
  );
  const withInterp = buildExtraStyleSceneInput({
    styleId: 'emoji-storytelling',
    projectId: 'proj-1',
    paramsJson: '{}',
    lines: SCENE_LINES,
    regionStartFrame: 0,
    canvasWidth: 1080,
    canvasHeight: 1920,
    durationFrames: 900,
    interpretation: interp,
  });
  const tagged = withInterp.lines.find((l) => l.text === 'love in the rain');
  assert.ok(tagged.semanticTags.includes('love'));
  assert.ok(tagged.semanticTags.includes('weather-rain'));
});

test('scene: seed is stable per (style, project) and differs across them', () => {
  assert.equal(deriveExtraStyleSeed('dream-sequence', 'proj-1'), deriveExtraStyleSeed('dream-sequence', 'proj-1'));
  assert.notEqual(deriveExtraStyleSeed('dream-sequence', 'proj-1'), deriveExtraStyleSeed('dream-sequence', 'proj-2'));
  assert.notEqual(deriveExtraStyleSeed('dream-sequence', 'proj-1'), deriveExtraStyleSeed('comic-book', 'proj-1'));
  const a = buildExtraStyleSceneInput({
    styleId: 'dream-sequence', projectId: 'proj-1', paramsJson: '{}', lines: [],
    regionStartFrame: 0, canvasWidth: 1080, canvasHeight: 1920, durationFrames: 900,
  });
  const b = buildExtraStyleSceneInput({
    styleId: 'dream-sequence', projectId: 'proj-1', paramsJson: '{}', lines: [],
    regionStartFrame: 0, canvasWidth: 1080, canvasHeight: 1920, durationFrames: 900,
  });
  assert.equal(a.seed, b.seed);
});
