import type { CameraType, VideoQuality } from 'expo-camera';
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';

import type { Edl } from '../lib/edl';
import { loadProjects, saveProjects } from '../lib/persistence';
import type {
  AudioRegion,
  AudioTrack,
  CountInBeats,
  CountdownSeconds,
  ExportQualityPref,
  FrameRatePref,
  MusicalSection,
  Project,
  ShuffleFrequency,
  ShuffleResultInfo,
  Take,
  TimelineClip,
} from '../types';

/**
 * Studio store — Overhaul Wave 2 (lead).
 *
 * PROJECTS are now the unit of work: creative state (track, region,
 * takes, the canonical EDL, shuffle state) lives inside the ACTIVE
 * project and is persisted to disk (src/lib/persistence.ts) — before
 * this, everything was useState-only and a restart lost the whole
 * studio (QA audit F-2). Camera/settings preferences stay global.
 *
 * The flat accessors (track, takes, …) are preserved so existing
 * screens keep working during the redesign wave: they read/write the
 * active project. The legacy seconds-based `timeline` is TRANSITIONAL
 * (in-memory only, cleared on project switch) — the canonical edit is
 * `edl`; Wave 3 removes the legacy timeline once every screen consumes
 * the EDL.
 */

let idCounter = 0;
function nextId(prefix: string): string {
  idCounter += 1;
  return `${prefix}-${Date.now().toString(36)}-${idCounter}`;
}
const nextClipId = () => nextId('clip');
const nextProjectId = () => nextId('project');

export function createEmptyProject(name: string): Project {
  const now = Date.now();
  return {
    id: nextProjectId(),
    name,
    createdAt: now,
    updatedAt: now,
    track: null,
    trackRegion: { startSeconds: 0, durationSeconds: null },
    takes: [],
    edl: null,
    lastShuffleSequence: null,
    shuffleFrequency: 'normal',
  };
}

interface StudioState {
  // ---- Projects ----
  projects: Project[];
  activeProject: Project | null;
  activeProjectId: string | null;
  /** False until the persisted state has been loaded from disk. */
  hydrated: boolean;
  createProject: (name?: string) => string;
  openProject: (id: string) => void;
  deleteProject: (id: string) => void;
  renameProject: (id: string, name: string) => void;

  // ---- Active project: creative state ----
  track: AudioTrack | null;
  takes: Take[];
  /** The canonical edit (frame-based EDL). Null until the first edit exists. */
  edl: Edl | null;
  setEdl: (edl: Edl | null) => void;
  /** TRANSITIONAL legacy seconds-based timeline; removed in Wave 3. */
  timeline: TimelineClip[];

  setTrack: (track: AudioTrack | null) => void;
  setTrackDuration: (seconds: number) => void;

  /** The selected part of the track — single source of truth (see AudioRegion). */
  trackRegion: AudioRegion;
  setTrackRegion: (region: AudioRegion) => void;

  addTake: (take: Take) => void;
  removeTake: (takeId: string) => void;
  /** Patch a take in place (rename, measured sync/duration updates…). */
  updateTake: (takeId: string, patch: Partial<Take>) => void;

  addToTimeline: (takeId: string) => void;
  removeFromTimeline: (clipId: string) => void;
  moveTimelineClip: (clipId: string, direction: -1 | 1) => void;
  swapTimelineClips: (clipIdA: string, clipIdB: string) => void;
  clearTimeline: () => void;

  /** Resolve a timeline clip back to its take. */
  takeForClip: (clip: TimelineClip) => Take | undefined;

  /** Cached phrase/energy analysis of the current track (see analysis.ts). */
  trackSections: MusicalSection[];
  setTrackSections: (sections: MusicalSection[]) => void;

  assignClipTake: (clipId: string, takeId: string) => void;
  applyTimeline: (
    clips: { takeId: string; trimStartSeconds?: number; trimEndSeconds?: number }[],
  ) => void;
  undoTimeline: () => void;
  canUndoTimeline: boolean;
  updateClipTrim: (clipId: string, trimStartSeconds: number, trimEndSeconds?: number) => void;
  updateClip: (clipId: string, patch: Partial<Omit<TimelineClip, 'id' | 'takeId'>>) => void;
  duplicateTimelineClip: (clipId: string) => void;
  splitTimelineClip: (clipId: string) => void;
  coverClipId: string | null;
  setCoverClipId: (clipId: string | null) => void;

