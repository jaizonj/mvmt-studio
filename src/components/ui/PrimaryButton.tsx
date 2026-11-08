import { Ionicons } from '@expo/vector-icons';
import { ActivityIndicator, Pressable, StyleSheet, Text } from 'react-native';

import { colors, radius, spacing, type as typeScale } from '../../theme';

type IoniconName = React.ComponentProps<typeof Ionicons>['name'];

interface PrimaryButtonProps {
  label: string;
  onPress: () => void;
  icon?: IoniconName;
  disabled?: boolean;
  loading?: boolean;
  accessibilityLabel?: string;
}

/**
 * The one primary action style (DESIGN_SYSTEM §5): acid-lime fill,
 * on-accent label, full width in its container. Press feedback is a
 * subtle scale + dim — immediate, native-driver friendly, no library.
 */
export function PrimaryButton({ label, onPress, icon, disabled, loading, accessibilityLabel }: PrimaryButtonProps) {
  const inactive = disabled || loading;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={accessibilityLabel ?? label}
      accessibilityState={{ disabled: !!inactive, busy: !!loading }}
      disabled={inactive}
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        inactive && styles.buttonDisabled,
        pressed && !inactive && styles.buttonPressed,
      ]}>
      {loading ? (
        <ActivityIndicator size="small" color={colors.onAccent} />
      ) : icon ? (
        <Ionicons name={icon} size={19} color={inactive ? colors.labelTertiary : colors.onAccent} />
      ) : null}
      <Text style={[styles.label, inactive && styles.labelDisabled]} numberOfLines={1}>
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 15,
    paddingHorizontal: spacing.lg,
    minHeight: 52,
  },
  buttonDisabled: { backgroundColor: colors.elevated },
  buttonPressed: { opacity: 0.88, transform: [{ scale: 0.98 }] },
  label: { ...typeScale.headline, color: colors.onAccent },
  labelDisabled: { color: colors.labelTertiary },
});
