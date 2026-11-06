import { describe, expect, it } from 'vitest';
import { addAppLinks, addDebugAppLinks, setApplicationName, verifiedHosts } from '../src/edit/androidManifest';
import { addCatalogEntries, addDependency, blocks, dependencyLine } from '../src/edit/gradle';
import { addExpoPlugin, addPackageDependency } from '../src/edit/json';
import { addBuildSetting, appTargets, replaceBuildSetting, setting } from '../src/edit/pbxproj';
import { addApplinks, applinksHosts } from '../src/edit/plistEdit';
import { addDependency as addPub, dependencyConstraint } from '../src/edit/pubspec';
import { editDartMain, editJsRoot, editKotlinActivity, editKotlinApplication, editSwiftUIApp, editUIKitAppDelegate, editUIKitSceneDelegate } from '../src/edit/source';
import { parseArgs, UsageError } from '../src/args';

const cfg = { sdkKey: 'cg_sdk_test_k', liveDomains: ['go.acme.com'], testDomain: 'dev.ciz.to' };

describe('XML manifests keep formatting', () => {
  const manifest = `<manifest xmlns:android="http://schemas.android.com/apk/res/android">
  <application android:label="x">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN" />
        <category android:name="android.intent.category.LAUNCHER" />
      </intent-filter>
      <!-- existing App Link -->
      <intent-filter android:autoVerify="true">
        <action android:name="android.intent.action.VIEW" />
        <data android:scheme="https" />
        <data android:host="old.acme.com" />
      </intent-filter>
    </activity>
  </application>
</manifest>
`;
  it('adds only missing hosts and never touches existing filters', () => {
    const r = addAppLinks(manifest, { activityName: '.MainActivity', hosts: ['old.acme.com', 'go.acme.com'], comment: 'c' });
    expect(r.added).toEqual(['go.acme.com']);
    expect(r.text.startsWith(manifest.slice(0, manifest.indexOf('    </activity>')))).toBe(true);
    expect([...verifiedHosts(r.text)].sort()).toEqual(['go.acme.com', 'old.acme.com']);
    // A second domain later goes into the Clikgate-marked filter.
    const r2 = addAppLinks(r.text, { activityName: '.MainActivity', hosts: ['go.acme.com', 'ciz.to'], comment: 'c' });
    expect(r2.text.match(/clikgate-setup:start/g)?.length).toBe(1);
    expect(verifiedHosts(r2.text).has('ciz.to')).toBe(true);
  });
  it('expands a self-closing <application/> in a debug manifest', () => {
    const debug = '<manifest xmlns:android="http://schemas.android.com/apk/res/android" xmlns:tools="http://schemas.android.com/tools">\n    <application tools:replace="x" />\n</manifest>\n';
    const r = addDebugAppLinks(debug, '.MainActivity', ['dev.ciz.to']);
    expect(r.text).toContain('<application tools:replace="x">');
    expect(r.text).toContain('<activity android:name=".MainActivity">');
    expect(verifiedHosts(r.text).has('dev.ciz.to')).toBe(true);
  });
  it('registers an Application class only when none is set', () => {
    expect(setApplicationName(manifest, '.ClikgateApplication')).toContain('<application android:label="x" android:name=".ClikgateApplication">');
    const named = manifest.replace('android:label="x"', 'android:name=".Mine"');
    expect(setApplicationName(named, '.ClikgateApplication')).toBe(named);
  });
});

