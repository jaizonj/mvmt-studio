/**
 * Node tests for the chronological EDL builder (buildEdlChronological
 * in src/lib/edl.ts) and the canonical EDL contract it targets.
 *
 * The Shuffle/auto-edit was removed 2026-11-12 (Jaizon: "auto edit is
 * out"): the editor builds the EDL chronologically — takes in
 * recording order, each at full length, laid end-to-end and clipped
 * to the song region. The sync contract below (ONE shared offset,
 * drift exclusion, manual frame calibration, legacy safety) is
 * unchanged — it is the same mapping, exercised through the new
 * builder instead of the old shuffle bridge.
 *
 * Run with: npm run test:edl
 * (tsc compiles the pure modules into tests/.build-edl, then node --test
 * runs this file against the compiled JS.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  buildEdlChronological,
  validateAgainstAssets,
  sourceFrameForTimelineFrame,
  takeSyncOffsetSeconds,
  secondsToFrames,
  framesToSeconds,
  canvasForTakes,
  DEFAULT_FPS,
} = require('./.build-edl/src/lib/edl.js');

const FPS = DEFAULT_FPS; // 30
const REGION_SECONDS = 40;
const REGION_FRAMES = REGION_SECONDS * FPS; // 1200

/** Three 15s takes recorded over a region starting at `regionStart` (absolute track time). */
function makeTakes(regionStart = 0) {
  return [
    { id: 'calm', trackOffsetSeconds: regionStart, durationSeconds: 15 },
    { id: 'mid', trackOffsetSeconds: regionStart, durationSeconds: 15 },
    { id: 'wild', trackOffsetSeconds: regionStart, durationSeconds: 15 },
  ];
}

function build(overrides = {}) {
  return buildEdlChronological({
    takes: makeTakes(0),
    regionStartSeconds: 0,
    regionLengthSeconds: REGION_SECONDS,
    audioUri: 'file:///track.mp3',
    ...overrides,
  });
}

function assertGapless(edl, expectedTotalFrames) {
  let cursor = 0;
  for (const segment of edl.segments) {
    assert.equal(segment.timelineStartFrame, cursor, `segment ${segment.id} must start where the previous ended`);
    assert.ok(segment.durationFrames > 0, `segment ${segment.id} must have positive duration`);
    cursor += segment.durationFrames;
  }
  assert.equal(edl.totalFrames, cursor, 'totalFrames must be the sum of segment durations');
  if (expectedTotalFrames !== undefined) {
    assert.equal(edl.totalFrames, expectedTotalFrames);
  }
}

test('determinism: the same takes and region reproduce the identical EDL byte-for-byte', () => {
  const a = build();
  const b = build();
  assert.equal(JSON.stringify(a), JSON.stringify(b));
});

test('chronological order: takes in recording order, each at full length, laid end-to-end', () => {
  const edl = build();
  assert.equal(edl.segments.length, 3);
  assert.deepEqual(
    edl.segments.map((s) => s.takeId),
    ['calm', 'mid', 'wild'],
  );
  assert.deepEqual(
    edl.segments.map((s) => s.durationFrames),
    [15 * FPS, 15 * FPS, 10 * FPS],
    'the third take is clipped to the 40s region',
  );
  assertGapless(edl, REGION_FRAMES);
  assert.equal(edl.fps, FPS);
  assert.equal(edl.canvas.width, 1080);
  assert.equal(edl.canvas.height, 1920);
  assert.equal(edl.audio.uri, 'file:///track.mp3');
  assert.equal(edl.audio.regionStartFrame, 0);
  assert.equal(edl.audio.volume, 1);
  for (const segment of edl.segments) {
    assert.ok(segment.sourceStartFrame >= 0, `${segment.id}: source start clamped at 0`);
  }
});

