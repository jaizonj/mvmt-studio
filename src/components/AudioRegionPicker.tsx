import { Ionicons } from '@expo/vector-icons';
import { useAudioPlayer } from 'expo-audio';
import { useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';

import { effectiveRegion } from '../lib/analysis';
import { loadTrackPeaks, samplePeaks, standinPeaks } from '../lib/waveform';
import { useStudio } from '../store/StudioContext';
import { colors, formatTime, radius, spacing } from '../theme';

const BAR_COUNT = 48;

/** The shortest performable part — handles and steppers enforce it. */
const MIN_REGION_SECONDS = 1;

/**
 * Audio-part picker: WHICH PART of the song, chosen by explicit
 * start and end (Jaizon, 2026-11-10 — the 15s/30s/1min/3min/Full
 * duration presets are gone, here and from the camera screen).
 *
 * The highlighted window on the waveform carries a handle at each
 * edge: drag the left handle to set the start, the right handle to
 * set the end, or the window's middle to move the whole part. One
 * pan gesture hit-tests where the drag began (near an edge = that
 * handle; inside = move; elsewhere = tap-to-centre), so there is
 * exactly one gesture to arbitrate. ±1s steppers beside the start /
 * end readouts give fine adjustment. Constraints everywhere: the
 * region is at least 1s, both ends stay inside the song, and a
 * handle stops at the other handle (start < end always).
 *
 * The selection lives in the studio store (AudioRegion =
 * start + duration; the end is start + duration) — recording length,
 * take anchoring, lyrics and the editor all read
 * that same value. The neutral default is the full song: a freshly
 * picked track stores { start: 0, duration: null } and the handles
 * sit at the song's edges until they're moved.
 *
 * Waveform note: the bars are REAL decoded peaks (the native
 * `waveformPeaks` via src/lib/waveform.ts), resampled to BAR_COUNT.
 * When the native engine is unavailable (Expo Go / older builds) or a
 * file can't be decoded, they fall back to the deterministic stand-in
 * drawn from the track name. The window geometry, labels and preview
 * are fully real either way.
 */
export function AudioRegionPicker() {
  const { track, trackRegion, setTrackRegion } = useStudio();
  const duration = track?.durationSeconds ?? 0;
  const region = effectiveRegion(trackRegion, duration);
  const [barWidth, setBarWidth] = useState(0);
  const [previewing, setPreviewing] = useState(false);
  /** The drag's mode + the region snapshot it started from. */
  const dragRef = useRef<{ mode: 'start' | 'end' | 'move'; start: number; end: number } | null>(null);
  const dragMovedRef = useRef(false);

  const player = useAudioPlayer(track?.uri ?? null);

  // Bars are the real decoded peaks once they land (stored tagged
  // with their uri); until then — and on any track switch — they are
  // the stand-in, so first paint is exactly what it always was.
  const [loadedBars, setLoadedBars] = useState<{ uri: string; bars: number[] } | null>(null);
  const trackUri = track?.uri;
  const trackName = track?.name;
  useEffect(() => {
    if (!trackUri || !trackName) return;
    let alive = true;
    void loadTrackPeaks({ uri: trackUri, name: trackName }).then((loaded) => {
      if (alive) setLoadedBars({ uri: trackUri, bars: samplePeaks(loaded, BAR_COUNT) });
    });
    return () => {
      alive = false;
    };
  }, [trackUri, trackName]);
  const bars =
    loadedBars && loadedBars.uri === trackUri ? loadedBars.bars : standinPeaks(trackName ?? 'track', BAR_COUNT);

  // Never leave a preview playing after the picker unmounts (sheet closed).
  useEffect(() => {
    return () => {
      try {
        player.pause();
      } catch {
        /* player already released */
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Preview must stop exactly at the region end.
  useEffect(() => {
    if (!previewing || !region) return;
    const timer = setInterval(() => {
      if (player.currentTime >= region.endSeconds - 0.05) {
        player.pause();
        setPreviewing(false);
      }
    }, 150);
    return () => clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [previewing, region?.endSeconds]);

  if (!track) {
    return <Text style={styles.empty}>Add a track first — then choose which part to perform.</Text>;
  }
  if (!region) {
    return (
      <Text style={styles.empty}>
        Track added. Its length is measured the first time it plays — record a take or tap preview in the editor, then
        come back to choose a part.
      </Text>
    );
  }

  const windowLeftPct = (region.startSeconds / duration) * 100;
  const windowWidthPct = Math.max(4, (region.lengthSeconds / duration) * 100);

  /** Store an explicit start/end as the region (start + duration). */
  const storeRegion = (startSeconds: number, endSeconds: number) => {
    setTrackRegion({ startSeconds, durationSeconds: endSeconds - startSeconds });
  };

  const nudgeStart = (deltaSeconds: number) => {
    const start = Math.min(
      Math.max(0, region.startSeconds + deltaSeconds),
      region.endSeconds - MIN_REGION_SECONDS,
    );
    storeRegion(start, region.endSeconds);
  };

  const nudgeEnd = (deltaSeconds: number) => {
    const end = Math.min(
      Math.max(region.startSeconds + MIN_REGION_SECONDS, region.endSeconds + deltaSeconds),
      duration,
    );
    storeRegion(region.startSeconds, end);
  };

  // Gesture callbacks run on user input, not render — see camera screen.
  /* eslint-disable react-hooks/refs */
  const pan = Gesture.Pan()
    .runOnJS(true)
    .onBegin((event) => {
      // Hit-test the touch: near an edge = that handle, inside the
      // window = move, outside = move too (a tap there centres the
      // window — handled onEnd when the gesture never travelled).
      // The grab zone is ~20px, widened in seconds so a handle is
      // never ungrabbable on a long song.
      const xSeconds = barWidth > 0 ? (event.x / barWidth) * duration : region.startSeconds;
      const grabSeconds = Math.max((20 / Math.max(1, barWidth)) * duration, 0.6);
      let mode: 'start' | 'end' | 'move' = 'move';
      if (Math.abs(xSeconds - region.startSeconds) <= grabSeconds) mode = 'start';
      else if (Math.abs(xSeconds - region.endSeconds) <= grabSeconds) mode = 'end';
      dragRef.current = { mode, start: region.startSeconds, end: region.endSeconds };
      dragMovedRef.current = false;
    })
    .onUpdate((event) => {
      const drag = dragRef.current;
      if (!drag || barWidth <= 0) return;
      if (Math.abs(event.translationX) > 3) dragMovedRef.current = true;
      const dxSeconds = (event.translationX / barWidth) * duration;
      if (drag.mode === 'start') {
        // The start handle stops at the end handle (min region).
        const start = Math.min(Math.max(0, drag.start + dxSeconds), drag.end - MIN_REGION_SECONDS);
        storeRegion(start, drag.end);
      } else if (drag.mode === 'end') {
        const end = Math.min(Math.max(drag.start + MIN_REGION_SECONDS, drag.end + dxSeconds), duration);
        storeRegion(drag.start, end);
      } else {
        const length = drag.end - drag.start;
        const start = Math.min(Math.max(0, drag.start + dxSeconds), Math.max(0, duration - length));
        storeRegion(start, start + length);
      }
    })
    .onEnd((event) => {
      // A tap (no real travel) outside the handles centres the
      // window on the tap, keeping its length — the old tap-to-move.
      const drag = dragRef.current;
      if (drag && !dragMovedRef.current && drag.mode === 'move' && barWidth > 0) {
        const tapped = (event.x / barWidth) * duration;
        const length = drag.end - drag.start;
        const start = Math.min(Math.max(0, tapped - length / 2), Math.max(0, duration - length));
        storeRegion(start, start + length);
      }
      dragRef.current = null;
    });
  /* eslint-enable react-hooks/refs */

  const togglePreview = async () => {
    if (previewing) {
      player.pause();
      setPreviewing(false);
      return;
    }
    await player.seekTo(region.startSeconds);
    player.play();
    setPreviewing(true);
  };

  return (
    <View>
      {/* Waveform (real decoded peaks) with start/end handles */}
      <GestureDetector gesture={pan}>
        <View style={styles.barWrap} onLayout={(e) => setBarWidth(e.nativeEvent.layout.width)}>
          <View style={styles.bars}>
            {bars.map((h, i) => (
              <View key={i} style={[styles.bar, { height: 8 + h * 30 }]} />
            ))}
          </View>
          <View style={[styles.window, { left: `${windowLeftPct}%`, width: `${windowWidthPct}%` }]}>
            <View style={[styles.handle, styles.handleLeft]}>
              <View style={styles.handleGrip} />
            </View>
            <View style={styles.windowHandle} />
            <View style={[styles.handle, styles.handleRight]}>
              <View style={styles.handleGrip} />
            </View>
          </View>
        </View>
      </GestureDetector>

      {/* Start / end readouts with ±1s fine-adjust steppers */}
      <View style={styles.readoutRow}>
        <View style={styles.endpoint}>
          <Text style={styles.endpointLabel}>Start</Text>
          <View style={styles.stepper}>
            <Pressable
              style={styles.stepButton}
              onPress={() => nudgeStart(-1)}
              accessibilityRole="button"
              accessibilityLabel="Start one second earlier">
              <Ionicons name="remove" size={15} color={colors.label} />
            </Pressable>
            <Text style={styles.timeValue}>{formatTime(region.startSeconds)}</Text>
            <Pressable
              style={styles.stepButton}
              onPress={() => nudgeStart(1)}
              accessibilityRole="button"
              accessibilityLabel="Start one second later">
              <Ionicons name="add" size={15} color={colors.label} />
            </Pressable>
          </View>
        </View>
        <Text style={styles.lengthCenter}>{formatTime(region.lengthSeconds)}</Text>
        <View style={styles.endpoint}>
          <Text style={styles.endpointLabel}>End</Text>
          <View style={styles.stepper}>
            <Pressable
              style={styles.stepButton}
              onPress={() => nudgeEnd(-1)}
              accessibilityRole="button"
              accessibilityLabel="End one second earlier">
              <Ionicons name="remove" size={15} color={colors.label} />
            </Pressable>
            <Text style={styles.timeValue}>{formatTime(region.endSeconds)}</Text>
            <Pressable
              style={styles.stepButton}
              onPress={() => nudgeEnd(1)}
              accessibilityRole="button"
              accessibilityLabel="End one second later">
              <Ionicons name="add" size={15} color={colors.label} />
            </Pressable>
          </View>
        </View>
      </View>

      <View style={styles.footerRow}>
        <Text style={styles.note}>Drag the edges to set the start and end.</Text>
        <Pressable style={styles.previewButton} onPress={togglePreview} accessibilityRole="button">
          <Ionicons name={previewing ? 'pause' : 'play'} size={14} color="#14141F" />
          <Text style={styles.previewButtonText}>{previewing ? 'Stop' : 'Preview'}</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  empty: { color: colors.labelSecondary, fontSize: 15, lineHeight: 20 },
  barWrap: {
    height: 56,
    borderRadius: radius.md,
    backgroundColor: 'rgba(255,255,255,0.07)',
    justifyContent: 'center',
    paddingHorizontal: 6,
    overflow: 'hidden',
  },
  bars: { flexDirection: 'row', alignItems: 'center', gap: 2 },
  bar: { flex: 1, borderRadius: 2, backgroundColor: 'rgba(255,255,255,0.4)' },
  window: {
    position: 'absolute',
    top: 4,
    bottom: 4,
    borderRadius: radius.sm,
    borderWidth: 1.5,
    borderColor: colors.accent,
    backgroundColor: colors.accentDim,
    alignItems: 'center',
    justifyContent: 'center',
  },
  windowHandle: { width: 22, height: 4, borderRadius: 2, backgroundColor: colors.accent },
  handle: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    width: 14,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.accent,
  },
  handleLeft: { left: 0, borderTopLeftRadius: radius.sm, borderBottomLeftRadius: radius.sm },
  handleRight: { right: 0, borderTopRightRadius: radius.sm, borderBottomRightRadius: radius.sm },
  handleGrip: { width: 3, height: 18, borderRadius: 2, backgroundColor: 'rgba(20,20,31,0.55)' },
  readoutRow: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: spacing.md,
    marginTop: spacing.md,
  },
  endpoint: { gap: 4 },
  endpointLabel: {
    fontSize: 11,
    fontWeight: '600',
    color: colors.labelSecondary,
    textTransform: 'uppercase',
    letterSpacing: 0.6,
  },
  stepper: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  stepButton: {
    width: 28,
    height: 28,
    borderRadius: radius.pill,
    backgroundColor: 'rgba(120,120,128,0.24)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  timeValue: {
    color: colors.label,
    fontSize: 15,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
    minWidth: 40,
    textAlign: 'center',
  },
  lengthCenter: {
    flex: 1,
    textAlign: 'center',
    color: colors.labelSecondary,
    fontSize: 13,
    paddingBottom: 6,
  },
  footerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    marginTop: spacing.md,
  },
  note: { color: colors.labelTertiary, fontSize: 12, flex: 1 },
  previewButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.pill,
    paddingHorizontal: 12,
    paddingVertical: 7,
  },
  previewButtonText: { color: '#14141F', fontSize: 13, fontWeight: '700' },
});
