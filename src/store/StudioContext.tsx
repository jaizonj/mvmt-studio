import type { CameraType, VideoQuality } from 'expo-camera';
import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react';

import type {
  AudioRegion,
  AudioTrack,
  CountInBeats,
  CountdownSeconds,
  ExportQualityPref,
  FrameRatePref,
  MusicalSection,
  ShuffleFrequency,
  ShuffleResultInfo,
  Take,
  TimelineClip,
} from '../types';

interface StudioState {
  track: AudioTrack | null;
  takes: Take[];
  /** The edit: an ordered list of take placements. */
  timeline: TimelineClip[];

  setTrack: (track: AudioTrack | null) => void;
  setTrackDuration: (seconds: number) => void;

  /** The selected part of the track — single source of truth (see AudioRegion). */
  trackRegion: AudioRegion;
  setTrackRegion: (region: AudioRegion) => void;

  addTake: (take: Take) => void;
  removeTake: (takeId: string) => void;

  addToTimeline: (takeId: string) => void;
  removeFromTimeline: (clipId: string) => void;
  /** Move a timeline clip one step earlier/later. */
  moveTimelineClip: (clipId: string, direction: -1 | 1) => void;
  /** Swap the positions of two timeline clips (tap one, then tap another). */
  swapTimelineClips: (clipIdA: string, clipIdB: string) => void;
  clearTimeline: () => void;

  /** Resolve a timeline clip back to its take. */
  takeForClip: (clip: TimelineClip) => Take | undefined;

  /** Cached phrase/energy analysis of the current track (see analysis.ts). */
  trackSections: MusicalSection[];
  setTrackSections: (sections: MusicalSection[]) => void;

  /**
   * Switch which take a timeline clip uses, keeping its trim range (the
   * same section of the song) — the Triller-style per-cut take switch on
   * the Shuffle timeline. Trim end clamps to the new take's length.
   */
  assignClipTake: (clipId: string, takeId: string) => void;
  /** Replace the whole timeline (used by Shuffle) — snapshot first so it can be undone. */
  applyTimeline: (
    clips: { takeId: string; trimStartSeconds?: number; trimEndSeconds?: number }[],
  ) => void;
  /** Undo the last whole-timeline change / clip edit. */
  undoTimeline: () => void;
  canUndoTimeline: boolean;
  /** Adjust a clip's trim in/out points (seconds inside its take). */
  updateClipTrim: (clipId: string, trimStartSeconds: number, trimEndSeconds?: number) => void;
  /** Patch any creative fields on a clip (speed, volume, fades, look, text, transition…). Edit stage only. */
  updateClip: (clipId: string, patch: Partial<Omit<TimelineClip, 'id' | 'takeId'>>) => void;
  /** Duplicate a clip in place (same take, same trims/creative settings). */
  duplicateTimelineClip: (clipId: string) => void;
  /** Split a clip into two at the midpoint of its current trim range. */
  splitTimelineClip: (clipId: string) => void;
  /** Which clip supplies the export cover/thumbnail frame. */
  coverClipId: string | null;
  setCoverClipId: (clipId: string | null) => void;

  /** The most recent shuffle applied (score kept internal only — never displayed). */
  lastShuffle: ShuffleResultInfo | null;
  setLastShuffle: (info: ShuffleResultInfo | null) => void;
  /** How often Shuffle changes clip — target section length for the engine. */
  shuffleFrequency: ShuffleFrequency;
  setShuffleFrequency: (v: ShuffleFrequency) => void;

  /**
   * Camera preferences — the "little options" that live in Settings.
   * Kept in the store (not on the camera screen) so the Settings sheet
   * shows and changes the REAL values from any flow screen; the camera
   * picks changes up when you go back to it.
   */
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

  // ---- Settings: configuration ONLY (no creative tools in Settings) ----
  /** Recorded video quality, applied to the camera. */
  resolution: VideoQuality;
  setResolution: (v: VideoQuality) => void;
  /** Preferred frame rate — a stored default; the camera picks the closest the device supports. */
  frameRate: FrameRatePref;
  setFrameRate: (v: FrameRatePref) => void;
  /** Rule-of-thirds grid overlay on the camera. */
  gridOverlay: boolean;
  setGridOverlay: (v: boolean | ((current: boolean) => boolean)) => void;
  /** Centre level/framing guide overlay on the camera. */
  levelGuide: boolean;
  setLevelGuide: (v: boolean | ((current: boolean) => boolean)) => void;
  /** Sync correction for Bluetooth/output latency, milliseconds (−500..500). Applied to track playback seeks. */
  audioOffsetMs: number;
  setAudioOffsetMs: (v: number) => void;
  /** Musical count-in beats played/flashed before a take starts (separate from the camera timer). */
  countInBeats: CountInBeats;
  setCountInBeats: (v: CountInBeats) => void;
  /** Flash a beat dot while recording. */
  metronome: boolean;
  setMetronome: (v: boolean | ((current: boolean) => boolean)) => void;
  /** Autosave preference for the project (persistence itself is a README TODO; the default is honoured when it lands). */
  autosave: boolean;
  setAutosave: (v: boolean | ((current: boolean) => boolean)) => void;
  /** Default export quality, shown/chosen on the Export stage. */
  exportQuality: ExportQualityPref;
  setExportQuality: (v: ExportQualityPref) => void;
}

