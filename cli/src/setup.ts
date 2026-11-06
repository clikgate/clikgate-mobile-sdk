import * as path from 'node:path';
import type { Options, Platform } from './args';
import { applyPlan, undoInstructions, type ApplyDeps, type ApplyResult } from './apply';
import { ApiClient, ApiError, NetworkError, type Fetch } from './api/client';
import { Clikgate, isSharedPlatformDomain, isTestDomain, type App } from './api/clikgate';
import { openBrowser, signIn, SignInError } from './api/device';
import {
  DASHBOARD_URL,
  DEFAULT_API_URL,
  EXIT,
  GOAL_SNIPPET,
  SDK_KEY_LIVE,
  SDK_KEY_TEST,
  SHARED_DOMAIN_FIX,
  SUCCESS_LINE,
  TEST_LINK_DOMAIN,
  appLinkHosts,
  appLinkParentOf,
  appSubdomainOf,
  isTestHost,
} from './constants';
import { detect, detectPackageManager, type Candidate } from './detect';
import { runLocalChecks, serverChecks, waitForFirstEvent, type Check } from './doctor';
import { exists, read, rel } from './fsutil';
import { backupFiles, treeState } from './git';
import { debugFingerprint, defaultDebugKeystore, normaliseFingerprint } from './keytool';
import { changes, renderDiffs, renderPlan, type Plan } from './plan';
import { buildPlan } from './platforms';
import { loadProject, needsPlatforms, type Project } from './project/load';
import { paint, type UI } from './ui';

export interface Deps {
  ui: UI;
  fetch?: Fetch;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  openBrowser?: (url: string) => void;
  debugFingerprint?: (keystore?: string) => string | undefined;
  apply?: ApplyDeps;
  /** Doctor's first-event wait (ms); 5 minutes by default. */
  liveWaitMs?: number;
}

const PLATFORM_LABEL: Record<Platform, string> = {
  flutter: 'Flutter',
  'react-native': 'React Native',
  expo: 'Expo',
  android: 'Android',
  ios: 'iOS',
};

export class Exit extends Error {
  constructor(readonly code: number, message = '') {
    super(message);
  }
}

// --------------------------------------------------------------------------------- detection

export async function chooseProject(opts: Options, ui: UI): Promise<Candidate> {
  const root = path.resolve(opts.cwd);
  if (!exists(root)) throw new Exit(EXIT.PROBLEMS, `${opts.cwd} doesn't exist.`);
  let found = detect(root);
  if (opts.platform) {
    const match = found.filter((c) => c.platform === opts.platform);
    found = match.length ? match : [{ platform: opts.platform, root, nativeFolders: { android: exists(path.join(root, 'android')), ios: exists(path.join(root, 'ios')) } }];
  }
  if (found.length === 0) {
    throw new Exit(
      EXIT.PROBLEMS,
      [
        `No app project found in ${root}.`,
        'The setup command works in a Flutter, React Native, Expo, native Android (Gradle) or native iOS (Xcode) app project.',
        'Run it in the project folder, or pass --cwd <path> (and --platform <flutter|react-native|expo|android|ios> to skip detection).',
        'For a website, run: npx @clikgate/setup website',
      ].join('\n')
    );
  }
  if (found.length === 1) return found[0];
  const [i] = await ui.choose(
    'Several app projects were found. Which one should Clikgate set up?',
    found.map((c) => `${PLATFORM_LABEL[c.platform]}  ${rel(root, c.root) || '.'}`)
  );
  return found[i];
}

// ----------------------------------------------------------------------------- signed-in work

interface OnlineResult {
  clikgate: Clikgate;
  apps: Partial<Record<'android' | 'ios', App>>;
  organization: string;
}

async function connect(opts: Options, deps: Deps, project: Project): Promise<{ clikgate: Clikgate; organization: string }> {
  const api = new ApiClient({ baseUrl: opts.apiUrl ?? DEFAULT_API_URL, fetch: deps.fetch });
  try {
    const session = await signIn(api, project.candidate.platform, {
      print: (l) => deps.ui.out(l),
      sleep: deps.sleep,
      now: deps.now,
      openBrowser: deps.openBrowser ?? (deps.ui.interactive ? openBrowser : undefined),
    });
    api.token = session.accessToken;
    deps.ui.out(paint(deps.ui, 'green', `✓ Signed in to ${session.organization.name}`));
    return { clikgate: new Clikgate(api), organization: session.organization.name };
  } catch (e) {
    if (e instanceof SignInError) throw new Exit(EXIT.SIGN_IN_FAILED, e.message);
    throw e;
  }
}

