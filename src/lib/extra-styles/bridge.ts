/**
 * Extra Styles 2.0 — bridge (Phase 2 core engine).
 *
 * Domain-typed wrappers over the native module's Extra Styles
 * surface (modules/mvmt-compositor/src/index.ts). Conventions
 * follow the module (availability gate, never reject where a
 * fallback exists, progress + cancellation by id for long work —
 * docs §6.6). Scene data crosses the bridge ONCE (at
 * preparation); per-frame evaluation is native-only.
 */

import {
  isCompositorAvailable,
  getExtraStyleCatalogJson,
  prepareExtraStyleSceneNative,
  updateExtraStyleParamsNative,
  prepareAudioAutomationNative,
  prepareSubjectMasksNative,
  renderExtraStylePreviewFrameNative,
  releaseExtraStyleSceneNative,
  getExtraStyleProfileJson,
  benchmarkExtraStyleNodesJson,
} from '../../../modules/mvmt-compositor/src/index';
import type { AudioAutomation, ExtraStyleCatalog, ExtraStyleSceneBuildInput, SubjectMaskIndex } from './types';
import { EXTRA_STYLES_BRIDGE_VERSION } from './types';

function parseCatalog(json: string | null): ExtraStyleCatalog | null {
  if (!json) return null;
  try {
    const parsed = JSON.parse(json) as ExtraStyleCatalog;
    if (!parsed || !Array.isArray(parsed.styles)) return null;
    return parsed;
  } catch {
    return null;
  }
}

/**
 * The style catalog (metadata only — docs §3.1), once per launch.
 * Null when the engine is unavailable (Expo Go) or the build is
 * older than the UI. The caller caches the result; the bridge is
 * never asked twice for the same launch.
 */
export async function fetchExtraStyleCatalog(): Promise<ExtraStyleCatalog | null> {
  if (!isCompositorAvailable()) return null;
  const json = await getExtraStyleCatalogJson();
  const catalog = parseCatalog(json);
  if (catalog && catalog.bridgeVersion > EXTRA_STYLES_BRIDGE_VERSION) return null;
  return catalog;
}

/**
 * Build a scene ahead of time (docs §6.6): style id + params +
 * lyric payload + automation/mask references in, a scene handle
 * out. This is where load time lives — honest progress belongs to
 * the caller. Null when the build failed (unknown style, bad
 * payload); the caller renders without a scene, never a failure.
 */
export async function prepareExtraStyleScene(
  input: ExtraStyleSceneBuildInput,
): Promise<string | null> {
  if (!isCompositorAvailable()) return null;
  return prepareExtraStyleSceneNative(input);
}

/**
 * Swap params in the compositor store without a rebuild (docs
 * §6.3). The composition is NOT rebuilt; playback does not
 * restart. Never rejects — a failed swap leaves the previous
 * params in place.
 */
export async function updateExtraStyleParams(
  handle: string,
  params: Record<string, unknown>,
): Promise<boolean> {
  if (!isCompositorAvailable()) return false;
  try {
    await updateExtraStyleParamsNative(handle, JSON.stringify(params));
    return true;
  } catch {
    return false;
  }
}

/** Audio automation for a song (docs §9.2): decoded once, cached
 *  per song, returned as the parsed artifact. Null when the
 *  analysis could not run — styles render non-reactively. */
export async function prepareAudioAutomation(uri: string): Promise<AudioAutomation | null> {
  if (!isCompositorAvailable()) return null;
  const json = await prepareAudioAutomationNative(uri);
  if (!json) return null;
  try {
    const parsed = JSON.parse(json) as AudioAutomation;
    if (!parsed || !Array.isArray(parsed.onsetEnvelope?.values)) return null;
    return parsed;
  } catch {
    return null;
  }
}

/** Subject masks for a take (docs §10.2): precomputed at 2 fps,
 *  cached per take. Null when unavailable — subject features hide
 *  with an honest note, never a failure. */
export async function prepareSubjectMasks(takeUri: string): Promise<SubjectMaskIndex | null> {
  if (!isCompositorAvailable()) return null;
  const json = await prepareSubjectMasksNative(takeUri);
  if (!json) return null;
  try {
    const parsed = JSON.parse(json) as SubjectMaskIndex;
    if (!parsed || !Array.isArray(parsed.maskUris)) return null;
    return parsed;
  } catch {
    return null;
  }
}

/**
 * Render one frame of a prepared scene for a card preview (docs
 * §12.2): the scene over a black frame at the requested size.
 * Resolves to the PNG file URI, or null. The caller caches the
 * frame on disk; the sample-clip variant lands in Phase 3.
 */
export async function renderExtraStylePreviewFrame(
  handle: string,
  frame: number,
  width: number,
  height: number,
): Promise<string | null> {
  if (!isCompositorAvailable()) return null;
  return renderExtraStylePreviewFrameNative(handle, frame, width, height);
}

/** Free a prepared scene + its caches (docs §6.6). */
export async function releaseExtraStyleScene(handle: string): Promise<void> {
  if (!isCompositorAvailable()) return;
  await releaseExtraStyleSceneNative(handle);
}

/** Render-time profiler log (docs §13.1): ms/frame per style. */
export async function fetchExtraStyleProfile(): Promise<Record<string, unknown> | null> {
  if (!isCompositorAvailable()) return null;
  const json = await getExtraStyleProfileJson();
  if (!json) return null;
  try {
    return JSON.parse(json) as Record<string, unknown>;
  } catch {
    return null;
  }
}

/** The Metal spike benchmark (docs §6.5): CI vs Metal frame times
 *  for the particle field + distortion wave. Device numbers only —
 *  on a build without Metal it returns the CI baseline + a note. */
export async function runExtraStyleMetalBenchmark(): Promise<Record<string, unknown> | null> {
  if (!isCompositorAvailable()) return null;
  const json = await benchmarkExtraStyleNodesJson();
  if (!json) return null;
  try {
    return JSON.parse(json) as Record<string, unknown>;
  } catch {
    return null;
  }
}
