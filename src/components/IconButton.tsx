import { Ionicons } from '@expo/vector-icons';
import { BlurView } from 'expo-blur';
import { Pressable, StyleSheet, Text } from 'react-native';

import { colors } from '../theme';

type IoniconName = React.ComponentProps<typeof Ionicons>['name'];

interface IconButtonProps {
  icon: IoniconName;
  onPress: () => void;
  accessibilityLabel: string;
  active?: boolean;
  disabled?: boolean;
  /** Optional text under the glyph (camera rails use labelled controls sparingly). */
  label?: string;
  size?: number;
}

/**
 * Circular translucent-material button in the iOS system style: blur + tint,
 * white SF-Symbol-style (Ionicons outline) glyph, subtle border.
 */
export function IconButton({ icon, onPress, accessibilityLabel, active, disabled, label, size = 44 }: IconButtonProps) {
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
      accessibilityState={{ disabled: !!disabled, selected: !!active }}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [styles.wrap, disabled && styles.disabled, pressed && styles.pressed]}>
      <BlurView
        intensity={45}
        tint="dark"
        style={[
          styles.circle,
          { width: size, height: size, borderRadius: size / 2 },
          active && styles.circleActive,
        ]}>
        <Ionicons name={icon} size={size * 0.48} color={active ? '#14141F' : '#FFFFFF'} />
      </BlurView>
      {label ? <Text style={styles.label}>{label}</Text> : null}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  wrap: {
    alignItems: 'center',
    gap: 4,
  },
  pressed: {
    opacity: 0.7,
    transform: [{ scale: 0.94 }],
  },
  disabled: {
    opacity: 0.35,
  },
  circle: {
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: colors.materialBorder,
    backgroundColor: colors.material,
  },
  circleActive: {
    backgroundColor: 'rgba(255,255,255,0.92)',
    borderColor: 'rgba(255,255,255,0.95)',
  },
  label: {
    color: colors.label,
    fontSize: 11,
    fontWeight: '500',
    textShadowColor: 'rgba(0,0,0,0.45)',
    textShadowRadius: 4,
  },
});