function sameId(a: string | null | undefined, b: string | undefined): boolean {
  return Boolean(a && b && a.toLowerCase() === b.toLowerCase());
}

async function askFingerprint(ui: UI, question: string): Promise<string | undefined> {
  for (let i = 0; i < 3; i++) {
    const a = await ui.ask(question);
    if (!a) return undefined;
    const fp = normaliseFingerprint(a);
    if (fp) return fp;
    ui.out('That isn\'t a SHA-256 fingerprint (32 bytes, like AB:CD:…). Try again, or press Enter to skip.');
  }
  return undefined;
}

/** Finds (or creates) the Clikgate apps and sends signing details (S.3 steps 4–5). */
async function pickApps(opts: Options, deps: Deps, project: Project, clikgate: Clikgate, manual: ManualNote[]): Promise<Partial<Record<'android' | 'ios', App>>> {
  const { ui } = deps;
  const out: Partial<Record<'android' | 'ios', App>> = {};
  const all = await clikgate.listApps();
  let forced: App | undefined;
  if (opts.app) {
    forced = all.find((a) => a.id === opts.app) ?? (await clikgate.getApp(opts.app));
  }
  for (const platform of needsPlatforms(project)) {
    const id = platform === 'android' ? project.androidAppId : project.iosBundleId;
    const label = platform === 'android' ? 'Android' : 'iOS';
    let app: App | undefined;
    if (forced && forced.platform === platform) app = forced;
    else {
      const matches = all.filter((a) => a.platform === platform && sameId(platform === 'android' ? a.package_name : a.bundle_id, id));
      if (matches.length === 1) app = matches[0];
      else if (matches.length > 1) {
        const [i] = await ui.choose(`Several Clikgate ${label} apps use ${id}. Which one?`, matches.map((a) => `${a.name} (${a.id})`));
        app = matches[i];
      }
    }
    if (app) {
      ui.out(`${paint(ui, 'green', '✓')} ${label} app: ${app.name} (${app.id})`);
    } else {
      if (!id) {
        manual.push({ label: `${label} app`, detail: `The project has no ${platform === 'android' ? 'applicationId' : 'bundle identifier'} the setup command could read, so no Clikgate ${label} app was matched or created. Create it in the dashboard, then run setup again with --app <app_id>.` });
        continue;
      }
      const create = opts.dryRun ? false : await ui.confirm(`No Clikgate ${label} app uses ${id}. Create "${project.name}" (${label}, ${id})?`, true);
      if (!create) {
        if (!opts.dryRun) manual.push({ label: `${label} app`, detail: `No Clikgate ${label} app for ${id}. Create one in the dashboard (Apps › Add app), then run setup again.` });
        else ui.out(`${paint(ui, 'dim', '·')} ${label}: no Clikgate app uses ${id} (a real run offers to create it)`);
        continue;
      }
      const body: Record<string, unknown> = { platform, name: project.name };
      if (platform === 'android') {
        const fp = (deps.debugFingerprint ?? debugFingerprint)(project.android?.debugKeystore ?? defaultDebugKeystore());
        const fps = fp ? [fp] : [];
        if (!fp) {
          const pasted = await askFingerprint(ui, 'keytool or the debug keystore wasn\'t found. Paste your debug signing SHA-256 (or press Enter to skip):');
          if (pasted) fps.push(pasted);
        }
        if (fps.length === 0) {
          manual.push({ label: 'Android app', detail: 'Clikgate needs at least one SHA-256 signing fingerprint to create the Android app. Create it in the dashboard, then run setup again.' });
          continue;
        }
        body.package_name = id;
        body.sha256_cert_fingerprints = fps;
      } else {
        let team = project.iosTeamId;
        if (!team) team = (await ui.ask('Your Apple Team ID (10 characters, from developer.apple.com › Membership), or Enter to skip:')).toUpperCase() || undefined;
        if (!team || !/^[A-Z0-9]{10}$/.test(team)) {
          manual.push({ label: 'iOS app', detail: 'Clikgate needs the Apple Team ID to create the iOS app. Create it in the dashboard (Apps › Add app), then run setup again.' });
          continue;
        }
        body.bundle_id = id;
        body.team_id = team;
      }
      app = await clikgate.createApp(body);
      ui.out(`${paint(ui, 'green', '✓')} Created the ${label} app ${app.name} (${app.id})`);
    }
    out[platform] = app;
  }
  return out;
}

