/**
 * Extra Styles 2.0 — lyric interpretation (Phase 2 core engine).
 *
 * The derived-data artifact (docs §7.3): verse/chorus sections from
 * line-text repetition, plus extended semantic tags from a keyword
 * dictionary. Computed ahead of time, once, deterministically, and
 * cached on disk keyed by (song identity + lyrics hash + recipe
 * version) — never per frame, never an AI call. If the
 * interpretation is missing, the scene builder falls back to lines
 * + stored decor only; section-aware behaviour is disabled, not
 * faked.
 *
 * The dictionary extends the v1 emoji dictionary (src/lib/lyrics.ts
 * LYRIC_EMOJI_KEYWORDS) with the concept lists the 40 styles need
 * (weather, time, place, motion, emotion, objects). Same rule as
 * v1: a keyword match is a fact, no match = no tag, nothing guessed.
 */

import type {
  LyricInterpretation,
  LyricInterpretationLine,
  LyricInterpretationSection,
} from './types';
import { LYRIC_INTERPRETATION_VERSION } from './types';

export interface InterpretationInputLine {
  id: string;
  text: string;
  startFrame: number;
  endFrame: number;
}

/** Concept → keywords (whole-word, case-insensitive). A line may
 *  carry several tags; they are returned in dictionary order,
 *  capped at 3, so the most load-bearing concept leads. */
export const SEMANTIC_TAG_DICTIONARY: { tag: string; keywords: string[] }[] = [
  { tag: 'love', keywords: ['love', 'heart', 'baby', 'kiss', 'forever', 'darling', 'adore', 'sweetheart'] },
  { tag: 'heartbreak', keywords: ['heartbreak', 'broken', 'break', 'goodbye', 'gone', 'lost', 'leaving'] },
  { tag: 'joy', keywords: ['happy', 'smile', 'laugh', 'joy', 'celebrate', 'sunshine', 'beautiful', 'alive'] },
  { tag: 'hype', keywords: ['party', 'lit', 'wild', 'crazy', 'energy', 'dance', 'dancing', 'club', 'fire', 'hot', 'go'] },
  { tag: 'sad', keywords: ['sad', 'cry', 'tears', 'lonely', 'alone', 'pain', 'hurt', 'miss', 'sorry'] },
  { tag: 'anger', keywords: ['hate', 'mad', 'angry', 'fight', 'rage', 'furious', 'damn'] },
  { tag: 'weather-rain', keywords: ['rain', 'storm', 'thunder', 'lightning', 'pouring', 'wet'] },
  { tag: 'weather-snow', keywords: ['snow', 'winter', 'ice', 'cold', 'freeze', 'frozen'] },
  { tag: 'weather-sun', keywords: ['sun', 'summer', 'sunshine', 'sunrise', 'sunset', 'heat', 'beach'] },
  { tag: 'weather-sky', keywords: ['sky', 'clouds', 'cloud', 'stars', 'moon', 'night', 'morning'] },
  { tag: 'time', keywords: ['tonight', 'tomorrow', 'yesterday', 'morning', 'midnight', 'forever', 'always', 'never'] },
  { tag: 'place-city', keywords: ['city', 'street', 'lights', 'neon', 'downtown', 'avenue'] },
  { tag: 'place-sea', keywords: ['ocean', 'sea', 'waves', 'beach', 'shore', 'sail'] },
  { tag: 'motion', keywords: ['run', 'running', 'fly', 'flying', 'drive', 'driving', 'dance', 'dancing', 'move', 'moving', 'fall', 'falling', 'rise', 'rising'] },
  { tag: 'money', keywords: ['money', 'cash', 'rich', 'gold', 'diamond', 'diamonds', 'crown', 'king', 'queen'] },
  { tag: 'music', keywords: ['music', 'song', 'sing', 'mic', 'guitar', 'melody', 'rhythm', 'beat'] },
  { tag: 'phone', keywords: ['phone', 'call', 'text', 'message'] },
  { tag: 'dream', keywords: ['dream', 'dreams', 'dreaming', 'sleep', 'waking'] },
  { tag: 'hope', keywords: ['hope', 'faith', 'believe', 'pray', 'angel', 'heaven'] },
];

