import type {
  CompositeLyricLine,
  CompositeLyrics,
  ResolvedLyricStyle,
} from '../../modules/mvmt-compositor/src/index';
import type { LyricLine, LyricStyle, LyricWord, ProjectLyrics } from '../types';
import { framesToSeconds, secondsToFrames } from './edl';
import { DEFAULT_ANIMATION_ID, resolveAnimationParams } from './lyricAnimations';
import { DEFAULT_FONT_ID, lyricFontById } from './lyricFonts';
import type { WhisperSegment } from './whisper';

/**
 * Lyrics helpers — grouping, frame mapping and payload building.
 *
 * THE timing rule of the feature: lyric lines live on the SONG
 * timeline in integer frames at the project fps (song-absolute, the
 * same clock as `Edl.audio.regionStartFrame`). The master song plays
 * continuously through every cut, so lines pinned to the song can
 * never be knocked out of sync by shuffle edits. The ONE mapping to
 * composition time happens here, at the native/overlay boundary:
 *
 *   timelineFrame = songFrame − regionStartFrame
 *
 * (the mirror of the take mapping in src/lib/edl.ts — region frame 0
 * of the song is composition frame 0).
 */

/** Grouping rules (Whisper output → singable lines). The grouper
 *  "decides which lyrics are a line": natural breaks first (segment
 *  boundaries, pauses, sentence ends), then hard caps split whatever
 *  is still too long, then a rescue pass re-homes stranded words. */
export const MAX_WORDS_PER_LINE = 7;
/** A pause longer than this always breaks the line. */
export const PAUSE_BREAK_SECONDS = 0.7;
/** A shorter pause already breaks once the line is at/over the soft
 *  target (this many words OR this duration) — lines should feel
 *  singable, not maximal. */
export const ADAPTIVE_PAUSE_SECONDS = 0.35;
export const SOFT_TARGET_WORDS = 5;
export const SOFT_TARGET_SECONDS = 2.2;
/** Hard caps: a line never exceeds these (a single word always may —
 *  it cannot be split). */
export const MAX_LINE_SECONDS = 3.5;
export const MAX_LINE_CHARS = 36;
/** When a cap forces a split, an internal pause at least this long
 *  counts as a split point (the largest one wins). */
export const SPLIT_PAUSE_SECONDS = 0.2;

let lyricIdCounter = 0;
export function newLyricLineId(): string {
  lyricIdCounter += 1;
  return `lyric-${Date.now().toString(36)}-${lyricIdCounter}`;
}

export function defaultLyricStyle(): LyricStyle {
  return {
    fontId: DEFAULT_FONT_ID,
    sizeRatio: 0.085,
    color: '#F4F1E9',
    background: 'none',
    position: 'bottom',
    animationId: DEFAULT_ANIMATION_ID,
    bold: true,
  };
}

/** Lines are always kept sorted by start (then end) frame. */
export function sortLyricLines(lines: LyricLine[]): LyricLine[] {
  return [...lines].sort((a, b) => a.startFrame - b.startFrame || a.endFrame - b.endFrame);
}

interface TimedWord {
  text: string;
  startSeconds: number;
  endSeconds: number;
}

