import { Ionicons } from '@expo/vector-icons';
import type { VideoQuality } from 'expo-camera';
import { useState, type ReactNode } from 'react';
import { Dimensions, Platform, Pressable, StyleSheet, Switch, Text, View } from 'react-native';

import { colors, radius, spacing } from '../theme';
import { SegmentedControl } from './SegmentedControl';
import { Sheet } from './Sheet';
import type { CountInBeats, CountdownSeconds, ExportQualityPref, FrameRatePref } from '../types';

type IoniconName = React.ComponentProps<typeof Ionicons>['name'];

export interface SettingsSheetProps {
  visible: boolean;
  onClose: () => void;
  // Camera configuration
  countdown: CountdownSeconds;
  onCountdownChange: (v: CountdownSeconds) => void;
  resolution: VideoQuality;
  onResolutionChange: (v: VideoQuality) => void;
  frameRate: FrameRatePref;
  onFrameRateChange: (v: FrameRatePref) => void;
  mirror: boolean;
  onMirrorChange: (v: boolean) => void;
  gridOverlay: boolean;
  onGridOverlayChange: (v: boolean) => void;
  levelGuide: boolean;
  onLevelGuideChange: (v: boolean) => void;
  // Audio configuration
  trackName: string | null;
  regionLabel: string;
  onPickTrack: () => void;
  onOpenRegion: () => void;
  audioOffsetMs: number;
  onAudioOffsetChange: (ms: number) => void;
  countInBeats: CountInBeats;
  onCountInBeatsChange: (v: CountInBeats) => void;
  metronome: boolean;
  onMetronomeChange: (v: boolean) => void;
  // Project / export configuration
  autosave: boolean;
  onAutosaveChange: (v: boolean) => void;
  exportQuality: ExportQualityPref;
  onExportQualityChange: (v: ExportQualityPref) => void;
  onSaveTake: () => void;
  /** Export action: straight to Export when a cut exists, otherwise to Shuffle to make one. */
  onExportAction: () => void;
}

function Tile({
  icon,
  label,
  value,
  onPress,
  children,
}: {
  icon: IoniconName;
  label: string;
  value?: string;
  onPress?: () => void;
  children?: ReactNode;
}) {
  const body = (
    <>
      <Ionicons name={icon} size={21} color={colors.label} />
      <Text style={styles.tileLabel}>{label}</Text>
      {value ? (
        <Text style={styles.tileValue} numberOfLines={1}>
          {value}
        </Text>
      ) : null}
      {children}
    </>
  );
  if (onPress) {
    return (
      <Pressable style={styles.tile} onPress={onPress} accessibilityRole="button">
        {body}
      </Pressable>
    );
  }
  return <View style={styles.tile}>{body}</View>;
}

function WideTile({ label, children }: { label: string; children: ReactNode }) {
  return (
    <View style={styles.wideTile}>
      <Text style={styles.tileLabel}>{label}</Text>
      {children}
    </View>
  );
}

function Group({
  title,
  children,
  more,
}: {
  title: string;
  children: ReactNode;
  more?: ReactNode;
}) {
  const [expanded, setExpanded] = useState(false);
  return (
    <View style={styles.group}>
      <Text style={styles.groupTitle}>{title}</Text>
      <View style={styles.grid}>{children}</View>
      {more ? (
        <>
          <Pressable
            style={styles.moreRow}
            onPress={() => setExpanded((v) => !v)}
            accessibilityRole="button"
            accessibilityState={{ expanded }}>
            <Text style={styles.moreText}>More</Text>
            <Ionicons name={expanded ? 'chevron-up' : 'chevron-down'} size={15} color={colors.accent} />
          </Pressable>
          {expanded ? <View style={styles.moreBody}>{more}</View> : null}
        </>
      ) : null}
    </View>
  );
}

function SwitchRow({ label, value, onChange }: { label: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <View style={styles.switchRow}>
      <Text style={styles.switchLabel}>{label}</Text>
      <Switch value={value} onValueChange={onChange} trackColor={{ true: colors.accent }} />
    </View>
  );
}

