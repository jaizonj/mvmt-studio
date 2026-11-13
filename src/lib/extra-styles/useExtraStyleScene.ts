/**
 * Extra Styles 2.0 — the project scene hook (Phase 3).
 *
 * One hook, used by the Editor preview AND the Export screen, so
 * both prepare the project's 2.0 scene the same way and both see
 * the same preparation state:
 *
 *  - No style selected (or the favorites-only shell) → 'none',
 *    handle null. The composition renders exactly as before.
 *  - Style selected → 'preparing' while the native scene builds,
 *    then 'ready' with the handle, or 'failed' when the scene
 *    could not be built (engine unavailable, a required input
 *    missing, native failure). 'failed' renders WITHOUT the scene
 *    — never a stall, never a crash.
 *  - Param change → the cheap path is the NATIVE one: the hook
 *    always calls `updateExtraStyleParams` on the live handle, and
 *    the native side decides (docs §8.2) — structural params
 *    rebuild the scene in place, everything else swaps values.
 *    Either way the HANDLE stays the same, so the preview key
 *    (built from the request, which carries the handle) never
 *    changes on a param edit and playback never restarts. A style
 *    switch, lyric edit, song/region/canvas change, or layer
 *    change re-prepares and the handle changes, which restarts the
 *    preview — correctly, because the picture changed.
 *  - `awaitReady` lets Export wait for an in-flight preparation
 *    before rendering, instead of racing it.
 *
 * The old handle is released only AFTER its replacement lands,
 * so a playing preview never loses its scene mid-frame. Handles
 * are released on unmount.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';

import { edlWithTakeCanvas } from '../edl';
import { lyricsHash } from './interpretation';
import { getCachedExtraStyleCatalog, prepareProjectExtraStyleScene } from './prepare';
import { releaseExtraStyleScene, updateExtraStyleParams } from './bridge';
import type { ExtraStyleCatalog, ExtraStyleMetadata } from './types';
import type { SceneInputLine } from './scene';
import type { Edl } from '../edl';
import type { Project } from '../../types';

export type ExtraStyleSceneStatus = 'none' | 'preparing' | 'ready' | 'failed';

export interface ExtraStyleScene {
  status: ExtraStyleSceneStatus;
  /** The native scene handle for the composition request (null when none). */
  handle: string | null;
  /** Display name of the active style (null when none). */
  styleName: string | null;
  /** The active style's metadata (null when none / catalog unavailable). */
  metadata: ExtraStyleMetadata | null;
  /**
   * Wait for an in-flight preparation and resolve with its
   * handle (or null when there is none / it failed). Already
   * resolved when nothing is preparing — Export calls this
   * before rendering so a tap during preparation waits for the
   * scene instead of racing it.
   */
  awaitReady: () => Promise<string | null>;
}

function lyricLinesToSceneInput(project: Project): SceneInputLine[] {
  return (project.lyrics?.lines ?? []).map((line) => ({
    id: line.id,
    text: line.text,
    startFrame: line.startFrame,
    endFrame: line.endFrame,
    ...(line.words
      ? {
          words: line.words.map((w) => ({
            text: w.text,
            startFrame: w.startFrame,
            endFrame: w.endFrame,
          })),
        }
      : {}),
    ...(line.decor
      ? {
          decor: {
            ...(line.decor.emoji ? { emoji: line.decor.emoji } : {}),
            ...(line.decor.tone ? { tone: line.decor.tone } : {}),
            ...(line.decor.emphasisWordIndices ? { emphasisWordIndices: [...line.decor.emphasisWordIndices] } : {}),
          },
        }
      : {}),
  }));
}

