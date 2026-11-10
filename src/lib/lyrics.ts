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

/** Grouping rules (Whisper output → singable lines). */
export const MAX_WORDS_PER_LINE = 7;
export const PAUSE_BREAK_SECONDS = 0.7;

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

/**
 * Group Whisper segments into lyric lines:
 * - a new segment always starts a new line;
 * - a pause of more than PAUSE_BREAK_SECONDS between words breaks;
 * - a line holds at most MAX_WORDS_PER_LINE words.
 * Seconds → frames rounds (Math.round) via the shared converters.
 * A segment without word timings becomes one line with no words.
 */
export function groupWhisperSegments(segments: WhisperSegment[], fps: number): LyricLine[] {
  const lines: LyricLine[] = [];
  let pending: { text: string; startSeconds: number; endSeconds: number }[] = [];

  const flush = () => {
    if (pending.length === 0) return;
    const startFrame = secondsToFrames(pending[0].startSeconds, fps);
    const endFrame = Math.max(secondsToFrames(pending[pending.length - 1].endSeconds, fps), startFrame + 1);
    const words: LyricWord[] = pending.map((w, i) => {
      const wStart = secondsToFrames(w.startSeconds, fps);
      // Every word spans at least one frame; the last word ends the line.
      const wEnd = i === pending.length - 1 ? endFrame : Math.max(secondsToFrames(w.endSeconds, fps), wStart + 1);
      return { text: w.text, startFrame: wStart, endFrame: wEnd };
    });
    lines.push({
      id: newLyricLineId(),
      text: words.map((w) => w.text).join(' '),
      startFrame,
      endFrame,
      words,
    });
    pending = [];
  };

  const ordered = [...segments].sort((a, b) => a.startSeconds - b.startSeconds);
  for (const segment of ordered) {
    flush(); // segment boundary always breaks the line
    const words = (segment.words ?? [])
      .map((w) => ({ text: w.text.trim(), startSeconds: w.startSeconds, endSeconds: w.endSeconds }))
      .filter((w) => w.text.length > 0)
      .sort((a, b) => a.startSeconds - b.startSeconds);
    if (words.length === 0) {
      const text = segment.text.trim();
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
    let previousEnd: number | null = null;
    for (const word of words) {
      if (pending.length > 0) {
        const pauseBreak = previousEnd !== null && word.startSeconds - previousEnd > PAUSE_BREAK_SECONDS;
        if (pauseBreak || pending.length >= MAX_WORDS_PER_LINE) flush();
      }
      pending.push(word);
      previousEnd = word.endSeconds;
    }
    flush(); // end of segment: the next segment starts a fresh line
  }
  flush();
  return sortLyricLines(lines);
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
  const out: CompositeLyricLine[] = [];
  for (const line of sortLyricLines(lyrics.lines)) {
    const startTl = songFrameToTimelineFrame(line.startFrame, regionStartFrame);
    const endTl = songFrameToTimelineFrame(line.endFrame, regionStartFrame);
    if (endTl <= 0 || endTl <= startTl) continue;
    const clampedStart = Math.max(0, startTl);
    const words = line.words
      ?.map((w) => {
        const wStart = Math.max(clampedStart, songFrameToTimelineFrame(w.startFrame, regionStartFrame));
        const wEnd = Math.min(endTl, songFrameToTimelineFrame(w.endFrame, regionStartFrame));
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
