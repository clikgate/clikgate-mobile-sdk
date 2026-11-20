/**
 * The app's download link, `https://<link subdomain>/download`: phones open the app when it's installed and go to
 * the App Store / Google Play when it isn't; computers go to the company website, or (without one) to a Clikgate
 * page with the store buttons. Setup asks for the website, then has Clikgate create the link once the files are
 * written, and prints it. It's an ordinary link: it can be edited in the dashboard (Links), and running setup again
 * never overwrites those edits.
 */
import type { App, Clikgate, DownloadLink } from './api/clikgate';
import { ApiError } from './api/client';
import { SHARED_PLATFORM_DOMAINS } from './constants';
import { paint, type UI } from './ui';

type Apps = Partial<Record<'android' | 'ios', App>>;
type Manual = { label: string; detail: string }[];

/** `acme.com` → `https://acme.com/`; undefined when it isn't a public https website. */
export function normaliseWebsite(input: string): string | undefined {
  const raw = input.trim();
  if (!raw) return undefined;
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(raw) ? raw : `https://${raw}`;
  let url: URL;
  try {
    url = new URL(withScheme);
  } catch {
    return undefined;
  }
  if (url.protocol !== 'https:' || url.username || url.password) return undefined;
  const host = url.hostname.toLowerCase();
  if (!host.includes('.') || host.endsWith('.') || /^[\d.]+$/.test(host) || host === 'localhost') return undefined;
  // A Clikgate link domain would send computers in a circle
  if (SHARED_PLATFORM_DOMAINS.some((d) => host === d || host.endsWith(`.${d}`))) return undefined;
  return url.toString();
}

export interface WebsiteChoice {
  url: string;
  /** Apps whose `website_url` must be saved. */
  update: App[];
}

/**
 * The website computer visitors go to: the one Clikgate already has, else asked (Enter skips). Undefined when
 * skipped, and the download link then shows computers a page with the store buttons.
 */
export async function chooseWebsite(ui: UI, yes: boolean, apps: Apps): Promise<WebsiteChoice | undefined> {
  const list = Object.values(apps).filter((a): a is App => Boolean(a));
  if (!list.length) return undefined;
  // An older Clikgate API has no `website_url` (and no download links): don't ask
  if (!list.some((a) => 'website_url' in a)) return undefined;
  const known = list.map((a) => a.website_url).find((u): u is string => Boolean(u));
  if (known) {
    ui.out(`${paint(ui, 'green', '✓')} Computers that open your download link go to ${known}`);
    return { url: known, update: list.filter((a) => a.website_url !== known) };
  }
  if (yes) return undefined;
  ui.out("Your app gets a download link: phones open the app, or the App Store / Google Play when it isn't installed.");
  for (;;) {
    const answer = (await ui.ask("Your company's website, for visitors on a computer (e.g. acme.com, Enter to skip):")).trim();
    if (!answer || answer.toLowerCase() === 'skip') {
      ui.out('  Skipped: computers will see a Clikgate page with your App Store and Google Play buttons.');
      return undefined;
    }
    const url = normaliseWebsite(answer);
    if (url) return { url, update: list };
    ui.out(paint(ui, 'yellow', '  Enter a public website address, for example acme.com or https://www.acme.com.'));
  }
}

export async function saveWebsite(ui: UI, clikgate: Clikgate, choice: WebsiteChoice, manual: Manual): Promise<void> {
  for (const app of choice.update) {
    try {
      await clikgate.updateApp(app.id, { website_url: choice.url });
      app.website_url = choice.url;
    } catch (e) {
      manual.push({
        label: 'Website',
        detail: `Couldn't save your website (${(e as Error).message}). Add it in the dashboard: Apps › your app › Identifiers and store links › Website.`,
      });
      return;
    }
  }
  if (choice.update.length) ui.out(`${paint(ui, 'green', '✓')} Website ${choice.url} saved for computer visitors`);
}

/** One call per link subdomain: Clikgate puts the iOS and Android apps that share it on the same link. */
export async function ensureDownloadLinks(ui: UI, clikgate: Clikgate, apps: Apps): Promise<DownloadLink[]> {
  const bySubdomain = new Map<string, App>();
  for (const app of Object.values(apps)) {
    if (app?.link_subdomain && app.link_subdomain_confirmed !== false && !bySubdomain.has(app.link_subdomain)) {
      bySubdomain.set(app.link_subdomain, app);
    }
  }
  const links: DownloadLink[] = [];
  for (const app of bySubdomain.values()) {
    try {
      links.push(await clikgate.ensureDownloadLink(app.id));
    } catch (e) {
      // An older Clikgate API has no download links: say nothing
      if (e instanceof ApiError && (([404, 405].includes(e.status) && e.code !== 'link_subdomain_not_confirmed') || e.code === 'cli_scope')) continue;
      ui.out(
        paint(ui, 'yellow', `! Couldn't create your download link (${(e as Error).message}). Run setup again, or create a link in the dashboard with "When the app isn't installed: Go to the app store".`)
      );
    }
  }
  return links;
}

/** The summary lines for each download link. */
export function describeDownloadLink(ui: UI, link: DownloadLink, has: { ios: boolean; android: boolean }): string[] {
  const lines = [`  ${paint(ui, 'bold', link.url)}`];
  if (link.status && link.status !== 'active') {
    lines.push(`    It's ${link.status} in the dashboard, so it doesn't redirect. Turn it back on in Links if you want to use it.`);
    return lines;
  }
  const iosReady = has.ios && link.ios_store_ready !== false;
  const stores = [iosReady ? 'the App Store' : undefined, has.android ? 'Google Play' : undefined].filter(Boolean);
  lines.push(`    Phones open your app, or ${stores.length ? stores.join(' / ') : 'the store'} when it isn't installed.`);
  lines.push(
    link.computer_destination === 'store_page' || !link.destination_url
      ? '    Computers see a page with your store buttons (add your website in the dashboard to send them there instead).'
      : `    Computers go to ${link.destination_url}.`
  );
  lines.push(`    Change it any time in the dashboard (Links): setup won't undo your edits.`);
  if (has.ios && !iosReady) {
    lines.push("    Until your iOS app is on the App Store, iPhones without it go where computers go. Run setup again after it's published.");
  }
  return lines;
}
