/**
 * The two app details that otherwise leave a warning after setup:
 *  - the URI scheme (`<scheme>://`), which the link page's "Open in app" button uses when Universal Links / App
 *    Links don't open the app. It's picked (or found in the project), written into the native files by the plan,
 *    and saved on the Clikgate apps after the files are written;
 *  - the iOS App Store ID, looked up from the bundle ID in Apple's public App Store directory (iTunes Search API).
 */
import * as fs from 'node:fs';
import * as path from 'node:path';
import type { App, Clikgate } from './api/clikgate';
import type { Fetch } from './api/client';
import { customSchemes } from './edit/androidManifest';
import { expoRoot, parseJsonc } from './edit/json';
import { urlSchemes } from './edit/plistEdit';
import type { Project } from './project/load';
import { paint, type UI } from './ui';

/** As clikgate_api's `uri_scheme` pattern: lowercase, starts with a letter, at most 31 characters. */
export const URI_SCHEME_PATTERN = /^[a-z][a-z0-9+.-]{0,30}$/;

/** Schemes other SDKs register (Facebook, Google sign-in, Microsoft, Twitter, Pinterest, TikTok, Expo dev tools…). */
export function isThirdPartyScheme(s: string): boolean {
  const v = s.toLowerCase();
  return (
    /^fb\d+/.test(v) ||
    v.startsWith('com.googleusercontent.') ||
    v.startsWith('msauth') ||
    v.startsWith('twitterkit-') ||
    v.startsWith('pdk') ||
    v.startsWith('tiktok') ||
    v.startsWith('exp+') ||
    v === 'exp' ||
    v.includes('$(') ||
    v.includes('${')
  );
}

function read(file: string): string | null {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch {
    return null;
  }
}

/** Custom schemes the project already registers (Info.plist, AndroidManifest, Expo app.json), own ones first. */
export function projectSchemes(project: Project): string[] {
  const found: string[] = [];
  const add = (s: string) => {
    const v = s.trim();
    if (v && !isThirdPartyScheme(v) && !found.includes(v)) found.push(v);
  };
  const cfg = project.candidate.appConfig;
  if (cfg && cfg.endsWith('.json')) {
    const text = read(cfg);
    if (text) {
      try {
        const scheme = expoRoot(parseJsonc(text))?.scheme;
        for (const s of Array.isArray(scheme) ? scheme : [scheme]) if (typeof s === 'string') add(s);
      } catch {
        /* not our file to judge */
      }
    }
  }
  if (project.ios) {
    for (const c of project.ios.configs) {
      if (!c.infoPlist) continue;
      const text = read(path.join(project.ios.srcRoot, c.infoPlist));
      if (!text) continue;
      try {
        urlSchemes(text).forEach(add);
      } catch {
        /* unreadable plist: the plan reports it */
      }
    }
  }
  if (project.android) {
    const text = read(project.android.mainManifest);
    if (text) {
      try {
        customSchemes(text).forEach(add);
      } catch {
        /* the plan reports it */
      }
    }
  }
  return found;
}

/** A scheme from the app's link subdomain (`tango-fuel-lite-3` → `tangofuellite3`), else from the project name. */
export function suggestScheme(apps: Partial<Record<'android' | 'ios', App>>, projectName: string): string | undefined {
  const from = [apps.android?.link_subdomain, apps.ios?.link_subdomain, apps.android?.name, apps.ios?.name, projectName];
  for (const f of from) {
    if (!f) continue;
    const v = f.toLowerCase().replace(/[^a-z0-9]/g, '').replace(/^[0-9]+/, '').slice(0, 31);
    if (URI_SCHEME_PATTERN.test(v)) return v;
  }
  return undefined;
}

export interface SchemeChoice {
  scheme: string;
  /** Apps whose Clikgate `uri_scheme` must be set once the files are written. */
  update: App[];
}

/**
 * Picks the URI scheme: the one Clikgate already has, else one the project registers, else a suggestion. Asks
 * unless `yes`. Returns undefined when skipped (a manual note says what to do instead).
 */
