import { Image } from 'expo-image';
import type { VideoThumbnail } from 'expo-video';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View, type ScrollViewInstance } from 'react-native';

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

/** Timeline scale — CapCut-like: fixed pixels per second, scrollable. */
const PX_PER_SEC = 30;
const STRIP_HEIGHT = 58;
const TILE_WIDTH = 34;

/**
 * The cut as a REAL timeline editor (CapCut-style), rebuilt after
 * Jaizon's device test (2026-11-08) — the old proportional bar read as
 * "one big cut" and showed nothing of the actual footage:
 *
 * - Fixed time scale with a ruler (tick every second, label every 5s),
 *   horizontally scrollable for longer cuts.
 * - Every cut is a filmstrip: real frames sampled from its take across
 *   the cut's range (expo-video thumbnails, colour placeholder until
 *   they land), so you can SEE each clip.
 * - A playhead tracks the preview playback and the strip auto-scrolls
 *   to follow it; the currently playing cut is underlined.
 * - Tap a cut to select it; the Editor's cut action bar (take switch,
 *   trim, split, delete) renders in the screen — this timeline IS the
 *   editor surface.
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
}: {
  clips: TimelineStripClip[];
  selectedClipId?: string | null;
  onSelectClip?: (clipId: string) => void;
  /** Preview position inside the edit, seconds — drives the playhead. */
  playbackSeconds?: number | null;
  isPlaying?: boolean;
}) {
  const scrollRef = useRef<ScrollViewInstance>(null);
  const scrollOffsetRef = useRef(0);
  const viewportWidthRef = useRef(0);
  const [, setThumbTick] = useState(0);

  const total = clips.reduce((sum, c) => sum + Math.max(0, c.lengthSeconds), 0);
  const totalWidth = Math.max(1, total * PX_PER_SEC);

  // Filmstrip sample times per clip: one frame per tile across the cut's
  // own range inside its take.
  const samples = useMemo(() => {
    const perClip = new Map<string, number[]>();
    for (const clip of clips) {
      if (!clip.sourceUri || clip.lengthSeconds <= 0) continue;
      const width = Math.max(18, clip.lengthSeconds * PX_PER_SEC);
      const tiles = Math.max(1, Math.round(width / TILE_WIDTH));
      const start = clip.sourceStartSeconds ?? 0;
      const times: number[] = [];
      for (let i = 0; i < tiles; i++) {
        times.push(Math.round((start + ((i + 0.5) * clip.lengthSeconds) / tiles) * 20) / 20);
      }
      perClip.set(clip.id, times);
    }
    return perClip;
  }, [clips]);

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

  // Keep the playhead in view while the preview plays.
  useEffect(() => {
    if (!isPlaying || playbackSeconds == null) return;
    const x = playbackSeconds * PX_PER_SEC;
    const offset = scrollOffsetRef.current;
    const viewW = viewportWidthRef.current;
    if (viewW > 0 && (x < offset + 24 || x > offset + viewW - 70)) {
      scrollRef.current?.scrollTo({ x: Math.max(0, x - 56), animated: true });
    }
  }, [playbackSeconds, isPlaying]);

  if (clips.length === 0 || total <= 0) return null;

  const playheadX = playbackSeconds != null ? Math.min(Math.max(0, playbackSeconds), total) * PX_PER_SEC : null;

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

  const rulerTicks = [];
  for (let s = 0; s <= Math.floor(total); s++) {
    rulerTicks.push(
      <View key={`tick-${s}`} style={[styles.tick, { left: s * PX_PER_SEC }, s % 5 === 0 && styles.tickMajor]} />,
    );
    if (s % 5 === 0) {
      rulerTicks.push(
        <Text key={`label-${s}`} style={[styles.rulerLabel, { left: s * PX_PER_SEC + 3 }]}>
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
          scrollEventThrottle={100}
          onScroll={(e) => {
            scrollOffsetRef.current = e.nativeEvent.contentOffset.x;
          }}
          onLayout={(e) => {
            viewportWidthRef.current = e.nativeEvent.layout.width;
          }}>
          <View style={{ width: totalWidth }}>
            <View style={styles.ruler}>{rulerTicks}</View>
            <View style={styles.stripRow}>
              {clips.map((clip, i) => {
                const width = Math.max(18, clip.lengthSeconds * PX_PER_SEC);
                const selected = selectedClipId === clip.id;
                const active = activeClipId === clip.id && playbackSeconds != null;
                const times = samples.get(clip.id) ?? [];
                const tileWidth = width / Math.max(1, times.length || 1);
                return (
                  <Pressable
                    key={clip.id}
                    style={[
                      styles.segment,
                      { width, backgroundColor: i % 2 === 0 ? colors.cardPressed : colors.elevated },
                      i > 0 && styles.segmentDivider,
                      active && styles.segmentActive,
                      selected && styles.segmentSelected,
                    ]}
                    onPress={() => onSelectClip?.(clip.id)}
                    accessibilityRole="button"
                    accessibilityState={{ selected }}
                    accessibilityLabel={`${clip.label}, cut ${i + 1} of ${clips.length}, ${formatTime(clip.lengthSeconds)}. Tap to switch its take.`}>
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
      {onSelectClip ? <Text style={styles.hint}>Tap a cut to switch which take it uses</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  headerRow: {
    flexDirection: 'row',
    alignItems: 'baseline',
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
  ruler: { height: 16, position: 'relative', marginBottom: 2 },
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
  // Inside the segment's width (not a margin) so cut boundaries stay
  // exactly on the ruler's time scale and the playhead lines up.
  segmentDivider: { borderLeftWidth: 2, borderLeftColor: colors.base },
  segmentActive: { borderBottomWidth: 3, borderBottomColor: colors.accent },
  segmentSelected: { borderWidth: 2, borderColor: colors.accent },
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
