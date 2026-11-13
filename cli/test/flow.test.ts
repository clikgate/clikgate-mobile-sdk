import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { describe, expect, it } from 'vitest';
import { detect, detectPackageManager } from '../src/detect';
import { main } from '../src/index';
import { loadProject } from '../src/project/load';
import { FIXTURES, OFFLINE, ScriptedUI, copyFixture, snapshotTree } from './helpers';

describe('detection', () => {
  it.each([
    ['flutter', 'flutter'],
    ['react-native', 'react-native'],
    ['expo-blank', 'expo'],
    ['expo-router', 'expo'],
    ['expo-native', 'expo'],
    ['android-compose', 'android'],
    ['android-views', 'android'],
    ['ios-swiftui', 'ios'],
    ['ios-uikit', 'ios'],
  ])('%s → %s', (fixture, platform) => {
    const found = detect(path.join(FIXTURES, fixture));
    expect(found.map((c) => c.platform)).toEqual([platform]);
  });
  it('Expo with and without native folders', () => {
    expect(detect(path.join(FIXTURES, 'expo-native'))[0].nativeFolders).toEqual({ android: true, ios: true });
    expect(detect(path.join(FIXTURES, 'expo-blank'))[0].nativeFolders).toEqual({ android: false, ios: false });
  });
  it('monorepo: finds the app below the workspace root and the root lockfile', () => {
    const found = detect(path.join(FIXTURES, 'monorepo'));
    expect(found.map((c) => [c.platform, path.relative(path.join(FIXTURES, 'monorepo'), c.root)])).toEqual([['react-native', 'apps/mobile']]);
    expect(detectPackageManager(found[0].root)).toBe('pnpm');
  });
  it('Gradle Kotlin DSL + version catalog, Groovy + flavours, Xcode targets', async () => {
    const ui = new ScriptedUI([[/applicationId/, [1]]]);
    const compose = await loadProject(ui, detect(path.join(FIXTURES, 'android-compose'))[0]);
    expect(compose.android).toMatchObject({ kotlinDsl: true, flavors: false, namespace: 'com.example.myapplication', launcherActivity: '.MainActivity' });
    expect(compose.android?.catalog).toMatch(/libs\.versions\.toml$/);
    const views = await loadProject(ui, detect(path.join(FIXTURES, 'android-views'))[0]);
    expect(views.android).toMatchObject({ kotlinDsl: false, flavors: true, applicationIds: ['com.example.viewsapp', 'com.example.viewsapp.paid'] });
    expect(views.androidAppId).toBe('com.example.viewsapp.paid');
    expect(ui.asked.some((q) => /applicationId/.test(q))).toBe(true);
    const swift = await loadProject(ui, detect(path.join(FIXTURES, 'ios-swiftui'))[0]);
    expect(swift.ios?.targets).toEqual(['MyApp']); // the unit-test target isn't an app target
    expect(swift).toMatchObject({ iosBundleId: 'com.example.MyApp', iosTeamId: 'ABCDE12345' });
    const flutter = await loadProject(ui, detect(path.join(FIXTURES, 'flutter'))[0]);
    expect(flutter.ios?.configs.map((c) => [c.name, c.debug])).toEqual([['Debug', true], ['Release', false], ['Profile', false]]);
    expect(flutter).toMatchObject({ androidAppId: 'com.example.flutter_app', iosBundleId: 'com.example.flutterApp' });
  });
  it('nothing found → explanation and exit 1', async () => {
    const dir = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'clikgate-empty-'));
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, ...OFFLINE], { ui })).toBe(1);
    expect(ui.text).toContain('No app project found');
  });
});

