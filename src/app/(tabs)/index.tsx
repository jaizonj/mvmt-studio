import { router } from 'expo-router';
import { useEffect, useRef } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { EmptyState } from '../../components/ui/EmptyState';
import { PrimaryButton } from '../../components/ui/PrimaryButton';
import { ProjectCard } from '../../components/ui/ProjectCard';
import { SectionHeader } from '../../components/ui/SectionHeader';
import { useStudio } from '../../store/StudioContext';
import { colors, spacing, type as typeScale } from '../../theme';

/**
 * Studio home — the front door (Overhaul IA, docs/DESIGN_SYSTEM.md §3.1).
 * A creative workspace, not a dashboard: wordmark, one prominent
 * New Project action, Continue with real media, Recent as visual cards.
 * No stats, no clutter.
 */
export default function StudioHome() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { activeProject, projects, hydrated } = studio;

  // Open straight into the camera (Jaizon, 2026-11-09: "the app
  // doesn't open with the camera running"). With an active project,
  // a cold launch lands in its Record screen — camera live,
  // Snapchat-style. Once per mount: backing out to Studio to look
  // at projects must not bounce straight back in.
  const launchedRef = useRef(false);
  useEffect(() => {
    if (!hydrated || !activeProject || launchedRef.current) return;
    launchedRef.current = true;
    router.push('/project/record');
  }, [hydrated, activeProject]);

  const startNewProject = () => {
    studio.createProject();
    router.push('/project/record');
  };

  const openProject = (id: string) => {
    studio.openProject(id);
    router.push('/project/record');
  };

  const isEmpty = hydrated && projects.length === 0;
  const recent = projects.filter((p) => p.id !== activeProject?.id).slice(0, 5);
  const hasMoreRecent = projects.filter((p) => p.id !== activeProject?.id).length > recent.length;

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={{ paddingTop: insets.top + spacing.xxxl, paddingBottom: spacing.xxxl }}>
      <View style={styles.hero}>
        <View style={styles.eyebrowRow}>
          <View style={styles.eyebrowDot} />
          <Text style={styles.eyebrow}>MUSIC VIDEO STUDIO</Text>
        </View>
        <Text style={styles.wordmark}>MVMT</Text>
        <Text style={styles.tagline}>Your song. Your performance. One cut.</Text>
      </View>

      {isEmpty ? (
        <View style={styles.section}>
          <EmptyState
            icon="musical-notes-outline"
            title="Make your first music video"
            body="Pick a song, record yourself performing it, and MVMT cuts the takes together for you."
            actionLabel="New Project"
            actionIcon="add"
            onAction={startNewProject}
          />
        </View>
      ) : (
        <>
          <View style={styles.section}>
            <PrimaryButton label="New Project" icon="add" onPress={startNewProject} />
            <Text style={styles.newProjectHint}>Pick a song and start recording — takes a minute to set up.</Text>
          </View>

          {hydrated && activeProject ? (
            <View style={styles.section}>
              <SectionHeader title="Continue" />
              <ProjectCard project={activeProject} variant="hero" onPress={() => openProject(activeProject.id)} />
            </View>
          ) : null}

          {hydrated && recent.length > 0 ? (
            <View style={styles.section}>
              <SectionHeader
                title="Recent projects"
                actionLabel={hasMoreRecent ? 'See all' : undefined}
                onAction={hasMoreRecent ? () => router.push('/projects') : undefined}
              />
              <View style={styles.recentList}>
                {recent.map((project) => (
                  <ProjectCard key={project.id} project={project} onPress={() => openProject(project.id)} />
                ))}
              </View>
            </View>
          ) : null}
        </>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.base },
  hero: { paddingHorizontal: spacing.xl, marginBottom: spacing.xxl },
  eyebrowRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, marginBottom: spacing.md },
  eyebrowDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: colors.accent },
  eyebrow: { ...typeScale.caption, color: colors.labelSecondary, letterSpacing: 1.6 },
  wordmark: { ...typeScale.largeTitle, color: colors.label, fontSize: 44, letterSpacing: 1.5 },
  tagline: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: spacing.sm, lineHeight: 21 },
  section: { paddingHorizontal: spacing.xl, marginBottom: spacing.xxl },
  newProjectHint: {
    ...typeScale.footnote,
    color: colors.labelTertiary,
    textAlign: 'center',
    marginTop: spacing.md,
  },
  recentList: { gap: spacing.md },
});
