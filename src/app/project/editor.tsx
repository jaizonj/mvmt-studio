import { Ionicons } from '@expo/vector-icons';
import { Image } from 'expo-image';
import { LinearGradient } from 'expo-linear-gradient';
import { router } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  Easing,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
  useWindowDimensions,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { NativePreview, type NativePreviewHandle } from '../../components/NativePreview';
import { SegmentedControl } from '../../components/SegmentedControl';
import { TimelineStrip, type TimelineStripClip } from '../../components/TimelineStrip';
import { effectiveRegion, estimateTakeEnergies } from '../../lib/analysis';
import { inspectAsset, isCompositorAvailable, type PreviewStatus } from '../../lib/compositor';
import {
  DEFAULT_FPS,
  edlDurationSeconds,
  edlToCompositeRequest,
  framesToSeconds,
  layoutSegments,
  secondsToFrames,
  segmentAtFrame,
  sourceFrameForTimelineFrame,
  validateEdl,
  type AssetMeasure,
  type Edl,
  type EdlSegment,
} from '../../lib/edl';
import { getCachedThumbnail, loadThumbnails } from '../../lib/thumbnails';
import { buildEdlFromShuffle, validateAgainstAssets } from '../../lib/shuffleEdl';
import { useStudio } from '../../store/StudioContext';
import type { ShuffleFrequency, Take } from '../../types';
import { colors, formatTime, radius, spacing, type as typeScale } from '../../theme';

/**
 * Editor — workspace stage 3, the centrepiece (design system §3.5).
 *
 * One screen, two modes, ONE timeline: the canonical frame-based EDL
 * (src/lib/edl.ts). Auto Edit shuffles takes into a cut via the
 * shuffle→EDL bridge; Manual Edit trims/splits/swaps/deletes cuts.
 * Every mutation flows through `commitEdl`, which validates against
 * measured asset durations and records an undo snapshot.
 *
 * Preview is the native composition (NativePreview) built from the
 * SAME edlToCompositeRequest the exporter consumes — what plays here
 * is what exports. Progress/status events are display-only; JS never
 * drives playback. No scores are ever shown: shuffle stays magic.
 */

type Mode = 'auto' | 'manual';

/** Screen-level EDL history depth (design system Appendix B). */
const HISTORY_CAP = 20;
/** UI floor for a cut's length (design system §3.5) — prevents slivers. */
const MIN_CUT_FRAMES = 3;
/** Where take-chip thumbnails are sampled inside each take. */
const CHIP_THUMB_SECONDS = 0.5;

let segmentIdCounter = 0;
function nextSegmentId(): string {
  segmentIdCounter += 1;
  return `seg-m${Date.now().toString(36)}-${segmentIdCounter}`;
}

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

function StepperGroup({
  label,
  onStep,
}: {
  label: string;
  onStep: (delta: number) => void;
}) {
  return (
    <View style={styles.stepperGroup}>
      <Text style={styles.stepperLabel}>{label}</Text>
      <View style={styles.stepperRow}>
        {[-5, -1, 1, 5].map((d) => (
          <Pressable
            key={d}
            onPress={() => onStep(d)}
            style={styles.stepperButton}
            accessibilityRole="button"
            accessibilityLabel={`Nudge the ${label.toLowerCase()} of the cut ${d > 0 ? 'later' : 'earlier'} by ${Math.abs(d)}`}>
            <Text style={styles.stepperButtonText}>{d > 0 ? `+${d}` : `${d}`}</Text>
          </Pressable>
        ))}
      </View>
    </View>
  );
}

export default function EditorScreen() {
  const studio = useStudio();
  // Keyed remount per project: every piece of screen state below
  // (mode, selection, EDL history, preview state) is per-project, so a
  // project switch starts the workspace clean — no reset effects.
  return <EditorWorkspace key={studio.activeProjectId ?? 'none'} />;
}

