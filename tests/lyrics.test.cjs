/**
 * Node tests for the lyrics helpers (src/lib/lyrics.ts): Whisper
 * grouping, the song↔timeline frame mapping, the text-edit word
 * rule, split/merge/shift, and the composite payload builder.
 * Run with: npm run test:lyrics
 * (tsc compiles the pure modules into tests/.build-lyrics, then
 * node --test runs this file against the compiled JS.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  groupWhisperSegments,
  songFrameToTimelineFrame,
  timelineFrameToSongFrame,
  lineAtSongFrame,
  lineIndexAtSongFrame,
  retimeLineWordsForText,
  splitLineAtWord,
  mergeLyricLines,
  shiftLyricLines,
  buildCompositeLyrics,
  defaultLyricStyle,
  MAX_WORDS_PER_LINE,
} = require('./.build-lyrics/src/lib/lyrics.js');

const FPS = 30;

/** A Whisper word timing. */
const w = (text, startSeconds, endSeconds) => ({ text, startSeconds, endSeconds });
/** A Whisper segment from [text, start, end] word tuples. */
const seg = (tuples, startSeconds, endSeconds) => ({
  text: tuples.map((t) => t[0]).join(' '),
  startSeconds: startSeconds ?? tuples[0][1],
  endSeconds: endSeconds ?? tuples[tuples.length - 1][2],
  words: tuples.map((t) => w(t[0], t[1], t[2])),
});

// ---- Grouping ----------------------------------------------------------

test('grouping: a segment boundary always breaks the line', () => {
  const lines = groupWhisperSegments(
    [seg([['hello', 0, 0.4], ['world', 0.4, 0.8]]), seg([['again', 0.9, 1.3]])],
    FPS,
  );
  assert.equal(lines.length, 2);
  assert.equal(lines[0].text, 'hello world');
  assert.equal(lines[1].text, 'again');
});

test('grouping: a pause over 0.7s breaks, a shorter one does not', () => {
  const broken = groupWhisperSegments(
    [seg([['one', 0, 0.3], ['two', 1.2, 1.5]])], // 0.9s gap
    FPS,
  );
  assert.equal(broken.length, 2);
  const kept = groupWhisperSegments(
    [seg([['one', 0, 0.3], ['two', 0.8, 1.1]])], // 0.5s gap
    FPS,
  );
  assert.equal(kept.length, 1);
  assert.equal(kept[0].text, 'one two');
});

test('grouping: a line holds at most MAX_WORDS_PER_LINE words', () => {
  const tuples = Array.from({ length: MAX_WORDS_PER_LINE + 3 }, (_, i) => [
    `w${i}`,
    i * 0.3,
    i * 0.3 + 0.25,
  ]);
  const lines = groupWhisperSegments([seg(tuples)], FPS);
  assert.equal(lines.length, 2);
  assert.equal(lines[0].words.length, MAX_WORDS_PER_LINE);
  assert.equal(lines[1].words.length, 3);
});

test('grouping: seconds become rounded frames and every span is >= 1 frame', () => {
  const lines = groupWhisperSegments([seg([['a', 0.5, 0.51]])], FPS);
  assert.equal(lines[0].startFrame, 15); // round(0.5 * 30)
  assert.ok(lines[0].endFrame > lines[0].startFrame);
  assert.equal(lines[0].words[0].startFrame, 15);
  assert.equal(lines[0].words[0].endFrame, lines[0].endFrame);
});

test('grouping: a segment without word timings becomes one untimed line', () => {
  const lines = groupWhisperSegments(
    [{ text: '  sung phrase  ', startSeconds: 2, endSeconds: 4, words: [] }],
    FPS,
  );
  assert.equal(lines.length, 1);
  assert.equal(lines[0].text, 'sung phrase');
  assert.equal(lines[0].words, undefined);
  assert.equal(lines[0].startFrame, 60);
  assert.equal(lines[0].endFrame, 120);
});

test('grouping: output is sorted by start frame', () => {
  const lines = groupWhisperSegments(
    [seg([['late', 5, 5.5]]), seg([['early', 1, 1.5]])],
    FPS,
  );
  assert.deepEqual(
    lines.map((l) => l.text),
    ['early', 'late'],
  );
});

