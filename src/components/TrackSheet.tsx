import { Ionicons } from '@expo/vector-icons';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { useStudio } from '../store/StudioContext';
import { colors, radius, spacing } from '../theme';
import { AudioRegionPicker } from './AudioRegionPicker';
import { Sheet } from './Sheet';

interface TrackSheetProps {
  visible: boolean;
  onClose: () => void;
  onPickTrack: () => void;
}

/** Track sheet: which song, and which part of it (the AudioRegionPicker). */
export function TrackSheet({ visible, onClose, onPickTrack }: TrackSheetProps) {
  const { track } = useStudio();
  return (
    <Sheet visible={visible} onClose={onClose} title="Track">
      {visible && track ? (
        <>
          <View style={styles.trackRow}>
            <Ionicons name="musical-notes" size={19} color={colors.label} />
            <Text style={styles.trackName} numberOfLines={1}>
              {track.name}
            </Text>
            <Pressable onPress={onPickTrack} hitSlop={8} accessibilityRole="button" accessibilityLabel="Change track">
              <Text style={styles.change}>Change</Text>
            </Pressable>
          </View>
          <Text style={styles.sectionLabel}>Choose the part</Text>
          <AudioRegionPicker />
        </>
      ) : (
        <>
          <Text style={styles.empty}>
            No track yet. Add an audio file and MVMT will play it while you record, so every take lines up.
          </Text>
          <Pressable style={styles.addButton} onPress={onPickTrack} accessibilityRole="button">
            <Ionicons name="add" size={18} color="#14141F" />
            <Text style={styles.addButtonText}>Add a track</Text>
          </Pressable>
        </>
      )}
    </Sheet>
  );
}

const styles = StyleSheet.create({
  trackRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderRadius: radius.md,
    padding: spacing.md,
  },
  trackName: { flex: 1, color: colors.label, fontSize: 15, fontWeight: '600' },
  change: { color: colors.accent, fontSize: 15, fontWeight: '600' },
  sectionLabel: {
    fontSize: 13,
    fontWeight: '600',
    color: colors.labelSecondary,
    textTransform: 'uppercase',
    letterSpacing: 0.6,
    marginTop: spacing.lg,
    marginBottom: spacing.sm,
  },
  empty: { color: colors.labelSecondary, fontSize: 15, lineHeight: 21 },
  addButton: {
    marginTop: spacing.lg,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.md,
    paddingVertical: 13,
  },
  addButtonText: { color: '#14141F', fontSize: 15, fontWeight: '700' },
});