async function sendSigningDetails(opts: Options, deps: Deps, project: Project, clikgate: Clikgate, apps: Partial<Record<'android' | 'ios', App>>, manual: ManualNote[]): Promise<void> {
  const { ui } = deps;
  const android = apps.android;
  if (android) {
    const have = new Set((android.sha256_cert_fingerprints ?? []).map((f) => f.toUpperCase()));
    const add: string[] = [];
    const debug = (deps.debugFingerprint ?? debugFingerprint)(project.android?.debugKeystore ?? defaultDebugKeystore());
    if (debug && !have.has(debug)) add.push(debug);
    if (debug) ui.out(`${paint(ui, 'green', '✓')} Debug signing SHA-256 ${have.has(debug) ? 'already in Clikgate' : 'read with keytool'}`);
    ui.out('Production App Links need the Play App Signing SHA-256 (Play Console › Release › Setup › App signing).');
    const play = opts.yes ? undefined : await askFingerprint(ui, 'Paste it now, or press Enter to add it later:');
    if (play && !have.has(play)) add.push(play);
    if (!play) manual.push({ label: 'Play App Signing fingerprint', detail: 'Add the Play App Signing SHA-256 to the Android app in the dashboard (Apps › your app › Signing). Without it, App Links open the browser in Play Store installs.' });
    if (add.length && !opts.dryRun) {
      apps.android = await clikgate.updateApp(android.id, { sha256_cert_fingerprints: [...(android.sha256_cert_fingerprints ?? []), ...add] });
      ui.out(`${paint(ui, 'green', '✓')} Sent ${add.length} signing fingerprint${add.length > 1 ? 's' : ''} to Clikgate`);
    }
  }
  const ios = apps.ios;
  if (ios) {
    if (!ios.team_id) {
      let team = project.iosTeamId;
      if (!team) team = (await ui.ask('Your Apple Team ID (10 characters), or Enter to skip:')).toUpperCase() || undefined;
      if (team && /^[A-Z0-9]{10}$/.test(team)) {
        if (!opts.dryRun) apps.ios = await clikgate.updateApp(ios.id, { team_id: team });
        ui.out(`${paint(ui, 'green', '✓')} Team ID ${team} sent to Clikgate`);
      } else manual.push({ label: 'Apple Team ID', detail: 'Add your Team ID to the iOS app in the dashboard so Universal Links can verify.' });
    } else ui.out(`${paint(ui, 'green', '✓')} Team ID ${ios.team_id} is set in Clikgate`);
  }
}

type PlatformKey = 'android' | 'ios';

interface ChosenDomains {
  /** Hosts for the SDK's linkDomains in code (every platform's release hosts). */
  code: string[];
  /** Release hosts written into manifests / entitlements (union, for Expo and single-list callers). */
  links: string[];
  /** The test host (debug builds), the first app's. */
  test?: string;
  /** Per-platform release / debug hosts: each platform's files get only its own app's hosts. */
  perPlatform: Partial<Record<PlatformKey, { live: string[]; test?: string }>>;
}

const LABEL: Record<PlatformKey, string> = { android: 'Android', ios: 'iOS' };

/**
 * Change 09 (N.1): an app opens links from its own link subdomain (`<sub>.ciz.to`; on the Free plan
 * `<sub>.clk.ng`, change 10 D.1; debug builds `<sub>.dev.ciz.to` on every plan) and the organisation's
 * active custom domains, from `app_link_domains`. Never a shared domain. An unconfirmed suggestion is
 * confirmed (after asking) with PATCH /v1/apps/{id}.
 */