describe('offline mode', () => {
  it('refuses a live key', async () => {
    const dir = copyFixture('flutter');
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_live_abc', '--domain', 'acme.ciz.to', '--yes'], { ui })).toBe(1);
    expect(ui.text).toContain('Use the test key; switch to live for release builds');
    expect(snapshotTree(dir)).toEqual(snapshotTree(path.join(FIXTURES, 'flutter')));
  });
  it('needs a test key and --domain', async () => {
    const dir = copyFixture('flutter');
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, '--sdk-key', 'sk_123', '--domain', 'acme.ciz.to'], { ui })).toBe(1);
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a'], { ui })).toBe(1);
    expect(ui.text).toContain('Offline mode needs --domain');
  });
  it('refuses a shared domain in --domain: shared domains can\'t open the app (change 09)', async () => {
    const dir = copyFixture('android-views');
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'ciz.to,go.acme.com', '--yes'], { ui })).toBe(1);
    expect(ui.text).toContain("ciz.to: remove this: shared domains can't open your app");
  });
  it('adds the app\'s test subdomain to debug builds automatically, and drops test hosts from --domain', async () => {
    const dir = copyFixture('android-views');
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'acme.ciz.to,go.acme.com,acme.dev.ciz.to', '--yes'], { ui: new ScriptedUI() })).toBe(0);
    expect(fs.readFileSync(path.join(dir, 'app/src/main/AndroidManifest.xml'), 'utf8')).not.toContain('dev.ciz.to');
    expect(fs.readFileSync(path.join(dir, 'app/src/debug/AndroidManifest.xml'), 'utf8')).toContain('acme.dev.ciz.to');
  });
  it('Free plan (change 10): an app subdomain under clk.ng is not a shared domain; debug builds get <sub>.dev.ciz.to', async () => {
    const dir = copyFixture('android-views');
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'acme.clk.ng', '--yes'], { ui: new ScriptedUI() })).toBe(0);
    const release = fs.readFileSync(path.join(dir, 'app/src/main/AndroidManifest.xml'), 'utf8');
    expect(release).toContain('android:host="acme.clk.ng"');
    expect(release).not.toContain('dev.ciz.to');
    expect(fs.readFileSync(path.join(dir, 'app/src/debug/AndroidManifest.xml'), 'utf8')).toContain('acme.dev.ciz.to');
    // clk.ng itself is still refused.
    const ui = new ScriptedUI();
    expect(await main(['--cwd', copyFixture('android-views'), '--sdk-key', 'cg_sdk_test_a', '--domain', 'clk.ng', '--yes'], { ui })).toBe(1);
    expect(ui.text).toContain("clk.ng: remove this: shared domains can't open your app");
  });
});

describe('existing dependencies', () => {
  // `dart run clikgate_flutter` needs the package in pubspec.yaml first (`flutter pub add clikgate_flutter`,
  // which writes it in sorted order): setup reports the step as already done and leaves pubspec.yaml alone.
  it.each(['^2.1.0', '^2.3.0'])('clikgate_flutter %s added by `flutter pub add` is already set up, pubspec.yaml unchanged', async (constraint) => {
    const dir = copyFixture('flutter');
    const pub = path.join(dir, 'pubspec.yaml');
    const added = fs.readFileSync(pub, 'utf8').replace('dependencies:\n  flutter:\n    sdk: flutter\n', `dependencies:\n  clikgate_flutter: ${constraint}\n  flutter:\n    sdk: flutter\n`);
    expect(added).toContain(`clikgate_flutter: ${constraint}`);
    fs.writeFileSync(pub, added);
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, ...OFFLINE], { ui })).toBe(0);
    expect(fs.readFileSync(pub, 'utf8')).toBe(added);
    expect(ui.text).toMatch(/already set up\s+clikgate_flutter dependency/);
    expect(ui.text).not.toContain('Update clikgate_flutter');
    expect(ui.text).not.toContain('pubspec.yaml  (add clikgate_flutter');
  });

  it('an older constraint is kept and reported as a manual step', async () => {
    const dir = copyFixture('flutter');
    const pub = path.join(dir, 'pubspec.yaml');
    fs.writeFileSync(pub, fs.readFileSync(pub, 'utf8').replace('  cupertino_icons: ^1.0.8', '  cupertino_icons: ^1.0.8\n  clikgate_flutter: ^1.3.0'));
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, ...OFFLINE], { ui })).toBe(0);
    expect(fs.readFileSync(pub, 'utf8')).toContain('clikgate_flutter: ^1.3.0');
    expect(ui.text).toContain('pubspec.yaml has clikgate_flutter ^1.3.0; this setup needs 2.1.0 or newer. Change it to ^2.1.0 and reinstall.');
  });
});

