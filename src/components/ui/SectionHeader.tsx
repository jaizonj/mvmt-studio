import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, spacing, type as typeScale } from '../../theme';

interface SectionHeaderProps {
  title: string;
  subtitle?: string;
  /** 'section' = in-page heading (title2); 'group' = settings-style eyebrow label. */
  variant?: 'section' | 'group';
  actionLabel?: string;
  onAction?: () => void;
}

/**
 * Shared heading row (DESIGN_SYSTEM §5). One typographic voice for
 * section titles on Studio/Projects and group titles in Settings, so
 * the three tabs read as one product.
 */
export function SectionHeader({ title, subtitle, variant = 'section', actionLabel, onAction }: SectionHeaderProps) {
  if (variant === 'group') {
    return (
      <View style={styles.groupWrap}>
        <Text style={styles.groupTitle}>{title}</Text>
        {subtitle ? <Text style={styles.groupSubtitle}>{subtitle}</Text> : null}
      </View>
    );
  }
  return (
    <View style={styles.row}>
      <View style={{ flex: 1 }}>
        <Text style={styles.title}>{title}</Text>
        {subtitle ? <Text style={styles.subtitle}>{subtitle}</Text> : null}
      </View>
      {actionLabel && onAction ? (
        <Pressable
          onPress={onAction}
          hitSlop={8}
          accessibilityRole="button"
          accessibilityLabel={actionLabel}
          style={({ pressed }) => pressed && styles.actionPressed}>
          <Text style={styles.action}>{actionLabel}</Text>
        </Pressable>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  row: { flexDirection: 'row', alignItems: 'flex-end', gap: spacing.md, marginBottom: spacing.md },
  title: { ...typeScale.title2, color: colors.label },
  subtitle: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: spacing.xs },
  action: { ...typeScale.subhead, color: colors.accent, fontWeight: '600' },
  actionPressed: { opacity: 0.6 },
  groupWrap: { paddingHorizontal: spacing.xl, marginTop: spacing.xl, marginBottom: spacing.sm },
  groupTitle: {
    ...typeScale.caption,
    color: colors.labelSecondary,
    fontWeight: '700',
    letterSpacing: 0.9,
    textTransform: 'uppercase',
  },
  groupSubtitle: { ...typeScale.footnote, color: colors.labelTertiary, marginTop: spacing.xs },
});