async function confirmSubdomain(opts: Options, deps: Deps, clikgate: Clikgate, platform: PlatformKey, app: App, manual: ManualNote[]): Promise<App | undefined> {
  const { ui } = deps;
  if (app.link_subdomain_confirmed !== false) return app;
  let name = app.link_subdomain ?? '';
  const label = LABEL[platform];
  // ciz.to, or clk.ng on the Free plan: the server's live hostname says which.
  const parent = appLinkParentOf(app.link_hostnames?.live);
  if (opts.dryRun) {
    ui.out(`${paint(ui, 'dim', '·')} ${label} app link subdomain ${name}.${parent} isn't confirmed yet (a real run asks to confirm it)`);
    const hosts = appLinkHosts(name, parent);
    return { ...app, app_link_domains: { release: [hosts.live], debug: [hosts.test] } };
  }
  for (let attempt = 0; attempt < 3; attempt++) {
    const ok = opts.yes || !ui.interactive ? true : await ui.confirm(`Your ${label} app's links will open it from ${name}.${parent} (test links: ${name}.${TEST_LINK_DOMAIN}). Use "${name}"?`, true);
    if (!ok) {
      const typed = (await ui.ask('Type another link subdomain (3–30 lowercase letters, digits or hyphens), or press Enter to skip:')).trim().toLowerCase();
      if (!typed) break;
      const check = await clikgate.checkSubdomain(typed, platform, app.id);
      if (!check.available) {
        ui.out(`${paint(ui, 'yellow', '!')} ${typed}: ${check.message ?? check.reason ?? 'not available'}${check.suggestion ? ` (try ${check.suggestion})` : ''}`);
        if (check.suggestion) name = check.suggestion;
        continue;
      }
      name = typed;
    }
    try {
      const updated = await clikgate.updateApp(app.id, { link_subdomain: name });
      ui.out(`${paint(ui, 'green', '✓')} ${label} app link subdomain: ${updated.link_hostnames?.live ?? `${name}.${parent}`}`);
      return updated;
    } catch (e) {
      if (e instanceof ApiError && e.code === 'link_subdomain_unavailable' && !opts.yes) {
        ui.out(`${paint(ui, 'yellow', '!')} ${name}: ${e.message}`);
        continue;
      }
      throw e;
    }
  }
  manual.push({ label: `${label} link subdomain`, detail: `Confirm your ${label} app's link subdomain in the dashboard (Apps › your app › Link subdomain), then run setup again. Until then its links can't open the app.` });
  return undefined;
}

async function chooseDomains(opts: Options, deps: Deps, clikgate: Clikgate, apps: Partial<Record<PlatformKey, App>>, manual: ManualNote[]): Promise<ChosenDomains> {
  const { ui } = deps;
  const perPlatform: ChosenDomains['perPlatform'] = {};
  let customs: string[] | undefined;
  for (const platform of ['android', 'ios'] as PlatformKey[]) {
    let app = apps[platform];
    if (!app) continue;
    const confirmed = await confirmSubdomain(opts, deps, clikgate, platform, app, manual);
    if (!confirmed) continue;
    app = confirmed;
    if (!opts.dryRun) apps[platform] = app;
    let release = app.app_link_domains?.release;
    let debug = app.app_link_domains?.debug;
    if (!release || !debug) {
      // A server without app_link_domains: the app subdomain plus the organisation's active custom domains.
      if (customs === undefined) {
        const domains = await clikgate.listDomains();
        customs = domains
          .filter((d) => (d.kind ? d.kind === 'custom' : !isTestDomain(d) && !isSharedPlatformDomain(d.hostname.toLowerCase())) && (d.status === undefined || d.status === 'active'))
          .map((d) => d.hostname.toLowerCase());
      }
      const hosts = app.link_hostnames ?? (app.link_subdomain ? appLinkHosts(app.link_subdomain) : undefined);
      release = [...(hosts ? [hosts.live] : []), ...customs];
      debug = hosts ? [hosts.test] : [];
    }
    // Never a shared domain, whatever the server sends.
    release = release.map((h) => h.toLowerCase()).filter((h) => !isSharedPlatformDomain(h) && !isTestHost(h));
    debug = debug.map((h) => h.toLowerCase()).filter((h) => !isSharedPlatformDomain(h));
    perPlatform[platform] = { live: release, test: debug[0] };
    ui.out(`${paint(ui, 'green', '✓')} ${LABEL[platform]} app links: ${release.join(', ') || 'none'}${debug[0] ? `; debug builds also ${debug[0]}` : ''}`);
  }
  // Custom domains: when there are several, the person can leave some out (release builds).
  const all = [...new Set(Object.values(perPlatform).flatMap((p) => p!.live))];
  const optional = all.filter((h) => !appSubdomainOf(h));
  if (optional.length > 1 && !opts.yes && ui.interactive) {
    const picks = await ui.choose('Custom link domains for this app (release builds):', optional, { multi: true, defaults: optional.map((_, i) => i) });
    const drop = new Set(optional.filter((_, i) => !picks.includes(i)));
    for (const p of Object.values(perPlatform)) p!.live = p!.live.filter((h) => !drop.has(h));
  }
  const links = [...new Set(Object.values(perPlatform).flatMap((p) => p!.live))];
  const test = Object.values(perPlatform).map((p) => p!.test).find(Boolean);
  return { code: links, links, test, perPlatform };
}