export async function chooseUriScheme(
  ui: UI,
  yes: boolean,
  project: Project,
  apps: Partial<Record<'android' | 'ios', App>>,
  manual: { label: string; detail: string }[]
): Promise<SchemeChoice | undefined> {
  const list = Object.values(apps).filter((a): a is App => Boolean(a));
  if (!list.length) return undefined;
  const inClikgate = list.map((a) => a.uri_scheme).find((s): s is string => Boolean(s));
  const inProject = projectSchemes(project).find((s) => URI_SCHEME_PATTERN.test(s.toLowerCase()))?.toLowerCase();
  const suggestion = inClikgate ?? inProject ?? suggestScheme(apps, project.name);
  let scheme = suggestion;
  if (inClikgate) {
    ui.out(`${paint(ui, 'green', '✓')} URI scheme ${inClikgate}:// is set in Clikgate`);
  } else if (!yes) {
    ui.out('A URI scheme lets the link page offer "Open in app" when a link doesn\'t open your app by itself.');
    for (;;) {
      const answer = (await ui.ask(`URI scheme${scheme ? ` [${scheme}]` : ''} (Enter to accept, a name, or "skip"):`)).trim().toLowerCase().replace(/:\/\/$/, '');
      if (answer === 'skip') {
        scheme = undefined;
        break;
      }
      if (!answer && scheme) break;
      if (URI_SCHEME_PATTERN.test(answer)) {
        scheme = answer;
        break;
      }
      ui.out(paint(ui, 'yellow', '  Use lowercase letters, digits, "+", "." or "-", starting with a letter (at most 31), for example yourapp.'));
    }
  }
  if (!scheme) {
    manual.push({
      label: 'URI scheme',
      detail: 'Skipped. To add it later, run setup again, or register a scheme in Xcode (target › Info › URL Types) and AndroidManifest.xml, then set it in the dashboard: Apps › your app › Identifiers and store links › URI scheme.',
    });
    return undefined;
  }
  return { scheme, update: list.filter((a) => a.uri_scheme !== scheme) };
}

/** Sets `uri_scheme` on the apps (after the files are written, so "Open in app" never points at a missing scheme). */
export async function saveUriScheme(ui: UI, clikgate: Clikgate, choice: SchemeChoice): Promise<void> {
  for (const app of choice.update) {
    try {
      await clikgate.updateApp(app.id, { uri_scheme: choice.scheme });
      ui.out(`${paint(ui, 'green', '✓')} URI scheme ${choice.scheme}:// saved on the ${app.platform === 'ios' ? 'iOS' : 'Android'} app in Clikgate`);
    } catch (e) {
      ui.out(paint(ui, 'yellow', `! Couldn't save the URI scheme on the ${app.platform} app (${(e as Error).message}). Set it in the dashboard: Apps › your app › Identifiers and store links › URI scheme.`));
    }
  }
}

export interface StoreListing {
  id: string;
  name: string;
  url: string;
}

/** Apple's public lookup by bundle ID (no key needed); a few storefronts, since an app may not be sold in the US. */
export async function lookupAppStore(fetchImpl: Fetch, bundleId: string): Promise<StoreListing | undefined> {
  for (const country of ['us', 'ng', 'gb']) {
    try {
      const r = await fetchImpl(`https://itunes.apple.com/lookup?bundleId=${encodeURIComponent(bundleId)}&country=${country}`, {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(10_000),
      });
      if (!r.ok) continue;
      const j = (await r.json()) as { resultCount?: number; results?: { trackId?: number; trackName?: string; trackViewUrl?: string; bundleId?: string }[] };
      const hit = (j.results ?? []).find((x) => x.trackId && x.bundleId === bundleId);
      if (hit?.trackId) {
        return { id: String(hit.trackId), name: hit.trackName ?? bundleId, url: `https://apps.apple.com/app/id${hit.trackId}` };
      }
    } catch {
      /* offline or blocked: treat as not found */
    }
  }
  return undefined;
}

/**
 * Fills the iOS app's App Store ID when it's missing: finds the published app by bundle ID and saves it after
 * confirming. Sends `store_url` too (the setup token may always set it), so the store redirect works either way.
 */
export async function fillAppStoreId(
  ui: UI,
  yes: boolean,
  dryRun: boolean,
  fetchImpl: Fetch,
  clikgate: Clikgate,
  app: App | undefined,
  manual: { label: string; detail: string }[]
): Promise<App | undefined> {
  if (!app || app.ios_app_store_id || app.store_url) return app;
  const bundle = app.bundle_id;
  const later = {
    label: 'App Store ID',
    detail:
      'Your iOS app isn\'t on the App Store yet, so visitors without the app see the link\'s web page. Once it\'s published, run setup again (it finds the ID by itself), or add it in the dashboard: Apps › your iOS app › Identifiers and store links › App Store ID.',
  };
  if (!bundle) {
    manual.push(later);
    return app;
  }
  const found = await lookupAppStore(fetchImpl, bundle);
  if (!found) {
    manual.push(later);
    return app;
  }
  const ok = yes || (await ui.confirm(`Found "${found.name}" on the App Store (id${found.id}). Send visitors without the app there?`, true));
  if (!ok) {
    manual.push({ label: 'App Store ID', detail: `Not set. Add it in the dashboard when you're ready: Apps › your iOS app › Identifiers and store links › App Store ID (${found.id}).` });
    return app;
  }
  if (dryRun) {
    ui.out(`  (dry run) would save App Store ID ${found.id}`);
    return app;
  }
  try {
    const updated = await clikgate.updateApp(app.id, { ios_app_store_id: found.id, store_url: found.url });
    ui.out(`${paint(ui, 'green', '✓')} App Store ID ${found.id} saved: visitors without the app go to "${found.name}" on the App Store`);
    return updated;
  } catch (e) {
    manual.push({ label: 'App Store ID', detail: `Couldn't save it (${(e as Error).message}). Add it in the dashboard: Apps › your iOS app › Identifiers and store links › App Store ID (${found.id}).` });
    return app;
  }
}