function EditorWorkspace() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { activeProject, track, takes, trackSections } = studio;
  const storedEdl = studio.edl;
  const { width: winW, height: winH } = useWindowDimensions();

  const [mode, setMode] = useState<Mode>('auto');
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

  const previewRef = useRef<NativePreviewHandle>(null);

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

  // ---- EDL mutation plumbing ----------------------------------------
  /** The ONLY way the EDL changes: snapshot for undo, validate, store. */
  const commitEdl = (next: Edl) => {
    setUndoStack((stack) => [...stack.slice(-(HISTORY_CAP - 1)), edl]);
    setRedoStack([]);
    const validated = validate(next);
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

  // ---- Sync offsets (the single definition, shared with the bridge) --
  const regionStartSeconds = useMemo(
    () =>
      effectiveRegion(studio.trackRegion, track?.durationSeconds)?.startSeconds ?? studio.trackRegion.startSeconds,
    [studio.trackRegion, track],
  );
  /** Where timeline frame 0 sits inside `take`, per the bridge's rule. */
  const offsetForTake = useCallback(
    (take: Take) => take.trackOffsetSeconds - regionStartSeconds + (take.syncOffsetSeconds ?? 0),
    [regionStartSeconds],
  );

  // ---- Auto Edit: shuffle --------------------------------------------
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

  // ---- Manual Edit operations ----------------------------------------
  const selected = edl?.segments.find((s) => s.id === selectedSegmentId) ?? null;
  const selectedIndex = selected && edl ? edl.segments.findIndex((s) => s.id === selected.id) : -1;

  const handleSelectClip = (id: string) => {
    const seg = edl?.segments.find((s) => s.id === id);
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

  const handleTrimStart = (segment: EdlSegment, delta: number) => {
    if (!edl) return;
    // +delta: start later (source advances, cut shortens from the left).
    // −delta: start earlier (source rewinds, cut lengthens) — bounded by
    // the source's first frame.
    const applied =
      delta > 0
        ? Math.min(delta, segment.durationFrames - MIN_CUT_FRAMES)
        : -Math.min(-delta, segment.sourceStartFrame);
    if (applied === 0) return;
    commitEdl(
      layoutSegments(
        edl.segments.map((s) =>
          s.id === segment.id
            ? { ...partialOf(s), sourceStartFrame: s.sourceStartFrame + applied, durationFrames: s.durationFrames - applied }
            : partialOf(s),
        ),
        edl,
      ),
    );
  };

  const handleTrimEnd = (segment: EdlSegment, delta: number) => {
    if (!edl) return;
    const durationFrames = Math.max(MIN_CUT_FRAMES, segment.durationFrames + delta);
    if (durationFrames === segment.durationFrames) return;
    commitEdl(
      layoutSegments(
        edl.segments.map((s) => (s.id === segment.id ? { ...partialOf(s), durationFrames } : partialOf(s))),
        edl,
      ),
    );
  };

  const playheadFrame = edl ? Math.round(positionSeconds * edl.fps) : 0;
  const playheadSegment = edl ? segmentAtFrame(edl, playheadFrame) : null;
  const canSplit =
    !!selected &&
    !!edl &&
    playheadSegment?.id === selected.id &&
    playheadFrame - selected.timelineStartFrame >= MIN_CUT_FRAMES &&
    selected.timelineStartFrame + selected.durationFrames - playheadFrame >= MIN_CUT_FRAMES;

  const handleSplit = () => {
    if (!edl || !selected || !canSplit) return;
    const local = playheadFrame - selected.timelineStartFrame;
    const partials: ReturnType<typeof partialOf>[] = [];
    for (const s of edl.segments) {
      if (s.id !== selected.id) {
        partials.push(partialOf(s));
      } else {
        partials.push({ ...partialOf(s), durationFrames: local });
        partials.push({
          id: nextSegmentId(),
          takeId: s.takeId,
          sourceStartFrame: s.sourceStartFrame + local,
          durationFrames: s.durationFrames - local,
        });
      }
    }
    commitEdl(layoutSegments(partials, edl));
  };

  const handleDelete = () => {
    if (!edl || !selected) return;
    commitEdl(layoutSegments(edl.segments.filter((s) => s.id !== selected.id).map(partialOf), edl));
    setSelectedSegmentId(null);
  };

  // ---- Preview ---------------------------------------------------------
  const takeUriById = useCallback((id: string) => takes.find((t) => t.id === id)?.uri, [takes]);
  const previewRequest = useMemo(() => {
    if (!edl || edl.segments.length === 0) return null;
    try {
      return edlToCompositeRequest(edl, takeUriById);
    } catch {
      return null;
    }
  }, [edl, takeUriById]);
  const previewKey = previewRequest ? `${JSON.stringify(previewRequest)}#${previewNonce}` : '';

  const handleProgress = useCallback((pos: number, playing: boolean) => {
    setPositionSeconds(pos);
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

  // Timeline view data, derived from the EDL at the display boundary.
  const stripClips: TimelineStripClip[] = useMemo(
    () =>
      edl
        ? edl.segments.map((seg) => {
            const take = takes.find((t) => t.id === seg.takeId);
            return {
              id: seg.id,
              label: `Take ${takeIndexById.get(seg.takeId) ?? ''}`,
              lengthSeconds: framesToSeconds(seg.durationFrames, edl.fps),
              sourceUri: take?.uri,
              sourceStartSeconds: framesToSeconds(seg.sourceStartFrame, edl.fps),
            };
          })
        : [],
    [edl, takes, takeIndexById],
  );

  // Preview frame size: 9:16, as large as the width allows, capped so
  // the whole workspace fits without scrolling (design system §7 —
  // the preview shrinks first).
  const previewHeight = Math.round(
    Math.min(452, Math.max(190, winH - 536), (winW - spacing.xl * 2) * (16 / 9)),
  );
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

  return (
    <View style={styles.root}>
      {/* Header band (design system §2.3): back, title, subtitle —
          plus this stage's undo/redo and the Export action. */}
      <View style={[styles.header, { paddingTop: insets.top + spacing.md }]}>
        <View style={styles.headerRow}>
          <Pressable
            onPress={() => router.back()}
            hitSlop={10}
            accessibilityRole="button"
            accessibilityLabel="Back to Takes"
            style={styles.backButton}>
            <Ionicons name="chevron-back" size={26} color={colors.accent} />
            <Text style={styles.backText}>Takes</Text>
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
        <Text style={styles.largeTitle}>Editor</Text>
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

          {/* Mode switch — never alters the cut, selection or playhead. */}
          <View style={styles.section}>
            <SegmentedControl
              options={[
                { value: 'auto' as Mode, label: 'Auto Edit' },
                { value: 'manual' as Mode, label: 'Manual Edit' },
              ]}
              value={mode}
              onChange={setMode}
              accessibilityLabel="Editor mode"
            />
          </View>

          {/* Mode panel */}
          <View style={styles.section}>
            {mode === 'auto' ? (
              <View style={styles.panel}>
                <Pressable
                  style={[styles.shuffleButton, !canShuffle && styles.shuffleButtonDisabled]}
                  onPress={handleShuffle}
                  disabled={!canShuffle}
                  accessibilityRole="button"
                  accessibilityLabel={hasCut ? 'Shuffle again for a different arrangement' : 'Shuffle takes into a cut'}>
                  <Ionicons name="shuffle" size={20} color={canShuffle ? colors.onAccent : colors.labelTertiary} />
                  <Text style={[styles.shuffleButtonText, !canShuffle && styles.shuffleButtonTextDisabled]}>
                    {hasCut ? 'Try another' : 'Shuffle my cut'}
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
                {hasCut ? (
                  <Text style={styles.caption}>
                    Not feeling a cut? Tap a cut below to swap its take, or switch to Manual Edit.
                  </Text>
                ) : null}
              </View>
            ) : (
              <View style={styles.panel}>
                {!edl || !hasCut ? (
                  <Text style={styles.manualHint}>Shuffle first, then fine-tune here.</Text>
                ) : selected ? (
                  <>
                    <View style={styles.cutHeaderRow}>
                      <Text style={styles.cutTitle}>
                        Cut {selectedIndex + 1} of {edl.segments.length}
                        <Text style={styles.cutLength}> · {formatTime(framesToSeconds(selected.durationFrames, edl.fps))}</Text>
                      </Text>
                      <View style={styles.cutActions}>
                        <Pressable
                          onPress={handleSplit}
                          disabled={!canSplit}
                          hitSlop={6}
                          accessibilityRole="button"
                          accessibilityLabel="Split this cut at the playhead"
                          accessibilityState={{ disabled: !canSplit }}
                          style={[styles.splitButton, !canSplit && styles.historyButtonDisabled]}>
                          <Ionicons name="cut-outline" size={15} color={colors.label} />
                          <Text style={styles.splitButtonText}>Split</Text>
                        </Pressable>
                        <Pressable
                          onPress={handleDelete}
                          hitSlop={6}
                          accessibilityRole="button"
                          accessibilityLabel="Delete this cut"
                          style={styles.deleteButton}>
                          <Ionicons name="trash-outline" size={15} color={colors.danger} />
                          <Text style={styles.deleteButtonText}>Delete</Text>
                        </Pressable>
                      </View>
                    </View>
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
                    {takes.some((t) => selected.takeId !== t.id && switchWouldEmpty(selected, t)) ? (
                      <Text style={styles.caption}>A take that is too short for this cut can&apos;t be used here.</Text>
                    ) : null}
                    <View style={styles.trimRow}>
                      <StepperGroup label="Start" onStep={(d) => handleTrimStart(selected, d)} />
                      <StepperGroup label="End" onStep={(d) => handleTrimEnd(selected, d)} />
                    </View>
                    <Text style={styles.caption}>
                      Starts {formatTime(framesToSeconds(Math.max(0, selected.sourceStartFrame), edl.fps))} into Take{' '}
                      {takeIndexById.get(selected.takeId) ?? ''} ·{' '}
                      {formatTime(framesToSeconds(selected.durationFrames, edl.fps))} long
                    </Text>
                  </>
                ) : (
                  <Text style={styles.manualHint}>
                    Tap a cut in the timeline to swap its take, trim it, split it at the playhead, or remove it.
                  </Text>
                )}
              </View>
            )}
          </View>

          <View style={styles.spacer} />

          {/* Timeline — visible in both modes (design system §3.5). */}
          <View style={[styles.section, { paddingBottom: Math.max(insets.bottom, spacing.md) }]}>
            {hasCut ? (
              <TimelineStrip
                clips={stripClips}
                selectedClipId={selectedSegmentId}
                onSelectClip={handleSelectClip}
                playbackSeconds={positionSeconds}
                isPlaying={isPlaying}
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
        </>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.groupedBackground },
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
  headerSubtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: 2 },
  section: { paddingHorizontal: spacing.xl, marginTop: spacing.md },
  spacer: { flex: 1, minHeight: spacing.sm },
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
  manualHint: { ...typeScale.subhead, color: colors.labelSecondary, lineHeight: 21 },
  cutHeaderRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.sm },
  cutTitle: { ...typeScale.headline, color: colors.label, flexShrink: 1 },
  cutLength: { ...typeScale.subhead, color: colors.labelSecondary, fontWeight: '400' },
  cutActions: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  splitButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    backgroundColor: colors.card,
    borderRadius: radius.pill,
    paddingHorizontal: 12,
    paddingVertical: 7,
  },
  splitButtonText: { color: colors.label, fontSize: 13, fontWeight: '600' },
  deleteButton: { flexDirection: 'row', alignItems: 'center', gap: 5, paddingHorizontal: 6, paddingVertical: 7 },
  deleteButtonText: { color: colors.danger, fontSize: 13, fontWeight: '600' },
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
  trimRow: { flexDirection: 'row', gap: spacing.xl, flexWrap: 'wrap' },
  stepperGroup: { gap: 6 },
  stepperLabel: { ...typeScale.caption, color: colors.labelSecondary, letterSpacing: 0.6 },
  stepperRow: { flexDirection: 'row', gap: 5 },
  stepperButton: {
    backgroundColor: colors.card,
    borderRadius: radius.sm,
    minWidth: 38,
    height: 34,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 6,
  },
  stepperButtonText: { color: colors.label, fontSize: 13, fontWeight: '700', fontVariant: ['tabular-nums'] },
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