test('clipping: the edit never runs past the region, and ends early when the takes run out', () => {
  // Region shorter than the first take: one segment, clipped to 15s.
  const short = build({ regionLengthSeconds: 15 });
  assert.equal(short.segments.length, 1);
  assert.equal(short.segments[0].takeId, 'calm');
  assertGapless(short, 15 * FPS);

  // Region longer than all takes combined (45s of takes): the edit
  // ends at 45s, not at the 100s region.
  const long = build({ regionLengthSeconds: 100 });
  assert.equal(long.segments.length, 3);
  assertGapless(long, 45 * FPS);

  // Zero-length region: nothing to lay out.
  const zero = build({ regionLengthSeconds: 0 });
  assert.deepEqual(zero.segments, []);
  assert.equal(zero.totalFrames, 0);
  assert.equal(zero.audio.uri, 'file:///track.mp3');
});

test('canvas: defaults to 1080x1920; an explicit canvas passes through', () => {
  assert.deepEqual(build().canvas, { width: 1080, height: 1920 });
  assert.deepEqual(build({ canvas: { width: 2160, height: 3840 } }).canvas, {
    width: 2160,
    height: 3840,
  });
});

test('region offset: timeline is region-relative, audio keeps the absolute region start', () => {
  const edl = build({
    takes: makeTakes(10),
    regionStartSeconds: 10,
  });
  assertGapless(edl, REGION_FRAMES);
  assert.equal(edl.audio.regionStartFrame, secondsToFrames(10, FPS));
  // Takes began exactly at the region start with no measured error, so
  // the first segment's footage starts at the take's frame 0.
  assert.equal(edl.segments[0].timelineStartFrame, 0);
  assert.equal(edl.segments[0].sourceStartFrame, 0);
});

test('source mapping: every segment follows the shared timeline→source formula', () => {
  const takes = makeTakes(0);
  takes[1].syncOffsetSeconds = 0.5; // 'mid' measured half a second late
  const edl = build({ takes });
  const byId = new Map(takes.map((t) => [t.id, t]));
  for (const segment of edl.segments) {
    const take = byId.get(segment.takeId);
    const offset = takeSyncOffsetSeconds(take, 0, FPS);
    const expected = Math.max(0, sourceFrameForTimelineFrame(segment.timelineStartFrame, offset, FPS));
    assert.equal(segment.sourceStartFrame, expected, `segment ${segment.id} (${segment.takeId})`);
  }
});

test('source mapping: a measured sync offset shifts only that take, by exactly offset×fps frames', () => {
  const base = build();
  const shiftedTakes = makeTakes(0);
  shiftedTakes[1].syncOffsetSeconds = 0.5; // 'mid'
  const shifted = build({ takes: shiftedTakes });

  // Sync metadata must not change WHICH takes the edit uses.
  assert.deepEqual(
    shifted.segments.map((s) => s.takeId),
    base.segments.map((s) => s.takeId),
  );
  assert.equal(shifted.segments.length, base.segments.length);
  shifted.segments.forEach((segment, i) => {
    const before = base.segments[i];
    assert.equal(segment.timelineStartFrame, before.timelineStartFrame);
    assert.equal(segment.durationFrames, before.durationFrames);
    if (segment.takeId === 'mid') {
      assert.equal(segment.sourceStartFrame, Math.max(0, before.sourceStartFrame - 15), 'mid shifts 0.5s×30fps earlier');
    } else {
      assert.equal(segment.sourceStartFrame, before.sourceStartFrame, 'other takes are untouched');
    }
  });
});