describe('preview, confirm, backups, undo', () => {
  it('--dry-run prints diffs and changes nothing', async () => {
    const dir = copyFixture('react-native');
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'acme.ciz.to', '--dry-run'], { ui })).toBe(0);
    expect(ui.text).toContain('+++ b/App.tsx');
    expect(ui.text).toContain('--dry-run: nothing was changed.');
    expect(snapshotTree(dir)).toEqual(snapshotTree(path.join(FIXTURES, 'react-native')));
    expect(fs.existsSync(path.join(dir, '.clikgate-setup-backup'))).toBe(false);
  });
  it('without --yes in a non-interactive shell: prints the plan, applies nothing, exit 2', async () => {
    const dir = copyFixture('expo-blank');
    const ui = new ScriptedUI([], false);
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'acme.ciz.to'], { ui })).toBe(2);
    expect(ui.text).toContain('pass --yes');
    expect(snapshotTree(dir)).toEqual(snapshotTree(path.join(FIXTURES, 'expo-blank')));
  });
  it('dirty git tree: warns and asks; "no" cancels with exit 2', async () => {
    const dir = copyFixture('ios-swiftui');
    const git = (...a: string[]) => spawnSync('git', ['-c', 'user.email=t@example.com', '-c', 'user.name=t', ...a], { cwd: dir, encoding: 'utf8' });
    git('init', '-q');
    git('add', '.');
    git('commit', '-qm', 'init');
    fs.appendFileSync(path.join(dir, 'MyApp/ContentView.swift'), '// wip\n');
    const ui = new ScriptedUI([[/Continue anyway/, false]]);
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'acme.ciz.to', '--no-install'], { ui })).toBe(2);
    expect(ui.text).toContain('uncommitted change');
    // Clean tree in a git repo: no backup folder (git is the undo).
    git('checkout', '--', '.');
    const ui2 = new ScriptedUI([[/Show full diff/, false], [/^Apply\?/, true]]);
    expect(await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'acme.ciz.to', '--no-install'], { ui: ui2 })).toBe(0);
    expect(fs.existsSync(path.join(dir, '.clikgate-setup-backup'))).toBe(false);
  });
  it('not a git repository: backs up every changed file first', async () => {
    const dir = copyFixture('android-compose');
    const ui = new ScriptedUI();
    expect(await main(['--cwd', dir, ...OFFLINE], { ui })).toBe(0);
    const [stamp] = fs.readdirSync(path.join(dir, '.clikgate-setup-backup'));
    const backup = path.join(dir, '.clikgate-setup-backup', stamp);
    expect(fs.readFileSync(path.join(backup, 'app/build.gradle.kts'), 'utf8')).toBe(fs.readFileSync(path.join(FIXTURES, 'android-compose/app/build.gradle.kts'), 'utf8'));
    expect(fs.readFileSync(path.join(backup, 'README.txt'), 'utf8')).toContain('app/src/debug/AndroidManifest.xml  (new file: delete it)');
  });
  it('a failure mid-apply stops, lists what changed and how to undo it, exit 1', async () => {
    const dir = copyFixture('flutter');
    let n = 0;
    const ui = new ScriptedUI();
    const code = await main(['--cwd', dir, ...OFFLINE], {
      ui,
      apply: {
        writeFile: (file, text) => {
          if (++n === 3) throw new Error('disk full');
          fs.mkdirSync(path.dirname(file), { recursive: true });
          fs.writeFileSync(file, text);
        },
      },
    });
    expect(code).toBe(1);
    expect(ui.text).toContain("Couldn't write");
    expect(ui.text).toContain('These files were changed:');
    expect(ui.text).toContain('~ pubspec.yaml');
    expect(ui.text).toMatch(/copy the files in \.clikgate-setup-backup\/\S+ back over the project/);
    expect(ui.text).not.toContain('Setup complete');
  });
  it('a failing package install stops with exit 1 and undo instructions', async () => {
    const dir = copyFixture('react-native');
    const ui = new ScriptedUI();
    const code = await main(['--cwd', dir, '--sdk-key', 'cg_sdk_test_a', '--domain', 'acme.ciz.to', '--yes'], { ui, apply: { run: () => ({ ok: false, output: 'exit code 1' }) } });
    expect(code).toBe(1);
    expect(ui.text).toContain('`npm install` failed');
    expect(ui.text).toContain('To undo:');
  });
});
