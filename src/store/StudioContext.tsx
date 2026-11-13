import type { CameraType, VideoQuality } from 'expo-camera';
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';

import { warmUpEqSong } from '../lib/autoEq';
import type { Edl } from '../lib/edl';
import { effectiveLook } from '../lib/looks';
import { cleanDetectedLyrics, respellLyricProfanity, retimeLineWordsForText, shiftLyricLines, sortLyricLines } from '../lib/lyrics';
import { lyricTemplateById } from '../lib/lyricTemplates';
import { resolveMixMasterStageSettings, type MixMasterStageSettings } from '../lib/mixMasterCurve';
import {
  mixMasterRestoreOriginalPatch,
  mixMasterUseInProjectPatch,
} from '../lib/mixMasterExport';
import { loadProjects, saveProjects } from '../lib/persistence';
import { findSongLibraryEntry, removeSongLibraryEntry, upsertSongLibraryEntry } from '../lib/songLibrary';
import type {
  AudioRegion,
  AudioTrack,
  CountInBeats,
  CountdownSeconds,
  ExportQualityPref,
  FrameRatePref,
  LyricLine,
  LyricStyle,
  MusicalSection,
  Project,
  ProjectLook,
  ProjectLyrics,
  ShuffleFrequency,
  SongLibraryEntry,
  Take,
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
 * The flat accessors (track, takes, …) read/write the ACTIVE project.
 * The canonical edit is the frame-based `edl` — the legacy seconds-based
 * timeline was removed in Wave 3 once every screen consumed the EDL.
 */

let idCounter = 0;
function nextId(prefix: string): string {
  idCounter += 1;
  return `${prefix}-${Date.now().toString(36)}-${idCounter}`;
}
const nextProjectId = () => nextId('project');

/**
 * Clean lyrics saved by earlier builds at load time: Whisper bracket
 * tokens ([_BEG_], [_TT_500]) and back-to-back echo-repeat lines are
 * removed from every stored project (the shared cleanup in
 * src/lib/lyrics.ts — the same pass fresh detections get). Only a
 * project whose lyrics actually change gets a new object, so the
 * debounced persist writes the cleaned state back exactly when
 * there was something to clean; the pass is idempotent.
 */
function cleanStoredLyrics(projects: Project[]): Project[] {
  return projects.map((project) => {
    const lyrics = project.lyrics;
    if (!lyrics) return project;
    const lines = cleanDetectedLyrics(lyrics.lines);
    const changed =
      lines.length !== lyrics.lines.length || lines.some((line, i) => line !== lyrics.lines[i]);
    return changed ? { ...project, lyrics: { ...lyrics, lines } } : project;
  });
}

/** The same load-time cleanup for song-library entries, plus a
 * shape guard — a malformed entry is dropped, never trusted. */
function cleanStoredLibrary(entries: SongLibraryEntry[] | undefined): SongLibraryEntry[] {
  if (!Array.isArray(entries)) return [];
  const out: SongLibraryEntry[] = [];
  for (const entry of entries) {
    if (!entry || typeof entry.key !== 'string' || typeof entry.uri !== 'string') continue;
    if (!entry.lyrics || !Array.isArray(entry.lyrics.lines)) continue;
    out.push({ ...entry, lyrics: { ...entry.lyrics, lines: cleanDetectedLyrics(entry.lyrics.lines) } });
  }
  return out;
}

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
    watermarkEnabled: true,
  };
}

/**
 * Native recorder quality (Settings → Capture quality). '1080p30' is
 * the default: session-preset steering, no forced device format.
 * The 60fps options make the native engine pin an exact-dimension
 * 60fps device format (with a silent preset fallback when a camera
 * doesn't offer one).
 */
