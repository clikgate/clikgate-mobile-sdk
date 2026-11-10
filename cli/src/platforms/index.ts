import * as path from 'node:path';
import type { Platform } from '../args';
import { SDK } from '../constants';
import type { PackageManager } from '../detect';
import { addExpoPlugin, addPackageDependency, findClikgatePlugin, parseJsonc, setExpoValueIfMissing } from '../edit/json';
import { setApplicationName, applicationName } from '../edit/androidManifest';
import { addCatalogEntries, addDependency as addGradleDependency, catalogAliasFor, dependencyLine, hasClikgateDependency } from '../edit/gradle';
import { addDependency as addPubDependency, dependencyConstraint } from '../edit/pubspec';
import {
  editDartMain,
  editJsRoot,
  editKotlinActivity,
  editKotlinApplication,
  editSwiftUIApp,
  editUIKitAppDelegate,
  editUIKitSceneDelegate,
  jsConfigureLines,
  newKotlinApplication,
  type SourceResult,
  type StartupConfig,
} from '../edit/source';
import { exists, read, rel } from '../fsutil';
import { PlanBuilder, type Plan } from '../plan';
import { findClassFile, type AndroidModule } from '../project/android';
import { targetSwiftFiles, type IosProject } from '../project/ios';
import { planAndroidBackup, planAndroidLinks, planIosLinks, type LinkDomains } from './native';
import { which } from '../which';
import { versionAtLeast } from '../doctor';

/** An existing, older constraint is never rewritten: it becomes a manual step. */
function outdated(pb: PlanBuilder, name: string, current: string, wanted: string, minimum: string, file: string): void {
  if (versionAtLeast(current, minimum) === false) {
    pb.manual(`Update ${name}`, `${file} has ${name} ${current}; this setup needs ${minimum} or newer. Change it to ${wanted} and reinstall.`);
  }
}

export interface PlanContext {
  root: string;
  platform: Platform;
  startup: StartupConfig;
  links: LinkDomains;
  android?: AndroidModule;
  ios?: IosProject;
  packageManager: PackageManager;
  /** Expo: the app config file (app.json, or app.config.js/ts which is never edited). */
  appConfig?: string;
  /** Expo: identifiers to write into app.json when missing (asked during app matching). */
  expoIds?: { androidPackage?: string; iosBundleId?: string };
  install: boolean;
}

function source(pb: PlanBuilder, file: string, result: SourceResult, summary: string, doneLabel: string): void {
  if (result.kind === 'done') pb.done(doneLabel);
  else if (result.kind === 'change') pb.change(file, result.text, summary);
  else pb.manual(doneLabel.replace(/^[^:]+: /, ''), result.reason, result.snippet);
}

function installCommand(pm: PackageManager): string[] {
  return [pm, 'install'];
}

function addJsDependency(pb: PlanBuilder): void {
  const pkg = pb.current('package.json');
  if (pkg === null) return;
  const deps = parseJsonc<{ dependencies?: Record<string, string> }>(pkg).dependencies ?? {};
  if (deps[SDK.reactNative.package]) {
    pb.done(`${SDK.reactNative.package} dependency`);
    outdated(pb, SDK.reactNative.package, deps[SDK.reactNative.package], SDK.reactNative.constraint, SDK.reactNative.minimum, 'package.json');
    return;
  }
  pb.change('package.json', addPackageDependency(pkg, SDK.reactNative.package, SDK.reactNative.constraint), `add ${SDK.reactNative.package} ${SDK.reactNative.constraint}`);
}

function podInstall(pb: PlanBuilder, ios: IosProject | undefined, ctx: PlanContext): void {
  if (!ctx.install || !ios?.podfile) return;
  if (!which('pod')) {
    pb.reminder(`Run \`pod install\` in ${rel(ctx.root, ios.srcRoot) || '.'} on a Mac before building for iOS.`);
    return;
  }
  const useBundler = exists(path.join(ctx.root, 'Gemfile')) && which('bundle');
  pb.command('iOS pods', useBundler ? ['bundle', 'exec', 'pod', 'install'] : ['pod', 'install'], ios.srcRoot, 'Run pod install now?');
}

