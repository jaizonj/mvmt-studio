import { Ionicons } from '@expo/vector-icons';
import type { ReactNode } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing, type as typeScale } from '../theme';

/**
 * CollapsibleSection — one grouped, collapsible block of the Edit
 * screen (Edit modes, Shuffle, Look, Lyrics, Project). The header
 * is a tappable card row carrying the title and a one-line summary
 * of what's inside (current Look, line count, watermark state), so
 * a collapsed section still tells the user what it holds. Children
 * stay mounted when collapsed (display: none) so panels keep their
 * tab, search and selection state — collapsing is a view choice,
 * never a reset. The preview and timeline live outside the
 * sections, so the hero of the screen is never buried.
 */

interface CollapsibleSectionProps {
  title: string;
  summary?: string;
  open: boolean;
  onToggle: () => void;
  children: ReactNode;
  accessibilityLabel?: string;
}

export function CollapsibleSection({
  title,
  summary,
  open,
  onToggle,
  children,
  accessibilityLabel,
}: CollapsibleSectionProps) {
  return (
    <View style={styles.section}>
      <Pressable
        style={styles.header}
        onPress={onToggle}
        accessibilityRole="button"
        accessibilityLabel={accessibilityLabel ?? `${title} section`}
        accessibilityState={{ expanded: open }}>
        <Text style={styles.title}>{title}</Text>
        {summary ? (
          <Text style={styles.summary} numberOfLines={1}>
            {summary}
          </Text>
        ) : null}
        <Ionicons name={open ? 'chevron-up' : 'chevron-down'} size={18} color={colors.labelSecondary} />
      </Pressable>
      <View style={[styles.body, !open && styles.bodyHidden]}>{children}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  section: { paddingHorizontal: spacing.xl, marginTop: spacing.md },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    minHeight: 52,
  },
  title: { ...typeScale.headline, color: colors.label, fontSize: 17 },
  summary: { ...typeScale.footnote, color: colors.labelSecondary, flex: 1, textAlign: 'right' },
  body: { gap: spacing.sm, marginTop: spacing.sm },
  bodyHidden: { display: 'none' },
});
