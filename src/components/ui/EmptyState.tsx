import { Ionicons } from '@expo/vector-icons';
import { StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing, type as typeScale } from '../../theme';
import { PrimaryButton } from './PrimaryButton';

type IoniconName = React.ComponentProps<typeof Ionicons>['name'];

interface EmptyStateProps {
  icon: IoniconName;
  title: string;
  body: string;
  actionLabel?: string;
  onAction?: () => void;
  actionIcon?: IoniconName;
}

/**
 * The single empty-state pattern (DESIGN_SYSTEM §5): a quiet card,
 * one icon, one line of explanation, and at most one way forward.
 * Used by Studio (no projects) and Projects (empty library).
 */
export function EmptyState({ icon, title, body, actionLabel, onAction, actionIcon }: EmptyStateProps) {
  return (
    <View style={styles.card}>
      <View style={styles.iconBadge}>
        <Ionicons name={icon} size={28} color={colors.labelSecondary} />
      </View>
      <Text style={styles.title}>{title}</Text>
      <Text style={styles.body}>{body}</Text>
      {actionLabel && onAction ? (
        <View style={styles.action}>
          <PrimaryButton label={actionLabel} icon={actionIcon} onPress={onAction} />
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    paddingVertical: spacing.xxl,
    paddingHorizontal: spacing.xl,
    alignItems: 'center',
  },
  iconBadge: {
    width: 56,
    height: 56,
    borderRadius: radius.pill,
    backgroundColor: colors.elevated,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: spacing.lg,
  },
  title: { ...typeScale.headline, color: colors.label, textAlign: 'center' },
  body: {
    ...typeScale.subhead,
    color: colors.labelSecondary,
    textAlign: 'center',
    lineHeight: 21,
    marginTop: spacing.sm,
  },
  action: { alignSelf: 'stretch', marginTop: spacing.xl },
});
