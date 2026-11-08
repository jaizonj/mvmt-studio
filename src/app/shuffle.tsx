import { Ionicons } from '@expo/vector-icons';
import { LinearGradient } from 'expo-linear-gradient';
import { router } from 'expo-router';
import { useEffect, useMemo, useRef, useState } from 'react';
import { Alert, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { FlowSteps } from '../components/FlowSteps';
import { SegmentedControl } from '../components/SegmentedControl';
import { SettingsSheetConnected } from '../components/SettingsSheetConnected';
import { TimelinePreview, type PreviewClip } from '../components/TimelinePreview';
import { TimelineStrip } from '../components/TimelineStrip';
import { buildSections, effectiveRegion, estimateTakeEnergies, subdivideSections } from '../lib/analysis';
import { generateShuffle } from '../lib/shuffle';
import { useStudio } from '../store/StudioContext';
import { SHUFFLE_FREQUENCY_LENGTHS, type ShuffleFrequency } from '../types';
import { colors, radius, spacing, type as typeScale } from '../theme';

/**
 * Shuffle stage — the heart of the app, and the only way a cut is
 * made (the separate Edit stage was removed, Jaizon 2026-11-08).
 * Flow: Record → Takes → Shuffle → Export. The shuffled cut is shown
 * on the timeline right here, and tapping a cut in that timeline
 * switches which take it uses — that's the editing, Triller-style,
 * all in one place.
 *
 * NO SCORE, MAGIC FEEL: the engine (src/lib/shuffle.ts, unchanged) still
 * generates and scores candidates internally — that's how it picks —
 * but NOTHING numeric or analytic is shown. The experience is: tap, a
 * brief iridescent shimmer, and the new cut auto-plays in the preview.
 * Minimal copy only ("Your cut, remixed ✦").
 *
 * Gating: unreachable with zero takes (locked state below). Export is
 * disabled until the cut is non-empty; if the cut is emptied, Export
 * re-locks. Settings stays configuration only.
 */
export default function ShuffleScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { track, takes, timeline, trackSections, lastShuffle } = studio;
  const [shimmering, setShimmering] = useState(false);
  const [justShuffled, setJustShuffled] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [selectedClipId, setSelectedClipId] = useState<string | null>(null);
  const shimmerTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (shimmerTimer.current) clearTimeout(shimmerTimer.current);
    },
    [],
  );

  const takeEnergies = useMemo(() => estimateTakeEnergies(takes), [takes]);

  const takeIndexById = useMemo(() => {
    const map = new Map<string, number>();
    [...takes].reverse().forEach((t, i) => map.set(t.id, i + 1));
    return map;
  }, [takes]);

  // The cut drawn as a timeline strip — updates the moment a shuffle lands.
  const stripClips = useMemo(
    () =>
      timeline.map((clip) => {
        const take = studio.takeForClip(clip);
        const start = clip.trimStartSeconds ?? 0;
        const end = clip.trimEndSeconds ?? take?.durationSeconds ?? start;
        return {
          id: clip.id,
          label: `Take ${takeIndexById.get(clip.takeId) ?? ''}`,
          lengthSeconds: Math.max(0, end - start),
        };
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [timeline, takes],
  );

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

  const locked = takes.length === 0;
  const hasCut = timeline.length > 0;
  const canShuffle = takes.length >= 2;

  const handleShuffle = () => {
    if (!canShuffle) return;
    const fullDuration =
      track?.durationSeconds ??
      Math.max(...takes.map((t) => t.durationSeconds ?? 0), 0);
    const regionEff = effectiveRegion(studio.trackRegion, fullDuration);
    const duration = regionEff?.lengthSeconds ?? fullDuration;
    if (!duration) {
      Alert.alert('Add a track first', 'Shuffle needs the track length to line sections up. Pick a track on the camera screen, then record a take so its duration is known.');
      return;
    }
    // Shuffle frequency = how often the cut changes clip. Sampled
    // sections are phrase-length, so subdivide them (energies inherited);
    // the fallback builder takes the target length directly.
    const targetLength = SHUFFLE_FREQUENCY_LENGTHS[studio.shuffleFrequency];
    const sections =
      trackSections.length > 0
        ? subdivideSections(trackSections, targetLength)
        : buildSections(duration, 120, regionEff?.startSeconds ?? 0, targetLength);
    const result = generateShuffle(
      sections,
      takes.map((t) => ({ id: t.id, energy: takeEnergies.get(t.id) ?? t.energy ?? 0.5 })),
      {
        candidates: 32,
        previousSequence: lastShuffle?.takeSequence ?? (timeline.length ? timeline.map((c) => c.takeId) : undefined),
      },
    );
    if (!result) return;
    // Each slot is a musical section: the clip is that section *inside* its
    // take (trimmed to the section range, clamped to the take's length), so
    // playing the timeline in order reproduces the track's timing.
    studio.applyTimeline(
      result.slots.map((slot) => {
        const take = takes.find((t) => t.id === slot.takeId);
        const takeLength = take?.durationSeconds;
        const relStart = Math.max(0, slot.startSeconds - (regionEff?.startSeconds ?? 0));
        const relEnd = slot.endSeconds - (regionEff?.startSeconds ?? 0);
        return {
          takeId: slot.takeId,
          trimStartSeconds: relStart,
          trimEndSeconds: takeLength && relEnd >= takeLength ? undefined : relEnd,
        };
      }),
    );
    // The engine's score stays INTERNAL (it picks the winner) — nothing
    // numeric or analytic is ever shown. The user just sees the magic:
    // a brief iridescent shimmer, then the new cut auto-plays.
    studio.setLastShuffle({
      score: result.score,
      candidatesEvaluated: result.candidatesEvaluated,
      takeSequence: result.slots.map((s) => s.takeId),
    });
    setJustShuffled(true);
    setSelectedClipId(null);
    setShimmering(true);
    if (shimmerTimer.current) clearTimeout(shimmerTimer.current);
    shimmerTimer.current = setTimeout(() => setShimmering(false), 950);
  };

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
              accessibilityLabel="Back"
              style={styles.backButton}>
              <Ionicons name="chevron-back" size={26} color={colors.accent} />
              <Text style={styles.backText}>Back</Text>
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
          <Text style={styles.largeTitle}>Shuffle</Text>
          <Text style={styles.headerSubtitle}>
            Remix your takes into a cut
            {timeline.length ? ` · ${timeline.length} clips in your cut` : ''}
          </Text>
          <View style={styles.stepsWrap}>
            <FlowSteps current="shuffle" takesCount={takes.length} cutCount={timeline.length} />
          </View>
        </View>

        {locked ? (
          <View style={[styles.section, styles.emptyCard]}>
            <Ionicons name="lock-closed-outline" size={30} color={colors.labelSecondary} />
            <Text style={styles.emptyTitle}>Record a take first</Text>
            <Text style={styles.emptyBody}>
              Shuffle works on your takes, and there aren&apos;t any yet. Record at least one take — two or more to
              shuffle — and this step unlocks.
            </Text>
            <Pressable style={styles.primaryButton} onPress={() => router.replace('/')} accessibilityRole="button">
              <Ionicons name="videocam-outline" size={18} color="#14141F" />
              <Text style={styles.primaryButtonText}>Back to Record</Text>
            </Pressable>
          </View>
        ) : (
          <>
            {/* Preview of the current cut — auto-plays after a shuffle,
                under a brief iridescent shimmer while it lands. */}
            {previewClips.length > 0 ? (
              <View style={[styles.section, styles.previewWrap]}>
                <TimelinePreview
                  key={previewKey}
                  clips={previewClips}
                  trackUri={track?.uri}
                  trackStartSeconds={(effectiveRegion(studio.trackRegion, track?.durationSeconds)?.startSeconds ?? 0) + studio.audioOffsetMs / 1000}
                />
                {shimmering ? (
                  <LinearGradient
                    colors={['rgba(185,167,255,0.45)', 'rgba(148,233,255,0.30)', 'rgba(255,183,233,0.45)', 'rgba(185,167,255,0.10)']}
                    start={{ x: 0, y: 0 }}
                    end={{ x: 1, y: 1 }}
                    style={styles.shimmer}
                    pointerEvents="none">
                    <Text style={styles.shimmerGlyph}>✦</Text>
                  </LinearGradient>
                ) : null}
              </View>
            ) : (
              <View style={[styles.section, styles.emptyCard]}>
                <Ionicons name="film-outline" size={30} color={colors.labelSecondary} />
                <Text style={styles.emptyTitle}>No cut yet</Text>
                <Text style={styles.emptyBody}>
                  Tap Shuffle and MVMT will arrange your takes into a cut, right here on the timeline.
                </Text>
              </View>
            )}

            {/* The cut, visible as a timeline — watch it rearrange, and
                tap any cut to switch which take it uses (Triller-style).
                This timeline IS the editor now: no separate Edit stage. */}
            {hasCut ? (
              <View style={styles.section}>
                <TimelineStrip
                  clips={stripClips}
                  selectedClipId={selectedClipId}
                  onSelectClip={(id) => setSelectedClipId((cur) => (cur === id ? null : id))}
                />
                {selectedClipId && timeline.some((c) => c.id === selectedClipId) ? (
                  <View style={styles.takePicker}>
                    <Text style={styles.takePickerTitle}>
                      Cut {(timeline.findIndex((c) => c.id === selectedClipId) ?? 0) + 1} · use take:
                    </Text>
                    <View style={styles.takeChipRow}>
                      {takes.map((take) => {
                        const isCurrent = timeline.find((c) => c.id === selectedClipId)?.takeId === take.id;
                        return (
                          <Pressable
                            key={take.id}
                            style={[styles.takeChip, isCurrent && styles.takeChipCurrent]}
                            disabled={isCurrent}
                            onPress={() => studio.assignClipTake(selectedClipId, take.id)}
                            accessibilityRole="button"
                            accessibilityState={{ selected: isCurrent }}
                            accessibilityLabel={`Use take ${takeIndexById.get(take.id)} for this cut`}>
                            <Text style={[styles.takeChipText, isCurrent && styles.takeChipTextCurrent]}>
                              Take {takeIndexById.get(take.id)}
                              {isCurrent ? ' ✓' : ''}
                            </Text>
                          </Pressable>
                        );
                      })}
                    </View>
                  </View>
                ) : null}
              </View>
            ) : null}

            {/* Shuffle frequency — how often the cut changes clip. */}
            <View style={styles.section}>
              <Text style={styles.frequencyLabel}>Shuffle frequency</Text>
              <SegmentedControl
                options={[
                  { value: 'chill' as ShuffleFrequency, label: 'Chill' },
                  { value: 'normal' as ShuffleFrequency, label: 'Normal' },
                  { value: 'fast' as ShuffleFrequency, label: 'Fast' },
                  { value: 'rapid' as ShuffleFrequency, label: 'Rapid' },
                ]}
                value={studio.shuffleFrequency}
                onChange={studio.setShuffleFrequency}
                accessibilityLabel="Shuffle frequency — how often the cut changes clip"
              />
              <Text style={styles.caption}>
                {studio.shuffleFrequency === 'chill'
                  ? 'Chill — longer clips, changes about every 4 seconds.'
                  : studio.shuffleFrequency === 'normal'
                    ? 'Normal — changes about every 2 seconds.'
                    : studio.shuffleFrequency === 'fast'
                      ? 'Fast — changes about every second.'
                      : 'Rapid — a new clip almost every beat.'}{' '}
                Applies to the next shuffle.
              </Text>
            </View>

            {/* THE shuffle action */}
            <View style={styles.section}>
              <Pressable
                style={[styles.shuffleButton, !canShuffle && styles.shuffleButtonDisabled]}
                onPress={handleShuffle}
                disabled={!canShuffle}
                accessibilityRole="button"
                accessibilityLabel={hasCut ? 'Shuffle again for a different arrangement' : 'Shuffle takes into an edit'}>
                <Ionicons name="shuffle" size={20} color="#14141F" />
                <Text style={styles.shuffleButtonText}>
                  {shimmering ? 'Shuffling…' : hasCut && lastShuffle ? 'Shuffle again' : 'Shuffle my cut'}
                </Text>
              </Pressable>
              {/* Minimal, confident copy only. No scores, no analysis —
                  Shuffle should feel like magic, not a report card. */}
              {!canShuffle ? (
                <Text style={styles.caption}>Shuffle needs at least 2 takes — record one more performance.</Text>
              ) : justShuffled ? (
                <Text style={styles.caption}>Your cut, remixed ✦</Text>
              ) : (
                <Text style={styles.caption}>One tap. A whole new arrangement.</Text>
              )}
              {hasCut ? (
                <Text style={styles.keepNote}>
                  Not feeling a cut? Tap it in the timeline above and switch its take — or shuffle again. Export
                  whenever you&apos;re ready.
                </Text>
              ) : null}
            </View>
          </>
        )}
      </ScrollView>

      {/* Export bar — on THIS stage, and locked until the cut exists. */}
      {!locked ? (
        <View style={[styles.exportBar, { paddingBottom: Math.max(insets.bottom, spacing.md) }]}>
          <Pressable
            style={[styles.exportButton, !hasCut && styles.exportButtonDisabled]}
            onPress={() => hasCut && router.push('/export')}
            disabled={!hasCut}
            accessibilityRole="button"
            accessibilityLabel={hasCut ? 'Export your video' : 'Export, locked until your cut has a clip'}>
            <Ionicons name={hasCut ? 'share-outline' : 'lock-closed-outline'} size={18} color={hasCut ? '#14141F' : colors.labelTertiary} />
            <Text style={[styles.exportButtonText, !hasCut && styles.exportButtonTextDisabled]}>Export</Text>
          </Pressable>
          <Text style={styles.nextCaption}>
            {hasCut ? 'Your cut, ready to export' : 'Shuffle to build your cut and unlock Export'}
          </Text>
        </View>
      ) : null}

      {/* Settings — configuration only, also reachable from here. Real
          values come from the store via the connected wrapper. */}
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
        }}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.groupedBackground },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.lg },
  headerRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  backButton: { flexDirection: 'row', alignItems: 'center', marginLeft: -6, marginBottom: spacing.xs },
  backText: { color: colors.accent, fontSize: 17 },
  gearButton: { padding: 6, marginBottom: spacing.xs },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  headerSubtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: 2 },
  stepsWrap: { marginTop: spacing.lg, alignItems: 'flex-start' },
  section: { paddingHorizontal: spacing.xl, marginBottom: spacing.xl },
  previewWrap: { position: 'relative' },
  shimmer: {
    position: 'absolute',
    top: 0,
    left: spacing.xl,
    right: spacing.xl,
    bottom: 0,
    borderRadius: radius.lg,
    alignItems: 'center',
    justifyContent: 'center',
  },
  shimmerGlyph: { fontSize: 44, color: '#FFFFFF', opacity: 0.9 },
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
  shuffleButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.md,
    paddingVertical: 15,
  },
  shuffleButtonDisabled: { opacity: 0.35 },
  shuffleButtonText: { color: '#14141F', fontSize: 17, fontWeight: '700' },
  frequencyLabel: { ...typeScale.headline, color: colors.label, marginBottom: spacing.sm },
  takePicker: { marginTop: spacing.md },
  takePickerTitle: { color: colors.label, fontSize: 14, fontWeight: '700', marginBottom: spacing.sm },
  takeChipRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  takeChip: {
    borderWidth: 1,
    borderColor: colors.materialBorder,
    backgroundColor: colors.card,
    borderRadius: radius.pill,
    paddingHorizontal: 14,
    paddingVertical: 9,
  },
  takeChipCurrent: { backgroundColor: '#FFFFFF', borderColor: '#FFFFFF' },
  takeChipText: { color: colors.label, fontSize: 14, fontWeight: '700' },
  takeChipTextCurrent: { color: '#14141F' },
  caption: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 18, marginTop: spacing.sm },
  keepNote: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 18, marginTop: spacing.sm },
  keepNoteStrong: { color: colors.label, fontWeight: '700' },
  disclosureRow: { flexDirection: 'row', alignItems: 'center', gap: 5, alignSelf: 'flex-start', paddingVertical: 4 },
  disclosureText: { color: colors.accent, fontSize: 15, fontWeight: '600' },
  card: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    paddingHorizontal: spacing.lg,
    marginTop: spacing.md,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.md,
    flexWrap: 'wrap',
  },
  rowSeparator: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.separator },
  rowSelected: { backgroundColor: colors.accentDim, borderRadius: radius.md },
  rowMain: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  rowBadge: {
    width: 26,
    height: 26,
    borderRadius: 13,
    backgroundColor: 'rgba(255,255,255,0.14)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  rowBadgeText: { color: colors.label, fontSize: 13, fontWeight: '700' },
  rowTitle: { ...typeScale.headline, color: colors.label },
  rowSubtitle: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: 1, lineHeight: 17 },
  trimBar: {
    flexBasis: '100%',
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    paddingTop: spacing.sm,
    flexWrap: 'wrap',
  },
  trimLabel: { ...typeScale.footnote, color: colors.labelSecondary, fontWeight: '600' },
  trimButton: {
    backgroundColor: 'rgba(255,255,255,0.12)',
    borderRadius: radius.pill,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  trimButtonText: { color: colors.label, fontSize: 12, fontWeight: '600' },
  undoButton: { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: spacing.md },
  undoText: { color: colors.accent, fontSize: 15, fontWeight: '500' },
  exportBar: {
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.md,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    backgroundColor: colors.groupedBackground,
    gap: spacing.xs,
  },
  exportButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 14,
  },
  exportButtonDisabled: { backgroundColor: 'rgba(255,255,255,0.10)' },
  exportButtonText: { color: '#14141F', fontSize: 17, fontWeight: '700' },
  exportButtonTextDisabled: { color: colors.labelTertiary },
  nextCaption: { ...typeScale.caption, color: colors.labelTertiary, textAlign: 'center' },
});
