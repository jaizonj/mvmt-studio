import { Image } from 'expo-image';
import type { VideoThumbnail } from 'expo-video';
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from 'react';
import {
  PanResponder,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
  type ScrollViewInstance,
} from 'react-native';

import { getCachedThumbnail, loadThumbnails } from '../lib/thumbnails';
import { colors, formatTime, radius, spacing, type as typeScale } from '../theme';

export interface TimelineStripClip {
  id: string;
  /** Display label, e.g. "Take 2". */
  label: string;
  /** Played length of this clip in the cut, seconds. */
  lengthSeconds: number;
  /** Source video for filmstrip thumbnails. */
  sourceUri?: string;
  /** Where this clip starts inside its source video, seconds. */
  sourceStartSeconds?: number;
}

export interface TimelineTrimDragEvent {
  clipId: string;
  edge: 'start' | 'end';
  /** Cumulative horizontal drag distance since the grab, in seconds (dx / pxPerSecond). */
  deltaSeconds: number;
  phase: 'move' | 'end';
}

export type TimelineScrubPhase = 'move' | 'end';

/** Default timeline scale — CapCut-like: fixed pixels per second, scrollable. */
const DEFAULT_PX_PER_SEC = 30;
const STRIP_HEIGHT = 58;
const TILE_WIDTH = 34;
/** Trim-handle grab width (the documented 44pt exception — stepper alternatives exist). */
const HANDLE_WIDTH = 28;
const RULER_HEIGHT = 22;

/**
 * Latest interaction inputs for the PanResponders below. They live in
 * a ref (updated from an effect) and are reached ONLY through stable
 * accessor callbacks, so the responder configs created during render
 * never close over the ref itself.
 */
interface InteractionState {
  pxPerSecond: number;
  total: number;
  onTrimDrag?: (event: TimelineTrimDragEvent) => void;
  onScrub?: (seconds: number, phase: TimelineScrubPhase) => void;
}

/**
 * One trim handle on the selected segment's edge. The PanResponder is
 * created once per (clip, edge); it reads the latest callbacks/scale
 * through the shared interaction ref, claims the gesture immediately
 * (these small zones are for trimming, not scrolling), and reports
 * CUMULATIVE drag distance so the editor can diff against the
 * segment's values at grab time.
 */
function TrimHandle({
  clipId,
  edge,
  emitTrimDrag,
  getScale,
  onGestureActiveChange,
}: {
  clipId: string;
  edge: 'start' | 'end';
  emitTrimDrag: (event: TimelineTrimDragEvent) => void;
  getScale: () => number;
  onGestureActiveChange: (active: boolean) => void;
}) {
  const responder = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => true,
        onMoveShouldSetPanResponder: () => true,
        onPanResponderTerminationRequest: () => false,
        onPanResponderGrant: () => {
          onGestureActiveChange(true);
        },
        // gestureState.dx is cumulative since the grab — and it is
        // also handed to release/terminate, so no drag state needs
        // to be stored anywhere.
        onPanResponderMove: (_e, g) => {
          emitTrimDrag({ clipId, edge, deltaSeconds: g.dx / getScale(), phase: 'move' });
        },
        onPanResponderRelease: (_e, g) => {
          emitTrimDrag({ clipId, edge, deltaSeconds: g.dx / getScale(), phase: 'end' });
          onGestureActiveChange(false);
        },
        onPanResponderTerminate: (_e, g) => {
          emitTrimDrag({ clipId, edge, deltaSeconds: g.dx / getScale(), phase: 'end' });
          onGestureActiveChange(false);
        },
      }),
    [clipId, edge, emitTrimDrag, getScale, onGestureActiveChange],
  );
  return (
    <View
      {...responder.panHandlers}
      style={[styles.trimHandle, edge === 'start' ? styles.trimHandleStart : styles.trimHandleEnd]}
      accessible
      accessibilityRole="adjustable"
      accessibilityLabel={`Drag to trim the ${edge} of the selected cut`}>
      <View style={styles.trimGrip} />
    </View>
  );
}

