import * as fs from 'node:fs';
import * as path from 'node:path';
import Ajv2020 from 'ajv/dist/2020';
import { describe, expect, it, vi } from 'vitest';
import { serverChecks, type DoctorReport } from '../src/doctor';
import { main } from '../src/index';
import { OFFLINE, ScriptedUI, copyFixture } from './helpers';

const schema = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'schema', 'doctor-report.schema.json'), 'utf8'));
const validate = new Ajv2020({ strict: true, allErrors: true }).compile(schema);

async function doctorJson(dir: string, extra: string[] = []): Promise<{ code: number; report: DoctorReport }> {
  let out = '';
  const spy = vi.spyOn(process.stdout, 'write').mockImplementation((chunk: string | Uint8Array) => {
    out += chunk.toString();
    return true;
  });
  try {
    const code = await main(['doctor', '--json', '--cwd', dir, ...extra], { ui: new ScriptedUI([], false) });
    return { code, report: JSON.parse(out) as DoctorReport };
  } finally {
    spy.mockRestore();
  }
}

async function setUp(fixture: string): Promise<string> {
  const dir = copyFixture(fixture);
  expect(await main(['--cwd', dir, ...OFFLINE], { ui: new ScriptedUI() })).toBe(0);
  return dir;
}

function byId(r: DoctorReport, id: string) {
  return r.checks.find((c) => c.id === id);
}