/**
 * Settings — CONFIGURATION ONLY, opened by the gear icon.
 *
 * Jaizon's distinction, applied strictly:
 *  - Creative tools (text, transitions, trim/split, speed, volume/fades,
 *    looks, replace/swap, cover frame) are part of making the art — they
 *    live in the Edit stage, on the timeline, where they're contextual.
 *    NONE of them are here.
 *  - Settings is only defaults and device/project configuration:
 *    timer default, resolution/frame-rate preference, mirror, grid/level
 *    guides, audio offset, count-in/metronome, autosave, export-quality
 *    default, device info, and which track/part is loaded.
 *
 * iOS grouped style, NOT a long scroll: groups of 2-column tiles,
 * segmented controls for multi-choice, switches for on/off, one "More"
 * disclosure per group. Nothing here bypasses the guided flow — the
 * only forward action ("Export video") follows the branch: straight
 * to Export when a cut exists, otherwise to the Edit-or-Shuffle choice.
 */
export function SettingsSheet(props: SettingsSheetProps) {
  const { width, height } = Dimensions.get('window');
  return (
    <Sheet visible={props.visible} onClose={props.onClose} title="Settings">
      <Group title="Camera">
        <WideTile label="Camera timer (seconds to get into position — beeps each second)">
          <SegmentedControl
            options={[
              { value: 0 as CountdownSeconds, label: 'Off' },
              { value: 3 as CountdownSeconds, label: '3s' },
              { value: 5 as CountdownSeconds, label: '5s' },
              { value: 10 as CountdownSeconds, label: '10s' },
            ]}
            value={props.countdown}
            onChange={props.onCountdownChange}
            accessibilityLabel="Camera countdown timer"
          />
        </WideTile>
        <WideTile label="Resolution">
          <SegmentedControl
            options={[
              { value: '2160p' as VideoQuality, label: '4K' },
              { value: '1080p' as VideoQuality, label: '1080p' },
              { value: '720p' as VideoQuality, label: '720p' },
              { value: '480p' as VideoQuality, label: '480p' },
            ]}
            value={props.resolution}
            onChange={props.onResolutionChange}
            accessibilityLabel="Recording resolution"
          />
        </WideTile>
        <Tile icon="speedometer-outline" label="Frame rate" value={`${props.frameRate} fps pref.`}>
          <SegmentedControl
            options={[
              { value: 30 as FrameRatePref, label: '30' },
              { value: 60 as FrameRatePref, label: '60' },
            ]}
            value={props.frameRate}
            onChange={props.onFrameRateChange}
            accessibilityLabel="Preferred frame rate"
          />
        </Tile>
        <Tile icon="swap-horizontal-outline" label="Mirror" value={props.mirror ? 'Front mirrored' : 'Off'}>
          <Switch value={props.mirror} onValueChange={props.onMirrorChange} trackColor={{ true: colors.accent }} />
        </Tile>
        <Tile icon="grid-outline" label="Grid" value={props.gridOverlay ? 'Thirds on' : 'Off'}>
          <Switch value={props.gridOverlay} onValueChange={props.onGridOverlayChange} trackColor={{ true: colors.accent }} />
        </Tile>
        <Tile icon="remove-outline" label="Level guide" value={props.levelGuide ? 'Centre line on' : 'Off'}>
          <Switch value={props.levelGuide} onValueChange={props.onLevelGuideChange} trackColor={{ true: colors.accent }} />
        </Tile>
      </Group>

      <Group
        title="Audio"
        more={
          <>
            <SwitchRow label="Beat flash while recording (metronome)" value={props.metronome} onChange={props.onMetronomeChange} />
            <Text style={styles.moreNote}>
              Audio offset corrects Bluetooth/output latency: positive values start the track later, negative
              earlier, in playback and preview sync.
            </Text>
          </>
        }>
        <Tile icon="musical-notes-outline" label="Track" value={props.trackName ?? 'None'} onPress={props.onPickTrack} />
        <Tile icon="cut-outline" label="Part" value={props.regionLabel} onPress={props.onOpenRegion} />
        <Tile icon="swap-vertical-outline" label="Audio offset" value={`${props.audioOffsetMs > 0 ? '+' : ''}${props.audioOffsetMs} ms`}>
          <View style={styles.stepperRow}>
            <Pressable style={styles.stepperButton} onPress={() => props.onAudioOffsetChange(props.audioOffsetMs - 10)} accessibilityRole="button" accessibilityLabel="Decrease audio offset">
              <Text style={styles.stepperText}>−10</Text>
            </Pressable>
            <Pressable style={styles.stepperButton} onPress={() => props.onAudioOffsetChange(props.audioOffsetMs + 10)} accessibilityRole="button" accessibilityLabel="Increase audio offset">
              <Text style={styles.stepperText}>+10</Text>
            </Pressable>
          </View>
        </Tile>
        <Tile icon="timer-outline" label="Count-in (beats before the take — clicks each beat)" value={props.countInBeats === 0 ? 'Off' : `${props.countInBeats} beats`}>
          <SegmentedControl
            options={[
              { value: 0 as CountInBeats, label: 'Off' },
              { value: 4 as CountInBeats, label: '4' },
              { value: 8 as CountInBeats, label: '8' },
            ]}
            value={props.countInBeats}
            onChange={props.onCountInBeatsChange}
            accessibilityLabel="Count-in beats"
          />
        </Tile>
      </Group>

      <Group
        title="Project & export"
        more={
          <>
            <View style={styles.switchRow}>
              <Text style={styles.switchLabel}>Device</Text>
              <Text style={styles.deviceValue}>
                {Platform.OS === 'ios' ? 'iPhone (iOS)' : Platform.OS} · {Math.round(width)}×{Math.round(height)}
              </Text>
            </View>
            <Text style={styles.moreNote}>
              Frame rate is a preference — the camera uses the closest rate the device supports. Resolution
              applies to recording directly.
            </Text>
          </>
        }>
        <Tile icon="cloud-done-outline" label="Autosave" value={props.autosave ? 'On' : 'Off'}>
          <Switch value={props.autosave} onValueChange={props.onAutosaveChange} trackColor={{ true: colors.accent }} />
        </Tile>
        <Tile icon="save-outline" label="Save a take" value="To Photos" onPress={props.onSaveTake} />
        <WideTile label="Export quality default">
          <SegmentedControl
            options={[
              { value: 'high' as ExportQualityPref, label: 'High' },
              { value: 'balanced' as ExportQualityPref, label: 'Balanced' },
              { value: 'small' as ExportQualityPref, label: 'Small file' },
            ]}
            value={props.exportQuality}
            onChange={props.onExportQualityChange}
            accessibilityLabel="Default export quality"
          />
        </WideTile>
        <Tile icon="share-outline" label="Export video" value="After Shuffle" onPress={props.onExportAction} />
      </Group>
    </Sheet>
  );
}

