/**
 * Node tests for the shuffle → EDL bridge (src/lib/shuffleEdl.ts) and
 * the canonical EDL contract it targets (src/lib/edl.ts).
 * Run with: npm run test:edl
 * (tsc compiles the pure modules into tests/.build-edl, then node --test
 * runs this file against the compiled JS.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { buildEdlFromShuffle, buildEdlFromSingleTake, validateAgainstAssets, sequenceKey } = require('./.build-edl/src/lib/shuffleEdl.js');
const { buildSections } = require('./.build-edl/src/lib/analysis.js');
const {
  sourceFrameForTimelineFrame,
  sourceFrameForSegmentFrame,
  takeSyncOffsetSeconds,
  secondsToFrames,
  framesToSeconds,
  canvasForTakes,
  layoutSegments,
  validateEdl,
  emptyEdl,
  segmentSpeed,
  segmentTimelineDurationFrames,
  segmentAtFrame,
  edlToCompositeRequest,
  DEFAULT_FPS,
} = require('./.build-edl/src/lib/edl.js');

const FPS = DEFAULT_FPS; // 30
const REGION_SECONDS = 15;
const REGION_FRAMES = REGION_SECONDS * FPS; // 450

/** Three takes recorded over a region starting at `regionStart` (absolute track time). */
function makeTakes(regionStart = 0) {
  return [
    { id: 'calm', energy: 0.15, trackOffsetSeconds: regionStart, durationSeconds: REGION_SECONDS },
    { id: 'mid', energy: 0.5, trackOffsetSeconds: regionStart, durationSeconds: REGION_SECONDS },
    { id: 'wild', energy: 0.9, trackOffsetSeconds: regionStart, durationSeconds: REGION_SECONDS },
  ];
}

/** Phrase-length sections (4s @120bpm) over 15s starting at `regionStart`, like the app's sampled sections. */
function makeSections(regionStart = 0) {
  return buildSections(REGION_SECONDS, 120, regionStart);
}

function build(overrides = {}) {
  return buildEdlFromShuffle({
    sections: makeSections(0),
    takes: makeTakes(0),
    frequency: 'normal',
    seed: 42,
    regionStartSeconds: 0,
    audioUri: 'file:///track.mp3',
    ...overrides,
  });
}

function assertGapless(edl, expectedTotalFrames) {
  let cursor = 0;
  for (const segment of edl.segments) {
    assert.equal(segment.timelineStartFrame, cursor, `segment ${segment.id} must start where the previous ended`);
    assert.ok(segment.durationFrames > 0, `segment ${segment.id} must have positive duration`);
    // The cursor advances by TIMELINE length — a slowed segment
    // occupies more frames than its source (identical at 1x).
    cursor += segmentTimelineDurationFrames(segment);
  }
  assert.equal(edl.totalFrames, cursor, 'totalFrames must be the sum of segment timeline durations');
  if (expectedTotalFrames !== undefined) {
    assert.equal(edl.totalFrames, expectedTotalFrames);
  }
}

test('determinism: same seed reproduces the identical EDL byte-for-byte', () => {
  const a = build();
  const b = build();
  assert.equal(JSON.stringify(a), JSON.stringify(b));
  assert.ok(a.shuffleInfo);
  assert.equal(a.shuffleInfo.candidatesEvaluated, 32);
  assert.deepEqual(a.shuffleInfo.takeSequence, a.edl.segments.map((s) => s.takeId));

  const other = build({ seed: 1337 });
  assert.notEqual(sequenceKey(other.edl), sequenceKey(a.edl), 'a different seed should produce a different edit');
});

test('gapless coverage: every frequency covers the whole region, contiguously', () => {
  for (const frequency of ['chill', 'normal', 'fast', 'rapid']) {
    const { edl, shuffleInfo } = build({ frequency });
    assert.ok(shuffleInfo, `${frequency}: shuffle should succeed`);
    assert.ok(edl.segments.length > 0, `${frequency}: segments expected`);
    assertGapless(edl, REGION_FRAMES);
    assert.equal(edl.fps, FPS);
    assert.equal(edl.canvas.width, 1080);
    assert.equal(edl.canvas.height, 1920);
    assert.equal(edl.audio.uri, 'file:///track.mp3');
    assert.equal(edl.audio.regionStartFrame, 0);
    assert.equal(edl.audio.volume, 1);
    for (const segment of edl.segments) {
      assert.ok(segment.sourceStartFrame >= 0, `${frequency}/${segment.id}: source start clamped at 0`);
    }
  }
});

