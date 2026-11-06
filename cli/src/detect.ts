import * as path from 'node:path';
import type { Platform } from './args';
import { parseJsonc, expoRoot } from './edit/json';
import { isFlutterApp } from './edit/pubspec';
import { exists, findUp, readIfExists, walk } from './fsutil';
import { findAppModules, hasGradleSettings } from './project/android';
import { findXcodeProjects } from './project/ios';

export interface Candidate {
  platform: Platform;
  root: string;
  /** Expo with android/ and/or ios/ folders: the native files are edited too. */
  nativeFolders?: { android: boolean; ios: boolean };
  /** For JS projects: the app config file (Expo). */
  appConfig?: string;
}

export type PackageManager = 'npm' | 'yarn' | 'pnpm' | 'bun';

type Pkg = { dependencies?: Record<string, string>; devDependencies?: Record<string, string> };

function pkgHas(pkg: Pkg, name: string): boolean {
  return Boolean(pkg.dependencies?.[name] ?? pkg.devDependencies?.[name]);
}

export function expoAppConfig(dir: string): string | undefined {
  for (const n of ['app.json', 'app.config.ts', 'app.config.js', 'app.config.mjs', 'app.config.cjs', 'app.config.json']) {
    const p = path.join(dir, n);
    if (!exists(p)) continue;
    if (n === 'app.json') {
      // A bare RN app.json ({name, displayName}) isn't an Expo config.
      try {
        const j = parseJsonc<Record<string, unknown>>(readIfExists(p)!);
        if (!('expo' in j) && !('slug' in j) && !('plugins' in j)) continue;
        void expoRoot(j);
      } catch {
        continue;
      }
    }
    return p;
  }
  return undefined;
}

/** The project types found in one folder (S.3 step 1). */
export function detectIn(dir: string): Candidate[] {
  const out: Candidate[] = [];
  const pubspec = readIfExists(path.join(dir, 'pubspec.yaml'));
  const pkgText = readIfExists(path.join(dir, 'package.json'));
  if (pubspec !== undefined && isFlutterApp(pubspec)) out.push({ platform: 'flutter', root: dir });
  if (pkgText !== undefined) {
    let pkg: Pkg = {};
    try {
      pkg = parseJsonc<Pkg>(pkgText);
    } catch {
      pkg = {};
    }
    if (pkgHas(pkg, 'expo')) {
      const appConfig = expoAppConfig(dir);
      if (appConfig) {
        out.push({
          platform: 'expo',
          root: dir,
          appConfig,
          nativeFolders: { android: exists(path.join(dir, 'android')), ios: exists(path.join(dir, 'ios')) },
        });
      }
    } else if (pkgHas(pkg, 'react-native')) {
      out.push({ platform: 'react-native', root: dir });
    }
  }
  if (pubspec === undefined && pkgText === undefined) {
    if (hasGradleSettings(dir) && findAppModules(dir).length > 0) out.push({ platform: 'android', root: dir });
    if (findXcodeProjects(dir).length > 0) out.push({ platform: 'ios', root: dir });
  }
  return out;
}

/**
 * Detection from the project folder; when nothing is there, look a few folders down
 * (monorepos: apps/mobile, packages/app…), skipping the native folders of JS/Flutter apps.
 */
export function detect(cwd: string, maxDepth = 3): Candidate[] {
  const here = detectIn(cwd);
  if (here.length) return here;
  const found: Candidate[] = [];
  const claimed: string[] = [];
  walk(cwd, maxDepth, (dir) => {
    if (dir === cwd) return;
    if (claimed.some((c) => dir.startsWith(c + path.sep))) return;
    const c = detectIn(dir);
    if (c.length) {
      found.push(...c);
      if (c.some((x) => x.platform !== 'android' && x.platform !== 'ios')) claimed.push(dir);
    }
  });
  return found;
}

export function detectPackageManager(root: string): PackageManager {
  // Monorepos keep the lockfile at the workspace root: look up to the repository root only.
  const git = findUp(root, ['.git']);
  const lock = findUp(root, ['bun.lock', 'bun.lockb', 'pnpm-lock.yaml', 'yarn.lock', 'package-lock.json'], git ? path.dirname(git) : root);
  if (!lock) return 'npm';
  const n = path.basename(lock);
  if (n.startsWith('bun')) return 'bun';
  if (n.startsWith('pnpm')) return 'pnpm';
  if (n === 'yarn.lock') return 'yarn';
  return 'npm';
}
