import * as path from 'node:path';
import { appTargets, isDebugConfig, setting, type AppTarget } from '../edit/pbxproj';
import { exists, isDir, list, read } from '../fsutil';

export interface IosConfig {
  id: string;
  name: string;
  debug: boolean;
  bundleId?: string;
  teamId?: string;
  /** CODE_SIGN_ENTITLEMENTS as written (relative to the project folder). */
  entitlements?: string;
  infoPlist?: string;
}

export interface IosProject {
  /** Folder holding the .xcodeproj ($(SRCROOT)). */
  srcRoot: string;
  xcodeproj: string;
  pbxproj: string;
  target: string;
  targets: string[];
  configs: IosConfig[];
  podfile?: string;
}

export function findXcodeProjects(dir: string): string[] {
  return list(dir)
    .filter((n) => n.endsWith('.xcodeproj') && n !== 'Pods.xcodeproj')
    .map((n) => path.join(dir, n))
    .filter((p) => exists(path.join(p, 'project.pbxproj')));
}

/** Resolves `$(VAR)` references that are plain build settings of the same configuration. */
function expand(value: string | undefined, settings: Record<string, unknown>, targetName: string): string | undefined {
  if (value === undefined) return undefined;
  let v = value.replace(/^"|"$/g, '');
  for (let i = 0; i < 5 && /\$\(|\$\{/.test(v); i++) {
    v = v.replace(/\$[({]([A-Za-z0-9_]+)(?::[^)}]*)?[)}]/g, (m, name: string) => {
      if (name === 'TARGET_NAME' || name === 'PRODUCT_NAME') return String(settings.PRODUCT_NAME ?? targetName).replace(/^"|"$/g, '').replace('$(TARGET_NAME)', targetName);
      const s = settings[name];
      return typeof s === 'string' ? s.replace(/^"|"$/g, '') : m;
    });
  }
  return /\$\(|\$\{/.test(v) ? undefined : v;
}

export function readIosProject(xcodeproj: string, targetName?: string): IosProject {
  const pbxproj = path.join(xcodeproj, 'project.pbxproj');
  const targets = appTargets(read(pbxproj));
  if (targets.length === 0) throw new Error(`${path.basename(xcodeproj)} has no app target`);
  const t: AppTarget = (targetName && targets.find((x) => x.name === targetName)) || targets[0];
  const srcRoot = path.dirname(xcodeproj);
  const configs = t.configs.map((c) => ({
    id: c.id,
    name: c.name,
    debug: isDebugConfig(c.name),
    bundleId: expand(setting(c, 'PRODUCT_BUNDLE_IDENTIFIER'), c.settings, t.name),
    teamId: expand(setting(c, 'DEVELOPMENT_TEAM'), c.settings, t.name),
    entitlements: setting(c, 'CODE_SIGN_ENTITLEMENTS')?.replace(/^"|"$/g, ''),
    infoPlist: setting(c, 'INFOPLIST_FILE')?.replace(/^"|"$/g, ''),
  }));
  const podfile = exists(path.join(srcRoot, 'Podfile')) ? path.join(srcRoot, 'Podfile') : undefined;
  return { srcRoot, xcodeproj, pbxproj, target: t.name, targets: targets.map((x) => x.name), configs, podfile };
}

/** Swift sources of the app target's folder (the folder named after the target, by convention). */
export function targetSwiftFiles(ios: IosProject): string[] {
  const dir = path.join(ios.srcRoot, ios.target);
  const out: string[] = [];
  const visit = (d: string, depth: number) => {
    for (const n of list(d)) {
      const p = path.join(d, n);
      if (isDir(p)) {
        if (depth < 3 && !n.endsWith('.xcassets') && !n.endsWith('.lproj')) visit(p, depth + 1);
      } else if (n.endsWith('.swift')) out.push(p);
    }
  };
  if (isDir(dir)) visit(dir, 0);
  return out.sort();
}

export function bundleIds(ios: IosProject): string[] {
  return Array.from(new Set(ios.configs.map((c) => c.bundleId).filter((b): b is string => Boolean(b))));
}

export function teamIds(ios: IosProject): string[] {
  return Array.from(new Set(ios.configs.map((c) => c.teamId).filter((b): b is string => Boolean(b))));
}
