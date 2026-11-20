import { afterEach, describe, expect, it } from 'vitest';
import type { App } from '../src/api/clikgate';
import { chooseWebsite, describeDownloadLink, normaliseWebsite } from '../src/downloadLink';
import { main } from '../src/index';
import { ScriptedUI, copyFixture } from './helpers';
import { startMockServer, type MockOptions, type MockServer } from './mockServer';
import { appStoreListings } from './setup';

const FP = 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';

describe('normaliseWebsite', () => {
  it('adds https and keeps paths', () => {
    expect(normaliseWebsite('acme.com')).toBe('https://acme.com/');
    expect(normaliseWebsite(' https://www.acme.com/app ')).toBe('https://www.acme.com/app');
  });
  it('rejects what computers could not open, or that loops back to Clikgate', () => {
    for (const bad of ['', 'http://acme.com', 'acme', 'localhost', '10.0.0.1', 'ftp://acme.com', 'tango.ciz.to', 'https://x.dev.ciz.to', 'https://u:p@acme.com']) {
      expect(normaliseWebsite(bad), bad).toBeUndefined();
    }
  });
});

describe('chooseWebsite', () => {
  const app = (id: string, platform: 'ios' | 'android', website_url: string | null = null): App => ({ id, platform, name: 'A', website_url });
  it('asks again after an invalid answer', async () => {
    const answers = ['not a site', 'acme.com'];
    const ui = new ScriptedUI();
    ui.ask = async (q: string) => (ui.asked.push(q), answers.shift() ?? '');
    const choice = await chooseWebsite(ui, false, { android: app('a', 'android'), ios: app('i', 'ios') });
    expect(choice?.url).toBe('https://acme.com/');
    expect(choice?.update.map((a) => a.id)).toEqual(['a', 'i']);
    expect(ui.asked).toHaveLength(2);
    expect(ui.text).toContain('Enter a public website address');
  });
  it("uses the website Clikgate already has without asking, and fills it on the other app", async () => {
    const ui = new ScriptedUI();
    const choice = await chooseWebsite(ui, false, { android: app('a', 'android', 'https://acme.com/'), ios: app('i', 'ios') });
    expect(ui.asked).toEqual([]);
    expect(choice?.update.map((a) => a.id)).toEqual(['i']);
  });
  it('--yes never asks', async () => {
    const ui = new ScriptedUI();
    expect(await chooseWebsite(ui, true, { android: app('a', 'android') })).toBeUndefined();
    expect(ui.asked).toEqual([]);
  });
});

describe('describeDownloadLink', () => {
  const ui = new ScriptedUI();
  it('warns that iPhones wait for the App Store listing', () => {
    const text = describeDownloadLink(ui, { url: 'https://t.ciz.to/download', computer_destination: 'store_page', ios_store_ready: false }, { ios: true, android: true }).join('\n');
    expect(text).toContain('or Google Play when');
    expect(text).toContain('Until your iOS app is on the App Store');
    expect(text).toContain('page with your store buttons');
  });
  it("doesn't mention iOS for an Android-only app, and says when the link is off", () => {
    const text = describeDownloadLink(ui, { url: 'https://t.ciz.to/download', computer_destination: 'website', destination_url: 'https://acme.com/', ios_store_ready: false }, { ios: false, android: true }).join('\n');
    expect(text).not.toContain('iOS');
    expect(text).toContain('Computers go to https://acme.com/');
    const off = describeDownloadLink(ui, { url: 'https://t.ciz.to/download', status: 'archived' }, { ios: true, android: true }).join('\n');
    expect(off).toContain("It's archived in the dashboard");
  });
});

