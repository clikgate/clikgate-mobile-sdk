// Single source of truth for names, versions and domains the setup command writes into projects.
// Package coordinates and versions must equal the SDKs in this repository (android/gradle.properties,
// ios/Clikgate.podspec, flutter/pubspec.yaml, react-native/package.json): scripts/check_cli_sdk_versions.mjs
// fails when they drift. See cli/DECISIONS.md.

import type { Platform } from './args';

export const CLI_VERSION = '1.1.1';

export const DEFAULT_API_URL = 'https://api.clikgate.com';
export const DASHBOARD_URL = 'https://app.clikgate.com';
export const DOCS_URL = 'https://clikgate.com/docs/setup-command';

/** The shared test link domain. Apps never declare it: debug builds get `<link_subdomain>.dev.ciz.to`. */
export const TEST_LINK_DOMAIN = 'dev.ciz.to';
/** Parent of every app's live link subdomain on Starter and up (`<link_subdomain>.ciz.to`, change 09 N.1). */
export const APP_LINK_PARENT = 'ciz.to';
/** Parent of an app's live link subdomain on the Free plan (`<link_subdomain>.clk.ng`, change 10 D.1). */
export const FREE_APP_LINK_PARENT = 'clk.ng';
/** Parents an app's live link subdomain can have. `clk.ng` itself is a shared domain; `yourapp.clk.ng` is not. */
export const APP_LINK_PARENTS = [APP_LINK_PARENT, FREE_APP_LINK_PARENT] as const;
/**
 * Clikgate's shared platform domains (change 09 N.1): many organisations' links live on them, so their
 * AASA / assetlinks list no customer app and they can't open one. Never written into a project; doctor
 * warns when a project still declares one.
 */
export const SHARED_PLATFORM_DOMAINS = ['ciz.to', 'clk.ng', 'clkg.to', TEST_LINK_DOMAIN];
export const SHARED_DOMAIN_FIX = "remove this: shared domains can't open your app";

/**
 * `yourapp.ciz.to` (live; `yourapp.clk.ng` on Free) → `yourapp.dev.ciz.to` (debug builds, every plan).
 * Only a fallback: the server's `link_hostnames` / `app_link_domains` say which parent the plan uses.
 */
export function appLinkHosts(subdomain: string, parent: string = APP_LINK_PARENT): { live: string; test: string } {
  return { live: `${subdomain}.${parent}`, test: `${subdomain}.${TEST_LINK_DOMAIN}` };
}

/** The parent (`ciz.to` or `clk.ng`) of an app's live link host, else `ciz.to`. */
export function appLinkParentOf(liveHost: string | undefined): string {
  return APP_LINK_PARENTS.find((p) => liveHost?.toLowerCase().endsWith(`.${p}`)) ?? APP_LINK_PARENT;
}

/** A test host: an app's `<sub>.dev.ciz.to`, or the shared `dev.ciz.to` itself. */
export function isTestHost(host: string): boolean {
  return host === TEST_LINK_DOMAIN || host.endsWith(`.${TEST_LINK_DOMAIN}`);
}

/**
 * The app subdomain of a `<sub>.ciz.to` or (Free, change 10) `<sub>.clk.ng` host (not `<sub>.dev.ciz.to`),
 * else undefined.
 */
export function appSubdomainOf(host: string): string | undefined {
  const m = /^([a-z0-9](?:[a-z0-9-]{1,28}[a-z0-9])?)\.(?:ciz\.to|clk\.ng)$/.exec(host);
  return m && m[1] !== 'dev' ? m[1] : undefined;
}

export const MARKER_START = 'clikgate-setup:start';
export const MARKER_END = 'clikgate-setup:end';

export const SDK = {
  flutter: { package: 'clikgate_flutter', constraint: '^1.5.1', minimum: '1.5.1' },
  reactNative: { package: '@clikgate/react-native', constraint: '^1.6.1', minimum: '1.6.1' },
  android: { group: 'com.clikgate', artifact: 'clikgate-android', version: '1.5.1' },
  ios: { pod: 'Clikgate', podConstraint: '~> 1.5', spm: 'https://github.com/clikgate/clikgate-ios-sdk', version: '1.5.1' },
} as const;

/**
 * The "Next steps" goal example per project type: one goal() method with the Provider enum. On a Payment goal
 * the app only reports the payment (provider and reference); it counts when the provider or server confirms it.
 */