// ---- Frame mapping ------------------------------------------------------

test('mapping: song and timeline frames differ by exactly the region start', () => {
  assert.equal(songFrameToTimelineFrame(450, 300), 150);
  assert.equal(timelineFrameToSongFrame(150, 300), 450);
  assert.equal(timelineFrameToSongFrame(songFrameToTimelineFrame(77, 300), 300), 77);
});

test('lineAtSongFrame: [start, end) containment, gaps miss', () => {
  const lines = [
    { id: 'a', text: 'a', startFrame: 30, endFrame: 60 },
    { id: 'b', text: 'b', startFrame: 90, endFrame: 120 },
  ];
  assert.equal(lineAtSongFrame(lines, 30)?.id, 'a');
  assert.equal(lineAtSongFrame(lines, 59)?.id, 'a');
  assert.equal(lineAtSongFrame(lines, 60), null); // end is exclusive
  assert.equal(lineAtSongFrame(lines, 75), null); // gap
  assert.equal(lineIndexAtSongFrame(lines, 119), 1);
  assert.equal(lineIndexAtSongFrame(lines, 120), -1);
});

// ---- The text-edit word rule ---------------------------------------------

test('text edit: same word count keeps timings word-for-word', () => {
  const line = {
    id: 'x',
    text: 'old words here',
    startFrame: 0,
    endFrame: 90,
    words: [
      { text: 'old', startFrame: 0, endFrame: 30 },
      { text: 'words', startFrame: 30, endFrame: 60 },
      { text: 'here', startFrame: 60, endFrame: 90 },
    ],
  };
  const edited = retimeLineWordsForText(line, 'brand new lyric');
  assert.equal(edited.text, 'brand new lyric');
  assert.deepEqual(
    edited.words.map((x) => [x.text, x.startFrame, x.endFrame]),
    [
      ['brand', 0, 30],
      ['new', 30, 60],
      ['lyric', 60, 90],
    ],
  );
});

test('text edit: a different word count drops the timings', () => {
  const line = {
    id: 'x',
    text: 'one two',
    startFrame: 0,
    endFrame: 60,
    words: [
      { text: 'one', startFrame: 0, endFrame: 30 },
      { text: 'two', startFrame: 30, endFrame: 60 },
    ],
  };
  assert.equal(retimeLineWordsForText(line, 'one two three').words, undefined);
  assert.equal(retimeLineWordsForText(line, 'one').words, undefined);
  assert.equal(retimeLineWordsForText(line, '').words, undefined);
});

// ---- Split / merge / shift -------------------------------------------------

test('split: timed words split on the word start', () => {
  const line = {
    id: 'x',
    text: 'a b c d',
    startFrame: 0,
    endFrame: 120,
    words: [
      { text: 'a', startFrame: 0, endFrame: 30 },
      { text: 'b', startFrame: 30, endFrame: 60 },
      { text: 'c', startFrame: 60, endFrame: 90 },
      { text: 'd', startFrame: 90, endFrame: 120 },
    ],
  };
  const [first, second] = splitLineAtWord(line, 2);
  assert.equal(first.text, 'a b');
  assert.equal(first.endFrame, 60);
  assert.equal(second.text, 'c d');
  assert.equal(second.startFrame, 60);
  assert.equal(second.words.length, 2);
  assert.notEqual(second.id, line.id);
  assert.equal(splitLineAtWord(line, 0), null);
  assert.equal(splitLineAtWord(line, 4), null);
});

test('split: untimed lines split proportionally by characters', () => {
  const line = { id: 'x', text: 'aaaa bbbb', startFrame: 0, endFrame: 90 };
  const [first, second] = splitLineAtWord(line, 1);
  assert.equal(first.text, 'aaaa');
  assert.equal(second.text, 'bbbb');
  assert.ok(first.endFrame > 0 && first.endFrame < 90);
  assert.equal(second.startFrame, first.endFrame);
  assert.equal(first.words, undefined);
});

