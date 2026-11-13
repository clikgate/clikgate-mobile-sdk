import * as path from 'node:path';
import { setupCommand, setupSubcommand } from './command';
import type { Platform } from './args';
import { Clikgate, type SetupCheck, type FileCheck } from './api/clikgate';
import { CLI_VERSION, DOCS_URL, SDK, SDK_KEY_ANY, SHARED_DOMAIN_FIX, SHARED_PLATFORM_DOMAINS, TEST_LINK_DOMAIN, isTestHost, maskKey } from './constants';
import { allLinkHosts, verifiedHosts } from './edit/androidManifest';
import { backupDeclarations, backupProblems } from './edit/backupRules';
import { catalogAliasFor, hasClikgateDependency } from './edit/gradle';
import { expoRoot, findClikgatePlugin, parseJsonc } from './edit/json';
import { apsEnvironment, applinksHosts } from './edit/plistEdit';
import { hasPushTokenForward } from './edit/source';
import { dependencyConstraint } from './edit/pubspec';
import { exists, findFiles, read, readIfExists, rel } from './fsutil';
import { isDebugSourceSet, type AndroidModule } from './project/android';
import type { IosProject } from './project/ios';
import { targetSwiftFiles } from './project/ios';

/**
 * `doctor` (S.5): local checks of the project files, then (when signed in) Clikgate's
 * setup-check, then an optional wait for the first test event. Never changes anything.
 * The JSON form (`--json`) is a stable interface for CI and AI assistants: schema_version 1.
 */

export type CheckStatus = 'pass' | 'warn' | 'fail' | 'skip';
export type CheckGroup = 'project' | 'clikgate' | 'live';

export interface Check {
  id: string;
  group: CheckGroup;
  status: CheckStatus;
  title: string;
  detail?: string;
  fix?: string;
  doc_url?: string;
  /** Machine-readable problem code from Clikgate (setup-check `problem`), for --json. */
  code?: string;
}

export interface DoctorReport {
  schema_version: 1;
  command: 'doctor';
  cli_version: string;
  project: { path: string; platform: Platform | null };
  ok: boolean;
  summary: { passed: number; warnings: number; failed: number; skipped: number };
  checks: Check[];
  next_steps: { message: string; doc_url: string | null }[];
}

export interface DoctorInput {
  root: string;
  platform: Platform;
  android?: AndroidModule;
  ios?: IosProject;
  /** Domains the project should cover (from --domain or Clikgate); otherwise inferred. */
  expectedLiveDomains?: string[];
  appConfig?: string;
}

export interface ServerInput {
  clikgate: Clikgate;
  apps: { id: string; platform: 'android' | 'ios' }[];
}

const DOC = (anchor: string) => `${DOCS_URL}#${anchor}`;
const UNINSTALL_DOC = 'https://clikgate.com/docs/uninstall-tracking';

export function versionAtLeast(constraint: string | undefined, minimum: string): boolean | undefined {
  if (!constraint) return undefined;
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(constraint);
  if (!m) return undefined;
  const [a, b, c] = minimum.split('.').map(Number);
  const v = [Number(m[1]), Number(m[2]), Number(m[3])];
  if (v[0] !== a) return v[0] > a;
  if (v[1] !== b) return v[1] > b;
  return v[2] >= c;
}

function startupFiles(input: DoctorInput): string[] {
  const { root } = input;
  switch (input.platform) {
    case 'flutter':
      return [path.join(root, 'lib', 'main.dart')].filter(exists);
    case 'react-native':
    case 'expo':
      return ['App.tsx', 'App.jsx', 'App.js', 'src/App.tsx', 'src/App.js', 'app/_layout.tsx', 'src/app/_layout.tsx', 'app/_layout.js', 'src/app/_layout.js', 'index.js', 'index.ts']
        .map((f) => path.join(root, f))
        .filter(exists);
    case 'android':
      return input.android ? findFiles(path.join(input.android.moduleDir, 'src', 'main'), /\.(kt|java)$/, 12) : [];
    case 'ios':
      return input.ios ? targetSwiftFiles(input.ios) : [];
  }
}

