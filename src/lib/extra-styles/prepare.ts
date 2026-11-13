/**
 * Extra Styles 2.0 — scene preparation (Phase 3).
 *
 * The ONE place that turns a project (or a card) into a prepared
 * native scene handle. Editor preview, Export, and the catalog
 * cards all come through here, so a scene is prepared the same
 * way everywhere — and so a preparation failure has exactly one
 * honest outcome: null (render without a scene), never a throw,
 * never a stall.
 *
 * Project scenes need the REAL inputs: the project's lyric lines
 * (song-frame timed), the interpretation artifact, audio
 * automation (only when the style's metadata asks for it), and
 * subject masks (only when asked for, from the cut's first take).
 * When a required input cannot be produced, preparation fails
 * outright — a style that needs automation cannot render
 * non-reactively, and a half-built scene would be a lie.
 *
 * Card scenes use the fixed sample data (sample.ts): the same
 * three lines, synthetic automation, and a synthetic mask index
 * for every style, so cards are comparable and deterministic.
 *
 * Not pure (calls the bridge) — not in the Node test compile.
 */

import {
  fetchExtraStyleCatalog,
  prepareAudioAutomation,
  prepareExtraStyleScene,
  prepareSubjectMasks,
} from './bridge';
import type { ExtraStyleCatalog, ExtraStyleMetadata, ExtraStyleParamValue, ExtraStyleState } from './types';
import { buildLyricInterpretation } from './interpretation';
import { resolveExtraStyleParams } from './params';
import { buildExtraStyleSceneInput, type SceneInputLine } from './scene';
import {
  buildSyntheticAutomation,
  buildSyntheticMaskIndex,
  CARD_PREVIEW_DURATION_FRAMES,
  CARD_PREVIEW_HEIGHT,
  CARD_PREVIEW_WIDTH,
  SAMPLE_CARD_LINES,
} from './sample';

/** The catalog, once per launch (the bridge is never asked twice
 *  for the same launch). Null in Expo Go / on an old build. */
let catalogPromise: Promise<ExtraStyleCatalog | null> | null = null;

export function getCachedExtraStyleCatalog(): Promise<ExtraStyleCatalog | null> {
  if (!catalogPromise) catalogPromise = fetchExtraStyleCatalog();
  return catalogPromise;
}

export interface PrepareProjectSceneArgs {
  metadata: ExtraStyleMetadata;
  state: ExtraStyleState;
  projectId: string;
  /** The project's lyric lines (song-frame timed, with decor). */
  lines: SceneInputLine[];
  /** The lyrics fine-offset drag-bar value (frames, ±45). */
  offsetFrames: number;
  /** Where the used song region starts, in song frames. */
  regionStartFrame: number;
  canvasWidth: number;
  canvasHeight: number;
  /** Composition length, @30fps integer frames. */
  durationFrames: number;
  /** The song file URI (automation identity + interpretation key). */
  songUri: string;
  /** The cut's first take URI (mask precompute input). */
  firstTakeUri: string | null | undefined;
}

/**
 * Prepare the scene for a project's chosen style. Resolves to
 * the scene handle, or null when there is no style to prepare,
 * the engine is unavailable, a required input could not be
 * produced, or the native build failed. Never throws.
 */
export async function prepareProjectExtraStyleScene(
  args: PrepareProjectSceneArgs,
): Promise<string | null> {
  const { metadata, state } = args;
  if (!state.styleId) return null;
  try {
    let automationJson: string | null = null;
    if (metadata.needsAudioAutomation) {
      const automation = await prepareAudioAutomation(args.songUri);
      // A style that needs automation cannot render without it.
      if (!automation) return null;
      automationJson = JSON.stringify(automation);
    }
    let maskRefJson: string | null = null;
    if (metadata.needsSubjectMasks) {
      if (!args.firstTakeUri) return null;
      const maskIndex = await prepareSubjectMasks(args.firstTakeUri);
      if (!maskIndex) return null;
      maskRefJson = JSON.stringify(maskIndex);
    }
    const interpretation = buildLyricInterpretation(args.lines, args.songUri);
    const input = buildExtraStyleSceneInput({
      styleId: metadata.id,
      projectId: args.projectId,
      paramsJson: JSON.stringify(
        resolveExtraStyleParams(metadata.parameters, state.params).params,
      ),
      ...(state.layers ? { layersJson: JSON.stringify(state.layers) } : {}),
      lines: args.lines,
      offsetFrames: args.offsetFrames,
      regionStartFrame: args.regionStartFrame,
      canvasWidth: args.canvasWidth,
      canvasHeight: args.canvasHeight,
      durationFrames: args.durationFrames,
      interpretation,
      ...(automationJson ? { automationJson } : {}),
      ...(maskRefJson ? { maskRefJson } : {}),
    });
    return await prepareExtraStyleScene(input);
  } catch {
    return null;
  }
}

/**
 * Prepare the scene for a catalog card: the style at the given
 * parameters (schema defaults when omitted) over the sample
 * lines, with synthetic automation AND a synthetic mask index
 * always supplied — audio and subject styles animate on the
 * card, and styles that don't need those inputs ignore them.
 * Resolves to the handle, or null. Never throws.
 */
export async function prepareCardPreviewScene(
  metadata: ExtraStyleMetadata,
  params?: Record<string, ExtraStyleParamValue>,
): Promise<string | null> {
  try {
    const input = buildExtraStyleSceneInput({
      styleId: metadata.id,
      projectId: 'extra-styles-sample',
      paramsJson: JSON.stringify(
        resolveExtraStyleParams(metadata.parameters, params ?? {}).params,
      ),
      lines: SAMPLE_CARD_LINES,
      regionStartFrame: 0,
      canvasWidth: CARD_PREVIEW_WIDTH,
      canvasHeight: CARD_PREVIEW_HEIGHT,
      durationFrames: CARD_PREVIEW_DURATION_FRAMES,
      automationJson: JSON.stringify(buildSyntheticAutomation()),
      maskRefJson: JSON.stringify(buildSyntheticMaskIndex()),
    });
    return await prepareExtraStyleScene(input);
  } catch {
    return null;
  }
}