export type CaptureQuality = '1080p30' | '1080p60' | '4k60';

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
  /** Stamp the active project as exported (called on a successful render). */
  markProjectExported: () => void;

  // ---- Active project: creative state ----
  track: AudioTrack | null;
  takes: Take[];
  /** The canonical edit (frame-based EDL). Null until the first edit exists. */
  edl: Edl | null;
  setEdl: (edl: Edl | null) => void;
  /** Apply a freshly generated edit + record its take sequence (so the next shuffle differs). */
  applyEdl: (edl: Edl, shuffleSequence?: string[]) => void;

  setTrack: (track: AudioTrack | null) => void;
  setTrackDuration: (seconds: number) => void;

  /** The selected part of the track — single source of truth (see AudioRegion). */
  trackRegion: AudioRegion;
  setTrackRegion: (region: AudioRegion) => void;

  addTake: (take: Take) => void;
  removeTake: (takeId: string) => void;
  /** Patch a take in place (rename, measured sync/duration updates…). */
  updateTake: (takeId: string, patch: Partial<Take>) => void;

  /** Cached phrase/energy analysis of the current track (see analysis.ts). */
  trackSections: MusicalSection[];
  setTrackSections: (sections: MusicalSection[]) => void;

  shuffleFrequency: ShuffleFrequency;
  setShuffleFrequency: (v: ShuffleFrequency) => void;

  /** Effective watermark flag for the active project — stored values
   *  win; projects saved before the flag existed read as ON. */
  watermarkEnabled: boolean;
  setWatermarkEnabled: (enabled: boolean) => void;

  /** Effective Auto EQ flag for the active project — stored values
   *  win; projects saved before the flag existed read as ON. When
   *  on, composition builds use the EQ-rendered copy of the song
   *  (harsh frequencies pulled down) once the engine has prepared
   *  it; recording always uses the original. */
  autoEqEnabled: boolean;
  setAutoEqEnabled: (enabled: boolean) => void;

  /** Effective Mix & Master flag for the active project — stored
   *  values win; projects saved before the flag existed read as
   *  OFF (Stage 1 is engine-only; the toggle comes with the Stage 3
   *  screen). When on, composition builds use the dynamically-EQ'd
   *  copy of the song INSTEAD of the Auto EQ copy; recording
   *  always uses the original. */
  mixMasterEnabled: boolean;
  setMixMasterEnabled: (enabled: boolean) => void;

  /** Effective Mix & Master stage settings for the active
   *  project — stored values win; unset reads as both stages ON
   *  at 100%. Only matters while `mixMasterEnabled` is on; the
   *  toggles and intensities come with the Stage 3 screen. */
  mixMasterStages: MixMasterStageSettings;
  setMixMasterStages: (patch: Partial<MixMasterStageSettings>) => void;

  /**
   * The ORIGINAL song this project's track was replaced from, when
   * the Mix & Master render was saved as the track ("Use in
   * project", Stage 4). Null when the track was never replaced —
   * the Mix & Master screen offers "Restore original song" while
   * this is set.
   */
  mixMasterSource: { uri: string; name: string } | null;
  /**
   * Save the processed song as the project's track (Stage 4 "Use in
   * project"): the track becomes the exported processed file, Mix &
   * Master turns off (the processing is baked into the file now),
   * and the original song is recorded in `mixMasterSource` so it
   * can be restored. Deliberately NOT setTrack: the region, the
   * EDL, the takes and the lyrics all carry over — the render is
   * the same song at the exact same length, so every song-time
   * position stays valid.
   */
  applyMixMasterTrack: (processedUri: string, processedFileName: string) => void;
  /** Switch the track back to the recorded original song (Stage 4). No-op when nothing was replaced. */
  restoreMixMasterSource: () => void;

  /** The active project's lyrics (song-frame timed lines + style). */
  lyrics: ProjectLyrics | null;
  /** Effective lyrics visibility — stored value wins; unset reads as
   *  ON when the project has lines, OFF when it has none. */
  lyricsEnabled: boolean;
  setLyricsEnabled: (enabled: boolean) => void;
  /** Replace (or clear, with null) the project's whole lyrics object. */
  setLyrics: (lyrics: ProjectLyrics | null) => void;
  /**
   * Patch one line. A `text` patch without a `words` patch runs the
   * word-timing rule (src/lib/lyrics.ts): same word count keeps the
   * timings word-for-word, a different count drops them.
   */
  updateLyricLine: (lineId: string, patch: Partial<LyricLine>) => void;
  addLyricLine: (line: LyricLine) => void;
  deleteLyricLine: (lineId: string) => void;
  setLyricStyle: (patch: Partial<LyricStyle>) => void;
  /** Heart/unheart a font in the Style tab picker (per-project favorite). */
  toggleFavoriteLyricFont: (fontId: string) => void;
  /** Heart/unheart an animation in the Style tab picker (per-project favorite). */
  toggleFavoriteLyricAnimation: (animationId: string) => void;
  /**
   * Apply an Extra Style template (Styles Redesign Stage 2): sets
   * `templateId` and merges the template's style into the project's
   * lyric style in one tap. Null clears the template (the style
   * stays as it is — classic rendering).
   */
  setLyricTemplate: (templateId: string | null) => void;
  /** Heart/unheart a template in the Extra tab picker (per-project favorite). */
  toggleFavoriteLyricTemplate: (templateId: string) => void;
  /** Shift every line (and its words) by a frame delta. */
  shiftAllLyrics: (frames: number) => void;
  /** The active lyrics' fine offset in frames (0 when unset) — the
   * Lyrics panel's drag bar; applied at render time only. */
  lyricsOffsetFrames: number;
  /** Store the fine offset (clamped to ±90 frames). */
  setLyricsOffset: (frames: number) => void;
  /** The song library: songs with the lyrics fixed for them. */
  songLibrary: SongLibraryEntry[];
  /** Use a library song as the active project's track, lyrics included. */
  applyLibrarySong: (entry: SongLibraryEntry) => void;
  /** Remove a song from the library. */
  deleteSongLibraryEntry: (key: string) => void;

  /**
   * The active project's EFFECTIVE video look — the stored look when
   * one was chosen, otherwise Original (no grade — the Auto Enhance
   * auto-apply was removed 2026-11-13). Resolve it with
   * resolveLookParams (src/lib/looks.ts) wherever a request is built.
   */
  look: ProjectLook;
  /** Store a look on the active project (preset pick, intensity, slider overrides). */
  setProjectLook: (look: ProjectLook) => void;

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
  captureQuality: CaptureQuality;
  setCaptureQuality: (v: CaptureQuality) => void;
  /** Native recorder stabilization: ON = the connection's .auto mode. */
  stabilization: boolean;
  setStabilization: (v: boolean | ((current: boolean) => boolean)) => void;
  /** Lock exposure + white balance for the duration of each take. */
  lockExposureWhileRecording: boolean;
  setLockExposureWhileRecording: (v: boolean | ((current: boolean) => boolean)) => void;
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
  /**
   * Export file-size target in MB (0 = off). Applies to the TikTok /
   * Balanced / Small tiers; stored like exportQuality.
   */
  exportTargetSizeMB: number;
  setExportTargetSizeMB: (v: number) => void;
  /**
   * Auto volume: normalize the song to the platform loudness
   * (−14 LUFS) inside the composition. Default ON; the toggle lives
   * on the Export screen and rides both preview and export requests.
   */
  autoVolume: boolean;
  setAutoVolume: (v: boolean | ((current: boolean) => boolean)) => void;
}

