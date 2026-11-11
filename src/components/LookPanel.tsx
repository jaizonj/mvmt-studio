import { Ionicons } from '@expo/vector-icons';
import Slider from '@react-native-community/slider';
import { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';

import {
  IDENTITY_LOOK_PARAMS,
  LOOK_PARAM_RANGES,
  LOOK_PRESETS,
  lookPresetById,
  resolveLookParams,
} from '../lib/looks';
import { useStudio } from '../store/StudioContext';
import { colors, radius, spacing, type as typeScale } from '../theme';
import type { LookParams } from '../types';

/**
 * Look — the Edit screen's grade section (a creative tool, so it
 * lives here, not in Settings). A dropdown-style preset picker over
 * the tasteful catalog in src/lib/looks.ts, plus an Adjust area whose
 * sliders fork per-param overrides onto the stored look.
 *
 * The grade is part of the composition: picking or adjusting here
 * changes the editor's native preview AND the export identically
 * (both requests resolve the same stored look through
 * resolveLookParams). Sliders commit on release — the LyricsPanel
 * pattern — so a drag doesn't rebuild the preview per tick; the
 * picture updates the moment the finger lifts.
 */

const percent = (v: number) => `${Math.round(v * 100)}%`;
const signedPercent = (v: number) => `${v > 0 ? '+' : ''}${Math.round(v * 100)}%`;

const ADJUST_SLIDERS: {
  key: keyof LookParams;
  label: string;
  format: (v: number) => string;
}[] = [
  { key: 'brightness', label: 'Brightness', format: signedPercent },
  { key: 'contrast', label: 'Contrast', format: percent },
  { key: 'saturation', label: 'Saturation', format: percent },
  { key: 'temperature', label: 'Warmth', format: (v) => `${v > 0 ? '+' : ''}${Math.round(v)}` },
  { key: 'sharpen', label: 'Sharpness', format: percent },
  { key: 'vignette', label: 'Vignette', format: percent },
];

export function LookPanel() {
  const studio = useStudio();
  const look = studio.look;
  const preset = lookPresetById(look.presetId);
  const hasOverrides = !!look.overrides && Object.keys(look.overrides).length > 0;
  const isOriginal = preset.id === 'original';

  const [pickerOpen, setPickerOpen] = useState(false);
  const [adjustOpen, setAdjustOpen] = useState(false);

  // The values the Adjust sliders display: the preset scaled by the
  // master intensity, with any forked override winning for its param.
  const baseParams = resolveLookParams({ presetId: look.presetId, intensity: look.intensity }) ??
    IDENTITY_LOOK_PARAMS;
  const displayParam = (key: keyof LookParams): number => look.overrides?.[key] ?? baseParams[key];

  const pickPreset = (presetId: string) => {
    // A preset pick keeps the master intensity but drops slider
    // overrides — they belonged to the old preset's character.
    studio.setProjectLook({ presetId, intensity: look.intensity, overrides: undefined });
    setPickerOpen(false);
  };

  const commitParam = (key: keyof LookParams, value: number) => {
    studio.setProjectLook({ ...look, overrides: { ...look.overrides, [key]: value } });
  };

  return (
    <View style={styles.section}>
      <View style={styles.panel}>
        <View style={styles.headerRow}>
          <Text style={styles.title}>Look</Text>
          <View style={styles.headerSpacer} />
          <Text style={styles.currentLabel}>
            {preset.name}
            {hasOverrides ? ' · Custom' : ''}
          </Text>
        </View>
        <Text style={styles.caption}>
          A grade for the whole cut — it&apos;s in the preview above and renders into the export.
        </Text>

        {/* Dropdown-style preset picker: the current choice as a
            tappable row, expanding into the full catalog. */}
        <Pressable
          style={styles.pickerRow}
          onPress={() => setPickerOpen((open) => !open)}
          accessibilityRole="button"
          accessibilityLabel={`Look preset: ${preset.name}. Tap to change.`}
          accessibilityState={{ expanded: pickerOpen }}>
          <View style={styles.pickerText}>
            <Text style={styles.pickerName}>{preset.name}</Text>
            <Text style={styles.pickerBlurb} numberOfLines={1}>
              {preset.blurb}
            </Text>
          </View>
          <Ionicons name={pickerOpen ? 'chevron-up' : 'chevron-down'} size={18} color={colors.labelSecondary} />
        </Pressable>
        {pickerOpen ? (
          <ScrollView style={styles.presetList} nestedScrollEnabled showsVerticalScrollIndicator={false}>
            {LOOK_PRESETS.map((candidate) => {
              const selected = candidate.id === preset.id;
              return (
                <Pressable
                  key={candidate.id}
                  style={[styles.presetRow, selected && styles.presetRowSelected]}
                  onPress={() => pickPreset(candidate.id)}
                  accessibilityRole="button"
                  accessibilityLabel={`Use the ${candidate.name} look`}
                  accessibilityState={{ selected }}>
                  <View style={styles.pickerText}>
                    <Text style={[styles.pickerName, selected && styles.presetNameSelected]}>
                      {candidate.name}
                    </Text>
                    <Text style={styles.pickerBlurb} numberOfLines={1}>
                      {candidate.blurb}
                    </Text>
                  </View>
                  {selected ? <Ionicons name="checkmark" size={18} color={colors.accent} /> : null}
                </Pressable>
              );
            })}
          </ScrollView>
        ) : null}

        {!isOriginal ? (
          <>
            <Pressable
              style={styles.adjustRow}
              onPress={() => setAdjustOpen((open) => !open)}
              accessibilityRole="button"
              accessibilityLabel="Adjust the look"
              accessibilityState={{ expanded: adjustOpen }}>
              <Text style={styles.adjustLabel}>Adjust</Text>
              {hasOverrides ? (
                <Pressable
                  hitSlop={8}
                  onPress={() => studio.setProjectLook({ ...look, overrides: undefined })}
                  accessibilityRole="button"
                  accessibilityLabel="Reset adjustments to the preset">
                  <Text style={styles.resetText}>Reset</Text>
                </Pressable>
              ) : null}
              <Ionicons name={adjustOpen ? 'chevron-up' : 'chevron-down'} size={18} color={colors.labelSecondary} />
            </Pressable>
            {adjustOpen ? (
              <View style={styles.sliders}>
                <LookSlider
                  label="Intensity"
                  value={look.intensity}
                  minimumValue={0}
                  maximumValue={1}
                  step={0.01}
                  format={percent}
                  onCommit={(v) => studio.setProjectLook({ ...look, intensity: v })}
                />
                {ADJUST_SLIDERS.map(({ key, label, format }) => {
                  const range = LOOK_PARAM_RANGES[key];
                  return (
                    <LookSlider
                      key={key}
                      label={label}
                      value={displayParam(key)}
                      minimumValue={range.min}
                      maximumValue={range.max}
                      step={(range.max - range.min) / 100}
                      format={format}
                      onCommit={(v) => commitParam(key, v)}
                    />
                  );
                })}
              </View>
            ) : null}
          </>
        ) : null}
      </View>
    </View>
  );
}

function LookSlider({
  label,
  value,
  minimumValue,
  maximumValue,
  step,
  format,
  onCommit,
}: {
  label: string;
  value: number;
  minimumValue: number;
  maximumValue: number;
  step: number;
  format: (v: number) => string;
  onCommit: (v: number) => void;
}) {
  // Draft pattern (LyricsPanel): the finger owns the value while
  // dragging; the store — and with it the preview rebuild — only
  // hears about the value on release.
  const [draft, setDraft] = useState<number | null>(null);
  const shown = draft ?? value;
  return (
    <View>
      <View style={styles.sliderLabelRow}>
        <Text style={styles.sliderLabel}>{label}</Text>
        <Text style={styles.sliderValue}>{format(shown)}</Text>
      </View>
      <Slider
        value={shown}
        minimumValue={minimumValue}
        maximumValue={maximumValue}
        step={step}
        onValueChange={setDraft}
        onSlidingComplete={(v) => {
          onCommit(v);
          setDraft(null);
        }}
        minimumTrackTintColor={colors.accent}
        maximumTrackTintColor={colors.elevated}
        thumbTintColor={colors.label}
        accessibilityLabel={label}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  section: { paddingHorizontal: spacing.xl, marginTop: spacing.md },
  panel: { gap: spacing.sm },
  headerRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  headerSpacer: { flex: 1 },
  title: { ...typeScale.headline, color: colors.label, fontSize: 19 },
  currentLabel: { ...typeScale.footnote, color: colors.labelSecondary },
  caption: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 18 },
  pickerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    minHeight: 52,
  },
  pickerText: { flex: 1, gap: 1 },
  pickerName: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  presetNameSelected: { color: colors.accent },
  pickerBlurb: { ...typeScale.footnote, color: colors.labelSecondary },
  presetList: {
    maxHeight: 264,
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingVertical: spacing.xs,
  },
  presetRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    minHeight: 48,
  },
  presetRowSelected: { backgroundColor: colors.elevated },
  adjustRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    minHeight: 36,
  },
  adjustLabel: { ...typeScale.subhead, color: colors.label, fontWeight: '600', flex: 1 },
  resetText: { ...typeScale.footnote, color: colors.accent, fontWeight: '600' },
  sliders: { gap: spacing.xs },
  sliderLabelRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  sliderLabel: { ...typeScale.caption, color: colors.labelSecondary },
  sliderValue: { ...typeScale.caption, color: colors.label, fontVariant: ['tabular-nums'] },
});