test('validation: honest durations pass unchanged; short takes clamp, unknown takes drop', () => {
  // Honest fixture: a 10s take followed by a 40s take over a 40s
  // region. The first take covers song [0,10]; the second covers
  // song [10,40] from its own file [10,40] — every source range fits
  // its asset, so validation passes the edit through untouched.
  const honestTakes = [
    { id: 'short', trackOffsetSeconds: 0, durationSeconds: 10 },
    { id: 'full', trackOffsetSeconds: 0, durationSeconds: 40 },
  ];
  const edl = build({ takes: honestTakes });
  assert.equal(edl.segments.length, 2);
  assertGapless(edl, REGION_FRAMES);

  const honest = validateAgainstAssets(edl, honestTakes, FPS);
  assert.equal(honest.ok, true);
  assert.deepEqual(honest.errors, []);
  assert.deepEqual(honest.edl.segments, edl.segments);

  // 'full' only really has 15s of footage: its segment starts at
  // timeline 10s (source 10s) and must clamp to the 5s it actually
  // holds ([10,15]), with errors reported and the edit kept gapless.
  const short = validateAgainstAssets(
    edl,
    honestTakes.map((t) => (t.id === 'full' ? { ...t, durationSeconds: 15 } : t)),
    FPS,
  );
  assert.equal(short.ok, false);
  assert.ok(short.errors.length > 0);
  assertGapless(short.edl, 15 * FPS);
  for (const segment of short.edl.segments) {
    if (segment.takeId === 'full') {
      assert.ok(segment.sourceStartFrame + segment.durationFrames <= 15 * FPS, 'full range inside its real 15s');
    }
  }

  // A take missing from the measures is dropped, never passed through.
  const unknown = validateAgainstAssets(edl, honestTakes.filter((t) => t.id !== 'full'), FPS);
  assert.equal(unknown.ok, false);
  assert.ok(unknown.errors.some((e) => e.includes('full')));
  assert.ok(unknown.edl.segments.every((s) => s.takeId !== 'full'));
  assertGapless(unknown.edl);

  // Zero known duration = zero usable footage.
  const zero = validateAgainstAssets(
    edl,
    honestTakes.map((t) => (t.id === 'full' ? { ...t, durationSeconds: undefined } : t)),
    FPS,
  );
  assert.equal(zero.ok, false);
  assert.ok(zero.edl.segments.every((s) => s.takeId !== 'full'));
  assertGapless(zero.edl);
});

test('degenerate inputs: no takes yields an empty EDL; one take yields one segment', () => {
  const none = build({ takes: [] });
  assert.deepEqual(none.segments, []);
  assert.equal(none.totalFrames, 0);
  assert.equal(none.audio.uri, 'file:///track.mp3');

  const one = build({ takes: makeTakes(0).slice(0, 1) });
  assert.equal(one.segments.length, 1);
  assert.equal(one.segments[0].takeId, 'calm');
  assertGapless(one, 15 * FPS);
});

test('input takes are not mutated by the builder', () => {
  const takes = makeTakes(0);
  takes[1].syncOffsetSeconds = 0.5;
  const snapshot = JSON.stringify(takes);
  build({ takes });
  build({ takes });
  assert.equal(JSON.stringify(takes), snapshot);
});

// ---------------------------------------------------------------------
// Sync fix (2026-11-09): ONE shared offset (takeSyncOffsetSeconds),
// drift exclusion, manual frame calibration, legacy safety.
// ---------------------------------------------------------------------

const near = (a, b) => Math.abs(a - b) < 1e-9;

test('shared offset: takeSyncOffsetSeconds composes window + measured + calibration', () => {
  // Window position relative to the region start is the base.
  assert.equal(takeSyncOffsetSeconds({ trackOffsetSeconds: 10 }, 4, FPS), 6);
  // The measured capture error adds directly (positive = started late).
  assert.equal(takeSyncOffsetSeconds({ trackOffsetSeconds: 10, syncOffsetSeconds: 0.5 }, 4, FPS), 6.5);
  // Manual calibration adds in whole frames: +3 frames @30fps = +0.1s.
  assert.ok(near(takeSyncOffsetSeconds({ trackOffsetSeconds: 10, syncAdjustFrames: 3 }, 4, FPS), 6.1));
  assert.ok(near(takeSyncOffsetSeconds({ trackOffsetSeconds: 10, syncAdjustFrames: -3 }, 4, FPS), 5.9));
  // All three terms compose.
  assert.ok(
    near(
      takeSyncOffsetSeconds({ trackOffsetSeconds: 10, syncOffsetSeconds: 0.5, syncAdjustFrames: 3 }, 4, FPS),
      6.6,
    ),
  );
  // Undefined sync fields are exactly zero — the pre-fix formula.
  assert.equal(takeSyncOffsetSeconds({ trackOffsetSeconds: 7 }, 2, FPS), 7 - 2);
});

