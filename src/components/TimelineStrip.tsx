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
  /** Played length of this clip in the cut, seconds — the TIMELINE
   *  length. A slowed clip is wider here (it occupies more of the
   *  cut); its source length is `lengthSeconds × speed`. */
  lengthSeconds: number;
  /** Playback rate of the clip's video (0.25–2, default 1). Used
   *  only to map filmstrip frames into source time and to show the
   *  speed badge; the width above already carries the timeline. */
  speed?: number;
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

/**
 * The one timeline scale — fixed, zoomed-in by default (simplification
 * pass v2): no zoom controls anywhere; 60 px/s shows fewer, larger
 * cuts at a time so the trim handles are easy to hit precisely.
 */
export const DEFAULT_PX_PER_SECOND = 60;
const STRIP_HEIGHT = 58;
/**
 * Filmstrip frames are horizontal rectangles that FILL their cut
 * (Jaizon, 2026-11-09): a cut's block is as wide as the cut is long
 * (duration × pxPerSecond), and the frames inside share that width
 * out evenly — so a quick cut reads as a short rectangle and a long
 * cut as a long one. Frames aim for ~76pt wide; the exact width is
 * the segment width divided by the frame count, and contentFit
 * "cover" centre-crops the vertical source into each rectangle
 * without ever stretching it.
 */
const TARGET_FRAME_WIDTH = 76;
/** Trim-handle grab width per side — generous zones so trimming is effortless. */
const HANDLE_WIDTH = 36;
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
      <View style={styles.trimGrip}>
        <View style={styles.trimGripNotch} />
      </View>
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
 * - One fixed, zoomed-in time scale (DEFAULT_PX_PER_SECOND) with a
 *   ruler (tick every second, labels every 5s), horizontally
 *   scrollable for longer cuts. No zoom controls (v2 simplification).
 * - Every cut is a filmstrip of horizontal-rectangle frames that
 *   fill the cut's length-proportional block: real frames sampled
 *   from its take at the source time each frame position represents
 *   (expo-video thumbnails, colour placeholder until they land),
 *   sharing the cut's width out evenly and cover-cropped, never
 *   stretched — so you can SEE each clip and read its length.
 * - A playhead tracks the preview playback and the strip auto-scrolls
 *   to follow it (suspended while the user is scrubbing/trimming);
 *   the currently playing cut is underlined.
 * - Tap a cut to select it. The selected cut grows prominent lime
 *   trim handles on both edges (drag = ripple-aware trim, owned by
 *   the editor) and dragging on the ruler scrubs the preview.
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
  onTrimDrag,
  onScrub,
  scrubbing = false,
}: {
  clips: TimelineStripClip[];
  selectedClipId?: string | null;
  onSelectClip?: (clipId: string) => void;
  /** Preview position inside the edit, seconds — drives the playhead. */
  playbackSeconds?: number | null;
  isPlaying?: boolean;
  /** Drag-trim on the selected segment's handles (editor owns semantics). */
  onTrimDrag?: (event: TimelineTrimDragEvent) => void;
  /** Ruler scrub: reports the timeline second under the finger. */
  onScrub?: (seconds: number, phase: TimelineScrubPhase) => void;
  /** True while the editor is scrubbing — suspends playhead auto-follow. */
  scrubbing?: boolean;
}) {
  const pxPerSecond = DEFAULT_PX_PER_SECOND;
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

  // Filmstrip sample times per clip: the frames share the cut's own
  // length out evenly — frame i covers an equal slice of the cut's
  // duration and is sampled at the CENTRE of that slice, mapped into
  // the take's source time. The frame COUNT targets ~76pt per frame,
  // so longer cuts simply get more (or wider) frames. A slowed clip
  // is WIDER on the timeline but covers LESS source time per tile:
  // the source span is the timeline length × speed.
  const samples = useMemo(() => {
    const perClip = new Map<string, number[]>();
    for (const clip of clips) {
      if (!clip.sourceUri || clip.lengthSeconds <= 0) continue;
      const width = Math.max(18, clip.lengthSeconds * pxPerSecond);
      const tiles = Math.max(1, Math.round(width / TARGET_FRAME_WIDTH));
      const start = clip.sourceStartSeconds ?? 0;
      const sourceSeconds = clip.lengthSeconds * (clip.speed ?? 1);
      const tileSeconds = sourceSeconds / tiles;
      const times: number[] = [];
      for (let i = 0; i < tiles; i++) {
        times.push(Math.round((start + (i + 0.5) * tileSeconds) * 20) / 20);
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

  // Ruler: tick every second; at the fixed 60 px/s scale a label
  // every 5s sits 300pt apart — never crowded.
  const labelEvery = 5;
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
        <Text style={styles.total}>
          {playbackSeconds != null
            ? `${formatTime(Math.min(playbackSeconds, total))} / ${formatTime(total)} · ${clips.length} cuts`
            : `${clips.length} cuts · ${formatTime(total)}`}
        </Text>
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
                // Frames share the cut's width out evenly: the longer
                // the cut, the longer its rectangles.
                const frameWidth = width / Math.max(1, times.length);
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
                      accessibilityLabel={`${clip.label}, cut ${i + 1} of ${clips.length}, ${formatTime(clip.lengthSeconds)}${clip.speed && clip.speed !== 1 ? `, ${clip.speed} times speed` : ''}. Tap to select this cut.`}>
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
                                  style={{ width: frameWidth, height: STRIP_HEIGHT }}
                                  contentFit="cover"
                                />
                              ) : (
                                <View key={ti} style={{ width: frameWidth, height: STRIP_HEIGHT }} />
                              );
                            })
                          : null}
                      </View>
                      <View style={styles.labelChip}>
                        <Text style={styles.labelChipText} numberOfLines={1}>
                          {clip.label}
                        </Text>
                      </View>
                      {clip.speed !== undefined && clip.speed !== 1 ? (
                        <View style={styles.speedBadge}>
                          <Text style={styles.speedBadgeText} numberOfLines={1}>
                            {clip.speed}×
                          </Text>
                        </View>
                      ) : null}
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
    height: STRIP_HEIGHT,
    borderRadius: 3,
    backgroundColor: colors.accent,
    borderWidth: 1,
    borderColor: 'rgba(0,0,0,0.35)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  trimGripNotch: {
    width: 2,
    height: 16,
    borderRadius: 1,
    backgroundColor: 'rgba(0,0,0,0.45)',
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
  speedBadge: {
    position: 'absolute',
    top: 3,
    right: 3,
    backgroundColor: colors.accent,
    borderRadius: 4,
    paddingHorizontal: 5,
    paddingVertical: 2,
  },
  speedBadgeText: { color: colors.onAccent, fontSize: 9, fontWeight: '800', fontVariant: ['tabular-nums'] },
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
