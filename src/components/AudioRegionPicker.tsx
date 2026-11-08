import { Ionicons } from '@expo/vector-icons';
import { useAudioPlayer } from 'expo-audio';
import { useEffect, useRef, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';

import { effectiveRegion } from '../lib/analysis';
import { loadTrackPeaks, samplePeaks, standinPeaks } from '../lib/waveform';
import { useStudio } from '../store/StudioContext';
import { colors, formatTime, radius, spacing } from '../theme';

const PRESETS: { label: string; seconds: number | null }[] = [
  { label: '15s', seconds: 15 },
  { label: '30s', seconds: 30 },
  { label: '1 min', seconds: 60 },
  { label: '3 min', seconds: 180 },
  { label: 'Full', seconds: null },
];

const BAR_COUNT = 48;

/**
 * Audio-part picker.
 *
 * Preset chips set the window length; the highlighted window on the
 * waveform can be dragged (or the bar tapped) to move it. Everything
 * clamps to the track: a preset longer than the track becomes the whole
 * track, and the window can never run past the end.
 *
 * The selection lives in the studio store (AudioRegion) — recording,
 * shuffle sectioning and the editor all read that same value.
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
  const dragStartRef = useRef(0);

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

  // Preview must stop exactly at the window end.
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

  const applyStart = (startSeconds: number) => {
    const maxStart = Math.max(0, duration - region.lengthSeconds);
    setTrackRegion({
      startSeconds: Math.min(Math.max(0, startSeconds), maxStart),
      durationSeconds: trackRegion.durationSeconds,
    });
  };

  // Gesture callbacks run on user input, not render — see camera screen.
  /* eslint-disable react-hooks/refs */
  const pan = Gesture.Pan()
    .runOnJS(true)
    .onBegin(() => {
      dragStartRef.current = region.startSeconds;
    })
    .onUpdate((event) => {
      if (barWidth <= 0) return;
      applyStart(dragStartRef.current + (event.translationX / barWidth) * duration);
    });
  /* eslint-enable react-hooks/refs */

  const applyPreset = (seconds: number | null) => {
    if (seconds === null) {
      setTrackRegion({ startSeconds: 0, durationSeconds: null });
      return;
    }
    const length = Math.min(seconds, duration);
    const start = Math.min(region.startSeconds, Math.max(0, duration - length));
    setTrackRegion({ startSeconds: start, durationSeconds: length });
  };

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
      {/* Preset chips */}
      <View style={styles.chipRow}>
        {PRESETS.map((preset) => {
          const selected =
            preset.seconds === null
              ? trackRegion.durationSeconds === null
              : trackRegion.durationSeconds === Math.min(preset.seconds, duration);
          return (
            <Pressable
              key={preset.label}
              onPress={() => applyPreset(preset.seconds)}
              style={[styles.chip, selected && styles.chipSelected]}
              accessibilityRole="button"
              accessibilityState={{ selected }}>
              <Text style={[styles.chipText, selected && styles.chipTextSelected]}>{preset.label}</Text>
            </Pressable>
          );
        })}
      </View>

      {/* Waveform (real decoded peaks) with draggable window */}
      <Pressable
        style={styles.barWrap}
        onLayout={(e) => setBarWidth(e.nativeEvent.layout.width)}
        onPress={(e) => {
          if (barWidth <= 0) return;
          const tapped = (e.nativeEvent.locationX / barWidth) * duration;
          applyStart(tapped - region.lengthSeconds / 2);
        }}>
        <View style={styles.bars}>
          {bars.map((h, i) => (
            <View key={i} style={[styles.bar, { height: 8 + h * 30 }]} />
          ))}
        </View>
        <GestureDetector gesture={pan}>
          <View
            style={[
              styles.window,
              { left: `${windowLeftPct}%`, width: `${windowWidthPct}%` },
            ]}>
            <View style={styles.windowHandle} />
          </View>
        </GestureDetector>
      </Pressable>

      {/* Live labels + preview */}
      <View style={styles.labelRow}>
        <Text style={styles.timeLabel}>
          {formatTime(region.startSeconds)} – {formatTime(region.endSeconds)}
        </Text>
        <Text style={styles.lengthLabel}>{formatTime(region.lengthSeconds)} selected</Text>
        <Pressable style={styles.previewButton} onPress={togglePreview} accessibilityRole="button">
          <Ionicons name={previewing ? 'pause' : 'play'} size={14} color="#14141F" />
          <Text style={styles.previewButtonText}>{previewing ? 'Stop' : 'Preview'}</Text>
        </Pressable>
      </View>
      <Text style={styles.note}>Drag the highlighted part to move it.</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  empty: { color: colors.labelSecondary, fontSize: 15, lineHeight: 20 },
  chipRow: { flexDirection: 'row', gap: spacing.sm, flexWrap: 'wrap', marginBottom: spacing.md },
  chip: {
    borderRadius: radius.pill,
    backgroundColor: 'rgba(120,120,128,0.24)',
    paddingHorizontal: 13,
    paddingVertical: 7,
  },
  chipSelected: { backgroundColor: '#FFFFFF' },
  chipText: { color: colors.label, fontSize: 13, fontWeight: '600' },
  chipTextSelected: { color: '#14141F' },
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
  labelRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    marginTop: spacing.md,
  },
  timeLabel: { color: colors.label, fontSize: 15, fontWeight: '600', fontVariant: ['tabular-nums'] },
  lengthLabel: { color: colors.labelSecondary, fontSize: 13, flex: 1 },
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
  note: { color: colors.labelTertiary, fontSize: 12, marginTop: spacing.sm },
});
