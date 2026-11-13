import { AndroidConfig, type ExportedConfig } from '@expo/config-plugins';
import fs from 'fs';
import os from 'os';
import path from 'path';

import withClikgate, {
  addApplinksToPlistText,
  addApsEnvironment,
  addPushTokenForwardObjc,
  addPushTokenForwardSwift,
  forwardsPushToken,
  addDebugAppLink,
  buildVariant,
  debugEntitlementsPath,
  isDebugSourceSet,
  isTestVariant,
  addAndroidIntentFilters,
  addAssociatedDomains,
  addQueriesScheme,
  addRemoteNotificationBackgroundMode,
  addUrlScheme,
  resolveProps,
} from '../index';

type Manifest = AndroidConfig.Manifest.AndroidManifest;

const baseConfig = (): ExportedConfig =>
  ({ name: 'My App', slug: 'my-app' }) as ExportedConfig;

/** The Expo prebuild template's manifest (main activity with the launcher filter + `scheme`). */
function templateManifest(): Manifest {
  return {
    manifest: {
      $: { 'xmlns:android': 'http://schemas.android.com/apk/res/android' },
      application: [
        {
          $: { 'android:name': '.MainApplication' },
          activity: [
            {
              '$': {
                'android:name': '.MainActivity',
                'android:launchMode': 'singleTask',
              },
              'intent-filter': [
                {
                  action: [
                    { $: { 'android:name': 'android.intent.action.MAIN' } },
                  ],
                  category: [
                    {
                      $: { 'android:name': 'android.intent.category.LAUNCHER' },
                    },
                  ],
                },
                {
                  action: [
                    { $: { 'android:name': 'android.intent.action.VIEW' } },
                  ],
                  category: [
                    {
                      $: { 'android:name': 'android.intent.category.DEFAULT' },
                    },
                    {
                      $: {
                        'android:name': 'android.intent.category.BROWSABLE',
                      },
                    },
                  ],
                  data: [{ $: { 'android:scheme': 'existingscheme' } }],
                },
              ],
            },
          ],
        },
      ],
    },
  } as Manifest;
}

/** Runs one mod of a plugin-applied config the way `expo prebuild` does (minus file I/O). */
async function runMod<T>(
  config: ExportedConfig,
  platform: 'ios' | 'android',
  modName: string,
  modResults: T
): Promise<T> {
  const mods = config.mods as Record<
    string,
    Record<string, (c: unknown) => Promise<unknown>>
  >;
  const mod = mods[platform]?.[modName];
  if (!mod) throw new Error(`no ${platform}.${modName} mod`);
  const projectRoot = fs.mkdtempSync(
    path.join(os.tmpdir(), 'clikgate-plugin-')
  );
  const result = (await mod({
    ...config,
    modResults,
    modRequest: {
      projectRoot,
      platformProjectRoot: path.join(projectRoot, platform),
      modName,
      platform,
      introspect: false,
      ignoreExistingNativeFiles: false,
    },
  })) as { modResults: T };
  return result.modResults;
}

function intentFilters(manifest: Manifest) {
  return (
    AndroidConfig.Manifest.getMainActivityOrThrow(manifest)['intent-filter'] ??
    []
  );
}

describe('resolveProps', () => {
  it('normalises domains and schemes', () => {
    expect(
      resolveProps({
        linkDomains: [
          'https://Inv.MyApp.com/',
          'applinks:go.myapp.com',
          'inv.myapp.com',
        ],
        uriScheme: 'myapp://',
      })
    ).toEqual({
      linkDomains: ['inv.myapp.com', 'go.myapp.com'],
      testLinkDomain: '',
      testVariants: ['development', 'preview'],
      uriScheme: 'myapp',
      enableBackgroundRemoteNotifications: true,
      enableWhatsAppSharing: true,
      automaticPushToken: true,
    });
  });

  it('defaults', () => {
    expect(resolveProps(undefined)).toEqual({
      linkDomains: [],
      testLinkDomain: '',
      testVariants: ['development', 'preview'],
      uriScheme: '',
      enableBackgroundRemoteNotifications: true,
      enableWhatsAppSharing: true,
      automaticPushToken: true,
    });
    expect(
      resolveProps({ enableBackgroundRemoteNotifications: false })
        .enableBackgroundRemoteNotifications
    ).toBe(false);
  });

  it('rejects invalid input', () => {
    expect(() =>
      resolveProps({ linkDomains: 'inv.myapp.com' as never })
    ).toThrow(/array/);
    expect(() => resolveProps({ linkDomains: ['not a domain'] })).toThrow(
      /Invalid link domain/
    );
    expect(() => resolveProps({ linkDomains: ['localhost'] })).toThrow(
      /Invalid link domain/
    );
    expect(() => resolveProps({ uriScheme: '1abc' })).toThrow(
      /Invalid uriScheme/
    );
  });
});