describe('doctor --json', () => {
  it('reports a clean setup with the documented schema and exit 0', async () => {
    for (const fixture of ['flutter', 'react-native', 'expo-router', 'android-compose', 'ios-uikit']) {
      const dir = await setUp(fixture);
      const { code, report } = await doctorJson(dir, ['--domain', 'acme.ciz.to,go.acme.com']);
      expect(validate(report), JSON.stringify(validate.errors)).toBe(true);
      expect(report.ok, JSON.stringify(report.checks.filter((c) => c.status === 'fail'))).toBe(true);
      expect(code).toBe(0);
      expect(byId(report, 'clikgate.signed_in')?.status).toBe('skip');
      // Key never printed in full.
      expect(JSON.stringify(report)).not.toContain('cg_sdk_test_abc123');
    }
  });

  it('fails on an untouched project (no dependency, no start-up code) with exit 1', async () => {
    const dir = copyFixture('flutter');
    const { code, report } = await doctorJson(dir);
    expect(validate(report)).toBe(true);
    expect(code).toBe(1);
    expect(byId(report, 'sdk.dependency')?.status).toBe('fail');
    expect(byId(report, 'startup.code')?.status).toBe('fail');
    expect(byId(report, 'ios.entitlements.Release')?.status).toBe('fail');
    expect(byId(report, 'android.debug_test_domain')?.status).toBe('warn');
  });

  it('fails when the test domain reaches a release manifest or release entitlements', async () => {
    const dir = await setUp('react-native');
    const main_ = path.join(dir, 'android/app/src/main/AndroidManifest.xml');
    fs.writeFileSync(main_, fs.readFileSync(main_, 'utf8').replace('<data android:host="go.acme.com" />', '<data android:host="go.acme.com" />\n            <data android:host="acme.dev.ciz.to" />'));
    const rel = path.join(dir, 'ios/RnApp/RnApp.entitlements');
    fs.writeFileSync(rel, fs.readFileSync(rel, 'utf8').replace('</array>', '\t<string>applinks:acme.dev.ciz.to</string>\n\t</array>'));
    const { code, report } = await doctorJson(dir);
    expect(code).toBe(1);
    expect(byId(report, 'android.release_no_test_domain')?.status).toBe('fail');
    expect(byId(report, 'ios.entitlements.Release')?.status).toBe('fail');
    expect(byId(report, 'ios.entitlements.Release')?.fix).toMatch(/Remove applinks:acme\.dev\.ciz\.to/);
  });

  it('fails when a release build misses a live domain, warns for a missing debug test domain', async () => {
    const dir = await setUp('android-compose');
    fs.rmSync(path.join(dir, 'app/src/debug/AndroidManifest.xml'));
    const { report } = await doctorJson(dir, ['--domain', 'acme.ciz.to,go.acme.com,links.acme.com']);
    expect(byId(report, 'android.release_domains')?.status).toBe('fail');
    expect(byId(report, 'android.release_domains')?.title).toContain('links.acme.com');
    expect(byId(report, 'android.debug_test_domain')?.status).toBe('warn');
  });

  it('fails when CODE_SIGN_ENTITLEMENTS points to a missing file', async () => {
    const dir = await setUp('ios-swiftui');
    fs.rmSync(path.join(dir, 'MyApp/MyAppDebug.entitlements'));
    const { report } = await doctorJson(dir);
    expect(byId(report, 'ios.entitlements.Debug')?.status).toBe('fail');
    expect(byId(report, 'ios.entitlements.Debug')?.title).toContain('is missing');
  });

  it('reports a live key without printing it', async () => {
    const dir = await setUp('expo-blank');
    const app = path.join(dir, 'App.tsx');
    fs.writeFileSync(app, fs.readFileSync(app, 'utf8').replace('cg_sdk_test_abc123', 'cg_sdk_live_zyx987'));
    const { report } = await doctorJson(dir);
    const key = byId(report, 'sdk.key')!;
    expect(key.title).toBe('Live SDK key in use');
    expect(key.detail).toBe('cg_sdk_live_zyx9…');
    expect(JSON.stringify(report)).not.toContain('zyx987');
  });

  it('warns when the SDK constraint is below the minimum (Flutter ^1.3.0 < 2.0.0)', async () => {
    const dir = await setUp('flutter');
    const pub = path.join(dir, 'pubspec.yaml');
    fs.writeFileSync(pub, fs.readFileSync(pub, 'utf8').replace('clikgate_flutter: ^2.0.0', 'clikgate_flutter: ^1.3.0'));
    const { code, report } = await doctorJson(dir);
    expect(byId(report, 'sdk.version')).toMatchObject({ status: 'warn', title: 'SDK version ^1.3.0' });
    expect(byId(report, 'sdk.version')?.detail).toBe('below the minimum 2.0.0');
    expect(code).toBe(0); // a warning, not a failure
  });

  it('flags the test domain in the Expo plugin linkDomains', async () => {
    const dir = await setUp('expo-blank');
    const app = path.join(dir, 'app.json');
    const j = JSON.parse(fs.readFileSync(app, 'utf8'));
    j.expo.plugins[0][1].linkDomains.push('acme.dev.ciz.to');
    fs.writeFileSync(app, JSON.stringify(j, null, 2));
    const { code, report } = await doctorJson(dir);
    expect(code).toBe(1);
    expect(byId(report, 'expo.plugin')?.status).toBe('fail');
  });

  it('warns on shared domains left in a project: "remove this: shared domains can\'t open your app" (change 09)', async () => {
    const dir = await setUp('react-native');
    const main_ = path.join(dir, 'android/app/src/main/AndroidManifest.xml');
    fs.writeFileSync(main_, fs.readFileSync(main_, 'utf8').replace('<data android:host="go.acme.com" />', '<data android:host="go.acme.com" />\n            <data android:host="clk.ng" />'));
    const rel = path.join(dir, 'ios/RnApp/RnAppDebug.entitlements');
    fs.writeFileSync(rel, fs.readFileSync(rel, 'utf8').replace('</array>', '\t<string>applinks:dev.ciz.to</string>\n\t</array>'));
    const { code, report } = await doctorJson(dir, ['--domain', 'acme.ciz.to,go.acme.com']);
    expect(code).toBe(0); // warnings, not failures
    expect(byId(report, 'android.shared_domains')).toMatchObject({ status: 'warn' });
    expect(byId(report, 'android.shared_domains')?.title).toContain("clk.ng: remove this: shared domains can't open your app");
    expect(byId(report, 'ios.shared_domains')?.title).toContain("applinks:dev.ciz.to: remove this: shared domains can't open your app");
    for (const shared of ['ciz.to', 'clkg.to']) {
      const d2 = await setUp('expo-blank');
      const app = path.join(d2, 'app.json');
      const j = JSON.parse(fs.readFileSync(app, 'utf8'));
      j.expo.plugins[0][1].linkDomains.push(shared);
      fs.writeFileSync(app, JSON.stringify(j, null, 2));
      const r = await doctorJson(d2);
      expect(byId(r.report, 'expo.shared_domains')?.title).toContain(`${shared}: remove this`);
    }
  });

  it('passes the shared-domain checks after setup', async () => {
    const dir = await setUp('flutter');
    const { report } = await doctorJson(dir, ['--domain', 'acme.ciz.to,go.acme.com']);
    expect(byId(report, 'android.shared_domains')?.status).toBe('pass');
    expect(byId(report, 'ios.shared_domains')?.status).toBe('pass');
    expect(byId(report, 'android.debug_test_domain')?.title).toContain('acme.dev.ciz.to');
  });

  it('accepts a Free plan app subdomain (<sub>.clk.ng) in release builds (change 10)', async () => {
    const dir = copyFixture('flutter');
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'acme.clk.ng', '--yes'], { ui: new ScriptedUI() })).toBe(0);
    const { code, report } = await doctorJson(dir, ['--domain', 'acme.clk.ng']);
    expect(code).toBe(0);
    expect(byId(report, 'android.shared_domains')?.status).toBe('pass');
    expect(byId(report, 'ios.shared_domains')?.status).toBe('pass');
    expect(byId(report, 'android.release_domains')).toMatchObject({ status: 'pass', title: 'Android: release builds cover acme.clk.ng' });
    expect(byId(report, 'android.debug_test_domain')?.title).toContain('acme.dev.ciz.to');
    expect(report.checks.filter((c) => c.status === 'fail')).toEqual([]);
  });

  it('prints a human report and the same exit code without --json', async () => {
    const dir = copyFixture('ios-swiftui');
    const ui = new ScriptedUI([], false);
    expect(await main(['doctor', '--cwd', dir], { ui })).toBe(1);
    expect(ui.text).toContain('✗ Start-up code');
    expect(ui.text).toMatch(/problems? found/);
  });
});

