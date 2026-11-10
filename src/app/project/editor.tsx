import { Ionicons } from '@expo/vector-icons';
import { Image } from 'expo-image';
import { LinearGradient } from 'expo-linear-gradient';
import { router } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Animated,
  Easing,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  View,
  useWindowDimensions,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { LyricsOverlay } from '../../components/LyricsOverlay';
import { LyricsPanel } from '../../components/LyricsPanel';
import { NativePreview, type NativePreviewHandle } from '../../components/NativePreview';
import { useLyricFonts } from '../../components/useLyricFonts';
import { WatermarkOverlay } from '../../components/WatermarkOverlay';
import { SegmentedControl } from '../../components/SegmentedControl';
import {
  TimelineStrip,
  type TimelineStripClip,
  type TimelineTrimDragEvent,
} from '../../components/TimelineStrip';
import { effectiveRegion, estimateTakeEnergies } from '../../lib/analysis';
import { inspectAsset, isCompositorAvailable, type PreviewStatus } from '../../lib/compositor';
import {
  DEFAULT_FPS,
  edlDurationSeconds,
  canvasForTakes,
  edlToCompositeRequest,
  edlWithTakeCanvas,
  framesToSeconds,
  layoutSegments,
  secondsToFrames,
  sourceFrameForTimelineFrame,
  takeSyncOffsetSeconds,
  validateEdl,
  type AssetMeasure,
  type Edl,
  type EdlSegment,
} from '../../lib/edl';
import { buildCompositeLyrics } from '../../lib/lyrics';
import { getCachedThumbnail, loadThumbnails } from '../../lib/thumbnails';
import { buildEdlFromShuffle, validateAgainstAssets } from '../../lib/shuffleEdl';
import { useStudio } from '../../store/StudioContext';
import type { ShuffleFrequency, Take } from '../../types';
import { colors, formatTime, radius, spacing, type as typeScale } from '../../theme';

/**
 * Editor — workspace stage 3, the centrepiece (design system §3.5).
 *
 * One screen, ONE timeline: the canonical frame-based EDL
 * (src/lib/edl.ts). The timeline is directly
 * interactive by default — tap a cut to select it, swap its take from
 * the chips below, drag its ends to trim; the shuffle (the
 * shuffle→EDL bridge) lives in its own section underneath. Every
 * mutation flows through `commitEdl`, which re-anchors (see the sync
 * invariant there), validates against measured asset durations and
 * records an undo snapshot.
 *
 * Layout (Edit mode): a FIXED header, then ONE vertical ScrollView
 * holding the preview, transport, timeline, selected-cut panel and
 * shuffle section — every control is reachable by scrolling on any
 * iPhone (the previous fixed-flex layout clipped the lower panels on
 * real devices).
 *
 * 2026-11-09 (Jaizon): the screen has two faces over the same logic.
 * It OPENS on a clean shuffle landing — a preview of the
 * already-shuffled cut plus Reshuffle / Edit / Continue and nothing
 * else (auto-shuffling on open when no edit exists yet) — and the
 * editing layout above is Edit mode, one tap deeper. The watermark
 * toggle sits at the bottom of Edit mode's scroll content.
 *
 * Preview is the native composition (NativePreview) built from the
 * SAME edlToCompositeRequest the exporter consumes — what plays here
 * is what exports. Progress/status events are display-only; JS never
 * drives playback. No scores are ever shown: shuffle stays magic.
 */

/** Screen-level EDL history depth (design system Appendix B). */
const HISTORY_CAP = 20;
/** UI floor for a cut's length (design system §3.5) — prevents slivers. */
const MIN_CUT_FRAMES = 3;
/** Where take-chip thumbnails are sampled inside each take. */
const CHIP_THUMB_SECONDS = 0.5;
/** Minimum interval between preview seeks while scrubbing the ruler. */
const SCRUB_SEEK_INTERVAL_MS = 120;

/** A fresh random seed per shuffle tap (successive cuts must differ). */
function randomSeed(): number {
  return (Math.random() * 0xffffffff) >>> 0;
}

/** The layoutSegments input shape for one existing segment. */
function partialOf(s: EdlSegment): { id: string; takeId: string; sourceStartFrame: number; durationFrames: number } {
  return { id: s.id, takeId: s.takeId, sourceStartFrame: s.sourceStartFrame, durationFrames: s.durationFrames };
}

/**
 * The one decorative animation in the product (design system §4): a
 * single lime sweep across the preview frame when a new cut lands,
 * ~800ms, ease-out, never looped.
 */
function SweepOverlay({ width }: { width: number }) {
  const [x] = useState(() => new Animated.Value(-width));
  useEffect(() => {
    const anim = Animated.timing(x, {
      toValue: width,
      duration: 800,
      easing: Easing.out(Easing.cubic),
      useNativeDriver: true,
    });
    anim.start();
    return () => anim.stop();
  }, [width, x]);
  return (
    <Animated.View style={[StyleSheet.absoluteFill, { transform: [{ translateX: x }], opacity: 0.4 }]} pointerEvents="none">
      <LinearGradient
        colors={[...colors.iridescent]}
        start={{ x: 0, y: 0 }}
        end={{ x: 1, y: 0 }}
        style={{ width: Math.max(1, width * 0.9), height: '100%' }}
      />
    </Animated.View>
  );
}

export default function EditorScreen() {
  const studio = useStudio();
  // Keyed remount per project: every piece of screen state below
  // (selection, EDL history, preview state) is per-project, so a
  // project switch starts the workspace clean — no reset effects.
  return <EditorWorkspace key={studio.activeProjectId ?? 'none'} />;
}

