import { StyleSheet, View, type StyleProp, type ViewStyle } from 'react-native';
import type { ReactNode } from 'react';

import { colors, radius, spacing } from '../../theme';

/**
 * Grouped-content container (DESIGN_SYSTEM §1: grouped lists on
 * colors.card are the default container, one level of nesting max).
 * Settings groups and any future grouped list share this surface.
 */
export function GroupCard({ children, style }: { children: ReactNode; style?: StyleProp<ViewStyle> }) {
  return <View style={[styles.card, style]}>{children}</View>;
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.lg,
    marginHorizontal: spacing.xl,
  },
});