export const GOAL_SNIPPET: Record<Platform, string> = {
  android: 'Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK)',
  ios: 'Clikgate.shared.goal("purchase", reference: "T123456", provider: .paystack)',
  flutter: "Clikgate.goal('purchase', reference: 'T123456', provider: ClikgateProvider.paystack)",
  'react-native': "Clikgate.goal('purchase', { reference: 'T123456', provider: ClikgateProvider.Paystack })",
  expo: "Clikgate.goal('purchase', { reference: 'T123456', provider: ClikgateProvider.Paystack })",
};

/**
 * Change 22 (I.2, I.8): identifying signed-in users. Path A (the default): the business's server returns an identity
 * token made with the server SDK's createIdentityToken (secret in CLIKGATE_IDENTITY_SECRET, server only) and the app
 * passes it to identifyUser(). Path B: the app sends getInstallationId() to its own server, which calls identifyUser.
 */
export const IDENTIFY_GUIDE_URL = 'https://clikgate.com/docs/identify-users';
export const IDENTIFY_SNIPPET: Record<Platform, string> = {
  android: 'Clikgate.identifyUser(customerId = user.id, identityToken = response.clikgateToken)',
  ios: 'Clikgate.shared.identifyUser(customerId: user.id, identityToken: response.clikgateToken)',
  flutter: 'Clikgate.identifyUser(customerId: user.id, identityToken: response.clikgateToken)',
  'react-native': 'Clikgate.identifyUser({ customerId: user.id, identityToken: response.clikgateToken })',
  expo: 'Clikgate.identifyUser({ customerId: user.id, identityToken: response.clikgateToken })',
};
export const INSTALLATION_ID_SNIPPET: Record<Platform, string> = {
  android: 'Clikgate.getInstallationId()',
  ios: 'try await Clikgate.shared.installationId()',
  flutter: 'await Clikgate.getInstallationId()',
  'react-native': 'await Clikgate.getInstallationId()',
  expo: 'await Clikgate.getInstallationId()',
};

// ------------------------------------------------------------------- websites (change 16 S, R.1–R.2)

/** The web script's URL, as in the dashboard's snippet. */
export const WEB_SCRIPT_URL = 'https://sdk.clikgate.com/v1/static/clikgate.js';
/** The keep route on the business's own server (the web script's `data-server-endpoint`). */
export const KEEP_ROUTE_PATH = '/cg/keep';
/** A publishable web key. Not secret; never an API key (`cg_live_…`) or SDK key in a page. */
export const WEB_KEY = /^cgw_(test|live)_[A-Za-z0-9_-]+$/;
export const WEB_KEY_PLACEHOLDER = 'cgw_test_REPLACE_ME';
/** Honest wording only (change 16 D1, docs): never "never lost", "forever" or "guaranteed". */
export const SAFARI_NOTE =
  "Safari, and every browser on iPhone, keeps a click ID saved by a script for up to 7 days (sometimes less). When your server saves it, it lasts as long as you choose, up to the browser's limit.";

/**
 * Server SDK packages for the keep route. The command never writes these into a project (it adds only the mobile
 * SDKs); it prints the install command. No versions here: the keep route ships in each server SDK's next minor
 * (after 1.1.0). If a minimum version is ever written or checked, add it here and to check_cli_sdk_versions.mjs.
 */
export const SERVER_SDK = {
  node: '@clikgate/node',
  python: 'clikgate',
  laravel: 'clikgate/clikgate-laravel',
  springBoot: 'com.clikgate:clikgate-spring-boot-starter',
  dotnet: 'Clikgate.AspNetCore',
} as const;

export const SUCCESS_LINE = 'Clikgate sees every click. Setup complete.';

export const EXIT = { OK: 0, PROBLEMS: 1, CANCELLED: 2, SIGN_IN_FAILED: 3 } as const;

export const SDK_KEY_TEST = /^cg_sdk_test_[A-Za-z0-9_-]+$/;
export const SDK_KEY_LIVE = /^cg_sdk_live_[A-Za-z0-9_-]+$/;
/** Any Clikgate SDK key as it appears in source code. */
export const SDK_KEY_ANY = /cg_sdk_(test|live)_[A-Za-z0-9_-]+/;

export function maskKey(key: string): string {
  const m = /^(cg_sdk_(?:test|live)_)(.*)$/.exec(key);
  if (!m) return '••••';
  return `${m[1]}${m[2].slice(0, 4)}…`;
}