describe('setup creates the download link', () => {
  let server: MockServer | undefined;
  afterEach(async () => {
    await server?.close();
    server = undefined;
    appStoreListings.clear();
  });

  async function run(rules: [RegExp, boolean | string][], opts: MockOptions = {}) {
    server = await startMockServer(opts);
    const dir = copyFixture('flutter');
    const ui = new ScriptedUI([
      [/Create "flutter_app" \(Android/, true],
      [/Create "flutter_app" \(iOS/, true],
      [/Paste it now/, ''],
      [/^URI scheme/, ''],
      ...rules,
      [/Show full diff/, false],
      [/^Apply\?/, true],
    ]);
    let t = 0;
    const code = await main(['--cwd', dir, '--api-url', server.url, '--no-install', '--no-wait'], {
      ui,
      sleep: async (ms) => void (t += ms),
      now: () => t,
      openBrowser: () => undefined,
      debugFingerprint: () => FP,
    });
    return { code, ui, server };
  }

  it('asks for the website, saves it on both apps, and prints one link for the pair', async () => {
    appStoreListings.set('com.example.flutterApp', { trackId: 1234567890, trackName: 'Flutter App' });
    const { code, ui, server } = await run([
      [/Found "Flutter App"/, true],
      [/company's website/, 'acme.com'],
    ]);
    expect(code, ui.text).toBe(0);
    const patches = server.requests.filter((r) => r.method === 'PATCH').map((r) => [r.path, r.body]);
    expect(patches).toContainEqual(['/v1/apps/app_1', { website_url: 'https://acme.com/' }]);
    expect(patches).toContainEqual(['/v1/apps/app_2', { website_url: 'https://acme.com/' }]);
    const posts = server.requests.filter((r) => r.path.endsWith('/download-link'));
    expect(posts).toHaveLength(1);
    // Created after the files are written
    const apply = server.requests.findIndex((r) => (r.body as { uri_scheme?: string } | undefined)?.uri_scheme);
    expect(server.requests.indexOf(posts[0])).toBeGreaterThan(apply);
    expect(ui.text).toContain('Your download link (share it anywhere):');
    expect(ui.text).toMatch(/https:\/\/[a-z0-9-]+\.ciz\.to\/download/);
    expect(ui.text).toContain('Phones open your app, or the App Store / Google Play');
    expect(ui.text).toContain('Computers go to https://acme.com/');
    expect(ui.text).not.toContain('Until your iOS app');
  });

  it('skipping the website gives computers the store page; an iOS app not yet published is explained', async () => {
    const { code, ui, server } = await run([[/company's website/, '']]);
    expect(code, ui.text).toBe(0);
    expect(server.requests.some((r) => (r.body as { website_url?: string } | undefined)?.website_url)).toBe(false);
    expect(ui.text).toContain('Skipped: computers will see a Clikgate page');
    expect(ui.text).toContain('Computers see a page with your store buttons');
    expect(ui.text).toContain('Until your iOS app is on the App Store');
  });

  it('an older API without download links says nothing about them', async () => {
    const { code, ui } = await run([[/company's website/, 'acme.com']], { downloadLinks: false });
    expect(code, ui.text).toBe(0);
    expect(ui.asked.some((q) => /company's website/.test(q))).toBe(false);
    expect(ui.text).not.toContain('download link');
    expect(ui.text).not.toContain("Couldn't create");
  });

  it("--dry-run neither saves the website nor creates the link", async () => {
    server = await startMockServer();
    const dir = copyFixture('flutter');
    const ui = new ScriptedUI([[/company's website/, 'acme.com']]);
    const code = await main(['--cwd', dir, '--api-url', server.url, '--no-install', '--no-wait', '--dry-run', '--yes'], {
      ui,
      sleep: async () => undefined,
      now: () => 0,
      openBrowser: () => undefined,
      debugFingerprint: () => FP,
    });
    expect(code, ui.text).toBe(0);
    expect(server.requests.some((r) => r.path.endsWith('/download-link'))).toBe(false);
    expect(server.requests.some((r) => (r.body as { website_url?: string } | undefined)?.website_url)).toBe(false);
  });
});
