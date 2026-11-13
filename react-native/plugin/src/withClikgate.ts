import {
  AndroidConfig,
  IOSConfig,
  createRunOncePlugin,
  withAndroidManifest,
  withAppDelegate,
  withEntitlementsPlist,
  withFinalizedMod,
  withInfoPlist,
  type ConfigPlugin,
} from '@expo/config-plugins';
import fs from 'fs';
import path from 'path';

const pkg: { name: string; version: string } = require('../../package.json');

/** Props of the `@clikgate/react-native` Expo config plugin. */
export interface ClikgatePluginProps {
  /**
   * Clikgate link domains (e.g. `["yourapp.ciz.to", "go.myapp.com"]`: your app's link subdomain and
   * your verified custom domains): iOS `applinks:` associated domains and Android App Link intent
   * filters with `android:autoVerify="true"`. Pass the same domains to
   * `Clikgate.configure({ linkDomains })`. Never a shared domain (`ciz.to`, `clk.ng`, `clkg.to`,
   * `dev.ciz.to`): shared domains can't open your app.
   */
  linkDomains?: string[];
  /**
   * Your app's test link subdomain (`"yourapp.dev.ciz.to"`), added to **development builds only**:
   * - always to Android debug builds (`app/src/debug/AndroidManifest.xml`, and other existing
   *   debug-based source sets such as `debugOptimized`) and to the iOS **Debug** configuration
   *   (a separate `<Target>Debug.entitlements` linked with `CODE_SIGN_ENTITLEMENTS`);
   * - to every build when the build variant is one of `testVariants`: `APP_VARIANT` (Expo's
   *   documented variant variable, set per profile in `eas.json`), else `EAS_BUILD_PROFILE`.
   * Release builds of other variants (`production`) never get it.
   */
  testLinkDomain?: string;
  /** Build variants (APP_VARIANT / EAS build profile) whose builds all get `testLinkDomain`. Default `["development", "preview"]`. */
  testVariants?: string[];
  /** Custom URL scheme for the interstitial's "Open in app" button (e.g. `"myapp"`). */
  uriScheme?: string;
  /**
   * iOS: add `remote-notification` to `UIBackgroundModes` so Clikgate's silent uninstall checks
   * can wake the app. Default `true`.
   */
  enableBackgroundRemoteNotifications?: boolean;
  /**
   * iOS: add `whatsapp` to `LSApplicationQueriesSchemes` (for apps that use the Engage features'
   * `share.whatsApp`, or check `Linking.canOpenURL('whatsapp://')` themselves). Optional: Engage
   * opens `whatsapp://send` without a `canOpenURL` check. Default `true`.
   */
  enableWhatsAppSharing?: boolean;
  /**
   * iOS uninstall tracking with the SDK's `automaticPushToken` (default on): adds the Push
   * Notifications capability (`aps-environment`, `development` unless already set, as
   * expo-notifications does; Xcode writes the distribution value when you export) and the one line
   * that passes the APNs token to Clikgate in the AppDelegate's
   * `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Users are never asked for
   * notification permission. Default `true`; `false` leaves both to you.
   */
  automaticPushToken?: boolean;
}

type InfoPlist = Record<string, unknown> & {
  CFBundleURLTypes?: {
    CFBundleURLSchemes: string[];
    CFBundleURLName?: string;
  }[];
  UIBackgroundModes?: string[];
  LSApplicationQueriesSchemes?: string[];
};
type Entitlements = Record<string, unknown>;
type IntentFilter = AndroidConfig.Manifest.ManifestIntentFilter;

const ASSOCIATED_DOMAINS = 'com.apple.developer.associated-domains';
const VIEW = 'android.intent.action.VIEW';
const DEFAULT = 'android.intent.category.DEFAULT';
const BROWSABLE = 'android.intent.category.BROWSABLE';

// ------------------------------------------------------------------ validation

