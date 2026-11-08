import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { useMemo, useState } from 'react';
import { ActivityIndicator, Alert, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { FlowSteps } from '../components/FlowSteps';
import { TimelinePreview, type PreviewClip } from '../components/TimelinePreview';
import { effectiveRegion } from '../lib/analysis';
import { isCompositorAvailable, renderVideo, type CompositeResult } from '../lib/compositor';
import { saveToPhotoLibrary, shareFile } from '../lib/media';
import { useStudio } from '../store/StudioContext';
import { colors, radius, spacing, type as typeScale } from '../theme';

/**
 * Export — the end of the flow (Record → Takes → Shuffle → Export).
 *
 * Reachable with a non-empty cut, and only with a non-empty cut:
 *  - zero takes → locked, "Record a take first", back to Record;
 *  - takes but an empty cut → locked, back to Shuffle to make the cut.
 * If the cut is emptied after arriving (takes deleted upstream), this
 * screen re-locks on the next render. Going back always works.
 *
 * Rendering: the native compositing engine (AVFoundation, local Expo
 * module `modules/mvmt-compositor`) renders the cut into ONE mp4 with
 * the master track laid over it. It only exists in development / EAS
 * builds — Expo Go cannot run custom native code — so in Expo Go this
 * screen says so plainly and per-take Save/Share remains the fallback.
 */
export default function ExportScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { track, takes, timeline } = studio;

  const takeIndexById = useMemo(() => {
    const map = new Map<string, number>();
    [...takes].reverse().forEach((t, i) => map.set(t.id, i + 1));
    return map;
  }, [takes]);

  const previewClips: PreviewClip[] = useMemo(
    () =>
      timeline
        .map((clip): PreviewClip | null => {
          const take = studio.takeForClip(clip);
          if (!take) return null;
          return {
            id: clip.id,
            uri: take.uri,
            trimStartSeconds: clip.trimStartSeconds ?? 0,
            trimEndSeconds: clip.trimEndSeconds,
            durationSeconds: take.durationSeconds,
            volume: clip.volume,
            muted: clip.muted,
          };
        })
        .filter((c): c is PreviewClip => c !== null),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [timeline, takes],
  );
  const previewKey = previewClips.map((c) => `${c.id}:${c.trimStartSeconds}-${c.trimEndSeconds ?? ''}:${c.muted ? 'm' : ''}${c.volume ?? ''}`).join('|');

  const noTakes = takes.length === 0;
  const emptyCut = !noTakes && timeline.length === 0;
  const locked = noTakes || emptyCut;

  const engineAvailable = isCompositorAvailable();
  const [rendering, setRendering] = useState(false);
  const [rendered, setRendered] = useState<CompositeResult | null>(null);

  const handleRender = async () => {
    setRendering(true);
    try {
      const clips = previewClips.map((clip) => ({
        uri: clip.uri,
        startSeconds: clip.trimStartSeconds,
        durationSeconds: Math.max(
          0.1,
          (clip.trimEndSeconds ?? clip.durationSeconds ?? clip.trimStartSeconds + 1) - clip.trimStartSeconds,
        ),
        muted: clip.muted ?? false,
        volume: clip.volume ?? 1,
      }));
      const region = effectiveRegion(studio.trackRegion, track?.durationSeconds);
      const result = await renderVideo({
        clips,
        audioUri: track?.uri ?? null,
        audioStartSeconds: Math.max(0, (region?.startSeconds ?? 0) + studio.audioOffsetMs / 1000),
        audioVolume: 1,
      });
      setRendered(result);
    } catch (error) {
      Alert.alert('Render failed', error instanceof Error ? error.message : 'Something went wrong while rendering.');
    } finally {
      setRendering(false);
    }
  };

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={{ paddingTop: insets.top + spacing.md, paddingBottom: insets.bottom + spacing.xxl }}>
      <View style={styles.header}>
        <Pressable
          onPress={() => router.back()}
          hitSlop={10}
          accessibilityRole="button"
          accessibilityLabel="Back"
          style={styles.backButton}>
          <Ionicons name="chevron-back" size={26} color={colors.accent} />
          <Text style={styles.backText}>Back</Text>
        </Pressable>
        <Text style={styles.largeTitle}>Export</Text>
        <Text style={styles.headerSubtitle}>
          {locked ? 'Locked — finish the earlier steps first' : `${timeline.length} clips · your cut`}
        </Text>
        <View style={styles.stepsWrap}>
          <FlowSteps current="export" takesCount={takes.length} cutCount={timeline.length} />
        </View>
      </View>

      {locked ? (
        <View style={[styles.section, styles.emptyCard]}>
          <Ionicons name="lock-closed-outline" size={30} color={colors.labelSecondary} />
          <Text style={styles.emptyTitle}>{noTakes ? 'Record a take first' : 'Your cut is empty'}</Text>
          <Text style={styles.emptyBody}>
            {noTakes
              ? 'Export is the end of the flow: Record → Takes → Shuffle → Export. There\'s nothing to export until you\'ve recorded a take.'
              : 'You have takes, but no cut yet. Let Shuffle build one — then Export unlocks.'}
          </Text>
          <Pressable
            style={styles.primaryButton}
            onPress={() => (noTakes ? router.replace('/') : router.replace('/shuffle'))}
            accessibilityRole="button">
            <Ionicons name={noTakes ? 'videocam-outline' : 'git-branch-outline'} size={18} color="#14141F" />
            <Text style={styles.primaryButtonText}>{noTakes ? 'Back to Record' : 'Go to Shuffle'}</Text>
          </Pressable>
        </View>
      ) : (
        <>
          {previewClips.length > 0 ? (
            <View style={styles.section}>
              <TimelinePreview
                key={previewKey}
                clips={previewClips}
                trackUri={track?.uri}
                trackStartSeconds={
                  (effectiveRegion(studio.trackRegion, track?.durationSeconds)?.startSeconds ?? 0) +
                  studio.audioOffsetMs / 1000
                }
              />
            </View>
          ) : null}

          <Text style={styles.sectionTitle}>Export video</Text>
          <View style={styles.card}>
            <View style={styles.row}>
              <Ionicons name="film-outline" size={20} color={colors.label} />
              <View style={{ flex: 1 }}>
                <Text style={styles.rowTitle}>Your finished video</Text>
                <Text style={styles.rowSubtitle}>
                  {engineAvailable
                    ? 'The native engine stitches your cut into one video with the track laid over it.'
                    : 'One-tap rendering needs the full app build — Expo Go can\'t run the native video engine. In the full build this button renders your cut into one video. For now, save or share individual takes:'}
                </Text>
              </View>
            </View>
            {engineAvailable ? (
              <View style={[styles.row, styles.rowSeparator]}>
                {rendered ? (
                  <>
                    <Text style={[styles.rowTitle, { flex: 1 }]}>Rendered · {rendered.durationSeconds.toFixed(1)}s</Text>
                    <Pressable
                      hitSlop={8}
                      onPress={async () =>
                        Alert.alert(
                          'Save to Photos',
                          (await saveToPhotoLibrary(rendered.uri)) ? 'Saved.' : 'Photos permission was not granted.',
                        )
                      }
                      accessibilityRole="button"
                      accessibilityLabel="Save rendered video to Photos">
                      <Ionicons name="save-outline" size={22} color={colors.label} />
                    </Pressable>
                    <Pressable
                      hitSlop={8}
                      onPress={async () => {
                        if (!(await shareFile(rendered.uri, 'video/mp4')))
                          Alert.alert('Sharing unavailable', 'Sharing is not available on this device.');
                      }}
                      accessibilityRole="button"
                      accessibilityLabel="Share rendered video">
                      <Ionicons name="share-outline" size={22} color={colors.label} />
                    </Pressable>
                  </>
                ) : (
                  <Pressable
                    style={styles.renderButton}
                    onPress={() => void handleRender()}
                    disabled={rendering}
                    accessibilityRole="button"
                    accessibilityLabel="Render my video">
                    {rendering ? <ActivityIndicator color="#14141F" /> : null}
                    <Text style={styles.renderButtonText}>{rendering ? 'Rendering…' : 'Render video'}</Text>
                  </Pressable>
                )}
              </View>
            ) : null}
            {takes.slice(0, 3).map((take) => (
              <View key={take.id} style={[styles.row, styles.rowSeparator]}>
                <Text style={[styles.rowTitle, { flex: 1 }]}>Take {takeIndexById.get(take.id)}</Text>
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
              </View>
            ))}
          </View>
        </>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.groupedBackground },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.lg },
  backButton: { flexDirection: 'row', alignItems: 'center', marginLeft: -6, marginBottom: spacing.xs },
  backText: { color: colors.accent, fontSize: 17 },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  headerSubtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: 2 },
  stepsWrap: { marginTop: spacing.lg, alignItems: 'flex-start' },
  section: { paddingHorizontal: spacing.xl, marginBottom: spacing.xl },
  sectionTitle: {
    ...typeScale.title2,
    color: colors.label,
    paddingHorizontal: spacing.xl,
    marginTop: spacing.xl,
    marginBottom: spacing.sm,
  },
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
  renderButton: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.pill,
    paddingVertical: 12,
  },
  renderButtonText: { color: '#14141F', fontSize: 15, fontWeight: '700' },
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
  rowSubtitle: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: 1, lineHeight: 17 },
});