describe('iOS mods', () => {
  it('adds applinks entries to the entitlements, keeping existing ones', async () => {
    const config = withClikgate(baseConfig(), {
      linkDomains: ['inv.myapp.com', 'go.myapp.com'],
    });
    const entitlements = await runMod(config, 'ios', 'entitlements', {
      'com.apple.developer.associated-domains': [
        'applinks:other.example.com',
        'applinks:inv.myapp.com',
      ],
      'aps-environment': 'development',
    });
    expect(entitlements).toEqual({
      'com.apple.developer.associated-domains': [
        'applinks:other.example.com',
        'applinks:inv.myapp.com',
        'applinks:go.myapp.com',
      ],
      'aps-environment': 'development',
    });
  });

  it('adds the remote-notification background mode and the URL scheme', async () => {
    const config = withClikgate(baseConfig(), {
      linkDomains: ['inv.myapp.com'],
      uriScheme: 'myapp',
    });
    const plist = await runMod<Record<string, unknown>>(
      config,
      'ios',
      'infoPlist',
      {
        UIBackgroundModes: ['fetch'],
        CFBundleURLTypes: [{ CFBundleURLSchemes: ['com.example.myapp'] }],
      }
    );
    expect(plist.UIBackgroundModes).toEqual(['fetch', 'remote-notification']);
    expect(plist.CFBundleURLTypes).toEqual([
      { CFBundleURLSchemes: ['com.example.myapp'] },
      { CFBundleURLSchemes: ['myapp'] },
    ]);
  });

  it('adds whatsapp to LSApplicationQueriesSchemes, keeping existing ones', async () => {
    const config = withClikgate(baseConfig(), {});
    const plist = await runMod<Record<string, unknown>>(
      config,
      'ios',
      'infoPlist',
      { LSApplicationQueriesSchemes: ['tel'] }
    );
    expect(plist.LSApplicationQueriesSchemes).toEqual(['tel', 'whatsapp']);
  });

  it('can leave LSApplicationQueriesSchemes alone', async () => {
    const config = withClikgate(baseConfig(), {
      enableWhatsAppSharing: false,
    });
    const plist = await runMod<Record<string, unknown>>(
      config,
      'ios',
      'infoPlist',
      {}
    );
    expect(plist.LSApplicationQueriesSchemes).toBeUndefined();
  });

  it('can leave background modes alone', async () => {
    const config = withClikgate(baseConfig(), {
      enableBackgroundRemoteNotifications: false,
    });
    const plist = await runMod<Record<string, unknown>>(
      config,
      'ios',
      'infoPlist',
      {}
    );
    expect(plist.UIBackgroundModes).toBeUndefined();
    expect(plist.CFBundleURLTypes).toBeUndefined();
  });

  it('helpers are idempotent', () => {
    const e = addAssociatedDomains(
      addAssociatedDomains({}, ['a.example.com']),
      ['a.example.com']
    );
    expect(e['com.apple.developer.associated-domains']).toEqual([
      'applinks:a.example.com',
    ]);
    expect(addAssociatedDomains({ x: 1 }, [])).toEqual({ x: 1 });
    const p = addRemoteNotificationBackgroundMode(
      addRemoteNotificationBackgroundMode({})
    );
    expect(p.UIBackgroundModes).toEqual(['remote-notification']);
    const s = addUrlScheme(addUrlScheme({}, 'myapp'), 'myapp');
    expect(s.CFBundleURLTypes).toEqual([{ CFBundleURLSchemes: ['myapp'] }]);
    expect(addUrlScheme({}, '')).toEqual({});
    const q = addQueriesScheme(addQueriesScheme({}, 'whatsapp'), 'whatsapp');
    expect(q.LSApplicationQueriesSchemes).toEqual(['whatsapp']);
  });
});