export function useExtraStyleScene(args: {
  project: Project | null;
  edl: Edl | null;
  takeUriById: (takeId: string) => string | undefined;
}): ExtraStyleScene {
  const { project, edl, takeUriById } = args;
  const [catalog, setCatalog] = useState<ExtraStyleCatalog | null>(null);
  const [status, setStatus] = useState<ExtraStyleSceneStatus>('none');
  const [handle, setHandle] = useState<string | null>(null);
  const handleRef = useRef<string | null>(null);
  const readyPromiseRef = useRef<Promise<string | null>>(Promise.resolve(null));

  useEffect(() => {
    let alive = true;
    void getCachedExtraStyleCatalog().then((fetched) => {
      if (alive) setCatalog(fetched);
    });
    return () => {
      alive = false;
    };
  }, []);

  const state = project?.extraStyle ?? null;
  const styleId = state?.styleId ?? '';
  const metadata = useMemo(
    () => (styleId ? catalog?.styles.find((s) => s.id === styleId && !s.internal) ?? null : null),
    [catalog, styleId],
  );

  // The scene key: everything a rebuild depends on. Lyrics are
  // hashed (an edit rebuilds). Params are deliberately NOT in the
  // key — a param change goes through updateExtraStyleParams,
  // which rebuilds in place natively when the schema says so and
  // keeps the handle either way (see the header note).
  const effectiveEdl = useMemo(
    () => (edl && project ? edlWithTakeCanvas(edl, project.takes) : null),
    [edl, project],
  );
  const sceneKey = useMemo(() => {
    if (!project || !effectiveEdl || !metadata || !state) return '';
    const lines = lyricLinesToSceneInput(project);
    return JSON.stringify([
      metadata.id,
      metadata.version,
      state.styleId,
      state.styleVersion,
      lyricsHash(
        lines.map((l) => ({ id: l.id, text: l.text, startFrame: l.startFrame, endFrame: l.endFrame })),
      ),
      project.lyrics?.offsetFrames ?? 0,
      effectiveEdl.audio.regionStartFrame,
      effectiveEdl.audio.uri,
      effectiveEdl.totalFrames,
      effectiveEdl.canvas.width,
      effectiveEdl.canvas.height,
      effectiveEdl.segments[0]?.takeId ?? '',
      state.layers ?? null,
    ]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [project, effectiveEdl, metadata, state?.styleId, state?.styleVersion, state?.layers]);

  // A scene needs a song: lyrics and automation both key off it.
  // When there is no scene to prepare, reset the mirrored state
  // during render — the effect below owns the external handle
  // release. This is the render-time adjustment React endorses
  // instead of setting state synchronously in an effect.
  const songUri = effectiveEdl?.audio.uri ?? null;
  const noScene = !project || !effectiveEdl || !metadata || !state || sceneKey === '' || !songUri;
  if (noScene && (handle !== null || status !== 'none')) {
    setHandle(null);
    setStatus('none');
  }

  const lastKeyRef = useRef('');
  const lastParamsRef = useRef<Record<string, unknown> | null>(null);

  // Release a handle exactly once.
  const release = useCallback((h: string | null) => {
    if (!h) return;
    void releaseExtraStyleScene(h);
  }, []);

  useEffect(() => {
    // No scene to prepare: release the live handle (the external
    // side) and reset the refs. The mirrored handle/status state
    // is reset during render above, not here.
    if (noScene) {
      if (handleRef.current) {
        release(handleRef.current);
        handleRef.current = null;
      }
      lastKeyRef.current = '';
      lastParamsRef.current = null;
      readyPromiseRef.current = Promise.resolve(null);
      return;
    }
    // Same scene key: only the PARAMS may have changed. The
    // native side decides rebuild-vs-swap and keeps the handle
    // either way — playback never restarts on a param edit.
    if (sceneKey === lastKeyRef.current && handleRef.current && lastParamsRef.current) {
      if (JSON.stringify(lastParamsRef.current) !== JSON.stringify(state.params)) {
        lastParamsRef.current = { ...state.params };
        void updateExtraStyleParams(handleRef.current, state.params);
      }
      return;
    }
    // (Re)build the scene.
    let alive = true;
    const preparation = (async () => {
      setStatus('preparing');
      const lines = lyricLinesToSceneInput(project);
      const firstTakeUri =
        effectiveEdl.segments.length > 0
          ? takeUriById(effectiveEdl.segments[0].takeId)
          : null;
      const next = await prepareProjectExtraStyleScene({
        metadata,
        state,
        projectId: project.id,
        lines,
        offsetFrames: project.lyrics?.offsetFrames ?? 0,
        regionStartFrame: effectiveEdl.audio.regionStartFrame,
        canvasWidth: effectiveEdl.canvas.width,
        canvasHeight: effectiveEdl.canvas.height,
        durationFrames: effectiveEdl.totalFrames,
        songUri,
        firstTakeUri: firstTakeUri ?? null,
      });
      if (!alive) {
        if (next) void releaseExtraStyleScene(next);
        return null;
      }
      const previous = handleRef.current;
      handleRef.current = next;
      lastKeyRef.current = sceneKey;
      lastParamsRef.current = { ...state.params };
      setHandle(next);
      setStatus(next ? 'ready' : 'failed');
      if (previous && previous !== next) release(previous);
      return next;
    })();
    readyPromiseRef.current = preparation;
    return () => {
      alive = false;
    };
    // takeUriById is stable per screen (useMemo'd); the key
    // carries everything the preparation reads.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [project, effectiveEdl, metadata, state, sceneKey]);

  // Unmount: release the live handle.
  useEffect(
    () => () => {
      if (handleRef.current) void releaseExtraStyleScene(handleRef.current);
      handleRef.current = null;
    },
    [],
  );

  const awaitReady = useCallback(() => readyPromiseRef.current, []);

  return {
    status,
    handle,
    styleName: metadata?.name ?? null,
    metadata,
    awaitReady,
  };
}
