import * as fs from 'node:fs';
import * as path from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { ApiClient } from '../src/api/client';
import { signIn, SignInError } from '../src/api/device';
import { verifiedHosts } from '../src/edit/androidManifest';
import { applinksHosts } from '../src/edit/plistEdit';
import { main } from '../src/index';
import { ScriptedUI, copyFixture } from './helpers';
import { MOCK_TOKEN, startMockServer, type MockServer } from './mockServer';

const FP = 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99';
const PLAY = '11:22:33:44:55:66:77:88:99:00:AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:00:AA:BB:CC:DD:EE:FF';

let server: MockServer | undefined;
afterEach(async () => {
  await server?.close();
  server = undefined;
});

function fakeClock() {
  let t = 0;
  const sleeps: number[] = [];
  return {
    now: () => t,
    sleep: async (ms: number) => {
      sleeps.push(ms);
      t += ms;
    },
    sleeps,
  };
}

describe('device sign-in (RFC 8628) against the mock server', () => {
  it('polls at the interval, adds 5 s on slow_down, and returns the token', async () => {
    server = await startMockServer({ tokenSequence: ['authorization_pending', 'slow_down', 'authorization_pending'] });
    const clock = fakeClock();
    const lines: string[] = [];
    const opened: string[] = [];
    const s = await signIn(new ApiClient({ baseUrl: server.url }), 'flutter', { print: (l) => lines.push(l), sleep: clock.sleep, now: clock.now, openBrowser: (u) => opened.push(u) });
    expect(s.accessToken).toBe(MOCK_TOKEN);
    expect(s.organization.name).toBe('Acme');
    expect(clock.sleeps).toEqual([5000, 5000, 10000, 10000]);
    expect(lines.join('\n')).toBe(
      ['To connect this project to Clikgate, open:', '  https://app.clikgate.com/cli?code=BCDF-GHJK', 'and check that the code shown is BCDF-GHJK.', 'If your account uses two-factor sign-in, the page also asks for your authenticator code (or a recovery code).'].join('\n')
    );
    expect(opened).toEqual(['https://app.clikgate.com/cli?code=BCDF-GHJK']);
    const dc = server.requests.find((r) => r.path === '/v1/cli/device-codes')!;
    expect(Object.keys((dc.body as { client_info: object }).client_info).sort()).toEqual(['cli_version', 'hostname_hint', 'os', 'project_type']);
    expect(((dc.body as { client_info: { hostname_hint: string } }).client_info.hostname_hint).length).toBeLessThanOrEqual(32);
    expect(lines.join('\n')).not.toContain(MOCK_TOKEN);
  });

  it('accepts RFC-style 400 errors with the same codes', async () => {
    server = await startMockServer({ tokenSequence: ['authorization_pending', 'slow_down'], rfcStatuses: true });
    const clock = fakeClock();
    const s = await signIn(new ApiClient({ baseUrl: server.url }), 'ios', { print: () => undefined, sleep: clock.sleep, now: clock.now });
    expect(s.accessToken).toBe(MOCK_TOKEN);
  });

  it("uses the server's slow_down interval when it's larger", async () => {
    server = await startMockServer({ tokenSequence: ['slow_down'], slowDownStep: 25 });
    const clock = fakeClock();
    await signIn(new ApiClient({ baseUrl: server.url }), 'ios', { print: () => undefined, sleep: clock.sleep, now: clock.now });
    expect(clock.sleeps).toEqual([5000, 30000]);
  });

  it.each([
    ['access_denied', 'denied'],
    ['expired_token', 'expired'],
    ['invalid_device_code', 'failed'],
  ])('%s ends sign-in (%s)', async (code, reason) => {
    server = await startMockServer({ tokenSequence: ['authorization_pending', code] });
    const clock = fakeClock();
    const err = await signIn(new ApiClient({ baseUrl: server.url }), 'ios', { print: () => undefined, sleep: clock.sleep, now: clock.now }).catch((e) => e);
    expect(err).toBeInstanceOf(SignInError);
    expect((err as SignInError).reason).toBe(reason);
  });

  it('gives up when the code expires while pending', async () => {
    server = await startMockServer({ tokenSequence: Array(500).fill('authorization_pending') });
    const clock = fakeClock();
    const err = await signIn(new ApiClient({ baseUrl: server.url }), 'ios', { print: () => undefined, sleep: clock.sleep, now: clock.now }).catch((e) => e);
    expect((err as SignInError).reason).toBe('expired');
  });

  it('exits 3 when sign-in fails', async () => {
    server = await startMockServer({ tokenSequence: ['access_denied'] });
    const dir = copyFixture('flutter');
    const clock = fakeClock();
    const ui = new ScriptedUI();
    const code = await main(['--cwd', dir, '--api-url', server.url, '--yes', '--no-install'], { ui, sleep: clock.sleep, now: clock.now, openBrowser: () => undefined });
    expect(code).toBe(3);
    expect(ui.text).toContain('Sign-in was denied');
  });
});