  lastShuffle: ShuffleResultInfo | null;
  setLastShuffle: (info: ShuffleResultInfo | null) => void;
  shuffleFrequency: ShuffleFrequency;
  setShuffleFrequency: (v: ShuffleFrequency) => void;

  // ---- Global camera + settings preferences ----
  facing: CameraType;
  setFacing: (f: CameraType | ((current: CameraType) => CameraType)) => void;
  torch: boolean;
  setTorch: (v: boolean | ((current: boolean) => boolean)) => void;
  mirror: boolean;
  setMirror: (v: boolean | ((current: boolean) => boolean)) => void;
  zoom: number;
  setZoom: (v: number | ((current: number) => number)) => void;
  countdown: CountdownSeconds;
  setCountdown: (v: CountdownSeconds) => void;
  resolution: VideoQuality;
  setResolution: (v: VideoQuality) => void;
  frameRate: FrameRatePref;
  setFrameRate: (v: FrameRatePref) => void;
  gridOverlay: boolean;
  setGridOverlay: (v: boolean | ((current: boolean) => boolean)) => void;
  levelGuide: boolean;
  setLevelGuide: (v: boolean | ((current: boolean) => boolean)) => void;
  audioOffsetMs: number;
  setAudioOffsetMs: (v: number) => void;
  countInBeats: CountInBeats;
  setCountInBeats: (v: CountInBeats) => void;
  metronome: boolean;
  setMetronome: (v: boolean | ((current: boolean) => boolean)) => void;
  autosave: boolean;
  setAutosave: (v: boolean | ((current: boolean) => boolean)) => void;
  exportQuality: ExportQualityPref;
  setExportQuality: (v: ExportQualityPref) => void;
}

const StudioContext = createContext<StudioState | null>(null);

