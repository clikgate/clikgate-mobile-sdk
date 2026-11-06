import * as path from 'node:path';
import { SHARED_DOMAIN_FIX, SHARED_PLATFORM_DOMAINS, isTestHost } from '../constants';
import { addAppLinks, addDebugAppLinks, allLinkHosts, newDebugManifest } from '../edit/androidManifest';
import { setBuildSetting } from '../edit/pbxproj';
import { addApplinks, addBoolIfMissing, applinksHosts, newEntitlements } from '../edit/plistEdit';
import { rel } from '../fsutil';
import type { PlanBuilder } from '../plan';
import { isDebugSourceSet, type AndroidModule } from '../project/android';
import type { IosProject } from '../project/ios';

export interface LinkDomains {
  /** Live domains for manifests/entitlements (release and debug builds). */
  live: string[];
  /** Test domain (debug builds only), or undefined when not used. */
  test?: string;
  /** Per-platform hosts (each app's own subdomain; change 09 N.1). Override live/test for that platform's files. */
  android?: { live: string[]; test?: string };
  ios?: { live: string[]; test?: string };
}

function list(hosts: string[]): string {
  return hosts.join(', ');
}

/** Android App Links: live domains in src/main, the test domain in src/debug only. */
export function planAndroidLinks(pb: PlanBuilder, mod: AndroidModule, domains: LinkDomains, opts: { flutter?: boolean } = {}): void {
  domains = domains.android ?? domains;
  const root = pb.root;
  const mainRel = rel(root, mod.mainManifest);
  const activity = mod.launcherActivity;
  if (!activity) {
    pb.manual(
      'Android App Links',
      `${mainRel} has no launcher activity, so the setup command can't tell which activity should open links. Add an intent filter with android:autoVerify="true" for ${list(domains.live)} to that activity.`
    );
    return;
  }
  const main = pb.current(mainRel)!;
  if (domains.live.length || opts.flutter) {
    const edit = addAppLinks(main, {
      activityName: activity,
      hosts: domains.live,
      comment: 'Clikgate App Links (all builds)',
      flutterDeepLinkingOff: opts.flutter,
    });
    if (edit.changed) {
      const what = edit.added.length ? `App Links for ${list(edit.added)}` : 'let Clikgate handle links';
      pb.change(mainRel, edit.text, what + (opts.flutter && edit.text.includes('flutter_deeplinking_enabled') && !main.includes('flutter_deeplinking_enabled') ? ', Flutter deep linking off' : ''));
    } else pb.done(`Android: App Links for ${list(domains.live)}`);
  }
  if (domains.test) {
    const debug = mod.sourceSetManifests.find((s) => s.name === 'debug');
    const debugRel = rel(root, debug?.file ?? path.join(mod.moduleDir, 'src', 'debug', 'AndroidManifest.xml'));
    const current = pb.current(debugRel);
    if (current === null) {
      pb.change(debugRel, newDebugManifest(activity, [domains.test]), `App Links for ${domains.test}, debug builds only`);
    } else {
      const edit = addDebugAppLinks(current, activity, [domains.test]);
      if (edit.changed) pb.change(debugRel, edit.text, `App Links for ${domains.test}, debug builds only`);
      else pb.done(`Android: App Links for ${domains.test} (debug builds only)`);
    }
  }
  // Other debug-based build types that already have a manifest (React Native's debugOptimized).
  if (domains.test) {
    for (const s of mod.sourceSetManifests) {
      if (s.name === 'debug' || !isDebugSourceSet(s.name)) continue;
      const r = rel(root, s.file);
      const edit = addDebugAppLinks(pb.current(r)!, activity, [domains.test]);
      if (edit.changed) pb.change(r, edit.text, `App Links for ${domains.test}, ${s.name} builds only`);
    }
  }
  // Test domains must never reach release builds, and shared domains can't open the app (change 09
  // N.1). We never remove lines: report them.
  for (const f of [{ name: 'main', file: mod.mainManifest }, ...mod.sourceSetManifests]) {
    const text = pb.current(rel(root, f.file));
    if (!text) continue;
    const hosts = [...allLinkHosts(text)];
    const shared = hosts.filter((h) => SHARED_PLATFORM_DOMAINS.includes(h));
    if (shared.length) {
      pb.manual(
        `Remove ${list(shared)} from ${rel(root, f.file)}`,
        `${rel(root, f.file)} has an intent filter for ${list(shared)}: ${SHARED_DOMAIN_FIX}. Remove those hosts; your app's link subdomain and custom domains open it.`
      );
    }
    if (isDebugSourceSet(f.name)) continue;
    const test = hosts.filter((h) => isTestHost(h) && !shared.includes(h));
    if (test.length) {
      pb.manual(
        `Remove ${list(test)} from ${rel(root, f.file)}`,
        `${rel(root, f.file)} is used by release builds and has an intent filter for ${list(test)}. Test links must only open debug builds: move that filter to src/debug/AndroidManifest.xml.`
      );
    }
  }
}

/**
 * iOS Associated Domains per build configuration: Release/Profile entitlements get the live
 * domains; a separate Debug entitlements file also gets the test domain. Both are linked
 * with CODE_SIGN_ENTITLEMENTS.
 */