describe('Android mods', () => {
  it('adds a verified App Link filter per domain and a scheme filter', async () => {
    const config = withClikgate(baseConfig(), {
      linkDomains: ['inv.myapp.com', 'go.myapp.com'],
      uriScheme: 'myapp',
    });
    const manifest = await runMod(
      config,
      'android',
      'manifest',
      templateManifest()
    );
    const filters = intentFilters(manifest);
    expect(filters).toHaveLength(5); // launcher + existing scheme + 2 domains + myapp

    const appLinks = filters.filter(
      (f) => f.$?.['android:autoVerify'] === 'true'
    );
    expect(appLinks).toEqual(
      ['inv.myapp.com', 'go.myapp.com'].map((host) => ({
        $: { 'android:autoVerify': 'true' },
        action: [{ $: { 'android:name': 'android.intent.action.VIEW' } }],
        category: [
          { $: { 'android:name': 'android.intent.category.DEFAULT' } },
          { $: { 'android:name': 'android.intent.category.BROWSABLE' } },
        ],
        data: [
          { $: { 'android:scheme': 'https' } },
          { $: { 'android:host': host } },
        ],
      }))
    );

    const scheme = filters[filters.length - 1];
    expect(scheme?.$).toBeUndefined();
    expect(scheme?.data).toEqual([{ $: { 'android:scheme': 'myapp' } }]);
  });

  it('does not duplicate filters (scheme already declared by Expo `scheme`, re-runs)', () => {
    let manifest = templateManifest();
    const options = {
      linkDomains: ['inv.myapp.com'],
      uriScheme: 'existingscheme',
    };
    manifest = addAndroidIntentFilters(manifest, options);
    manifest = addAndroidIntentFilters(manifest, options);
    const filters = intentFilters(manifest);
    expect(filters).toHaveLength(3); // launcher + existing scheme + 1 domain
  });

  it('works without any props', async () => {
    const config = withClikgate(baseConfig());
    const manifest = await runMod(
      config,
      'android',
      'manifest',
      templateManifest()
    );
    expect(intentFilters(manifest)).toHaveLength(2);
  });

  it('throws when there is no main activity', () => {
    const manifest = {
      manifest: { $: {}, application: [{ $: {} }] },
    } as unknown as Manifest;
    expect(() =>
      addAndroidIntentFilters(manifest, {
        linkDomains: ['a.example.com'],
        uriScheme: '',
      })
    ).toThrow();
  });
});

describe('plugin entry', () => {
  it('app.plugin.js exports the plugin function (built output)', () => {
    const built = path.join(__dirname, '../../build/index.js');
    if (!fs.existsSync(built)) return; // build output only exists after `npm run build:plugin`
    const plugin = require('../../../app.plugin.js');
    expect(typeof plugin).toBe('function');
    const config = plugin(baseConfig(), { linkDomains: ['inv.myapp.com'] });
    expect(Object.keys(config.mods.ios)).toEqual([
      'entitlements',
      'appDelegate',
      'infoPlist',
    ]);
    expect(Object.keys(config.mods.android)).toEqual(['manifest']);
  });

  it('runs once per config', () => {
    const config = withClikgate(
      withClikgate(baseConfig(), { linkDomains: ['a.example.com'] }),
      {
        linkDomains: ['b.example.com'],
      }
    );
    expect(
      config._internal?.pluginHistory?.['@clikgate/react-native']
    ).toBeDefined();
  });
});