function normaliseHost(d: string): string {
  return d
    .trim()
    .replace(/^https?:\/\//i, '')
    .replace(/^applinks:/i, '')
    .replace(/\/.*$/, '')
    .toLowerCase();
}

/** The build variant: `APP_VARIANT` (Expo's convention), else EAS Build's `EAS_BUILD_PROFILE`. */
export function buildVariant(
  env: Record<string, string | undefined> = process.env
): string | undefined {
  return env.APP_VARIANT || env.EAS_BUILD_PROFILE || undefined;
}

/** True when every build of this variant should get the test link domain. */
export function isTestVariant(
  variants: string[],
  env: Record<string, string | undefined> = process.env
): boolean {
  const v = buildVariant(env);
  return v !== undefined && variants.includes(v);
}

/** Normalises and validates the plugin props (throws on invalid input). */
export function resolveProps(
  props: ClikgatePluginProps | void | null
): Required<ClikgatePluginProps> {
  const p = props ?? {};
  if (p.linkDomains != null && !Array.isArray(p.linkDomains)) {
    throw new Error(
      '[@clikgate/react-native] linkDomains must be an array of host names'
    );
  }
  const linkDomains = Array.from(
    new Set(
      (p.linkDomains ?? []).map((d) => {
        if (typeof d !== 'string') {
          throw new Error(
            '[@clikgate/react-native] linkDomains must be an array of host names'
          );
        }
        const host = normaliseHost(d);
        if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(host)) {
          throw new Error(
            `[@clikgate/react-native] Invalid link domain "${d}" (expected e.g. inv.myapp.com)`
          );
        }
        return host;
      })
    )
  );
  let testLinkDomain = '';
  if (p.testLinkDomain != null && p.testLinkDomain !== '') {
    if (typeof p.testLinkDomain !== 'string') {
      throw new Error(
        '[@clikgate/react-native] testLinkDomain must be a host name'
      );
    }
    testLinkDomain = normaliseHost(p.testLinkDomain);
    if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(testLinkDomain)) {
      throw new Error(
        `[@clikgate/react-native] Invalid testLinkDomain "${p.testLinkDomain}" (expected e.g. yourapp.dev.ciz.to)`
      );
    }
    if (linkDomains.includes(testLinkDomain)) {
      throw new Error(
        `[@clikgate/react-native] ${testLinkDomain} is in linkDomains: list it only as testLinkDomain so release builds don't get it`
      );
    }
  }
  if (
    p.testVariants != null &&
    (!Array.isArray(p.testVariants) ||
      p.testVariants.some((v) => typeof v !== 'string'))
  ) {
    throw new Error(
      '[@clikgate/react-native] testVariants must be an array of strings'
    );
  }
  let uriScheme = '';
  if (p.uriScheme != null && p.uriScheme !== '') {
    if (typeof p.uriScheme !== 'string') {
      throw new Error('[@clikgate/react-native] uriScheme must be a string');
    }
    uriScheme = p.uriScheme.trim().replace(/:\/*$/, '');
    if (!/^[a-zA-Z][a-zA-Z0-9+.-]*$/.test(uriScheme)) {
      throw new Error(
        `[@clikgate/react-native] Invalid uriScheme "${p.uriScheme}" (expected e.g. myapp)`
      );
    }
  }
  return {
    linkDomains,
    testLinkDomain,
    testVariants: p.testVariants ?? ['development', 'preview'],
    uriScheme,
    enableBackgroundRemoteNotifications:
      p.enableBackgroundRemoteNotifications !== false,
    enableWhatsAppSharing: p.enableWhatsAppSharing !== false,
    automaticPushToken: p.automaticPushToken !== false,
  };
}

// ------------------------------------------------------------------ iOS

/** Adds `applinks:<domain>` for each domain (keeps existing entries, no duplicates). */
export function addAssociatedDomains(
  entitlements: Entitlements,
  domains: string[]
): Entitlements {
  if (domains.length === 0) return entitlements;
  const existing = Array.isArray(entitlements[ASSOCIATED_DOMAINS])
    ? (entitlements[ASSOCIATED_DOMAINS] as string[])
    : [];
  const next = [...existing];
  for (const d of domains) {
    const entry = `applinks:${d}`;
    if (!next.includes(entry)) next.push(entry);
  }
  return { ...entitlements, [ASSOCIATED_DOMAINS]: next };
}

/** Adds `remote-notification` to `UIBackgroundModes`. */
export function addRemoteNotificationBackgroundMode<
  T extends Record<string, unknown>,
>(infoPlist: T): T {
  const modes = Array.isArray(infoPlist.UIBackgroundModes)
    ? (infoPlist.UIBackgroundModes as string[])
    : [];
  if (modes.includes('remote-notification')) return infoPlist;
  return { ...infoPlist, UIBackgroundModes: [...modes, 'remote-notification'] };
}

/** Adds `scheme` to `LSApplicationQueriesSchemes` (keeps existing entries, no duplicates). */
export function addQueriesScheme<T extends Record<string, unknown>>(
  infoPlist: T,
  scheme: string
): T {
  const schemes = Array.isArray(infoPlist.LSApplicationQueriesSchemes)
    ? (infoPlist.LSApplicationQueriesSchemes as string[])
    : [];
  if (schemes.includes(scheme)) return infoPlist;
  return { ...infoPlist, LSApplicationQueriesSchemes: [...schemes, scheme] };
}

/** Adds a `CFBundleURLTypes` entry for the scheme unless one already lists it. */
export function addUrlScheme<T extends Record<string, unknown>>(
  infoPlist: T,
  scheme: string
): T {
  if (!scheme) return infoPlist;
  const types = Array.isArray(infoPlist.CFBundleURLTypes)
    ? (infoPlist.CFBundleURLTypes as { CFBundleURLSchemes?: string[] }[])
    : [];
  if (types.some((t) => (t.CFBundleURLSchemes ?? []).includes(scheme)))
    return infoPlist;
  return {
    ...infoPlist,
    CFBundleURLTypes: [...types, { CFBundleURLSchemes: [scheme] }],
  };
}

// ------------------------------------------------------------------ iOS push token (uninstall tracking)

const APS_ENVIRONMENT = 'aps-environment';
const MARK_START = '// @clikgate/react-native:push-token start';
const MARK_END = '// @clikgate/react-native:push-token end';
const SWIFT_LINE = 'ClikgateRN.setPushToken(deviceToken: deviceToken)';
const OBJC_LINE = '[ClikgateRN setPushTokenWithDeviceToken:deviceToken];';

/** Adds `aps-environment` (Push Notifications capability) unless the app already sets it. */
export function addApsEnvironment(
  entitlements: Entitlements,
  value: 'development' | 'production' = 'development'
): Entitlements {
  if (typeof entitlements[APS_ENVIRONMENT] === 'string') return entitlements;
  return { ...entitlements, [APS_ENVIRONMENT]: value };
}

/** True when the AppDelegate already passes the APNs token to Clikgate. */
export function forwardsPushToken(contents: string): boolean {
  return (
    /setPushToken\s*\(\s*deviceToken\s*:/.test(contents) ||
    /setPushTokenWithDeviceToken\s*:/.test(contents)
  );
}

/** Offset of the `}` matching the `{` at `open` (skips strings and comments), or -1. */
function matchingBrace(text: string, open: number): number {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    const c = text[i];
    const n = text[i + 1];
    if (c === '/' && n === '/') {
      const e = text.indexOf('\n', i);
      if (e < 0) return -1;
      i = e;
      continue;
    }
    if (c === '/' && n === '*') {
      const e = text.indexOf('*/', i + 2);
      if (e < 0) return -1;
      i = e + 1;
      continue;
    }
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"' && text[j] !== '\n')
        j += text[j] === '\\' ? 2 : 1;
      i = j;
      continue;
    }
    if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

function lineStartOf(text: string, offset: number): number {
  return text.lastIndexOf('\n', offset - 1) + 1;
}

function indentOf(text: string, offset: number): string {
  return /^[ \t]*/.exec(text.slice(lineStartOf(text, offset)))![0];
}

/** Inserts `lines` (already indented) right after the `{` at `open`. */
function insertAfterBrace(text: string, open: number, lines: string[]): string {
  const eol = text.indexOf('\n', open);
  const at = eol < 0 ? text.length : eol;
  return `${text.slice(0, at)}\n${lines.join('\n')}${text.slice(at)}`;
}

function addImport(text: string, line: string, pattern: RegExp): string {
  if (text.includes(line)) return text;
  let end = -1;
  for (const m of text.matchAll(pattern)) {
    const e = text.indexOf('\n', m.index!);
    end = Math.max(end, e < 0 ? text.length : e);
  }
  if (end < 0) return `${line}\n${text}`;
  return `${text.slice(0, end)}\n${line}${text.slice(end)}`;
}

/**
 * Swift AppDelegate (Expo SDK 53+: `class AppDelegate: ExpoAppDelegate`): the forward line in
 * `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`, adding that method (a
 * `public override` that calls `super` for `ExpoAppDelegate`) when missing. Idempotent.
 */
export function addPushTokenForwardSwift(contents: string): string {
  if (forwardsPushToken(contents)) return contents;
  let out: string;
  const fn =
    /func\s+application\s*\(\s*_\s+[A-Za-z0-9_]+\s*:\s*UIApplication\s*,\s*didRegisterForRemoteNotificationsWithDeviceToken\s+([A-Za-z0-9_]+)\s*:\s*Data\s*\)\s*\{/.exec(
      contents
    );
  if (fn) {
    const open = fn.index + fn[0].length - 1;
    const indent = indentOf(contents, fn.index) + '  ';
    out = insertAfterBrace(contents, open, [
      `${indent}${MARK_START}`,
      `${indent}ClikgateRN.setPushToken(deviceToken: ${fn[1]})`,
      `${indent}${MARK_END}`,
    ]);
  } else {
    const cls =
      /class\s+AppDelegate\s*:([^{]*)\{/.exec(contents) ??
      /class\s+[A-Za-z0-9_]+\s*:([^{]*\b(?:ExpoAppDelegate|UIApplicationDelegate|RCTAppDelegate)\b[^{]*)\{/.exec(
        contents
      );
    if (!cls)
      throw new Error(
        `[@clikgate/react-native] No AppDelegate class found: add ${SWIFT_LINE} to application(_:didRegisterForRemoteNotificationsWithDeviceToken:) yourself, or set automaticPushToken: false`
      );
    const open = cls.index + cls[0].length - 1;
    const close = matchingBrace(contents, open);
    if (close < 0)
      throw new Error(
        '[@clikgate/react-native] Could not read the AppDelegate class'
      );
    const expo = /\bExpoAppDelegate\b/.test(cls[1] ?? '');
    const i = indentOf(contents, cls.index) + '  ';
    const method = [
      '',
      `${i}${MARK_START}`,
      `${i}${expo ? 'public override ' : ''}func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {`,
      ...(expo
        ? [
            `${i}  super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)`,
          ]
        : []),
      `${i}  ${SWIFT_LINE}`,
      `${i}}`,
      `${i}${MARK_END}`,
    ].join('\n');
    const at = lineStartOf(contents, close);
    out = `${contents.slice(0, at).replace(/\n*$/, '')}\n${method}\n${contents.slice(at)}`;
  }
  return addImport(
    out,
    'import ClikgateReactNative',
    /^(?:internal\s+|public\s+|@_exported\s+)?import\s+[A-Za-z]/gm
  );
}

/** Objective-C AppDelegate (`AppDelegate.mm`, Expo SDK 52 and older): the same forward. */
export function addPushTokenForwardObjc(contents: string): string {
  if (forwardsPushToken(contents)) return contents;
  let out: string;
  const fn =
    /-\s*\(\s*void\s*\)\s*application\s*:\s*\(\s*UIApplication\s*\*\s*\)\s*[A-Za-z0-9_]+\s+didRegisterForRemoteNotificationsWithDeviceToken\s*:\s*\(\s*NSData\s*\*\s*\)\s*([A-Za-z0-9_]+)\s*\{/.exec(
      contents
    );
  if (fn) {
    out = insertAfterBrace(contents, fn.index + fn[0].length - 1, [
      `  ${MARK_START}`,
      `  [ClikgateRN setPushTokenWithDeviceToken:${fn[1]}];`,
      `  ${MARK_END}`,
    ]);
  } else {
    const impl = /^@implementation\s+AppDelegate\b.*$/m.exec(contents);
    const end = impl ? /^@end\b/m.exec(contents.slice(impl.index)) : null;
    if (!impl || !end)
      throw new Error(
        `[@clikgate/react-native] No @implementation AppDelegate found: add ${OBJC_LINE} to application:didRegisterForRemoteNotificationsWithDeviceToken: yourself, or set automaticPushToken: false`
      );
    const at = impl.index + end.index;
    const method = [
      MARK_START,
      '- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken',
      '{',
      '  if ([[self superclass] instancesRespondToSelector:_cmd]) {',
      '    [super application:application didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];',
      '  }',
      `  ${OBJC_LINE}`,
      '}',
      MARK_END,
      '',
    ].join('\n');
    out = `${contents.slice(0, at)}${method}\n${contents.slice(at)}`;
  }
  const header = [
    '#if __has_include(<ClikgateReactNative/ClikgateReactNative-Swift.h>)',
    '#import <ClikgateReactNative/ClikgateReactNative-Swift.h>',
    '#else',
    '#import "ClikgateReactNative-Swift.h"',
    '#endif',
  ].join('\n');
  if (out.includes('ClikgateReactNative-Swift.h')) return out;
  return addImport(out, header, /^#import\s+[<"]/gm);
}

// ------------------------------------------------------------------ Android

function hasAction(f: IntentFilter, name: string) {
  return (f.action ?? []).some((a) => a.$?.['android:name'] === name);
}

function dataValues(f: IntentFilter, attr: 'android:scheme' | 'android:host') {
  return (f.data ?? [])
    .map((d) => d.$?.[attr])
    .filter((v): v is string => typeof v === 'string');
}

function viewFilter(
  data: Record<string, string>[],
  autoVerify: boolean
): IntentFilter {
  return {
    ...(autoVerify ? { $: { 'android:autoVerify': 'true' as const } } : {}),
    action: [{ $: { 'android:name': VIEW } }],
    category: [
      { $: { 'android:name': DEFAULT } },
      { $: { 'android:name': BROWSABLE } },
    ],
    data: data.map((d) => ({ $: d })),
  };
}

/**
 * Adds to the main activity one verified App Link filter (`https` + host, `autoVerify="true"`)
 * per domain and a filter for the custom scheme, unless equivalent filters already exist.
 */
export function addAndroidIntentFilters(
  manifest: AndroidConfig.Manifest.AndroidManifest,
  options: { linkDomains: string[]; uriScheme: string }
): AndroidConfig.Manifest.AndroidManifest {
  const activity = AndroidConfig.Manifest.getMainActivityOrThrow(manifest);
  const filters: IntentFilter[] = activity['intent-filter'] ?? [];

  for (const host of options.linkDomains) {
    const exists = filters.some(
      (f) =>
        hasAction(f, VIEW) &&
        f.$?.['android:autoVerify'] === 'true' &&
        dataValues(f, 'android:scheme').includes('https') &&
        dataValues(f, 'android:host').includes(host)
    );
    if (!exists) {
      filters.push(
        viewFilter(
          [{ 'android:scheme': 'https' }, { 'android:host': host }],
          true
        )
      );
    }
  }

  const scheme = options.uriScheme;
  if (scheme) {
    const exists = filters.some(
      (f) =>
        hasAction(f, VIEW) && dataValues(f, 'android:scheme').includes(scheme)
    );
    if (!exists)
      filters.push(viewFilter([{ 'android:scheme': scheme }], false));
  }

  activity['intent-filter'] = filters;
  return manifest;
}

// ------------------------------------------------------------------ test link domain (debug builds)

const ANDROID_NS = 'http://schemas.android.com/apk/res/android';

/** Debug-based Android source sets: `debug`, `debugOptimized`, `<flavor>Debug`. */
export function isDebugSourceSet(name: string): boolean {
  return /^debug/.test(name) || /Debug/.test(name);
}

/**
 * Adds a verified App Link filter for `host` to `activityName` in a debug-only manifest (merged
 * into the main one by the Android build). Creates `<application>` / `<activity>` as needed.
 */
export function addDebugAppLink(
  manifest: AndroidConfig.Manifest.AndroidManifest | null,
  activityName: string,
  host: string
): AndroidConfig.Manifest.AndroidManifest {
  const m: AndroidConfig.Manifest.AndroidManifest =
    manifest ??
    ({
      manifest: { $: { 'xmlns:android': ANDROID_NS } },
    } as AndroidConfig.Manifest.AndroidManifest);
  const root =
    m.manifest as AndroidConfig.Manifest.AndroidManifest['manifest'] & {
      $: Record<string, string>;
    };
  root.$ = {
    ...(root.$ ?? {}),
    'xmlns:android': root.$?.['xmlns:android'] ?? ANDROID_NS,
  };
  if (!root.application || root.application.length === 0) {
    root.application = [
      { $: {} } as AndroidConfig.Manifest.ManifestApplication,
    ];
  }
  const app = root.application[0] as AndroidConfig.Manifest.ManifestApplication;
  app.activity = app.activity ?? [];
  let activity = app.activity.find(
    (a) => a.$?.['android:name'] === activityName
  );
  if (!activity) {
    activity = {
      $: { 'android:name': activityName },
    } as AndroidConfig.Manifest.ManifestActivity;
    app.activity.push(activity);
  }
  const filters: IntentFilter[] = activity['intent-filter'] ?? [];
  const exists = filters.some(
    (f) =>
      hasAction(f, VIEW) &&
      f.$?.['android:autoVerify'] === 'true' &&
      dataValues(f, 'android:scheme').includes('https') &&
      dataValues(f, 'android:host').includes(host)
  );
  if (!exists)
    filters.push(
      viewFilter(
        [{ 'android:scheme': 'https' }, { 'android:host': host }],
        true
      )
    );
  activity['intent-filter'] = filters;
  return m;
}

async function writeAndroidDebugAppLinks(
  platformProjectRoot: string,
  host: string
): Promise<void> {
  const src = path.join(platformProjectRoot, 'app', 'src');
  const mainPath = path.join(src, 'main', 'AndroidManifest.xml');
  if (!fs.existsSync(mainPath)) return;
  const main = await AndroidConfig.Manifest.readAndroidManifestAsync(mainPath);
  const activityName =
    AndroidConfig.Manifest.getMainActivityOrThrow(main).$['android:name'];
  const sets = new Set(['debug']);
  for (const name of fs.existsSync(src) ? fs.readdirSync(src) : []) {
    if (
      name !== 'main' &&
      isDebugSourceSet(name) &&
      fs.existsSync(path.join(src, name, 'AndroidManifest.xml'))
    )
      sets.add(name);
  }
  for (const name of sets) {
    const file = path.join(src, name, 'AndroidManifest.xml');
    const current = fs.existsSync(file)
      ? await AndroidConfig.Manifest.readAndroidManifestAsync(file)
      : null;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    await AndroidConfig.Manifest.writeAndroidManifestAsync(
      file,
      addDebugAppLink(current, activityName, host)
    );
  }
}

/**
 * Adds `<string>applinks:<host></string>` to an entitlements plist's associated domains (text
 * edit, so the copy keeps every other entitlement exactly as the Release file has it).
 */
export function addApplinksToPlistText(text: string, host: string): string {
  const entry = `applinks:${host}`;
  if (text.includes(`<string>${entry}</string>`)) return text;
  const key = `<key>${ASSOCIATED_DOMAINS}</key>`;
  const k = text.indexOf(key);
  if (k >= 0) {
    const arrOpen = text.indexOf('<array', k);
    const arrSelf = text
      .slice(arrOpen, text.indexOf('>', arrOpen) + 1)
      .endsWith('/>');
    if (arrSelf) {
      const end = text.indexOf('>', arrOpen) + 1;
      return `${text.slice(0, arrOpen)}<array>\n    <string>${entry}</string>\n  </array>${text.slice(end)}`;
    }
    const close = text.indexOf('</array>', arrOpen);
    const lineStart = text.lastIndexOf('\n', close) + 1;
    const indent = text.slice(lineStart, close).match(/^\s*$/)
      ? text.slice(lineStart, close)
      : '';
    return `${text.slice(0, lineStart)}${indent}  <string>${entry}</string>\n${text.slice(lineStart)}`;
  }
  const block = (i: string) =>
    `${i}<key>${ASSOCIATED_DOMAINS}</key>\n${i}<array>\n${i}  <string>${entry}</string>\n${i}</array>\n`;
  const selfDict = /<dict\s*\/>/.exec(text);
  if (selfDict) {
    const lineStart = text.lastIndexOf('\n', selfDict.index) + 1;
    const i = text.slice(lineStart, selfDict.index);
    return `${text.slice(0, selfDict.index)}<dict>\n${block(i + '  ')}${i}</dict>${text.slice(selfDict.index + selfDict[0].length)}`;
  }
  const close = text.lastIndexOf('</dict>');
  if (close < 0)
    throw new Error(
      '[@clikgate/react-native] The entitlements file has no <dict>'
    );
  const lineStart = text.lastIndexOf('\n', close) + 1;
  const i = text.slice(lineStart, close);
  return `${text.slice(0, lineStart)}${block(i + '  ')}${text.slice(lineStart)}`;
}

/** `<dir>/<name>Debug.entitlements` next to the Release entitlements file. */
export function debugEntitlementsPath(releasePath: string): string {
  return path.join(
    path.dirname(releasePath),
    `${path.basename(releasePath, '.entitlements')}Debug.entitlements`
  );
}

/**
 * iOS Debug configuration: a copy of the (final) Release entitlements plus `applinks:<host>`,
 * linked with CODE_SIGN_ENTITLEMENTS on the app target's debug configurations only.
 */
function writeIosDebugEntitlements(projectRoot: string, host: string): void {
  const releasePath = IOSConfig.Entitlements.getEntitlementsPath(projectRoot);
  if (!releasePath) return;
  const iosRoot = path.join(projectRoot, 'ios');
  const debugPath = debugEntitlementsPath(releasePath);
  fs.writeFileSync(
    debugPath,
    addApplinksToPlistText(fs.readFileSync(releasePath, 'utf8'), host)
  );
  const project = IOSConfig.XcodeUtils.getPbxproj(projectRoot);
  const [, target] = IOSConfig.Target.findFirstNativeTarget(project);
  const relative = path.relative(iosRoot, debugPath).split(path.sep).join('/');
  let changed = false;
  for (const [, config] of IOSConfig.XcodeUtils.getBuildConfigurationsForListId(
    project,
    target.buildConfigurationList
  )) {
    const name = IOSConfig.XcodeUtils.unquote(String(config.name));
    if (!/debug/i.test(name)) continue;
    const current = config.buildSettings.CODE_SIGN_ENTITLEMENTS;
    if (
      current !== undefined &&
      IOSConfig.XcodeUtils.unquote(String(current)) === relative
    )
      continue;
    config.buildSettings.CODE_SIGN_ENTITLEMENTS = relative;
    changed = true;
  }
  if (changed) fs.writeFileSync(project.filepath, project.writeSync());
}

// ------------------------------------------------------------------ plugin

const withClikgate: ConfigPlugin<ClikgatePluginProps | void> = (
  config,
  rawProps
) => {
  const props = resolveProps(rawProps);
  // Development/preview variants: every build gets the test domain. Otherwise debug builds only.
  const allBuilds =
    props.testLinkDomain && isTestVariant(props.testVariants)
      ? [...props.linkDomains, props.testLinkDomain]
      : props.linkDomains;

  config = withEntitlementsPlist(config, (c) => {
    c.modResults = addAssociatedDomains(
      c.modResults,
      allBuilds
    ) as typeof c.modResults;
    return c;
  });

  if (props.automaticPushToken) {
    config = withEntitlementsPlist(config, (c) => {
      c.modResults = addApsEnvironment(c.modResults) as typeof c.modResults;
      return c;
    });
    config = withAppDelegate(config, (c) => {
      const { language, contents } = c.modResults;
      if (language === 'swift')
        c.modResults.contents = addPushTokenForwardSwift(contents);
      else if (language === 'objc' || language === 'objcpp')
        c.modResults.contents = addPushTokenForwardObjc(contents);
      return c;
    });
  }

  config = withInfoPlist(config, (c) => {
    let plist = c.modResults as unknown as InfoPlist;
    if (props.enableBackgroundRemoteNotifications)
      plist = addRemoteNotificationBackgroundMode(plist);
    plist = addUrlScheme(plist, props.uriScheme);
    if (props.enableWhatsAppSharing)
      plist = addQueriesScheme(plist, 'whatsapp');
    c.modResults = plist as unknown as typeof c.modResults;
    return c;
  });

  config = withAndroidManifest(config, (c) => {
    c.modResults = addAndroidIntentFilters(c.modResults, {
      linkDomains: allBuilds,
      uriScheme: props.uriScheme,
    });
    return c;
  });

  if (props.testLinkDomain) {
    // Finalized mods run after every other mod has written its file.
    config = withFinalizedMod(config, [
      'android',
      async (c) => {
        await writeAndroidDebugAppLinks(
          c.modRequest.platformProjectRoot,
          props.testLinkDomain
        );
        return c;
      },
    ]);
    config = withFinalizedMod(config, [
      'ios',
      async (c) => {
        writeIosDebugEntitlements(
          c.modRequest.projectRoot,
          props.testLinkDomain
        );
        return c;
      },
    ]);
  }

  return config;
};

export default createRunOncePlugin(withClikgate, pkg.name, pkg.version);