interface ManualNote {
  label: string;
  detail: string;
}

// ------------------------------------------------------------------------------------- setup

export async function runSetup(opts: Options, deps: Deps): Promise<number> {
  const { ui } = deps;
  const candidate = await chooseProject(opts, ui);
  const project = await loadProject(ui, candidate);
  const root = project.root;
  ui.out(`Found ${/^[AEIOU]/.test(PLATFORM_LABEL[candidate.platform]) || candidate.platform === 'ios' ? 'an' : 'a'} ${PLATFORM_LABEL[candidate.platform]} project${root !== path.resolve(opts.cwd) ? ` in ${rel(path.resolve(opts.cwd), root)}` : ''}.`);
  const manual: ManualNote[] = [];

  // Offline mode (S.6): the test key and domains come from flags.
  const offline = opts.sdkKey !== undefined;
  if (offline) {
    if (SDK_KEY_LIVE.test(opts.sdkKey!)) throw new Exit(EXIT.PROBLEMS, 'Use the test key; switch to live for release builds.');
    if (!SDK_KEY_TEST.test(opts.sdkKey!)) throw new Exit(EXIT.PROBLEMS, '--sdk-key must be a test SDK key (cg_sdk_test_…), from Dashboard › Apps › your app › SDK keys.');
    if (!opts.domains?.length) throw new Exit(EXIT.PROBLEMS, "Offline mode needs --domain <host>[,<host>] (your app's link subdomain and custom domains, e.g. yourapp.ciz.to,go.acme.com; on the Free plan yourapp.clk.ng).");
    const shared = opts.domains.filter(isSharedPlatformDomain);
    if (shared.length) {
      throw new Exit(
        EXIT.PROBLEMS,
        `${shared.join(', ')}: ${SHARED_DOMAIN_FIX}. Pass your app's link subdomain instead (Dashboard › Apps › your app, e.g. --domain yourapp.ciz.to, or yourapp.clk.ng on the Free plan), plus any custom domains.`
      );
    }
  }

  // Working tree (S.3 step 2).
  const tree = treeState(root);
  if (tree.isRepo && tree.dirty.length && !opts.dryRun) {
    ui.out(paint(ui, 'yellow', `! This project has ${tree.dirty.length} uncommitted change${tree.dirty.length > 1 ? 's' : ''}. Committing first makes the setup easy to review and undo.`));
    if (!opts.yes && !(await ui.confirm('Continue anyway?', false))) return EXIT.CANCELLED;
  }

  let online: OnlineResult | undefined;
  let codeDomains: string[];
  let linkDomains: string[];
  let perPlatform: ChosenDomains['perPlatform'] = {};
  let testDomain: string | undefined;
  let sdkKey: string;
  let sdkKeyIos: string | undefined;
  if (offline) {
    codeDomains = opts.domains!.filter((d) => !isTestHost(d));
    linkDomains = [...codeDomains];
    sdkKey = opts.sdkKey!;
    // Debug builds get the app's test subdomain: <sub>.ciz.to (or <sub>.clk.ng on Free) → <sub>.dev.ciz.to.
    const sub = codeDomains.map(appSubdomainOf).find((x): x is string => Boolean(x));
    testDomain = sub ? appLinkHosts(sub).test : opts.domains!.find((d) => d.endsWith(`.${TEST_LINK_DOMAIN}`));
    if (!testDomain) {
      manual.push({ label: 'Test links', detail: `No app link subdomain (yourapp.ciz.to, or yourapp.clk.ng on the Free plan) in --domain, so debug builds don't get a test domain. Add your app's link subdomain to --domain and run setup again, or add yourapp.${TEST_LINK_DOMAIN} to debug builds yourself.` });
    }
    manual.push({ label: 'Signing details', detail: 'Offline mode sends nothing to Clikgate: add the SHA-256 signing fingerprints (debug and Play App Signing) and the Apple Team ID to your apps in the dashboard.' });
  } else {
    const { clikgate, organization } = await connect(opts, deps, project);
    const apps = await pickApps(opts, deps, project, clikgate, manual);
    await sendSigningDetails(opts, deps, project, clikgate, apps, manual);
    const d = await chooseDomains(opts, deps, clikgate, apps, manual);
    codeDomains = d.code;
    linkDomains = d.links;
    perPlatform = d.perPlatform;
    testDomain = d.test;
    online = { clikgate, apps, organization };
    const androidKey = apps.android?.sdk_key_test;
    const iosKey = apps.ios?.sdk_key_test;
    sdkKey = androidKey ?? iosKey ?? 'cg_sdk_test_REPLACE_ME';
    sdkKeyIos = androidKey && iosKey && androidKey !== iosKey ? iosKey : undefined;
    if (!androidKey && !iosKey) manual.push({ label: 'SDK key', detail: 'No Clikgate app was chosen, so the start-up code has a placeholder key: replace cg_sdk_test_REPLACE_ME with your app\'s test SDK key.' });
    if (codeDomains.length === 0 && Object.keys(apps).length) manual.push({ label: 'Link domains', detail: "No app link domain yet: confirm your app's link subdomain in the dashboard (Apps › your app › Link subdomain), then run setup again." });
  }

  // Plan (S.3 steps 7–8, S.4).
  const plan = buildPlan({
    root,
    platform: candidate.platform,
    startup: { sdkKey, sdkKeyIos, liveDomains: codeDomains, testDomain },
    links: { live: linkDomains, test: testDomain, android: perPlatform.android, ios: perPlatform.ios },
    android: project.android,
    ios: project.ios,
    packageManager: detectPackageManager(root),
    appConfig: candidate.appConfig,
    expoIds:
      candidate.platform === 'expo'
        ? {
            androidPackage: project.expoMissing?.androidPackage && online?.apps.android?.package_name ? online.apps.android.package_name : undefined,
            iosBundleId: project.expoMissing?.iosBundleId && online?.apps.ios?.bundle_id ? online.apps.ios.bundle_id : undefined,
          }
        : undefined,
    install: opts.install,
  });
  for (const m of manual) plan.steps.push({ kind: 'manual', label: m.label, detail: m.detail });

  const reviewed = await reviewAndApply(opts, deps, plan, tree);
  if ('exit' in reviewed) return reviewed.exit;
  const applied = reviewed.applied;

  // Verify (S.3 step 10).
  ui.out('');
  ui.out('Checking the setup…');
  const reloaded = await loadProject(quietUI(ui), { ...candidate, nativeFolders: candidate.nativeFolders });
  const checks: Check[] = runLocalChecks({
    root,
    platform: candidate.platform,
    android: reloaded.android,
    ios: reloaded.ios,
    expectedLiveDomains: linkDomains,
    appConfig: candidate.appConfig,
  });
  const next: { message: string; doc_url: string | null }[] = [];
  if (online) {
    for (const [platform, app] of Object.entries(online.apps) as ['android' | 'ios', App][]) {
      try {
        const r = serverChecks({ id: app.id, platform }, await online.clikgate.setupCheck(app.id));
        checks.push(...r.checks);
        next.push(...r.next);
      } catch (e) {
        checks.push({ id: 'clikgate.setup_check', group: 'clikgate', status: 'warn', title: `Couldn't run Clikgate's setup check: ${(e as Error).message}` });
      }
    }
  }
  printChecks(ui, checks);
  if (online && opts.wait && ui.interactive && Object.keys(online.apps).length) {
    ui.out('');
    ui.out('Run your app on a device or emulator now.');
    ui.out('Waiting for the first event from your app… (up to 5 minutes, press Enter to skip)');
    const ac = new AbortController();
    const skip = ui.waitForEnter(ac.signal);
    const live = await waitForFirstEvent(
      online.clikgate,
      (Object.entries(online.apps) as ['android' | 'ios', App][]).map(([platform, a]) => ({ id: a.id, platform })),
      deps.liveWaitMs ?? 5 * 60_000,
      { sleep: deps.sleep, now: deps.now, skip }
    );
    ac.abort();
    printChecks(ui, [live]);
  }

  // Summary (S.3 step 11).
  printSummary(ui, plan, applied, checks, next, { sdkKey, root, online, testDomain, platform: project.candidate.platform });
  ui.out('');
  ui.out(paint(ui, 'bold', SUCCESS_LINE));
  return EXIT.OK;
}

