/**
 * Extra Styles 2.0 — scene-build input (Phase 2 core engine).
 *
 * Builds the ONE payload that crosses the bridge at preparation
 * (docs §3.2): resolved lyric lines + words in COMPOSITION frames,
 * stored intelligence, style params, canvas, seed. The Swift side
 * builds the scene graph from this; per-frame evaluation is
 * native-only, so this payload is built once, never per frame.
 *
 * THE EMOJI LESSON (Jaizon, 2026-11-13 ~01:26 MST): in the v1
 * Emoji Story template he NEVER saw a single emoji — the v1
 * payload carried the stored emoji only when a template was
 * active, and both renderers displayed it only for Emoji Story,
 * so the chain never delivered a visible emoji on his phone.
 * The 2.0 rule is the opposite: stored intelligence (emoji, tone,
 * emphasis) is copied into the scene input UNCONDITIONALLY —
 * whenever the line has it, whatever the style. There is no
 * activation gate anywhere on this path, and the test pins it: a
 * line with an emoji produces a payload line with that emoji.
 * The Emoji Storytelling demo (Phase 3) must prove the emoji
 * visible end-to-end (stored intelligence → scene → preview AND
 * export) before it counts as done.
 */

import type { ExtraStyleSceneBuildInput, ExtraStyleSceneLineInput, LyricInterpretation } from './types';
import { fnv1a32 } from './interpretation';

/** A lyric line as the app stores it (structural — mirrors
 *  LyricLine without importing the app's types, so this module
 *  stays independent of the editor's files). */
export interface SceneInputLine {
  id: string;
  text: string;
  /** Song-absolute frames @30fps. */
  startFrame: number;
  endFrame: number;
  words?: { text: string; startFrame: number; endFrame: number }[];
  decor?: {
    emoji?: string;
    tone?: 'joy' | 'sad' | 'anger' | 'love' | 'hype';
    emphasisWordIndices?: number[];
  };
}

export interface BuildSceneInputArgs {
  styleId: string;
  projectId: string;
  paramsJson: string;
  layersJson?: string | null;
  lines: SceneInputLine[];
  /** The fine-offset drag bar value (frames, ±45) — applied here,
   *  at the one boundary, like buildCompositeLyrics. */
  offsetFrames?: number;
  /** Where the used song region starts, in song frames. */
  regionStartFrame: number;
  canvasWidth: number;
  canvasHeight: number;
  /** Composition length, @30fps integer frames. */
  durationFrames: number;
  fps?: number;
  /** Lyric interpretation (sections + semantic tags), when computed. */
  interpretation?: LyricInterpretation | null;
  automationJson?: string | null;
  maskRefJson?: string | null;
}

/**
 * 32-bit seed for the scene (docs §5.4): FNV-1a of
 * (styleId + projectId) — stable across launches, previews, and
 * exports. Node ids / line ids are mixed in per node by the
 * evaluator, so one seed drives the whole scene's scatter.
 */
export function deriveExtraStyleSeed(styleId: string, projectId: string): number {
  return fnv1a32(`${styleId}|${projectId}`);
}

/**
 * Map song frames to composition frames (frame − regionStart +
 * offset), clamp to the composition, drop lines entirely outside
 * it. Words are mapped the same way; a word without timings is
 * dropped (the line still renders, word-level animation falls
 * back to line-level for it).
 *
 * Intelligence is copied through unconditionally — see the header
 * note. A line with an emoji ALWAYS produces a payload line with
 * that emoji.
 */
export function buildExtraStyleSceneInput(args: BuildSceneInputArgs): ExtraStyleSceneBuildInput {
  const fps = args.fps ?? 30;
  const offset = args.offsetFrames ?? 0;
  const tagsByLine = new Map<string, string[]>();
  for (const line of args.interpretation?.lines ?? []) {
    tagsByLine.set(line.lineId, line.semanticTags);
  }
  const toCompositionSeconds = (songFrame: number): number =>
    (songFrame - args.regionStartFrame + offset) / fps;
  const durationSeconds = args.durationFrames / fps;

  const lines: ExtraStyleSceneLineInput[] = [];
  for (const line of args.lines) {
    const startSeconds = toCompositionSeconds(line.startFrame);
    const endSeconds = toCompositionSeconds(line.endFrame);
    // Entirely outside the composition (before 0 or after the
    // end) → the style never sees it.
    if (endSeconds <= 0 || startSeconds >= durationSeconds) continue;
    const clampedStart = Math.max(0, startSeconds);
    const clampedEnd = Math.min(durationSeconds, endSeconds);
    if (clampedEnd - clampedStart <= 0) continue;
    const words = (line.words ?? [])
      .map((w) => ({
        text: w.text,
        startSeconds: Math.max(0, toCompositionSeconds(w.startFrame)),
        endSeconds: Math.min(durationSeconds, toCompositionSeconds(w.endFrame)),
      }))
      .filter((w) => w.endSeconds > w.startSeconds);
    const payload: ExtraStyleSceneLineInput = {
      text: line.text,
      startSeconds: clampedStart,
      endSeconds: clampedEnd,
      ...(words.length > 0 ? { words } : {}),
      // Stored intelligence — unconditional, no gate (see header).
      ...(line.decor?.emoji ? { emoji: line.decor.emoji } : {}),
      ...(line.decor?.tone ? { tone: line.decor.tone } : {}),
      ...(line.decor?.emphasisWordIndices && line.decor.emphasisWordIndices.length > 0
        ? { emphasisWordIndices: [...line.decor.emphasisWordIndices] }
        : {}),
      ...(tagsByLine.get(line.id)?.length
        ? { semanticTags: [...tagsByLine.get(line.id)!] }
        : {}),
    };
    lines.push(payload);
  }

  return {
    styleId: args.styleId,
    paramsJson: args.paramsJson,
    ...(args.layersJson ? { layersJson: args.layersJson } : {}),
    lines,
    seed: deriveExtraStyleSeed(args.styleId, args.projectId),
    canvasWidth: args.canvasWidth,
    canvasHeight: args.canvasHeight,
    durationFrames: args.durationFrames,
    fps,
    ...(args.automationJson ? { automationJson: args.automationJson } : {}),
    ...(args.maskRefJson ? { maskRefJson: args.maskRefJson } : {}),
  };
}