describe('testLinkDomain (debug / development builds only)', () => {
  const FIXTURE = path.join(__dirname, '../__fixtures__/expo-prebuild');
  const ENV_KEYS = ['APP_VARIANT', 'EAS_BUILD_PROFILE'] as const;
  const saved: Record<string, string | undefined> = {};
  beforeEach(() => {
    for (const k of ENV_KEYS) {
      saved[k] = process.env[k];
      delete process.env[k];
    }
  });
  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k];
      else process.env[k] = saved[k];
    }
  });

  function copyPrebuild(): string {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'clikgate-prebuild-'));
    fs.cpSync(FIXTURE, dir, { recursive: true });
    return dir;
  }

  async function runFinalized(
    config: ExportedConfig,
    platform: 'ios' | 'android',
    projectRoot: string
  ) {
    const mods = config.mods as Record<
      string,
      Record<string, (c: unknown) => Promise<unknown>>
    >;
    await mods[platform]!.finalized!({
      ...config,
      modResults: undefined,
      modRequest: {
        projectRoot,
        platformProjectRoot: path.join(projectRoot, platform),
        modName: 'finalized',
        platform,
        introspect: false,
        ignoreExistingNativeFiles: false,
      },
    });
  }

  it('validates and normalises the prop', () => {
    expect(
      resolveProps({
        linkDomains: ['go.acme.com'],
        testLinkDomain: 'https://DEV.ciz.to/',
      })
    ).toMatchObject({
      testLinkDomain: 'dev.ciz.to',
      testVariants: ['development', 'preview'],
    });
    expect(() =>
      resolveProps({
        linkDomains: ['dev.ciz.to'],
        testLinkDomain: 'dev.ciz.to',
      })
    ).toThrow(/only as testLinkDomain/);
    expect(() => resolveProps({ testLinkDomain: 'not a host' })).toThrow(
      /Invalid testLinkDomain/
    );
    expect(() =>
      resolveProps({ testVariants: 'preview' as unknown as string[] })
    ).toThrow(/testVariants/);
  });

  it('reads the variant from APP_VARIANT, then EAS_BUILD_PROFILE', () => {
    expect(buildVariant({})).toBeUndefined();
    expect(buildVariant({ EAS_BUILD_PROFILE: 'preview' })).toBe('preview');
    expect(
      buildVariant({
        APP_VARIANT: 'development',
        EAS_BUILD_PROFILE: 'production',
      })
    ).toBe('development');
    expect(
      isTestVariant(['development', 'preview'], {
        EAS_BUILD_PROFILE: 'production',
      })
    ).toBe(false);
    expect(
      isTestVariant(['development', 'preview'], { APP_VARIANT: 'preview' })
    ).toBe(true);
    expect(isDebugSourceSet('debug')).toBe(true);
    expect(isDebugSourceSet('debugOptimized')).toBe(true);
    expect(isDebugSourceSet('freeDebug')).toBe(true);
    expect(isDebugSourceSet('release')).toBe(false);
  });

  it('production / unset variant: release config never gets the test domain', async () => {
    const config = withClikgate(baseConfig(), {
      linkDomains: ['go.acme.com'],
      testLinkDomain: 'dev.ciz.to',
    });
    const entitlements = await runMod(config, 'ios', 'entitlements', {});
    expect(entitlements).toMatchObject({
      'com.apple.developer.associated-domains': ['applinks:go.acme.com'],
    });
    const manifest = await runMod(
      config,
      'android',
      'manifest',
      templateManifest()
    );
    const hosts = intentFilters(manifest)
      .flatMap((f) => (f.data ?? []).map((d) => d.$?.['android:host']))
      .filter(Boolean);
    expect(hosts).toEqual(['go.acme.com']);
  });

  it.each(['development', 'preview'])(
    '%s variant: every build gets the test domain',
    async (variant) => {
      process.env.EAS_BUILD_PROFILE = variant;
      const config = withClikgate(baseConfig(), {
        linkDomains: ['go.acme.com'],
        testLinkDomain: 'dev.ciz.to',
      });
      const entitlements = await runMod(config, 'ios', 'entitlements', {});
      expect(entitlements).toMatchObject({
        'com.apple.developer.associated-domains': [
          'applinks:go.acme.com',
          'applinks:dev.ciz.to',
        ],
      });
    }
  );

  it('Android: adds the test domain to debug and debugOptimized manifests only (idempotent)', async () => {
    const dir = copyPrebuild();
    const config = withClikgate(baseConfig(), {
      linkDomains: ['go.acme.com'],
      testLinkDomain: 'dev.ciz.to',
    });
    await runFinalized(config, 'android', dir);
    await runFinalized(config, 'android', dir);
    const read = (s: string) =>
      fs.readFileSync(
        path.join(dir, 'android/app/src', s, 'AndroidManifest.xml'),
        'utf8'
      );
    for (const s of ['debug', 'debugOptimized']) {
      const text = read(s);
      expect(text.match(/android:host="dev\.ciz\.to"/g)).toHaveLength(1);
      expect(text).toContain('android:usesCleartextTraffic="true"'); // existing attributes kept
      expect(text).toContain('<activity android:name=".MainActivity">');
    }
    expect(read('main')).not.toContain('dev.ciz.to');
  });

  it('Android: creates src/debug/AndroidManifest.xml when missing', () => {
    const m = addDebugAppLink(null, '.MainActivity', 'dev.ciz.to');
    const activity = (
      m.manifest.application?.[0] as AndroidConfig.Manifest.ManifestApplication
    ).activity?.[0];
    expect(activity?.$['android:name']).toBe('.MainActivity');
    expect(activity?.['intent-filter']?.[0]?.$).toEqual({
      'android:autoVerify': 'true',
    });
    expect(addDebugAppLink(m, '.MainActivity', 'dev.ciz.to')).toEqual(m);
  });

  it('iOS: a Debug entitlements copy plus the test domain, linked for Debug only (idempotent)', async () => {
    const dir = copyPrebuild();
    const releasePath = path.join(
      dir,
      'ios/exponative/exponative.entitlements'
    );
    fs.writeFileSync(
      releasePath,
      '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n  <dict>\n    <key>aps-environment</key>\n    <string>development</string>\n    <key>com.apple.developer.associated-domains</key>\n    <array>\n      <string>applinks:go.acme.com</string>\n    </array>\n  </dict>\n</plist>'
    );
    const config = withClikgate(baseConfig(), {
      linkDomains: ['go.acme.com'],
      testLinkDomain: 'dev.ciz.to',
    });
    await runFinalized(config, 'ios', dir);
    await runFinalized(config, 'ios', dir);
    const debugPath = debugEntitlementsPath(releasePath);
    expect(path.basename(debugPath)).toBe('exponativeDebug.entitlements');
    const debug = fs.readFileSync(debugPath, 'utf8');
    expect(debug).toContain('<key>aps-environment</key>');
    expect(debug.match(/applinks:dev\.ciz\.to/g)).toHaveLength(1);
    expect(debug).toContain('<string>applinks:go.acme.com</string>');
    expect(fs.readFileSync(releasePath, 'utf8')).not.toContain('dev.ciz.to');
    const pbx = fs.readFileSync(
      path.join(dir, 'ios/exponative.xcodeproj/project.pbxproj'),
      'utf8'
    );
    expect(
      pbx.match(
        /CODE_SIGN_ENTITLEMENTS = exponative\/exponativeDebug\.entitlements;/g
      )
    ).toHaveLength(1);
    expect(
      pbx.match(
        /CODE_SIGN_ENTITLEMENTS = exponative\/exponative\.entitlements;/g
      )
    ).toHaveLength(1);
  });

  it('plist text edit handles <dict/>, an existing array and a missing key', () => {
    const empty = '<plist version="1.0">\n  <dict/>\n</plist>';
    expect(addApplinksToPlistText(empty, 'dev.ciz.to')).toBe(
      '<plist version="1.0">\n  <dict>\n    <key>com.apple.developer.associated-domains</key>\n    <array>\n      <string>applinks:dev.ciz.to</string>\n    </array>\n  </dict>\n</plist>'
    );
    const other =
      '<plist version="1.0">\n  <dict>\n    <key>aps-environment</key>\n    <string>development</string>\n  </dict>\n</plist>';
    expect(addApplinksToPlistText(other, 'dev.ciz.to')).toContain(
      '<string>development</string>\n    <key>com.apple.developer.associated-domains</key>'
    );
    const once = addApplinksToPlistText(empty, 'dev.ciz.to');
    expect(addApplinksToPlistText(once, 'dev.ciz.to')).toBe(once);
  });

  it('adds no extra mods when testLinkDomain is not set', () => {
    const config = withClikgate(baseConfig(), { linkDomains: ['go.acme.com'] });
    expect(Object.keys((config.mods as Record<string, object>).ios)).toEqual([
      'entitlements',
      'appDelegate',
      'infoPlist',
    ]);
  });
});