describe('allow-list', () => {
  it('cli_scope reads "This needs the dashboard"', async () => {
    const { describeError } = await import('../src/setup');
    const { ApiError } = await import('../src/api/client');
    expect(describeError(new ApiError(403, 'cli_scope', 'Not allowed')).message).toBe(
      "This needs the dashboard: https://app.clikgate.com (the setup command's sign-in can't do it)."
    );
  });
});

describe('signed-in setup (Flutter fixture)', () => {
  it('creates both apps, sends signing details, writes the app subdomain (never a shared domain) and per-platform keys', async () => {
    server = await startMockServer();
    const dir = copyFixture('flutter');
    const clock = fakeClock();
    const ui = new ScriptedUI([
      [/Create "flutter_app" \(Android/, true],
      [/Create "flutter_app" \(iOS/, true],
      [/Paste it now/, PLAY],
      [/Show full diff/, false],
      [/^Apply\?/, true],
    ]);
    const code = await main(['--cwd', dir, '--api-url', server.url, '--no-install'], {
      ui,
      sleep: clock.sleep,
      now: clock.now,
      openBrowser: () => undefined,
      debugFingerprint: () => FP,
      liveWaitMs: 60_000,
    });
    expect(code, ui.text).toBe(0);
    const create = server.requests.filter((r) => r.method === 'POST' && r.path === '/v1/apps').map((r) => r.body);
    expect(create).toEqual([
      { platform: 'android', name: 'flutter_app', package_name: 'com.example.flutter_app', sha256_cert_fingerprints: [FP] },
      { platform: 'ios', name: 'flutter_app', bundle_id: 'com.example.flutterApp', team_id: '723T38P4P4' },
    ]);
    // Play App Signing fingerprint added (add-only).
    const patch = server.requests.find((r) => r.method === 'PATCH' && r.path === '/v1/apps/app_1');
    expect(patch?.body).toEqual({ sha256_cert_fingerprints: [FP, PLAY] });
    // Change 09 (N.1): no shared-domain opt-in any more.
    expect(server.requests.some((r) => r.path.endsWith('/sdk-settings'))).toBe(false);
    // Only allow-listed endpoints, always with the token.
    for (const r of server.requests) {
      if (r.path.startsWith('/v1/cli/device-codes') || r.path === '/v1/cli/token') continue;
      expect(r.auth).toBe(`Bearer ${MOCK_TOKEN}`);
      expect(r.path).toMatch(/^\/v1\/(apps|domains|link-subdomains\/availability|cli\/setup-check)/);
    }
    const main_ = fs.readFileSync(path.join(dir, 'lib/main.dart'), 'utf8');
    expect(main_).toContain("sdkKey: defaultTargetPlatform == TargetPlatform.iOS ? 'cg_sdk_test_ios2' : 'cg_sdk_test_android1',");
    expect(main_).toContain("linkDomains: ['flutter-app.ciz.to', 'go.acme.com', if (kDebugMode) 'flutter-app.dev.ciz.to'],");
    expect(main_).toContain("import 'package:flutter/foundation.dart' show kDebugMode, defaultTargetPlatform, TargetPlatform;");
    // Release: the app subdomain and the active custom domain; debug adds the test subdomain; no shared domain anywhere.
    const androidMain = fs.readFileSync(path.join(dir, 'android/app/src/main/AndroidManifest.xml'), 'utf8');
    expect([...verifiedHosts(androidMain)].sort()).toEqual(['flutter-app.ciz.to', 'go.acme.com']);
    expect([...verifiedHosts(fs.readFileSync(path.join(dir, 'android/app/src/debug/AndroidManifest.xml'), 'utf8'))]).toEqual(['flutter-app.dev.ciz.to']);
    expect(applinksHosts(fs.readFileSync(path.join(dir, 'ios/Runner/Runner.entitlements'), 'utf8')).sort()).toEqual(['flutter-app.ciz.to', 'go.acme.com']);
    expect(applinksHosts(fs.readFileSync(path.join(dir, 'ios/Runner/RunnerDebug.entitlements'), 'utf8')).sort()).toEqual(['flutter-app.ciz.to', 'flutter-app.dev.ciz.to', 'go.acme.com']);
    for (const shared of ['"ciz.to"', '"clk.ng"', '"dev.ciz.to"', 'applinks:ciz.to<', 'applinks:dev.ciz.to<']) expect(androidMain + fs.readFileSync(path.join(dir, 'ios/Runner/RunnerDebug.entitlements'), 'utf8')).not.toContain(shared);
    expect(androidMain).not.toContain('old.acme.com'); // a custom domain that isn't active
    // Doctor ran with Clikgate's setup check and saw the first event.
    expect(ui.text).toContain('flutter-app.ciz.to: assetlinks.json lists this app');
    expect(ui.text).toContain('flutter-app.ciz.to: apple-app-site-association lists this app');
    expect(ui.text).toContain('Android app: link subdomain flutter-app.ciz.to (debug builds flutter-app.dev.ciz.to)');
    // Next steps: one goal() method with the Provider enum (never payment()).
    expect(ui.text).toContain("3. Send goals with one call: Clikgate.goal('purchase', reference: 'T123456', provider: ClikgateProvider.paystack)");
    expect(ui.text).not.toContain('payment(');
    // Change 22 (I.2): identity Path A by default, Path B mentioned, the guide linked; never track().
    expect(ui.text).toContain("4. Identify signed-in users (optional): return a token from your server's createIdentityToken(user.id)");
    expect(ui.text).toContain('Clikgate.identifyUser(customerId: user.id, identityToken: response.clikgateToken)');
    expect(ui.text).toContain('await Clikgate.getInstallationId()');
    expect(ui.text).toContain('https://clikgate.com/docs/identify-users');
    expect(ui.text).not.toMatch(/\.track\(/);
    expect(ui.text).toContain('authenticator code');
    expect(ui.text).toMatch(/Clikgate is receiving events from (Android|iOS) ✓/);
    expect(ui.text.trim().endsWith('Clikgate sees every click. Setup complete.')).toBe(true);
    // The CLI token is never printed or written.
    expect(ui.text).not.toContain(MOCK_TOKEN);
    expect(JSON.stringify([...fs.readdirSync(dir)])).not.toContain(MOCK_TOKEN);
  });

  it('Free plan (change 10): release builds get <sub>.clk.ng from app_link_domains, debug builds <sub>.dev.ciz.to; doctor passes', async () => {
    server = await startMockServer({ liveParent: 'clk.ng' });
    const dir = copyFixture('flutter');
    const clock = fakeClock();
    const ui = new ScriptedUI([
      [/Create "flutter_app" \(Android/, true],
      [/Create "flutter_app" \(iOS/, true],
      [/Paste it now/, PLAY],
      [/Show full diff/, false],
      [/^Apply\?/, true],
    ]);
    const code = await main(['--cwd', dir, '--api-url', server.url, '--no-install'], {
      ui,
      sleep: clock.sleep,
      now: clock.now,
      openBrowser: () => undefined,
      debugFingerprint: () => FP,
      liveWaitMs: 60_000,
    });
    expect(code, ui.text).toBe(0);
    const main_ = fs.readFileSync(path.join(dir, 'lib/main.dart'), 'utf8');
    expect(main_).toContain("linkDomains: ['flutter-app.clk.ng', 'go.acme.com', if (kDebugMode) 'flutter-app.dev.ciz.to'],");
    const androidMain = fs.readFileSync(path.join(dir, 'android/app/src/main/AndroidManifest.xml'), 'utf8');
    expect([...verifiedHosts(androidMain)].sort()).toEqual(['flutter-app.clk.ng', 'go.acme.com']);
    expect([...verifiedHosts(fs.readFileSync(path.join(dir, 'android/app/src/debug/AndroidManifest.xml'), 'utf8'))]).toEqual(['flutter-app.dev.ciz.to']);
    expect(applinksHosts(fs.readFileSync(path.join(dir, 'ios/Runner/Runner.entitlements'), 'utf8')).sort()).toEqual(['flutter-app.clk.ng', 'go.acme.com']);
    expect(androidMain).not.toContain('"clk.ng"');
    expect(ui.text).toContain('Android app: link subdomain flutter-app.clk.ng (debug builds flutter-app.dev.ciz.to)');
    expect(ui.text).toContain('flutter-app.clk.ng: assetlinks.json lists this app');
    expect(ui.text).not.toContain('remove this');
    expect(ui.text.trim().endsWith('Clikgate sees every click. Setup complete.')).toBe(true);
  });

  it('an unconfirmed suggestion: asks, checks another name, confirms with PATCH and writes per-platform hosts', async () => {
    const settings = { shared_domain_app_links: false, test_domain_app_links: true };
    server = await startMockServer({
      takenSubdomains: ['shop'],
      apps: [
        { id: 'app_a', platform: 'android', name: 'A', package_name: 'com.example.flutter_app', sha256_cert_fingerprints: [FP], sdk_key_test: 'cg_sdk_test_same', sdk_settings: settings, link_subdomain: 'acme-a', link_subdomain_confirmed: false },
        { id: 'app_i', platform: 'ios', name: 'I', bundle_id: 'com.example.flutterApp', team_id: '723T38P4P4', sha256_cert_fingerprints: [], sdk_key_test: 'cg_sdk_test_same', sdk_settings: settings, link_subdomain: 'acme-i', link_subdomain_confirmed: true },
      ],
    });
    const dir = copyFixture('flutter');
    const clock = fakeClock();
    const ui = new ScriptedUI([
      [/Use "acme-a"\?/, false],
      [/Type another link subdomain/, 'shop'],
      [/Use "shop-2"\?/, true],
      [/Show full diff/, false],
      [/^Apply\?/, true],
    ]);
    const code = await main(['--cwd', dir, '--api-url', server.url, '--no-install', '--no-wait'], { ui, sleep: clock.sleep, now: clock.now, openBrowser: () => undefined, debugFingerprint: () => FP });
    expect(code, ui.text).toBe(0);
    expect(ui.text).toContain('shop: Another app already uses this name.');
    const patch = server.requests.filter((r) => r.method === 'PATCH' && r.path === '/v1/apps/app_a').map((r) => r.body);
    expect(patch).toContainEqual({ link_subdomain: 'shop-2' });
    expect(server.requests.some((r) => r.path.startsWith('/v1/link-subdomains/availability?name=shop&platform=android'))).toBe(true);
    // Each platform's files get only its own app's subdomain (the other app's file wouldn't list it).
    expect([...verifiedHosts(fs.readFileSync(path.join(dir, 'android/app/src/main/AndroidManifest.xml'), 'utf8'))].sort()).toEqual(['go.acme.com', 'shop-2.ciz.to']);
    expect([...verifiedHosts(fs.readFileSync(path.join(dir, 'android/app/src/debug/AndroidManifest.xml'), 'utf8'))]).toEqual(['shop-2.dev.ciz.to']);
    expect(applinksHosts(fs.readFileSync(path.join(dir, 'ios/Runner/Runner.entitlements'), 'utf8')).sort()).toEqual(['acme-i.ciz.to', 'go.acme.com']);
    expect(applinksHosts(fs.readFileSync(path.join(dir, 'ios/Runner/RunnerDebug.entitlements'), 'utf8'))).toContain('acme-i.dev.ciz.to');
    // Same key for both apps: a single literal. The code lists every platform's release hosts.
    const dart = fs.readFileSync(path.join(dir, 'lib/main.dart'), 'utf8');
    expect(dart).toContain("sdkKey: 'cg_sdk_test_same',");
    expect(dart).toContain("'shop-2.ciz.to'");
    expect(dart).toContain("'acme-i.ciz.to'");
  });

  it('--yes confirms the suggested subdomain; skipping it leaves a manual step and no app links for that app', async () => {
    const settings = { shared_domain_app_links: false, test_domain_app_links: true };
    server = await startMockServer({
      apps: [{ id: 'app_a', platform: 'android', name: 'A', package_name: 'com.example.myapplication', sha256_cert_fingerprints: [FP], sdk_key_test: 'cg_sdk_test_x', sdk_settings: settings, link_subdomain: 'myapp', link_subdomain_confirmed: false }],
    });
    const dir = copyFixture('android-compose');
    const clock = fakeClock();
    const code = await main(['--cwd', dir, '--api-url', server.url, '--no-install', '--no-wait', '--yes'], { ui: new ScriptedUI(), sleep: clock.sleep, now: clock.now, openBrowser: () => undefined, debugFingerprint: () => FP });
    expect(code).toBe(0);
    expect(server.requests.find((r) => r.method === 'PATCH' && r.path === '/v1/apps/app_a' && (r.body as { link_subdomain?: string })?.link_subdomain)?.body).toEqual({ link_subdomain: 'myapp' });
    expect(fs.readFileSync(path.join(dir, 'app/src/main/AndroidManifest.xml'), 'utf8')).toContain('android:host="myapp.ciz.to"');

    const server2 = await startMockServer({
      apps: [{ id: 'app_a', platform: 'android', name: 'A', package_name: 'com.example.myapplication', sha256_cert_fingerprints: [FP], sdk_key_test: 'cg_sdk_test_x', sdk_settings: settings, link_subdomain: 'myapp', link_subdomain_confirmed: false }],
    });
    try {
      const dir2 = copyFixture('android-compose');
      const ui = new ScriptedUI([[/Use "myapp"\?/, false], [/Type another link subdomain/, ''], [/Show full diff/, false], [/^Apply\?/, true]]);
      expect(await main(['--cwd', dir2, '--api-url', server2.url, '--no-install', '--no-wait'], { ui, sleep: clock.sleep, now: clock.now, openBrowser: () => undefined, debugFingerprint: () => FP })).toBe(0);
      expect(server2.requests.some((r) => r.method === 'PATCH' && (r.body as { link_subdomain?: string })?.link_subdomain)).toBe(false);
      expect(ui.text).toContain('Android link subdomain');
      expect(fs.readFileSync(path.join(dir2, 'app/src/main/AndroidManifest.xml'), 'utf8')).not.toContain('ciz.to');
    } finally {
      await server2.close();
    }
  });

  it('cancelling at "Apply?" changes nothing and exits 2', async () => {
    server = await startMockServer({
      apps: [{ id: 'app_a', platform: 'android', name: 'A', package_name: 'com.example.myapplication', sha256_cert_fingerprints: [FP], sdk_key_test: 'cg_sdk_test_x', sdk_settings: { shared_domain_app_links: true, test_domain_app_links: true } }],
    });
    const dir = copyFixture('android-compose');
    const clock = fakeClock();
    const ui = new ScriptedUI([[/Show full diff/, true], [/^Apply\?/, false]]);
    const code = await main(['--cwd', dir, '--api-url', server.url, '--no-install'], { ui, sleep: clock.sleep, now: clock.now, openBrowser: () => undefined, debugFingerprint: () => FP });
    expect(code).toBe(2);
    expect(fs.readFileSync(path.join(dir, 'app/build.gradle.kts'), 'utf8')).not.toContain('clikgate');
  });
});