const styles = StyleSheet.create({
  group: { marginBottom: spacing.lg },
  groupTitle: {
    fontSize: 13,
    fontWeight: '600',
    color: colors.labelSecondary,
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    marginBottom: spacing.sm,
  },
  grid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  tile: {
    width: '48.5%',
    minHeight: 74,
    borderRadius: radius.md,
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.08)',
    padding: spacing.md,
    gap: 3,
    alignItems: 'flex-start',
  },
  wideTile: {
    width: '100%',
    borderRadius: radius.md,
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.08)',
    padding: spacing.md,
    gap: spacing.sm,
  },
  tileLabel: { color: colors.label, fontSize: 15, fontWeight: '600' },
  tileValue: { color: colors.labelSecondary, fontSize: 13 },
  moreRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    paddingTop: spacing.sm,
    alignSelf: 'flex-start',
  },
  moreText: { color: colors.accent, fontSize: 14, fontWeight: '600' },
  moreBody: {
    marginTop: spacing.sm,
    borderRadius: radius.md,
    backgroundColor: 'rgba(255,255,255,0.05)',
    padding: spacing.md,
    gap: spacing.sm,
  },
  moreNote: { color: colors.labelSecondary, fontSize: 13, lineHeight: 18 },
  switchRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  switchLabel: { color: colors.label, fontSize: 15 },
  deviceValue: { color: colors.labelSecondary, fontSize: 14 },
  stepperRow: { flexDirection: 'row', gap: spacing.sm, marginTop: 2 },
  stepperButton: {
    backgroundColor: 'rgba(255,255,255,0.12)',
    borderRadius: radius.pill,
    paddingHorizontal: 10,
    paddingVertical: 5,
  },
  stepperText: { color: colors.label, fontSize: 12, fontWeight: '700' },
});
