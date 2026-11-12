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
  cleanDetectedLyrics,
  respellLyricProfanity,
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

test('grouping: an over-cap word run splits into balanced lines under the cap', () => {
  // ADJUSTED with the 50-style expansion: the grouper no longer fills
  // the first line to MAX_WORDS_PER_LINE and dumps the rest — an
  // over-cap run with no usable pause splits at its midpoint word,
  // so 10 evenly sung words become two balanced 5-word lines, each
  // still under the cap. (Previously: 7 + 3.)
  const tuples = Array.from({ length: MAX_WORDS_PER_LINE + 3 }, (_, i) => [
    `w${i}`,
    i * 0.3,
    i * 0.3 + 0.25,
  ]);
  const lines = groupWhisperSegments([seg(tuples)], FPS);
  assert.equal(lines.length, 2);
  assert.equal(lines[0].words.length, 5);
  assert.equal(lines[1].words.length, 5);
  for (const line of lines) assert.ok(line.words.length <= MAX_WORDS_PER_LINE);
});

test('grouping: an adaptive pause breaks once the line reaches the soft word target', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['a', 0, 0.25],
        ['b', 0.3, 0.55],
        ['c', 0.6, 0.85],
        ['d', 0.9, 1.15],
        ['e', 1.2, 1.45],
        ['f', 1.85, 2.1], // 0.4s gap, line already holds 5 words
        ['g', 2.15, 2.4],
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 2);
  assert.equal(lines[0].text, 'a b c d e');
  assert.equal(lines[1].text, 'f g');
});

test('grouping: an adaptive pause breaks on the soft duration target too', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['a', 0, 0.8],
        ['b', 0.85, 1.65],
        ['c', 1.7, 2.5], // line is 2.5s long with only 3 words
        ['d', 2.9, 3.7], // 0.4s gap -> break
        ['e', 3.75, 4.4],
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 2);
  assert.equal(lines[0].text, 'a b c');
  assert.equal(lines[1].text, 'd e');
});

test('grouping: a 0.4s pause does NOT break a line still under the soft target', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['a', 0, 0.3],
        ['b', 0.35, 0.65],
        ['c', 1.05, 1.35], // 0.4s gap, but the line is short and young
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 1);
  assert.equal(lines[0].text, 'a b c');
});

test('grouping: a sentence-ending word closes the line (with at least 2 words in it)', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['we', 0, 0.3],
        ['go', 0.35, 0.65],
        ['home.', 0.7, 1.1],
        ['now', 1.15, 1.45],
        ['we', 1.5, 1.8],
        ['dance', 1.85, 2.2],
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 2);
  assert.equal(lines[0].text, 'we go home.');
  assert.equal(lines[1].text, 'now we dance');

  const kept = groupWhisperSegments(
    [
      seg([
        ['Go.', 0, 0.35], // a one-word line does not break after itself
        ['now', 0.4, 0.7],
        ['we', 0.75, 1.05],
        ['dance', 1.1, 1.45],
      ]),
    ],
    FPS,
  );
  assert.equal(kept.length, 1);
  assert.equal(kept[0].text, 'Go. now we dance');
});

test('grouping: an over-duration chunk splits at its largest internal pause', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['a', 0, 0.9],
        ['b', 1.12, 2.02],
        ['c', 2.24, 3.14],
        ['d', 3.44, 4.34], // 0.3s gap — the largest in a 6.58s chunk
        ['e', 4.56, 5.46],
        ['f', 5.68, 6.58],
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 2);
  assert.equal(lines[0].text, 'a b c');
  assert.equal(lines[1].text, 'd e f');
});

test('grouping: the duration cap splits even two long held words', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['a', 0, 2.0],
        ['b', 2.1, 4.2], // together 4.2s > 3.5s cap; the rescue must not re-merge them
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 2);
  assert.equal(lines[0].text, 'a');
  assert.equal(lines[1].text, 'b');
});