describe('automaticPushToken (iOS uninstall tracking)', () => {
  const expoSwift = `internal import Expo
import React
import ReactAppDependencyProvider

@main
class AppDelegate: ExpoAppDelegate {
  var window: UIWindow?

  public override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

class ReactNativeDelegate: ExpoReactNativeFactoryDelegate {
  override func bundleURL() -> URL? {
    return nil
  }
}
`;

  const expoObjc = `#import "AppDelegate.h"

#import <React/RCTBundleURLProvider.h>
#import <React/RCTLinkingManager.h>

@implementation AppDelegate

// Explicitly define remote notification delegates to ensure compatibility with some third-party libraries
- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
  return [super application:application didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];
}

@end
`;

  it('adds aps-environment (development) unless the app sets it', async () => {
    const config = withClikgate(baseConfig(), {});
    expect(await runMod(config, 'ios', 'entitlements', {})).toEqual({
      'aps-environment': 'development',
    });
    expect(addApsEnvironment({ 'aps-environment': 'production' })).toEqual({
      'aps-environment': 'production',
    });
  });

  it('Swift (ExpoAppDelegate): adds a public override that calls super, once', async () => {
    const config = withClikgate(baseConfig(), {});
    const out = await runMod(config, 'ios', 'appDelegate', {
      language: 'swift',
      contents: expoSwift,
      path: 'AppDelegate.swift',
    });
    const text = (out as { contents: string }).contents;
    expect(text).toContain(
      '  public override func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {\n    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)\n    ClikgateRN.setPushToken(deviceToken: deviceToken)\n  }'
    );
    expect(text).toMatch(/^import ClikgateReactNative$/m);
    // inside AppDelegate, not ReactNativeDelegate
    expect(text.indexOf('didRegisterForRemoteNotifications')).toBeLessThan(
      text.indexOf('class ReactNativeDelegate')
    );
    expect(addPushTokenForwardSwift(text)).toBe(text);
    expect(forwardsPushToken(text)).toBe(true);
  });

  it('Swift: adds the line to an existing method', () => {
    const src = `import UIKit\n\nclass AppDelegate: UIResponder, UIApplicationDelegate {\n  func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {\n    Other.register(token)\n  }\n}\n`;
    const text = addPushTokenForwardSwift(src);
    expect(text).toContain('ClikgateRN.setPushToken(deviceToken: token)');
    expect(
      text.match(/didRegisterForRemoteNotificationsWithDeviceToken/g)
    ).toHaveLength(1);
  });

  it('Objective-C (Expo SDK 52 template): adds the line to the existing method and the header', async () => {
    const config = withClikgate(baseConfig(), {});
    const out = await runMod(config, 'ios', 'appDelegate', {
      language: 'objcpp',
      contents: expoObjc,
      path: 'AppDelegate.mm',
    });
    const text = (out as { contents: string }).contents;
    expect(text).toContain(
      '{\n  // @clikgate/react-native:push-token start\n  [ClikgateRN setPushTokenWithDeviceToken:deviceToken];'
    );
    expect(text).toContain(
      '#import <ClikgateReactNative/ClikgateReactNative-Swift.h>'
    );
    expect(addPushTokenForwardObjc(text)).toBe(text);
  });

  it('Objective-C: adds the method before @end when missing', () => {
    const text = addPushTokenForwardObjc(
      '#import "AppDelegate.h"\n\n@implementation AppDelegate\n\n@end\n'
    );
    expect(text).toContain('instancesRespondToSelector:_cmd');
    expect(
      text.indexOf('[ClikgateRN setPushTokenWithDeviceToken:deviceToken];')
    ).toBeLessThan(text.indexOf('@end'));
  });

  it('automaticPushToken: false adds neither', () => {
    const config = withClikgate(baseConfig(), { automaticPushToken: false });
    expect(Object.keys((config.mods as Record<string, object>).ios)).toEqual([
      'entitlements',
      'infoPlist',
    ]);
  });
});