const StudioContext = createContext<StudioState | null>(null);

export function StudioProvider({ children }: { children: ReactNode }) {
  const [projects, setProjects] = useState<Project[]>([]);
  const [activeProjectId, setActiveProjectId] = useState<string | null>(null);
  const [hydrated, setHydrated] = useState(false);
  const [songLibrary, setSongLibrary] = useState<SongLibraryEntry[]>([]);

  // Transient (never persisted): the track analysis cache.
  const [trackSections, setTrackSections] = useState<MusicalSection[]>([]);

  // Global preferences.
  const [facing, setFacing] = useState<CameraType>('back');
  const [torch, setTorch] = useState(false);
  const [mirror, setMirror] = useState(true);
  const [zoom, setZoom] = useState(0);
  // Timer defaults OFF (Jaizon, device test 2026-11-08).
  const [countdown, setCountdown] = useState<CountdownSeconds>(0);
  const [resolution, setResolution] = useState<VideoQuality>('1080p');
  const [frameRate, setFrameRate] = useState<FrameRatePref>(30);
  const [captureQuality, setCaptureQuality] = useState<CaptureQuality>('1080p30');
  // Capture enhancements (Balanced quality update): stabilization
  // auto-on, exposure locked while a take records — both default ON
  // and auto-applied; Settings turns them off.
  const [stabilization, setStabilization] = useState(true);
  const [lockExposureWhileRecording, setLockExposureWhileRecording] = useState(true);
  const [gridOverlay, setGridOverlay] = useState(false);
  const [levelGuide, setLevelGuide] = useState(false);
  const [audioOffsetMs, setAudioOffsetMsState] = useState(0);
  // Count-in defaults OFF too (device test 2026-11-08).
  const [countInBeats, setCountInBeats] = useState<CountInBeats>(0);
  const [metronome, setMetronome] = useState(false);
  const [autosave, setAutosave] = useState(true);
  const [exportQuality, setExportQuality] = useState<ExportQualityPref>('balanced');
  const [exportTargetSizeMB, setExportTargetSizeMB] = useState(0);
  const [autoVolume, setAutoVolume] = useState(true);

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
        setProjects(cleanStoredLyrics(loaded.projects));
        setSongLibrary(cleanStoredLibrary(loaded.songLibrary));
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
      void saveProjects({ version: 1, projects, activeProjectId, songLibrary });
    }, 400);
    return () => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
    };
  }, [projects, activeProjectId, songLibrary, hydrated]);

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
    setTrackSections([]);
    return project.id;
  }, []);

  const openProject = useCallback(
    (id: string) => {
      if (!projects.some((p) => p.id === id)) return;
      setActiveProjectId(id);
            setTrackSections([]);
      },
    [projects],
  );

  const deleteProject = useCallback(
    (id: string) => {
      setProjects((current) => {
        const next = current.filter((p) => p.id !== id);
        if (activeProjectId === id) {
          setActiveProjectId(next[0]?.id ?? null);
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

  const markProjectExported = useCallback(() => {
    patchActiveProject({ exportedAt: Date.now() });
  }, [patchActiveProject]);

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

  const applyEdl = useCallback(
    (next: Edl, shuffleSequence?: string[]) =>
      patchActiveProject({
        edl: next,
        lastShuffleSequence: shuffleSequence ?? activeProjectRef.current?.lastShuffleSequence ?? null,
      }),
    [patchActiveProject],
  );

  const setTrack = useCallback(
    (next: AudioTrack | null) => {
      patchActiveProject({
        track: next,
        trackRegion: { startSeconds: 0, durationSeconds: null },
        lastShuffleSequence: null,
        // Lyrics are timed against THIS song's clock — a new song
        // invalidates them, so they clear with the track.
        lyrics: undefined,
        lyricsEnabled: undefined,
      });
      setTrackSections([]);
      // Auto EQ warm-up: start analyzing/rendering the new song in
      // the background so the processed copy is ready when the
      // editor/export screens build their compositions. Fire and
      // forget — if it never lands, compositions use the original.
      warmUpEqSong(next?.uri);
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

  // The persisted field is optional (older projects predate it); the
  // effective value defaults to ON when it was never set.
  const watermarkEnabled = activeProject?.watermarkEnabled ?? true;

  const setWatermarkEnabled = useCallback(
    (enabled: boolean) => patchActiveProject({ watermarkEnabled: enabled }),
    [patchActiveProject],
  );

  // Auto EQ, same shape as the watermark flag: the persisted field
  // is optional and the effective value defaults to ON.
  const autoEqEnabled = activeProject?.autoEqEnabled ?? true;

  const setAutoEqEnabled = useCallback(
    (enabled: boolean) => patchActiveProject({ autoEqEnabled: enabled }),
    [patchActiveProject],
  );

  // Mix & Master, same shape as the Auto EQ flag — except the
  // effective value defaults to OFF (Stage 1 is engine-only).
  const mixMasterEnabled = activeProject?.mixMasterEnabled ?? false;

  const setMixMasterEnabled = useCallback(
    (enabled: boolean) => patchActiveProject({ mixMasterEnabled: enabled }),
    [patchActiveProject],
  );

  // Mix & Master stage settings (Stage 2): the resolved set for
  // the active project — stored partial values merged over the
  // defaults (both stages ON at 100%). The setter patches the
  // stored object, so a toggle/intensity change re-renders the
  // processed song (the native cache key includes the settings).
  const mixMasterStages = resolveMixMasterStageSettings(activeProject?.mixMasterStages);

  const setMixMasterStages = useCallback(
    (patch: Partial<MixMasterStageSettings>) => {
      const current = resolveMixMasterStageSettings(activeProjectRef.current?.mixMasterStages);
      patchActiveProject({ mixMasterStages: { ...current, ...patch } });
    },
    [patchActiveProject],
  );

  // Mix & Master Stage 4: the original song this project's track
  // was replaced from ("Use in project"). Null = never replaced.
  const mixMasterSource = activeProject?.mixMasterSource ?? null;

  const applyMixMasterTrack = useCallback(
    (processedUri: string, processedFileName: string) => {
      const current = activeProjectRef.current;
      const track = current?.track;
      if (!track) return;
      patchActiveProject(
        mixMasterUseInProjectPatch(
          track,
          processedUri,
          processedFileName,
          current.mixMasterSource ?? null,
        ),
      );
    },
    [patchActiveProject],
  );

  const restoreMixMasterSource = useCallback(() => {
    const current = activeProjectRef.current;
    const source = current?.mixMasterSource;
    const track = current?.track;
    if (!source || !track) return;
    patchActiveProject(mixMasterRestoreOriginalPatch(source, track.durationSeconds));
  }, [patchActiveProject]);

  // ---- Lyrics (song-frame timed; see src/lib/lyrics.ts) ----
  const lyrics = activeProject?.lyrics ?? null;
  const lyricsEnabled = activeProject?.lyricsEnabled ?? ((activeProject?.lyrics?.lines.length ?? 0) > 0);

  const setLyricsEnabled = useCallback(
    (enabled: boolean) => patchActiveProject({ lyricsEnabled: enabled }),
    [patchActiveProject],
  );

  /** Patch the lyrics object, keeping lines sorted by start frame.
   * Every lyric change also refreshes the song-library entry for
   * the active track, so the fixed lyrics follow the song into
   * future projects (the library's whole point). Event-driven on
   * purpose — no state is ever set from an effect for this. */
  const patchLyrics = useCallback(
    (next: ProjectLyrics | null) => {
      const sorted = next ? { ...next, lines: sortLyricLines(next.lines) } : null;
      patchActiveProject({ lyrics: sorted ?? undefined });
      const track = activeProjectRef.current?.track;
      if (sorted && sorted.lines.length > 0 && track) {
        setSongLibrary((current) => {
          const existing = findSongLibraryEntry(current, track.name, track.durationSeconds);
          if (
            existing &&
            existing.uri === track.uri &&
            JSON.stringify(existing.lyrics) === JSON.stringify(sorted)
          ) {
            return current;
          }
          return upsertSongLibraryEntry(current, {
            name: track.name,
            uri: track.uri,
            durationSeconds: track.durationSeconds,
            lyrics: sorted,
            now: Date.now(),
          });
        });
      }
    },
    [patchActiveProject],
  );

  const setLyrics = useCallback(
    (next: ProjectLyrics | null) => patchLyrics(next),
    [patchLyrics],
  );

  const updateLyricLine = useCallback(
    (lineId: string, patch: Partial<LyricLine>) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      patchLyrics({
        ...current,
        lines: current.lines.map((line) => {
          if (line.id !== lineId) return line;
          const { text: rawText, words: rawWords, ...rest } = patch;
          // Lyric text committed by hand gets the same profanity
          // respelling as detected text (Jaizon's clean versions).
          const text = rawText !== undefined ? respellLyricProfanity(rawText) : undefined;
          const words =
            rawWords !== undefined
              ? rawWords.map((w) => {
                  const respelled = respellLyricProfanity(w.text);
                  return respelled === w.text ? w : { ...w, text: respelled };
                })
              : undefined;
          let next: LyricLine = { ...line, ...rest };
          if (text !== undefined) {
            // A text patch WITH an explicit words patch applies both
            // verbatim (split/merge build their words themselves);
            // a text patch alone runs the redistribution rule (same
            // word count keeps the timings, different count drops).
            next = words !== undefined ? { ...next, text, words } : retimeLineWordsForText(next, text);
          } else if (words !== undefined) {
            next = { ...next, words };
          }
          // Frame sanity: a line always spans at least one frame.
          return { ...next, endFrame: Math.max(next.endFrame, next.startFrame + 1) };
        }),
      });
    },
    [patchLyrics],
  );

  const addLyricLine = useCallback(
    (line: LyricLine) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      const text = respellLyricProfanity(line.text);
      const words = line.words?.map((w) => {
        const respelled = respellLyricProfanity(w.text);
        return respelled === w.text ? w : { ...w, text: respelled };
      });
      patchLyrics({
        ...current,
        lines: [...current.lines, { ...line, text, ...(words ? { words } : {}) }],
      });
    },
    [patchLyrics],
  );

  const deleteLyricLine = useCallback(
    (lineId: string) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      patchLyrics({ ...current, lines: current.lines.filter((l) => l.id !== lineId) });
    },
    [patchLyrics],
  );

  const setLyricStyle = useCallback(
    (patch: Partial<LyricStyle>) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      patchLyrics({ ...current, style: { ...current.style, ...patch } });
    },
    [patchLyrics],
  );

  const shiftAllLyrics = useCallback(
    (frames: number) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current || frames === 0) return;
      patchLyrics({ ...current, lines: shiftLyricLines(current.lines, frames) });
    },
    [patchLyrics],
  );

  /** Toggle one id in a favorites list (add if absent, remove if present). */
  const toggleFavoriteLyricFont = useCallback(
    (fontId: string) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      const favs = current.favoriteFontIds ?? [];
      patchLyrics({
        ...current,
        favoriteFontIds: favs.includes(fontId) ? favs.filter((f) => f !== fontId) : [...favs, fontId],
      });
    },
    [patchLyrics],
  );

  const toggleFavoriteLyricAnimation = useCallback(
    (animationId: string) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      const favs = current.favoriteAnimationIds ?? [];
      patchLyrics({
        ...current,
        favoriteAnimationIds: favs.includes(animationId)
          ? favs.filter((f) => f !== animationId)
          : [...favs, animationId],
      });
    },
    [patchLyrics],
  );

  const setLyricTemplate = useCallback(
    (templateId: string | null) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      if (templateId === null) {
        const { templateId: _old, ...rest } = current;
        patchLyrics(rest);
        return;
      }
      const template = lyricTemplateById(templateId);
      if (!template) return;
      patchLyrics({ ...current, templateId, style: { ...current.style, ...template.style } });
    },
    [patchLyrics],
  );

  const toggleFavoriteLyricTemplate = useCallback(
    (templateId: string) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      const favs = current.favoriteTemplateIds ?? [];
      patchLyrics({
        ...current,
        favoriteTemplateIds: favs.includes(templateId)
          ? favs.filter((f) => f !== templateId)
          : [...favs, templateId],
      });
    },
    [patchLyrics],
  );

  // ---- Lyric fine offset + song library ----
  const lyricsOffsetFrames = activeProject?.lyrics?.offsetFrames ?? 0;

  const setLyricsOffset = useCallback(
    (frames: number) => {
      const current = activeProjectRef.current?.lyrics;
      if (!current) return;
      const clamped = Math.max(-90, Math.min(90, Math.round(frames)));
      patchLyrics({ ...current, offsetFrames: clamped });
    },
    [patchLyrics],
  );

  const applyLibrarySong = useCallback(
    (entry: SongLibraryEntry) => {
      setTrack({
        uri: entry.uri,
        name: entry.name,
        ...(entry.durationSeconds !== undefined ? { durationSeconds: entry.durationSeconds } : {}),
      });
      patchActiveProject({ lyrics: entry.lyrics, lyricsEnabled: true });
    },
    [patchActiveProject, setTrack],
  );

  const deleteSongLibraryEntry = useCallback((key: string) => {
    setSongLibrary((current) => removeSongLibraryEntry(current, key));
  }, []);

  // A known song brings its lyrics back: when the active project's
  // track matches a library entry and the project has no lyrics of
  // its own yet, attach the saved ones. Runs after setTrack (which
  // clears lyrics for the new song) and on project switches. The
  // patch lands through an async boundary, mirroring hydration —
  // state is never set synchronously from an effect here.
  useEffect(() => {
    if (!hydrated) return;
    const project = activeProject;
    if (!project?.track || project.lyrics !== undefined) return;
    const entry = findSongLibraryEntry(songLibrary, project.track.name, project.track.durationSeconds);
    if (!entry) return;
    let alive = true;
    void (async () => {
      if (alive) patchActiveProject({ lyrics: entry.lyrics, lyricsEnabled: true });
    })();
    return () => {
      alive = false;
    };
  }, [hydrated, activeProject, songLibrary, patchActiveProject]);

  // ---- Video look (per-project grade; see src/lib/looks.ts) ----
  // The EFFECTIVE look is exposed (stored value wins, otherwise
  // Original — no grade) so the Editor and Export always agree;
  // writes go through patchActiveProject like every creative field,
  // and — unlike lyrics — a track change does NOT clear it.
  const look = useMemo(() => effectiveLook(activeProject), [activeProject]);

  const setProjectLook = useCallback(
    (next: ProjectLook) => patchActiveProject({ look: next }),
    [patchActiveProject],
  );

  const addTake = useCallback(
    (take: Take) => {
      const current = activeProjectRef.current;
      if (!current) return;
      // Stable "Take N" numbering: assign the next sequence number so
      // deleting a take never renumbers the survivors.
      const withSeq: Take =
        take.seq !== undefined
          ? take
          : { ...take, seq: current.takes.reduce((max, t) => Math.max(max, t.seq ?? 0), 0) + 1 };
      patchActiveProject({ takes: [withSeq, ...current.takes] });
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
    },
    [patchActiveProject],
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
      markProjectExported,
      track,
      takes,
      edl,
      setEdl,
      applyEdl,
      setTrack,
      setTrackDuration,
      trackRegion,
      setTrackRegion,
      addTake,
      removeTake,
      updateTake,
      trackSections,
      setTrackSections,
      shuffleFrequency,
      setShuffleFrequency,
      watermarkEnabled,
      setWatermarkEnabled,
      autoEqEnabled,
      setAutoEqEnabled,
      mixMasterEnabled,
      setMixMasterEnabled,
      mixMasterStages,
      setMixMasterStages,
      mixMasterSource,
      applyMixMasterTrack,
      restoreMixMasterSource,
      lyrics,
      lyricsEnabled,
      setLyricsEnabled,
      setLyrics,
      updateLyricLine,
      addLyricLine,
      deleteLyricLine,
      setLyricStyle,
      toggleFavoriteLyricFont,
      toggleFavoriteLyricAnimation,
      setLyricTemplate,
      toggleFavoriteLyricTemplate,
      shiftAllLyrics,
      lyricsOffsetFrames,
      setLyricsOffset,
      songLibrary,
      applyLibrarySong,
      deleteSongLibraryEntry,
      look,
      setProjectLook,
      resolution,
      setResolution,
      frameRate,
      setFrameRate,
      captureQuality,
      setCaptureQuality,
      stabilization,
      setStabilization,
      lockExposureWhileRecording,
      setLockExposureWhileRecording,
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
      exportTargetSizeMB,
      setExportTargetSizeMB,
      autoVolume,
      setAutoVolume,
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
      markProjectExported,
      track,
      takes,
      edl,
      setEdl,
      applyEdl,
      setTrack,
      setTrackDuration,
      trackRegion,
      setTrackRegion,
      addTake,
      removeTake,
      updateTake,
      trackSections,
      shuffleFrequency,
      setShuffleFrequency,
      watermarkEnabled,
      setWatermarkEnabled,
      autoEqEnabled,
      setAutoEqEnabled,
      mixMasterEnabled,
      setMixMasterEnabled,
      mixMasterStages,
      setMixMasterStages,
      mixMasterSource,
      applyMixMasterTrack,
      restoreMixMasterSource,
      lyrics,
      lyricsEnabled,
      setLyricsEnabled,
      setLyrics,
      updateLyricLine,
      addLyricLine,
      deleteLyricLine,
      setLyricStyle,
      toggleFavoriteLyricFont,
      toggleFavoriteLyricAnimation,
      setLyricTemplate,
      toggleFavoriteLyricTemplate,
      shiftAllLyrics,
      lyricsOffsetFrames,
      setLyricsOffset,
      songLibrary,
      applyLibrarySong,
      deleteSongLibraryEntry,
      look,
      setProjectLook,
      resolution,
      frameRate,
      captureQuality,
      stabilization,
      lockExposureWhileRecording,
      gridOverlay,
      levelGuide,
      audioOffsetMs,
      setAudioOffsetMs,
      countInBeats,
      metronome,
      autosave,
      exportQuality,
      exportTargetSizeMB,
      autoVolume,
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