/**
 * The ruler band with the scrub PanResponder. The ruler lives INSIDE
 * the scrolled content, so the touch's locationX is already the
 * absolute timeline coordinate — no scroll-offset correction (that
 * would double-count). Only horizontal-dominant drags are claimed,
 * so vertical page scrolls starting on the ruler still reach the
 * screen's ScrollView.
 */
function RulerBand({
  enabled,
  emitScrub,
  hasScrub,
  onGestureActiveChange,
  children,
}: {
  enabled: boolean;
  emitScrub: (locationX: number, phase: TimelineScrubPhase) => void;
  hasScrub: () => boolean;
  onGestureActiveChange: (active: boolean) => void;
  children: ReactNode;
}) {
  const responder = useMemo(
    () =>
      PanResponder.create({
        onStartShouldSetPanResponder: () => false,
        onMoveShouldSetPanResponder: (_e, g) =>
          hasScrub() && Math.abs(g.dx) > 4 && Math.abs(g.dx) >= Math.abs(g.dy),
        onPanResponderTerminationRequest: () => false,
        onPanResponderGrant: (e) => {
          onGestureActiveChange(true);
          emitScrub(e.nativeEvent.locationX, 'move');
        },
        onPanResponderMove: (e) => {
          emitScrub(e.nativeEvent.locationX, 'move');
        },
        onPanResponderRelease: (e) => {
          emitScrub(e.nativeEvent.locationX, 'end');
          onGestureActiveChange(false);
        },
        onPanResponderTerminate: () => {
          onGestureActiveChange(false);
        },
      }),
    [emitScrub, hasScrub, onGestureActiveChange],
  );
  return (
    <View
      style={styles.ruler}
      {...(enabled ? responder.panHandlers : {})}
      accessible={enabled}
      accessibilityLabel={enabled ? 'Timeline ruler. Drag sideways to scrub the preview.' : undefined}>
      {children}
    </View>
  );
}

/**
 * The cut as a REAL timeline editor (CapCut-style), rebuilt after
 * Jaizon's device test (2026-11-08) — the old proportional bar read as
 * "one big cut" and showed nothing of the actual footage:
 *
 * - Time scale (pxPerSecond, editor-controlled zoom) with a ruler
 *   (tick every second, time labels that adapt to the zoom),
 *   horizontally scrollable for longer cuts.
 * - Every cut is a filmstrip: real frames sampled from its take across
 *   the cut's range (expo-video thumbnails, colour placeholder until
 *   they land), so you can SEE each clip.
 * - A playhead tracks the preview playback and the strip auto-scrolls
 *   to follow it (suspended while the user is scrubbing/trimming);
 *   the currently playing cut is underlined.
 * - Tap a cut to select it. The selected cut grows lime trim handles
 *   on both edges (drag = ripple-aware trim, owned by the editor) and
 *   dragging on the ruler scrubs the preview.
 *
 * Skin (design system §5): graphite only — segment placeholder fills
 * alternate cardPressed/elevated and the filmstrip frames carry the
 * visual variety; selection is a 2pt accent outline; no rainbow
 * segment colours (culled, §6 #8).
 */
