import type { VideoQuality } from 'expo-camera';
import { Image } from 'expo-image';
import { Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SegmentedControl } from '../../components/SegmentedControl';
import { GroupCard } from '../../components/ui/GroupCard';
import { SectionHeader } from '../../components/ui/SectionHeader';
import { isCompositorAvailable } from '../../lib/compositor';
import { useStudio } from '../../store/StudioContext';
import { colors, radius, spacing, type as typeScale } from '../../theme';
import type { CountInBeats, CountdownSeconds, ExportQualityPref, FrameRatePref } from '../../types';

/**
 * Settings — configuration ONLY (Overhaul IA: the single home for
 * settings; the per-screen gear sheets are gone). Creative tools live
 * in the Editor, never here. Bindings are unchanged from the previous
 * screen — only the presentation is refined (grouped cards, consistent
 * rows, hairline separators).
 */
export default function SettingsScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={{ paddingTop: insets.top + spacing.xl, paddingBottom: spacing.xxxl }}>
      <View style={styles.header}>
        <Text style={styles.largeTitle}>Settings</Text>
        <Text style={styles.subtitle}>Defaults for recording and export.</Text>
      </View>

      <SectionHeader variant="group" title="Camera" />
      <GroupCard>
        <ControlBlock label="Video quality" first>
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
        </ControlBlock>
        <ControlBlock label="Frame rate" hint="The default capture rate. Edits and exports are always 30 fps.">
          <SegmentedControl
            options={[
              { value: 30 as FrameRatePref, label: '30' },
              { value: 60 as FrameRatePref, label: '60' },
            ]}
            value={studio.frameRate}
            onChange={studio.setFrameRate}
            accessibilityLabel="Preferred frame rate"
          />
        </ControlBlock>
        <ToggleRow label="Mirror front camera" value={studio.mirror} onChange={studio.setMirror} />
        <ToggleRow label="Grid overlay" value={studio.gridOverlay} onChange={studio.setGridOverlay} />
        <ToggleRow label="Centre level guide" value={studio.levelGuide} onChange={studio.setLevelGuide} last />
      </GroupCard>

      <SectionHeader variant="group" title="Recording defaults" />
      <GroupCard>
        <ControlBlock label="Camera timer" first>
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
        </ControlBlock>
        <ControlBlock label="Count-in (beats)" hint="Clicks before the take starts, after the timer.">
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
        </ControlBlock>
        <ToggleRow label="Metronome flash while recording" value={studio.metronome} onChange={studio.setMetronome} last />
      </GroupCard>

      <SectionHeader variant="group" title="Sync" />
      <GroupCard>
        <View style={styles.stepperRow}>
          <View style={{ flex: 1 }}>
            <Text style={styles.rowLabelInline}>Audio offset</Text>
            <Text style={styles.rowHint}>Corrects Bluetooth / output latency when recording.</Text>
          </View>
          <Pressable
            style={({ pressed }) => [styles.stepButton, pressed && styles.stepButtonPressed]}
            onPress={() => studio.setAudioOffsetMs(studio.audioOffsetMs - 10)}
            accessibilityRole="button"
            accessibilityLabel="Decrease audio offset">
            <Text style={styles.stepButtonText}>−</Text>
          </Pressable>
          <Text style={styles.stepValue}>{studio.audioOffsetMs} ms</Text>
          <Pressable
            style={({ pressed }) => [styles.stepButton, pressed && styles.stepButtonPressed]}
            onPress={() => studio.setAudioOffsetMs(studio.audioOffsetMs + 10)}
            accessibilityRole="button"
            accessibilityLabel="Increase audio offset">
            <Text style={styles.stepButtonText}>+</Text>
          </Pressable>
        </View>
      </GroupCard>

      <SectionHeader variant="group" title="Export" />
      <GroupCard>
        <ControlBlock
          label="Default quality"
          hint="The default for new exports. You can change it for a single video on the Export screen."
          first
          last>
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
        </ControlBlock>
      </GroupCard>

      <SectionHeader variant="group" title="About" />
      <GroupCard>
        <View style={styles.infoRow}>
          <Text style={styles.rowLabelInline}>Native media engine</Text>
          <Text style={styles.infoValue}>{isCompositorAvailable() ? 'Available' : 'Not in this build'}</Text>
        </View>
        <View style={styles.separator} />
        <Text style={styles.aboutText}>
          MVMT Studio records takes while your song plays, then cuts them together on a frame-accurate timeline and
          renders with the native engine — preview and export are the same composition.
        </Text>
      </GroupCard>

      {/* Brand mark — the lockup as a quiet footer under About. */}
      <View style={styles.brandFooter}>
        <Image
          source={require('../../../assets/logo-lockup.png')}
          style={styles.brandLogo}
          contentFit="contain"
          accessibilityLabel="MVMT Studio"
        />
      </View>
    </ScrollView>
  );
}

function ControlBlock({
  label,
  hint,
  first,
  last,
  children,
}: {
  label: string;
  hint?: string;
  first?: boolean;
  last?: boolean;
  children: React.ReactNode;
}) {
  return (
    <View style={[styles.block, !first && styles.blockSeparator, !last && styles.blockSpacing]}>
      <Text style={styles.rowLabel}>{label}</Text>
      {children}
      {hint ? <Text style={styles.rowHint}>{hint}</Text> : null}
    </View>
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
        trackColor={{ true: colors.accent, false: colors.elevated }}
        thumbColor={value ? colors.onAccent : colors.label}
        accessibilityLabel={label}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.base },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.sm },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  subtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: spacing.xs },
  block: { gap: spacing.sm },
  blockSpacing: { marginBottom: spacing.lg },
  blockSeparator: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    paddingTop: spacing.lg,
  },
  separator: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    marginVertical: spacing.md,
  },
  rowLabel: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  rowLabelInline: { ...typeScale.body, color: colors.label },
  rowHint: { ...typeScale.footnote, color: colors.labelTertiary, marginTop: 2, lineHeight: 17 },
  toggleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    minHeight: 44,
    paddingVertical: spacing.sm,
  },
  toggleRowSeparator: { borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: colors.separator },
  stepperRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  stepButton: {
    width: 36,
    height: 36,
    borderRadius: radius.pill,
    backgroundColor: colors.elevated,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stepButtonPressed: { backgroundColor: colors.cardPressed, opacity: 0.85 },
  stepButtonText: { color: colors.label, fontSize: 18, fontWeight: '700' },
  stepValue: { ...typeScale.headline, color: colors.label, minWidth: 64, textAlign: 'center', fontVariant: ['tabular-nums'] },
  infoRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 32 },
  brandFooter: { alignItems: 'center', marginTop: spacing.xxl },
  brandLogo: { width: 110, aspectRatio: 363 / 175, opacity: 0.85 },
  infoValue: { ...typeScale.subhead, color: colors.labelSecondary },
  aboutText: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 18 },
});