/**
 * Shows the plan, then: --dry-run prints the diffs and stops (exit 0); otherwise it confirms (or --yes), backs up
 * outside git, and applies. Shared by app setup and the website command.
 */
export async function reviewAndApply(
  opts: Pick<Options, 'dryRun' | 'yes'>,
  deps: Deps,
  plan: Plan,
  tree: { isRepo: boolean }
): Promise<{ exit: number } | { applied?: ApplyResult }> {
  const { ui } = deps;
  const root = plan.root;
  ui.out('');
  renderPlan(ui, plan);
  const work = plan.steps.some((s) => s.kind === 'change' || s.kind === 'command');
  if (opts.dryRun) {
    ui.out('');
    renderDiffs(ui, plan);
    ui.out(paint(ui, 'dim', '--dry-run: nothing was changed.'));
    printManual(ui, plan);
    return { exit: EXIT.OK };
  }
  let applied: ApplyResult | undefined;
  if (work) {
    if (opts.yes) {
      ui.out('');
      renderDiffs(ui, plan);
    } else {
      if (!ui.interactive) {
        ui.out('');
        renderDiffs(ui, plan);
        ui.out('Not applied: run in a terminal to confirm, or pass --yes.');
        return { exit: EXIT.CANCELLED };
      }
      if (await ui.confirm('Show full diff?', true)) renderDiffs(ui, plan);
      if (!(await ui.confirm('Apply?', false))) {
        ui.out('Cancelled. Nothing was changed.');
        return { exit: EXIT.CANCELLED };
      }
    }
    // Backups (S.3 step 2) when there's no git history to undo with.
    let backupDir: string | undefined;
    const files = changes(plan).map((c) => c.file);
    if (!tree.isRepo && files.length) {
      backupDir = backupFiles(root, files);
      ui.out(`Backed up the files to ${rel(root, backupDir)}/`);
    }
    applied = await applyPlan(ui, plan, { yes: opts.yes }, deps.apply);
    if (!applied.ok) {
      ui.err(paint(ui, 'red', `✗ ${applied.failure}`));
      for (const l of undoInstructions(applied, tree, backupDir, root)) ui.err(l);
      return { exit: EXIT.PROBLEMS };
    }
    ui.out(paint(ui, 'green', `✓ Applied ${applied.written.length + applied.created.length} file change${applied.written.length + applied.created.length === 1 ? '' : 's'}`));
  } else {
    ui.out(paint(ui, 'green', '✓ Everything is already set up.'));
  }

  return { applied };
}