test('region offset: timeline is region-relative, audio keeps the absolute region start', () => {
  const { edl } = build({
    sections: makeSections(10),
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
  const { edl } = build({ takes });
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

  // Sync metadata must not change WHICH takes the shuffle picks.
  assert.equal(sequenceKey(shifted.edl), sequenceKey(base.edl));
  assert.equal(shifted.edl.segments.length, base.edl.segments.length);
  shifted.edl.segments.forEach((segment, i) => {
    const before = base.edl.segments[i];
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
  const { edl } = build();

  const honest = validateAgainstAssets(edl, makeTakes(0), FPS);
  assert.equal(honest.ok, true);
  assert.deepEqual(honest.errors, []);
  assert.deepEqual(honest.edl.segments, edl.segments);

  // 'mid' only really has 2s of footage: its source ranges must clamp
  // to 60 frames, with errors reported and the edit kept gapless.
  const short = validateAgainstAssets(
    edl,
    makeTakes(0).map((t) => (t.id === 'mid' ? { ...t, durationSeconds: 2 } : t)),
    FPS,
  );
  assert.equal(short.ok, false);
  assert.ok(short.errors.length > 0);
  assertGapless(short.edl);
  for (const segment of short.edl.segments) {
    if (segment.takeId === 'mid') {
      assert.ok(segment.sourceStartFrame + segment.durationFrames <= 2 * FPS, 'mid range inside its real 2s');
    }
  }

  // A take missing from the measures is dropped, never passed through.
  const unknown = validateAgainstAssets(edl, makeTakes(0).filter((t) => t.id !== 'wild'), FPS);
  assert.equal(unknown.ok, false);
  assert.ok(unknown.errors.some((e) => e.includes('wild')));
  assert.ok(unknown.edl.segments.every((s) => s.takeId !== 'wild'));
  assertGapless(unknown.edl);

  // Zero known duration = zero usable footage.
  const zero = validateAgainstAssets(
    edl,
    makeTakes(0).map((t) => (t.id === 'mid' ? { ...t, durationSeconds: undefined } : t)),
    FPS,
  );
  assert.equal(zero.ok, false);
  assert.ok(zero.edl.segments.every((s) => s.takeId !== 'mid'));
  assertGapless(zero.edl);
});

test('frequency sanity: faster frequencies cut more over the same 15s', () => {
  const counts = {};
  for (const frequency of ['chill', 'normal', 'fast', 'rapid']) {
    counts[frequency] = build({ frequency }).edl.segments.length;
  }
  assert.ok(counts.rapid > counts.fast, JSON.stringify(counts));
  assert.ok(counts.fast > counts.normal, JSON.stringify(counts));
  assert.ok(counts.normal > counts.chill, JSON.stringify(counts));
  assert.ok(counts.rapid >= 15, `rapid should cut almost every beat, got ${counts.rapid}`);
});

test('no adjacent repeats beyond chance at rapid across seeds', () => {
  let same = 0;
  let pairs = 0;
  for (let seed = 1; seed <= 8; seed++) {
    const { edl } = build({ frequency: 'rapid', seed });
    for (let i = 1; i < edl.segments.length; i++) {
      pairs += 1;
      if (edl.segments[i].takeId === edl.segments[i - 1].takeId) same += 1;
    }
  }
  assert.ok(pairs > 100, `expected a large sample of cut pairs, got ${pairs}`);
  assert.ok(same / pairs < 0.2, `adjacent same-take rate ${same}/${pairs} is too high`);
});

test('novelty: feeding the previous sequence back produces a different edit', () => {
  const first = build();
  const second = build({ previousSequence: first.shuffleInfo.takeSequence });
  assert.ok(second.shuffleInfo);
  assert.equal(second.shuffleInfo.isRepeatOfPrevious, false);
  assert.notEqual(sequenceKey(second.edl), sequenceKey(first.edl));
});

test('degenerate inputs: fewer than 2 takes yields an empty EDL and null info', () => {
  const { edl, shuffleInfo } = build({ takes: makeTakes(0).slice(0, 1) });
  assert.equal(shuffleInfo, null);
  assert.deepEqual(edl.segments, []);
  assert.equal(edl.totalFrames, 0);
  assert.equal(edl.audio.uri, 'file:///track.mp3');
});

test('fallback: with no sampled sections, the grid is built from take durations', () => {
  const { edl, shuffleInfo } = build({ sections: [] });
  assert.ok(shuffleInfo);
  assertGapless(edl, REGION_FRAMES);
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

  // End to end through the bridge: every (unclamped) segment of every
  // take satisfies the same identity against its timeline position.
  const takes = makeTakes(0);
  takes[0].syncOffsetSeconds = 0.2;
  takes[1].syncOffsetSeconds = 0.7;
  takes[2].syncOffsetSeconds = -0.1; // captured slightly early
  const { edl } = build({ takes });
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
  assert.ok(checked >= 3, `expected several segments to verify, got ${checked}`);
});

test('drift invariance: syncDriftSeconds never enters the mapping', () => {
  // Audit verdict (2026-11-09): the stored drift figure is dominated
  // by capture-start latency, not clock drift — so wildly different
  // drift values must produce byte-identical edits.
  const driftPlusMinus = makeTakes(0).map((t, i) => ({ ...t, syncDriftSeconds: i === 0 ? 5 : -5 }));
  const driftHuge = makeTakes(0).map((t) => ({ ...t, syncDriftSeconds: 123.456 }));
  const plain = build();
  assert.equal(JSON.stringify(build({ takes: driftPlusMinus }).edl), JSON.stringify(plain.edl));
  assert.equal(JSON.stringify(build({ takes: driftHuge }).edl), JSON.stringify(plain.edl));
});

test('calibration: syncAdjustFrames shifts the source by whole frames, honoured on every shuffle', () => {
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
  // −3 frames (clamped at 0); take selection is unchanged.
  const base = build();
  const calTakes = makeTakes(0);
  calTakes[1].syncAdjustFrames = 3; // 'mid'
  const cal = build({ takes: calTakes });
  assert.equal(sequenceKey(cal.edl), sequenceKey(base.edl));
  cal.edl.segments.forEach((segment, i) => {
    const before = base.edl.segments[i];
    if (segment.takeId === 'mid') {
      assert.equal(segment.sourceStartFrame, Math.max(0, before.sourceStartFrame - 3));
    } else {
      assert.equal(segment.sourceStartFrame, before.sourceStartFrame);
    }
  });

  // Re-shuffling with other seeds must not mutate the input takes,
  // and the calibration is honoured in every resulting edit.
  const snapshot = JSON.stringify(calTakes);
  let midChecked = 0;
  for (const seed of [7, 99]) {
    const { edl } = build({ takes: calTakes, seed });
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
  assert.ok(midChecked > 0, 'expected at least one mid segment across the re-shuffles');
  assert.equal(JSON.stringify(calTakes), snapshot, 'the bridge must not mutate its input takes');
});

test('legacy safety: takes with no sync metadata build and validate exactly as before', () => {
  // The default fixture carries NO sync fields at all (pre-measurement
  // takes): the offset collapses to trackOffset − regionStart.
  const { edl, shuffleInfo } = build({
    sections: makeSections(10),
    takes: makeTakes(10),
    regionStartSeconds: 10,
  });
  assert.ok(shuffleInfo);
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

// ---------------------------------------------------------------------
// Clip speed (Edit Modes Stage 1, 2026-11-12): per-segment playback
// rate — video-only, the song stays 1x. Source ranges never change;
// only the timeline length and the composition mapping stretch.
// ---------------------------------------------------------------------

test('speed: timeline duration is source / speed, laid out gapless', () => {
  const laid = layoutSegments(
    [
      { id: 'seg-1', takeId: 'calm', sourceStartFrame: 0, durationFrames: 90, speed: 0.5 },
      { id: 'seg-2', takeId: 'mid', sourceStartFrame: 0, durationFrames: 90, speed: 2 },
      { id: 'seg-3', takeId: 'wild', sourceStartFrame: 0, durationFrames: 90 },
    ],
    emptyEdl(FPS),
  );
  // 90 source frames at 0.5x = 180 timeline frames; at 2x = 45; at 1x = 90.
  assert.equal(segmentTimelineDurationFrames(laid.segments[0]), 180);
  assert.equal(segmentTimelineDurationFrames(laid.segments[1]), 45);
  assert.equal(segmentTimelineDurationFrames(laid.segments[2]), 90);
  assert.deepEqual(
    laid.segments.map((s) => s.timelineStartFrame),
    [0, 180, 225],
  );
  assert.equal(laid.totalFrames, 315);
  assertGapless(laid, 315);
  assert.equal(segmentAtFrame(laid, 179)?.id, 'seg-1');
  assert.equal(segmentAtFrame(laid, 180)?.id, 'seg-2');
  assert.equal(segmentAtFrame(laid, 224)?.id, 'seg-2');
  assert.equal(segmentAtFrame(laid, 225)?.id, 'seg-3');
  assert.equal(segmentAtFrame(laid, 315), null);
});

test('speed: sanitisation — missing, invalid and out-of-range speeds read as 1x-bounded', () => {
  assert.equal(segmentSpeed({}), 1);
  assert.equal(segmentSpeed({ speed: undefined }), 1);
  assert.equal(segmentSpeed({ speed: 0 }), 1);
  assert.equal(segmentSpeed({ speed: -1 }), 1);
  assert.equal(segmentSpeed({ speed: NaN }), 1);
  assert.equal(segmentSpeed({ speed: 0.1 }), 0.25);
  assert.equal(segmentSpeed({ speed: 5 }), 2);
  assert.equal(segmentSpeed({ speed: 0.5 }), 0.5);
  assert.equal(segmentSpeed({ speed: 2 }), 2);
});

test('speed: source mapping inside a segment advances at the segment speed', () => {
  const seg = {
    id: 'seg-1',
    takeId: 'calm',
    timelineStartFrame: 100,
    sourceStartFrame: 50,
    durationFrames: 60,
    speed: 0.5,
  };
  assert.equal(sourceFrameForSegmentFrame(seg, 100), 50);
  assert.equal(sourceFrameForSegmentFrame(seg, 120), 60); // 20 timeline frames × 0.5
  assert.equal(sourceFrameForSegmentFrame({ ...seg, speed: 2 }, 110), 70);
  assert.equal(sourceFrameForSegmentFrame({ ...seg, speed: undefined }, 110), 60);
});

test('speed: validation clamps source ranges and keeps the speed', () => {
  const raw = layoutSegments(
    [
      { id: 'seg-1', takeId: 'calm', sourceStartFrame: 0, durationFrames: 90, speed: 0.5 },
      { id: 'seg-2', takeId: 'mid', sourceStartFrame: 400, durationFrames: 90, speed: 2 },
    ],
    emptyEdl(FPS),
  );
  // 'mid' only has 450 frames of footage: its range [400, 490)
  // clamps to [400, 450) — and both speeds survive the clamp.
  const validated = validateEdl(raw, [
    { takeId: 'calm', durationFrames: 450 },
    { takeId: 'mid', durationFrames: 450 },
  ]);
  assert.equal(validated.ok, false);
  assert.equal(validated.edl.segments[0].speed, 0.5);
  assert.equal(validated.edl.segments[1].speed, 2);
  assert.equal(validated.edl.segments[1].durationFrames, 50);
  // Timeline: 90/0.5 = 180, then 50/2 = 25 → gapless at 0, 180, total 205.
  assert.deepEqual(
    validated.edl.segments.map((s) => s.timelineStartFrame),
    [0, 180],
  );
  assert.equal(validated.edl.totalFrames, 205);
  assertGapless(validated.edl, 205);
});

test('speed: export request carries the rate; source range and song are untouched', () => {
  const raw = layoutSegments(
    [
      { id: 'seg-1', takeId: 'calm', sourceStartFrame: 0, durationFrames: 90, speed: 0.5 },
      { id: 'seg-2', takeId: 'mid', sourceStartFrame: 90, durationFrames: 90, speed: 2 },
    ],
    { ...emptyEdl(FPS), audio: { uri: 'file:///track.mp3', regionStartFrame: 0, volume: 1 } },
  );
  const request = edlToCompositeRequest(raw, (id) => `file:///${id}.mp4`);
  assert.equal(request.clips[0].speed, 0.5);
  assert.equal(request.clips[1].speed, 2);
  // Source ranges are the un-retimed source: 3s each starting at 0s / 3s.
  assert.equal(request.clips[0].startSeconds, 0);
  assert.equal(request.clips[0].durationSeconds, 3);
  assert.equal(request.clips[1].startSeconds, 3);
  assert.equal(request.clips[1].durationSeconds, 3);
  // The song rides 1x over the whole (now longer) cut: 6s of source
  // at 0.5x + 1.5s at 2x = 7.5s of timeline.
  assert.equal(request.audioUri, 'file:///track.mp3');
  assert.equal(request.audioStartSeconds, 0);
  assert.equal(raw.totalFrames, 225); // 180 + 45
});

test('speed: survives the project JSON round-trip', () => {
  const seg = {
    id: 'seg-1',
    takeId: 'calm',
    timelineStartFrame: 0,
    sourceStartFrame: 0,
    durationFrames: 90,
    speed: 0.5,
  };
  const revived = JSON.parse(JSON.stringify(seg));
  assert.equal(segmentSpeed(revived), 0.5);
  assert.equal(segmentTimelineDurationFrames(revived), 180);
});

// ---------------------------------------------------------------------
// Single-take passthrough (2026-11-12): one take can't shuffle, but
// it IS the cut — one segment over the region.
// ---------------------------------------------------------------------

test('single take: one take over the region builds a valid one-segment cut', () => {
  const take = makeTakes(0)[0]; // 'calm', 15s, window at region start
  const edl = buildEdlFromSingleTake({
    take,
    regionStartSeconds: 0,
    regionLengthSeconds: REGION_SECONDS,
    audioUri: 'file:///track.mp3',
  });
  assert.equal(edl.segments.length, 1);
  assert.equal(edl.segments[0].takeId, 'calm');
  assert.equal(edl.segments[0].timelineStartFrame, 0);
  assert.equal(edl.segments[0].sourceStartFrame, 0);
  assert.equal(edl.segments[0].durationFrames, REGION_FRAMES);
  assert.equal(edl.totalFrames, REGION_FRAMES);
  assert.equal(edl.audio.uri, 'file:///track.mp3');
  assert.equal(edl.audio.regionStartFrame, 0);
  // It validates clean against the take's real duration.
  assert.equal(validateAgainstAssets(edl, makeTakes(0), FPS).ok, true);
});

test('single take: clips to the region when the take is longer; clips to the take when it is shorter', () => {
  const long = buildEdlFromSingleTake({
    take: { ...makeTakes(0)[0], durationSeconds: 60 },
    regionStartSeconds: 0,
    regionLengthSeconds: REGION_SECONDS,
    audioUri: null,
  });
  assert.equal(long.segments[0].durationFrames, REGION_FRAMES);

  const short = buildEdlFromSingleTake({
    take: { ...makeTakes(0)[0], durationSeconds: 10 },
    regionStartSeconds: 0,
    regionLengthSeconds: REGION_SECONDS,
    audioUri: null,
  });
  assert.equal(short.segments[0].durationFrames, 10 * FPS);
  assert.equal(short.totalFrames, 10 * FPS);

  // No usable duration = no cut (the editor's handler reports it).
  const empty = buildEdlFromSingleTake({
    take: { id: 'x', trackOffsetSeconds: 0 },
    regionStartSeconds: 0,
    regionLengthSeconds: REGION_SECONDS,
    audioUri: null,
  });
  assert.deepEqual(empty.segments, []);
});

test('single take: source start follows the shared sync mapping', () => {
  // Take recorded from track time 0, region starts at 5s, capture
  // ran 0.5s late: the region's first frame is 4.5s into the take.
  const edl = buildEdlFromSingleTake({
    take: { ...makeTakes(0)[0], trackOffsetSeconds: 0, durationSeconds: 20, syncOffsetSeconds: 0.5 },
    regionStartSeconds: 5,
    regionLengthSeconds: REGION_SECONDS,
    audioUri: 'file:///track.mp3',
  });
  assert.equal(edl.segments[0].sourceStartFrame, 135);
  assert.equal(edl.segments[0].durationFrames, REGION_FRAMES);
  assert.equal(edl.audio.regionStartFrame, 5 * FPS);
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
