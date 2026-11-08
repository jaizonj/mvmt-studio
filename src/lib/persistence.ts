import { Directory, File, Paths } from 'expo-file-system';

import type { Project } from '../types';

/**
 * Project persistence — one JSON file in the app's documents folder.
 *
 * Before the overhaul the store was useState-only: restarting the app
 * lost the track, the takes index and the edit, orphaning the media
 * files in the sandbox (QA audit F-2). Media files themselves already
 * live in the sandbox (copied there on pick/record), so persisting the
 * project metadata (incl. each take's URI + measured sync data and the
 * canonical EDL, which is plain JSON) is all it takes to make projects
 * survive restarts.
 *
 * All functions are failure-tolerant: persistence must never crash the
 * studio. Callers get null/false and the app keeps running in-memory.
 */

export interface PersistedProjects {
  version: 1;
  projects: Project[];
  activeProjectId: string | null;
}

const DIR_NAME = 'mvmt';
const FILE_NAME = 'projects.json';

function projectsFile(): File {
  const dir = new Directory(Paths.document, DIR_NAME);
  if (!dir.exists) dir.create({ intermediates: true });
  return new File(dir, FILE_NAME);
}

export async function loadProjects(): Promise<PersistedProjects | null> {
  try {
    const file = projectsFile();
    if (!file.exists) return null;
    const raw = await file.text();
    const parsed = JSON.parse(raw) as PersistedProjects;
    if (!parsed || parsed.version !== 1 || !Array.isArray(parsed.projects)) return null;
    return parsed;
  } catch {
    return null;
  }
}

export async function saveProjects(state: PersistedProjects): Promise<boolean> {
  try {
    const file = projectsFile();
    file.write(JSON.stringify(state));
    return true;
  } catch {
    return false;
  }
}