const StudioContext = createContext<StudioState | null>(null);

let clipCounter = 0;
function nextClipId(): string {
  clipCounter += 1;
  return `clip-${Date.now().toString(36)}-${clipCounter}`;
}

export function StudioProvider({ children }: { children: ReactNode }) {
  const [track, setTrackState] = useState<AudioTrack | null>(null);
  const [takes, setTakes] = useState<Take[]>([]);
  const [timeline, setTimeline] = useState<TimelineClip[]>([]);
  const [trackSections, setTrackSections] = useState<MusicalSection[]>([]);
  const [trackRegion, setTrackRegionState] = useState<AudioRegion>({ startSeconds: 0, durationSeconds: null });

  const setTrackRegion = useCallback((region: AudioRegion) => {
    setTrackRegionState({
      startSeconds: Math.max(0, region.startSeconds),
      durationSeconds: region.durationSeconds === null ? null : Math.max(1, region.durationSeconds),
    });
    // Region changed — any sampled section table belongs to the old region.
    setTrackSections([]);
  }, []);
  const [undoStack, setUndoStack] = useState<TimelineClip[][]>([]);
  const [lastShuffle, setLastShuffle] = useState<ShuffleResultInfo | null>(null);
  const [shuffleFrequency, setShuffleFrequency] = useState<ShuffleFrequency>('normal');
  const [facing, setFacing] = useState<CameraType>('back');
  const [torch, setTorch] = useState(false);
  const [mirror, setMirror] = useState(true);
  const [zoom, setZoom] = useState(0);
  // Timer defaults OFF (Jaizon, device test 2026-11-08): pressing record
  // starts the take straight away unless he turns a timer on himself.
  const [countdown, setCountdown] = useState<CountdownSeconds>(0);
  const [coverClipId, setCoverClipId] = useState<string | null>(null);
  // Settings (configuration only)
  const [resolution, setResolution] = useState<VideoQuality>('1080p');
  const [frameRate, setFrameRate] = useState<FrameRatePref>(30);
  const [gridOverlay, setGridOverlay] = useState(false);
  const [levelGuide, setLevelGuide] = useState(false);
  const [audioOffsetMs, setAudioOffsetMsState] = useState(0);
  // Count-in defaults OFF too — it previously stacked after the camera
  // timer (3-2-1 then 4-3-2-1), which read as one confusing countdown.
  const [countInBeats, setCountInBeats] = useState<CountInBeats>(0);
  const [metronome, setMetronome] = useState(false);
  const [autosave, setAutosave] = useState(true);
  const [exportQuality, setExportQuality] = useState<ExportQualityPref>('balanced');

  const setAudioOffsetMs = useCallback((v: number) => {
    setAudioOffsetMsState(Math.max(-500, Math.min(500, Math.round(v))));
  }, []);

  const pushUndo = useCallback((snapshot: TimelineClip[]) => {
    setUndoStack((current) => [...current.slice(-9), snapshot]);
  }, []);

  const assignClipTake = useCallback((clipId: string, takeId: string) => {
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
  }, [takes]);

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
        if (end - start < 1) return current; // too short to split usefully
        const mid = start + (end - start) / 2;
        const first: TimelineClip = { ...clip, trimEndSeconds: mid };
        const second: TimelineClip = { ...clip, id: nextClipId(), trimStartSeconds: mid, trimEndSeconds: clip.trimEndSeconds };
        return [...current.slice(0, index), first, second, ...current.slice(index + 1)];
      });
    },
    [takes],
  );

  const setTrack = useCallback((next: AudioTrack | null) => {
    setTrackState(next);
    setTrackSections([]);
    setTrackRegionState({ startSeconds: 0, durationSeconds: null });
    setLastShuffle(null);
    // A new track invalidates the old edit's timing assumptions, but the
    // takes themselves are kept — the user may just be swapping songs.
    // (Timeline is left untouched on purpose; see README "Design notes".)
  }, []);

  const setTrackDuration = useCallback((seconds: number) => {
    setTrackState((current) =>
      current && (!current.durationSeconds || Math.abs(current.durationSeconds - seconds) > 0.5)
        ? { ...current, durationSeconds: seconds }
        : current,
    );
  }, []);

  const addTake = useCallback((take: Take) => {
    setTakes((current) => [take, ...current]);
  }, []);

  const removeTake = useCallback((takeId: string) => {
    setTakes((current) => current.filter((t) => t.id !== takeId));
    setTimeline((current) => current.filter((c) => c.takeId !== takeId));
  }, []);

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

  const value = useMemo<StudioState>(
    () => ({
      track,
      takes,
      timeline,
      setTrack,
      setTrackDuration,
      trackRegion,
      setTrackRegion,
      addTake,
      removeTake,
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
      track,
      takes,
      timeline,
      setTrack,
      setTrackDuration,
      trackRegion,
      setTrackRegion,
      addTake,
      removeTake,
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