const SENTENCE_END = /[.!?]+["'”’)]?$/;

function lineText(words: TimedWord[]): string {
  return words.map((w) => w.text).join(' ');
}

function lineDurationSeconds(words: TimedWord[]): number {
  return words.length === 0 ? 0 : words[words.length - 1].endSeconds - words[0].startSeconds;
}

/** Hard caps (words / duration / characters). A single word always
 *  "fits" — it cannot be split further. */
function lineFitsCaps(words: TimedWord[]): boolean {
  if (words.length <= 1) return true;
  return (
    words.length <= MAX_WORDS_PER_LINE &&
    lineDurationSeconds(words) <= MAX_LINE_SECONDS &&
    lineText(words).length <= MAX_LINE_CHARS
  );
}

/**
 * Phase 1 — natural breaks inside one segment: a pause over
 * PAUSE_BREAK_SECONDS always breaks; a pause of ADAPTIVE_PAUSE_SECONDS
 * or more breaks once the line is at/over the soft target (words or
 * duration); a sentence-ending word (. ! ?) closes the line when it
 * already holds at least two words.
 */
function chunkSegmentWords(words: TimedWord[]): TimedWord[][] {
  const chunks: TimedWord[][] = [];
  let current: TimedWord[] = [];
  for (const word of words) {
    if (current.length > 0) {
      const prev = current[current.length - 1];
      const gap = word.startSeconds - prev.endSeconds;
      const hardPause = gap > PAUSE_BREAK_SECONDS;
      const adaptivePause =
        gap >= ADAPTIVE_PAUSE_SECONDS &&
        (current.length >= SOFT_TARGET_WORDS || lineDurationSeconds(current) >= SOFT_TARGET_SECONDS);
      const sentenceBreak = current.length >= 2 && SENTENCE_END.test(prev.text);
      if (hardPause || adaptivePause || sentenceBreak) {
        chunks.push(current);
        current = [];
      }
    }
    current.push(word);
  }
  if (current.length > 0) chunks.push(current);
  return chunks;
}

/**
 * Phase 2 — hard caps: a chunk still over a cap splits at its largest
 * internal pause (pauses under SPLIT_PAUSE_SECONDS don't count; ties
 * go to the pause closest to the chunk's middle), or at the midpoint
 * word when the chunk has no usable pause. Recurses until every piece
 * fits (or is a single word).
 */
function splitChunkToCaps(words: TimedWord[]): TimedWord[][] {
  if (lineFitsCaps(words)) return [words];
  let boundary = -1;
  let bestGap = 0;
  for (let i = 1; i < words.length; i += 1) {
    const gap = words[i].startSeconds - words[i - 1].endSeconds;
    if (gap < SPLIT_PAUSE_SECONDS) continue;
    const closerToMiddle =
      boundary === -1 || Math.abs(i - words.length / 2) < Math.abs(boundary - words.length / 2);
    if (gap > bestGap || (gap === bestGap && closerToMiddle)) {
      boundary = i;
      bestGap = gap;
    }
  }
  if (boundary === -1) boundary = Math.ceil(words.length / 2);
  return [...splitChunkToCaps(words.slice(0, boundary)), ...splitChunkToCaps(words.slice(boundary))];
}

/**
 * Phase 3 — stranded-word rescue, per segment (segment boundaries are
 * absolute): a one-word line merges into its closer neighbour when
 * the join is tight (gap ≤ PAUSE_BREAK_SECONDS), the join wasn't a
 * sentence break, and the merged line stays under the hard caps.
 * Repeats — one merge can un-strand the next line.
 */
function rescueStrandedLines(chunks: TimedWord[][]): TimedWord[][] {
  const out = chunks.map((c) => [...c]);
  let merged = true;
  while (merged) {
    merged = false;
    for (let i = 0; i < out.length; i += 1) {
      if (out[i].length !== 1) continue;
      const word = out[i][0];
      const prev = i > 0 ? out[i - 1] : null;
      const next = i < out.length - 1 ? out[i + 1] : null;
      const backGap = prev ? word.startSeconds - prev[prev.length - 1].endSeconds : null;
      const fwdGap = next ? next[0].startSeconds - word.endSeconds : null;
      const canBack =
        prev !== null &&
        backGap !== null &&
        backGap <= PAUSE_BREAK_SECONDS &&
        !SENTENCE_END.test(prev[prev.length - 1].text) &&
        lineFitsCaps([...prev, word]);
      const canFwd =
        next !== null &&
        fwdGap !== null &&
        fwdGap <= PAUSE_BREAK_SECONDS &&
        !SENTENCE_END.test(word.text) &&
        lineFitsCaps([word, ...next]);
      if (!canBack && !canFwd) continue;
      const goBack = canBack && (!canFwd || (backGap as number) <= (fwdGap as number));
      if (goBack && prev) {
        out.splice(i - 1, 2, [...prev, word]);
      } else if (next) {
        out.splice(i, 2, [word, ...next]);
      }
      merged = true;
      break; // rescan from the top after each merge
    }
  }
  return out;
}

// ---- Detection cleanup --------------------------------------------------

/** Whisper bracket tokens — [_BEG_], [_TT_500], …: the special /
 *  timestamp marker family. The native engine filters these tokens
 *  out before assembly; the JS side strips them again so segments
 *  from any source — and lyrics saved before the native filter
 *  existed — come out clean. */
const WHISPER_BRACKET_TOKEN = /\[_[^\]]*\]/g;

