import * as path from 'node:path';
import type { Candidate } from '../detect';
import { expoRoot, parseJsonc } from '../edit/json';
import { readPubspec } from '../edit/pubspec';
import { exists, read } from '../fsutil';
import type { UI } from '../ui';
import { findAppModules, hasGradleSettings, readAndroidModule, type AndroidModule } from './android';
import { bundleIds, findXcodeProjects, readIosProject, teamIds, type IosProject } from './ios';
import { appTargets } from '../edit/pbxproj';

export interface Project {
  candidate: Candidate;
  root: string;
  name: string;
  android?: AndroidModule;
  ios?: IosProject;
  /** Identifiers used to match Clikgate apps. */
  androidAppId?: string;
  iosBundleId?: string;
  iosTeamId?: string;
  /** Expo identifiers came from app.json (true) or are missing there. */
  expoMissing?: { androidPackage: boolean; iosBundleId: boolean };
}

async function pick<T>(ui: UI, question: string, items: T[], label: (t: T) => string): Promise<T> {
  if (items.length === 1) return items[0];
  const [i] = await ui.choose(question, items.map(label));
  return items[i];
}

async function loadAndroid(ui: UI, gradleRoot: string): Promise<AndroidModule | undefined> {
  if (!hasGradleSettings(gradleRoot)) return undefined;
  const modules = findAppModules(gradleRoot);
  if (modules.length === 0) return undefined;
  const preferred = modules.find((m) => path.basename(m) === 'app');
  const dir = modules.length > 1 && !preferred ? await pick(ui, 'Which Android app module?', modules, (m) => path.basename(m)) : preferred ?? modules[0];
  return readAndroidModule(gradleRoot, dir);
}

async function loadIos(ui: UI, dir: string, preferTarget?: string): Promise<IosProject | undefined> {
  const projects = findXcodeProjects(dir);
  if (projects.length === 0) return undefined;
  const xcodeproj = await pick(ui, 'Which Xcode project?', projects, (p) => path.basename(p));
  const targets = appTargets(read(path.join(xcodeproj, 'project.pbxproj'))).map((t) => t.name);
  if (targets.length === 0) return undefined;
  const target = preferTarget && targets.includes(preferTarget) ? preferTarget : await pick(ui, 'Which app target?', targets, (t) => t);
  return readIosProject(xcodeproj, target);
}

export async function loadProject(ui: UI, c: Candidate): Promise<Project> {
  const root = c.root;
  const p: Project = { candidate: c, root, name: path.basename(root) };
  switch (c.platform) {
    case 'flutter': {
      try {
        p.name = String(readPubspec(read(path.join(root, 'pubspec.yaml'))).name ?? p.name);
      } catch {
        // keep the folder name
      }
      p.android = await loadAndroid(ui, path.join(root, 'android'));
      p.ios = await loadIos(ui, path.join(root, 'ios'), 'Runner');
      break;
    }
    case 'react-native': {
      const appJson = path.join(root, 'app.json');
      if (exists(appJson)) {
        try {
          p.name = String(parseJsonc<{ name?: string; displayName?: string }>(read(appJson)).displayName ?? p.name);
        } catch {
          // ignore
        }
      }
      p.android = await loadAndroid(ui, path.join(root, 'android'));
      p.ios = await loadIos(ui, path.join(root, 'ios'));
      break;
    }
    case 'expo': {
      if (c.appConfig?.endsWith('.json')) {
        const cfg = expoRoot(parseJsonc(read(c.appConfig))) ?? {};
        p.name = String(cfg.name ?? p.name);
        const android = (cfg.android ?? {}) as { package?: string };
        const ios = (cfg.ios ?? {}) as { bundleIdentifier?: string; appleTeamId?: string };
        p.androidAppId = android.package;
        p.iosBundleId = ios.bundleIdentifier;
        p.iosTeamId = ios.appleTeamId;
        p.expoMissing = { androidPackage: !android.package, iosBundleId: !ios.bundleIdentifier };
      }
      if (c.nativeFolders?.android) p.android = await loadAndroid(ui, path.join(root, 'android'));
      if (c.nativeFolders?.ios) p.ios = await loadIos(ui, path.join(root, 'ios'));
      break;
    }
    case 'android':
      p.android = await loadAndroid(ui, root);
      break;
    case 'ios':
      p.ios = await loadIos(ui, root);
      break;
  }
  if (p.android && !p.androidAppId) {
    const ids = p.android.applicationIds;
    if (ids.length) p.androidAppId = await pick(ui, 'Which Android applicationId should Clikgate use?', ids, (x) => x);
  }
  if (p.ios && !p.iosBundleId) {
    const ids = bundleIds(p.ios);
    const release = p.ios.configs.find((c2) => !c2.debug && c2.bundleId)?.bundleId;
    if (ids.length > 1) p.iosBundleId = await pick(ui, 'Which iOS bundle identifier should Clikgate use?', ids, (x) => x);
    else p.iosBundleId = release ?? ids[0];
  }
  if (p.ios && !p.iosTeamId) {
    const teams = teamIds(p.ios);
    if (teams.length) p.iosTeamId = await pick(ui, 'Which Apple Team ID?', teams, (x) => x);
  }
  return p;
}

/** Which Clikgate app platforms the project needs. */
export function needsPlatforms(p: Project): ('android' | 'ios')[] {
  switch (p.candidate.platform) {
    case 'android':
      return ['android'];
    case 'ios':
      return ['ios'];
    case 'expo':
      return ['android', 'ios'];
    default:
      return [...(p.android ? (['android'] as const) : []), ...(p.ios ? (['ios'] as const) : [])];
  }
}