test('grouping: the character cap splits recursively until lines fit', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['aaaaaaaaaaaaaaaaaaaa', 0, 0.3], // 20 chars each, 62 joined
        ['bbbbbbbbbbbbbbbbbbbb', 0.35, 0.65],
        ['cccccccccccccccccccc', 0.7, 1.0],
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 3);
  for (const line of lines) assert.ok(line.text.length <= 36);
});

test('grouping: a stranded single word is rescued into its neighbour', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['a', 0, 0.25],
        ['b', 0.3, 0.55],
        ['c', 0.6, 0.85],
        ['d', 0.9, 1.15],
        ['e', 1.2, 1.45],
        ['f', 1.85, 2.1], // adaptive break strands it; the rescue re-homes it
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 1);
  assert.equal(lines[0].text, 'a b c d e f');
});

test('grouping: a word stranded across a long pause stays its own line', () => {
  const lines = groupWhisperSegments(
    [
      seg([
        ['a', 0, 0.25],
        ['b', 0.3, 0.55],
        ['c', 0.6, 0.85],
        ['d', 0.9, 1.15],
        ['e', 1.2, 1.45],
        ['f', 2.35, 2.6], // 0.9s gap — too far to rescue
      ]),
    ],
    FPS,
  );
  assert.equal(lines.length, 2);
  assert.equal(lines[1].text, 'f');
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

// ---- Detection cleanup (Whisper junk tokens + echo repeats) --------------

test('cleanup: a [_BEG_]-only segment produces no line at all', () => {
  const lines = groupWhisperSegments(
    [
      // The screenshot's case: the begin marker as its own
      // zero-length "line", plus a bare timestamp-token segment.
      { text: '[_BEG_]', startSeconds: 103, endSeconds: 103, words: [w('[_BEG_]', 103, 103)] },
      { text: '[_TT_500]', startSeconds: 104, endSeconds: 104, words: [] },
    ],
    FPS,
  );
  assert.equal(lines.length, 0);
});

test('cleanup: a bracket token glued to a word is stripped, the word stays', () => {
  // The screenshot's other case: "me?[_TT_500]".
  const lines = groupWhisperSegments(
    [seg([['Hello,', 0, 0.5], ['see', 0.55, 0.9], ['me?[_TT_500]', 0.95, 1.5]])],
    FPS,
  );
  assert.equal(lines.length, 1);
  assert.equal(lines[0].text, 'Hello, see me?');
  assert.equal(lines[0].words[2].text, 'me?');
});

test('cleanup: back-to-back identical lines collapse to the first (echo repeats)', () => {
  const lines = groupWhisperSegments(
    [
      seg([['hello', 0, 0.4], ['world', 0.45, 0.9]]),
      seg([['hello', 1.2, 1.6], ['world', 1.65, 2.1]]),
      seg([['hello', 2.4, 2.8], ['world', 2.85, 3.3]]),
    ],
    FPS,
  );
  assert.equal(lines.length, 1);
  assert.equal(lines[0].startFrame, 0); // the FIRST occurrence survives
});

test('cleanup: a repeat that returns later (a chorus) is kept', () => {
  const lines = groupWhisperSegments(
    [
      seg([['hello', 0, 0.4], ['world', 0.45, 0.9]]),
      seg([['something', 1.2, 1.7], ['else', 1.75, 2.1]]),
      seg([['hello', 3.0, 3.4], ['world', 3.45, 3.9]]),
    ],
    FPS,
  );
  assert.deepEqual(
    lines.map((l) => l.text),
    ['hello world', 'something else', 'hello world'],
  );
});

test('cleanup: cleanDetectedLyrics strips saved junk and collapses normalized duplicates', () => {
  const line = (id, text, s, words) => ({
    id,
    text,
    startFrame: s,
    endFrame: s + 30,
    ...(words ? { words } : {}),
  });
  const saved = [
    line('a', '[_BEG_]', 0, [{ text: '[_BEG_]', startFrame: 0, endFrame: 0 }]),
    line('b', 'me?[_TT_500]', 30, [{ text: 'me?[_TT_500]', startFrame: 30, endFrame: 60 }]),
    line('c', 'Hello, World!', 60),
    line('d', 'hello world', 90), // same line modulo case/punctuation, consecutive — drops
    line('e', 'a different line', 120),
    line('f', 'Hello, World!', 150), // chorus return — kept
  ];
  const cleaned = cleanDetectedLyrics(saved);
  assert.deepEqual(
    cleaned.map((l) => l.text),
    ['me?', 'Hello, World!', 'a different line', 'Hello, World!'],
  );
  assert.equal(cleaned[0].words[0].text, 'me?');
});

test('profanity: respellLyricProfanity applies Jaizon\'s clean versions with casing', () => {
  assert.equal(respellLyricProfanity('niggas'), 'ngas');
  assert.equal(respellLyricProfanity('nigga'), 'nga');
  assert.equal(respellLyricProfanity('Niggas'), 'Ngas');
  assert.equal(respellLyricProfanity('NIGGA'), 'NGA');
  assert.equal(respellLyricProfanity('fuck'), 'f');
  assert.equal(respellLyricProfanity('Fuck'), 'F');
  assert.equal(respellLyricProfanity('FUCK'), 'F');
  assert.equal(respellLyricProfanity('bitch'), 'bih');
  assert.equal(respellLyricProfanity('Bitch'), 'Bih');
  assert.equal(respellLyricProfanity('shit'), 'shi');
  assert.equal(respellLyricProfanity('Shit'), 'Shi');
});

test('profanity: inflections fold to the same roots', () => {
  assert.equal(respellLyricProfanity('fucking'), 'f');
  assert.equal(respellLyricProfanity("fuckin'"), 'f');
  assert.equal(respellLyricProfanity('fucked'), 'f');
  assert.equal(respellLyricProfanity('bitches'), 'bih');
  assert.equal(respellLyricProfanity('shitty'), 'shi');
  assert.equal(respellLyricProfanity('niggaz'), 'ngas');
});

test('profanity: punctuation neighbours survive, lookalike words untouched', () => {
  assert.equal(respellLyricProfanity('fuck, that shit!'), 'f, that shi!');
  assert.equal(respellLyricProfanity('shitake mushrooms in class'), 'shitake mushrooms in class');
  assert.equal(respellLyricProfanity('a clean line entirely'), 'a clean line entirely');
});

test('profanity: cleanDetectedLyrics respells line text and words', () => {
  const saved = [
    {
      id: 'a',
      text: 'my niggas fuck shit up',
      startFrame: 0,
      endFrame: 60,
      words: [
        { text: 'my', startFrame: 0, endFrame: 10 },
        { text: 'niggas', startFrame: 10, endFrame: 25 },
        { text: 'fuck', startFrame: 25, endFrame: 40 },
        { text: 'shit', startFrame: 40, endFrame: 55 },
        { text: 'up', startFrame: 55, endFrame: 60 },
      ],
    },
  ];
  const cleaned = cleanDetectedLyrics(saved);
  assert.equal(cleaned[0].text, 'my ngas f shi up');
  assert.deepEqual(
    cleaned[0].words.map((word) => word.text),
    ['my', 'ngas', 'f', 'shi', 'up'],
  );
});

test('cleanup: cleanDetectedLyrics is idempotent and leaves clean lines untouched', () => {
  const saved = [
    { id: 'a', text: 'clean line', startFrame: 0, endFrame: 30 },
    { id: 'b', text: 'another one', startFrame: 30, endFrame: 60 },
  ];
  const once = cleanDetectedLyrics(saved);
  assert.equal(once[0], saved[0]); // identity preserved — nothing needed changing
  assert.equal(once[1], saved[1]);
  assert.deepEqual(cleanDetectedLyrics(once), once);
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

test('payload: offsetFrames shifts every line and word at the boundary', () => {
  const project = {
    ...payloadProject([
      {
        id: 'a',
        text: 'one two',
        startFrame: 330,
        endFrame: 390,
        words: [
          { text: 'one', startFrame: 330, endFrame: 360 },
          { text: 'two', startFrame: 360, endFrame: 390 },
        ],
      },
    ]),
    offsetFrames: 15, // +0.5s — Jaizon's "off by half a second" case
  };
  const payload = buildCompositeLyrics(project, 300, FPS);
  assert.equal(payload.lines[0].startSeconds, 1.5);
  assert.equal(payload.lines[0].endSeconds, 3.5);
  assert.equal(payload.lines[0].words[0].startSeconds, 1.5);
  assert.equal(payload.lines[0].words[1].endSeconds, 3.5);
  // The authored project is untouched — the offset is render-time only.
  assert.equal(project.lines[0].startFrame, 330);
});

test('payload: a negative offset can push a line out of the window', () => {
  const project = {
    ...payloadProject([{ id: 'a', text: 'hi', startFrame: 300, endFrame: 330 }]),
    offsetFrames: -45,
  };
  assert.equal(buildCompositeLyrics(project, 300, FPS), null);
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

// ── JS↔Swift bridge contract ─────────────────────────────────────
// Regression (Jaizon, 2026-11-10): lyrics exported in "a basic font
// with no style". The Expo bridge converts the request's lyrics
// record BY FIELD NAME; the Swift LyricStyleRecord declared
// postScriptName / colorHex / strokeColorHex / backgroundColorHex
// while the payload emits fontPostScriptName / color / strokeColor /
// backgroundColor — so every styled field arrived empty on device
// (system font, white, no stroke) while previews (pure JS) looked
// right. These tests pin the payload's keys to the Swift records'
// @Field names so the two sides can never drift again silently.
const fs = require('node:fs');
const path = require('node:path');

function swiftRecordFields(structName) {
  const swiftPath = path.join(
    __dirname,
    '..',
    'modules',
    'mvmt-compositor',
    'ios',
    'MvmtCompositorModule.swift',
  );
  const source = fs.readFileSync(swiftPath, 'utf8');
  const match = source.match(new RegExp(`struct ${structName}: Record \\{([\\s\\S]*?)\\n\\}`));
  assert.ok(match, `Swift record ${structName} not found`);
  return [...match[1].matchAll(/var (\w+):/g)].map((m) => m[1]).sort();
}

test('composite lyric style keys match the Swift LyricStyleRecord fields exactly', () => {
  const payload = buildCompositeLyrics(
    payloadProject([{ id: 'a', text: 'hi', startFrame: 0, endFrame: 30 }], {
      strokeColor: '#000000',
      strokeWidthRatio: 0.1,
      background: 'pill',
      backgroundColor: '#111111',
    }),
    0,
    FPS,
  );
  assert.deepEqual(Object.keys(payload.style).sort(), swiftRecordFields('LyricStyleRecord'));
  assert.deepEqual(
    Object.keys(payload.style.animation).sort(),
    swiftRecordFields('LyricAnimationRecord'),
  );
});

test('composite lyric line keys match the Swift LyricLineRecord fields', () => {
  const payload = buildCompositeLyrics(
    payloadProject([
      {
        id: 'a',
        text: 'hi there',
        startFrame: 0,
        endFrame: 30,
        words: [
          { text: 'hi', startFrame: 0, endFrame: 15 },
          { text: 'there', startFrame: 15, endFrame: 30 },
        ],
      },
    ]),
    0,
    FPS,
  );
  const swiftLineFields = swiftRecordFields('LyricLineRecord');
  for (const key of Object.keys(payload.lines[0])) {
    assert.ok(swiftLineFields.includes(key), `payload line key ${key} has no Swift field`);
  }
  // Stage 2: `decor` is optional on LyricsRecord (nil = classic
  // style), so the classic payload's top-level keys are a SUBSET —
  // the exact match lives in the template payload test below.
  const swiftLyricsFields = swiftRecordFields('LyricsRecord');
  for (const key of Object.keys(payload)) {
    assert.ok(swiftLyricsFields.includes(key), `payload key ${key} has no Swift field`);
  }
  assert.equal(payload.decor, undefined);
});

// ── Style catalog contract (Styles Redesign Stage 1) ─────────────
// Fonts and animations carry exactly one browse category each, and
// near-duplicate animations are hidden from the picker behind an
// alias map — but a project that stored the old id must still
// render, as the survivor.
const {
  LYRIC_ANIMATIONS,
  LYRIC_ANIMATION_ALIASES,
  LYRIC_ANIMATION_CATEGORIES,
  PICKER_ANIMATIONS,
  lyricAnimationById,
  resolveAnimationParams,
} = require('./.build-lyrics/src/lib/lyricAnimations.js');
const {
  LYRIC_FONTS,
  LYRIC_FONT_CATEGORIES,
  lyricFontById,
} = require('./.build-lyrics/src/lib/lyricFonts.js');

test('catalog: 50 fonts, each in exactly one of the 6 font categories', () => {
  assert.equal(LYRIC_FONTS.length, 50);
  assert.equal(new Set(LYRIC_FONTS.map((f) => f.id)).size, 50);
  for (const font of LYRIC_FONTS) {
    assert.ok(
      LYRIC_FONT_CATEGORIES.includes(font.category),
      `${font.id} has no valid category`,
    );
  }
  const counts = {};
  for (const f of LYRIC_FONTS) counts[f.category] = (counts[f.category] ?? 0) + 1;
  assert.deepEqual(counts, {
    'Clean Sans': 13,
    'Serif & Elegant': 12,
    'Handwritten & Playful': 12,
    'Display & Impact': 7,
    'Typewriter & Mono': 3,
    Script: 3,
  });
});

test('catalog: 50 animations, each in exactly one of the 6 animation categories', () => {
  assert.equal(LYRIC_ANIMATIONS.length, 50);
  assert.equal(new Set(LYRIC_ANIMATIONS.map((a) => a.id)).size, 50);
  for (const a of LYRIC_ANIMATIONS) {
    assert.ok(
      LYRIC_ANIMATION_CATEGORIES.includes(a.category),
      `${a.id} has no valid category`,
    );
  }
});

test('catalog: every animation alias points at a real survivor, never at another alias', () => {
  for (const [alias, target] of Object.entries(LYRIC_ANIMATION_ALIASES)) {
    assert.ok(
      LYRIC_ANIMATIONS.some((a) => a.id === alias),
      `alias source ${alias} is not a catalog id`,
    );
    assert.ok(
      LYRIC_ANIMATIONS.some((a) => a.id === target),
      `alias target ${target} is not a catalog id`,
    );
    assert.ok(!(target in LYRIC_ANIMATION_ALIASES), `alias ${alias} chains to ${target}`);
    assert.notEqual(alias, target);
  }
});

test('catalog: the picker shows 34 animations — every survivor, no alias', () => {
  assert.equal(
    PICKER_ANIMATIONS.length,
    LYRIC_ANIMATIONS.length - Object.keys(LYRIC_ANIMATION_ALIASES).length,
  );
  const pickerIds = new Set(PICKER_ANIMATIONS.map((a) => a.id));
  for (const alias of Object.keys(LYRIC_ANIMATION_ALIASES)) {
    assert.ok(!pickerIds.has(alias), `picker still shows aliased ${alias}`);
  }
  for (const a of LYRIC_ANIMATIONS) {
    if (!(a.id in LYRIC_ANIMATION_ALIASES)) assert.ok(pickerIds.has(a.id), `picker hides survivor ${a.id}`);
  }
});

test('catalog: an aliased animation id resolves to its survivor', () => {
  const cases = {
    'soft-rise': 'rise',
    'float-up': 'float',
    'slide-fade-left': 'slide-left',
    'slide-fade-right': 'slide-right',
    'swing-left': 'swing',
    'swing-right': 'swing',
    'zoom-far': 'zoom',
    'impact-soft': 'impact',
    'shrink-out': 'zoom',
    'karaoke-rise': 'karaoke',
    'highlight-sweep': 'karaoke',
    'typewriter-fast': 'typewriter',
    'word-drop': 'word-rise',
    'cascade-down': 'cascade',
    'fade-slow': 'fade',
    'glow-pulse': 'pulse',
  };
  assert.equal(Object.keys(cases).length, Object.keys(LYRIC_ANIMATION_ALIASES).length);
  for (const [alias, survivor] of Object.entries(cases)) {
    assert.equal(lyricAnimationById(alias).id, survivor, `${alias} should resolve to ${survivor}`);
    assert.deepEqual(resolveAnimationParams(alias), resolveAnimationParams(survivor));
  }
  // Unknown ids still fall back to the default preset.
  assert.equal(lyricAnimationById('not-a-preset').id, 'karaoke');
});

test('catalog: aliased ids still render through the composite payload', () => {
  const payload = buildCompositeLyrics(
    payloadProject([{ id: 'a', text: 'hi', startFrame: 0, endFrame: 30 }], { animationId: 'soft-rise' }),
    0,
    FPS,
  );
  assert.equal(payload.style.animation.enterSecs, 0.4); // rise's params, not soft-rise's
  assert.equal(payload.style.animation.wordMode, 'none');
  const glow = buildCompositeLyrics(
    payloadProject([{ id: 'a', text: 'hi', startFrame: 0, endFrame: 30 }], { animationId: 'glow-pulse' }),
    0,
    FPS,
  );
  assert.equal(glow.style.animation.emphasisScale, 1.08); // pulse's params
});

test('catalog: unknown font ids fall back to the default font', () => {
  assert.equal(lyricFontById('not-a-font').id, 'avenir-next');
});

// ── Extra Styles contract (Styles Redesign Stage 2) ──────────────
// Thirty complete templates (own font/palette/animation/decor) over one
// parametric decor model; the decor registry must exist on BOTH
// sides (JS preview + Swift burn-in) or a kind renders nowhere.
const {
  LYRIC_TEMPLATES,
  LYRIC_DECOR_KINDS,
  EXTRA_STYLE_CATEGORIES,
  lyricTemplateById,
  resolveLyricDecor,
} = require('./.build-lyrics/src/lib/lyricTemplates.js');
const { analyzeLyricLine } = require('./.build-lyrics/src/lib/lyrics.js');

test('templates: exactly 30, unique ids, one of the 6 categories each', () => {
  assert.equal(LYRIC_TEMPLATES.length, 30);
  const ids = LYRIC_TEMPLATES.map((t) => t.id);
  assert.equal(new Set(ids).size, 30);
  for (const t of LYRIC_TEMPLATES) {
    assert.ok(EXTRA_STYLE_CATEGORIES.includes(t.category), `${t.id} category ${t.category}`);
    assert.ok(t.name && t.tagline, `${t.id} needs a name and tagline`);
  }
  assert.equal(lyricTemplateById('not-a-template'), undefined);
  assert.equal(lyricTemplateById('emoji-story').name, 'Emoji Story');
  assert.equal(lyricTemplateById('split-screen-words').name, 'Split Screen Words');
});

test('templates: every template references a real picker animation and a real font', () => {
  const pickerIds = new Set(PICKER_ANIMATIONS.map((a) => a.id));
  const fontIds = new Set(LYRIC_FONTS.map((f) => f.id));
  for (const t of LYRIC_TEMPLATES) {
    assert.ok(pickerIds.has(t.style.animationId), `${t.id} animationId ${t.style.animationId} is not in the picker`);
    assert.ok(fontIds.has(t.style.fontId), `${t.id} fontId ${t.style.fontId} is not in the font catalog`);
  }
});

test('decor: resolveLyricDecor folds the Stage 3 field defaults', () => {
  const bare = resolveLyricDecor({ kind: 'glow' });
  assert.equal(bare.rotationDeg, 0);
  assert.equal(bare.tracking, 0);
  assert.equal(bare.align, 'center');
  assert.equal(bare.kind, 'glow');
  // Explicit values survive the fold.
  const tilted = resolveLyricDecor({ kind: 'spray', rotationDeg: -3, tracking: 0.35, align: 'left' });
  assert.equal(tilted.rotationDeg, -3);
  assert.equal(tilted.tracking, 0.35);
  assert.equal(tilted.align, 'left');
});

// LyricStyle fields, read from the type itself — defaultLyricStyle()
// omits the optional fields (strokeColor, maxWidthRatio, …), so its
// keys are not the full field set.
function lyricStyleFields() {
  const source = fs.readFileSync(path.join(__dirname, '..', 'src', 'types.ts'), 'utf8');
  const match = source.match(/export interface LyricStyle \{([\s\S]*?)\n\}/);
  assert.ok(match, 'LyricStyle interface not found');
  return new Set([...match[1].matchAll(/^  (\w+)\??:/gm)].map((m) => m[1]));
}

test('templates: every style override is a real LyricStyle field and resolves', () => {
  const styleKeys = lyricStyleFields();
  for (const t of LYRIC_TEMPLATES) {
    for (const key of Object.keys(t.style)) {
      assert.ok(styleKeys.has(key), `${t.id} style key ${key} is not a LyricStyle field`);
    }
    // The merged style must resolve exactly like a classic style.
    const payload = buildCompositeLyrics(
      payloadProject(
        [{ id: 'a', text: 'hi', startFrame: 0, endFrame: 30 }],
        { ...t.style },
      ),
      0,
      FPS,
    );
    assert.equal(payload.style.fontPostScriptName.length > 0, true);
    assert.equal(payload.style.animation.wordMode, lyricAnimationById(t.style.animationId ?? 'karaoke').wordMode);
  }
});

test('decor: the 20 kinds exist on the Swift side too (registry parity)', () => {
  // The Swift side has no decor enum — `LyricDecorRecord.kind` is a
  // plain string and the builders switch on the literal
  // (`decorKind == "emoji-row"`, …). Parity is pinned two ways: the
  // JS mirror list SWIFT_DECOR_KINDS must equal the preview list,
  // and every kind's literal must appear in the Swift source, so a
  // kind can never exist on one side only.
  const {
    SWIFT_DECOR_KINDS,
  } = require('./.build-lyrics/src/lib/lyricTemplates.js');
  assert.deepEqual([...LYRIC_DECOR_KINDS].sort(), [...SWIFT_DECOR_KINDS].sort());
  const swiftPath = path.join(__dirname, '..', 'modules', 'mvmt-compositor', 'ios', 'MvmtCompositorModule.swift');
  const source = fs.readFileSync(swiftPath, 'utf8');
  for (const kind of LYRIC_DECOR_KINDS) {
    assert.ok(source.includes(`"${kind}"`), `Swift has no branch for decor kind ${kind}`);
  }
});

test('decor: every template decor kind is in the registry', () => {
  for (const t of LYRIC_TEMPLATES) {
    assert.ok(LYRIC_DECOR_KINDS.includes(t.decor.kind), `${t.id} decor kind ${t.decor.kind}`);
  }
});

test('payload: template decor keys match the Swift LyricDecorRecord fields exactly', () => {
  const decor = resolveLyricDecor(LYRIC_TEMPLATES[0].decor);
  assert.deepEqual(Object.keys(decor).sort(), swiftRecordFields('LyricDecorRecord'));
  // Every template's decor resolves to the same key set.
  for (const t of LYRIC_TEMPLATES) {
    assert.deepEqual(Object.keys(resolveLyricDecor(t.decor)).sort(), swiftRecordFields('LyricDecorRecord'));
  }
});

test('payload: a template project emits decor + line intelligence; a classic project emits neither', () => {
  const line = {
    id: 'a',
    text: 'I love you NEVER',
    startFrame: 0,
    endFrame: 60,
    words: [
      { text: 'I', startFrame: 0, endFrame: 10 },
      { text: 'love', startFrame: 10, endFrame: 25 },
      { text: 'you', startFrame: 25, endFrame: 40 },
      { text: 'NEVER', startFrame: 40, endFrame: 60 },
    ],
    decor: analyzeLyricLine('I love you NEVER'),
  };
  const templatePayload = buildCompositeLyrics(
    { ...payloadProject([line]), templateId: 'emoji-story' },
    0,
    FPS,
  );
  assert.ok(templatePayload.decor, 'template payload carries decor');
  assert.deepEqual(Object.keys(templatePayload.decor).sort(), swiftRecordFields('LyricDecorRecord'));
  // With a template active the top-level keys match LyricsRecord
  // exactly (the classic payload is a subset — see the line-keys
  // test above).
  assert.deepEqual(Object.keys(templatePayload).sort(), swiftRecordFields('LyricsRecord'));
  assert.equal(templatePayload.lines[0].emoji, '❤️');
  assert.equal(templatePayload.lines[0].tone, 'love');
  assert.deepEqual(templatePayload.lines[0].emphasisWordIndices, [3]);
  for (const key of Object.keys(templatePayload.lines[0])) {
    assert.ok(
      swiftRecordFields('LyricLineRecord').includes(key),
      `payload line key ${key} has no Swift field`,
    );
  }
  const classicPayload = buildCompositeLyrics(payloadProject([line]), 0, FPS);
  assert.equal(classicPayload.decor, undefined);
  assert.equal(classicPayload.lines[0].emoji, undefined);
  assert.equal(classicPayload.lines[0].tone, undefined);
  assert.equal(classicPayload.lines[0].emphasisWordIndices, undefined);
});

// ── Lyric intelligence (Styles Redesign Stage 2) ─────────────────
// Deterministic, computed once at Detect / on line edits, stored on
// the line — renderers only read it. No match means no emoji, never
// a guess; tones come only from the word lists.
test('intelligence: emoji is the first dictionary hit in line order', () => {
  assert.equal(analyzeLyricLine('fire in my heart tonight').emoji, '🔥');
  assert.equal(analyzeLyricLine('I love you tonight').emoji, '❤️');
  assert.equal(analyzeLyricLine('driving my car fast').emoji, '🚗');
  // No match means no decor at all — never a guessed emoji.
  assert.equal(analyzeLyricLine('just some ordinary words'), undefined);
});

test('intelligence: tone comes only from the lists, love beats joy', () => {
  assert.equal(analyzeLyricLine('I love this happy day').tone, 'love');
  assert.equal(analyzeLyricLine('so happy dancing all night').tone, 'joy');
  assert.equal(analyzeLyricLine('crying in the rain alone').tone, 'sad');
  assert.equal(analyzeLyricLine('I am so angry right now').tone, 'anger');
  assert.equal(analyzeLyricLine('turn it up lets go wild').tone, 'hype');
  assert.equal(analyzeLyricLine('just some ordinary words'), undefined);
});

test('intelligence: emphasis flags ALL-CAPS words and repeats', () => {
  assert.deepEqual(analyzeLyricLine('I said NEVER again').emphasisWordIndices, [2]);
  assert.deepEqual(analyzeLyricLine('go go home').emphasisWordIndices, [0, 1]);
  // A line with decor but no emphasis carries no emphasis key.
  assert.equal(analyzeLyricLine('I love you').emphasisWordIndices, undefined);
});

test('intelligence: detection stores decor on the line', () => {
  const lines = groupWhisperSegments([
    seg(
      [
        ['I', 0, 0.3],
        ['love', 0.3, 0.6],
        ['you', 0.6, 1],
      ],
      0,
      1,
    ),
  ]);
  assert.equal(lines.length, 1);
  assert.equal(lines[0].decor.emoji, '❤️');
  assert.equal(lines[0].decor.tone, 'love');
});
