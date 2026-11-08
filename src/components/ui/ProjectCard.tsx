import { Ionicons } from '@expo/vector-icons';
import { Image } from 'expo-image';
import { useEffect, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { getCachedThumbnail, loadThumbnails } from '../../lib/thumbnails';
import { colors, radius, spacing, type as typeScale } from '../../theme';
import type { Project } from '../../types';

/** "Just now" / "5m ago" / "2h ago" / "Yesterday" / "12 Oct" — recency in words. */
export function formatRelativeUpdated(updatedAt: number): string {
  const diffMs = Date.now() - updatedAt;
  const minutes = Math.floor(diffMs / 60000);
  if (minutes < 1) return 'Just now';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days === 1) return 'Yesterday';
  if (days < 7) return `${days}d ago`;
  return new Date(updatedAt).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

/** Stage-aware state line for a project (DESIGN_SYSTEM §3.1). */
function stageState(project: Project): string {
  if (!project.track) return 'No song yet';
  if (project.takes.length === 0) return 'Ready to record';
  if (project.exportedAt && project.edl) return 'Exported';
  if (project.edl) return 'Ready to export';
  return 'Ready to edit';
}

interface ProjectCardProps {
  project: Project;
  /** hero = Studio Continue (tall portrait media); list = Studio Recent / Projects. */
  variant?: 'hero' | 'list';
  onPress: () => void;
  onRename?: () => void;
  onDelete?: () => void;
  isActive?: boolean;
}

/**
 * Project card (DESIGN_SYSTEM §3.1.1 / §5): real media first — the
 * first take's opening frame, cover-fit, never stretched — with a
 * designed graphite placeholder when the project has no takes yet.
 * Pressed state is the shared cardPressed surface.
 */
export function ProjectCard({ project, variant = 'list', onPress, onRename, onDelete, isActive }: ProjectCardProps) {
  const hero = variant === 'hero';
  const firstTake = project.takes[0];
  const thumbUri = firstTake?.uri;
  const [, setThumbTick] = useState(0);

  useEffect(() => {
    if (!thumbUri) return;
    if (getCachedThumbnail(thumbUri, 0) !== undefined) return;
    let alive = true;
    loadThumbnails(thumbUri, [0]).then(() => {
      if (alive) setThumbTick((n) => n + 1);
    });
    return () => {
      alive = false;
    };
  }, [thumbUri]);

  const thumb = thumbUri ? getCachedThumbnail(thumbUri, 0) : null;
  const songLine = project.track ? project.track.name : 'No song yet';
  const metaLine = `${songLine}${project.takes.length ? ` · ${project.takes.length} take${project.takes.length === 1 ? '' : 's'}` : ''}`;
  const stateLine = hero
    ? `${stageState(project)} · ${formatRelativeUpdated(project.updatedAt)}`
    : `${stageState(project)} · ${formatRelativeUpdated(project.updatedAt)}`;

  return (
    <Pressable
      onPress={onPress}
      accessibilityRole="button"
      accessibilityLabel={`${project.name}. ${metaLine}. ${stateLine}`}
      style={({ pressed }) => [styles.card, hero && styles.cardHero, pressed && styles.cardPressed]}>
      {thumb ? (
        <Image
          source={thumb}
          style={[styles.thumb, hero ? styles.thumbHero : styles.thumbList]}
          contentFit="cover"
          transition={150}
        />
      ) : (
        <View style={[styles.thumb, hero ? styles.thumbHero : styles.thumbList, styles.thumbPlaceholder]}>
          <Ionicons name="musical-notes" size={hero ? 26 : 20} color={colors.labelTertiary} />
        </View>
      )}
      <View style={styles.content}>
        <View style={styles.titleRow}>
          <Text style={[styles.name, hero && styles.nameHero]} numberOfLines={1}>
            {project.name}
          </Text>
          {isActive ? (
            <View style={styles.activeBadge}>
              <Text style={styles.activeBadgeText}>Current</Text>
            </View>
          ) : null}
        </View>
        <Text style={styles.meta} numberOfLines={1}>
          {metaLine}
        </Text>
        <Text style={styles.state} numberOfLines={1}>
          {stateLine}
        </Text>
      </View>
      {onRename || onDelete ? (
        <View style={styles.actions}>
          {onRename ? (
            <Pressable
              onPress={onRename}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel={`Rename ${project.name}`}
              style={({ pressed }) => [styles.actionButton, pressed && styles.actionPressed]}>
              <Ionicons name="pencil-outline" size={18} color={colors.labelSecondary} />
            </Pressable>
          ) : null}
          {onDelete ? (
            <Pressable
              onPress={onDelete}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel={`Delete ${project.name}`}
              style={({ pressed }) => [styles.actionButton, pressed && styles.actionPressed]}>
              <Ionicons name="trash-outline" size={18} color={colors.danger} />
            </Pressable>
          ) : null}
        </View>
      ) : (
        <Ionicons name="chevron-forward" size={18} color={colors.labelTertiary} />
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.md,
  },
  cardHero: { padding: spacing.lg, gap: spacing.lg },
  cardPressed: { backgroundColor: colors.cardPressed },
  thumb: { borderRadius: radius.sm, backgroundColor: colors.elevated },
  thumbList: { width: 54, height: 72 },
  thumbHero: { width: 72, height: 96 },
  thumbPlaceholder: { alignItems: 'center', justifyContent: 'center' },
  content: { flex: 1 },
  titleRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  name: { ...typeScale.headline, color: colors.label, flexShrink: 1 },
  nameHero: { fontSize: 19 },
  activeBadge: {
    backgroundColor: colors.accentDim,
    borderRadius: radius.pill,
    paddingHorizontal: spacing.sm,
    paddingVertical: 2,
  },
  activeBadgeText: { ...typeScale.caption, color: colors.accent },
  meta: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: spacing.xs },
  state: { ...typeScale.caption, color: colors.labelTertiary, marginTop: spacing.xs },
  actions: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  actionButton: {
    width: 36,
    height: 36,
    borderRadius: radius.pill,
    backgroundColor: colors.elevated,
    alignItems: 'center',
    justifyContent: 'center',
  },
  actionPressed: { opacity: 0.6 },
});
