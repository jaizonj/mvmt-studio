/**
 * Node tests for the shuffle engine + analysis tables.
 * Run with: npm run test:shuffle
 * (tsc compiles the two pure modules into tests/.build, then node --test
 * runs this file against the compiled JS.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { generateShuffle, seededRandom } = require('./.build/src/lib/shuffle.js');
const { buildSections, estimateTakeEnergies, SectionEnergyAccumulator } = require('./.build/src/lib/analysis.js');

function sectionsFromEnergies(energies, sectionSeconds = 4) {
  return energies.map((energy, i) => ({
    index: i,
    startSeconds: i * sectionSeconds,
    endSeconds: (i + 1) * sectionSeconds,
    energy,
  }));
}

const takes = [
  { id: 'calm', energy: 0.15 },
  { id: 'mid', energy: 0.5 },
  { id: 'wild', energy: 0.9 },
];

test('returns null with fewer than 2 takes or no sections', () => {
  assert.equal(generateShuffle(sectionsFromEnergies([0.5, 0.5]), [takes[0]]), null);
  assert.equal(generateShuffle([], takes), null);
});

test('produces one slot per window, covering the whole track in order', () => {
  const sections = sectionsFromEnergies([0.2, 0.4, 0.6, 0.8, 0.3, 0.9]);
  const out = generateShuffle(sections, takes, { random: seededRandom(42) });
  assert.ok(out);
  assert.equal(out.slots[0].startSeconds, 0);
  assert.equal(out.slots[out.slots.length - 1].endSeconds, 24);
  for (let i = 1; i < out.slots.length; i++) {
    assert.equal(out.slots[i].startSeconds, out.slots[i - 1].endSeconds, 'slots must be contiguous');
  }
  assert.ok(out.candidatesEvaluated >= 24 && out.candidatesEvaluated <= 48);
  assert.ok(out.score >= 0 && out.score <= 100);
});

test('never returns an edit identical to the previous shuffle when alternatives exist', () => {
  const sections = sectionsFromEnergies([0.2, 0.8, 0.3, 0.9, 0.5, 0.1, 0.7, 0.4]);
  const first = generateShuffle(sections, takes, { random: seededRandom(7) });
  const previous = first.slots.map((s) => s.takeId);
  for (let seed = 1; seed <= 5; seed++) {
    const next = generateShuffle(sections, takes, { random: seededRandom(seed * 100), previousSequence: previous });
    assert.notDeepEqual(next.slots.map((s) => s.takeId), previous);
    assert.equal(next.isRepeatOfPrevious, false);
  }
});

test('energy matching: best-of-N beats a deliberately mismatched edit', () => {
  // Alternating silent/intense sections; takes at the extremes + middle.
  const sections = sectionsFromEnergies([0.05, 0.95, 0.05, 0.95, 0.05, 0.95]);
  const out = generateShuffle(sections, takes, { random: seededRandom(3), candidates: 48 });
  const mismatches = out.slots.filter((slot, i) => {
    const take = takes.find((t) => t.id === slot.takeId);
    return Math.abs(sections[i].energy - take.energy) > 0.6;
  });
  assert.ok(mismatches.length <= 1, `expected near-perfect energy matching, got ${mismatches.length} bad slots`);
});

test('minimum shot length: short sections are merged, no flickery shots', () => {
  const sections = sectionsFromEnergies([0.3, 0.4, 0.5, 0.6, 0.7, 0.8], 1); // 1s sections
  const out = generateShuffle(sections, takes, { random: seededRandom(9), minShotSeconds: 2.5 });
  for (const slot of out.slots) {
    const isLast = slot.endSeconds === 6;
    assert.ok(slot.endSeconds - slot.startSeconds >= 2.5 || isLast, 'shot shorter than minimum');
  }
  assert.ok(out.slots.length < sections.length, 'sections should have been merged');
});

test('adjacent same-take runs are rare across many shuffles', () => {
  const sections = sectionsFromEnergies([0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5]);
  let adjacentSame = 0;
  let totalPairs = 0;
  for (let seed = 0; seed < 20; seed++) {
    const out = generateShuffle(sections, takes, { random: seededRandom(seed) });
    for (let i = 1; i < out.slots.length; i++) {
      totalPairs += 1;
      if (out.slots[i].takeId === out.slots[i - 1].takeId) adjacentSame += 1;
    }
  }
  assert.ok(adjacentSame / totalPairs < 0.2, `too many adjacent repeats: ${adjacentSame}/${totalPairs}`);
});

test('buildSections aligns to phrase boundaries', () => {
  const sections = buildSections(30, 120); // 8 beats @120bpm = 4s phrases
  assert.equal(sections.length, 8); // 7 full phrases + 2s remainder
  assert.equal(sections[0].endSeconds, 4);
  assert.equal(sections[sections.length - 1].endSeconds, 30);
});

test('energy accumulator normalises the loudest section to ~1', () => {
  const acc = new SectionEnergyAccumulator(8, 120); // two 4s sections
  for (let t = 0; t < 4; t += 0.5) acc.addSample(t, 0.1); // quiet first half
  for (let t = 4; t < 8; t += 0.5) acc.addSample(t, 0.8); // loud second half
  const sections = acc.finish();
  assert.equal(sections.length, 2);
  assert.ok(sections[1].energy > 0.95);
  assert.ok(sections[0].energy < sections[1].energy);
  assert.equal(acc.sampledSectionCount, 2);
});

test('take energy heuristic ranks busier files higher', () => {
  const energies = estimateTakeEnergies([
    { id: 'still', fileSizeBytes: 1_000_000, durationSeconds: 10 },
    { id: 'busy', fileSizeBytes: 6_000_000, durationSeconds: 10 },
    { id: 'unknown' },
  ]);
  assert.ok(energies.get('busy') > energies.get('still'));
  assert.ok(energies.get('unknown') >= 0 && energies.get('unknown') <= 1);
});

test('REGRESSION: sections shorter than the default minimum still produce many cuts', () => {
  // Device test 2026-11-08: Rapid frequency subdivides to 0.5s sections,
  // and the old buildWindows merged them ALL into one window — a 15s
  // "shuffle" came out as a single full-length cut. With the engine's
  // default 2.5s minimum, 0.5s sections must accumulate into ~2.5s shots.
  const sections = sectionsFromEnergies(new Array(30).fill(0.5), 0.5); // 15s of 0.5s sections
  const out = generateShuffle(sections, takes, { random: seededRandom(11) });
  assert.ok(out);
  assert.ok(out.slots.length >= 4, `expected several cuts, got ${out.slots.length}`);
  assert.equal(out.slots[0].startSeconds, 0);
  assert.equal(out.slots[out.slots.length - 1].endSeconds, 15);
  for (let i = 1; i < out.slots.length; i++) {
    assert.equal(out.slots[i].startSeconds, out.slots[i - 1].endSeconds, 'slots must be contiguous');
  }
});

test('rapid frequency (minShot = section length) cuts almost every beat', () => {
  const sections = sectionsFromEnergies(new Array(30).fill(0.5), 0.5); // 15s
  const out = generateShuffle(sections, takes, { random: seededRandom(5), minShotSeconds: 0.5 });
  assert.ok(out);
  // Random variety merges may join a few neighbours, but a 15s rapid
  // shuffle must land in double digits — never one big cut.
  assert.ok(out.slots.length >= 15, `expected 15+ cuts, got ${out.slots.length}`);
  const distinct = new Set(out.slots.map((s) => s.takeId));
  assert.ok(distinct.size >= 2, 'rapid shuffle should actually switch takes');
});