export function TimelineStrip({
  clips,
  selectedClipId,
  onSelectClip,
  playbackSeconds,
  isPlaying = false,
  pxPerSecond = DEFAULT_PX_PER_SEC,
  onTrimDrag,
  onScrub,
  scrubbing = false,
  headerAccessory,
}: {
  clips: TimelineStripClip[];
  selectedClipId?: string | null;
  onSelectClip?: (clipId: string) => void;
  /** Preview position inside the edit, seconds — drives the playhead. */
  playbackSeconds?: number | null;
  isPlaying?: boolean;
  /** Timeline zoom: pixels per second (editor steps it through presets). */
  pxPerSecond?: number;
  /** Drag-trim on the selected segment's handles (editor owns semantics). */
  onTrimDrag?: (event: TimelineTrimDragEvent) => void;
  /** Ruler scrub: reports the timeline second under the finger. */
  onScrub?: (seconds: number, phase: TimelineScrubPhase) => void;
  /** True while the editor is scrubbing — suspends playhead auto-follow. */
  scrubbing?: boolean;
  /** Extra controls rendered at the right of the header row (e.g. zoom). */
  headerAccessory?: ReactNode;
}) {
  const scrollRef = useRef<ScrollViewInstance>(null);
  const scrollOffsetRef = useRef(0);
  const viewportWidthRef = useRef(0);
  const [, setThumbTick] = useState(0);
  // True while a handle/ruler gesture owns the touch — the strip's own
  // horizontal scroll must not fight it.
  const [gestureActive, setGestureActive] = useState(false);

  const total = clips.reduce((sum, c) => sum + Math.max(0, c.lengthSeconds), 0);
  const totalWidth = Math.max(1, total * pxPerSecond);

  // Stable channel from the PanResponders to the latest props/total.
  // The responders are created during render, so they may only hold
  // these plain accessor callbacks — the ref itself is read inside
  // them, at gesture time.
  const interactionRef = useRef<InteractionState>({ pxPerSecond, total, onTrimDrag, onScrub });
  useEffect(() => {
    interactionRef.current = { pxPerSecond, total, onTrimDrag, onScrub };
  });
  const getScale = useCallback(() => interactionRef.current.pxPerSecond, []);
  const emitTrimDrag = useCallback((event: TimelineTrimDragEvent) => {
    interactionRef.current.onTrimDrag?.(event);
  }, []);
  const emitScrub = useCallback((locationX: number, phase: TimelineScrubPhase) => {
    const s = interactionRef.current;
    s.onScrub?.(Math.min(Math.max(locationX / s.pxPerSecond, 0), s.total), phase);
  }, []);
  const hasScrub = useCallback(() => !!interactionRef.current.onScrub, []);

  // Filmstrip sample times per clip: one frame per tile across the cut's
  // own range inside its take.
  const samples = useMemo(() => {
    const perClip = new Map<string, number[]>();
    for (const clip of clips) {
      if (!clip.sourceUri || clip.lengthSeconds <= 0) continue;
      const width = Math.max(18, clip.lengthSeconds * pxPerSecond);
      const tiles = Math.max(1, Math.round(width / TILE_WIDTH));
      const start = clip.sourceStartSeconds ?? 0;
      const times: number[] = [];
      for (let i = 0; i < tiles; i++) {
        times.push(Math.round((start + ((i + 0.5) * clip.lengthSeconds) / tiles) * 20) / 20);
      }
      perClip.set(clip.id, times);
    }
    return perClip;
  }, [clips, pxPerSecond]);

  const samplesKey = useMemo(
    () =>
      clips
        .map((c) => `${c.sourceUri ?? ''}@${(samples.get(c.id) ?? []).join(',')}`)
        .join('|'),
    [clips, samples],
  );

  // Generate any thumbnails not already cached, then re-render once.
  useEffect(() => {
    let alive = true;
    const byUri = new Map<string, number[]>();
    for (const clip of clips) {
      if (!clip.sourceUri) continue;
      for (const t of samples.get(clip.id) ?? []) {
        if (getCachedThumbnail(clip.sourceUri, t) === undefined) {
          const list = byUri.get(clip.sourceUri) ?? [];
          list.push(t);
          byUri.set(clip.sourceUri, list);
        }
      }
    }
    if (byUri.size === 0) return;
    Promise.all([...byUri.entries()].map(([uri, times]) => loadThumbnails(uri, times))).then(() => {
      if (alive) setThumbTick((n) => n + 1);
    });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [samplesKey]);

  // Keep the playhead in view while the preview plays — never while
  // the user is scrubbing or dragging a trim handle.
  useEffect(() => {
    if (!isPlaying || playbackSeconds == null || scrubbing || gestureActive) return;
    const x = playbackSeconds * pxPerSecond;
    const offset = scrollOffsetRef.current;
    const viewW = viewportWidthRef.current;
    if (viewW > 0 && (x < offset + 24 || x > offset + viewW - 70)) {
      scrollRef.current?.scrollTo({ x: Math.max(0, x - 56), animated: true });
    }
  }, [playbackSeconds, isPlaying, pxPerSecond, scrubbing, gestureActive]);

  if (clips.length === 0 || total <= 0) return null;

  const playheadX = playbackSeconds != null ? Math.min(Math.max(0, playbackSeconds), total) * pxPerSecond : null;

  // Which cut is under the playhead (for the playing underline).
  let activeClipId: string | null = null;
  if (playbackSeconds != null) {
    let acc = 0;
    for (const clip of clips) {
      const len = Math.max(0, clip.lengthSeconds);
      if (playbackSeconds < acc + len || clip === clips[clips.length - 1]) {
        activeClipId = clip.id;
        break;
      }
      acc += len;
    }
  }

  // Ruler: tick every second; labels every 5s at reading zoom, every
  // 10s when zoomed out so they never collide.
  const labelEvery = pxPerSecond >= 30 ? 5 : 10;
  const rulerTicks = [];
  for (let s = 0; s <= Math.floor(total); s++) {
    rulerTicks.push(
      <View
        key={`tick-${s}`}
        style={[styles.tick, { left: s * pxPerSecond }, s % labelEvery === 0 && styles.tickMajor]}
      />,
    );
    if (s % labelEvery === 0) {
      rulerTicks.push(
        <Text key={`label-${s}`} style={[styles.rulerLabel, { left: s * pxPerSecond + 3 }]}>
          {formatTime(s)}
        </Text>,
      );
    }
  }

  return (
    <View>
      <View style={styles.headerRow}>
        <Text style={styles.title}>Your cut</Text>
        <View style={styles.headerRight}>
          <Text style={styles.total}>
            {playbackSeconds != null
              ? `${formatTime(Math.min(playbackSeconds, total))} / ${formatTime(total)} · ${clips.length} cuts`
              : `${clips.length} cuts · ${formatTime(total)}`}
          </Text>
          {headerAccessory}
        </View>
      </View>
      <View style={styles.editor}>
        <ScrollView
          ref={scrollRef}
          horizontal
          showsHorizontalScrollIndicator={false}
          scrollEnabled={!gestureActive}
          scrollEventThrottle={100}
          onScroll={(e) => {
            scrollOffsetRef.current = e.nativeEvent.contentOffset.x;
          }}
          onLayout={(e) => {
            viewportWidthRef.current = e.nativeEvent.layout.width;
          }}>
          <View style={{ width: totalWidth }}>
            <RulerBand
              enabled={!!onScrub}
              emitScrub={emitScrub}
              hasScrub={hasScrub}
              onGestureActiveChange={setGestureActive}>
              {rulerTicks}
            </RulerBand>
            <View style={styles.stripRow}>
              {clips.map((clip, i) => {
                const width = Math.max(18, clip.lengthSeconds * pxPerSecond);
                const selected = selectedClipId === clip.id;
                const active = activeClipId === clip.id && playbackSeconds != null;
                const times = samples.get(clip.id) ?? [];
                const tileWidth = width / Math.max(1, times.length || 1);
                return (
                  <View
                    key={clip.id}
                    style={[
                      styles.segment,
                      { width, backgroundColor: i % 2 === 0 ? colors.cardPressed : colors.elevated },
                      i > 0 && styles.segmentDivider,
                      active && styles.segmentActive,
                      selected && styles.segmentSelected,
                    ]}>
                    <Pressable
                      style={styles.segmentPress}
                      onPress={() => onSelectClip?.(clip.id)}
                      accessibilityRole="button"
                      accessibilityState={{ selected }}
                      accessibilityLabel={`${clip.label}, cut ${i + 1} of ${clips.length}, ${formatTime(clip.lengthSeconds)}. Tap to select this cut.`}>
                      <View style={styles.filmstrip}>
                        {times.length > 0
                          ? times.map((t, ti) => {
                              const thumb: VideoThumbnail | null | undefined = clip.sourceUri
                                ? getCachedThumbnail(clip.sourceUri, t)
                                : null;
                              return thumb ? (
                                <Image
                                  key={ti}
                                  source={thumb}
                                  style={{ width: tileWidth, height: STRIP_HEIGHT }}
                                  contentFit="cover"
                                />
                              ) : (
                                <View key={ti} style={{ width: tileWidth, height: STRIP_HEIGHT }} />
                              );
                            })
                          : null}
                      </View>
                      <View style={styles.labelChip}>
                        <Text style={styles.labelChipText} numberOfLines={1}>
                          {clip.label}
                        </Text>
                      </View>
                    </Pressable>
                    {selected && onTrimDrag ? (
                      <>
                        <TrimHandle
                          clipId={clip.id}
                          edge="start"
                          emitTrimDrag={emitTrimDrag}
                          getScale={getScale}
                          onGestureActiveChange={setGestureActive}
                        />
                        <TrimHandle
                          clipId={clip.id}
                          edge="end"
                          emitTrimDrag={emitTrimDrag}
                          getScale={getScale}
                          onGestureActiveChange={setGestureActive}
                        />
                      </>
                    ) : null}
                  </View>
                );
              })}
            </View>
            {playheadX != null ? (
              <View style={[styles.playhead, { left: playheadX }]} pointerEvents="none">
                <View style={styles.playheadKnob} />
              </View>
            ) : null}
          </View>
        </ScrollView>
      </View>
      {onSelectClip ? (
        <Text style={styles.hint}>
          {onTrimDrag
            ? 'Tap a cut to select it · drag the ends of a selected cut to trim · drag the ruler to scrub'
            : 'Tap a cut to switch which take it uses'}
        </Text>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.sm,
  },
  headerRight: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  title: { ...typeScale.headline, color: colors.label },
  total: { ...typeScale.footnote, color: colors.labelSecondary, fontVariant: ['tabular-nums'] },
  editor: {
    backgroundColor: colors.card,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.separator,
    overflow: 'hidden',
    paddingVertical: 6,
  },
  ruler: { height: RULER_HEIGHT, position: 'relative', marginBottom: 2 },
  tick: {
    position: 'absolute',
    bottom: 0,
    width: 1,
    height: 4,
    backgroundColor: colors.separator,
  },
  tickMajor: { height: 7, backgroundColor: colors.labelTertiary },
  rulerLabel: {
    position: 'absolute',
    top: 0,
    color: colors.labelTertiary,
    fontSize: 9,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
  stripRow: { flexDirection: 'row', height: STRIP_HEIGHT },
  segment: {
    height: STRIP_HEIGHT,
    borderRadius: 4,
    overflow: 'hidden',
    position: 'relative',
  },
  segmentPress: { flex: 1 },
  // Inside the segment's width (not a margin) so cut boundaries stay
  // exactly on the ruler's time scale and the playhead lines up.
  segmentDivider: { borderLeftWidth: 2, borderLeftColor: colors.base },
  segmentActive: { borderBottomWidth: 3, borderBottomColor: colors.accent },
  segmentSelected: { borderWidth: 2, borderColor: colors.accent },
  trimHandle: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    width: HANDLE_WIDTH,
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 2,
  },
  trimHandleStart: { left: 0 },
  trimHandleEnd: { right: 0 },
  trimGrip: {
    width: 6,
    height: 30,
    borderRadius: 3,
    backgroundColor: colors.accent,
    borderWidth: 1,
    borderColor: 'rgba(0,0,0,0.35)',
  },
  filmstrip: { flexDirection: 'row', position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
  labelChip: {
    position: 'absolute',
    left: 3,
    bottom: 3,
    backgroundColor: colors.material,
    borderRadius: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
  },
  labelChipText: { color: colors.label, fontSize: 9, fontWeight: '700' },
  playhead: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    width: 2,
    marginLeft: -1,
    backgroundColor: colors.label,
    shadowColor: '#000',
    shadowOpacity: 0.5,
    shadowRadius: 2,
  },
  playheadKnob: {
    position: 'absolute',
    top: -1,
    left: -4,
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: colors.label,
  },
  hint: { ...typeScale.caption, color: colors.labelSecondary, marginTop: spacing.sm },
});
