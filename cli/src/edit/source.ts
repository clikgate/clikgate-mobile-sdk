import { MARKER_END, MARKER_START, SDK, TEST_LINK_DOMAIN } from '../constants';
import { blocks } from './gradle';

/**
 * Start-up code. Source files are edited only in recognised template shapes; every inserted
 * line sits between `// clikgate-setup:start` and `// clikgate-setup:end`. Existing lines are
 * never removed or reordered (the one rewrite is making Dart's `main` async, as S.4 asks).
 * Anything else returns a manual step with the exact snippet.
 */

export interface StartupConfig {
  /** The test SDK key (Android's when the apps differ). */
  sdkKey: string;
  /** iOS app's test key when it differs from `sdkKey` (Flutter / React Native / Expo). */
  sdkKeyIos?: string;
  liveDomains: string[];
  testDomain?: string;
}

export type SourceResult =
  | { kind: 'done' }
  | { kind: 'change'; text: string }
  | { kind: 'manual'; reason: string; snippet: string };

export function hasMarkers(text: string): boolean {
  return text.includes(MARKER_START);
}

const S = `// ${MARKER_START}`;
const E = `// ${MARKER_END}`;

function indentLines(lines: string[], indent: string): string {
  return lines.map((l) => (l === '' ? '' : indent + l)).join('\n');
}

/** Inserts `block` on its own lines before the line at `lineStart`, with one blank line before it. */
function insertBeforeLine(text: string, lineStart: number, block: string): string {
  const before = text.slice(0, lineStart);
  const prevBlank = /\n[ \t]*\n$/.test(before) || /^\s*$/.test(before);
  return before + (prevBlank ? '' : '\n') + block + '\n' + text.slice(lineStart);
}

function lineStartAt(text: string, offset: number): number {
  return text.lastIndexOf('\n', offset - 1) + 1;
}
function lineEndAt(text: string, offset: number): number {
  const i = text.indexOf('\n', offset);
  return i < 0 ? text.length : i;
}
function indentAt(text: string, offset: number): string {
  return /^[ \t]*/.exec(text.slice(lineStartAt(text, offset)))![0];
}
/** Indent of the first non-empty line after `offset`, or `fallback`. */
function bodyIndent(text: string, offset: number, fallback: string): string {
  const rest = text.slice(lineEndAt(text, offset) + 1);
  const m = /^([ \t]*)\S/m.exec(rest);
  if (m && m[1].length > 0 && !/^[ \t]*[})\]]/.test(rest.slice(m.index))) return m[1];
  return fallback;
}
function unitOf(text: string): string {
  if (/\n\t/.test(text)) return '\t';
  return /\n {2}\S/.test(text) ? '  ' : '    ';
}

/**
 * Offset of the end of the line that ends the last import statement, or -1. `quoted`: the
 * statement ends with a quoted module name (JS/TS/Dart, possibly spanning lines); otherwise it
 * ends at the end of its line (Kotlin, Swift).
 */
