import * as path from 'node:path';
import { applicationIds, hasProductFlavors, isAppModule, namespace } from '../edit/gradle';
import { exists, isDir, list, read, readIfExists } from '../fsutil';
import { launcherActivity } from '../edit/androidManifest';
import { parseXml } from '../edit/xml';

export interface AndroidModule {
  /** Gradle project folder (the one with settings.gradle). */
  gradleRoot: string;
  moduleDir: string;
  buildFile: string;
  kotlinDsl: boolean;
  applicationIds: string[];
  namespace?: string;
  flavors: boolean;
  mainManifest: string;
  /** Other source sets with a manifest (debug, release, flavours…). */
  sourceSetManifests: { name: string; file: string }[];
  /** gradle/libs.versions.toml when it exists and the module uses `libs.` accessors. */
  catalog?: string;
  /** Activity that receives links (android:name as written). */
  launcherActivity?: string;
  /** Debug keystore used by the debug build (RN templates ship one in the module). */
  debugKeystore?: string;
}

const BUILD_FILES = ['build.gradle.kts', 'build.gradle'];

function buildFileIn(dir: string): string | undefined {
  for (const f of BUILD_FILES) if (exists(path.join(dir, f))) return path.join(dir, f);
  return undefined;
}

export function hasGradleSettings(dir: string): boolean {
  return exists(path.join(dir, 'settings.gradle')) || exists(path.join(dir, 'settings.gradle.kts'));
}

/** App modules (com.android.application) of a Gradle project, one or two folders deep. */
export function findAppModules(gradleRoot: string): string[] {
  const out: string[] = [];
  const consider = (dir: string) => {
    const bf = buildFileIn(dir);
    if (bf && isAppModule(read(bf)) && exists(path.join(dir, 'src', 'main', 'AndroidManifest.xml'))) out.push(dir);
  };
  for (const name of list(gradleRoot).sort()) {
    const p = path.join(gradleRoot, name);
    if (!isDir(p) || name.startsWith('.') || name === 'build' || name === 'gradle') continue;
    consider(p);
  }
  return out;
}

export function readAndroidModule(gradleRoot: string, moduleDir: string): AndroidModule {
  const buildFile = buildFileIn(moduleDir)!;
  const text = read(buildFile);
  const srcDir = path.join(moduleDir, 'src');
  const mainManifest = path.join(srcDir, 'main', 'AndroidManifest.xml');
  const sourceSetManifests = list(srcDir)
    .filter((n) => n !== 'main' && exists(path.join(srcDir, n, 'AndroidManifest.xml')))
    .sort()
    .map((n) => ({ name: n, file: path.join(srcDir, n, 'AndroidManifest.xml') }));
  const catalogPath = path.join(gradleRoot, 'gradle', 'libs.versions.toml');
  const catalog = exists(catalogPath) && /\blibs\.[a-z]/.test(text) ? catalogPath : undefined;
  let activity: string | undefined;
  try {
    activity = launcherActivity(parseXml(read(mainManifest)))?.attrs['android:name'];
  } catch {
    activity = undefined;
  }
  let debugKeystore: string | undefined;
  const ks = /storeFile\s*(?:=\s*)?file\(\s*["']([^"']+)["']\s*\)/.exec(text);
  if (ks && /signingConfigs/.test(text) && exists(path.join(moduleDir, ks[1]))) debugKeystore = path.join(moduleDir, ks[1]);
  return {
    gradleRoot,
    moduleDir,
    buildFile,
    kotlinDsl: buildFile.endsWith('.kts'),
    applicationIds: applicationIds(text),
    namespace: namespace(text),
    flavors: hasProductFlavors(text),
    mainManifest,
    sourceSetManifests,
    catalog,
    launcherActivity: activity,
    debugKeystore,
  };
}

/**
 * Debug-only source sets: `debug`, debug-based build types such as React Native's
 * `debugOptimized`, and variant sets ending in `Debug` (e.g. freeDebug).
 */
export function isDebugSourceSet(name: string): boolean {
  return /^debug/.test(name) || /Debug/.test(name);
}

/** Resolves `.MainActivity` / `MainActivity` / fully-qualified names to a source file. */
export function findClassFile(moduleDir: string, pkg: string | undefined, className: string): string | undefined {
  const fq = className.startsWith('.') ? `${pkg}${className}` : className.includes('.') ? className : `${pkg}.${className}`;
  const relPath = fq.split('.').join('/');
  for (const root of ['kotlin', 'java']) {
    for (const ext of ['.kt', '.java']) {
      const p = path.join(moduleDir, 'src', 'main', root, relPath + ext);
      if (exists(p)) return p;
    }
  }
  return undefined;
}

export function readText(p: string): string | undefined {
  return readIfExists(p);
}
