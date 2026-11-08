import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { Alert, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { useStudio } from '../../store/StudioContext';
import { colors, radius, spacing, type as typeScale } from '../../theme';
import type { Project } from '../../types';

/** Projects — every project, open / rename / delete (Overhaul IA). */
export default function ProjectsScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { projects, activeProjectId, hydrated } = studio;

  const open = (project: Project) => {
    studio.openProject(project.id);
    router.push('/project/record');
  };

  const rename = (project: Project) => {
    Alert.prompt('Rename project', undefined, (name) => studio.renameProject(project.id, name ?? ''), 'plain-text', project.name);
  };

  const remove = (project: Project) => {
    Alert.alert('Delete project?', `"${project.name}" and its edit will be removed. Recorded take files stay in the app sandbox but will no longer be listed.`, [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Delete', style: 'destructive', onPress: () => studio.deleteProject(project.id) },
    ]);
  };

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={{ paddingTop: insets.top + spacing.lg, paddingBottom: spacing.xxl }}>
      <View style={styles.header}>
        <Text style={styles.largeTitle}>Projects</Text>
      </View>

      {!hydrated ? null : projects.length === 0 ? (
        <View style={styles.empty}>
          <Ionicons name="folder-open-outline" size={34} color={colors.labelSecondary} />
          <Text style={styles.emptyTitle}>No projects yet</Text>
          <Text style={styles.emptyBody}>Start one from the Studio tab — pick a song, record takes, and MVMT cuts them together.</Text>
        </View>
      ) : (
        <View style={styles.list}>
          {projects.map((project) => {
            const isActive = project.id === activeProjectId;
            return (
              <View key={project.id} style={styles.row}>
                <Pressable style={{ flex: 1 }} onPress={() => open(project)} accessibilityRole="button">
                  <Text style={styles.name} numberOfLines={1}>
                    {project.name}
                    {isActive ? '  ·  current' : ''}
                  </Text>
                  <Text style={styles.meta} numberOfLines={1}>
                    {project.track ? project.track.name : 'No song yet'}
                    {project.takes.length ? ` · ${project.takes.length} takes` : ''}
                    {project.edl ? ' · has an edit' : ''}
                  </Text>
                </Pressable>
                <Pressable onPress={() => rename(project)} hitSlop={8} accessibilityRole="button" accessibilityLabel={`Rename ${project.name}`}>
                  <Ionicons name="pencil-outline" size={19} color={colors.labelSecondary} />
                </Pressable>
                <Pressable onPress={() => remove(project)} hitSlop={8} accessibilityRole="button" accessibilityLabel={`Delete ${project.name}`}>
                  <Ionicons name="trash-outline" size={19} color={colors.danger} />
                </Pressable>
              </View>
            );
          })}
        </View>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.base },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.lg },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  list: { paddingHorizontal: spacing.xl },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.lg,
    marginBottom: spacing.md,
  },
  name: { ...typeScale.headline, color: colors.label },
  meta: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: 2 },
  empty: { alignItems: 'center', gap: spacing.sm, padding: spacing.xxl },
  emptyTitle: { ...typeScale.headline, color: colors.label },
  emptyBody: { ...typeScale.subhead, color: colors.labelSecondary, textAlign: 'center', lineHeight: 20 },
});