describe('plist, pbxproj, gradle, pubspec, json', () => {
  it('appends applinks to an existing array', () => {
    const t = '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>aps-environment</key>\n\t<string>development</string>\n\t<key>com.apple.developer.associated-domains</key>\n\t<array>\n\t\t<string>applinks:old.acme.com</string>\n\t</array>\n</dict>\n</plist>\n';
    const out = addApplinks(t, ['old.acme.com', 'go.acme.com']);
    expect(applinksHosts(out)).toEqual(['old.acme.com', 'go.acme.com']);
    expect(out).toContain('\t\t<string>applinks:go.acme.com</string>\n\t</array>');
    expect(addApplinks(out, ['go.acme.com'])).toBe(out);
  });
  it('inserts a build setting in alphabetical position and refuses to overwrite', () => {
    const pbx = `// !$*UTF8*$!
{
	archiveVersion = 1;
	objectVersion = 77;
	objects = {
		C1 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.acme.app;
			};
			name = Debug;
		};
		L1 = {
			isa = XCConfigurationList;
			buildConfigurations = (
				C1 /* Debug */,
			);
		};
		T1 /* App */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = L1;
			name = App;
			productType = "com.apple.product-type.application";
		};
	};
	rootObject = T1;
}
`;
    const out = addBuildSetting(pbx, 'C1', 'CODE_SIGN_ENTITLEMENTS', 'App/AppDebug.entitlements');
    expect(out).toContain('AppIcon;\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = App/AppDebug.entitlements;\n\t\t\t\tLD_RUNPATH');
    expect(setting(appTargets(out)[0].configs[0], 'CODE_SIGN_ENTITLEMENTS')).toBe('App/AppDebug.entitlements');
    expect(() => addBuildSetting(out, 'C1', 'CODE_SIGN_ENTITLEMENTS', 'x')).toThrow(/already set/);
    expect(setting(appTargets(replaceBuildSetting(out, 'C1', 'CODE_SIGN_ENTITLEMENTS', 'App/Other.entitlements'))[0].configs[0], 'CODE_SIGN_ENTITLEMENTS')).toBe('App/Other.entitlements');
  });
  it('gradle: brace scanner ignores strings and comments; dependency lines per DSL', () => {
    const g = 'android {\n  defaultConfig { applicationId "a{b" } // }\n}\ndependencies {\n    implementation "x:y:1" /* } */\n}\n';
    expect(blocks(g).filter((b) => b.depth === 0).map((b) => b.name)).toEqual(['android', 'dependencies']);
    expect(addDependency(g, dependencyLine(false, false))).toContain("    implementation 'com.clikgate:clikgate-android:1.5.1'\n    // clikgate-setup:end\n}\n");
    expect(dependencyLine(true, false)).toBe('implementation("com.clikgate:clikgate-android:1.5.1")');
    expect(addCatalogEntries('[versions]\nagp = "8"\n\n[libraries]\nx = { module = "a:b" }\n')).toBe('[versions]\nagp = "8"\nclikgate = "1.5.1"\n\n[libraries]\nx = { module = "a:b" }\nclikgate-android = { group = "com.clikgate", name = "clikgate-android", version.ref = "clikgate" }\n');
  });
  it('pubspec: keeps comments and adds after the last dependency', () => {
    const y = 'name: a\ndependencies:\n  flutter:\n    sdk: flutter\n  # icons\n  cupertino_icons: ^1.0.8 # keep\n\n# dev\ndev_dependencies:\n  lints: ^5.0.0\n';
    const out = addPub(y, 'clikgate_flutter', '^1.5.1');
    expect(out).toBe('name: a\ndependencies:\n  flutter:\n    sdk: flutter\n  # icons\n  cupertino_icons: ^1.0.8 # keep\n  clikgate_flutter: ^1.5.1\n\n# dev\ndev_dependencies:\n  lints: ^5.0.0\n');
    expect(dependencyConstraint(out, 'clikgate_flutter')).toBe('^1.5.1');
  });
  it('package.json alphabetical insert; app.json plugin completes existing entries', () => {
    const pkg = '{\n  "dependencies": {\n    "expo": "~58.0.0",\n    "react": "19"\n  }\n}\n';
    expect(addPackageDependency(pkg, '@clikgate/react-native', '^1.6.1')).toBe('{\n  "dependencies": {\n    "@clikgate/react-native": "^1.6.1",\n    "expo": "~58.0.0",\n    "react": "19"\n  }\n}\n');
    const app = '{\n  "expo": {\n    "plugins": [\n      ["@clikgate/react-native", { "linkDomains": ["old.acme.com"] }]\n    ]\n  }\n}\n';
    const out = JSON.parse(addExpoPlugin(app, { linkDomains: ['go.acme.com'], testLinkDomain: 'dev.ciz.to' }));
    expect(out.expo.plugins[0]).toEqual(['@clikgate/react-native', { linkDomains: ['old.acme.com', 'go.acme.com'], testLinkDomain: 'dev.ciz.to' }]);
  });
});