describe("doctor: Clikgate's setup check", () => {
  const app = { id: 'app_1', platform: 'android' as const };
  const ok = { applies: true, served: true, contains_app: true, problem: null };
  const other = { applies: false, served: true, contains_app: false, problem: null };
  it('judges only the file that applies to the platform', () => {
    const r = serverChecks(app, { app: { fingerprints_present: true }, domains: [{ hostname: 'go.acme.com', aasa: other, assetlinks: ok }] });
    expect(r.checks.map((c) => [c.id, c.status])).toEqual([
      ['clikgate.android.fingerprints', 'pass'],
      ['clikgate.domain.go.acme.com.assetlinks', 'pass'],
    ]);
  });
  it.each([
    ['link_subdomain_not_confirmed', /Confirm the app's link subdomain/],
    ['wrong_fingerprint', /keytool/],
    ['redirected', /without redirects/],
    ['some_new_code', /Clikgate reports: some_new_code/],
  ])('%s → fail with a fix', (problem, fix) => {
    const r = serverChecks(app, { app: { fingerprints_present: true }, domains: [{ hostname: 'acme.ciz.to', assetlinks: { applies: true, served: true, contains_app: false, problem }, aasa: other }] });
    const c = r.checks.find((x) => x.id === 'clikgate.domain.acme.ciz.to.assetlinks')!;
    expect(c.status).toBe('fail');
    expect(c.fix).toMatch(fix);
  });
  it('checks the app link subdomain: confirmed passes, unconfirmed fails with a fix (change 09)', () => {
    const ok = serverChecks(app, { app: { fingerprints_present: true, link_subdomain: 'acme', link_subdomain_confirmed: true }, domains: [] });
    expect(ok.checks.find((c) => c.id === 'clikgate.android.link_subdomain')).toMatchObject({ status: 'pass', title: 'Android app: link subdomain acme.ciz.to (debug builds acme.dev.ciz.to)' });
    const no = serverChecks(app, { app: { fingerprints_present: true, link_subdomain: 'acme', link_subdomain_confirmed: false }, domains: [] });
    expect(no.checks.find((c) => c.id === 'clikgate.android.link_subdomain')).toMatchObject({ status: 'fail', code: 'link_subdomain_not_confirmed' });
  });
  it('a Free plan app subdomain from the server passes (change 10)', () => {
    const r = serverChecks(app, {
      app: { fingerprints_present: true, link_subdomain: 'acme', link_subdomain_confirmed: true, link_hostnames: { live: 'acme.clk.ng', test: 'acme.dev.ciz.to' } },
      domains: [{ hostname: 'acme.clk.ng', assetlinks: ok, aasa: other }],
    });
    expect(r.checks.find((c) => c.id === 'clikgate.android.link_subdomain')).toMatchObject({ status: 'pass', title: 'Android app: link subdomain acme.clk.ng (debug builds acme.dev.ciz.to)' });
    expect(r.checks.find((c) => c.id === 'clikgate.domain.acme.clk.ng.assetlinks')?.status).toBe('pass');
  });
  it('not served, missing fingerprints / Team ID, SDK warnings and next steps', () => {
    const r = serverChecks(app, {
      app: { fingerprints_present: false },
      domains: [{ hostname: 'go.acme.com', assetlinks: { applies: true, served: false, contains_app: false, problem: null } }],
      sdk: { warnings: [{ code: 'sdk_outdated', severity: 'warning', message: 'SDK 1.1.0 is below 1.3.0' }] },
      next_steps: [{ message: 'Add your Play App Signing fingerprint', doc_url: 'https://clikgate.com/docs/android' }],
    });
    expect(r.checks.find((c) => c.id === 'clikgate.android.fingerprints')?.status).toBe('fail');
    expect(r.checks.find((c) => c.id === 'clikgate.domain.go.acme.com.assetlinks')?.title).toContain('not served');
    expect(r.checks.find((c) => c.id === 'clikgate.sdk.sdk_outdated')?.status).toBe('warn');
    expect(r.next).toEqual([{ message: 'Add your Play App Signing fingerprint', doc_url: 'https://clikgate.com/docs/android' }]);
    const ios = serverChecks({ id: 'app_2', platform: 'ios' }, { app: { team_id_present: false }, domains: [] });
    expect(ios.checks[0]).toMatchObject({ id: 'clikgate.ios.team_id', status: 'fail' });
  });
});