/** RN bare / Expo with ios/: Clikgate's module picks links up from RCTLinkingManager. */
function rnIosForwarding(pb: PlanBuilder, ios: IosProject): void {
  const files = targetSwiftFiles(ios).concat(
    ['AppDelegate.mm', 'AppDelegate.m'].map((n) => path.join(ios.srcRoot, ios.target, n)).filter(exists)
  );
  // Expo's AppDelegate / scene delegate forward links to RCTLinkingManager themselves.
  const forwards = files.some((f) => /RCTLinkingManager|ExpoAppDelegate|ExpoAppSceneDelegate/.test(read(f)));
  if (forwards) pb.done('iOS: links reach Clikgate through RCTLinkingManager');
  else {
    pb.manual(
      'iOS link forwarding',
      "Your AppDelegate/SceneDelegate doesn't forward links to RCTLinkingManager. Add the two methods below (or forward with ClikgateRN.handle(url:) / ClikgateRN.continue(userActivity:)).",
      [
        'func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {',
        '  RCTLinkingManager.application(app, open: url, options: options)',
        '}',
        'func application(_ application: UIApplication, continue userActivity: NSUserActivity,',
        '                 restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {',
        '  RCTLinkingManager.application(application, continue: userActivity, restorationHandler: restorationHandler)',
        '}',
      ].join('\n')
    );
  }
}

function nativeLinks(pb: PlanBuilder, ctx: PlanContext, flutter: boolean): void {
  const hasAny = ctx.links.live.length > 0 || Boolean(ctx.links.test);
  if (ctx.android && hasAny) planAndroidLinks(pb, ctx.android, ctx.links, { flutter });
  else if (ctx.android && flutter) planAndroidLinks(pb, ctx.android, ctx.links, { flutter });
  if (ctx.android) planAndroidBackup(pb, ctx.android);
  if (ctx.ios && hasAny) planIosLinks(pb, ctx.ios, ctx.links, { flutter });
}

// ------------------------------------------------------------------------------------ Flutter

function planFlutter(pb: PlanBuilder, ctx: PlanContext): void {
  const pubspec = pb.current('pubspec.yaml')!;
  const existing = dependencyConstraint(pubspec, SDK.flutter.package);
  if (existing) {
    pb.done(`${SDK.flutter.package} dependency`);
    outdated(pb, SDK.flutter.package, existing, SDK.flutter.constraint, SDK.flutter.minimum, 'pubspec.yaml');
  } else pb.change('pubspec.yaml', addPubDependency(pubspec, SDK.flutter.package, SDK.flutter.constraint), `add ${SDK.flutter.package} ${SDK.flutter.constraint}`);
  nativeLinks(pb, ctx, true);
  const mainRel = 'lib/main.dart';
  const main = pb.current(mainRel);
  if (main === null) pb.manual('Start Clikgate', 'lib/main.dart not found. Call Clikgate.configure before runApp.', editDartMain('void main() {\n  runApp(const MyApp());\n}\n', ctx.startup).kind === 'change' ? undefined : undefined);
  else source(pb, mainRel, editDartMain(main, ctx.startup), 'start Clikgate', 'Flutter: start-up code in lib/main.dart');
  if (ctx.install) {
    if (which('flutter')) pb.command('Flutter packages', ['flutter', 'pub', 'get'], ctx.root);
    else pb.reminder('Run `flutter pub get` (Flutter wasn\'t found on PATH).');
  }
  pb.reminder('Listen to deep links in your root widget: `Clikgate.onDeepLink.listen((link) => …)` (links that arrive before you listen are replayed).');
}

// ------------------------------------------------------------------------------- React Native

function jsRootFile(root: string, candidates: string[]): string | undefined {
  return candidates.find((c) => exists(path.join(root, c)));
}

