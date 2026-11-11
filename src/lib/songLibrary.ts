import type { ProjectLyrics, SongLibraryEntry } from '../types';

/**
 * Song library — pure helpers (the store owns the state).
 *
 * A song's identity is its file name plus its duration: the same
 * audio picked again — from Files, or from the library itself —
 * produces the same key, while a different song that merely shares
 * a file name is kept apart by the duration. Matching tolerates
 * small duration disagreements (a re-measured file can drift by a
 * fraction of a second between imports).
 */

/** Normalise a track name for keying: drop the extension, fold
 * case, punctuation and spacing away. */
export function normalizeSongName(name: string): string {
  return name
    .replace(/\.[a-z0-9]{2,5}$/i, '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** The library key for a song. Unknown duration keys on name only. */
export function songLibraryKey(name: string, durationSeconds?: number): string {
  const base = normalizeSongName(name);
  if (durationSeconds === undefined || !Number.isFinite(durationSeconds) || durationSeconds <= 0) {
    return base;
  }
  return `${base}|${Math.round(durationSeconds)}`;
}

/**
 * Find the entry for a song: exact key first, then a same-name
 * entry whose duration agrees within 1.5s (the import paths do not
 * always measure identically). Returns undefined when the library
 * has never seen this song.
 */
export function findSongLibraryEntry(
  entries: SongLibraryEntry[],
  name: string,
  durationSeconds?: number,
): SongLibraryEntry | undefined {
  const exact = entries.find((e) => e.key === songLibraryKey(name, durationSeconds));
  if (exact) return exact;
  const base = normalizeSongName(name);
  if (!base) return undefined;
  return entries.find((e) => {
    if (normalizeSongName(e.name) !== base) return false;
    if (durationSeconds === undefined || e.durationSeconds === undefined) return true;
    return Math.abs(e.durationSeconds - durationSeconds) <= 1.5;
  });
}

/**
 * Insert or refresh the entry for a song's lyrics. The freshest
 * save wins, entries stay newest-first, and the library is capped
 * (oldest drop off) so it cannot grow without bound.
 */
export function upsertSongLibraryEntry(
  entries: SongLibraryEntry[],
  input: { name: string; uri: string; durationSeconds?: number; lyrics: ProjectLyrics; now: number },
): SongLibraryEntry[] {
  const key = songLibraryKey(input.name, input.durationSeconds);
  const entry: SongLibraryEntry = {
    key,
    name: input.name,
    uri: input.uri,
    ...(input.durationSeconds !== undefined ? { durationSeconds: input.durationSeconds } : {}),
    lyrics: input.lyrics,
    updatedAt: input.now,
  };
  const rest = entries.filter((e) => e.key !== key);
  return [entry, ...rest].sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 50);
}

/** Drop one entry by key (user removed it from the library). */
export function removeSongLibraryEntry(entries: SongLibraryEntry[], key: string): SongLibraryEntry[] {
  return entries.filter((e) => e.key !== key);
}
