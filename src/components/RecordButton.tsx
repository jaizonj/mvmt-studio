import { LinearGradient } from 'expo-linear-gradient';
import { Pressable, StyleSheet, View } from 'react-native';

import { colors } from '../theme';

interface RecordButtonProps {
  recording: boolean;
  disabled?: boolean;
  onPress: () => void;
}

/**
 * Capture button, bottom centre — iOS Camera / Snapchat placement.
 * Design rule: iridescent is a THIN accent ring only; the button itself is
 * the familiar white ring + red dot (stop square while recording).
 */
export function RecordButton({ recording, disabled, onPress }: RecordButtonProps) {
  return (
    <Pressable
      accessibilityLabel={recording ? 'Stop recording' : 'Start recording'}
      accessibilityRole="button"
      accessibilityState={{ disabled: !!disabled }}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [styles.wrap, pressed && styles.pressed, disabled && styles.disabled]}>
      <LinearGradient
        colors={[...colors.iridescent]}
        start={{ x: 0, y: 0 }}
        end={{ x: 1, y: 1 }}
        style={styles.ring}>
        <View style={styles.inner}>
          <View style={recording ? styles.stopSquare : styles.recordDot} />
        </View>
      </LinearGradient>
      {/* thin accent ring = the 3pt gradient border above; inner stays system-white */}
    </Pressable>
  );
}

const RING = 76;

const styles = StyleSheet.create({
  wrap: {
    width: RING,
    height: RING,
    borderRadius: RING / 2,
    shadowColor: '#000',
    shadowOpacity: 0.35,
    shadowRadius: 10,
    shadowOffset: { width: 0, height: 4 },
    elevation: 6,
  },
  pressed: {
    transform: [{ scale: 0.94 }],
  },
  disabled: {
    opacity: 0.4,
  },
  ring: {
    flex: 1,
    borderRadius: RING / 2,
    padding: 3,
  },
  inner: {
    flex: 1,
    borderRadius: RING / 2,
    borderWidth: 4,
    borderColor: '#FFFFFF',
    backgroundColor: 'transparent',
    alignItems: 'center',
    justifyContent: 'center',
  },
  recordDot: {
    width: 52,
    height: 52,
    borderRadius: 26,
    backgroundColor: colors.danger,
  },
  stopSquare: {
    width: 34,
    height: 34,
    borderRadius: 8,
    backgroundColor: colors.danger,
  },
});
