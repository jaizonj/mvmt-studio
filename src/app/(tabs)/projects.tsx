import { router } from 'expo-router';
import { Alert, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { EmptyState } from '../../components/ui/EmptyState';
import { ProjectCard } from '../../components/ui/ProjectCard';
import { useStudio } from '../../store/StudioContext';
import { colors, spacing, type as typeScale } from '../../theme';
import type { Project } from '../../types';

/** Projects — every project, open / rename / delete (Overhaul IA, §3.1.2). */
export default function ProjectsScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const { projects, activeProjectId, hydrated } = studio;

  const open = (project: Project) => {
    studio.openProject(project.id);
    router.push('/project/record');
  };

  const startNewProject = () => {
    studio.createProject();
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
      contentContainerStyle={{ paddingTop: insets.top + spacing.xl, paddingBottom: spacing.xxxl }}>
      <View style={styles.header}>
        <Text style={styles.largeTitle}>Projects</Text>
        {hydrated && projects.length > 0 ? (
          <Text style={styles.subtitle}>
            {projects.length} project{projects.length === 1 ? '' : 's'}
          </Text>
        ) : null}
      </View>

      {!hydrated ? null : projects.length === 0 ? (
        <View style={styles.emptyWrap}>
          <EmptyState
            icon="folder-open-outline"
            title="No projects yet"
            body="Projects you create will live here."
            actionLabel="New Project"
            actionIcon="add"
            onAction={startNewProject}
          />
        </View>
      ) : (
        <View style={styles.list}>
          {projects.map((project) => (
            <ProjectCard
              key={project.id}
              project={project}
              isActive={project.id === activeProjectId}
              onPress={() => open(project)}
              onRename={() => rename(project)}
              onDelete={() => remove(project)}
            />
          ))}
        </View>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.base },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.xl },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  subtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: spacing.xs },
  list: { paddingHorizontal: spacing.xl, gap: spacing.md },
  emptyWrap: { paddingHorizontal: spacing.xl },
});
