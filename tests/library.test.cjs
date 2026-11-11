/**
 * Node tests for the song library helpers (src/lib/songLibrary.ts):
 * keying, matching and upsert. Run with: npm run test:library
 * (tsc compiles the pure module into tests/.build-library, then
 * node --test runs this file against the compiled JS.)
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  normalizeSongName,
  songLibraryKey,
  findSongLibraryEntry,
  upsertSongLibraryEntry,
  removeSongLibraryEntry,
} = require('./.build-library/src/lib/songLibrary.js');

const lyrics = { lines: [{ id: 'a', text: 'hi', startFrame: 0, endFrame: 30 }], style: {} };
const entry = (name, durationSeconds, uri = 'file:///song.m4a', updatedAt = 1) => ({
  key: songLibraryKey(name, durationSeconds),
  name,
  uri,
  ...(durationSeconds !== undefined ? { durationSeconds } : {}),
  lyrics,
  updatedAt,
});

test('key: name is normalised, duration rounds into the key', () => {
  assert.equal(normalizeSongName('My Song (Official).MP3'), 'my song official');
  assert.equal(songLibraryKey('My Song.mp3', 187.4), 'my song|187');
  assert.equal(songLibraryKey('My Song.mp3', 187.6), 'my song|188');
  assert.equal(songLibraryKey('My Song.mp3'), 'my song');
  assert.equal(songLibraryKey('My Song.mp3', 0), 'my song');
});

test('find: exact key, then name with duration tolerance', () => {
  const entries = [entry('Blue Suede.mp3', 200), entry('Red Dress.mp3', 180)];
  assert.equal(findSongLibraryEntry(entries, 'Blue Suede.mp3', 200)?.name, 'Blue Suede.mp3');
  // A re-measured duration within 1.5s still finds the song.
  assert.equal(findSongLibraryEntry(entries, 'blue suede', 201.4)?.name, 'Blue Suede.mp3');
  // A different song that happens to share the name does not match.
  assert.equal(findSongLibraryEntry(entries, 'Blue Suede.mp3', 320), undefined);
  assert.equal(findSongLibraryEntry(entries, 'Unknown.mp3', 100), undefined);
});

test('upsert: refresh replaces, newest first, cap holds', () => {
  let entries = [];
  entries = upsertSongLibraryEntry(entries, { name: 'A.mp3', uri: 'file:///a', durationSeconds: 100, lyrics, now: 10 });
  entries = upsertSongLibraryEntry(entries, { name: 'B.mp3', uri: 'file:///b', durationSeconds: 100, lyrics, now: 20 });
  assert.deepEqual(entries.map((e) => e.name), ['B.mp3', 'A.mp3']);
  const fixed = { lines: [{ id: 'x', text: 'fixed', startFrame: 0, endFrame: 30 }], style: {} };
  entries = upsertSongLibraryEntry(entries, { name: 'A.mp3', uri: 'file:///a2', durationSeconds: 100, lyrics: fixed, now: 30 });
  assert.equal(entries.length, 2);
  assert.equal(entries[0].name, 'A.mp3');
  assert.equal(entries[0].uri, 'file:///a2');
  assert.equal(entries[0].lyrics.lines[0].text, 'fixed');
});

test('remove: drops by key only', () => {
  const entries = [entry('A.mp3', 100), entry('B.mp3', 100)];
  const next = removeSongLibraryEntry(entries, entries[0].key);
  assert.deepEqual(next.map((e) => e.name), ['B.mp3']);
});
