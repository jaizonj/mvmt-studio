import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useStudio } from '../../store/StudioContext';
import { colors, radius, spacing, type as typeScale } from '../../theme';

/**
 * Studio home — the front door (Overhaul IA, docs/DESIGN_SYSTEM.md).
 * Branding, one prominent New Project action, Continue for the active
 * project, and recent projects. No dashboards, no statistics.
 */
export default function StudioHome() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { activeProject, projects, hydrated } = studio;

  const startNewProject = () => {
    studio.createProject();
    router.push('/project/record');
  };

  const openProject = (id: string) => {
    studio.openProject(id);
    router.push('/project/record');
  };

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={{ paddingTop: insets.top + spacing.xxl, paddingBottom: spacing.xxl }}>
      <View style={styles.header}>
        <Text style={styles.wordmark}>MVMT</Text>
        <Text style={styles.tagline}>Music videos, shot and cut to the song.</Text>
      </View>

      <View style={styles.section}>
        <Pressable style={styles.newProjectButton} onPress={startNewProject} accessibilityRole="button">
          <Ionicons name="add-circle" size={22} color={colors.onAccent} />
          <Text style={styles.newProjectText}>New Project</Text>
        </Pressable>
      </View>

      {hydrated && activeProject ? (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Continue</Text>
          <Pressable style={styles.projectCard} onPress={() => openProject(activeProject.id)} accessibilityRole="button">
            <View style={styles.projectIcon}>
              <Ionicons name="musical-notes" size={20} color={colors.accent} />
            </View>
            <View style={{ flex: 1 }}>
              <Text style={styles.projectName} numberOfLines={1}>
                {activeProject.name}
              </Text>
              <Text style={styles.projectMeta} numberOfLines={1}>
                {activeProject.track ? activeProject.track.name : 'No song yet'}
                {activeProject.takes.length ? ` · ${activeProject.takes.length} takes` : ''}
                {activeProject.edl ? ' · edit in progress' : ''}
              </Text>
            </View>
            <Ionicons name="chevron-forward" size={18} color={colors.labelTertiary} />
          </Pressable>
        </View>
      ) : null}

      {hydrated && projects.length > 1 ? (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Recent projects</Text>
          {projects
            .filter((p) => p.id !== activeProject?.id)
            .slice(0, 4)
            .map((project) => (
              <Pressable
                key={project.id}
                style={styles.projectRow}
                onPress={() => openProject(project.id)}
                accessibilityRole="button">
                <View style={{ flex: 1 }}>
                  <Text style={styles.projectName} numberOfLines={1}>
                    {project.name}
                  </Text>
                  <Text style={styles.projectMeta} numberOfLines={1}>
                    {project.track ? project.track.name : 'No song yet'}
                    {project.takes.length ? ` · ${project.takes.length} takes` : ''}
                  </Text>
                </View>
                <Ionicons name="chevron-forward" size={16} color={colors.labelTertiary} />
              </Pressable>
            ))}
        </View>
      ) : null}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.base },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.xxl },
  wordmark: { color: colors.label, fontSize: 40, fontWeight: '800', letterSpacing: 2 },
  tagline: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: spacing.xs },
  section: { paddingHorizontal: spacing.xl, marginBottom: spacing.xxl },
  sectionTitle: { ...typeScale.headline, color: colors.label, marginBottom: spacing.md },
  newProjectButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 16,
  },
  newProjectText: { color: colors.onAccent, fontSize: 17, fontWeight: '700' },
  projectCard: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.lg,
  },
  projectIcon: {
    width: 44,
    height: 44,
    borderRadius: radius.md,
    backgroundColor: colors.accentDim,
    alignItems: 'center',
    justifyContent: 'center',
  },
  projectRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  projectName: { ...typeScale.headline, color: colors.label },
  projectMeta: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: 2 },
});
