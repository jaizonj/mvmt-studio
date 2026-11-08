import { Ionicons } from '@expo/vector-icons';
import { Image } from 'expo-image';
import type { VideoThumbnail } from 'expo-video';
import { router } from 'expo-router';
import { useEffect, useMemo, useState } from 'react';
import { Alert, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { NativePreview } from '../../components/NativePreview';
import { EmptyState } from '../../components/ui/EmptyState';
import { PrimaryButton } from '../../components/ui/PrimaryButton';
import type { CompositeRequest } from '../../lib/compositor';
import { getCachedThumbnail, loadThumbnails } from '../../lib/thumbnails';
import { useStudio } from '../../store/StudioContext';
import type { Take } from '../../types';
import { colors, formatTime, radius, spacing, type as typeScale } from '../../theme';

/**
 * Stage 2 — Takes review (Wave 2 redesign, DESIGN_SYSTEM §3.4).
 *
 * The review experience is visual first: every take is a real filmstrip
 * of its own frames, with its name, when it was shot, which camera, and
 * its sync status in plain words ("In sync", "Sync not measured", …) —
 * never raw numbers. Tap a take to preview it in the native player
 * (muted, exactly the frames the editor will use); rename and delete
 * live in the row's overflow menu, and deleting a take that the
 * current cut uses warns that the cut will be cleared with it.
 *
 * Forward action: "Open Editor". Gating: with no takes the screen is
 * an empty state pointing back to Record.
 */

/** Frame-sample times for a take's filmstrip (deterministic per take). */
function sampleTimes(take: Take): number[] {
  const d = take.durationSeconds;
  if (d && d > 0.2) return [0.18, 0.5, 0.82].map((f) => Math.round(d * f * 100) / 100);
  return [0.4, 1.2, 2.0];
}

type SyncTone = 'success' | 'adjusted' | 'off' | 'unmeasured';

/**
 * Sync status in human words, from the take's MEASURED sync offset
 * (seconds, stored on the take at record time). Thresholds: within
 * ~1 frame at 30fps (0.04s) reads as plainly in sync; up to 0.10s is
 * in sync with a slight offset worth knowing about; beyond that the
 * take needs a check before export. No raw values are ever shown.
 */
function syncStatus(take: Take): { text: string; tone: SyncTone } {
  const offset = take.syncOffsetSeconds;
  if (offset === undefined) return { text: 'Sync not measured', tone: 'unmeasured' };
  const magnitude = Math.abs(offset);
  if (magnitude <= 0.04) return { text: 'In sync', tone: 'success' };
  if (magnitude <= 0.1) return { text: 'In sync · slight offset', tone: 'adjusted' };
  return { text: 'Off sync — check before export', tone: 'off' };
}

const SYNC_DOT_COLORS: Record<SyncTone, string> = {
  success: colors.success,
  adjusted: colors.labelTertiary,
  off: colors.danger,
  unmeasured: colors.labelTertiary,
};

function formatClockTime(epochMs: number): string {
  return new Date(epochMs).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

/** A take's filmstrip: three real frames across the take, cover-fit. */
function TakeFilmstrip({ take }: { take: Take }) {
  const times = sampleTimes(take);
  return (
    <View style={styles.filmstrip}>
      {times.map((t, i) => {
        const thumb: VideoThumbnail | null | undefined = getCachedThumbnail(take.uri, t);
        return thumb ? (
          <Image key={i} source={thumb} style={styles.filmTile} contentFit="cover" />
        ) : (
          <View
            key={i}
            style={[styles.filmTile, { backgroundColor: i % 2 ? colors.cardPressed : colors.elevated }]}
          />
        );
      })}
      {take.durationSeconds ? (
        <View style={styles.durationBadge}>
          <Text style={styles.durationBadgeText}>{formatTime(take.durationSeconds)}</Text>
        </View>
      ) : null}
    </View>
  );
}

export default function TakesScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { activeProject, track, takes, edl } = studio;

  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [previewPaused, setPreviewPaused] = useState(false);
  const [, setThumbTick] = useState(0);

  // Chronological order (oldest first): "Take N" numbering follows the
  // session — Take 1 is the first take recorded — and the list reads
  // in the order the takes were shot.
  const sortedTakes = useMemo(
    () => [...takes].sort((a, b) => a.createdAt - b.createdAt || a.id.localeCompare(b.id)),
    [takes],
  );
  const takeNumberById = useMemo(() => {
    const map = new Map<string, number>();
    // Stable store-assigned sequence numbers win (survives deletions);
    // takes recorded before they existed fall back to session order.
    sortedTakes.forEach((t, i) => map.set(t.id, t.seq ?? i + 1));
    return map;
  }, [sortedTakes]);

  const takeName = (take: Take) =>
    take.displayName?.trim() ? take.displayName.trim() : `Take ${takeNumberById.get(take.id) ?? ''}`;

  // How many cuts of the current edit each take fills (in-cut badge +
  // the delete warning both read this).
  const edlUseCountByTakeId = useMemo(() => {
    const map = new Map<string, number>();
    for (const segment of edl?.segments ?? []) {
      map.set(segment.takeId, (map.get(segment.takeId) ?? 0) + 1);
    }
    return map;
  }, [edl]);

  // Generate any filmstrip frames not already cached, then re-render.
  const takesKey = sortedTakes.map((t) => `${t.id}:${t.durationSeconds ?? 0}`).join('|');
  useEffect(() => {
    let alive = true;
    const byUri = new Map<string, number[]>();
    for (const take of sortedTakes) {
      for (const t of sampleTimes(take)) {
        if (getCachedThumbnail(take.uri, t) === undefined) {
          const list = byUri.get(take.uri) ?? [];
          list.push(t);
          byUri.set(take.uri, list);
        }
      }
    }
    if (byUri.size === 0) return;
    Promise.all([...byUri.entries()].map(([uri, times]) => loadThumbnails(uri, times))).then(() => {
      if (alive) setThumbTick((n) => n + 1);
    });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [takesKey]);

  const selectedTake = sortedTakes.find((t) => t.id === selectedId) ?? null;

  // One-clip native preview of the selected take: muted, no song — the
  // take exactly as the editor will use it. Only buildable once the
  // take's length is known (the composition needs a real duration).
  const previewRequest: CompositeRequest | null = useMemo(
    () =>
      selectedTake?.durationSeconds
        ? {
            clips: [
              {
                uri: selectedTake.uri,
                startSeconds: 0,
                durationSeconds: selectedTake.durationSeconds,
                muted: true,
                volume: 1,
              },
            ],
            audioUri: null,
          }
        : null,
    [selectedTake],
  );

  const selectTake = (take: Take) => {
    if (selectedId === take.id) {
      setSelectedId(null);
    } else {
      setSelectedId(take.id);
      setPreviewPaused(false);
    }
  };

  const promptRename = (take: Take) => {
    Alert.prompt(
      'Rename take',
      'Give this take a name.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Save',
          onPress: (text?: string) => {
            const name = text?.trim().slice(0, 40);
            studio.updateTake(take.id, { displayName: name ? name : undefined });
          },
        },
      ],
      'plain-text',
      take.displayName ?? '',
    );
  };

  const confirmDelete = (take: Take) => {
    const inCut = (edlUseCountByTakeId.get(take.id) ?? 0) > 0;
    Alert.alert(
      `Delete ${takeName(take)}?`,
      inCut
        ? 'This take is used in your current cut. Deleting it will also clear the cut.'
        : 'This take will be permanently deleted.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: () => {
            studio.removeTake(take.id);
            if (inCut) studio.setEdl(null);
            if (selectedId === take.id) setSelectedId(null);
          },
        },
      ],
    );
  };

  const openTakeMenu = (take: Take) => {
    Alert.alert(takeName(take), undefined, [
      { text: 'Rename', onPress: () => promptRename(take) },
      { text: 'Delete', style: 'destructive', onPress: () => confirmDelete(take) },
      { text: 'Cancel', style: 'cancel' },
    ]);
  };

  const locked = takes.length === 0;

  return (
    <View style={styles.root}>
      <ScrollView
        style={{ flex: 1 }}
        contentContainerStyle={{ paddingTop: insets.top + spacing.md, paddingBottom: spacing.xl }}>
        <View style={styles.header}>
          <Pressable
            onPress={() => router.back()}
            hitSlop={10}
            accessibilityRole="button"
            accessibilityLabel="Back to Record"
            style={styles.backButton}>
            <Ionicons name="chevron-back" size={26} color={colors.accent} />
            <Text style={styles.backText}>Record</Text>
          </Pressable>
          <Text style={styles.largeTitle}>Takes</Text>
          <Text style={styles.headerSubtitle}>
            {track ? track.name : (activeProject?.name ?? 'Your project')}
            {takes.length ? ` · ${takes.length} take${takes.length === 1 ? '' : 's'}` : ''}
          </Text>
        </View>

        {locked ? (
          <View style={styles.section}>
            <EmptyState
              icon="videocam-outline"
              title="Record a take first"
              body="Takes you record will appear here — watch them back, drop the duds, and know they're in sync before you cut."
              actionLabel="Back to Record"
              onAction={() => router.replace('/project/record')}
            />
          </View>
        ) : (
          <>
            {/* Preview pane — the selected take in the native player. */}
            {selectedTake ? (
              <View style={styles.section}>
                {previewRequest ? (
                  <>
                    <NativePreview
                      request={previewRequest}
                      requestKey={selectedTake.id}
                      paused={previewPaused}
                      style={styles.preview}
                    />
                    <View style={styles.transportRow}>
                      <Pressable
                        style={styles.playButton}
                        onPress={() => setPreviewPaused((p) => !p)}
                        accessibilityRole="button"
                        accessibilityLabel={previewPaused ? `Play ${takeName(selectedTake)}` : 'Pause preview'}>
                        <Ionicons name={previewPaused ? 'play' : 'pause'} size={20} color={colors.label} />
                      </Pressable>
                      <View style={{ flex: 1 }}>
                        <Text style={styles.transportTitle} numberOfLines={1}>
                          {takeName(selectedTake)}
                        </Text>
                        <Text style={styles.transportSub}>
                          {selectedTake.durationSeconds ? formatTime(selectedTake.durationSeconds) : ''}
                          {selectedTake.facing === 'front' ? ' · Front camera' : ' · Back camera'}
                        </Text>
                      </View>
                    </View>
                  </>
                ) : (
                  <View style={styles.noteCard}>
                    <Text style={styles.noteText}>
                      Preview unavailable until this take&apos;s length is known.
                    </Text>
                  </View>
                )}
              </View>
            ) : (
              <View style={styles.section}>
                <Text style={styles.hint}>Tap a take to preview it.</Text>
              </View>
            )}

            {/* The takes — one grouped card, filmstrip rows. */}
            <View style={styles.card}>
              {sortedTakes.map((take, i) => {
                const status = syncStatus(take);
                const useCount = edlUseCountByTakeId.get(take.id) ?? 0;
                const selected = selectedId === take.id;
                const renamed = !!take.displayName?.trim();
                return (
                  <Pressable
                    key={take.id}
                    onPress={() => selectTake(take)}
                    style={[styles.row, i > 0 && styles.rowSeparator, selected && styles.rowSelected]}
                    accessibilityRole="button"
                    accessibilityState={{ selected }}
                    accessibilityLabel={`${takeName(take)}, ${take.facing === 'front' ? 'front' : 'back'} camera, recorded ${formatClockTime(take.createdAt)}, ${status.text}. Tap to preview.`}>
                    <TakeFilmstrip take={take} />
                    <View style={styles.rowInfo}>
                      <View style={styles.titleRow}>
                        <Text style={styles.rowTitle} numberOfLines={1}>
                          {takeName(take)}
                        </Text>
                        {useCount > 0 ? (
                          <View style={styles.inCutBadge}>
                            <Text style={styles.inCutBadgeText}>
                              In your cut{useCount > 1 ? ` ×${useCount}` : ''}
                            </Text>
                          </View>
                        ) : null}
                      </View>
                      <Text style={styles.rowSubtitle} numberOfLines={1}>
                        {renamed ? `Take ${takeNumberById.get(take.id)} · ` : ''}
                        {take.facing === 'front' ? 'Front camera' : 'Back camera'} ·{' '}
                        {formatClockTime(take.createdAt)}
                      </Text>
                      <View style={styles.syncRow}>
                        <View style={[styles.syncDot, { backgroundColor: SYNC_DOT_COLORS[status.tone] }]} />
                        <Text style={styles.syncText}>{status.text}</Text>
                      </View>
                    </View>
                    <Pressable
                      hitSlop={10}
                      onPress={() => openTakeMenu(take)}
                      style={styles.overflowButton}
                      accessibilityRole="button"
                      accessibilityLabel={`Options for ${takeName(take)}`}>
                      <Ionicons name="ellipsis-horizontal" size={22} color={colors.labelSecondary} />
                    </Pressable>
                  </Pressable>
                );
              })}
            </View>
          </>
        )}
      </ScrollView>

      {/* Forward action — the Editor (Auto + Manual) works from one
          take; shuffling between takes needs two, said in the caption
          when there's only one. */}
      {!locked ? (
        <View style={[styles.actionBand, { paddingBottom: Math.max(insets.bottom, spacing.md) }]}>
          <PrimaryButton label="Open Editor" icon="cut-outline" onPress={() => router.push('/project/editor')} />
          {takes.length === 1 ? (
            <Text style={styles.actionCaption}>
              One take is enough to edit — record another to shuffle between takes.
            </Text>
          ) : null}
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.groupedBackground },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.lg },
  backButton: { flexDirection: 'row', alignItems: 'center', marginLeft: -6, marginBottom: spacing.xs },
  backText: { color: colors.accent, fontSize: 17 },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  headerSubtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: 2 },
  section: { paddingHorizontal: spacing.xl, marginBottom: spacing.xl },

  preview: { width: 216, aspectRatio: 9 / 16, alignSelf: 'center' },
  transportRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    width: 216,
    alignSelf: 'center',
    marginTop: spacing.md,
  },
  playButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: colors.card,
    alignItems: 'center',
    justifyContent: 'center',
  },
  transportTitle: { ...typeScale.headline, color: colors.label },
  transportSub: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: 1, fontVariant: ['tabular-nums'] },

  noteCard: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.lg,
    alignItems: 'center',
  },
  noteText: { ...typeScale.footnote, color: colors.labelSecondary, textAlign: 'center', lineHeight: 18 },
  hint: { ...typeScale.footnote, color: colors.labelSecondary },

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
    borderRadius: radius.sm,
  },
  rowSeparator: { borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: colors.separator },
  rowSelected: { backgroundColor: colors.cardPressed },
  rowInfo: { flex: 1, gap: 2 },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  rowTitle: { ...typeScale.headline, color: colors.label, flexShrink: 1 },
  inCutBadge: {
    backgroundColor: colors.accentDim,
    borderRadius: radius.pill,
    paddingHorizontal: 8,
    paddingVertical: 2,
  },
  inCutBadgeText: { ...typeScale.caption, color: colors.accent },
  rowSubtitle: { ...typeScale.footnote, color: colors.labelSecondary },
  syncRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 2 },
  syncDot: { width: 7, height: 7, borderRadius: 4 },
  syncText: { ...typeScale.caption, color: colors.labelSecondary },
  overflowButton: { padding: 6, alignSelf: 'flex-start' },

  filmstrip: {
    width: 108,
    height: 72,
    borderRadius: radius.sm,
    overflow: 'hidden',
    flexDirection: 'row',
    backgroundColor: colors.elevated,
  },
  filmTile: { width: 36, height: 72 },
  durationBadge: {
    position: 'absolute',
    right: 4,
    bottom: 4,
    backgroundColor: colors.material,
    borderRadius: 4,
    paddingHorizontal: 5,
    paddingVertical: 1,
  },
  durationBadgeText: { ...typeScale.caption, color: colors.label, fontVariant: ['tabular-nums'] },

  actionBand: {
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.md,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    backgroundColor: colors.groupedBackground,
    gap: spacing.xs,
  },
  actionCaption: { ...typeScale.caption, color: colors.labelTertiary, textAlign: 'center' },
});