function normalizeToken(token: string): string {
  return token.toLowerCase().replace(/[^a-z0-9']/g, '');
}

/**
 * Extended semantic tags for one line's text. Whole-word matches
 * only; no match = no tags. Deterministic: same text → same tags.
 */
export function analyzeSemanticTags(text: string): string[] {
  const tokens = new Set(text.split(/\s+/).map(normalizeToken).filter(Boolean));
  if (tokens.size === 0) return [];
  const tags: string[] = [];
  for (const { tag, keywords } of SEMANTIC_TAG_DICTIONARY) {
    if (keywords.some((w) => tokens.has(w))) tags.push(tag);
    if (tags.length >= 3) break;
  }
  return tags;
}

/** FNV-1a 32-bit hash — stable across launches (same algorithm the
 *  native caches use for their keys). */
export function fnv1a32(input: string): number {
  let hash = 0x811c9dc5;
  for (let i = 0; i < input.length; i += 1) {
    hash ^= input.charCodeAt(i);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

/** Hash of the stored lines + words an interpretation was built
 *  from — a lyrics edit invalidates the cached artifact. */
export function lyricsHash(lines: InterpretationInputLine[]): string {
  const canonical = JSON.stringify(
    lines.map((l) => [l.id, l.text, l.startFrame, l.endFrame]),
  );
  return fnv1a32(canonical).toString(16).padStart(8, '0');
}

function normalizeLineText(text: string): string {
  return text.toLowerCase().replace(/[^a-z0-9\s']/g, '').replace(/\s+/g, ' ').trim();
}

/**
 * Verse / chorus sections from line-text repetition (docs §7.2).
 *
 * - The longest repeated block of ≥2 consecutive lines is the
 *   chorus; every occurrence is a chorus section.
 * - The spans between chorus occurrences are verses (a span of a
 *   single line becomes 'other' — too short to call a verse).
 * - No repeated block → no sections at all (styles fall back to
 *   line-by-line behaviour); nothing is guessed.
 * - Confidence for a chorus occurrence scales with how much of the
 *   song the repeated block covers; verses report 0.5 (structural,
 *   not measured).
 */
export function detectSections(lines: InterpretationInputLine[]): LyricInterpretationSection[] {
  if (lines.length < 4) return [];
  const normalized = lines.map((l) => normalizeLineText(l.text));
  // Longest repeated consecutive block (length ≥ 2 lines), found
  // by comparing every pair of start positions.
  let bestLen = 0;
  let bestStarts: number[] = [];
  for (let len = Math.floor(lines.length / 2); len >= 2; len -= 1) {
    const starts: number[] = [];
    for (let i = 0; i + len <= lines.length; i += 1) {
      for (let j = i + 1; j + len <= lines.length; j += 1) {
        let match = true;
        for (let k = 0; k < len; k += 1) {
          if (normalized[i + k] !== normalized[j + k] || normalized[i + k].length === 0) {
            match = false;
            break;
          }
        }
        if (match) {
          if (!starts.includes(i)) starts.push(i);
          if (!starts.includes(j)) starts.push(j);
        }
      }
    }
    if (starts.length >= 2) {
      bestLen = len;
      bestStarts = starts.sort((a, b) => a - b);
      break;
    }
  }
  if (bestLen === 0) return [];
  const chorusCoverage = (bestStarts.length * bestLen) / lines.length;
  const confidence = Math.max(0.3, Math.min(1, chorusCoverage * 1.5));
  const sections: LyricInterpretationSection[] = [];
  let cursor = 0;
  for (const start of bestStarts) {
    if (start > cursor) {
      const span = lines.slice(cursor, start);
      const kind: LyricInterpretationSection['kind'] = span.length >= 2 ? 'verse' : 'other';
      sections.push({
        kind,
        startFrame: span[0].startFrame,
        endFrame: span[span.length - 1].endFrame,
        confidence: kind === 'verse' ? 0.5 : 0.3,
      });
    }
    const block = lines.slice(start, start + bestLen);
    sections.push({
      kind: 'chorus',
      startFrame: block[0].startFrame,
      endFrame: block[block.length - 1].endFrame,
      confidence,
    });
    cursor = start + bestLen;
  }
  if (cursor < lines.length) {
    const span = lines.slice(cursor);
    const kind: LyricInterpretationSection['kind'] = span.length >= 2 ? 'verse' : 'other';
    sections.push({
      kind,
      startFrame: span[0].startFrame,
      endFrame: span[span.length - 1].endFrame,
      confidence: kind === 'verse' ? 0.5 : 0.3,
    });
  }
  return sections;
}

/** Build the interpretation artifact for a project's lyrics. */
export function buildLyricInterpretation(
  lines: InterpretationInputLine[],
  songKey: string,
): LyricInterpretation {
  const perLine: LyricInterpretationLine[] = lines.map((line) => ({
    lineId: line.id,
    semanticTags: analyzeSemanticTags(line.text),
  }));
  return {
    version: LYRIC_INTERPRETATION_VERSION,
    songKey,
    lyricsHash: lyricsHash(lines),
    sections: detectSections(lines),
    lines: perLine,
  };
}

// ---------------------------------------------------------------------------
// Syllables — a deterministic vowel-group heuristic over word
// timings (docs §17 #29, Rhythm Typography). Approximate, never
// phonetic: a word is split at vowel-group boundaries, keeping the
// consonants before each vowel group with that group. The result
// is documented as approximate in the style, not hidden.
// ---------------------------------------------------------------------------

const VOWELS = new Set(['a', 'e', 'i', 'o', 'u', 'y']);

/** Split one word into approximate syllables. */
export function splitWordIntoSyllables(word: string): string[] {
  const letters = word.toLowerCase().replace(/[^a-z']/g, '');
  if (letters.length === 0) return [];
  if (letters.length <= 3) return [word];
  // Find vowel-group starts.
  const groups: number[] = [];
  for (let i = 0; i < letters.length; i += 1) {
    if (VOWELS.has(letters[i]) && (i === 0 || !VOWELS.has(letters[i - 1]))) {
      groups.push(i);
    }
  }
  if (groups.length <= 1) return [word];
  // Split one consonant before each vowel-group start: a single
  // intervocalic consonant opens the next syllable ("mu-sic"),
  // and a cluster splits between its consonants ("hel-lo",
  // "win-dow"). "beau-ti-ful" falls out of the same rule.
  const boundaries: number[] = [];
  for (let g = 1; g < groups.length; g += 1) {
    boundaries.push(groups[g] - 1);
  }
  const parts: string[] = [];
  let start = 0;
  for (const b of boundaries) {
    if (b > start) {
      parts.push(word.slice(start, b));
      start = b;
    }
  }
  if (start < word.length) parts.push(word.slice(start));
  return parts.filter(Boolean);
}