describe('source code: recognised shapes only, otherwise manual', () => {
  it('Dart: arrow main becomes async with configure before runApp', () => {
    const r = editDartMain("import 'package:flutter/material.dart';\n\nvoid main() => runApp(const MyApp());\n", cfg);
    expect(r.kind).toBe('change');
    if (r.kind === 'change') {
      expect(r.text).toContain('Future<void> main() async {');
      expect(r.text.indexOf('await Clikgate.configure(')).toBeLessThan(r.text.indexOf('runApp(const MyApp());'));
    }
  });
  it.each([
    ['Dart main without runApp', () => editDartMain('void main() {\n  start();\n}\n', cfg)],
    ['Dart with no main', () => editDartMain('class A {}\n', cfg)],
    ['JS expression-bodied component', () => editJsRoot("import React from 'react';\nconst App = () => (\n  <View />\n);\nexport default App;\n", cfg, 'App.tsx')],
    ['JS class component', () => editJsRoot("import React from 'react';\nexport default class App extends React.Component {\n  render() { return null; }\n}\n", cfg, 'App.tsx')],
    ['Kotlin Application without onCreate', () => editKotlinApplication('class MyApp : Application() {\n}\n', cfg, 'MyApp.kt')],
    ['Kotlin Activity that already has onNewIntent', () => editKotlinActivity('class MainActivity : ComponentActivity() {\n    override fun onCreate(savedInstanceState: Bundle?) {\n        super.onCreate(savedInstanceState)\n    }\n    override fun onNewIntent(intent: Intent) {\n        super.onNewIntent(intent)\n    }\n}\n', 'MainActivity', 'MainActivity.kt')],
    ['SwiftUI App with an init()', () => editSwiftUIApp('import SwiftUI\n@main\nstruct A: App {\n    init() {}\n    var body: some Scene {\n        WindowGroup {\n            ContentView()\n        }\n    }\n}\n', cfg, 'A.swift')],
    ['SwiftUI WindowGroup with several views', () => editSwiftUIApp('import SwiftUI\n@main\nstruct A: App {\n    var body: some Scene {\n        WindowGroup {\n            if x { ContentView() } else { Other() }\n        }\n    }\n}\n', cfg, 'A.swift')],
    ['UIKit AppDelegate already handling URLs', () => editUIKitAppDelegate('import UIKit\n@main\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {\n        return true\n    }\n    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool { true }\n}\n', cfg, 'AppDelegate.swift', true)],
    ['UIKit SceneDelegate already handling activities', () => editUIKitSceneDelegate('class SceneDelegate: UIResponder, UIWindowSceneDelegate {\n    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {}\n}\n', 'SceneDelegate.swift')],
  ])('%s → manual step with a snippet', (_name, run) => {
    const r = run();
    expect(r.kind).toBe('manual');
    if (r.kind === 'manual') {
      expect(r.reason.length).toBeGreaterThan(5);
      expect(r.snippet).toMatch(/Clikgate/);
    }
  });
  it('JS: reuses React.useEffect when React is the default import', () => {
    const r = editJsRoot("import React from 'react';\nimport { View } from 'react-native';\n\nexport default function App() {\n  return <View />;\n}\n", cfg, 'App.tsx');
    expect(r.kind).toBe('change');
    if (r.kind === 'change') {
      expect(r.text).toContain('  React.useEffect(');
      expect(r.text).not.toContain("import { useEffect } from 'react';");
    }
  });
});

describe('arguments', () => {
  it('parses every documented flag', () => {
    const o = parseArgs(['doctor', '--json', '--cwd', 'x', '--platform', 'ios', '--app', 'app_1', '--api-url', 'http://l/', '--no-color', '--verbose', '--no-wait'], '/');
    expect(o).toMatchObject({ command: 'doctor', json: true, cwd: 'x', platform: 'ios', app: 'app_1', apiUrl: 'http://l', color: false, verbose: true, wait: false });
    const s = parseArgs(['--sdk-key', 'cg_sdk_test_a', '--domain', 'https://Ciz.to/,go.acme.com', '--dry-run', '--yes', '--no-install'], '/');
    expect(s).toMatchObject({ command: 'setup', sdkKey: 'cg_sdk_test_a', domains: ['ciz.to', 'go.acme.com'], dryRun: true, yes: true, install: false });
  });
  it.each([[['--json']], [['--bogus']], [['--platform', 'web']], [['--domain', 'ciz.to']], [['deploy']], [['--cwd']]])('rejects %j', (argv) => {
    expect(() => parseArgs(argv, '/')).toThrow(UsageError);
  });
});

describe('goal snippets', () => {
  it('show one goal() call with the Provider enum on every platform, never payment()', async () => {
    const { GOAL_SNIPPET } = await import('../src/constants');
    for (const [platform, snippet] of Object.entries(GOAL_SNIPPET)) {
      expect(snippet, platform).toMatch(/goal\('purchase'|goal\("purchase"/);
      expect(snippet, platform).toMatch(/Provider\.PAYSTACK|\.paystack|Provider\.Paystack/);
      expect(snippet, platform).not.toContain('payment(');
    }
  });
});