function quietUI(ui: UI): UI {
  return { ...ui, out: () => undefined, choose: async (_q, _o, opts) => opts?.defaults ?? [0], confirm: ui.confirm.bind(ui), ask: ui.ask.bind(ui), waitForEnter: ui.waitForEnter.bind(ui), err: ui.err.bind(ui), debug: ui.debug.bind(ui), interactive: false, color: ui.color, verbose: ui.verbose };
}

export function printChecks(ui: UI, checks: Check[]): void {
  for (const c of checks) {
    const mark = c.status === 'pass' ? paint(ui, 'green', '✓') : c.status === 'fail' ? paint(ui, 'red', '✗') : c.status === 'warn' ? paint(ui, 'yellow', '!') : paint(ui, 'dim', '-');
    ui.out(`  ${mark} ${c.title}${c.detail ? paint(ui, 'dim', `  (${c.detail})`) : ''}`);
    if (c.fix && c.status !== 'pass') ui.out(`      ${c.fix}`);
  }
}

function printManual(ui: UI, plan: Plan): void {
  const manual = plan.steps.filter((s): s is Extract<Plan['steps'][number], { kind: 'manual' }> => s.kind === 'manual');
  if (!manual.length) return;
  ui.out('');
  ui.out(paint(ui, 'bold', 'Manual steps:'));
  for (const m of manual) {
    ui.out(`  ! ${m.label}: ${m.detail}`);
    if (m.snippet) for (const l of m.snippet.split('\n')) ui.out(`      ${l}`);
  }
}

