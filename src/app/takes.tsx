import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { Alert, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SettingsSheetConnected } from '../components/SettingsSheetConnected';
import { saveToPhotoLibrary, shareFile } from '../lib/media';
import { useStudio } from '../store/StudioContext';
import { colors, formatTime, radius, spacing, type as typeScale } from '../theme';

/**
 * Stage 2 — Takes review.
 *
 * TikTok-style: you land here straight after recording. Review what you
 * shot, delete the duds, and (if you want a hand-built cut) add takes to
 * the cut.
 *
 * Gating: this screen is only reachable with at least one take (the
 * camera blocks navigation before that with "Record a take first").
 * If every take is deleted while you're here, the step re-locks and
 * the empty state points back to Record. Going back to the camera
 * always works and preserves takes + cut.
 * The flow is one clean line (no Edit stage): Record → Takes →
 * Shuffle → Export. From here, straight to Shuffle.
 */
export default function TakesScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { track, takes, timeline } = studio;

  const takeIndexById = useMemo(() => {
    const map = new Map<string, number>();
    [...takes].reverse().forEach((t, i) => map.set(t.id, i + 1));
    return map;
  }, [takes]);

  const locked = takes.length === 0;
  const [settingsOpen, setSettingsOpen] = useState(false);

  return (
    <View style={styles.root}>
      <ScrollView
        style={{ flex: 1 }}
        contentContainerStyle={{ paddingTop: insets.top + spacing.md, paddingBottom: spacing.xl }}>
        <View style={styles.header}>
          <View style={styles.headerRow}>
            <Pressable
              onPress={() => router.back()}
              hitSlop={10}
              accessibilityRole="button"
              accessibilityLabel="Back to camera"
              style={styles.backButton}>
              <Ionicons name="chevron-back" size={26} color={colors.accent} />
              <Text style={styles.backText}>Record</Text>
            </Pressable>
            <Pressable
              onPress={() => setSettingsOpen(true)}
              hitSlop={10}
              accessibilityRole="button"
              accessibilityLabel="Settings"
              style={styles.gearButton}>
              <Ionicons name="settings-outline" size={23} color={colors.label} />
            </Pressable>
          </View>
          <Text style={styles.largeTitle}>Your takes</Text>
          <Text style={styles.headerSubtitle}>
            {track ? track.name : 'No track loaded'}
            {takes.length ? ` · ${takes.length} take${takes.length === 1 ? '' : 's'}` : ''}
            {timeline.length ? ` · ${timeline.length} in your cut` : ''}
          </Text>
        </View>

        {locked ? (
          <View style={[styles.section, styles.emptyCard]}>
            <Ionicons name="lock-closed-outline" size={30} color={colors.labelSecondary} />
            <Text style={styles.emptyTitle}>Record a take first</Text>
            <Text style={styles.emptyBody}>
              This step unlocks once you&apos;ve recorded something. Head back to the camera and shoot your first
              take — it plays the track from the top, so it&apos;ll be in sync.
            </Text>
            <Pressable style={styles.primaryButton} onPress={() => router.back()} accessibilityRole="button">
              <Ionicons name="videocam-outline" size={18} color="#14141F" />
              <Text style={styles.primaryButtonText}>Back to Record</Text>
            </Pressable>
          </View>
        ) : (
          <>
            <View style={styles.card}>
              {takes.map((take, i) => (
                <View key={take.id} style={[styles.row, i > 0 && styles.rowSeparator]}>
                  <Ionicons
                    name={take.facing === 'front' ? 'person-outline' : 'videocam-outline'}
                    size={20}
                    color={colors.label}
                  />
                  <View style={{ flex: 1 }}>
                    <Text style={styles.rowTitle}>Take {takeIndexById.get(take.id)}</Text>
                    <Text style={styles.rowSubtitle}>
                      {take.durationSeconds ? `${formatTime(take.durationSeconds)} · ` : ''}
                      {take.facing === 'front' ? 'Front camera' : 'Back camera'}
                    </Text>
                  </View>
                  <Pressable
                    hitSlop={8}
                    onPress={async () =>
                      Alert.alert(
                        'Save to Photos',
                        (await saveToPhotoLibrary(take.uri)) ? 'Saved.' : 'Photos permission was not granted.',
                      )
                    }
                    accessibilityRole="button"
                    accessibilityLabel="Save take to Photos">
                    <Ionicons name="save-outline" size={22} color={colors.label} />
                  </Pressable>
                  <Pressable
                    hitSlop={8}
                    onPress={async () => {
                      if (!(await shareFile(take.uri, 'video/mp4')))
                        Alert.alert('Sharing unavailable', 'Sharing is not available on this device.');
                    }}
                    accessibilityRole="button"
                    accessibilityLabel="Share take">
                    <Ionicons name="share-outline" size={22} color={colors.label} />
                  </Pressable>
                  <Pressable
                    hitSlop={8}
                    onPress={() => studio.removeTake(take.id)}
                    accessibilityRole="button"
                    accessibilityLabel="Delete take">
                    <Ionicons name="trash-outline" size={22} color={colors.danger} />
                  </Pressable>
                </View>
              ))}
            </View>
            <Text style={styles.hint}>
              Next, Shuffle arranges these takes into a cut — then tap any cut in its timeline to switch which
              take it uses. Deleting a take also removes it from your cut.
            </Text>
          </>
        )}
      </ScrollView>

      {/* Next — straight to Shuffle, where the cut is made and adjusted
          on its timeline, then Export. One clean line. */}
      {!locked ? (
        <View style={[styles.nextBar, { paddingBottom: Math.max(insets.bottom, spacing.md) }]}>
          <Pressable
            style={styles.nextButton}
            onPress={() => router.push('/shuffle')}
            accessibilityRole="button"
            accessibilityLabel="Continue to Shuffle">
            <Ionicons name="shuffle-outline" size={18} color="#14141F" />
            <Text style={styles.nextButtonText}>Shuffle my takes</Text>
          </Pressable>
          <Text style={styles.nextCaption}>Then adjust the shuffle on its timeline, and export</Text>
        </View>
      ) : null}

      <SettingsSheetConnected
        visible={settingsOpen}
        onClose={() => setSettingsOpen(false)}
        onPickTrack={() => {
          setSettingsOpen(false);
          router.replace('/');
        }}
        onOpenRegion={() => {
          setSettingsOpen(false);
          router.replace('/');
        }}
        onExportAction={() => {
          setSettingsOpen(false);
          if (timeline.length > 0) router.push('/export');
          else router.push('/shuffle');
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.groupedBackground },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.lg },
  backButton: { flexDirection: 'row', alignItems: 'center', marginLeft: -6, marginBottom: spacing.xs },
  backText: { color: colors.accent, fontSize: 17 },
  headerRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  gearButton: { padding: 6, marginBottom: spacing.xs },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  headerSubtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: 2 },
  section: { paddingHorizontal: spacing.xl },
  emptyCard: {
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.xl,
    marginHorizontal: spacing.xl,
  },
  emptyTitle: { ...typeScale.headline, color: colors.label },
  emptyBody: { ...typeScale.subhead, color: colors.labelSecondary, lineHeight: 20, textAlign: 'center' },
  primaryButton: {
    marginTop: spacing.sm,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.pill,
    paddingHorizontal: 18,
    paddingVertical: 11,
  },
  primaryButtonText: { color: '#14141F', fontSize: 15, fontWeight: '700' },
  card: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    marginHorizontal: spacing.xl,
    paddingHorizontal: spacing.lg,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.md,
  },
  rowSeparator: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.separator },
  rowTitle: { ...typeScale.headline, color: colors.label },
  rowSubtitle: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: 1 },
  hint: {
    ...typeScale.footnote,
    color: colors.labelSecondary,
    lineHeight: 18,
    paddingHorizontal: spacing.xl,
    marginTop: spacing.md,
  },
  nextBar: {
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.md,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    backgroundColor: colors.groupedBackground,
    gap: spacing.xs,
  },
  nextButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.md,
    paddingVertical: 14,
  },
  nextButtonText: { color: '#14141F', fontSize: 17, fontWeight: '700' },
  nextCaption: { ...typeScale.caption, color: colors.labelTertiary, textAlign: 'center' },
});
