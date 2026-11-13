import * as fs from 'node:fs';
import * as path from 'node:path';
import { describe, expect, it } from 'vitest';
import { main } from '../src/index';
import { allLinkHosts, verifiedHosts } from '../src/edit/androidManifest';
import { appTargets, setting } from '../src/edit/pbxproj';
import { applinksHosts, apsEnvironment, readPlist } from '../src/edit/plistEdit';
import { findXcodeProjects } from '../src/project/ios';
import { isDebugSourceSet } from '../src/project/android';
import { FIXTURE_NAMES, OFFLINE, ScriptedUI, copyFixture, snapshotTree, treeDiff } from './helpers';

const TEST = 'acme.dev.ciz.to';

function projectRoot(fixture: string, dir: string): string {
  return fixture === 'monorepo' ? path.join(dir, 'apps', 'mobile') : dir;
}

/** Every Android manifest under the project, split into debug-only and release-reachable. */
function manifests(root: string): { debug: string[]; release: string[] } {
  const out = { debug: [] as string[], release: [] as string[] };
  const visit = (d: string) => {
    for (const n of fs.readdirSync(d)) {
      const p = path.join(d, n);
      if (fs.statSync(p).isDirectory()) {
        if (n !== '.clikgate-setup-backup' && n !== 'node_modules') visit(p);
      } else if (n === 'AndroidManifest.xml') {
        const sourceSet = path.basename(path.dirname(p));
        (isDebugSourceSet(sourceSet) ? out.debug : out.release).push(p);
      }
    }
  };
  visit(root);
  return out;
}

function iosConfigs(root: string): { name: string; debug: boolean; hosts: string[]; aps?: string }[] {
  const dirs = [root, path.join(root, 'ios')].filter((d) => fs.existsSync(d));
  const out: { name: string; debug: boolean; hosts: string[]; aps?: string }[] = [];
  for (const d of dirs) {
    for (const xp of findXcodeProjects(d)) {
      for (const t of appTargets(fs.readFileSync(path.join(xp, 'project.pbxproj'), 'utf8'))) {
        for (const c of t.configs) {
          const ent = setting(c, 'CODE_SIGN_ENTITLEMENTS')?.replace(/^"|"$/g, '');
          expect(ent, `${c.name} has CODE_SIGN_ENTITLEMENTS`).toBeTruthy();
          const file = path.join(path.dirname(xp), ent!);
          expect(fs.existsSync(file), `${ent} exists`).toBe(true);
          const text = fs.readFileSync(file, 'utf8');
          readPlist(text); // parses
          out.push({ name: c.name, debug: /debug/i.test(c.name), hosts: applinksHosts(text), aps: apsEnvironment(text) });
        }
      }
    }
  }
  return out;
}

describe.each(FIXTURE_NAMES)('offline setup on %s', (fixture) => {
  it('matches the snapshot, keeps the test domain out of release builds, and is idempotent', async () => {
    const dir = copyFixture(fixture);
    const ui = new ScriptedUI();
    const code = await main(['--cwd', dir, ...OFFLINE], { ui });
    expect(code, ui.text).toBe(0);
    expect(ui.text).toContain('Clikgate sees every click. Setup complete.');
    await expect(treeDiff(fixture, dir)).toMatchFileSnapshot(`__snapshots__/${fixture}.diff`);
    // Uninstall tracking: SwiftUI apps without an AppDelegate get the forward line as a manual step;
    // every iOS project gets aps-environment and the signing note.
    if (fixture === 'ios-swiftui') expect(ui.text).toContain('Forward the APNs token');
    if (fs.existsSync(path.join(projectRoot(fixture, dir), 'ios')) || fixture.startsWith('ios-')) expect(ui.text).toContain('Push Notifications capability (aps-environment) was added');

    const root = projectRoot(fixture, dir);
    // Android: the app's test subdomain only in debug source sets; live domains in main; no shared domain.
    const m = manifests(root);
    for (const f of m.release) expect(allLinkHosts(fs.readFileSync(f, 'utf8')).has(TEST), f).toBe(false);
    const mainManifest = m.release.find((f) => f.includes(`${path.sep}main${path.sep}`));
    if (mainManifest) {
      const hosts = verifiedHosts(fs.readFileSync(mainManifest, 'utf8'));
      expect([...hosts].sort()).toEqual(['acme.ciz.to', 'go.acme.com']);
      expect(m.debug.some((f) => verifiedHosts(fs.readFileSync(f, 'utf8')).has(TEST))).toBe(true);
    }
    // iOS: every configuration links an entitlements file; only Debug has the test subdomain.
    for (const c of iosConfigs(root)) {
      expect(c.hosts).toEqual(expect.arrayContaining(['acme.ciz.to', 'go.acme.com']));
      for (const shared of ['ciz.to', 'clk.ng', 'clkg.to', 'dev.ciz.to']) expect(c.hosts).not.toContain(shared);
      expect(c.hosts.includes(TEST), `${c.name}`).toBe(c.debug);
      expect(c.aps, `${c.name} aps-environment`).toBe(c.debug ? 'development' : 'production');
    }
    // Expo: the plugin keeps the test domain apart from linkDomains.
    const appJson = path.join(root, 'app.json');
    if (fixture.startsWith('expo')) {
      const plugins = JSON.parse(fs.readFileSync(appJson, 'utf8')).expo.plugins as unknown[];
      const entry = plugins.find((p) => Array.isArray(p) && p[0] === '@clikgate/react-native') as [string, { linkDomains: string[]; testLinkDomain: string }];
      expect(entry[1]).toEqual({ linkDomains: ['acme.ciz.to', 'go.acme.com'], testLinkDomain: TEST });
    }
    // No telemetry, no live key: only the test key appears in the project.
    const all = [...snapshotTree(dir).values()].join('\n');
    expect(all).not.toMatch(/cg_sdk_live_/);
    // The SDKs' platformDomainBrowserFallback opt-out keeps its default: never written.
    expect(all).not.toMatch(/platformDomainBrowserFallback/);

    // Backups (not a git repository).
    expect(fs.existsSync(path.join(dir, fixture === 'monorepo' ? 'apps/mobile' : '.', '.clikgate-setup-backup'))).toBe(true);

    // Second run: nothing changes.
    const before = snapshotTree(dir);
    const ui2 = new ScriptedUI();
    expect(await main(['--cwd', dir, ...OFFLINE], { ui: ui2 })).toBe(0);
    expect(ui2.text).toContain('Everything is already set up.');
    expect(snapshotTree(dir)).toEqual(before);
  });
});