function planReactNative(pb: PlanBuilder, ctx: PlanContext): void {
  addJsDependency(pb);
  nativeLinks(pb, ctx, false);
  if (ctx.ios) rnIosForwarding(pb, ctx.ios);
  const file = jsRootFile(ctx.root, ['App.tsx', 'App.jsx', 'App.js', 'src/App.tsx', 'src/App.js']);
  if (!file) pb.manual('Start Clikgate', 'No App.tsx / App.js found. Call Clikgate.configure once at start-up and subscribe to onDeepLink in your root component.', jsConfigureLines(ctx.startup).join('\n'));
  else source(pb, file, editJsRoot(pb.current(file)!, ctx.startup, file), 'start Clikgate', `React Native: start-up code in ${file}`);
  if (ctx.install) pb.command('JavaScript packages', installCommand(ctx.packageManager), ctx.root);
  podInstall(pb, ctx.ios, ctx);
}

// --------------------------------------------------------------------------------------- Expo

function planExpo(pb: PlanBuilder, ctx: PlanContext): void {
  addJsDependency(pb);
  const cfgRel = ctx.appConfig ? rel(ctx.root, ctx.appConfig) : 'app.json';
  const pluginProps = { linkDomains: ctx.links.live, testLinkDomain: ctx.links.test };
  if (cfgRel === 'app.json') {
    let text = pb.current('app.json')!;
    const before = text;
    const found = findClikgatePlugin(parseJsonc(text));
    text = addExpoPlugin(text, pluginProps);
    if (ctx.expoIds?.androidPackage) text = setExpoValueIfMissing(text, ['android', 'package'], ctx.expoIds.androidPackage);
    if (ctx.expoIds?.iosBundleId) text = setExpoValueIfMissing(text, ['ios', 'bundleIdentifier'], ctx.expoIds.iosBundleId);
    if (text !== before) pb.change('app.json', text, found ? 'complete the Clikgate config plugin' : `Clikgate config plugin: ${pluginProps.linkDomains.join(', ')}${pluginProps.testLinkDomain ? `; ${pluginProps.testLinkDomain} in development/preview builds only` : ''}`);
    else pb.done('Expo: Clikgate config plugin in app.json');
  } else {
    pb.manual(
      'Expo config plugin',
      `${cfgRel} is code, so the setup command doesn't edit it. Add this entry to its \`plugins\` array:`,
      JSON.stringify([SDK.reactNative.package, pluginProps], null, 2)
    );
  }
  if (ctx.android || ctx.ios) nativeLinks(pb, ctx, false);
  if (ctx.ios) rnIosForwarding(pb, ctx.ios);
  const pkg = parseJsonc<{ main?: string }>(pb.current('package.json') ?? '{}');
  const router = pkg.main === 'expo-router/entry';
  const file = router
    ? jsRootFile(ctx.root, ['src/app/_layout.tsx', 'app/_layout.tsx', 'src/app/_layout.jsx', 'app/_layout.jsx', 'src/app/_layout.js', 'app/_layout.js'])
    : jsRootFile(ctx.root, ['App.tsx', 'App.jsx', 'App.js', 'src/App.tsx', 'src/App.js']);
  if (!file) pb.manual('Start Clikgate', router ? 'No app/_layout file found.' : 'No App.tsx / App.js found.', jsConfigureLines(ctx.startup).join('\n'));
  else source(pb, file, editJsRoot(pb.current(file)!, ctx.startup, file), 'start Clikgate', `Expo: start-up code in ${file}`);
  if (ctx.install) pb.command('JavaScript packages', installCommand(ctx.packageManager), ctx.root);
  pb.reminder('Expo: build a new development build (`npx expo run:android` / `npx expo run:ios`, or `eas build --profile development`). Expo Go and old builds don\'t include the Clikgate native module or the new app links.');
  podInstall(pb, ctx.ios, ctx);
}

// ------------------------------------------------------------------------------ Native Android