/** Remove every whisper bracket token from a text fragment. */
export function stripWhisperBracketTokens(text: string): string {
  return text.replace(WHISPER_BRACKET_TOKEN, '');
}

/** Profanity respelling (Jaizon, 2026-11-11): detected lyrics get
 * the clean-version spellings he asked for — niggas → ngas,
 * fuck → f, bitch → bih, shit → shi — with their common
 * inflections folded to the same roots. Matches are whole words
 * with an explicit inflection list, so lookalike words (shitake,
 * class) are never touched. The replacement takes the matched
 * word's casing: Niggas → Ngas, FUCK → F. */
const LYRIC_PROFANITY_RULES: { pattern: RegExp; replacement: string }[] = [
  // The tail guard is a letter lookahead, not \b: after a consumed
  // apostrophe ("fuckin'") a \b can never match, which would leave
  // the apostrophe stranded on the replacement.
  { pattern: /\bniggas(?![a-z])|\bniggaz(?![a-z])/gi, replacement: 'ngas' },
  { pattern: /\bnigga(?![a-z])/gi, replacement: 'nga' },
  { pattern: /\bfuck(?:s|ed|ing|in'?|er|ers)?(?![a-z])/gi, replacement: 'f' },
  { pattern: /\bbitch(?:es|y)?(?![a-z])/gi, replacement: 'bih' },
  { pattern: /\bshit(?:s|ty|ted|ting|tin'?)?(?![a-z])/gi, replacement: 'shi' },
];

function matchProfanityCase(source: string, replacement: string): string {
  if (source.length > 1 && source === source.toUpperCase()) {
    return replacement.toUpperCase();
  }
  if (source.charAt(0) === source.charAt(0).toUpperCase()) {
    return replacement.charAt(0).toUpperCase() + replacement.slice(1);
  }
  return replacement;
}

/** Respell the profanity in a lyric fragment to Jaizon's clean
 * versions. Applied wherever lyric text is cleaned (detection,
 * stored-lyrics hydration) and wherever a line's text is committed
 * (editor edits, split/merge, added lines), so preview and export
 * always show the clean spellings. */
export function respellLyricProfanity(text: string): string {
  let out = text;
  for (const rule of LYRIC_PROFANITY_RULES) {
    out = out.replace(rule.pattern, (matched) => matchProfanityCase(matched, rule.replacement));
  }
  return out;
}

/** Bracket-strip + profanity-respell + whitespace-normalise a word
 * or line text. */
function cleanLyricText(text: string): string {
  return respellLyricProfanity(stripWhisperBracketTokens(text)).replace(/\s+/g, ' ').trim();
}

/** Dedup key: case, punctuation and spacing don't make a line a
 *  different line. */
function normalizeLineTextForDedup(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]+/gu, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Clean detected (or previously saved) lyric lines:
 * - bracket tokens are stripped from every word and every line
 *   text; words that become empty drop out, and a timed line's text
 *   is rebuilt from its kept words;
 * - lines whose text is empty after cleaning disappear entirely
 *   (a [_BEG_]-only line is the canonical case);
 * - CONSECUTIVE duplicate lines (same normalized text) collapse to
 *   the first occurrence — back-to-back repeats in a row are the
 *   delay/echo artefacts detection produces (Jaizon's ruling),
 *   while a repeat that returns later (a chorus) is real and KEPT.
 * Lines that need no change keep their object identity, so callers
 * can tell whether anything was cleaned.
 */
export function cleanDetectedLyrics(lines: LyricLine[]): LyricLine[] {
  const cleaned: LyricLine[] = [];
  for (const line of lines) {
    let next: LyricLine;
    if (line.words && line.words.length > 0) {
      let changed = false;
      const words: LyricWord[] = [];
      for (const word of line.words) {
        const text = cleanLyricText(word.text);
        if (text.length === 0) {
          changed = true;
          continue;
        }
        if (text !== word.text) changed = true;
        words.push(text === word.text ? word : { ...word, text });
      }
      const text = words.map((w) => w.text).join(' ');
      if (text.length === 0) continue;
      if (text !== line.text) changed = true;
      next = changed ? { ...line, text, words } : line;
    } else {
      const text = cleanLyricText(line.text);
      if (text.length === 0) continue;
      next = text === line.text ? line : { ...line, text };
    }
    const prev = cleaned[cleaned.length - 1];
    if (prev && normalizeLineTextForDedup(prev.text) === normalizeLineTextForDedup(next.text)) {
      continue; // consecutive echo repeat — the first occurrence wins
    }
    cleaned.push(next);
  }
  return cleaned;
}

function lineFromWords(words: TimedWord[], fps: number): LyricLine {
  const startFrame = secondsToFrames(words[0].startSeconds, fps);
  const endFrame = Math.max(secondsToFrames(words[words.length - 1].endSeconds, fps), startFrame + 1);
  const timed: LyricWord[] = words.map((w, i) => {
    const wStart = secondsToFrames(w.startSeconds, fps);
    // Every word spans at least one frame; the last word ends the line.
    const wEnd = i === words.length - 1 ? endFrame : Math.max(secondsToFrames(w.endSeconds, fps), wStart + 1);
    return { text: w.text, startFrame: wStart, endFrame: wEnd };
  });
  return { id: newLyricLineId(), text: lineText(words), startFrame, endFrame, words: timed };
}

/**
 * Group Whisper segments into lyric lines. A new segment always
 * starts a new line; inside a segment the three phases above decide
 * the lines (natural breaks → cap splits → stranded-word rescue).
 * Seconds → frames rounds (Math.round) via the shared converters.
 * A segment without word timings becomes one line with no words.
 */
export function groupWhisperSegments(segments: WhisperSegment[], fps: number): LyricLine[] {
  const lines: LyricLine[] = [];
  const ordered = [...segments].sort((a, b) => a.startSeconds - b.startSeconds);
  for (const segment of ordered) {
    // Sanitize at import: bracket tokens are stripped from every
    // word (and the segment text below) and emptied words drop out
    // before grouping, so junk can never form a line of its own.
    const words = (segment.words ?? [])
      .map((w) => ({ text: cleanLyricText(w.text), startSeconds: w.startSeconds, endSeconds: w.endSeconds }))
      .filter((w) => w.text.length > 0)
      .sort((a, b) => a.startSeconds - b.startSeconds);
    if (words.length === 0) {
      const text = cleanLyricText(segment.text);
      if (text.length > 0) {
        const startFrame = secondsToFrames(segment.startSeconds, fps);
        lines.push({
          id: newLyricLineId(),
          text,
          startFrame,
          endFrame: Math.max(secondsToFrames(segment.endSeconds, fps), startFrame + 1),
        });
      }
      continue;
    }
    const chunks = rescueStrandedLines(chunkSegmentWords(words).flatMap(splitChunkToCaps));
    for (const chunk of chunks) lines.push(lineFromWords(chunk, fps));
  }
  // Final pass: drop anything that cleaned to empty and collapse
  // back-to-back echo repeats across segment boundaries.
  return cleanDetectedLyrics(sortLyricLines(lines));
}

// ---- Song ↔ timeline frame mapping -----------------------------------

export function songFrameToTimelineFrame(songFrame: number, regionStartFrame: number): number {
  return songFrame - regionStartFrame;
}

export function timelineFrameToSongFrame(timelineFrame: number, regionStartFrame: number): number {
  return timelineFrame + regionStartFrame;
}

/** Index of the line containing `songFrame` ([start, end)), or -1. */
export function lineIndexAtSongFrame(lines: LyricLine[], songFrame: number): number {
  for (let i = 0; i < lines.length; i += 1) {
    if (songFrame >= lines[i].startFrame && songFrame < lines[i].endFrame) return i;
  }
  return -1;
}

export function lineAtSongFrame(lines: LyricLine[], songFrame: number): LyricLine | null {
  const index = lineIndexAtSongFrame(lines, songFrame);
  return index >= 0 ? lines[index] : null;
}

// ---- Line editing ------------------------------------------------------

/**
 * THE text-edit rule (exactly): when a line's text is edited and the
 * new text has the SAME number of words as the line's timed words,
 * each new word inherits the old word's timing (timings are kept,
 * redistributed word-for-word). When the counts differ — or the line
 * had no timed words — the word timings are dropped and word-level
 * animations fall back to line-level for that line.
 */
export function retimeLineWordsForText(line: LyricLine, newText: string): LyricLine {
  const tokens = newText.trim().split(/\s+/).filter(Boolean);
  if (!line.words || tokens.length === 0 || tokens.length !== line.words.length) {
    return { ...line, text: newText, words: undefined };
  }
  return {
    ...line,
    text: newText,
    words: line.words.map((word, i) => ({ ...word, text: tokens[i] })),
  };
}

/**
 * Split a line at a word boundary: `wordIndex` is the first word of
 * the SECOND line. With timed words the split lands on that word's
 * start; without them, the text splits at the same token index and
 * the time split is proportional to the character position. Returns
 * null when the index can't produce two non-empty lines.
 */
export function splitLineAtWord(line: LyricLine, wordIndex: number): [LyricLine, LyricLine] | null {
  if (line.words && line.words.length >= 2) {
    if (wordIndex < 1 || wordIndex > line.words.length - 1) return null;
    const firstWords = line.words.slice(0, wordIndex);
    const secondWords = line.words.slice(wordIndex);
    const splitFrame = secondWords[0].startFrame;
    if (splitFrame <= line.startFrame || splitFrame >= line.endFrame) return null;
    return [
      { ...line, text: firstWords.map((w) => w.text).join(' '), endFrame: splitFrame, words: firstWords },
      {
        id: newLyricLineId(),
        text: secondWords.map((w) => w.text).join(' '),
        startFrame: splitFrame,
        endFrame: line.endFrame,
        words: secondWords,
      },
    ];
  }
  const tokens = line.text.trim().split(/\s+/).filter(Boolean);
  if (tokens.length < 2 || wordIndex < 1 || wordIndex > tokens.length - 1) return null;
  const firstText = tokens.slice(0, wordIndex).join(' ');
  const secondText = tokens.slice(wordIndex).join(' ');
  const fraction = firstText.length / Math.max(1, line.text.trim().length);
  const splitFrame = Math.round(line.startFrame + (line.endFrame - line.startFrame) * fraction);
  if (splitFrame <= line.startFrame || splitFrame >= line.endFrame) return null;
  return [
    { ...line, text: firstText, endFrame: splitFrame, words: undefined },
    { id: newLyricLineId(), text: secondText, startFrame: splitFrame, endFrame: line.endFrame, words: undefined },
  ];
}

/** Merge two lines (a first) into one, keeping a's id. Words survive
 *  only when BOTH lines carry them. */
export function mergeLyricLines(a: LyricLine, b: LyricLine): LyricLine {
  return {
    id: a.id,
    text: [a.text.trim(), b.text.trim()].filter(Boolean).join(' '),
    startFrame: Math.min(a.startFrame, b.startFrame),
    endFrame: Math.max(a.endFrame, b.endFrame),
    words: a.words && b.words ? [...a.words, ...b.words] : undefined,
  };
}

/** Shift every line (and its words) by `deltaFrames`, clamped so no
 *  line starts before song frame 0 (durations preserved). */
export function shiftLyricLines(lines: LyricLine[], deltaFrames: number): LyricLine[] {
  if (deltaFrames === 0) return lines;
  return lines.map((line) => {
    const applied = Math.max(deltaFrames, -line.startFrame);
    if (applied === 0) return line;
    return {
      ...line,
      startFrame: line.startFrame + applied,
      endFrame: line.endFrame + applied,
      words: line.words?.map((w) => ({
        ...w,
        startFrame: w.startFrame + applied,
        endFrame: w.endFrame + applied,
      })),
    };
  });
}

// ---- Composite payload -------------------------------------------------

/** Resolve a project lyric style for the native boundary: the font
 *  becomes a PostScript name (the real bold face when bold + known),
 *  the animation id becomes its parameter set. */
export function resolveLyricStyle(style: LyricStyle): ResolvedLyricStyle {
  const font = lyricFontById(style.fontId);
  return {
    fontPostScriptName: style.bold && font.boldPostScriptName ? font.boldPostScriptName : font.postScriptName,
    sizeRatio: style.sizeRatio,
    color: style.color,
    strokeColor: style.strokeColor,
    strokeWidthRatio: style.strokeWidthRatio,
    background: style.background,
    backgroundColor: style.backgroundColor,
    position: style.position,
    verticalOffsetRatio: style.verticalOffsetRatio ?? 0,
    maxWidthRatio: style.maxWidthRatio ?? 0.88,
    bold: style.bold,
    animation: resolveAnimationParams(style.animationId),
  };
}

/**
 * Build the CompositeRequest lyrics payload: lines mapped from song
 * frames to COMPOSITION seconds (region start subtracted), clamped
 * to the composition — lines ending before it are dropped, lines
 * straddling its start are clamped (their words clamped into the
 * visible window). Null when nothing is visible.
 */
export function buildCompositeLyrics(
  lyrics: ProjectLyrics | null | undefined,
  regionStartFrame: number,
  fps: number,
): CompositeLyrics | null {
  if (!lyrics || lyrics.lines.length === 0) return null;
  // The panel's fine-offset drag bar: a global shift applied here,
  // at the one boundary every renderer (preview overlay + export
  // burn-in) reads, so the authored line timings never change.
  const offset = Math.round(lyrics.offsetFrames ?? 0);
  const out: CompositeLyricLine[] = [];
  for (const line of sortLyricLines(lyrics.lines)) {
    const startTl = songFrameToTimelineFrame(line.startFrame, regionStartFrame) + offset;
    const endTl = songFrameToTimelineFrame(line.endFrame, regionStartFrame) + offset;
    if (endTl <= 0 || endTl <= startTl) continue;
    const clampedStart = Math.max(0, startTl);
    const words = line.words
      ?.map((w) => {
        const wStart = Math.max(clampedStart, songFrameToTimelineFrame(w.startFrame, regionStartFrame) + offset);
        const wEnd = Math.min(endTl, songFrameToTimelineFrame(w.endFrame, regionStartFrame) + offset);
        if (wEnd <= wStart) return null;
        return {
          text: w.text,
          startSeconds: framesToSeconds(wStart, fps),
          endSeconds: framesToSeconds(wEnd, fps),
        };
      })
      .filter((w): w is NonNullable<typeof w> => w !== null);
    out.push({
      text: line.text,
      startSeconds: framesToSeconds(clampedStart, fps),
      endSeconds: framesToSeconds(endTl, fps),
      ...(words && words.length > 0 ? { words } : {}),
    });
  }
  if (out.length === 0) return null;
  return { lines: out, style: resolveLyricStyle(lyrics.style) };
}