function EditorWorkspace() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { activeProject, track, takes, trackSections } = studio;
  const storedEdl = studio.edl;
  const { width: winW, height: winH } = useWindowDimensions();

  // Two faces, one workspace (Jaizon, 2026-11-09): the screen OPENS
  // on the shuffle landing — preview of the already-shuffled cut,
  // Reshuffle, Edit, Continue, nothing else — and the full editing
  // surface lives one tap deeper in 'edit'. All state/logic below is
  // shared; only the presentation branches.
  const [mode, setMode] = useState<'shuffle' | 'edit'>('shuffle');
  const [selectedSegmentId, setSelectedSegmentId] = useState<string | null>(null);
  const [paused, setPaused] = useState(true);
  const [isPlaying, setIsPlaying] = useState(false);
  const [positionSeconds, setPositionSeconds] = useState(0);
  const [previewStatus, setPreviewStatus] = useState<PreviewStatus | null>(null);
  const [previewNonce, setPreviewNonce] = useState(0);
  const [justShuffled, setJustShuffled] = useState(false);
  const [shuffleNote, setShuffleNote] = useState<string | null>(null);
  const [sweepKey, setSweepKey] = useState(0);
  const [undoStack, setUndoStack] = useState<(Edl | null)[]>([]);
  const [redoStack, setRedoStack] = useState<(Edl | null)[]>([]);
  const [, setChipThumbTick] = useState(0);
  const [scrubbing, setScrubbing] = useState(false);
  /** Uncommitted trim-drag result, shown in the timeline only (no
   *  history push, no preview rebuild) until the drag ends. */
  const [draftEdl, setDraftEdl] = useState<Edl | null>(null);

  const previewRef = useRef<NativePreviewHandle>(null);
  const scrubbingRef = useRef(false);
  const lastScrubSeekAtRef = useRef(0);

  const takeIndexById = useMemo(() => {
    const map = new Map<string, number>();
    [...takes].reverse().forEach((t, i) => map.set(t.id, i + 1));
    return map;
  }, [takes]);

  // ---- Measured take durations (native inspectAsset) ----------------
  // The EDL contract: validate against MEASURED durations when the
  // native engine can provide them; JS-recorded durations are the
  // fallback. Measures are cached per file URI for the screen's life.
  const measureCacheRef = useRef(new Map<string, number>());
  const [measureMap, setMeasureMap] = useState<Map<string, number>>(new Map());
  useEffect(() => {
    if (!isCompositorAvailable()) return;
    const missing = takes.filter((t) => !measureCacheRef.current.has(t.uri));
    if (missing.length === 0) return;
    let alive = true;
    void (async () => {
      await Promise.all(
        missing.map(async (t) => {
          try {
            const info = await inspectAsset(t.uri);
            measureCacheRef.current.set(t.uri, secondsToFrames(info.durationSeconds, DEFAULT_FPS));
          } catch {
            measureCacheRef.current.set(t.uri, -1); // unavailable — JS fallback covers this take
          }
        }),
      );
      if (alive) setMeasureMap(new Map(measureCacheRef.current));
    })();
    return () => {
      alive = false;
    };
  }, [takes]);

  /** Native measures, only when EVERY take is covered — partial native
   *  data must never drop segments the JS durations would have kept. */
  const nativeMeasures = useMemo<AssetMeasure[] | null>(() => {
    if (!isCompositorAvailable() || takes.length === 0) return null;
    const out: AssetMeasure[] = [];
    for (const t of takes) {
      const frames = measureMap.get(t.uri);
      if (frames === undefined || frames < 0) return null;
      out.push({ takeId: t.id, durationFrames: frames });
    }
    return out;
  }, [takes, measureMap]);

  const validate = useCallback(
    (candidate: Edl): Edl =>
      nativeMeasures
        ? validateEdl(candidate, nativeMeasures).edl
        : validateAgainstAssets(candidate, takes, candidate.fps).edl,
    [nativeMeasures, takes],
  );

  /** The EDL as shown and edited: the stored edit, validated. */
  const edl = useMemo(() => (storedEdl ? validate(storedEdl) : null), [storedEdl, validate]);
  const hasCut = !!edl && edl.segments.length > 0;
  const totalSeconds = edl ? edlDurationSeconds(edl) : 0;

  // Take-chip thumbnails (one frame per take, via the shared pipeline).
  useEffect(() => {
    let alive = true;
    const missing = takes.filter((t) => getCachedThumbnail(t.uri, CHIP_THUMB_SECONDS) === undefined);
    if (missing.length === 0) return;
    Promise.all(missing.map((t) => loadThumbnails(t.uri, [CHIP_THUMB_SECONDS]))).then(() => {
      if (alive) setChipThumbTick((n) => n + 1);
    });
    return () => {
      alive = false;
    };
  }, [takes]);

  // ---- Sync offsets (the single definition, shared with the bridge) --
  const regionStartSeconds = useMemo(
    () =>
      effectiveRegion(studio.trackRegion, track?.durationSeconds)?.startSeconds ?? studio.trackRegion.startSeconds,
    [studio.trackRegion, track],
  );
  /**
   * Where timeline frame 0 sits inside `take` — delegates to the ONE
   * shared offset (src/lib/edl.ts), the same function the shuffle
   * bridge uses, so the anchor and the bridge can never diverge. It
   * includes the take's manual frame calibration (syncAdjustFrames).
   */
  const offsetForTake = useCallback(
    (take: Take) => takeSyncOffsetSeconds(take, regionStartSeconds, DEFAULT_FPS),
    [regionStartSeconds],
  );

  /**
   * THE SYNC ANCHOR: re-derive every segment's source start from its
   * timeline position via the single shared mapping (segments must
   * already be laid out). A segment therefore always shows its take's
   * performance AT that song position — moving, trimming, splitting,
   * duplicating or reordering cuts can never knock the edit out of
   * sync, and there is deliberately NO per-clip slip/offset control:
   * auto-sync always wins. Segments referencing a missing take pass
   * through untouched (validation drops them).
   */
  const reanchorSegments = useCallback(
    (segments: EdlSegment[], fps: number): EdlSegment[] =>
      segments.map((s) => {
        const take = takes.find((t) => t.id === s.takeId);
        if (!take) return s;
        return {
          ...s,
          sourceStartFrame: Math.max(
            0,
            sourceFrameForTimelineFrame(s.timelineStartFrame, offsetForTake(take), fps),
          ),
        };
      }),
    [takes, offsetForTake],
  );

  // ---- EDL mutation plumbing ----------------------------------------
  /**
   * The ONLY way the EDL changes: snapshot for undo, re-lay out,
   * RE-ANCHOR (the sync invariant above — applied here so EVERY
   * mutation honours it: drag trims and take-switch), validate,
   * store. The anchor is
   * a no-op for fresh shuffle output, which the bridge already builds
   * anchored. Validation may clamp/drop a segment whose anchored
   * source start falls outside its take's measured length — correct
   * and honest: that take has no footage for that song moment.
   */
  const commitEdl = (next: Edl) => {
    setUndoStack((stack) => [...stack.slice(-(HISTORY_CAP - 1)), edl]);
    setRedoStack([]);
    setDraftEdl(null);
    const relaid = layoutSegments(next.segments.map(partialOf), next);
    const anchored: Edl = { ...relaid, segments: reanchorSegments(relaid.segments, relaid.fps) };
    const validated = validate(anchored);
    studio.applyEdl(validated, validated.segments.map((s) => s.takeId));
  };

  const applyHistoryEdl = (target: Edl | null) => {
    if (target) studio.applyEdl(target, target.segments.map((s) => s.takeId));
    else studio.setEdl(null);
    setSelectedSegmentId(null);
    setPaused(true);
    setIsPlaying(false);
    setPositionSeconds(0);
  };

  const handleUndo = () => {
    if (undoStack.length === 0) return;
    const previous = undoStack[undoStack.length - 1];
    setUndoStack((stack) => stack.slice(0, -1));
    setRedoStack((stack) => [...stack.slice(-(HISTORY_CAP - 1)), edl]);
    applyHistoryEdl(previous);
  };

  const handleRedo = () => {
    if (redoStack.length === 0) return;
    const next = redoStack[redoStack.length - 1];
    setRedoStack((stack) => stack.slice(0, -1));
    setUndoStack((stack) => [...stack.slice(-(HISTORY_CAP - 1)), edl]);
    applyHistoryEdl(next);
  };

  const canUndo = undoStack.length > 0;
  const canRedo = redoStack.length > 0;

  // ---- Shuffle ---------------------------------------------------------
  const canShuffle = takes.length >= 2;
  const handleShuffle = () => {
    if (!canShuffle) return;
    const energies = estimateTakeEnergies(takes);
    const { edl: built } = buildEdlFromShuffle({
      sections: trackSections,
      takes: takes.map((t) => ({ ...t, energy: energies.get(t.id) ?? t.energy ?? 0.5 })),
      frequency: studio.shuffleFrequency,
      seed: randomSeed(),
      previousSequence:
        activeProject?.lastShuffleSequence ?? (edl ? edl.segments.map((s) => s.takeId) : undefined),
      regionStartSeconds,
      audioUri: track?.uri ?? null,
      // The cut renders at the takes' own size (4K takes → 4K cut).
      ...(canvasForTakes(takes) ? { canvas: canvasForTakes(takes)! } : {}),
    });
    if (built.segments.length === 0) {
      setShuffleNote("That didn't cut — check the song is loaded, then try again.");
      return;
    }
    commitEdl(built);
    setSelectedSegmentId(null);
    setJustShuffled(true);
    setShuffleNote(null);
    setPositionSeconds(0);
    setPaused(false); // the new cut auto-plays from the top
    setSweepKey((k) => k + 1);
  };

  // ---- Open on a shuffled cut --------------------------------------
  // The shuffle landing must always open on a finished cut (Jaizon,
  // 2026-11-09): when the project has no edit yet, the first shuffle
  // is generated automatically — exactly once per mount, and
  // EditorScreen remounts per project, so the guard is per project.
  // A stored edit is shown as-is; undoing back to no edit must not
  // trigger a surprise re-shuffle, so the guard is consumed either way.
  const autoShuffledRef = useRef(false);
  const handleShuffleRef = useRef(handleShuffle);
  useEffect(() => {
    handleShuffleRef.current = handleShuffle;
  });
  useEffect(() => {
    if (autoShuffledRef.current) return;
    if (storedEdl) {
      autoShuffledRef.current = true;
      return;
    }
    if (takes.length === 0) return; // takes haven't landed yet — wait
    if (!canShuffle) {
      autoShuffledRef.current = true;
      return;
    }
    // Deferred by a frame: generating the cut commits state (local
    // UI state + the store), and doing that synchronously inside the
    // effect would cascade renders on mount. One frame is invisible
    // — the landing still opens on the finished, auto-playing cut.
    // The guard is consumed inside the callback, so if this effect
    // re-runs first (a dep settled), the pending frame is cancelled
    // and a fresh one is scheduled instead of doubling up.
    const frame = requestAnimationFrame(() => {
      autoShuffledRef.current = true;
      handleShuffleRef.current();
    });
    return () => cancelAnimationFrame(frame);
  }, [storedEdl, takes.length, canShuffle]);

  // ---- Selection & take swap ------------------------------------------
  const selected = edl?.segments.find((s) => s.id === selectedSegmentId) ?? null;
  const selectedIndex = selected && edl ? edl.segments.findIndex((s) => s.id === selected.id) : -1;

  const handleSelectClip = (id: string) => {
    const seg = edl?.segments.find((s) => s.id === id);
    // Tapping a cut just selects it (there are no modes) and moves
    // the playhead to its start so the panel and preview agree.
    setSelectedSegmentId(id);
    if (seg && edl) {
      const start = framesToSeconds(seg.timelineStartFrame, edl.fps);
      setPositionSeconds(start);
      previewRef.current?.seek(start);
    }
  };

  const handleSwitchTake = (segment: EdlSegment, take: Take) => {
    if (!edl || take.id === segment.takeId) return;
    // Keep the cut's place and length; recompute where its footage
    // lives inside the new take via the single shared mapping.
    // (commitEdl's sync anchor re-derives the same value — this keeps
    // the intent explicit at the call site.)
    const sourceStartFrame = Math.max(
      0,
      sourceFrameForTimelineFrame(segment.timelineStartFrame, offsetForTake(take), edl.fps),
    );
    commitEdl(
      layoutSegments(
        edl.segments.map((s) =>
          s.id === segment.id ? { ...partialOf(s), takeId: take.id, sourceStartFrame } : partialOf(s),
        ),
        edl,
      ),
    );
  };

  /** Would switching `segment` to `take` start past the take's end? */
  const switchWouldEmpty = (segment: EdlSegment, take: Take): boolean => {
    if (!edl) return false;
    const start = Math.max(0, sourceFrameForTimelineFrame(segment.timelineStartFrame, offsetForTake(take), edl.fps));
    const measured = nativeMeasures?.find((m) => m.takeId === take.id)?.durationFrames;
    const frames = measured ?? secondsToFrames(take.durationSeconds ?? 0, edl.fps);
    return frames > 0 && start >= frames;
  };

  /**
   * Drag-trim from the timeline handles. 'move' events carry the
   * CUMULATIVE drag distance, so each move rebuilds a display-only
   * draft from the committed EDL (frame-quantised, same 3-frame UI
   * floor, re-anchored so the filmstrip shows exactly what
   * will commit) — no history, no preview rebuild. 'end' commits the
   * draft through commitEdl (validate + history + preview rebuild).
   *
   * The END handle trims the selected cut's duration (later cuts
   * ripple via layout). The START handle ripple-trims the BOUNDARY
   * with the previous cut: the boundary follows the finger — the
   * previous cut grows/shrinks by the same amount — because in a
   * packed timeline a cut's start IS the previous cut's end. The
   * first cut starts at frame 0 and has nothing to ripple against,
   * so its start handle is inert by design.
   */
  const handleTrimDrag = (event: TimelineTrimDragEvent) => {
    if (!edl) return;
    if (event.phase === 'end') {
      if (draftEdl) commitEdl(draftEdl);
      setDraftEdl(null);
      return;
    }
    const index = edl.segments.findIndex((s) => s.id === event.clipId);
    if (index === -1) return;
    const segment = edl.segments[index];
    const deltaFrames = Math.round(event.deltaSeconds * edl.fps);
    const partials = edl.segments.map(partialOf);
    if (event.edge === 'end') {
      const durationFrames = Math.max(MIN_CUT_FRAMES, segment.durationFrames + deltaFrames);
      if (durationFrames === segment.durationFrames) {
        setDraftEdl(null);
        return;
      }
      partials[index] = { ...partials[index], durationFrames };
    } else {
      const prev = edl.segments[index - 1];
      if (!prev) {
        setDraftEdl(null);
        return;
      }
      const applied = Math.max(
        -(prev.durationFrames - MIN_CUT_FRAMES),
        Math.min(deltaFrames, segment.durationFrames - MIN_CUT_FRAMES),
      );
      if (applied === 0) {
        setDraftEdl(null);
        return;
      }
      partials[index - 1] = { ...partials[index - 1], durationFrames: prev.durationFrames + applied };
      partials[index] = { ...partials[index], durationFrames: segment.durationFrames - applied };
    }
    const laid = layoutSegments(partials, edl);
    setDraftEdl({ ...laid, segments: reanchorSegments(laid.segments, laid.fps) });
  };

  // ---- Preview ---------------------------------------------------------
  const takeUriById = useCallback((id: string) => takes.find((t) => t.id === id)?.uri, [takes]);

  // Watermark: the flag lives on the project (toggled in Edit mode
  // below) and drives the WatermarkOverlay on the preview frame.
  // The native preview request deliberately carries NO watermark
  // fields: a composition with the animation tool throws when a
  // player item assigns it (Edit crash, 2026-11-09), so previews are
  // built tool-free (forExport: false in the module) and the stamp
  // exists only in the export render and in this screen's overlay.
  // Keeping the fields out of the request also means flipping the
  // toggle never rebuilds the preview.
  const watermarkOn = studio.watermarkEnabled;

  // Lyrics: bundled faces load for the panel's font chips and the
  // overlay. The payload (composition seconds, resolved style) is
  // built ONCE here from the project's song-frame lines — the SAME
  // builder the Export screen feeds the native render. The native
  // preview request itself deliberately carries NO lyrics (like the
  // watermark): the preview draws them through LyricsOverlay, so
  // lyric edits never rebuild the composition mid-edit.
  useLyricFonts();
  const regionStartFrame = edl
    ? edl.audio.regionStartFrame
    : secondsToFrames(regionStartSeconds, DEFAULT_FPS);
  const lyricsPayload = useMemo(
    () =>
      studio.lyricsEnabled
        ? buildCompositeLyrics(studio.lyrics, regionStartFrame, DEFAULT_FPS)
        : null,
    [studio.lyrics, studio.lyricsEnabled, regionStartFrame],
  );

  const previewRequest = useMemo(() => {
    if (!edl || edl.segments.length === 0) return null;
    try {
      return edlToCompositeRequest(edlWithTakeCanvas(edl, takes), takeUriById);
    } catch {
      return null;
    }
  }, [edl, takeUriById, takes]);
  const previewKey = previewRequest ? `${JSON.stringify(previewRequest)}#${previewNonce}` : '';

  const handleProgress = useCallback((pos: number, playing: boolean) => {
    // While the user scrubs the ruler, their finger owns the displayed
    // position — engine progress events must not overwrite it.
    if (!scrubbingRef.current) setPositionSeconds(pos);
    setIsPlaying(playing);
  }, []);
  const handleStatus = useCallback((status: PreviewStatus) => {
    setPreviewStatus(status);
    if (status === 'ended') {
      setPaused(true);
      setIsPlaying(false);
    }
  }, []);

  const togglePlay = () => {
    if (!previewRequest) return;
    if (paused && previewStatus === 'ended') previewRef.current?.seek(0);
    setPaused((p) => !p);
  };

  /** Ruler scrub: the finger owns the playhead — display updates are
   *  immediate, preview seeks are throttled (~120ms) during the drag
   *  and land exactly on release. */
  const handleScrub = (seconds: number, phase: 'move' | 'end') => {
    const clamped = Math.max(0, Math.min(seconds, totalSeconds));
    if (phase === 'move') {
      if (!scrubbingRef.current) {
        scrubbingRef.current = true;
        setScrubbing(true);
      }
      setPositionSeconds(clamped);
      const now = Date.now();
      if (now - lastScrubSeekAtRef.current >= SCRUB_SEEK_INTERVAL_MS) {
        lastScrubSeekAtRef.current = now;
        previewRef.current?.seek(clamped);
      }
    } else {
      previewRef.current?.seek(clamped);
      setPositionSeconds(clamped);
      scrubbingRef.current = false;
      setScrubbing(false);
    }
  };

  // Timeline view data, derived from the EDL at the display boundary.
  // During a trim drag the strip shows the DRAFT (so the user sees the
  // trim result live); the preview keeps playing the committed EDL.
  const displayEdl = draftEdl ?? edl;
  const stripClips: TimelineStripClip[] = useMemo(
    () =>
      displayEdl
        ? displayEdl.segments.map((seg) => {
            const take = takes.find((t) => t.id === seg.takeId);
            return {
              id: seg.id,
              label: `Take ${takeIndexById.get(seg.takeId) ?? ''}`,
              lengthSeconds: framesToSeconds(seg.durationFrames, displayEdl.fps),
              sourceUri: take?.uri,
              sourceStartSeconds: framesToSeconds(seg.sourceStartFrame, displayEdl.fps),
            };
          })
        : [],
    [displayEdl, takes, takeIndexById],
  );

  // Prominent cinematic preview (v2): 9:16, just under half the
  // screen height, clamped so it feels standard and easy to watch
  // without crowding out the timeline below — the ScrollView still
  // reaches everything. Width follows the 9:16 height, capped by the
  // screen width minus horizontal padding.
  const previewHeight = Math.round(Math.min(470, Math.max(340, winH * 0.46)));
  const previewWidth = Math.round(Math.min(winW - spacing.xl * 2, previewHeight * (9 / 16)));

  const frequencyCaption =
    studio.shuffleFrequency === 'chill'
      ? 'Longer clips — changes about every 4 seconds.'
      : studio.shuffleFrequency === 'normal'
        ? 'Changes about every 2 seconds.'
        : studio.shuffleFrequency === 'fast'
          ? 'Changes about every second.'
          : 'A new clip almost every beat.';

  const headerSubtitle = hasCut
    ? `${edl!.segments.length} cut${edl!.segments.length === 1 ? '' : 's'} · ${formatTime(totalSeconds)}`
    : track
      ? track.name
      : 'No song loaded';

  // The preview frame + transport, shared verbatim by the shuffle
  // landing and Edit mode — one NativePreview wiring, so both faces
  // of this screen play the identical composition.
  const previewAndTransport = (
    <>
    {/* Preview — the native composition, exactly as it exports. */}
    <View style={styles.previewArea}>
      <View style={[styles.previewFrame, { width: previewWidth, height: previewHeight }]}>
        {previewRequest ? (
          <>
            <NativePreview
              ref={previewRef}
              request={previewRequest}
              requestKey={previewKey}
              paused={paused}
              onProgress={handleProgress}
              onStatus={handleStatus}
              style={StyleSheet.absoluteFill}
            />
            {sweepKey > 0 ? <SweepOverlay key={sweepKey} width={previewWidth} /> : null}
            <WatermarkOverlay enabled={watermarkOn} width={previewWidth} />
            <LyricsOverlay lyrics={lyricsPayload} positionSeconds={positionSeconds} width={previewWidth} />
            {previewStatus === 'loading' ? (
              <View style={styles.previewOverlay} pointerEvents="none">
                <ActivityIndicator color={colors.label} />
                <Text style={styles.previewOverlayText}>Preparing your cut…</Text>
              </View>
            ) : null}
            {previewStatus === 'error' ? (
              <View style={styles.previewOverlay}>
                <Text style={styles.previewOverlayText}>The preview could not be prepared.</Text>
                <Pressable
                  style={styles.retryButton}
                  onPress={() => setPreviewNonce((n) => n + 1)}
                  accessibilityRole="button"
                  accessibilityLabel="Try preparing the preview again">
                  <Text style={styles.retryButtonText}>Try again</Text>
                </Pressable>
              </View>
            ) : null}
          </>
        ) : (
          <View style={styles.previewPlaceholder}>
            <Ionicons name="film-outline" size={34} color={colors.labelSecondary} />
            <Text style={styles.previewPlaceholderText}>No cut yet</Text>
          </View>
        )}
      </View>
    </View>

    {/* Transport — display only; the engine owns playback. */}
    <View style={styles.transport}>
      <Pressable
        onPress={togglePlay}
        disabled={!previewRequest}
        hitSlop={6}
        accessibilityRole="button"
        accessibilityLabel={paused ? 'Play preview' : 'Pause preview'}
        accessibilityState={{ disabled: !previewRequest }}
        style={[styles.playButton, !previewRequest && styles.historyButtonDisabled]}>
        <Ionicons name={paused ? 'play' : 'pause'} size={20} color={colors.label} />
      </Pressable>
      <Text style={styles.transportTime}>{formatTime(Math.min(positionSeconds, totalSeconds))}</Text>
      <View style={styles.progressTrack}>
        <View
          style={[
            styles.progressFill,
            { width: `${totalSeconds > 0 ? Math.min(100, Math.max(0, (positionSeconds / totalSeconds) * 100)) : 0}%` },
          ]}
        />
      </View>
      <Text style={styles.transportTime}>{formatTime(totalSeconds)}</Text>
    </View>
    </>
  );

  // ---- Shuffle landing ----------------------------------------------
  // The screen Record's Next lands on (Jaizon, 2026-11-09): the
  // preview of the already-shuffled cut, Reshuffle, Edit, Continue —
  // and nothing else. No timeline, no selection, no chips.
  if (mode === 'shuffle') {
    return (
      <View style={styles.root}>
        <View style={[styles.header, { paddingTop: insets.top + spacing.md }]}>
          <View style={styles.headerRow}>
            <Pressable
              onPress={() => router.back()}
              hitSlop={10}
              accessibilityRole="button"
              accessibilityLabel="Back to Record"
              style={styles.backButton}>
              <Ionicons name="chevron-back" size={26} color={colors.accent} />
              <Text style={styles.backText}>Record</Text>
            </Pressable>
          </View>
          <Text style={styles.largeTitle} numberOfLines={1}>
            Your cut
          </Text>
          <Text style={styles.headerSubtitle} numberOfLines={1}>
            {headerSubtitle}
          </Text>
        </View>

        {takes.length === 0 ? (
          <View style={[styles.section, styles.emptyCard]}>
            <Ionicons name="videocam-outline" size={30} color={colors.labelSecondary} />
            <Text style={styles.emptyTitle}>Record some takes first</Text>
            <Text style={styles.emptyBody}>
              Your shuffled cut appears here once you have recorded some takes to cut together.
            </Text>
            <Pressable
              style={styles.emptyPrimaryButton}
              onPress={() => router.back()}
              accessibilityRole="button">
              <Ionicons name="videocam-outline" size={18} color={colors.onAccent} />
              <Text style={styles.emptyPrimaryButtonText}>Back to Record</Text>
            </Pressable>
          </View>
        ) : (
          <ScrollView
            style={styles.scroll}
            contentContainerStyle={[
              styles.scrollContent,
              { paddingBottom: Math.max(insets.bottom, spacing.md) + spacing.xl },
            ]}
            showsVerticalScrollIndicator={false}>
            {previewAndTransport}

            <View style={styles.section}>
              <View style={styles.panel}>
                <View style={styles.actionRow}>
                  <Pressable
                    style={[styles.actionButton, !canShuffle && styles.actionButtonDisabled]}
                    onPress={handleShuffle}
                    disabled={!canShuffle}
                    accessibilityRole="button"
                    accessibilityLabel="Reshuffle for a different arrangement">
                    <Ionicons name="shuffle" size={19} color={canShuffle ? colors.label : colors.labelTertiary} />
                    <Text style={[styles.actionButtonText, !canShuffle && styles.actionButtonTextDisabled]}>
                      Reshuffle
                    </Text>
                  </Pressable>
                  <Pressable
                    style={styles.actionButton}
                    onPress={() => setMode('edit')}
                    accessibilityRole="button"
                    accessibilityLabel="Edit the cut">
                    <Ionicons name="create-outline" size={19} color={colors.label} />
                    <Text style={styles.actionButtonText}>Edit</Text>
                  </Pressable>
                </View>
                {!canShuffle ? (
                  <Text style={styles.caption}>
                    Shuffle needs at least 2 takes — record one more to mix between takes.
                  </Text>
                ) : shuffleNote ? (
                  <Text style={styles.caption}>{shuffleNote}</Text>
                ) : null}
                <Pressable
                  style={[styles.continueButton, !hasCut && styles.continueButtonDisabled]}
                  onPress={() => hasCut && router.push('/project/export')}
                  disabled={!hasCut}
                  accessibilityRole="button"
                  accessibilityLabel={hasCut ? 'Continue to Export' : 'Continue — make a cut first'}
                  accessibilityState={{ disabled: !hasCut }}>
                  <Text style={[styles.continueButtonText, !hasCut && styles.continueButtonTextDisabled]}>
                    Continue
                  </Text>
                  <Ionicons name="arrow-forward" size={18} color={hasCut ? colors.onAccent : colors.labelTertiary} />
                </Pressable>
              </View>
            </View>
          </ScrollView>
        )}
      </View>
    );
  }

  return (
    <View style={styles.root}>
      {/* Edit-mode header band: back to the shuffle landing, the
          "Edit" title — plus this stage's undo/redo and the Export
          action. FIXED: it lives outside the scroll area. */}
      <View style={[styles.header, { paddingTop: insets.top + spacing.md }]}>
        <View style={styles.headerRow}>
          <Pressable
            onPress={() => setMode('shuffle')}
            hitSlop={10}
            accessibilityRole="button"
            accessibilityLabel="Back to your cut"
            style={styles.backButton}>
            <Ionicons name="chevron-back" size={26} color={colors.accent} />
            <Text style={styles.backText}>Your cut</Text>
          </Pressable>
          <View style={styles.headerActions}>
            <Pressable
              onPress={handleUndo}
              disabled={!canUndo}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel="Undo"
              accessibilityState={{ disabled: !canUndo }}
              style={[styles.historyButton, !canUndo && styles.historyButtonDisabled]}>
              <Ionicons name="arrow-undo" size={19} color={colors.label} />
            </Pressable>
            <Pressable
              onPress={handleRedo}
              disabled={!canRedo}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel="Redo"
              accessibilityState={{ disabled: !canRedo }}
              style={[styles.historyButton, !canRedo && styles.historyButtonDisabled]}>
              <Ionicons name="arrow-redo" size={19} color={colors.label} />
            </Pressable>
            <Pressable
              onPress={() => hasCut && router.push('/project/export')}
              disabled={!hasCut}
              accessibilityRole="button"
              accessibilityLabel={hasCut ? 'Export your video' : 'Export — make a cut first'}
              accessibilityState={{ disabled: !hasCut }}
              style={[styles.exportButton, !hasCut && styles.exportButtonDisabled]}>
              <Ionicons name="share-outline" size={16} color={hasCut ? colors.onAccent : colors.labelTertiary} />
              <Text style={[styles.exportButtonText, !hasCut && styles.exportButtonTextDisabled]}>Export</Text>
            </Pressable>
          </View>
        </View>
        <View style={styles.titleRow}>
          <Text style={styles.largeTitle} numberOfLines={1}>
            Edit
          </Text>
          {activeProject ? (
            <Pressable
              onPress={() =>
                Alert.prompt(
                  'Rename project',
                  undefined,
                  (name) => studio.renameProject(activeProject.id, name ?? ''),
                  'plain-text',
                  activeProject.name,
                )
              }
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel={`Rename project ${activeProject.name}`}
              style={styles.renameChip}>
              <Text style={styles.renameText} numberOfLines={1}>
                {activeProject.name}
              </Text>
              <Ionicons name="pencil-outline" size={14} color={colors.labelSecondary} />
            </Pressable>
          ) : null}
        </View>
        <Text style={styles.headerSubtitle} numberOfLines={1}>
          {headerSubtitle}
        </Text>
      </View>

      {takes.length === 0 ? (
        <View style={[styles.section, styles.emptyCard]}>
          <Ionicons name="lock-closed-outline" size={30} color={colors.labelSecondary} />
          <Text style={styles.emptyTitle}>Record a take first</Text>
          <Text style={styles.emptyBody}>
            The Editor works on your takes, and there aren&apos;t any yet. Record at least one take — two or more to
            shuffle — and this step unlocks.
          </Text>
          <Pressable
            style={styles.emptyPrimaryButton}
            onPress={() => router.replace('/project/record')}
            accessibilityRole="button">
            <Ionicons name="videocam-outline" size={18} color={colors.onAccent} />
            <Text style={styles.emptyPrimaryButtonText}>Back to Record</Text>
          </Pressable>
        </View>
      ) : (
        <ScrollView
          style={styles.scroll}
          contentContainerStyle={[
            styles.scrollContent,
            { paddingBottom: Math.max(insets.bottom, spacing.md) + spacing.xl },
          ]}
          showsVerticalScrollIndicator={false}>
          {previewAndTransport}

          {/* Timeline — the editing surface, directly interactive:
              tap a cut to select it, drag its ends to trim, drag the
              ruler to scrub the preview. */}
          <View style={styles.section}>
            {hasCut ? (
              <TimelineStrip
                clips={stripClips}
                selectedClipId={selectedSegmentId}
                onSelectClip={handleSelectClip}
                playbackSeconds={positionSeconds}
                isPlaying={isPlaying}
                onTrimDrag={handleTrimDrag}
                onScrub={handleScrub}
                scrubbing={scrubbing}
              />
            ) : (
              <View style={styles.timelineEmpty}>
                <Ionicons name="film-outline" size={30} color={colors.labelSecondary} />
                <Text style={styles.emptyTitle}>No cut yet</Text>
                <Text style={styles.timelineEmptyBody}>
                  Tap Shuffle my cut and MVMT arranges your takes into a cut, right here.
                </Text>
              </View>
            )}
          </View>

          {/* Selected-cut panel — appears when a cut is tapped: swap
              its take from the chips; trimming is drag-only, on the
              timeline itself. */}
          {selected && edl ? (
            <View style={styles.section}>
              <View style={styles.panel}>
                <Text style={styles.cutTitle}>
                  Cut {selectedIndex + 1} · Take {takeIndexById.get(selected.takeId) ?? ''}
                </Text>
                <Text style={styles.caption}>
                  {formatTime(framesToSeconds(selected.timelineStartFrame, edl.fps))} –{' '}
                  {formatTime(
                    framesToSeconds(selected.timelineStartFrame + selected.durationFrames, edl.fps),
                  )}{' '}
                  on the timeline · {formatTime(framesToSeconds(selected.durationFrames, edl.fps))} long
                </Text>
                <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.chipScroll}>
                  <View style={styles.chipRow}>
                    {takes.map((take) => {
                      const isCurrent = selected.takeId === take.id;
                      const disabled = !isCurrent && switchWouldEmpty(selected, take);
                      const thumb = getCachedThumbnail(take.uri, CHIP_THUMB_SECONDS);
                      return (
                        <Pressable
                          key={take.id}
                          disabled={isCurrent || disabled}
                          onPress={() => handleSwitchTake(selected, take)}
                          accessibilityRole="button"
                          accessibilityState={{ selected: isCurrent, disabled: isCurrent || disabled }}
                          accessibilityLabel={
                            disabled
                              ? `Take ${takeIndexById.get(take.id)}, too short for this cut`
                              : `Use take ${takeIndexById.get(take.id)} for this cut`
                          }
                          style={[
                            styles.takeChip,
                            isCurrent && styles.takeChipCurrent,
                            disabled && styles.takeChipDisabled,
                          ]}>
                          {thumb ? (
                            <Image source={thumb} style={styles.takeChipThumb} contentFit="cover" />
                          ) : (
                            <View style={[styles.takeChipThumb, styles.takeChipThumbPlaceholder]} />
                          )}
                          <Text style={styles.takeChipText}>Take {takeIndexById.get(take.id)}</Text>
                          {isCurrent ? <Ionicons name="checkmark" size={14} color={colors.accent} /> : null}
                        </Pressable>
                      );
                    })}
                  </View>
                </ScrollView>
                <Text style={styles.caption}>Drag the ends of a cut to trim it.</Text>
              </View>
            </View>
          ) : null}

          {/* Shuffle — always available below the editing surface. */}
          <View style={styles.section}>
            <View style={styles.panel}>
              <Pressable
                style={[styles.shuffleButton, !canShuffle && styles.shuffleButtonDisabled]}
                onPress={handleShuffle}
                disabled={!canShuffle}
                accessibilityRole="button"
                accessibilityLabel={hasCut ? 'Shuffle again for a different arrangement' : 'Shuffle takes into a cut'}>
                <Ionicons name="shuffle" size={20} color={canShuffle ? colors.onAccent : colors.labelTertiary} />
                <Text style={[styles.shuffleButtonText, !canShuffle && styles.shuffleButtonTextDisabled]}>
                  {hasCut ? 'Try another shuffle' : 'Shuffle my cut'}
                </Text>
              </Pressable>
              {!canShuffle ? (
                <Text style={styles.caption}>
                  Shuffle needs at least 2 takes — record one more to mix between takes.
                </Text>
              ) : shuffleNote ? (
                <Text style={styles.caption}>{shuffleNote}</Text>
              ) : justShuffled && hasCut ? (
                <Text style={styles.caption}>Your cut, remixed.</Text>
              ) : null}
              <Text style={styles.panelLabel}>Cut pace</Text>
              <SegmentedControl
                options={[
                  { value: 'chill' as ShuffleFrequency, label: 'Chill' },
                  { value: 'normal' as ShuffleFrequency, label: 'Normal' },
                  { value: 'fast' as ShuffleFrequency, label: 'Fast' },
                  { value: 'rapid' as ShuffleFrequency, label: 'Rapid' },
                ]}
                value={studio.shuffleFrequency}
                onChange={studio.setShuffleFrequency}
                accessibilityLabel="Cut pace — how often the cut changes"
              />
              <Text style={styles.caption}>{frequencyCaption} Applies to the next shuffle.</Text>
            </View>
          </View>

          {/* Watermark — the MVMT studio logo stamped on the video
              (preview and export alike). A project-level output
              choice, so it lives here in Edit, not in Settings. */}
          <View style={styles.section}>
            <View style={styles.panel}>
              <View style={styles.watermarkRow}>
                <View style={styles.watermarkText}>
                  <Text style={styles.cutTitle}>Watermark</Text>
                  <Text style={styles.caption}>MVMT studio logo on the video</Text>
                </View>
                <Switch
                  value={watermarkOn}
                  onValueChange={studio.setWatermarkEnabled}
                  trackColor={{ true: colors.accent, false: colors.elevated }}
                  thumbColor={watermarkOn ? colors.onAccent : colors.label}
                  accessibilityLabel="Watermark"
                />
              </View>
            </View>
          </View>

          {/* Lyrics — Whisper-detected lines on the song timeline,
              edited line by line, styled CapCut-style. A creative
              tool, so it lives here in Edit (not Settings). */}
          <LyricsPanel
            regionStartFrame={regionStartFrame}
            positionSeconds={positionSeconds}
            isPlaying={!paused}
            onSeek={(seconds) => {
              previewRef.current?.seek(seconds);
              setPositionSeconds(seconds);
            }}
            onPlay={() => setPaused(false)}
            onPause={() => setPaused(true)}
          />
        </ScrollView>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.groupedBackground },
  scroll: { flex: 1 },
  scrollContent: { flexGrow: 1 },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.sm },
  headerRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  backButton: { flexDirection: 'row', alignItems: 'center', marginLeft: -6 },
  backText: { color: colors.accent, fontSize: 17 },
  headerActions: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  historyButton: {
    width: 36,
    height: 36,
    borderRadius: 18,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.card,
  },
  historyButtonDisabled: { opacity: 0.4 },
  exportButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: colors.accent,
    borderRadius: radius.pill,
    paddingHorizontal: 14,
    paddingVertical: 8,
  },
  exportButtonDisabled: { backgroundColor: colors.elevated },
  exportButtonText: { color: colors.onAccent, fontSize: 15, fontWeight: '700' },
  exportButtonTextDisabled: { color: colors.labelTertiary },
  largeTitle: { ...typeScale.largeTitle, color: colors.label, marginTop: spacing.xs },
  titleRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md },
  renameChip: { flexDirection: 'row', alignItems: 'center', gap: 5, flexShrink: 1, paddingVertical: 4 },
  renameText: { ...typeScale.subhead, color: colors.labelSecondary, flexShrink: 1 },
  headerSubtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: 2 },
  section: { paddingHorizontal: spacing.xl, marginTop: spacing.md },
  previewArea: { alignItems: 'center', marginTop: spacing.sm },
  previewFrame: {
    borderRadius: radius.lg,
    overflow: 'hidden',
    backgroundColor: '#000',
    position: 'relative',
  },
  previewPlaceholder: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
  },
  previewPlaceholderText: { ...typeScale.headline, color: colors.labelSecondary },
  previewOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    backgroundColor: 'rgba(0,0,0,0.45)',
  },
  previewOverlayText: { ...typeScale.footnote, color: colors.label, textAlign: 'center', paddingHorizontal: spacing.lg },
  retryButton: {
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingHorizontal: 16,
    paddingVertical: 9,
  },
  retryButtonText: { color: colors.label, fontSize: 15, fontWeight: '600' },
  transport: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingHorizontal: spacing.xl,
    marginTop: spacing.md,
  },
  playButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: colors.card,
    alignItems: 'center',
    justifyContent: 'center',
  },
  transportTime: {
    ...typeScale.footnote,
    color: colors.labelSecondary,
    fontVariant: ['tabular-nums'],
    minWidth: 34,
    textAlign: 'center',
  },
  progressTrack: {
    flex: 1,
    height: 4,
    borderRadius: radius.pill,
    backgroundColor: colors.elevated,
    overflow: 'hidden',
  },
  progressFill: { height: '100%', backgroundColor: colors.label, borderRadius: radius.pill },
  panel: { gap: spacing.sm },
  panelLabel: { ...typeScale.headline, color: colors.label, marginTop: spacing.sm },
  shuffleButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 14,
  },
  shuffleButtonDisabled: { backgroundColor: colors.elevated },
  shuffleButtonText: { color: colors.onAccent, ...typeScale.headline },
  shuffleButtonTextDisabled: { color: colors.labelTertiary },
  caption: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 18 },
  actionRow: { flexDirection: 'row', gap: spacing.sm },
  actionButton: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 7,
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingVertical: 13,
  },
  actionButtonDisabled: { opacity: 0.5 },
  actionButtonText: { color: colors.label, ...typeScale.headline },
  actionButtonTextDisabled: { color: colors.labelTertiary },
  continueButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 14,
  },
  continueButtonDisabled: { backgroundColor: colors.elevated },
  continueButtonText: { color: colors.onAccent, ...typeScale.headline },
  continueButtonTextDisabled: { color: colors.labelTertiary },
  watermarkRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md },
  watermarkText: { flex: 1, gap: 2 },
  cutTitle: { ...typeScale.headline, color: colors.label },
  chipScroll: { marginHorizontal: -spacing.xs },
  chipRow: { flexDirection: 'row', gap: spacing.sm, paddingHorizontal: spacing.xs, paddingVertical: 2 },
  takeChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.separator,
    borderRadius: radius.pill,
    paddingLeft: 5,
    paddingRight: 12,
    paddingVertical: 5,
  },
  takeChipCurrent: { borderColor: colors.accent, borderWidth: 2, backgroundColor: colors.accentDim },
  takeChipDisabled: { opacity: 0.4 },
  takeChipThumb: { width: 40, height: 40, borderRadius: radius.sm },
  takeChipThumbPlaceholder: { backgroundColor: colors.elevated },
  takeChipText: { color: colors.label, fontSize: 14, fontWeight: '600' },
  emptyCard: {
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.xl,
    marginHorizontal: spacing.xl,
    marginTop: spacing.lg,
  },
  emptyTitle: { ...typeScale.headline, color: colors.label },
  emptyBody: { ...typeScale.subhead, color: colors.labelSecondary, lineHeight: 20, textAlign: 'center' },
  emptyPrimaryButton: {
    marginTop: spacing.sm,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    backgroundColor: colors.accent,
    borderRadius: radius.pill,
    paddingHorizontal: 18,
    paddingVertical: 11,
  },
  emptyPrimaryButtonText: { color: colors.onAccent, fontSize: 15, fontWeight: '700' },
  timelineEmpty: { alignItems: 'center', gap: spacing.sm, paddingVertical: spacing.lg },
  timelineEmptyBody: {
    ...typeScale.footnote,
    color: colors.labelSecondary,
    lineHeight: 18,
    textAlign: 'center',
    paddingHorizontal: spacing.xl,
  },
});
