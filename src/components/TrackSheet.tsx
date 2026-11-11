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
  const { track, songLibrary, applyLibrarySong, deleteSongLibraryEntry } = useStudio();
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
          {/* The region is stored live as the handles move; this is
              the explicit confirm that closes the sheet — on first
              pick and on every later change via the notes icon. */}
          <Pressable style={styles.confirmButton} onPress={onClose} accessibilityRole="button">
            <Text style={styles.confirmButtonText}>Use this part</Text>
          </Pressable>
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
      {visible && songLibrary.length > 0 ? (
        <>
          <Text style={styles.sectionLabel}>Song library</Text>
          {songLibrary.map((entry) => (
            <View key={entry.key} style={styles.libraryRow}>
              <Pressable
                style={styles.libraryMain}
                onPress={() => applyLibrarySong(entry)}
                accessibilityRole="button"
                accessibilityLabel={`Use ${entry.name} with its saved lyrics`}>
                <Ionicons name="library" size={17} color={colors.accent} />
                <View style={styles.libraryText}>
                  <Text style={styles.libraryName} numberOfLines={1}>
                    {entry.name}
                  </Text>
                  <Text style={styles.libraryMeta}>
                    Lyrics saved · {entry.lyrics.lines.length} {entry.lyrics.lines.length === 1 ? 'line' : 'lines'}
                  </Text>
                </View>
              </Pressable>
              <Pressable
                onPress={() => deleteSongLibraryEntry(entry.key)}
                hitSlop={8}
                accessibilityRole="button"
                accessibilityLabel={`Remove ${entry.name} from the library`}>
                <Ionicons name="trash-outline" size={17} color={colors.labelSecondary} />
              </Pressable>
            </View>
          ))}
          <Text style={styles.libraryHint}>
            Picking a library song loads its audio with the lyrics you already fixed for it.
          </Text>
        </>
      ) : null}
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
  confirmButton: {
    marginTop: spacing.lg,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 13,
  },
  confirmButtonText: { color: colors.onAccent, fontSize: 15, fontWeight: '700' },
  libraryRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: 'rgba(255,255,255,0.05)',
    borderRadius: radius.md,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  libraryMain: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  libraryText: { flex: 1, gap: 2 },
  libraryName: { color: colors.label, fontSize: 14, fontWeight: '600' },
  libraryMeta: { color: colors.labelSecondary, fontSize: 12 },
  libraryHint: { color: colors.labelSecondary, fontSize: 12, lineHeight: 17, marginTop: 2 },
});