test('alignment: takes with different capture-start delays point at the same song positions', () => {
  // Direct mapping at one timeline frame (10s into the region): the
  // take that started capturing 0.5s later must be read 15 frames
  // earlier in its file, so both files show the SAME song moment.
  const F = 300;
  const punctual = { trackOffsetSeconds: 0, syncOffsetSeconds: 0.2 };
  const delayed = { trackOffsetSeconds: 0, syncOffsetSeconds: 0.7 };
  const sPunctual = sourceFrameForTimelineFrame(F, takeSyncOffsetSeconds(punctual, 0, FPS), FPS);
  const sDelayed = sourceFrameForTimelineFrame(F, takeSyncOffsetSeconds(delayed, 0, FPS), FPS);
  assert.equal(sPunctual - sDelayed, 15);
  // Recovered song position = file time + when capture actually began.
  const songOf = (take, sourceFrame) =>
    framesToSeconds(sourceFrame, FPS) + take.trackOffsetSeconds + (take.syncOffsetSeconds ?? 0);
  assert.equal(songOf(punctual, sPunctual), framesToSeconds(F, FPS));
  assert.equal(songOf(delayed, sDelayed), framesToSeconds(F, FPS));

  // End to end through the builder: every (unclamped) segment of every
  // take satisfies the same identity against its timeline position.
  const takes = makeTakes(0);
  takes[0].syncOffsetSeconds = 0.2;
  takes[1].syncOffsetSeconds = 0.7;
  takes[2].syncOffsetSeconds = -0.1; // captured slightly early
  const edl = build({ takes });
  const byId = new Map(takes.map((t) => [t.id, t]));
  let checked = 0;
  for (const segment of edl.segments) {
    if (segment.sourceStartFrame === 0) continue; // clamped: not enough footage before the window
    const take = byId.get(segment.takeId);
    assert.ok(
      near(songOf(take, segment.sourceStartFrame), framesToSeconds(segment.timelineStartFrame, FPS)),
      `segment ${segment.id} (${segment.takeId}) must show the song at its timeline position`,
    );
    checked += 1;
  }
  assert.ok(checked >= 2, `expected several segments to verify, got ${checked}`);
});

test('drift invariance: syncDriftSeconds never enters the mapping', () => {
  // Audit verdict (2026-11-09): the stored drift figure is dominated
  // by capture-start latency, not clock drift — so wildly different
  // drift values must produce byte-identical edits.
  const driftPlusMinus = makeTakes(0).map((t, i) => ({ ...t, syncDriftSeconds: i === 0 ? 5 : -5 }));
  const driftHuge = makeTakes(0).map((t) => ({ ...t, syncDriftSeconds: 123.456 }));
  const plain = build();
  assert.equal(JSON.stringify(build({ takes: driftPlusMinus })), JSON.stringify(plain));
  assert.equal(JSON.stringify(build({ takes: driftHuge })), JSON.stringify(plain));
});

