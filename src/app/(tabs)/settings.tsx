import type { VideoQuality } from 'expo-camera';
import { Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SegmentedControl } from '../../components/SegmentedControl';
import { isCompositorAvailable } from '../../lib/compositor';
import { useStudio } from '../../store/StudioContext';
import { colors, radius, spacing, type as typeScale } from '../../theme';
import type { CountInBeats, CountdownSeconds, ExportQualityPref, FrameRatePref } from '../../types';

/**
 * Settings — configuration ONLY (Overhaul IA: the single home for
 * settings; the per-screen gear sheets are gone). Creative tools live
 * in the Editor, never here.
 */
export default function SettingsScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={{ paddingTop: insets.top + spacing.lg, paddingBottom: spacing.xxl }}>
      <View style={styles.header}>
        <Text style={styles.largeTitle}>Settings</Text>
      </View>

      <Text style={styles.groupTitle}>Camera</Text>
      <View style={styles.card}>
        <Text style={styles.rowLabel}>Video quality</Text>
        <SegmentedControl
          options={[
            { value: '2160p' as VideoQuality, label: '4K' },
            { value: '1080p' as VideoQuality, label: '1080p' },
            { value: '720p' as VideoQuality, label: '720p' },
            { value: '480p' as VideoQuality, label: '480p' },
          ]}
          value={studio.resolution}
          onChange={studio.setResolution}
          accessibilityLabel="Recorded video quality"
        />
        <Text style={styles.rowLabel}>Frame rate</Text>
        <SegmentedControl
          options={[
            { value: 30 as FrameRatePref, label: '30' },
            { value: 60 as FrameRatePref, label: '60' },
          ]}
          value={studio.frameRate}
          onChange={studio.setFrameRate}
          accessibilityLabel="Preferred frame rate"
        />
        <ToggleRow label="Mirror front camera" value={studio.mirror} onChange={studio.setMirror} />
        <ToggleRow label="Grid overlay" value={studio.gridOverlay} onChange={studio.setGridOverlay} />
        <ToggleRow label="Centre level guide" value={studio.levelGuide} onChange={studio.setLevelGuide} last />
      </View>

      <Text style={styles.groupTitle}>Recording defaults</Text>
      <View style={styles.card}>
        <Text style={styles.rowLabel}>Camera timer</Text>
        <SegmentedControl
          options={[
            { value: 0 as CountdownSeconds, label: 'Off' },
            { value: 3 as CountdownSeconds, label: '3s' },
            { value: 5 as CountdownSeconds, label: '5s' },
            { value: 10 as CountdownSeconds, label: '10s' },
          ]}
          value={studio.countdown}
          onChange={studio.setCountdown}
          accessibilityLabel="Default camera timer"
        />
        <Text style={styles.rowLabel}>Count-in (beats)</Text>
        <SegmentedControl
          options={[
            { value: 0 as CountInBeats, label: 'Off' },
            { value: 4 as CountInBeats, label: '4' },
            { value: 8 as CountInBeats, label: '8' },
          ]}
          value={studio.countInBeats}
          onChange={studio.setCountInBeats}
          accessibilityLabel="Default count-in beats"
        />
        <ToggleRow label="Metronome flash while recording" value={studio.metronome} onChange={studio.setMetronome} last />
      </View>

      <Text style={styles.groupTitle}>Sync</Text>
      <View style={styles.card}>
        <View style={styles.stepperRow}>
          <View style={{ flex: 1 }}>
            <Text style={styles.rowLabelInline}>Audio offset</Text>
            <Text style={styles.rowHint}>Corrects Bluetooth / output latency when recording.</Text>
          </View>
          <Pressable style={styles.stepButton} onPress={() => studio.setAudioOffsetMs(studio.audioOffsetMs - 10)} accessibilityRole="button" accessibilityLabel="Decrease audio offset">
            <Text style={styles.stepButtonText}>−</Text>
          </Pressable>
          <Text style={styles.stepValue}>{studio.audioOffsetMs} ms</Text>
          <Pressable style={styles.stepButton} onPress={() => studio.setAudioOffsetMs(studio.audioOffsetMs + 10)} accessibilityRole="button" accessibilityLabel="Increase audio offset">
            <Text style={styles.stepButtonText}>+</Text>
          </Pressable>
        </View>
      </View>

      <Text style={styles.groupTitle}>Export</Text>
      <View style={styles.card}>
        <Text style={styles.rowLabel}>Default quality</Text>
        <SegmentedControl
          options={[
            { value: 'high' as ExportQualityPref, label: 'High' },
            { value: 'balanced' as ExportQualityPref, label: 'Balanced' },
            { value: 'small' as ExportQualityPref, label: 'Small' },
          ]}
          value={studio.exportQuality}
          onChange={studio.setExportQuality}
          accessibilityLabel="Default export quality"
        />
      </View>

      <Text style={styles.groupTitle}>About</Text>
      <View style={styles.card}>
        <View style={styles.infoRow}>
          <Text style={styles.rowLabelInline}>Native media engine</Text>
          <Text style={styles.infoValue}>{isCompositorAvailable() ? 'Available' : 'Not in this build'}</Text>
        </View>
        <Text style={styles.aboutText}>
          MVMT Studio records takes while your song plays, then cuts them together on a frame-accurate timeline and
          renders with the native engine — preview and export are the same composition.
        </Text>
      </View>
    </ScrollView>
  );
}

function ToggleRow({
  label,
  value,
  onChange,
  last,
}: {
  label: string;
  value: boolean;
  onChange: (v: boolean) => void;
  last?: boolean;
}) {
  return (
    <View style={[styles.toggleRow, !last && styles.toggleRowSeparator]}>
      <Text style={styles.rowLabelInline}>{label}</Text>
      <Switch
        value={value}
        onValueChange={onChange}
        trackColor={{ true: colors.accent, false: 'rgba(244,241,233,0.18)' }}
        thumbColor={value ? colors.onAccent : colors.label}
        accessibilityLabel={label}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.base },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.lg },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  groupTitle: {
    ...typeScale.footnote,
    color: colors.labelSecondary,
    fontWeight: '700',
    letterSpacing: 0.8,
    textTransform: 'uppercase',
    paddingHorizontal: spacing.xl,
    marginTop: spacing.lg,
    marginBottom: spacing.sm,
  },
  card: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.lg,
    marginHorizontal: spacing.xl,
    gap: spacing.md,
  },
  rowLabel: { ...typeScale.subhead, color: colors.labelSecondary, fontWeight: '600' },
  rowLabelInline: { ...typeScale.body, color: colors.label },
  rowHint: { ...typeScale.footnote, color: colors.labelTertiary, marginTop: 2 },
  toggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: spacing.xs,
  },
  toggleRowSeparator: { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.separator, paddingBottom: spacing.md },
  stepperRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  stepButton: {
    width: 34,
    height: 34,
    borderRadius: radius.pill,
    backgroundColor: colors.elevated,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepButtonText: { color: colors.label, fontSize: 18, fontWeight: '700' },
  stepValue: { ...typeScale.headline, color: colors.label, minWidth: 64, textAlign: 'center', fontVariant: ['tabular-nums'] },
  infoRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  infoValue: { ...typeScale.subhead, color: colors.labelSecondary },
  aboutText: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 18 },
});