function planAndroid(pb: PlanBuilder, ctx: PlanContext): void {
  const mod = ctx.android!;
  const buildRel = rel(ctx.root, mod.buildFile);
  const build = pb.current(buildRel)!;
  const catalogRel = mod.catalog ? rel(ctx.root, mod.catalog) : undefined;
  const catalog = catalogRel ? pb.current(catalogRel)! : undefined;
  if (hasClikgateDependency(build, catalog)) pb.done(`${SDK.android.group}:${SDK.android.artifact} dependency`);
  else if (catalogRel && catalog) {
    const alias = catalogAliasFor(catalog);
    pb.change(catalogRel, addCatalogEntries(catalog), `add ${SDK.android.artifact} ${SDK.android.version} to the version catalog`);
    const line = alias ? dependencyLine(mod.kotlinDsl, true).replace('clikgate.android', alias.replace(/[-_]/g, '.')) : dependencyLine(mod.kotlinDsl, true);
    pb.change(buildRel, addGradleDependency(build, line), `add ${SDK.android.artifact}`);
  } else {
    pb.change(buildRel, addGradleDependency(build, dependencyLine(mod.kotlinDsl, false)), `add ${SDK.android.group}:${SDK.android.artifact}:${SDK.android.version}`);
  }
  nativeLinks(pb, ctx, false);

  // Application class: extend it, or create ClikgateApplication.kt and register it.
  const manifestRel = rel(ctx.root, mod.mainManifest);
  const appName = applicationName(pb.current(manifestRel)!);
  const pkg = mod.namespace ?? mod.applicationIds[0];
  if (appName && !appName.startsWith('${')) {
    const file = findClassFile(mod.moduleDir, pkg, appName);
    if (file && file.endsWith('.kt')) {
      const r = rel(ctx.root, file);
      source(pb, r, editKotlinApplication(pb.current(r)!, ctx.startup, r), 'start Clikgate in Application.onCreate', `Android: start-up code in ${r}`);
    } else {
      pb.manual('Start Clikgate', `Add Clikgate.configure to ${appName}.onCreate()${file ? ` (${rel(ctx.root, file)} is Java)` : ''}.`, editKotlinApplication('', ctx.startup, appName).kind === 'manual' ? (editKotlinApplication('', ctx.startup, appName) as { snippet: string }).snippet : undefined);
    }
  } else if (!pkg) {
    pb.manual('Start Clikgate', 'The module has no namespace or applicationId, so the setup command can\'t place an Application class.');
  } else {
    const dir = path.join(mod.moduleDir, 'src', 'main', exists(path.join(mod.moduleDir, 'src', 'main', 'kotlin')) ? 'kotlin' : 'java', ...pkg.split('.'));
    const appRel = rel(ctx.root, path.join(dir, 'ClikgateApplication.kt'));
    const existing = pb.current(appRel);
    if (existing === null) pb.change(appRel, newKotlinApplication(pkg, ctx.startup), 'start Clikgate (new Application class)');
    else pb.done(`Android: ${appRel}`);
    const m = pb.current(manifestRel)!;
    const withName = setApplicationName(m, '.ClikgateApplication');
    if (withName !== m) pb.change(manifestRel, withName, 'register ClikgateApplication');
  }

  // Activity: hand intents to the SDK.
  if (mod.launcherActivity) {
    const file = findClassFile(mod.moduleDir, pkg, mod.launcherActivity);
    const className = mod.launcherActivity.split('.').pop()!;
    if (file && file.endsWith('.kt')) {
      const r = rel(ctx.root, file);
      source(pb, r, editKotlinActivity(pb.current(r)!, className, r), 'hand links to Clikgate', `Android: link handling in ${r}`);
    } else {
      const res = editKotlinActivity('', className, mod.launcherActivity);
      pb.manual('Hand links to Clikgate', `Call Clikgate.handleIntent(this, intent) in ${className}.onCreate and onNewIntent.`, res.kind === 'manual' ? res.snippet : undefined);
    }
  }
}