export function planIosLinks(pb: PlanBuilder, ios: IosProject, domains: LinkDomains, opts: { flutter?: boolean } = {}): void {
  domains = domains.ios ?? domains;
  const root = pb.root;
  const srcRel = (p: string) => rel(root, path.join(ios.srcRoot, p));
  const pbxRel = rel(root, ios.pbxproj);
  const release = ios.configs.filter((c) => !c.debug);
  const debug = ios.configs.filter((c) => c.debug);
  let pbx = pb.current(pbxRel)!;
  const linked: string[] = [];

  // Release-like configurations share one file.
  const existingRelease = release.find((c) => c.entitlements)?.entitlements;
  const releaseFile = existingRelease ?? `${ios.target}/${ios.target}.entitlements`;
  const releaseRel = srcRel(releaseFile);
  const releaseText = pb.current(releaseRel);
  let releaseAfter: string;
  if (releaseText === null) {
    releaseAfter = newEntitlements(domains.live);
    pb.change(releaseRel, releaseAfter, `associated domains: ${list(domains.live)}`);
  } else {
    releaseAfter = addApplinks(releaseText, domains.live);
    if (releaseAfter !== releaseText) pb.change(releaseRel, releaseAfter, `associated domains: ${list(domains.live)}`);
    else pb.done(`iOS: associated domains in ${releaseFile}`);
  }
  for (const c of release) {
    if (c.entitlements === releaseFile) continue;
    if (c.entitlements && c.entitlements !== releaseFile) {
      // Another release-like configuration with its own file: add the live domains there too.
      const t = pb.current(srcRel(c.entitlements));
      if (t !== null) {
        const a = addApplinks(t, domains.live);
        if (a !== t) pb.change(srcRel(c.entitlements), a, `associated domains: ${list(domains.live)} (${c.name})`);
      }
      continue;
    }
    pbx = setBuildSetting(pbx, c.id, 'CODE_SIGN_ENTITLEMENTS', releaseFile);
    linked.push(`${c.name} → ${releaseFile}`);
  }
  for (const c of release) {
    const t = c.entitlements ? pb.current(srcRel(c.entitlements)) : null;
    const test = t ? applinksHosts(t).filter((h) => isTestHost(h) && !SHARED_PLATFORM_DOMAINS.includes(h)) : [];
    if (test.length) {
      pb.manual(
        `Remove ${list(test)} from ${c.entitlements}`,
        `The ${c.name} configuration uses ${c.entitlements}, which lists ${test.map((h) => `applinks:${h}`).join(', ')}. Test links must only open Debug builds: remove that entry (the Debug entitlements keep it).`
      );
    }
  }
  // Shared domains in any configuration (change 09 N.1): reported once per file, never removed.
  const seen = new Set<string>();
  for (const c of ios.configs) {
    if (!c.entitlements || seen.has(c.entitlements)) continue;
    seen.add(c.entitlements);
    const t = pb.current(srcRel(c.entitlements));
    let hosts: string[] = [];
    try {
      hosts = t ? applinksHosts(t) : [];
    } catch {
      continue;
    }
    const shared = hosts.filter((h) => SHARED_PLATFORM_DOMAINS.includes(h));
    if (shared.length) {
      pb.manual(
        `Remove ${shared.map((h) => `applinks:${h}`).join(', ')} from ${c.entitlements}`,
        `${c.entitlements} lists ${shared.map((h) => `applinks:${h}`).join(', ')}: ${SHARED_DOMAIN_FIX}. Remove those entries; your app's link subdomain and custom domains open it.`
      );
    }
  }

  // Debug configurations: their own file with the live domains plus the test domain.
  if (debug.length) {
    const debugHosts = domains.test ? [...domains.live, domains.test] : domains.live;
    const own = debug.find((c) => c.entitlements && c.entitlements !== releaseFile)?.entitlements;
    const debugFile = own ?? `${ios.target}/${ios.target}Debug.entitlements`;
    const debugRel = srcRel(debugFile);
    const debugText = pb.current(debugRel);
    if (debugText === null) {
      // A copy of the release entitlements (so other capabilities match) plus the test domain.
      pb.change(debugRel, addApplinks(releaseAfter, debugHosts), `adds ${domains.test ?? 'nothing'}, Debug configuration only`);
    } else {
      const a = addApplinks(debugText, debugHosts);
      if (a !== debugText) pb.change(debugRel, a, `associated domains${domains.test ? ` with ${domains.test}` : ''}, Debug configuration only`);
      else pb.done(`iOS: Debug entitlements (${debugFile})`);
    }
    for (const c of debug) {
      if (c.entitlements === debugFile) continue;
      pbx = setBuildSetting(pbx, c.id, 'CODE_SIGN_ENTITLEMENTS', debugFile, c.entitlements === releaseFile);
      linked.push(`${c.name} → ${debugFile}`);
    }
  }
  if (linked.length) pb.change(pbxRel, pbx, `link the entitlements files: ${linked.join(', ')}`);
  else pb.done('iOS: entitlements linked per build configuration');

  if (opts.flutter) {
    const plistFile = ios.configs.find((c) => c.infoPlist)?.infoPlist;
    if (plistFile) {
      const pRel = srcRel(plistFile);
      const t = pb.current(pRel);
      if (t !== null) {
        const a = addBoolIfMissing(t, 'FlutterDeepLinkingEnabled', false);
        if (a !== t) pb.change(pRel, a, "let Clikgate handle links (Flutter's deep linking off)");
      }
    }
  }
}