test('merge: words survive only when both lines carry them', () => {
  const timed = (id, text, s, e) => ({
    id,
    text,
    startFrame: s,
    endFrame: e,
    words: [{ text, startFrame: s, endFrame: e }],
  });
  const both = mergeLyricLines(timed('a', 'one', 0, 30), timed('b', 'two', 30, 60));
  assert.equal(both.text, 'one two');
  assert.equal(both.words.length, 2);
  const mixed = mergeLyricLines(timed('a', 'one', 0, 30), { id: 'b', text: 'two', startFrame: 30, endFrame: 60 });
  assert.equal(mixed.words, undefined);
  assert.equal(mixed.endFrame, 60);
});

test('shift: moves words too and clamps at song frame 0 keeping durations', () => {
  const lines = [
    {
      id: 'a',
      text: 'x',
      startFrame: 10,
      endFrame: 40,
      words: [{ text: 'x', startFrame: 10, endFrame: 40 }],
    },
  ];
  const shifted = shiftLyricLines(lines, -25);
  assert.equal(shifted[0].startFrame, 0);
  assert.equal(shifted[0].endFrame, 30); // duration preserved
  assert.equal(shifted[0].words[0].startFrame, 0);
  assert.equal(shiftLyricLines(lines, 5)[0].startFrame, 15);
});

// ---- Composite payload ------------------------------------------------------

const payloadProject = (lines, styleOverrides = {}) => ({
  lines,
  style: { ...defaultLyricStyle(), ...styleOverrides },
});

test('payload: maps song frames to composition seconds via the region start', () => {
  const payload = buildCompositeLyrics(
    payloadProject([{ id: 'a', text: 'hi', startFrame: 330, endFrame: 390 }]),
    300,
    FPS,
  );
  assert.equal(payload.lines.length, 1);
  assert.equal(payload.lines[0].startSeconds, 1); // (330-300)/30
  assert.equal(payload.lines[0].endSeconds, 3);
});

test('payload: lines before the region drop, straddling lines clamp', () => {
  const payload = buildCompositeLyrics(
    payloadProject([
      { id: 'gone', text: 'gone', startFrame: 0, endFrame: 240 },
      { id: 'straddle', text: 'straddle', startFrame: 270, endFrame: 360 },
    ]),
    300,
    FPS,
  );
  assert.equal(payload.lines.length, 1);
  assert.equal(payload.lines[0].text, 'straddle');
  assert.equal(payload.lines[0].startSeconds, 0);
  assert.equal(payload.lines[0].endSeconds, 2);
});

test('payload: words are clamped into the visible window', () => {
  const payload = buildCompositeLyrics(
    payloadProject([
      {
        id: 'a',
        text: 'one two',
        startFrame: 270,
        endFrame: 360,
        words: [
          { text: 'one', startFrame: 270, endFrame: 300 },
          { text: 'two', startFrame: 300, endFrame: 360 },
        ],
      },
    ]),
    300,
    FPS,
  );
  // 'one' ends exactly at the region start -> dropped; 'two' survives.
  assert.equal(payload.lines[0].words.length, 1);
  assert.equal(payload.lines[0].words[0].text, 'two');
  assert.equal(payload.lines[0].words[0].startSeconds, 0);
});

test('payload: empty or invisible lyrics build null', () => {
  assert.equal(buildCompositeLyrics(null, 0, FPS), null);
  assert.equal(buildCompositeLyrics(payloadProject([]), 0, FPS), null);
  assert.equal(
    buildCompositeLyrics(payloadProject([{ id: 'a', text: 'x', startFrame: 0, endFrame: 30 }]), 300, FPS),
    null,
  );
});

test('payload: style resolves to a PostScript name + animation params', () => {
  const payload = buildCompositeLyrics(
    payloadProject([{ id: 'a', text: 'hi', startFrame: 0, endFrame: 30 }], {
      fontId: 'avenir-next',
      bold: true,
      animationId: 'karaoke',
    }),
    0,
    FPS,
  );
  assert.equal(payload.style.fontPostScriptName, 'AvenirNext-Bold'); // real bold face preferred
  assert.equal(payload.style.animation.wordMode, 'karaoke');
  assert.equal(payload.style.animation.emphasisScale, 1.18);
  const regular = buildCompositeLyrics(
    payloadProject([{ id: 'a', text: 'hi', startFrame: 0, endFrame: 30 }], { bold: false }),
    0,
    FPS,
  );
  assert.equal(regular.style.fontPostScriptName, 'AvenirNext-Regular');
});