test('calibration: syncAdjustFrames shifts the source by whole frames, honoured in every build', () => {
  // Sign, per the formula: the adjustment ADDS to the offset, and the
  // offset is SUBTRACTED from the timeline frame — so +3 frames of
  // calibration reads the footage 3 frames EARLIER in the file.
  const F = 300;
  const unadjusted = sourceFrameForTimelineFrame(
    F,
    takeSyncOffsetSeconds({ trackOffsetSeconds: 0 }, 0, FPS),
    FPS,
  );
  const adjusted = sourceFrameForTimelineFrame(
    F,
    takeSyncOffsetSeconds({ trackOffsetSeconds: 0, syncAdjustFrames: 3 }, 0, FPS),
    FPS,
  );
  assert.equal(adjusted, unadjusted - 3);

  // End to end: only the calibrated take's segments move, by exactly
  // −3 frames (clamped at 0); take order is unchanged.
  const base = build();
  const calTakes = makeTakes(0);
  calTakes[1].syncAdjustFrames = 3; // 'mid'
  const cal = build({ takes: calTakes });
  assert.deepEqual(
    cal.segments.map((s) => s.takeId),
    base.segments.map((s) => s.takeId),
  );
  cal.segments.forEach((segment, i) => {
    const before = base.segments[i];
    if (segment.takeId === 'mid') {
      assert.equal(segment.sourceStartFrame, Math.max(0, before.sourceStartFrame - 3));
    } else {
      assert.equal(segment.sourceStartFrame, before.sourceStartFrame);
    }
  });

  // Rebuilding must not mutate the input takes, and the calibration
  // is honoured in every resulting edit.
  const snapshot = JSON.stringify(calTakes);
  let midChecked = 0;
  for (let i = 0; i < 2; i++) {
    const edl = build({ takes: calTakes });
    for (const segment of edl.segments) {
      if (segment.takeId !== 'mid') continue;
      const expected = Math.max(
        0,
        sourceFrameForTimelineFrame(
          segment.timelineStartFrame,
          takeSyncOffsetSeconds(calTakes[1], 0, FPS),
          FPS,
        ),
      );
      assert.equal(segment.sourceStartFrame, expected);
      midChecked += 1;
    }
  }
  assert.ok(midChecked > 0, 'expected at least one mid segment across the rebuilds');
  assert.equal(JSON.stringify(calTakes), snapshot, 'the builder must not mutate its input takes');
});

test('legacy safety: takes with no sync metadata build and validate exactly as before', () => {
  // The default fixture carries NO sync fields at all (pre-measurement
  // takes): the offset collapses to trackOffset − regionStart.
  // (15s region, so the first 15s take fills it and every source
  // range fits its asset.)
  const edl = build({
    takes: makeTakes(10),
    regionStartSeconds: 10,
    regionLengthSeconds: 15,
  });
  assert.equal(edl.segments.length, 1);
  assert.equal(edl.segments[0].sourceStartFrame, 0);
  const validated = validateAgainstAssets(edl, makeTakes(10), FPS);
  assert.equal(validated.ok, true);
  assert.deepEqual(validated.errors, []);
});

test('persistence: sync fields survive the project JSON round-trip', () => {
  // src/lib/persistence.ts serialises the whole project state with
  // JSON.stringify and restores it with JSON.parse (no field picking),
  // so a plain JSON round-trip of a Take fixture is the honest
  // headless proxy for the app-restart check.
  const take = {
    id: 'take-1',
    trackOffsetSeconds: 3.25,
    syncOffsetSeconds: 0.42,
    syncAdjustFrames: -2,
    syncSource: 'fileCorrelation',
    syncConfidence: 0.87,
    syncDriftSeconds: 0.03,
  };
  const revived = JSON.parse(JSON.stringify({ id: 'project-1', takes: [take] })).takes[0];
  assert.deepEqual(revived, take);
  // The revived take drives the shared offset identically.
  assert.equal(takeSyncOffsetSeconds(revived, 1, FPS), takeSyncOffsetSeconds(take, 1, FPS));
});

test('canvas: follows the largest RECORDED take; imports never vote', () => {
  const recorded1080 = { id: 'r1', width: 1080, height: 1920 };
  const recorded4k = { id: 'r2', width: 2160, height: 3840 };
  const importLandscape4k = { id: 'i1', source: 'imported', width: 3840, height: 2160 };
  const importSmall = { id: 'i2', source: 'imported', width: 1280, height: 720 };
  const legacyNoDims = { id: 'r3' };

  // No dimensions anywhere → no vote.
  assert.equal(canvasForTakes([legacyNoDims]), null);
  // Imports alone → still no vote: the canvas stays the caller's.
  assert.equal(canvasForTakes([importLandscape4k, importSmall]), null);
  // A 4K landscape import must not hijack a 1080p recorded project's canvas.
  assert.deepEqual(canvasForTakes([recorded1080, importLandscape4k]), { width: 1080, height: 1920 });
  // Recorded takes still raise the canvas among themselves.
  assert.deepEqual(canvasForTakes([recorded1080, recorded4k, importLandscape4k]), {
    width: 2160,
    height: 3840,
  });
});