function keyLocation(root: string, plan: Plan, sdkKey: string): string | undefined {
  for (const s of plan.steps) {
    if (s.kind !== 'change' || !s.after.includes(sdkKey)) continue;
    const line = s.after.split('\n').findIndex((l) => l.includes(sdkKey));
    return `${s.file}:${line + 1}`;
  }
  // Already set up: look in the usual files.
  for (const f of ['lib/main.dart', 'App.tsx', 'App.js', 'app/_layout.tsx', 'src/app/_layout.tsx']) {
    const p = path.join(root, f);
    if (exists(p)) {
      const i = read(p).split('\n').findIndex((l) => l.includes(sdkKey));
      if (i >= 0) return `${f}:${i + 1}`;
    }
  }
  return undefined;
}

function printSummary(
  ui: UI,
  plan: Plan,
  applied: { written: string[]; created: string[]; commandsRun: string[]; commandsSkipped: string[] } | undefined,
  checks: Check[],
  next: { message: string; doc_url: string | null }[],
  ctx: { sdkKey: string; root: string; online?: OnlineResult; testDomain?: string; platform: Platform }
): void {
  ui.out('');
  ui.out(paint(ui, 'bold', 'Summary'));
  const done = plan.steps.filter((s) => s.kind === 'done');
  if (applied) {
    for (const f of applied.written) ui.out(`  ${paint(ui, 'green', '✓')} changed ${f}`);
    for (const f of applied.created) ui.out(`  ${paint(ui, 'green', '✓')} created ${f}`);
    for (const c of applied.commandsRun) ui.out(`  ${paint(ui, 'green', '✓')} ran ${c}`);
    for (const c of applied.commandsSkipped) ui.out(`  ${paint(ui, 'yellow', '-')} skipped ${c} (run it yourself)`);
  }
  if (done.length) ui.out(`  ${paint(ui, 'green', '✓')} ${done.length} step${done.length > 1 ? 's were' : ' was'} already set up`);
  printManual(ui, plan);
  const failing = checks.filter((c) => c.status === 'fail');
  if (failing.length) {
    ui.out('');
    ui.out(paint(ui, 'bold', 'Still to fix:'));
    for (const c of failing) ui.out(`  ✗ ${c.title}${c.fix ? ` — ${c.fix}` : ''}`);
  }
  if (plan.reminders.length) {
    ui.out('');
    ui.out(paint(ui, 'bold', 'Reminders:'));
    for (const r of plan.reminders) ui.out(`  • ${r}`);
  }
  ui.out('');
  ui.out(paint(ui, 'bold', 'Next steps:'));
  ui.out(`  1. Create a link: ${DASHBOARD_URL}/links/new (test links use ${ctx.testDomain ?? `your app's <link_subdomain>.${TEST_LINK_DOMAIN}`} and open debug builds).`);
  const loc = keyLocation(ctx.root, plan, ctx.sdkKey);
  ui.out(
    `  2. Go live: for release builds, replace the test key (cg_sdk_test_…)${loc ? ` at ${loc}` : ''} with your live SDK key from ${DASHBOARD_URL}/apps (SDK keys). The setup command never handles live keys.`
  );
  ui.out(`  3. Send goals with one call: ${GOAL_SNIPPET[ctx.platform]} (a Payment goal waits until your payment provider or server confirms it).`);
  for (const n of next) ui.out(`  • ${n.message}${n.doc_url ? ` (${n.doc_url})` : ''}`);
}

export function describeError(e: unknown): { code: number; message: string } {
  if (e instanceof Exit) return { code: e.code, message: e.message };
  if (e instanceof ApiError) {
    if (e.status === 401) return { code: EXIT.SIGN_IN_FAILED, message: 'Clikgate rejected the sign-in (it may have expired or been revoked). Run the command again.' };
    if (e.code === 'cli_scope') return { code: EXIT.PROBLEMS, message: `This needs the dashboard: ${DASHBOARD_URL} (the setup command's sign-in can't do it).` };
    return { code: EXIT.PROBLEMS, message: `Clikgate API error (${e.code}): ${e.message}${e.requestId ? ` [request ${e.requestId}]` : ''}` };
  }
  if (e instanceof NetworkError) return { code: EXIT.PROBLEMS, message: e.message };
  return { code: EXIT.PROBLEMS, message: (e as Error)?.message ?? String(e) };
}

export { connect, pickApps, printManual, PLATFORM_LABEL };