export function afterLastImport(text: string, pattern: RegExp, quoted = false): number {
  let end = -1;
  for (const m of text.matchAll(pattern)) {
    let stmtEnd = lineEndAt(text, m.index!);
    if (quoted) {
      const q = /^import\s+(?:[^'"]*?\bfrom\s*)?['"][^'"\n]+['"]/.exec(text.slice(m.index));
      if (q) stmtEnd = lineEndAt(text, m.index! + q[0].length);
    }
    end = Math.max(end, stmtEnd);
  }
  return end;
}

export function dualKey(cfg: StartupConfig): boolean {
  return Boolean(cfg.sdkKeyIos && cfg.sdkKeyIos !== cfg.sdkKey);
}

function quoteList(domains: string[], q: string): string {
  return domains.map((d) => `${q}${d}${q}`).join(', ');
}

// ----------------------------------------------------------------------------- Dart (Flutter)

export function dartSnippet(cfg: StartupConfig, indent = '  '): string[] {
  const domains = `[${quoteList(cfg.liveDomains, "'")}${cfg.testDomain ? `, if (kDebugMode) '${cfg.testDomain}'` : ''}]`;
  return [
    S,
    'WidgetsFlutterBinding.ensureInitialized();',
    'await Clikgate.configure(',
    dualKey(cfg)
      ? `${indent}sdkKey: defaultTargetPlatform == TargetPlatform.iOS ? '${cfg.sdkKeyIos}' : '${cfg.sdkKey}',`
      : `${indent}sdkKey: '${cfg.sdkKey}',`,
    cfg.testDomain ? `${indent}// ${cfg.testDomain} (test links) only in debug builds` : null,
    `${indent}linkDomains: ${domains},`,
    ');',
    E,
  ].filter((l): l is string => l !== null);
}

export function editDartMain(text: string, cfg: StartupConfig): SourceResult {
  if (hasMarkers(text)) return { kind: 'done' };
  const snippet = [
    `import 'package:${SDK.flutter.package}/${SDK.flutter.package}.dart';`,
    '',
    'Future<void> main() async {',
    indentLines(dartSnippet(cfg), '  '),
    '  runApp(const MyApp());',
    '}',
  ].join('\n');
  const manual = (reason: string): SourceResult => ({ kind: 'manual', reason, snippet });

  let out = text;
  // `void main() => runApp(X);` -> block body
  const arrow = /^(void|Future<void>)\s+main\s*\(([^)]*)\)\s*(async\s*)?=>\s*(runApp\([\s\S]*?\));[ \t]*$/m.exec(out);
  if (arrow) {
    out = out.slice(0, arrow.index) + `Future<void> main(${arrow[2]}) async {\n  ${arrow[4]};\n}` + out.slice(arrow.index + arrow[0].length);
  }
  const sig = /^(void|Future<void>)\s+main\s*\(([^)]*)\)\s*(async\s*)?\{/m.exec(out);
  if (!sig) return manual('lib/main.dart has no `main()` function in a shape the setup command recognises');
  const bodyOpen = sig.index + sig[0].length - 1;
  const mainBlock = blocks(out).find((b) => b.open === bodyOpen);
  if (!mainBlock || mainBlock.close < 0) return manual('Could not find the end of main()');
  const body = out.slice(bodyOpen + 1, mainBlock.close);
  const runIdx = body.search(/^[ \t]*runApp\(/m);
  if (runIdx < 0) return manual('main() doesn\'t call runApp() directly');
  const runAt = bodyOpen + 1 + runIdx;
  const runLineStart = runAt; // search matched at line start
  const indent = indentAt(out, runLineStart + 1);
  let lines = dartSnippet(cfg);
  if (/WidgetsFlutterBinding\.ensureInitialized\(\)/.test(body.slice(0, runIdx))) {
    lines = lines.filter((l) => !l.startsWith('WidgetsFlutterBinding'));
  }
  // Insert before the runApp line.
  out = out.slice(0, runLineStart) + indentLines(lines, indent) + '\n' + out.slice(runLineStart);
  // Make main async (Future<void> ... async).
  const sig2 = /^(void|Future<void>)\s+main\s*\(([^)]*)\)\s*(async\s*)?\{/m.exec(out)!;
  if (sig2[1] !== 'Future<void>' || !sig2[3]) {
    out = out.slice(0, sig2.index) + `Future<void> main(${sig2[2]}) async {` + out.slice(sig2.index + sig2[0].length);
  }
  // Imports.
  const imports = [`import 'package:${SDK.flutter.package}/${SDK.flutter.package}.dart';`];
  const shown = [...(cfg.testDomain ? ['kDebugMode'] : []), ...(dualKey(cfg) ? ['defaultTargetPlatform', 'TargetPlatform'] : [])];
  if (shown.length && !/^import\s+['"]package:flutter\/foundation\.dart['"]\s*;/m.test(out)) {
    imports.push(`import 'package:flutter/foundation.dart' show ${shown.join(', ')};`);
  }
  const block = [S, ...imports, E].join('\n');
  const after = afterLastImport(out, /^import\s+['"]/gm, true);
  if (after < 0) out = block + '\n\n' + out;
  else out = out.slice(0, after) + '\n' + block + out.slice(after);
  return { kind: 'change', text: out };
}

// ----------------------------------------------------------------------------- JS / TS (React Native, Expo)

export function jsConfigureLines(cfg: StartupConfig): string[] {
  const live = `[${quoteList(cfg.liveDomains, "'")}]`;
  const domains = cfg.testDomain ? `__DEV__ ? [${quoteList([...cfg.liveDomains, cfg.testDomain], "'")}] : ${live}` : live;
  return [
    'Clikgate.configure({',
    dualKey(cfg) ? `  sdkKey: Platform.OS === 'ios' ? '${cfg.sdkKeyIos}' : '${cfg.sdkKey}',` : `  sdkKey: '${cfg.sdkKey}',`,
    cfg.testDomain ? `  // ${cfg.testDomain} (test links) only in development builds` : null,
    `  linkDomains: ${domains},`,
    '}).catch(console.warn);',
  ].filter((l): l is string => l !== null);
}

function jsHookLines(useEffectName: string): string[] {
  return [
    S,
    `${useEffectName}(`,
    '  () =>',
    '    Clikgate.onDeepLink((link) => {',
    '      // Open the screen for link.path (link.data has the link\'s data)',
    "      console.log('Clikgate deep link', link.path);",
    '    }),',
    '  []',
    ');',
    E,
  ];
}

interface ComponentBody {
  /** Offset of the `{` that opens the component body. */
  open: number;
}

/** Finds the default-exported function component's body. */
export function findRootComponent(text: string): ComponentBody | undefined {
  const candidates: { name?: string; start: number }[] = [];
  const direct = /^export\s+default\s+function\s*([A-Za-z0-9_$]*)\s*\(/m.exec(text);
  if (direct) candidates.push({ start: direct.index + direct[0].length - 1 });
  const named = /^export\s+default\s+([A-Za-z0-9_$]+)\s*;?\s*$/m.exec(text);
  if (named) {
    const fn = new RegExp(`^(?:export\\s+)?function\\s+${named[1]}\\s*\\(`, 'm').exec(text);
    if (fn) candidates.push({ start: fn.index + fn[0].length - 1 });
    const arrow = new RegExp(`^(?:export\\s+)?const\\s+${named[1]}\\s*(?::[^=]+)?=\\s*\\(`, 'm').exec(text);
    if (arrow) candidates.push({ start: arrow.index + arrow[0].length - 1 });
  }
  for (const c of candidates) {
    // Match the parameter list's parentheses.
    let depth = 0;
    let i = c.start;
    for (; i < text.length; i++) {
      if (text[i] === '(') depth++;
      else if (text[i] === ')') { depth--; if (depth === 0) break; }
    }
    const rest = text.slice(i + 1);
    const m = /^\s*(?::\s*[A-Za-z0-9_.<>\[\]| ]+)?\s*(=>)?\s*\{/.exec(rest);
    if (m) return { open: i + 1 + m[0].length - 1 };
  }
  return undefined;
}

export function editJsRoot(text: string, cfg: StartupConfig, fileLabel: string): SourceResult {
  if (hasMarkers(text)) return { kind: 'done' };
  const snippet = [
    `import { Clikgate } from '${SDK.reactNative.package}';`,
    "import { useEffect } from 'react';",
    '',
    ...jsConfigureLines(cfg),
    '',
    '// inside your root component:',
    ...jsHookLines('useEffect').filter((l) => l !== S && l !== E),
  ].join('\n');
  const root = findRootComponent(text);
  if (!root) return { kind: 'manual', reason: `${fileLabel}: the root component isn't in a shape the setup command recognises`, snippet };

  // Which useEffect to call.
  let useEffectName = 'useEffect';
  let needImport = true;
  const named = /^import\s+(?:[A-Za-z0-9_$]+\s*,\s*)?\{([^}]*)\}\s*from\s*['"]react['"]/m.exec(text);
  if (named && /\buseEffect\b/.test(named[1])) needImport = false;
  else if (/^import\s+(?:\*\s+as\s+)?React\b[^;]*from\s*['"]react['"]/m.test(text)) {
    useEffectName = 'React.useEffect';
    needImport = false;
  } else if (/\buseEffect\b/.test(text)) {
    return { kind: 'manual', reason: `${fileLabel} already uses a \`useEffect\` that isn't React's named import`, snippet };
  }

  let out = text;
  // 1. Hook at the start of the component body.
  const unit = unitOf(text);
  const fnIndent = indentAt(out, root.open);
  const indent = bodyIndent(out, root.open, fnIndent + unit);
  const bodyLineEnd = lineEndAt(out, root.open);
  if (out.slice(root.open + 1, bodyLineEnd).trim() !== '') {
    return { kind: 'manual', reason: `${fileLabel}: the root component's body starts on the same line as its \`{\``, snippet };
  }
  out = out.slice(0, bodyLineEnd) + '\n' + indentLines(jsHookLines(useEffectName), indent) + out.slice(bodyLineEnd);

  // 2. Imports and configure after the last import.
  const block = [
    S,
    `import { Clikgate } from '${SDK.reactNative.package}';`,
    needImport ? "import { useEffect } from 'react';" : null,
    dualKey(cfg) && !/^import\s+\{[^}]*\bPlatform\b[^}]*\}\s*from\s*['"]react-native['"]/m.test(text) ? "import { Platform } from 'react-native';" : null,
    '',
    ...jsConfigureLines(cfg),
    E,
  ].filter((l): l is string => l !== null);
  const after = afterLastImport(out, /^import\s/gm, true);
  if (after < 0) out = block.join('\n') + '\n\n' + out;
  else out = out.slice(0, after) + '\n\n' + block.join('\n') + out.slice(after);
  return { kind: 'change', text: out };
}

// ----------------------------------------------------------------------------- Kotlin (native Android)

export function kotlinConfigureLines(cfg: StartupConfig): string[] {
  const live = `listOf(${quoteList(cfg.liveDomains, '"')})`;
  const lines = [S];
  if (cfg.testDomain) {
    lines.push(
      `// ${cfg.testDomain} (test links) only in debug builds`,
      'val debuggable = (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0',
      `val linkDomains = if (debuggable) ${live} + "${cfg.testDomain}" else ${live}`
    );
  } else {
    lines.push(`val linkDomains = ${live}`);
  }
  lines.push(
    'Clikgate.configure(',
    '    this,',
    `    sdkKey = "${cfg.sdkKey}",`,
    '    options = ClikgateOptions(linkDomains = linkDomains),',
    ')',
    'Clikgate.onDeepLink { link ->',
    '    // Open the screen for link.path (link.data has the link\'s data)',
    '    Log.i("Clikgate", "Deep link: ${link.path}")',
    '}',
    E
  );
  return lines;
}

const KOTLIN_APP_IMPORTS = ['android.content.pm.ApplicationInfo', 'android.util.Log', 'com.clikgate.Clikgate', 'com.clikgate.ClikgateOptions'];

function addKotlinImports(text: string, imports: string[]): string {
  const missing = imports.filter((i) => !new RegExp(`^import\\s+${i.replace(/\./g, '\\.')}\\s*$`, 'm').test(text));
  if (missing.length === 0) return text;
  const block = [S, ...missing.map((i) => `import ${i}`), E].join('\n');
  const after = afterLastImport(text, /^import\s+[A-Za-z]/gm);
  if (after >= 0) return text.slice(0, after) + '\n' + block + text.slice(after);
  const pkg = /^package\s+[^\n]+$/m.exec(text);
  if (pkg) {
    const at = pkg.index + pkg[0].length;
    return text.slice(0, at) + '\n\n' + block + text.slice(at);
  }
  return block + '\n\n' + text;
}

export function newKotlinApplication(pkg: string, cfg: StartupConfig): string {
  const body = indentLines(kotlinConfigureLines(cfg), '        ');
  return [
    `package ${pkg}`,
    '',
    'import android.app.Application',
    ...KOTLIN_APP_IMPORTS.map((i) => `import ${i}`),
    '',
    '// Created by the Clikgate setup command (registered in AndroidManifest.xml).',
    'class ClikgateApplication : Application() {',
    '    override fun onCreate() {',
    '        super.onCreate()',
    body,
    '    }',
    '}',
    '',
  ].join('\n');
}

export function editKotlinApplication(text: string, cfg: StartupConfig, label: string): SourceResult {
  if (hasMarkers(text)) return { kind: 'done' };
  const snippet = ['override fun onCreate() {', '    super.onCreate()', indentLines(kotlinConfigureLines(cfg), '    '), '}'].join('\n');
  const m = /override\s+fun\s+onCreate\s*\(\s*\)\s*(?::\s*Unit\s*)?\{/.exec(text);
  if (!m) return { kind: 'manual', reason: `${label} has no onCreate() the setup command can extend`, snippet };
  const open = m.index + m[0].length - 1;
  const b = blocks(text).find((x) => x.open === open);
  if (!b || b.close < 0) return { kind: 'manual', reason: `${label}: couldn't read onCreate()`, snippet };
  const body = text.slice(open + 1, b.close);
  const sup = /^[ \t]*super\.onCreate\(\)[ \t]*;?[ \t]*$/m.exec(body);
  if (!sup) return { kind: 'manual', reason: `${label}: onCreate() doesn't call super.onCreate() on its own line`, snippet };
  const supEnd = open + 1 + sup.index + sup[0].length;
  const indent = /^[ \t]*/.exec(sup[0])![0];
  let out = text.slice(0, supEnd) + '\n' + indentLines(kotlinConfigureLines(cfg), indent) + text.slice(supEnd);
  out = addKotlinImports(out, KOTLIN_APP_IMPORTS);
  return { kind: 'change', text: out };
}

/** MainActivity: hand cold- and warm-start intents to the SDK (native Android only). */
export function editKotlinActivity(text: string, className: string, label: string): SourceResult {
  if (hasMarkers(text)) return { kind: 'done' };
  const snippet = [
    'override fun onCreate(savedInstanceState: Bundle?) {',
    '    super.onCreate(savedInstanceState)',
    '    Clikgate.handleIntent(this, intent)          // cold start',
    '    // ...',
    '}',
    '',
    'override fun onNewIntent(intent: Intent) {',
    '    super.onNewIntent(intent)',
    '    setIntent(intent)',
    '    Clikgate.handleIntent(this, intent)          // warm start',
    '}',
  ].join('\n');
  const manual = (reason: string): SourceResult => ({ kind: 'manual', reason: `${label}: ${reason}`, snippet });
  const cls = new RegExp(`class\\s+${className}\\b[^{\\n]*\\{`).exec(text);
  if (!cls) return manual(`class ${className} has no body the setup command recognises`);
  const all = blocks(text);
  const clsBlock = all.find((b) => b.open === cls.index + cls[0].length - 1);
  if (!clsBlock || clsBlock.close < 0) return manual('couldn\'t read the class body');
  if (/fun\s+onNewIntent\s*\(/.test(text)) return manual('it already overrides onNewIntent()');
  const on = /override\s+fun\s+onCreate\s*\(\s*savedInstanceState\s*:\s*Bundle\?\s*\)\s*\{/.exec(text);
  if (!on) return manual('it has no onCreate(savedInstanceState: Bundle?)');
  const onBlock = all.find((b) => b.open === on.index + on[0].length - 1);
  if (!onBlock || onBlock.close < 0) return manual('couldn\'t read onCreate()');
  const body = text.slice(onBlock.open + 1, onBlock.close);
  const sup = /^[ \t]*super\.onCreate\(savedInstanceState\)[ \t]*;?[ \t]*$/m.exec(body);
  if (!sup) return manual('onCreate() doesn\'t call super.onCreate(savedInstanceState) on its own line');
  const indent = /^[ \t]*/.exec(sup[0])![0];
  const memberIndent = indentAt(text, on.index);
  const unit = indent.slice(memberIndent.length) || '    ';
  const supEnd = onBlock.open + 1 + sup.index + sup[0].length;
  const newIntent = indentLines(
    [S, 'override fun onNewIntent(intent: Intent) {', `${unit}super.onNewIntent(intent)`, `${unit}setIntent(intent)`, `${unit}Clikgate.handleIntent(this, intent) // warm start`, '}', E],
    memberIndent
  );
  // Insert onNewIntent before the class's closing brace (on its own line).
  const closeLineStart = lineStartAt(text, clsBlock.close);
  let out: string;
  if (/^[ \t]*$/.test(text.slice(closeLineStart, clsBlock.close))) {
    out = insertBeforeLine(text, closeLineStart, newIntent);
  } else return manual('the class body doesn\'t end on its own line');
  out = out.slice(0, supEnd) + '\n' + indentLines([S, 'Clikgate.handleIntent(this, intent) // cold start', E], indent) + out.slice(supEnd);
  out = addKotlinImports(out, ['android.content.Intent', 'com.clikgate.Clikgate']);
  return { kind: 'change', text: out };
}

// ----------------------------------------------------------------------------- Swift (native iOS)

export function swiftConfigureLines(cfg: StartupConfig, unit = '    '): string[] {
  const live = `[${quoteList(cfg.liveDomains, '"')}]`;
  const lines: string[] = [];
  if (cfg.testDomain) {
    lines.push(
      `// ${cfg.testDomain} (test links) only in Debug builds`,
      '#if DEBUG',
      `let linkDomains = [${quoteList([...cfg.liveDomains, cfg.testDomain], '"')}]`,
      '#else',
      `let linkDomains = ${live}`,
      '#endif'
    );
  } else lines.push(`let linkDomains = ${live}`);
  lines.push(
    `Clikgate.configure(sdkKey: "${cfg.sdkKey}", options: ClikgateOptions(linkDomains: linkDomains))`,
    'Clikgate.shared.onDeepLink { link in',
    `${unit}// Open the screen for link.path (link.data has the link's data)`,
    `${unit}print("Clikgate deep link:", link.path ?? "/")`,
    '}'
  );
  return lines;
}

function addSwiftImport(text: string): string {
  if (/^import\s+Clikgate\s*$/m.test(text)) return text;
  const after = afterLastImport(text, /^import\s+[A-Za-z]/gm);
  const block = [S, 'import Clikgate', E].join('\n');
  if (after < 0) return block + '\n\n' + text;
  return text.slice(0, after) + '\n' + block + text.slice(after);
}

function swiftUnit(text: string): string {
  return /\n\t/.test(text) ? '\t' : '    ';
}

/** SwiftUI `@main struct X: App`. */
export function editSwiftUIApp(text: string, cfg: StartupConfig, label: string): SourceResult {
  if (hasMarkers(text)) return { kind: 'done' };
  const unit = swiftUnit(text);
  const snippet = [
    'import Clikgate',
    '',
    'init() {',
    indentLines(swiftConfigureLines(cfg, unit), unit),
    '}',
    '',
    '// on your root view inside WindowGroup:',
    '.onOpenURL { Clikgate.shared.handle(url: $0) }',
    '.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Clikgate.shared.continue(userActivity: $0) }',
  ].join('\n');
  const manual = (reason: string): SourceResult => ({ kind: 'manual', reason: `${label}: ${reason}`, snippet });
  const app = /@main\s+struct\s+([A-Za-z0-9_]+)\s*:\s*(?:SwiftUI\.)?App\s*\{/.exec(text);
  if (!app) return manual('no `@main struct …: App` found');
  const all = blocks(text);
  const appBlock = all.find((b) => b.open === app.index + app[0].length - 1);
  if (!appBlock || appBlock.close < 0) return manual('couldn\'t read the App struct');
  const appBody = text.slice(appBlock.open, appBlock.close);
  if (/\binit\s*\(\s*\)/.test(appBody)) return manual('the App struct already has an init()');
  const wg = /WindowGroup\s*(\([^)]*\))?\s*\{/.exec(appBody);
  if (!wg) return manual('no WindowGroup found');
  const wgOpen = appBlock.open + wg.index + wg[0].length - 1;
  const wgBlock = all.find((b) => b.open === wgOpen);
  if (!wgBlock || wgBlock.close < 0) return manual('couldn\'t read the WindowGroup');
  const wgBody = text.slice(wgOpen + 1, wgBlock.close);
  const nonEmpty = wgBody.split('\n').filter((l) => l.trim() !== '');
  if (nonEmpty.length !== 1 || !/^[ \t]*[A-Z][A-Za-z0-9_]*\([^(){}]*\)[ \t]*$/.test(nonEmpty[0])) {
    return manual('the WindowGroup content isn\'t a single view like `ContentView()`');
  }
  const viewLineStart = wgOpen + 1 + wgBody.indexOf(nonEmpty[0]);
  const viewLineEnd = viewLineStart + nonEmpty[0].length;
  const viewIndent = /^[ \t]*/.exec(nonEmpty[0])![0];
  const modifiers = indentLines(
    [S, '.onOpenURL { Clikgate.shared.handle(url: $0) }', '.onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Clikgate.shared.continue(userActivity: $0) }', E],
    viewIndent + unit
  );
  let out = text.slice(0, viewLineEnd) + '\n' + modifiers + text.slice(viewLineEnd);
  // init() as the first member of the struct.
  const memberIndent = indentAt(text, app.index) + unit;
  const initBlock = indentLines([S, 'init() {', ...swiftConfigureLines(cfg, unit).map((l) => unit + l), '}', E, ''], memberIndent);
  const structLineEnd = lineEndAt(out, appBlock.open);
  out = out.slice(0, structLineEnd) + '\n' + initBlock + out.slice(structLineEnd);
  out = addSwiftImport(out);
  return { kind: 'change', text: out };
}

/** UIKit AppDelegate: configure at the start of didFinishLaunching. */
export function editUIKitAppDelegate(text: string, cfg: StartupConfig, label: string, withUrlMethods: boolean): SourceResult {
  if (hasMarkers(text)) return { kind: 'done' };
  const unit = swiftUnit(text);
  const urlMethods = [
    'func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {',
    `${unit}Clikgate.shared.handle(url: url)`,
    '}',
    '',
    'func application(_ application: UIApplication, continue userActivity: NSUserActivity,',
    `${unit}${unit}${unit}${unit} restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {`,
    `${unit}Clikgate.shared.continue(userActivity: userActivity)`,
    '}',
  ];
  const snippet = [
    'import Clikgate',
    '',
    '// at the start of application(_:didFinishLaunchingWithOptions:):',
    ...swiftConfigureLines(cfg, unit),
    ...(withUrlMethods ? ['', ...urlMethods] : []),
  ].join('\n');
  const manual = (reason: string): SourceResult => ({ kind: 'manual', reason: `${label}: ${reason}`, snippet });
  const fn = /func\s+application\s*\(\s*_\s+application\s*:\s*UIApplication\s*,\s*didFinishLaunchingWithOptions\s+launchOptions\s*:[^{]*\)\s*->\s*Bool\s*\{/.exec(text);
  if (!fn) return manual('no application(_:didFinishLaunchingWithOptions:) found');
  const all = blocks(text);
  const open = fn.index + fn[0].length - 1;
  const fnBlock = all.find((b) => b.open === open);
  if (!fnBlock || fnBlock.close < 0) return manual('couldn\'t read didFinishLaunching');
  if (out_hasOnSameLine(text, open)) return manual('the method body starts on the same line');
  const indent = bodyIndent(text, open, indentAt(text, fn.index) + unit);
  const lineEnd = lineEndAt(text, open);
  let out = text.slice(0, lineEnd) + '\n' + indentLines([S, ...swiftConfigureLines(cfg, unit), E], indent) + text.slice(lineEnd);
  if (withUrlMethods) {
    if (/open\s+url\s*:\s*URL/.test(text) || /continue\s+userActivity\s*:/.test(text)) {
      return manual('it already handles URLs or user activities');
    }
    const cls = /class\s+[A-Za-z0-9_]+\s*:[^{]*UIApplicationDelegate[^{]*\{/.exec(out);
    if (!cls) return manual('no AppDelegate class found');
    const clsBlock = blocks(out).find((b) => b.open === cls.index + cls[0].length - 1);
    if (!clsBlock || clsBlock.close < 0) return manual('couldn\'t read the AppDelegate class');
    const memberIndent = indentAt(out, cls.index) + unit;
    const closeLineStart = lineStartAt(out, clsBlock.close);
    out = insertBeforeLine(out, closeLineStart, indentLines([S, ...urlMethods, E], memberIndent));
  }
  out = addSwiftImport(out);
  return { kind: 'change', text: out };
}

function out_hasOnSameLine(text: string, open: number): boolean {
  return text.slice(open + 1, lineEndAt(text, open)).trim() !== '';
}

/** UIKit SceneDelegate: forward launch, Universal Link and URL-scheme events. */
export function editUIKitSceneDelegate(text: string, label: string): SourceResult {
  if (hasMarkers(text)) return { kind: 'done' };
  const unit = swiftUnit(text);
  const methods = [
    'func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {',
    `${unit}Clikgate.shared.continue(userActivity: userActivity)`,
    '}',
    '',
    'func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {',
    `${unit}URLContexts.forEach { Clikgate.shared.handle(url: $0.url) }`,
    '}',
  ];
  const snippet = [
    '// at the start of scene(_:willConnectTo:options:):',
    'connectionOptions.userActivities.forEach { Clikgate.shared.continue(userActivity: $0) }',
    'connectionOptions.urlContexts.forEach { Clikgate.shared.handle(url: $0.url) }',
    '',
    ...methods,
  ].join('\n');
  const manual = (reason: string): SourceResult => ({ kind: 'manual', reason: `${label}: ${reason}`, snippet });
  if (/func\s+scene\s*\(\s*_\s+scene\s*:\s*UIScene\s*,\s*continue\s/.test(text) || /openURLContexts/.test(text)) {
    return manual('it already handles user activities or URLs');
  }
  const wc = /func\s+scene\s*\(\s*_\s+scene\s*:\s*UIScene\s*,\s*willConnectTo\s+session\s*:\s*UISceneSession\s*,\s*options\s+([A-Za-z0-9_]+)\s*:\s*UIScene\.ConnectionOptions\s*\)\s*\{/.exec(text);
  if (!wc) return manual('no scene(_:willConnectTo:options:) found');
  const opts = wc[1];
  const all = blocks(text);
  const open = wc.index + wc[0].length - 1;
  if (!all.find((b) => b.open === open)) return manual('couldn\'t read scene(_:willConnectTo:options:)');
  if (out_hasOnSameLine(text, open)) return manual('the method body starts on the same line');
  const cls = /class\s+[A-Za-z0-9_]+\s*:[^{]*UIWindowSceneDelegate[^{]*\{/.exec(text);
  if (!cls) return manual('no SceneDelegate class found');
  const clsBlock = all.find((b) => b.open === cls.index + cls[0].length - 1);
  if (!clsBlock || clsBlock.close < 0) return manual('couldn\'t read the SceneDelegate class');
  const memberIndent = indentAt(text, cls.index) + unit;
  const closeLineStart = lineStartAt(text, clsBlock.close);
  let out = insertBeforeLine(text, closeLineStart, indentLines([S, ...methods, E], memberIndent));
  const indent = bodyIndent(out, open, indentAt(out, wc.index) + unit);
  const lineEnd = lineEndAt(out, open);
  out =
    out.slice(0, lineEnd) +
    '\n' +
    indentLines(
      [S, `${opts}.userActivities.forEach { Clikgate.shared.continue(userActivity: $0) }`, `${opts}.urlContexts.forEach { Clikgate.shared.handle(url: $0.url) }`, E],
      indent
    ) +
    out.slice(lineEnd);
  out = addSwiftImport(out);
  return { kind: 'change', text: out };
}

// ------------------------------------------------- APNs token forward (automaticPushToken, uninstall tracking)

/**
 * Which SDK receives the APNs token: the native iOS SDK (`Clikgate.shared`) or the React Native
 * module (`ClikgateRN`, which keeps a token that arrives before `Clikgate.configure` runs in JS).
 */
export type PushForwardTarget = 'native' | 'react-native';

/** True when the file already passes the APNs device token to Clikgate. */
export function hasPushTokenForward(text: string): boolean {
  return /setPushToken\s*\(\s*deviceToken\s*:/.test(text) || /setPushTokenWithDeviceToken\s*:/.test(text);
}

/** The one forward line, per language and target. `token` is the method's parameter name. */
export function pushForwardLine(lang: 'swift' | 'objc', target: PushForwardTarget, token = 'deviceToken'): string {
  if (lang === 'swift') return target === 'native' ? `Clikgate.shared.setPushToken(deviceToken: ${token})` : `ClikgateRN.setPushToken(deviceToken: ${token})`;
  return target === 'native' ? `[Clikgate.shared setPushTokenWithDeviceToken:${token}];` : `[ClikgateRN setPushTokenWithDeviceToken:${token}];`;
}

/** Manual-step snippet (SwiftUI apps without an AppDelegate, or files the setup can't edit). */
export function pushForwardSnippet(lang: 'swift' | 'objc', target: PushForwardTarget, swiftUI = false): string {
  if (lang === 'objc') {
    return [
      '- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {',
      `  ${pushForwardLine('objc', target)}`,
      '}',
    ].join('\n');
  }
  const method = [
    'func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {',
    `    ${pushForwardLine('swift', target)}`,
    '}',
  ];
  if (!swiftUI) return method.join('\n');
  return [
    'import Clikgate',
    '',
    'final class AppDelegate: NSObject, UIApplicationDelegate {',
    ...method.map((l) => '    ' + l),
    '}',
    '',
    '// in your @main App struct:',
    '@UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate',
  ].join('\n');
}

function addSwiftModuleImport(text: string, module: string): string {
  if (new RegExp(`^(?:@_exported\\s+|internal\\s+|public\\s+)?import\\s+${module}\\s*$`, 'm').test(text)) return text;
  const after = afterLastImport(text, /^(?:@_exported\s+|internal\s+|public\s+|@testable\s+)?import\s+[A-Za-z]/gm);
  const block = [S, `import ${module}`, E].join('\n');
  if (after < 0) return block + '\n\n' + text;
  return text.slice(0, after) + '\n' + block + text.slice(after);
}

/**
 * UIKit AppDelegate (Swift): pass the APNs token to Clikgate in
 * `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`. Adds the line to an existing
 * method, or adds the method (an `override` that calls `super` for Expo's `ExpoAppDelegate`).
 * Idempotent: a file that already forwards the token is left alone.
 */
export function editSwiftPushForward(text: string, target: PushForwardTarget, label: string): SourceResult {
  if (hasPushTokenForward(text)) return { kind: 'done' };
  const unit = unitOf(text);
  const manual = (reason: string): SourceResult => ({ kind: 'manual', reason: `${label}: ${reason}`, snippet: pushForwardSnippet('swift', target) });
  const module = target === 'native' ? 'Clikgate' : 'ClikgateReactNative';
  const all = blocks(text);
  const fn = /func\s+application\s*\(\s*_\s+([A-Za-z0-9_]+)\s*:\s*UIApplication\s*,\s*didRegisterForRemoteNotificationsWithDeviceToken\s+([A-Za-z0-9_]+)\s*:\s*Data\s*\)\s*\{/.exec(text);
  let out: string;
  if (fn) {
    const open = fn.index + fn[0].length - 1;
    if (!all.find((b) => b.open === open && b.close >= 0)) return manual('couldn\'t read application(_:didRegisterForRemoteNotificationsWithDeviceToken:)');
    if (out_hasOnSameLine(text, open)) return manual('the method body starts on the same line');
    const indent = bodyIndent(text, open, indentAt(text, fn.index) + unit);
    const lineEnd = lineEndAt(text, open);
    out = text.slice(0, lineEnd) + '\n' + indentLines([S, pushForwardLine('swift', target, fn[2]), E], indent) + text.slice(lineEnd);
  } else {
    const cls = /class\s+[A-Za-z0-9_]+\s*:([^{]*)\{/g;
    let m: RegExpExecArray | null;
    let found: RegExpExecArray | undefined;
    while ((m = cls.exec(text))) {
      if (/\b(UIApplicationDelegate|ExpoAppDelegate|RCTAppDelegate)\b/.test(m[1])) {
        found = m;
        break;
      }
    }
    if (!found) return manual('no AppDelegate class found');
    const clsBlock = all.find((b) => b.open === found!.index + found![0].length - 1);
    if (!clsBlock || clsBlock.close < 0) return manual('couldn\'t read the AppDelegate class');
    const expo = /\bExpoAppDelegate\b/.test(found[1]);
    const method = [
      S,
      `${expo ? 'public override ' : ''}func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {`,
      ...(expo ? [`${unit}super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)`] : []),
      `${unit}${pushForwardLine('swift', target)}`,
      '}',
      E,
    ];
    const memberIndent = indentAt(text, found.index) + unit;
    out = insertBeforeLine(text, lineStartAt(text, clsBlock.close), indentLines(method, memberIndent));
  }
  out = addSwiftModuleImport(out, module);
  return { kind: 'change', text: out };
}

/**
 * UIKit AppDelegate (Objective-C, `.m` / `.mm`): the same forward. Imports the module's generated
 * Swift header with `#import` when the app can see it (framework pods), else declares the one method it
 * calls (static library pods); `@import` would need -fcxx-modules in Objective-C++.
 * `headerText` is the AppDelegate's `.h` (where `@interface AppDelegate : Superclass` usually is): a new
 * method calls `super` only when the superclass can have it (`RCTAppDelegate`, `EXAppDelegateWrapper`),
 * since `[super …]` on a plain `UIResponder` / `NSObject` doesn't compile.
 */
export function editObjcPushForward(text: string, target: PushForwardTarget, label: string, headerText = ''): SourceResult {
  if (hasPushTokenForward(text)) return { kind: 'done' };
  const manual = (reason: string): SourceResult => ({ kind: 'manual', reason: `${label}: ${reason}`, snippet: pushForwardSnippet('objc', target) });
  const unit = unitOf(text);
  const all = blocks(text);
  const fn = /-\s*\(\s*void\s*\)\s*application\s*:\s*\(\s*UIApplication\s*\*\s*\)\s*[A-Za-z0-9_]+\s+didRegisterForRemoteNotificationsWithDeviceToken\s*:\s*\(\s*NSData\s*\*\s*\)\s*([A-Za-z0-9_]+)\s*\{/.exec(text);
  let out: string;
  if (fn) {
    const open = fn.index + fn[0].length - 1;
    if (!all.find((b) => b.open === open && b.close >= 0)) return manual('couldn\'t read application:didRegisterForRemoteNotificationsWithDeviceToken:');
    if (out_hasOnSameLine(text, open)) return manual('the method body starts on the same line');
    const indent = bodyIndent(text, open, unit);
    const lineEnd = lineEndAt(text, open);
    out = text.slice(0, lineEnd) + '\n' + indentLines([S, pushForwardLine('objc', target, fn[1]), E], indent) + text.slice(lineEnd);
  } else {
    const impl = /^@implementation\s+([A-Za-z0-9_]*AppDelegate)\b.*$/m.exec(text);
    if (!impl) return manual('no @implementation …AppDelegate found');
    const end = /^@end\b/m.exec(text.slice(impl.index));
    if (!end) return manual('the @implementation has no @end');
    const endAt = impl.index + end.index;
    const superclass = new RegExp(`@interface\\s+${impl[1]}\\s*:\\s*([A-Za-z0-9_]+)`).exec(text + '\n' + headerText)?.[1];
    const callsSuper = superclass !== 'UIResponder' && superclass !== 'NSObject';
    const method = [
      S,
      '- (void)application:(UIApplication *)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken',
      '{',
      ...(callsSuper
        ? [
            `${unit}if ([[self superclass] instancesRespondToSelector:_cmd]) {`,
            `${unit}${unit}[super application:application didRegisterForRemoteNotificationsWithDeviceToken:deviceToken];`,
            `${unit}}`,
          ]
        : []),
      `${unit}${pushForwardLine('objc', target)}`,
      '}',
      E,
    ];
    out = insertBeforeLine(text, endAt, method.join('\n'));
  }
  const header = target === 'native' ? 'Clikgate/Clikgate-Swift.h' : 'ClikgateReactNative/ClikgateReactNative-Swift.h';
  const fallback = target === 'native' ? 'Clikgate-Swift.h' : 'ClikgateReactNative-Swift.h';
  if (!out.includes(fallback)) {
    // Static library pods (the React Native default, or no use_frameworks!) don't put the generated
    // Swift header on the app's header search path, and `@import` needs -fcxx-modules in a `.mm`:
    // declare the one Objective-C method the forward calls instead.
    const declaration =
      target === 'native'
        ? ['@interface Clikgate : NSObject', '@property (class, nonatomic, readonly, strong) Clikgate *shared;', '- (void)setPushTokenWithDeviceToken:(NSData *)deviceToken;', '@end']
        : ['@interface ClikgateRN : NSObject', '+ (void)setPushTokenWithDeviceToken:(NSData *)deviceToken;', '@end'];
    const imports = [S, `#if __has_include(<${header}>)`, `#import <${header}>`, '#else', ...declaration, '#endif', E].join('\n');
    const after = afterLastImport(out, /^#import\s+[<"]/gm);
    out = after < 0 ? imports + '\n\n' + out : out.slice(0, after) + '\n' + imports + out.slice(after);
  }
  return { kind: 'change', text: out };
}

export { TEST_LINK_DOMAIN };