// ---------------------------------------------------------------------------------- Native iOS

function planIos(pb: PlanBuilder, ctx: PlanContext): void {
  const ios = ctx.ios!;
  if (ios.podfile) {
    const podRel = rel(ctx.root, ios.podfile);
    const text = pb.current(podRel)!;
    if (/pod\s+['"]Clikgate['"/]/.test(text)) pb.done(`pod '${SDK.ios.pod}'`);
    else {
      const t = new RegExp(`^([ \\t]*)target\\s+['"]${ios.target}['"]\\s+do[ \\t]*$`, 'm').exec(text);
      if (t) {
        const indent = t[1] + '  ';
        const at = t.index + t[0].length;
        const block = `\n${indent}# clikgate-setup:start\n${indent}pod '${SDK.ios.pod}', '${SDK.ios.podConstraint}'\n${indent}# clikgate-setup:end`;
        pb.change(podRel, text.slice(0, at) + block + text.slice(at), `add pod '${SDK.ios.pod}', '${SDK.ios.podConstraint}'`);
      } else pb.manual('Add the Clikgate pod', `Add pod '${SDK.ios.pod}', '${SDK.ios.podConstraint}' to the ${ios.target} target in ${podRel}.`);
    }
  } else {
    const pbx = read(ios.pbxproj);
    if (pbx.includes(SDK.ios.spm.replace('https://', ''))) pb.done('Clikgate Swift package');
    else
      pb.manual(
        'Add the Clikgate Swift package',
        `In Xcode: File › Add Package Dependencies…, enter ${SDK.ios.spm}, choose "Up to Next Major Version" from ${SDK.ios.version}, and add the Clikgate library to the ${ios.target} target. (The setup command doesn't edit Swift package references in project.pbxproj: Xcode writes several linked objects for them and a partial edit would break the project.)`
      );
  }
  nativeLinks(pb, ctx, false);

  const swift = targetSwiftFiles(ios);
  const swiftUI = swift.find((f) => /@main\s+struct\s+\w+\s*:\s*(SwiftUI\.)?App\b/.test(read(f)));
  const appDelegate = swift.find((f) => /class\s+\w+\s*:[^{]*UIApplicationDelegate/.test(read(f)));
  const sceneDelegate = swift.find((f) => /class\s+\w+\s*:[^{]*UIWindowSceneDelegate/.test(read(f)));
  if (swiftUI) {
    const r = rel(ctx.root, swiftUI);
    source(pb, r, editSwiftUIApp(pb.current(r)!, ctx.startup, r), 'start Clikgate; .onOpenURL and .onContinueUserActivity', `iOS: start-up code in ${r}`);
  } else if (appDelegate) {
    const r = rel(ctx.root, appDelegate);
    source(pb, r, editUIKitAppDelegate(pb.current(r)!, ctx.startup, r, !sceneDelegate), sceneDelegate ? 'start Clikgate' : 'start Clikgate; forward URLs and user activities', `iOS: start-up code in ${r}`);
    if (sceneDelegate) {
      const s = rel(ctx.root, sceneDelegate);
      source(pb, s, editUIKitSceneDelegate(pb.current(s)!, s), 'forward Universal Links and URLs to Clikgate', `iOS: link forwarding in ${s}`);
    }
  } else {
    pb.manual('Start Clikgate', `No SwiftUI App or UIKit AppDelegate found in ${ios.target}/. Call Clikgate.configure at launch and forward URLs (see docs).`);
  }
}

export function buildPlan(ctx: PlanContext): Plan {
  const pb = new PlanBuilder(ctx.root);
  switch (ctx.platform) {
    case 'flutter': planFlutter(pb, ctx); break;
    case 'react-native': planReactNative(pb, ctx); break;
    case 'expo': planExpo(pb, ctx); break;
    case 'android': planAndroid(pb, ctx); break;
    case 'ios': planIos(pb, ctx); break;
  }
  return pb.build();
}
