import * as fs from 'node:fs';
import * as path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { ApiClient, NetworkError } from '../src/api/client';
import { addSchemeFilter, customSchemes } from '../src/edit/androidManifest';
import { addUrlScheme, readPlist, urlSchemes } from '../src/edit/plistEdit';
import { main } from '../src/index';
import { isThirdPartyScheme, suggestScheme, URI_SCHEME_PATTERN } from '../src/storeAndScheme';
import { ScriptedUI, copyFixture } from './helpers';
import { startMockServer, type MockServer } from './mockServer';
import { appStoreListings } from './setup';

const FP = 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';

describe('API client retries', () => {
  const ok = () => new Response('{"ok":true}', { status: 200, headers: { 'Content-Type': 'application/json' } });

  it('retries a dropped connection with the same Idempotency-Key, then succeeds', async () => {
    const keys: (string | undefined)[] = [];
    let calls = 0;
    const fetchImpl = (async (_u: string, init: RequestInit) => {
      keys.push((init.headers as Record<string, string>)['Idempotency-Key']);
      if (++calls < 3) throw Object.assign(new Error('ECONNRESET: The socket connection was closed unexpectedly'), { code: 'ECONNRESET' });
      return ok();
    }) as unknown as typeof fetch;
    const waits: number[] = [];
    const api = new ApiClient({ baseUrl: 'https://api.example', fetch: fetchImpl, sleep: async (ms) => void waits.push(ms) });
    expect(await api.post('/v1/cli/device-codes', {})).toEqual({ ok: true });
    expect(calls).toBe(3);
    expect(waits).toEqual([1000, 3000]);
    expect(new Set(keys).size).toBe(1);
    expect(keys[0]).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("retries Cloudflare's 530 and 502, but not a 404", async () => {
    const statuses = [530, 502, 200];
    const fetchImpl = (async () => new Response(statuses[0] === 200 ? '{}' : 'down', { status: statuses.shift()! })) as unknown as typeof fetch;
    await new ApiClient({ baseUrl: 'https://api.example', fetch: fetchImpl, sleep: async () => undefined }).get('/v1/apps');
    expect(statuses).toEqual([]);
    let n = 0;
    const notFound = (async () => (n++, new Response('{"error":{"code":"not_found","message":"No such app"}}', { status: 404 }))) as unknown as typeof fetch;
    await expect(new ApiClient({ baseUrl: 'https://api.example', fetch: notFound, sleep: async () => undefined }).get('/v1/apps/x')).rejects.toThrow('No such app');
    expect(n).toBe(1);
  });

  it('gives up after three attempts with a clear message, and GETs carry no Idempotency-Key', async () => {
    const seen: RequestInit[] = [];
    const fetchImpl = (async (_u: string, init: RequestInit) => {
      seen.push(init);
      throw new Error('ECONNRESET');
    }) as unknown as typeof fetch;
    const err = (await new ApiClient({ baseUrl: 'https://api.example', fetch: fetchImpl, sleep: async () => undefined }).get('/v1/apps').catch((e: unknown) => e)) as Error;
    expect(err).toBeInstanceOf(NetworkError);
    expect(err.message).toBe("Can't reach https://api.example (ECONNRESET). Check your connection and try again.");
    expect(seen).toHaveLength(3);
    expect((seen[0].headers as Record<string, string>)['Idempotency-Key']).toBeUndefined();
  });
});

describe('URI scheme in Info.plist', () => {
  const plist = (body: string) =>
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>CFBundleName</key>\n\t<string>Tango</string>${body}\n</dict>\n</plist>\n`;

  it('adds CFBundleURLTypes when there is none, in the file\'s tab indentation', () => {
    const out = addUrlScheme(plist(''), 'tangofuel', 'com.example.tango');
    expect(urlSchemes(out)).toEqual(['tangofuel']);
    expect((readPlist(out).CFBundleURLTypes as { CFBundleURLName: string }[])[0].CFBundleURLName).toBe('com.example.tango');
    expect(out).toContain('\t<key>CFBundleURLTypes</key>\n\t<array>\n\t\t<dict>\n\t\t\t<key>CFBundleURLName</key>');
  });

  it('appends to existing URL types (keeps Google sign-in) and is unchanged when the scheme is there', () => {
    const google = '\n\t<key>CFBundleURLTypes</key>\n\t<array>\n\t\t<dict>\n\t\t\t<key>CFBundleURLSchemes</key>\n\t\t\t<array>\n\t\t\t\t<string>com.googleusercontent.apps.123</string>\n\t\t\t</array>\n\t\t</dict>\n\t</array>';
    const out = addUrlScheme(plist(google), 'tangofuel', 'com.example.tango');
    expect(urlSchemes(out)).toEqual(['com.googleusercontent.apps.123', 'tangofuel']);
    expect(addUrlScheme(out, 'tangofuel', 'x')).toBe(out);
    expect(addUrlScheme(out, 'TangoFuel', 'x')).toBe(out);
  });
});

describe('URI scheme in AndroidManifest', () => {
  const manifest = `<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application>
        <activity android:name=".MainActivity" android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
`;

  it('adds a VIEW/BROWSABLE filter (no autoVerify) to the activity, once', () => {
    const edit = addSchemeFilter(manifest, '.MainActivity', 'tangofuel');
    expect(edit.changed).toBe(true);
    expect(customSchemes(edit.text)).toEqual(['tangofuel']);
    expect(edit.text).toContain('            <intent-filter>\n                <action android:name="android.intent.action.VIEW" />');
    expect(edit.text).toContain('<data android:scheme="tangofuel" />');
    expect(edit.text.match(/autoVerify/g)).toBeNull();
    expect(addSchemeFilter(edit.text, '.MainActivity', 'tangofuel').changed).toBe(false);
  });

  it('ignores https filters when listing custom schemes', () => {
    const withHttps = manifest.replace('</activity>', '    <intent-filter android:autoVerify="true"><action android:name="android.intent.action.VIEW" /><data android:scheme="https" /><data android:host="a.ciz.to" /></intent-filter>\n        </activity>');
    expect(customSchemes(withHttps)).toEqual([]);
  });
});

describe('scheme rules', () => {
  it('suggests a valid scheme from the link subdomain, then the name', () => {
    expect(suggestScheme({ android: { id: 'a', platform: 'android', name: 'X', link_subdomain: 'tango-fuel-lite-3' } }, 'p')).toBe('tangofuellite3');
    expect(suggestScheme({ ios: { id: 'i', platform: 'ios', name: '9 Lives App' } }, 'p')).toBe('livesapp');
    expect(suggestScheme({}, 'flutter_app')).toBe('flutterapp');
    expect(URI_SCHEME_PATTERN.test('tango-fuel')).toBe(true);
    expect(URI_SCHEME_PATTERN.test('Tango')).toBe(false);
  });

  it("never treats other SDKs' schemes as the app's", () => {
    for (const s of ['fb123456', 'com.googleusercontent.apps.1-abc', 'msauth.com.acme', 'exp+myapp', '$(PRODUCT_BUNDLE_IDENTIFIER)']) expect(isThirdPartyScheme(s)).toBe(true);
    expect(isThirdPartyScheme('tangofuel')).toBe(false);
  });
});

describe('setup fills the URI scheme and the App Store ID', () => {
  let server: MockServer | undefined;
  afterEach(async () => {
    await server?.close();
    server = undefined;
    appStoreListings.clear();
  });

  it('writes the scheme to both platforms, saves it on both apps, and saves the App Store link', async () => {
    server = await startMockServer();
    appStoreListings.set('com.example.flutterApp', { trackId: 1234567890, trackName: 'Flutter App' });
    const dir = copyFixture('flutter');
    const ui = new ScriptedUI([
      [/Create "flutter_app" \(Android/, true],
      [/Create "flutter_app" \(iOS/, true],
      [/Paste it now/, ''],
      [/Found "Flutter App" on the App Store \(id1234567890\)/, true],
      [/^URI scheme \[flutterapp\]/, ''],
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
    expect(code, ui.text).toBe(0);
    expect(urlSchemes(fs.readFileSync(path.join(dir, 'ios/Runner/Info.plist'), 'utf8'))).toContain('flutterapp');
    expect(customSchemes(fs.readFileSync(path.join(dir, 'android/app/src/main/AndroidManifest.xml'), 'utf8'))).toEqual(['flutterapp']);
    const patches = server.requests.filter((r) => r.method === 'PATCH' && r.path.startsWith('/v1/apps/')).map((r) => [r.path, r.body]);
    expect(patches).toContainEqual(['/v1/apps/app_2', { ios_app_store_id: '1234567890', store_url: 'https://apps.apple.com/app/id1234567890' }]);
    expect(patches).toContainEqual(['/v1/apps/app_1', { uri_scheme: 'flutterapp' }]);
    expect(patches).toContainEqual(['/v1/apps/app_2', { uri_scheme: 'flutterapp' }]);
    // The scheme is saved only after the files are written
    const firstSchemePatch = server.requests.findIndex((r) => (r.body as { uri_scheme?: string } | undefined)?.uri_scheme);
    const setupCheck = server.requests.findIndex((r) => r.path.startsWith('/v1/cli/setup-check'));
    expect(firstSchemePatch).toBeGreaterThan(-1);
    expect(firstSchemePatch).toBeLessThan(setupCheck);
    expect(ui.text).toContain('✓ App Store ID 1234567890 saved: visitors without the app go to "Flutter App" on the App Store');
    expect(ui.text).toContain('✓ URI scheme flutterapp:// saved on the iOS app in Clikgate');
  });

  it('an app not on the App Store leaves a clear manual step; "skip" leaves the scheme out', async () => {
    server = await startMockServer();
    const dir = copyFixture('flutter');
    const ui = new ScriptedUI([
      [/Create "flutter_app" \(Android/, true],
      [/Create "flutter_app" \(iOS/, true],
      [/Paste it now/, ''],
      [/^URI scheme/, 'skip'],
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
    expect(code, ui.text).toBe(0);
    expect(ui.text).toContain("Your iOS app isn't on the App Store yet");
    expect(ui.text).toContain('Apps › your app › Identifiers and store links › URI scheme');
    expect(urlSchemes(fs.readFileSync(path.join(dir, 'ios/Runner/Info.plist'), 'utf8'))).not.toContain('flutterapp');
    expect(server.requests.some((r) => (r.body as { uri_scheme?: string } | undefined)?.uri_scheme)).toBe(false);
  });
});