export function StudioProvider({ children }: { children: ReactNode }) {
  const [projects, setProjects] = useState<Project[]>([]);
  const [activeProjectId, setActiveProjectId] = useState<string | null>(null);
  const [hydrated, setHydrated] = useState(false);

  // Transient (never persisted): analysis cache, legacy timeline, undo.
  const [trackSections, setTrackSections] = useState<MusicalSection[]>([]);
  const [timeline, setTimeline] = useState<TimelineClip[]>([]);
  const [undoStack, setUndoStack] = useState<TimelineClip[][]>([]);
  const [lastShuffle, setLastShuffle] = useState<ShuffleResultInfo | null>(null);
  const [coverClipId, setCoverClipId] = useState<string | null>(null);

  // Global preferences.
  const [facing, setFacing] = useState<CameraType>('back');
  const [torch, setTorch] = useState(false);
  const [mirror, setMirror] = useState(true);
  const [zoom, setZoom] = useState(0);
  // Timer defaults OFF (Jaizon, device test 2026-11-08).
  const [countdown, setCountdown] = useState<CountdownSeconds>(0);
  const [resolution, setResolution] = useState<VideoQuality>('1080p');
  const [frameRate, setFrameRate] = useState<FrameRatePref>(30);
  const [gridOverlay, setGridOverlay] = useState(false);
  const [levelGuide, setLevelGuide] = useState(false);
  const [audioOffsetMs, setAudioOffsetMsState] = useState(0);
  // Count-in defaults OFF too (device test 2026-11-08).
  const [countInBeats, setCountInBeats] = useState<CountInBeats>(0);
  const [metronome, setMetronome] = useState(false);
  const [autosave, setAutosave] = useState(true);
  const [exportQuality, setExportQuality] = useState<ExportQualityPref>('balanced');

  const activeProject = useMemo(
    () => projects.find((p) => p.id === activeProjectId) ?? null,
    [projects, activeProjectId],
  );
  // Callbacks patch "the active project" without taking it as a
  // dependency; the ref is synced in an effect (never during render).
  const activeProjectRef = useRef<Project | null>(null);
  useEffect(() => {
    activeProjectRef.current = activeProject;
  }, [activeProject]);

  // ---- Hydrate from disk once; guarantee at least one project exists
  // so the studio always opens onto something real. ----
  useEffect(() => {
    let alive = true;
    void (async () => {
      const loaded = await loadProjects();
      if (!alive) return;
      if (loaded && loaded.projects.length > 0) {
        setProjects(loaded.projects);
        setActiveProjectId(
          loaded.activeProjectId && loaded.projects.some((p) => p.id === loaded.activeProjectId)
            ? loaded.activeProjectId
            : loaded.projects[0].id,
        );
      } else {
        const first = createEmptyProject('My first project');
        setProjects([first]);
        setActiveProjectId(first.id);
      }
      setHydrated(true);
    })();
    return () => {
      alive = false;
    };
  }, []);

  // ---- Persist (debounced) whenever projects change after hydration. ----
  const saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    if (!hydrated) return;
    if (saveTimer.current) clearTimeout(saveTimer.current);
    saveTimer.current = setTimeout(() => {
      void saveProjects({ version: 1, projects, activeProjectId });
    }, 400);
    return () => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
    };
  }, [projects, activeProjectId, hydrated]);

  /** Patch the active project immutably + stamp updatedAt. */
  const patchActiveProject = useCallback((patch: Partial<Project>) => {
    setProjects((current) => {
      const id = activeProjectRef.current?.id;
      if (!id) return current;
      return current.map((p) => (p.id === id ? { ...p, ...patch, updatedAt: Date.now() } : p));
    });
  }, []);

  // ---- Project management ----
  const createProject = useCallback((name?: string) => {
    const project = createEmptyProject(name?.trim() || 'Untitled project');
    setProjects((current) => [project, ...current]);
    setActiveProjectId(project.id);
    setTimeline([]);
    setUndoStack([]);
    setLastShuffle(null);
    setTrackSections([]);
    setCoverClipId(null);
    return project.id;
  }, []);

  const openProject = useCallback(
    (id: string) => {
      if (!projects.some((p) => p.id === id)) return;
      setActiveProjectId(id);
      setTimeline([]);
      setUndoStack([]);
      setLastShuffle(null);
      setTrackSections([]);
      setCoverClipId(null);
    },
    [projects],
  );

  const deleteProject = useCallback(
    (id: string) => {
      setProjects((current) => {
        const next = current.filter((p) => p.id !== id);
        if (activeProjectId === id) {
          setActiveProjectId(next[0]?.id ?? null);
          setTimeline([]);
          setUndoStack([]);
          setLastShuffle(null);
        }
        return next;
      });
    },
    [activeProjectId],
  );

  const renameProject = useCallback((id: string, name: string) => {
    const trimmed = name.trim();
    if (!trimmed) return;
    setProjects((current) => current.map((p) => (p.id === id ? { ...p, name: trimmed, updatedAt: Date.now() } : p)));
  }, []);

  // ---- Active-project creative state (legacy-compatible accessors) ----
  const track = activeProject?.track ?? null;
  const takes = useMemo(() => activeProject?.takes ?? [], [activeProject]);
  const trackRegion = useMemo(
    () => activeProject?.trackRegion ?? { startSeconds: 0, durationSeconds: null },
    [activeProject],
  );
  const edl = activeProject?.edl ?? null;
  const shuffleFrequency = activeProject?.shuffleFrequency ?? 'normal';

  const setEdl = useCallback(
    (next: Edl | null) => patchActiveProject({ edl: next }),
    [patchActiveProject],
  );

  const setTrack = useCallback(
    (next: AudioTrack | null) => {
      patchActiveProject({
        track: next,
        trackRegion: { startSeconds: 0, durationSeconds: null },
        lastShuffleSequence: null,
      });
      setTrackSections([]);
      setLastShuffle(null);
    },
    [patchActiveProject],
  );

  const setTrackDuration = useCallback(
    (seconds: number) => {
      const current = activeProjectRef.current;
      if (!current?.track) return;
      if (current.track.durationSeconds && Math.abs(current.track.durationSeconds - seconds) <= 0.5) return;
      patchActiveProject({ track: { ...current.track, durationSeconds: seconds } });
    },
    [patchActiveProject],
  );

  const setTrackRegion = useCallback(
    (region: AudioRegion) => {
      patchActiveProject({
        trackRegion: {
          startSeconds: Math.max(0, region.startSeconds),
          durationSeconds: region.durationSeconds === null ? null : Math.max(1, region.durationSeconds),
        },
      });
      // Region changed — any sampled section table belongs to the old region.
      setTrackSections([]);
    },
    [patchActiveProject],
  );

  const setShuffleFrequency = useCallback(
    (v: ShuffleFrequency) => patchActiveProject({ shuffleFrequency: v }),
    [patchActiveProject],
  );

  const addTake = useCallback(
    (take: Take) => {
      const current = activeProjectRef.current;
      if (!current) return;
      patchActiveProject({ takes: [take, ...current.takes] });
    },
    [patchActiveProject],
  );

  const updateTake = useCallback(
    (takeId: string, patch: Partial<Take>) => {
      const current = activeProjectRef.current;
      if (!current) return;
      patchActiveProject({ takes: current.takes.map((t) => (t.id === takeId ? { ...t, ...patch } : t)) });
    },
    [patchActiveProject],
  );

  const removeTake = useCallback(
    (takeId: string) => {
      const current = activeProjectRef.current;
      if (!current) return;
      patchActiveProject({ takes: current.takes.filter((t) => t.id !== takeId) });
      setTimeline((tl) => tl.filter((c) => c.takeId !== takeId));
    },
    [patchActiveProject],
  );

  // ---- Legacy timeline operations (transitional; see header note) ----
  const pushUndo = useCallback((snapshot: TimelineClip[]) => {
    setUndoStack((current) => [...current.slice(-9), snapshot]);
  }, []);

  const assignClipTake = useCallback(
    (clipId: string, takeId: string) => {
      setTimeline((current) =>
        current.map((c) => {
          if (c.id !== clipId) return c;
          const take = takes.find((t) => t.id === takeId);
          const end = c.trimEndSeconds;
          return {
            ...c,
            takeId,
            trimEndSeconds:
              end !== undefined && take?.durationSeconds && end >= take.durationSeconds ? undefined : end,
          };
        }),
      );
    },
    [takes],
  );

  const applyTimeline = useCallback(
    (clips: { takeId: string; trimStartSeconds?: number; trimEndSeconds?: number }[]) => {
      setTimeline((current) => {
        pushUndo(current);
        return clips.map((clip) => ({ id: nextClipId(), ...clip }));
      });
    },
    [pushUndo],
  );

  const undoTimeline = useCallback(() => {
    setUndoStack((current) => {
      const previous = current[current.length - 1];
      if (previous) setTimeline(previous);
      return current.slice(0, -1);
    });
  }, []);

  const updateClipTrim = useCallback((clipId: string, trimStartSeconds: number, trimEndSeconds?: number) => {
    setTimeline((current) =>
      current.map((c) => (c.id === clipId ? { ...c, trimStartSeconds, trimEndSeconds } : c)),
    );
  }, []);

  const updateClip = useCallback((clipId: string, patch: Partial<Omit<TimelineClip, 'id' | 'takeId'>>) => {
    setTimeline((current) => current.map((c) => (c.id === clipId ? { ...c, ...patch } : c)));
  }, []);

  const duplicateTimelineClip = useCallback((clipId: string) => {
    setTimeline((current) => {
      const index = current.findIndex((c) => c.id === clipId);
      if (index === -1) return current;
      const copy: TimelineClip = { ...current[index], id: nextClipId() };
      return [...current.slice(0, index + 1), copy, ...current.slice(index + 1)];
    });
  }, []);

  const splitTimelineClip = useCallback(
    (clipId: string) => {
      setTimeline((current) => {
        const index = current.findIndex((c) => c.id === clipId);
        if (index === -1) return current;
        const clip = current[index];
        const take = takes.find((t) => t.id === clip.takeId);
        const start = clip.trimStartSeconds ?? 0;
        const end = clip.trimEndSeconds ?? take?.durationSeconds ?? start + 1;
        if (end - start < 1) return current;
        const mid = start + (end - start) / 2;
        const first: TimelineClip = { ...clip, trimEndSeconds: mid };
        const second: TimelineClip = { ...clip, id: nextClipId(), trimStartSeconds: mid, trimEndSeconds: clip.trimEndSeconds };
        return [...current.slice(0, index), first, second, ...current.slice(index + 1)];
      });
    },
    [takes],
  );

  const addToTimeline = useCallback((takeId: string) => {
    setTimeline((current) => [...current, { id: nextClipId(), takeId }]);
  }, []);

  const removeFromTimeline = useCallback((clipId: string) => {
    setTimeline((current) => current.filter((c) => c.id !== clipId));
    setCoverClipId((current) => (current === clipId ? null : current));
  }, []);

  const moveTimelineClip = useCallback((clipId: string, direction: -1 | 1) => {
    setTimeline((current) => {
      const index = current.findIndex((c) => c.id === clipId);
      const target = index + direction;
      if (index === -1 || target < 0 || target >= current.length) return current;
      const next = [...current];
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });
  }, []);

  const swapTimelineClips = useCallback((clipIdA: string, clipIdB: string) => {
    if (clipIdA === clipIdB) return;
    setTimeline((current) => {
      const a = current.findIndex((c) => c.id === clipIdA);
      const b = current.findIndex((c) => c.id === clipIdB);
      if (a === -1 || b === -1) return current;
      const next = [...current];
      [next[a], next[b]] = [next[b], next[a]];
      return next;
    });
  }, []);

  const clearTimeline = useCallback(() => {
    setTimeline([]);
    setCoverClipId(null);
  }, []);

  const takeForClip = useCallback(
    (clip: TimelineClip) => takes.find((t) => t.id === clip.takeId),
    [takes],
  );

  const setAudioOffsetMs = useCallback((v: number) => {
    setAudioOffsetMsState(Math.max(-500, Math.min(500, Math.round(v))));
  }, []);

  const value = useMemo<StudioState>(
    () => ({
      projects,
      activeProject,
      activeProjectId,
      hydrated,
      createProject,
      openProject,
      deleteProject,
      renameProject,
      track,
      takes,
      edl,
      setEdl,
      timeline,
      setTrack,
      setTrackDuration,
      trackRegion,
      setTrackRegion,
      addTake,
      removeTake,
      updateTake,
      addToTimeline,
      removeFromTimeline,
      moveTimelineClip,
      swapTimelineClips,
      clearTimeline,
      takeForClip,
      trackSections,
      setTrackSections,
      applyTimeline,
      assignClipTake,
      undoTimeline,
      canUndoTimeline: undoStack.length > 0,
      updateClipTrim,
      lastShuffle,
      setLastShuffle,
      shuffleFrequency,
      setShuffleFrequency,
      updateClip,
      duplicateTimelineClip,
      splitTimelineClip,
      coverClipId,
      setCoverClipId,
      resolution,
      setResolution,
      frameRate,
      setFrameRate,
      gridOverlay,
      setGridOverlay,
      levelGuide,
      setLevelGuide,
      audioOffsetMs,
      setAudioOffsetMs,
      countInBeats,
      setCountInBeats,
      metronome,
      setMetronome,
      autosave,
      setAutosave,
      exportQuality,
      setExportQuality,
      facing,
      setFacing,
      torch,
      setTorch,
      mirror,
      setMirror,
      zoom,
      setZoom,
      countdown,
      setCountdown,
    }),
    [
      projects,
      activeProject,
      activeProjectId,
      hydrated,
      createProject,
      openProject,
      deleteProject,
      renameProject,
      track,
      takes,
      edl,
      setEdl,
      timeline,
      setTrack,
      setTrackDuration,
      trackRegion,
      setTrackRegion,
      addTake,
      removeTake,
      updateTake,
      addToTimeline,
      removeFromTimeline,
      moveTimelineClip,
      swapTimelineClips,
      clearTimeline,
      takeForClip,
      trackSections,
      applyTimeline,
      assignClipTake,
      undoTimeline,
      undoStack.length,
      updateClipTrim,
      lastShuffle,
      shuffleFrequency,
      setShuffleFrequency,
      updateClip,
      duplicateTimelineClip,
      splitTimelineClip,
      coverClipId,
      resolution,
      frameRate,
      gridOverlay,
      levelGuide,
      audioOffsetMs,
      setAudioOffsetMs,
      countInBeats,
      metronome,
      autosave,
      exportQuality,
      facing,
      torch,
      mirror,
      zoom,
      countdown,
    ],
  );

  return <StudioContext.Provider value={value}>{children}</StudioContext.Provider>;
}

export function useStudio(): StudioState {
  const ctx = useContext(StudioContext);
  if (!ctx) throw new Error('useStudio must be used inside <StudioProvider>');
  return ctx;
}