function localChecks(input: DoctorInput): { checks: Check[]; liveHostsFound: Set<string> } {
  const checks: Check[] = [];
  const add = (c: Omit<Check, 'group'> & { group?: CheckGroup }) => checks.push({ group: 'project', ...c });
  // Change 09 (N.1): shared domains list no customer app, so they can never open this one.
  const sharedCheck = (id: string, name: string, hosts: string[], prefix = '') => {
    const shared = [...new Set(hosts.map((h) => h.toLowerCase()))].filter((h) => SHARED_PLATFORM_DOMAINS.includes(h));
    if (shared.length) {
      add({
        id: `${id}.shared_domains`,
        status: 'warn',
        title: `${name}: ${shared.map((h) => prefix + h).join(', ')}: ${SHARED_DOMAIN_FIX}`,
        fix: `Remove ${shared.map((h) => prefix + h).join(', ')}. Use your app's link subdomain (<link_subdomain>.ciz.to in release builds, or <link_subdomain>.clk.ng on the Free plan; <link_subdomain>.dev.ciz.to in debug builds) and your verified custom domains. Run \`${setupCommand()}\` to add them.`,
        doc_url: DOC('app-link-subdomains'),
      });
    } else add({ id: `${id}.shared_domains`, status: 'pass', title: `${name}: no shared Clikgate domain in app links` });
  };
  const { root, platform } = input;
  const shown = rel(process.cwd(), root);
  add({ id: 'project.detected', status: 'pass', title: `Project: ${platform}`, detail: shown === '' ? '.' : shown.startsWith('..') ? root : shown });

  // ---- SDK dependency and version
  let constraint: string | undefined;
  let hasDep = false;
  let depLabel = '';
  if (platform === 'flutter') {
    depLabel = SDK.flutter.package;
    constraint = dependencyConstraint(read(path.join(root, 'pubspec.yaml')), SDK.flutter.package);
    hasDep = constraint !== undefined;
  } else if (platform === 'react-native' || platform === 'expo') {
    depLabel = SDK.reactNative.package;
    const pkg = parseJsonc<{ dependencies?: Record<string, string> }>(read(path.join(root, 'package.json')));
    constraint = pkg.dependencies?.[SDK.reactNative.package];
    hasDep = constraint !== undefined;
  } else if (platform === 'android' && input.android) {
    depLabel = `${SDK.android.group}:${SDK.android.artifact}`;
    const build = read(input.android.buildFile);
    const catalog = input.android.catalog ? read(input.android.catalog) : undefined;
    hasDep = hasClikgateDependency(build, catalog);
    constraint = new RegExp(`${SDK.android.group}:${SDK.android.artifact}:([0-9][^"')\\s]*)`).exec(build)?.[1];
    if (!constraint && catalog && catalogAliasFor(catalog)) constraint = /^\s*clikgate\s*=\s*"([^"]+)"/m.exec(catalog)?.[1];
  } else if (platform === 'ios' && input.ios) {
    depLabel = SDK.ios.pod;
    const pod = input.ios.podfile ? read(input.ios.podfile) : '';
    const pm = /pod\s+['"]Clikgate(?:\/[A-Za-z]+)?['"]\s*(?:,\s*['"]([^'"]+)['"])?/.exec(pod);
    const spm = read(input.ios.pbxproj).includes('clikgate-ios-sdk');
    hasDep = Boolean(pm) || spm;
    constraint = pm?.[1] ?? (spm ? undefined : undefined);
  }
  const minimum = platform === 'flutter' ? SDK.flutter.minimum : platform === 'react-native' || platform === 'expo' ? SDK.reactNative.minimum : platform === 'android' ? SDK.android.version : SDK.ios.version;
  if (!hasDep) {
    const fix =
      platform === 'ios' && !input.ios?.podfile
        ? `Add the Clikgate Swift package in Xcode: File › Add Package Dependencies…, ${SDK.ios.spm}, from ${SDK.ios.version}.`
        : 'Run `' + setupCommand() + '` to add it.';
    add({ id: 'sdk.dependency', status: 'fail', title: `${depLabel} dependency`, detail: 'not found', fix, doc_url: DOC('what-gets-changed') });
  } else {
    add({ id: 'sdk.dependency', status: 'pass', title: `${depLabel} dependency`, detail: constraint ?? 'found' });
    const ok = versionAtLeast(constraint, minimum);
    if (ok === false) add({ id: 'sdk.version', status: 'warn', title: `SDK version ${constraint}`, detail: `below the minimum ${minimum}`, fix: `Update ${depLabel} to ${minimum} or newer.` });
  }

  // ---- Start-up code and key
  const files = startupFiles(input);
  const withConfigure = files.filter((f) => /Clikgate\s*\.\s*configure\s*\(/.test(read(f)));
  if (withConfigure.length === 0) {
    add({ id: 'startup.code', status: 'fail', title: 'Start-up code', detail: 'Clikgate.configure(...) not found', fix: 'Run `' + setupCommand() + '`, or add Clikgate.configure at app start (see the docs).', doc_url: DOC('what-gets-changed') });
  } else {
    add({ id: 'startup.code', status: 'pass', title: 'Start-up code', detail: withConfigure.map((f) => rel(root, f)).join(', ') });
  }
  const keys = new Set<string>();
  for (const f of withConfigure) for (const m of read(f).matchAll(new RegExp(SDK_KEY_ANY.source, 'g'))) keys.add(m[0]);
  if (withConfigure.length) {
    if (keys.size === 0) add({ id: 'sdk.key', status: 'warn', title: 'SDK key', detail: 'no cg_sdk_ key found in the start-up code (read from elsewhere?)' });
    else {
      const live = [...keys].filter((k) => k.startsWith('cg_sdk_live_'));
      const masked = [...keys].map(maskKey).join(', ');
      add({
        id: 'sdk.key',
        status: 'pass',
        title: live.length ? 'Live SDK key in use' : 'Test SDK key in use',
        detail: masked,
        ...(live.length ? { fix: 'Use the test key (cg_sdk_test_…) in debug builds; the live key is for release builds.' } : {}),
      });
    }
  }

  // ---- App links (Android)
  const liveHosts = new Set<string>();
  const expected = new Set(input.expectedLiveDomains ?? []);
  const androidRelease: Set<string>[] = [];
  if (input.android) {
    const mod = input.android;
    const main = readIfExists(mod.mainManifest);
    if (main) {
      const release = new Set(verifiedHosts(main));
      const releaseAll = new Set(allLinkHosts(main));
      const debugHosts = new Set<string>();
      for (const s of mod.sourceSetManifests) {
        const t = read(s.file);
        if (isDebugSourceSet(s.name)) verifiedHosts(t).forEach((h) => debugHosts.add(h));
        else {
          verifiedHosts(t).forEach((h) => release.add(h));
          allLinkHosts(t).forEach((h) => releaseAll.add(h));
        }
      }
      const releaseTest = [...releaseAll].filter(isTestHost);
      if (releaseTest.length) {
        add({ id: 'android.release_no_test_domain', status: 'fail', title: `Android: ${releaseTest.join(', ')} in a release manifest`, fix: `Move the ${releaseTest.join(', ')} intent filter to src/debug/AndroidManifest.xml: test links must only open debug builds.` });
      } else {
        add({ id: 'android.release_no_test_domain', status: 'pass', title: `Android: no test domain (*.${TEST_LINK_DOMAIN}) in release builds` });
      }
      [...release].filter(isTestHost).forEach((h) => release.delete(h));
      release.forEach((h) => liveHosts.add(h));
      androidRelease.push(release);
      const debugTest = [...debugHosts].filter((h) => h.endsWith(`.${TEST_LINK_DOMAIN}`));
      if (debugTest.length) add({ id: 'android.debug_test_domain', status: 'pass', title: `Android: ${debugTest.join(', ')} in debug builds` });
      else add({ id: 'android.debug_test_domain', status: 'warn', title: `Android: your app's test subdomain (<link_subdomain>.${TEST_LINK_DOMAIN}) missing from debug builds`, fix: 'Test links won\'t open debug builds. Run `' + setupCommand() + '` to add it to src/debug/AndroidManifest.xml.' });
      sharedCheck('android', 'Android', [...releaseAll, ...debugHosts]);
      // Auto Backup: the app's own rules need Clikgate's excludes and tools:replace (else the
      // manifest merge fails). No own rules: the SDK's rules apply.
      let decls: ReturnType<typeof backupDeclarations> = [];
      try {
        decls = backupDeclarations(main);
      } catch {
        decls = [];
      }
      if (decls.length) {
        const resDir = path.join(path.dirname(mod.mainManifest), 'res', 'xml');
        const problems = backupProblems(main, (r) => readIfExists(path.join(resDir, `${r}.xml`)) ?? null);
        if (problems.length) {
          add({
            id: 'android.backup_rules',
            status: 'fail',
            title: 'Android: backup rules',
            detail: problems.join('; '),
            fix: "Run `" + setupCommand() + "` to add Clikgate's excludes to your backup rules and tools:replace to <application>.",
          });
        } else add({ id: 'android.backup_rules', status: 'pass', title: "Android: backup rules exclude Clikgate's installation ID" });
      }
    }
  }

  // ---- App links (iOS)
  const iosRelease: Set<string>[] = [];
  if (input.ios) {
    const ios = input.ios;
    const iosAll: string[] = [];
    for (const c of ios.configs) {
      if (!c.entitlements) {
        add({ id: `ios.entitlements.${c.name}`, status: c.debug ? 'warn' : 'fail', title: `iOS ${c.name}: no entitlements file`, fix: 'Run `' + setupCommand() + '` to add Associated Domains for this build configuration.' });
        continue;
      }
      const file = path.join(ios.srcRoot, c.entitlements);
      const text = readIfExists(file);
      if (text === undefined) {
        add({ id: `ios.entitlements.${c.name}`, status: 'fail', title: `iOS ${c.name}: ${c.entitlements} is missing`, fix: 'CODE_SIGN_ENTITLEMENTS points to a file that doesn\'t exist.' });
        continue;
      }
      let hosts: string[];
      try {
        hosts = applinksHosts(text);
      } catch (e) {
        add({ id: `ios.entitlements.${c.name}`, status: 'fail', title: `iOS ${c.name}: ${c.entitlements} isn't a valid plist`, detail: (e as Error).message });
        continue;
      }
      iosAll.push(...hosts);
      const testHosts = hosts.filter(isTestHost);
      const appTest = hosts.filter((h) => h.endsWith(`.${TEST_LINK_DOMAIN}`));
      if (c.debug) {
        if (appTest.length) add({ id: `ios.entitlements.${c.name}`, status: 'pass', title: `iOS ${c.name}: associated domains include ${appTest.join(', ')}`, detail: hosts.join(', ') });
        else add({ id: `ios.entitlements.${c.name}`, status: 'warn', title: `iOS ${c.name}: your app's test subdomain (<link_subdomain>.${TEST_LINK_DOMAIN}) missing`, fix: 'Test links won\'t open Debug builds. Run `' + setupCommand() + '`.' });
      } else if (testHosts.length) {
        add({ id: `ios.entitlements.${c.name}`, status: 'fail', title: `iOS ${c.name}: ${testHosts.join(', ')} in a release configuration`, fix: `Remove ${testHosts.map((h) => `applinks:${h}`).join(', ')} from ${c.entitlements}; keep test domains in the Debug entitlements only.` });
      } else {
        const set = new Set(hosts);
        set.forEach((h) => liveHosts.add(h));
        iosRelease.push(set);
        add({ id: `ios.entitlements.${c.name}`, status: hosts.length ? 'pass' : 'fail', title: `iOS ${c.name}: associated domains`, detail: hosts.join(', ') || 'none', ...(hosts.length ? {} : { fix: 'Add applinks:<your app link subdomain>.ciz.to (.clk.ng on the Free plan). Run `' + setupCommand() + '`.' }) });
      }
    }
    sharedCheck('ios', 'iOS', iosAll, 'applinks:');
    pushChecks(input, ios, add);
  }

  // ---- Expo config plugin
  if (platform === 'expo') {
    const cfg = input.appConfig;
    if (!cfg || !cfg.endsWith('app.json')) {
      add({ id: 'expo.plugin', status: 'warn', title: 'Expo config plugin', detail: `${cfg ? rel(root, cfg) : 'app config'} is code; not checked`, fix: `Make sure its plugins include ["${SDK.reactNative.package}", {"linkDomains": ["<link_subdomain>.ciz.to", ...], "testLinkDomain": "<link_subdomain>.${TEST_LINK_DOMAIN}"}].` });
    } else {
      const json = parseJsonc(read(cfg));
      const found = findClikgatePlugin(json);
      const props = found?.props ?? {};
      const domains = Array.isArray(props.linkDomains) ? (props.linkDomains as string[]) : [];
      if (!found) add({ id: 'expo.plugin', status: 'fail', title: 'Expo config plugin', detail: 'not in app.json', fix: 'Run `' + setupCommand() + '`.' });
      else if (domains.some(isTestHost)) {
        const t = domains.filter(isTestHost);
        add({ id: 'expo.plugin', status: 'fail', title: 'Expo config plugin', detail: `${t.join(', ')} is in linkDomains (all builds)`, fix: `Move it to "testLinkDomain" (development/preview builds only).` });
      } else {
        domains.forEach((d) => liveHosts.add(d));
        androidRelease.push(new Set(domains));
        add({ id: 'expo.plugin', status: domains.length ? 'pass' : 'warn', title: 'Expo config plugin', detail: `linkDomains: ${domains.join(', ') || 'none'}; testLinkDomain: ${String(props.testLinkDomain ?? 'not set')}` });
      }
      sharedCheck('expo', 'Expo', [...domains, ...(typeof props.testLinkDomain === 'string' ? [props.testLinkDomain] : [])]);
      void expoRoot(json);
    }
  }

  // ---- Every live domain covered on each platform
  const want = expected.size ? expected : new Set([...liveHosts].filter((h) => !SHARED_PLATFORM_DOMAINS.includes(h)));
  const sides: [string, Set<string>[]][] = [['Android', androidRelease], ['iOS', iosRelease]];
  for (const [name, sets] of sides) {
    if (sets.length === 0 || want.size === 0) continue;
    const missing = [...want].filter((h) => sets.some((s) => !s.has(h)));
    const id = `${name.toLowerCase()}.release_domains`;
    if (missing.length) {
      add({ id, status: expected.size ? 'fail' : 'warn', title: `${name}: release builds miss ${missing.join(', ')}`, fix: 'Run `' + setupCommand() + '` to add every live link domain.' });
    } else {
      add({ id, status: 'pass', title: `${name}: release builds cover ${[...want].join(', ')}` });
    }
  }
  return { checks, liveHostsFound: liveHosts };
}

/**
 * Uninstall tracking on iOS (`automaticPushToken`): the Push Notifications capability in every
 * build configuration, and the AppDelegate line that hands the APNs token to Clikgate (not on
 * Flutter: the plugin receives it as an application delegate). Warnings only: apps that don't use
 * uninstall tracking don't need either.
 */
function pushChecks(input: DoctorInput, ios: IosProject, add: (c: Omit<Check, 'group'>) => void): void {
  const missing: string[] = [];
  let read_ = 0;
  for (const c of ios.configs) {
    const text = c.entitlements ? readIfExists(path.join(ios.srcRoot, c.entitlements)) : undefined;
    if (text === undefined) {
      missing.push(c.name);
      continue;
    }
    try {
      if (!apsEnvironment(text)) missing.push(c.name);
      read_++;
    } catch {
      missing.push(c.name);
    }
  }
  if (missing.length) {
    add({
      id: 'ios.push.aps_environment',
      status: 'warn',
      title: `iOS: Push Notifications capability (aps-environment) missing in ${missing.join(', ')}`,
      detail: 'Uninstall tracking needs an APNs token; users are never asked for notification permission.',
      fix: 'Run `' + setupCommand() + '` (development in Debug, production in Release), or add Push Notifications in Xcode › Signing & Capabilities.',
      doc_url: UNINSTALL_DOC,
    });
  } else if (read_) add({ id: 'ios.push.aps_environment', status: 'pass', title: 'iOS: Push Notifications capability (aps-environment)' });

  if (input.platform === 'flutter') return; // the plugin forwards the token itself
  const files = [
    ...targetSwiftFiles(ios),
    ...['AppDelegate.mm', 'AppDelegate.m'].map((n) => path.join(ios.srcRoot, ios.target, n)).filter(exists),
  ];
  const forwarding = files.filter((f) => hasPushTokenForward(read(f)));
  const delegate = files.find((f) => /class\s+\w+\s*:[^{]*\b(UIApplicationDelegate|ExpoAppDelegate|RCTAppDelegate)\b/.test(read(f)) || /@implementation\s+\w*AppDelegate\b/.test(read(f)));
  const call = input.platform === 'ios' ? 'Clikgate.shared.setPushToken(deviceToken: deviceToken)' : 'ClikgateRN.setPushToken(deviceToken: deviceToken)';
  if (forwarding.length) {
    add({ id: 'ios.push.token_forward', status: 'pass', title: 'iOS: APNs token forwarded to Clikgate', detail: forwarding.map((f) => rel(input.root, f)).join(', ') });
  } else {
    add({
      id: 'ios.push.token_forward',
      status: 'warn',
      title: 'iOS: the APNs token isn\'t forwarded to Clikgate',
      detail: delegate ? rel(input.root, delegate) : 'no AppDelegate found',
      fix: `Uninstall tracking: in application(_:didRegisterForRemoteNotificationsWithDeviceToken:) call ${call}. ${delegate ? 'Run `' + setupCommand() + '` to add it.' : 'SwiftUI apps: add an AppDelegate with @UIApplicationDelegateAdaptor.'}`,
      doc_url: UNINSTALL_DOC,
    });
  }
}

/** Plain-language fixes for setup-check `problem` codes (the code itself stays in `code`). */
const PROBLEM_FIXES: Record<string, (host: string, platform: 'android' | 'ios') => string> = {
  domain_not_active: (h) => `${h} isn't active yet: finish its setup in the dashboard (Domains).`,
  unreachable: (h) => `Clikgate couldn't reach https://${h}. Check the domain's DNS record and certificate in the dashboard (Domains).`,
  not_served: (h, p) => `https://${h} doesn't serve the ${p === 'ios' ? 'apple-app-site-association' : 'assetlinks.json'} file yet. Check the domain's status in the dashboard.`,
  redirected: (h) => `https://${h}/.well-known/… redirects; app-links files must be served without redirects. Check the domain's DNS points at Clikgate (not another service).`,
  invalid_json: (h) => `The app-links file on ${h} isn't valid JSON. Contact Clikgate support.`,
  missing_team_id: () => 'Add your Apple Team ID (10 characters) to the iOS app in the dashboard, or rerun `' + setupCommand() + '`.',
  missing_fingerprints: () => 'Add your signing SHA-256 fingerprints (debug and Play App Signing) to the Android app in the dashboard, or rerun `' + setupCommand() + '`.',
  app_not_listed: (h) => `${h}'s app-links file doesn't list this app yet. Check the app's identifiers in the dashboard, then run doctor again in a few minutes.`,
  wrong_fingerprint: () => 'The fingerprints in Clikgate don\'t match your signing certificate. Add the SHA-256 from `keytool` (debug) and Play Console › Release › Setup › App signing (release).',
  link_subdomain_not_confirmed: () => 'Confirm the app\'s link subdomain in the dashboard (Apps › your app › Link subdomain), or run `' + setupCommand() + '` and confirm it.',
};

function fileCheck(platform: 'android' | 'ios', d: { aasa?: FileCheck; assetlinks?: FileCheck }): [string, FileCheck | undefined] {
  const candidates: [string, FileCheck | undefined][] = [
    ['apple-app-site-association', d.aasa],
    ['assetlinks.json', d.assetlinks],
  ];
  const applied = candidates.find(([, c]) => c?.applies === true);
  if (applied) return applied;
  return platform === 'ios' ? candidates[0] : candidates[1];
}

export function serverChecks(app: { id: string; platform: 'android' | 'ios' }, report: SetupCheck): { checks: Check[]; next: { message: string; doc_url: string | null }[] } {
  const checks: Check[] = [];
  const label = app.platform === 'ios' ? 'iOS' : 'Android';
  const add = (c: Omit<Check, 'group'>) => checks.push({ group: 'clikgate', ...c });
  const a = report.app ?? {};
  if (app.platform === 'android') {
    const ok = a.fingerprints_present ?? (a.sha256_cert_fingerprints?.length ?? 0) > 0;
    add({ id: `clikgate.${app.platform}.fingerprints`, status: ok ? 'pass' : 'fail', title: `${label} app: signing fingerprints`, ...(ok ? {} : { fix: 'Add the SHA-256 of your signing certificates (debug and Play App Signing) in the dashboard or rerun setup.' }) });
  } else {
    const ok = a.team_id_present ?? Boolean(a.team_id);
    add({ id: `clikgate.${app.platform}.team_id`, status: ok ? 'pass' : 'fail', title: `${label} app: Team ID`, ...(ok ? {} : { fix: 'Add your Apple Team ID (10 characters) in the dashboard or rerun setup.' }) });
  }
  // Change 09 (N.1): the app's own link subdomain, whose files list only this app.
  if (a.link_subdomain) {
    const hosts = a.link_hostnames ?? { live: `${a.link_subdomain}.ciz.to`, test: `${a.link_subdomain}.dev.ciz.to` };
    if (a.link_subdomain_confirmed === false) {
      add({ id: `clikgate.${app.platform}.link_subdomain`, status: 'fail', title: `${label} app: link subdomain ${hosts.live} isn't confirmed`, fix: PROBLEM_FIXES.link_subdomain_not_confirmed(hosts.live, app.platform), code: 'link_subdomain_not_confirmed' });
    } else {
      add({ id: `clikgate.${app.platform}.link_subdomain`, status: 'pass', title: `${label} app: link subdomain ${hosts.live} (debug builds ${hosts.test})` });
    }
  }
  for (const d of report.domains ?? []) {
    const [fileName, c] = fileCheck(app.platform, d);
    const id = `clikgate.domain.${d.hostname}.${app.platform === 'ios' ? 'aasa' : 'assetlinks'}`;
    if (!c) {
      add({ id, status: 'skip', title: `${d.hostname}: ${fileName}`, detail: 'not reported' });
      continue;
    }
    if (c.served && c.contains_app) {
      add({ id, status: 'pass', title: `${d.hostname}: ${fileName} lists this app` });
      continue;
    }
    const problem = c.problem ?? (c.served ? 'app_not_listed' : 'not_served');
    const fix = PROBLEM_FIXES[problem]?.(d.hostname, app.platform) ?? `Clikgate reports: ${problem}. See the dashboard (Domains).`;
    add({ id, status: 'fail', title: `${d.hostname}: ${fileName} ${c.served ? "doesn't list this app" : 'not served'}`, fix, code: problem });
  }
  for (const w of report.sdk?.warnings ?? []) {
    add({ id: `clikgate.sdk.${w.code ?? 'warning'}`, status: w.severity === 'error' ? 'fail' : 'warn', title: w.message ?? w.code ?? 'SDK warning' });
  }
  const next = (report.next_steps ?? []).map((n) => ({ message: n.message, doc_url: n.doc_url ?? null }));
  return { checks, next };
}

export function summarise(root: string, platform: Platform | null, checks: Check[], next: { message: string; doc_url: string | null }[]): DoctorReport {
  const count = (s: CheckStatus) => checks.filter((c) => c.status === s).length;
  const failed = count('fail');
  return {
    schema_version: 1,
    command: 'doctor',
    cli_version: CLI_VERSION,
    project: { path: root, platform },
    ok: failed === 0,
    summary: { passed: count('pass'), warnings: count('warn'), failed, skipped: count('skip') },
    checks,
    next_steps: next,
  };
}

export interface LiveWaitDeps {
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  /** Resolves when the person presses Enter (skip). */
  skip?: Promise<boolean>;
}

/** Polls setup-check until a test-mode SDK request arrives (up to `timeoutMs`). */
export async function waitForFirstEvent(clikgate: Clikgate, apps: { id: string; platform: 'android' | 'ios' }[], timeoutMs: number, deps: LiveWaitDeps = {}): Promise<Check> {
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
  const now = deps.now ?? Date.now;
  const deadline = now() + timeoutMs;
  let skipped = false;
  void deps.skip?.then((v) => {
    if (v) skipped = true;
  });
  for (;;) {
    for (const app of apps) {
      try {
        const r = await clikgate.setupCheck(app.id);
        if (r.sdk?.first_test_request_at || r.sdk?.last_test_request_at) {
          const p = r.sdk.platform ?? app.platform;
          const name = p === 'ios' ? 'iOS' : p === 'android' ? 'Android' : p;
          return { id: 'live.first_event', group: 'live', status: 'pass', title: `Clikgate is receiving events from ${name} ✓`, detail: r.sdk.sdk_version ? `SDK ${r.sdk.sdk_version}` : undefined };
        }
      } catch {
        // keep waiting
      }
    }
    if (skipped) return { id: 'live.first_event', group: 'live', status: 'skip', title: 'First event: skipped' };
    if (now() >= deadline) {
      return {
        id: 'live.first_event',
        group: 'live',
        status: 'warn',
        title: 'No event from your app yet',
        fix: 'Run the app on a device or emulator (a debug build with the test key), then run `' + setupSubcommand('doctor') + '` again.',
      };
    }
    await sleep(5000);
    if (skipped) return { id: 'live.first_event', group: 'live', status: 'skip', title: 'First event: skipped' };
  }
}

export function runLocalChecks(input: DoctorInput): Check[] {
  return localChecks(input).checks;
}
