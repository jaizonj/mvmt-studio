import { Ionicons } from '@expo/vector-icons';
import { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing, type as typeScale } from '../theme';

/**
 * DropdownPicker — one compact select for the Edit screen's
 * option rows (LookPanel's preset picker pattern, shared): the
 * current choice as a tappable card row, expanding into the full
 * option list. Picks close the list again. `value` may be null —
 * an action list (rhythm modes) with no persistent selection shows
 * the placeholder instead.
 */

export interface DropdownOption<T extends string | number> {
  value: T;
  label: string;
  description?: string;
  disabled?: boolean;
}

interface DropdownPickerProps<T extends string | number> {
  value: T | null;
  placeholder: string;
  options: readonly DropdownOption<T>[];
  onChange: (value: T) => void;
  accessibilityLabel: string;
}

export function DropdownPicker<T extends string | number>({
  value,
  placeholder,
  options,
  onChange,
  accessibilityLabel,
}: DropdownPickerProps<T>) {
  const [open, setOpen] = useState(false);
  const selected = value !== null ? options.find((o) => o.value === value) : undefined;
  return (
    <View>
      <Pressable
        style={styles.row}
        onPress={() => setOpen((was) => !was)}
        accessibilityRole="button"
        accessibilityLabel={accessibilityLabel}
        accessibilityState={{ expanded: open }}>
        <View style={styles.text}>
          <Text style={styles.value}>{selected ? selected.label : placeholder}</Text>
          {selected?.description ? (
            <Text style={styles.description} numberOfLines={1}>
              {selected.description}
            </Text>
          ) : null}
        </View>
        <Ionicons name={open ? 'chevron-up' : 'chevron-down'} size={18} color={colors.labelSecondary} />
      </Pressable>
      {open ? (
        <View style={styles.list}>
          {options.map((option) => {
            const isSelected = value !== null && option.value === value;
            return (
              <Pressable
                key={String(option.value)}
                disabled={option.disabled}
                onPress={() => {
                  onChange(option.value);
                  setOpen(false);
                }}
                accessibilityRole="button"
                accessibilityLabel={option.description ? `${option.label} — ${option.description}` : option.label}
                accessibilityState={{ selected: isSelected, disabled: !!option.disabled }}
                style={[styles.optionRow, option.disabled && styles.optionDisabled]}>
                <View style={styles.text}>
                  <Text style={[styles.optionLabel, isSelected && styles.optionLabelSelected]}>
                    {option.label}
                  </Text>
                  {option.description ? (
                    <Text style={styles.description} numberOfLines={1}>
                      {option.description}
                    </Text>
                  ) : null}
                </View>
                {isSelected ? <Ionicons name="checkmark" size={18} color={colors.accent} /> : null}
              </Pressable>
            );
          })}
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    minHeight: 52,
  },
  text: { flex: 1, gap: 1 },
  value: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  description: { ...typeScale.footnote, color: colors.labelSecondary },
  list: {
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingVertical: spacing.xs,
    marginTop: spacing.xs,
  },
  optionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    minHeight: 48,
  },
  optionDisabled: { opacity: 0.4 },
  optionLabel: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  optionLabelSelected: { color: colors.accent },
});
