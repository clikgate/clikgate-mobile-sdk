import * as path from 'node:path';
import { WEBSITE_SERVERS, type Options, type WebsiteServer } from './args';
import {
  EXIT,
  KEEP_ROUTE_PATH,
  SAFARI_NOTE,
  SDK_KEY_ANY,
  SERVER_SDK,
  SUCCESS_LINE,
  WEB_KEY,
  WEB_KEY_PLACEHOLDER,
  WEB_SCRIPT_URL,
} from './constants';
import { parseJsonc } from './edit/json';
import { detectPackageManager, type PackageManager } from './detect';
import { exists, isDir, list, readIfExists, rel } from './fsutil';
import { treeState } from './git';
import { PlanBuilder, type Plan } from './plan';
import { Exit, printManual, reviewAndApply, type Deps } from './setup';
import { paint, type UI } from './ui';

/**
 * `npx @clikgate/setup website` (change 16 S and R.2): the web script tag, and, when the website has its own server,
 * the `/cg/keep` route plus the tag's `data-server-endpoint="/cg/keep"`. The server is detected from package files;
 * when nothing is recognised the command asks "Does your website have its own server?". Edits follow the app setup's
 * rules: shown as a diff first, idempotent, never overwriting a file, and anything that can't be placed safely is a
 * manual step with the exact code.
 */

export const SERVER_LABEL: Record<WebsiteServer, string> = {
  nextjs: 'Next.js',
  express: 'Express',
  laravel: 'Laravel',
  django: 'Django',
  'spring-boot': 'Spring Boot',
  'aspnet-core': 'ASP.NET Core',
  wordpress: 'WordPress',
  shopify: 'Shopify theme',
};

export const OWN_SERVER_QUESTION = 'Does your website have its own server?';

export interface WebsiteCandidate {
  server: WebsiteServer;
  root: string;
  /** What was found, for "Found a Next.js website (package.json lists next)." */
  evidence: string;
}

type Pkg = { dependencies?: Record<string, string>; devDependencies?: Record<string, string>; main?: string };

function readPkg(dir: string): Pkg | undefined {
  const t = readIfExists(path.join(dir, 'package.json'));
  if (t === undefined) return undefined;
  try {
    return parseJsonc<Pkg>(t);
  } catch {
    return undefined;
  }
}

function pkgHas(pkg: Pkg | undefined, name: string): boolean {
  return Boolean(pkg?.dependencies?.[name] ?? pkg?.devDependencies?.[name]);
}

/** `django` as a package name, not `django-environ` or `djangorestframework`. */
const DJANGO_REQ = /(?<![\w.-])django(?![\w-])/i;

function csprojFiles(dir: string): string[] {
  return list(dir).filter((n) => n.endsWith('.csproj')).sort();
}

/** The website servers recognised in one folder, by their package files (R.2). */
export function detectWebsiteIn(dir: string): WebsiteCandidate[] {
  const out: WebsiteCandidate[] = [];
  const add = (server: WebsiteServer, evidence: string) => out.push({ server, root: dir, evidence });
  if (exists(path.join(dir, 'wp-config.php'))) add('wordpress', 'wp-config.php');
  else if (isDir(path.join(dir, 'wp-content'))) add('wordpress', 'wp-content/');
  if (exists(path.join(dir, 'config', 'settings_schema.json')) && exists(path.join(dir, 'layout', 'theme.liquid'))) {
    add('shopify', 'config/settings_schema.json and layout/theme.liquid');
  }
  const pkg = readPkg(dir);
  if (pkgHas(pkg, 'next')) add('nextjs', 'package.json lists next');
  else if (pkgHas(pkg, 'express')) add('express', 'package.json lists express');
  const composer = readIfExists(path.join(dir, 'composer.json'));
  let laravel = false;
  if (composer !== undefined) {
    try {
      laravel = Boolean(parseJsonc<{ require?: Record<string, string> }>(composer).require?.['laravel/framework']);
    } catch {
      laravel = false;
    }
  }
  if (laravel) add('laravel', 'composer.json requires laravel/framework');
  else if (exists(path.join(dir, 'artisan'))) add('laravel', 'artisan');
  if (exists(path.join(dir, 'manage.py'))) add('django', 'manage.py');
  else {
    for (const f of ['requirements.txt', 'pyproject.toml', 'Pipfile']) {
      const t = readIfExists(path.join(dir, f));
      if (t !== undefined && DJANGO_REQ.test(t)) {
        add('django', `${f} lists django`);
        break;
      }
    }
  }
  for (const f of ['pom.xml', 'build.gradle', 'build.gradle.kts']) {
    const t = readIfExists(path.join(dir, f));
    if (t !== undefined && t.includes('spring-boot')) {
      add('spring-boot', `${f} uses spring-boot`);
      break;
    }
  }
  const web = csprojFiles(dir).find((f) => /Sdk\s*=\s*"Microsoft\.NET\.Sdk\.Web"/.test(readIfExists(path.join(dir, f)) ?? ''));
  if (web) add('aspnet-core', `${web} uses Microsoft.NET.Sdk.Web`);
  return out;
}

const SKIP = new Set([
  'node_modules', '.git', 'build', 'dist', '.next', 'vendor', 'storage', 'target', 'bin', 'obj', 'venv', '.venv',
  '__pycache__', '.clikgate-setup-backup', 'Pods', '.gradle', '.idea', 'coverage', 'out',
]);

function walkDirs(root: string, maxDepth: number, visit: (dir: string) => void): void {
  const queue: [string, number][] = [[root, 0]];
  while (queue.length) {
    const [dir, depth] = queue.shift()!;
    visit(dir);
    if (depth >= maxDepth) continue;
    for (const name of list(dir).sort()) {
      if (SKIP.has(name) || name.startsWith('.')) continue;
      const p = path.join(dir, name);
      if (isDir(p)) queue.push([p, depth + 1]);
    }
  }
}

/**
 * Detection in the project folder; when nothing is there, a few folders down (monorepos: apps/web, packages/site…),
 * like the app detection. A WordPress install's own folders aren't searched below it.
 */
export function detectWebsite(cwd: string, maxDepth = 3): WebsiteCandidate[] {
  const here = detectWebsiteIn(cwd);
  if (here.length) return here;
  const found: WebsiteCandidate[] = [];
  const claimed: string[] = [];
  walkDirs(cwd, maxDepth, (dir) => {
    if (dir === cwd || claimed.some((c) => dir.startsWith(c + path.sep))) return;
    const c = detectWebsiteIn(dir);
    if (c.length) {
      found.push(...c);
      claimed.push(dir);
    }
  });
  return found;
}

// ------------------------------------------------------------------------------- keep route

export type KeepResult = 'added' | 'present' | 'manual';
/** Servers that get a keep route (WordPress and Shopify keep the click ID themselves). */
export type KeepServer = Exclude<WebsiteServer, 'wordpress' | 'shopify'>;

interface KeepContext {
  root: string;
  packageManager: PackageManager;
}

const KEEP = KEEP_ROUTE_PATH;
const MANUAL_KEEP = 'Keep route';

function eol(text: string): string {
  return text.includes('\r\n') ? '\r\n' : '\n';
}

/** Inserts `newLines` before line index `at`, keeping the file's line endings. */
function insertLines(text: string, at: number, newLines: string[]): string {
  const nl = eol(text);
  const ls = text.split(/\r?\n/);
  ls.splice(at, 0, ...newLines);
  return ls.join(nl);
}

/** Appends lines at the end, with one blank line before them. */
function appendBlock(text: string, block: string[]): string {
  const nl = eol(text);
  const body = text.replace(/(\r?\n)+$/, '');
  return `${body}${body ? nl + nl : ''}${block.join(nl)}${nl}`;
}

/**
 * Index of the line after the last top-level import (JS `import`/`require`, Python `import`/`from`), skipping
 * multi-line statements; -1 when the file has none.
 */
function afterImports(text: string, lang: 'js' | 'py'): number {
  const ls = text.split(/\r?\n/);
  let after = -1;
  let open = 0;
  for (let i = 0; i < ls.length; i++) {
    const l = ls[i];
    if (open > 0) {
      open += (l.match(/[({[]/g) ?? []).length - (l.match(/[)}\]]/g) ?? []).length;
      if (open <= 0) {
        open = 0;
        after = i + 1;
      }
      continue;
    }
    const isImport =
      lang === 'py'
        ? /^(import|from)\s+\S/.test(l)
        : /^import[\s{*'"]/.test(l) || /^(const|let|var)\s+[\w{},\s]+=\s*require\(/.test(l);
    if (!isImport) continue;
    open = (l.match(/[({[]/g) ?? []).length - (l.match(/[)}\]]/g) ?? []).length;
    if (open <= 0) {
      open = 0;
      after = i + 1;
    }
  }
  return after;
}

function installStep(pb: PlanBuilder, server: WebsiteServer, ctx: KeepContext, present: boolean): void {
  const pm = ctx.packageManager;
  const label = 'Clikgate server SDK';
  if (present) {
    pb.done(`${label} dependency`);
    pb.reminder('The keep route needs a Clikgate server SDK version that includes it: update the SDK if the route is reported missing.');
    return;
  }
  const cmd: Record<KeepServer, string> = {
    nextjs: `${pm === 'npm' ? 'npm install' : `${pm} add`} ${SERVER_SDK.node}`,
    express: `${pm === 'npm' ? 'npm install' : `${pm} add`} ${SERVER_SDK.node}`,
    laravel: `composer require ${SERVER_SDK.laravel}`,
    django: `pip install ${SERVER_SDK.python}`,
    'spring-boot': `add the dependency ${SERVER_SDK.springBoot} to pom.xml or build.gradle`,
    'aspnet-core': `dotnet add package ${SERVER_SDK.dotnet}`,
  };
  const c = cmd[server as keyof typeof cmd];
  pb.manual(
    'Install the Clikgate server SDK',
    `The keep route uses the Clikgate server SDK (a version that includes the keep route), which the setup command doesn't add for you. Install it in the website's folder, then set it up as its README says; the API key stays on your server, never in a page:`,
    c
  );
}

function has(text: string | null, re: RegExp | string): boolean {
  if (text === null) return false;
  return typeof re === 'string' ? text.includes(re) : re.test(text);
}

// Next.js (App Router): app/cg/keep/route.ts

const NEXT_ROUTE = () =>
  [
    `import { Clikgate } from '${SERVER_SDK.node}';`,
    '',
    `const clikgate = new Clikgate();`,
    '',
    '// Saves the Clikgate click ID from your own server (the web script\'s data-server-endpoint).',
    `export const POST = clikgate.clickIds.keepRoute();`,
    '',
  ].join('\n');

function planNext(pb: PlanBuilder, ctx: KeepContext): KeepResult {
  const appDir = ['src/app', 'app'].find((d) => isDir(path.join(ctx.root, d)));
  const ts = exists(path.join(ctx.root, 'tsconfig.json'));
  const snippet = NEXT_ROUTE();
  if (!appDir) {
    pb.manual(
      MANUAL_KEEP,
      `No App Router folder (app/ or src/app/) was found, and a Pages Router API route can't answer at ${KEEP} (it lives under /api). Create app/cg/keep/route.${ts ? 'ts' : 'js'} (the App Router works next to pages/ from Next.js 13.4) with:`,
      snippet
    );
    return 'manual';
  }
  const dir = `${appDir}/cg/keep`;
  const existing = ['route.ts', 'route.js', 'route.tsx', 'route.jsx', 'route.mjs'].map((n) => `${dir}/${n}`).find((f) => pb.current(f) !== null);
  if (existing) {
    if (has(pb.current(existing), 'keepRoute')) {
      pb.done(`${KEEP} route (${existing})`);
      return 'present';
    }
    pb.manual(MANUAL_KEEP, `${existing} already exists and isn't the Clikgate keep route; it was left as it is. Make its POST handler:`, snippet);
    return 'manual';
  }
  pb.change(`${dir}/route.${ts ? 'ts' : 'js'}`, snippet, `add the ${KEEP} route`);
  pb.reminder(`The ${KEEP} route creates a Clikgate client: set CLIKGATE_API_KEY on your server (never in the page).`);
  return 'added';
}

// Express: app.post('/cg/keep', clikgate.clickIds.keepRoute().express)

const EXPRESS_FILES = ['server.js', 'app.js', 'index.js', 'server.ts', 'app.ts', 'index.ts', 'server.mjs', 'app.mjs', 'index.mjs', 'src/server.js', 'src/app.js', 'src/index.js', 'src/server.ts', 'src/app.ts', 'src/index.ts'];
const EXPRESS_APP = /^(?:const|let|var)\s+(\w+)\s*=\s*express\(\s*\)\s*;?\s*$/;

function planExpress(pb: PlanBuilder, ctx: KeepContext): KeepResult {
  const main = readPkg(ctx.root)?.main;
  const candidates = [...new Set([...(main ? [main.replace(/^\.\//, '')] : []), ...EXPRESS_FILES])];
  const manualSnippet = [`import { Clikgate } from '${SERVER_SDK.node}';`, 'const clikgate = new Clikgate();', `app.post('${KEEP}', clikgate.clickIds.keepRoute().express);`].join('\n');
  for (const f of candidates) {
    const text = pb.current(f);
    if (text === null || !/express\(\s*\)/.test(text)) continue;
    if (has(text, `'${KEEP}'`) || has(text, `"${KEEP}"`) || has(text, `\`${KEEP}\``)) {
      pb.done(`${KEEP} route (${f})`);
      return 'present';
    }
    const ls = text.split(/\r?\n/);
    const appLines = ls.map((l, i) => [l, i] as const).filter(([l]) => EXPRESS_APP.test(l));
    if (appLines.length !== 1) break;
    const [appLine, appIndex] = appLines[0];
    const app = EXPRESS_APP.exec(appLine)![1];
    const instance = ls.map((l, i) => [/^(?:const|let|var)\s+(\w+)\s*=\s*new\s+Clikgate\(/.exec(l), i] as const).find(([m]) => m);
    if (!instance && /new\s+Clikgate\(/.test(text)) break; // a client in some inner scope: don't guess
    const cjs = /require\(\s*['"]express['"]\s*\)/.test(text);
    const route = (name: string) => `${app}.post('${KEEP}', ${name}.clickIds.keepRoute().express);`;
    let out: string;
    if (instance) {
      const name = instance[0]![1];
      out = insertLines(text, Math.max(appIndex, instance[1]) + 1, [route(name)]);
    } else {
      out = insertLines(text, appIndex + 1, ['const clikgate = new Clikgate();', route('clikgate')]);
      if (!/from\s+['"]@clikgate\/node['"]|require\(\s*['"]@clikgate\/node['"]\s*\)/.test(text)) {
        const importLine = cjs ? `const { Clikgate } = require('${SERVER_SDK.node}');` : `import { Clikgate } from '${SERVER_SDK.node}';`;
        const at = afterImports(out, 'js');
        out = insertLines(out, at < 0 ? 0 : at, [importLine]);
      } else {
        break; // @clikgate/node is imported under some other shape: don't guess the names
      }
      pb.reminder(`The ${KEEP} route creates a Clikgate client: set CLIKGATE_API_KEY on your server (never in the page).`);
    }
    pb.change(f, out, `add the ${KEEP} route`);
    return 'added';
  }
  pb.manual(MANUAL_KEEP, `The file that creates your Express app (const app = express()) wasn't found, or has a shape the setup command doesn't edit. Add this after it, before your other routes:`, manualSnippet);
  return 'manual';
}

// Laravel: Route::clikgateKeep('/cg/keep'); in routes/web.php

function planLaravel(pb: PlanBuilder): KeepResult {
  const f = 'routes/web.php';
  const line = `Route::clikgateKeep('${KEEP}');`;
  const text = pb.current(f);
  if (text === null || !text.includes('<?php')) {
    pb.manual(MANUAL_KEEP, `${f} wasn't found. Add this to your web routes:`, line);
    return 'manual';
  }
  if (has(text, 'clikgateKeep') || has(text, `'${KEEP}'`) || has(text, `"${KEEP}"`)) {
    pb.done(`${KEEP} route (${f})`);
    return 'present';
  }
  if (/\?>\s*$/.test(text)) {
    pb.manual(MANUAL_KEEP, `${f} ends with a closing ?> tag; add this before it:`, line);
    return 'manual';
  }
  pb.change(f, appendBlock(text, ['// Saves the Clikgate click ID from your own server (the web script\'s data-server-endpoint).', line]), `add the ${KEEP} route`);
  return 'added';
}

// Django: path("cg/keep", clikgate.django.keep_view()) in the root urls.py

function djangoRootUrls(pb: PlanBuilder, root: string): string | undefined {
  const manage = readIfExists(path.join(root, 'manage.py'));
  const settingsModule = manage && /DJANGO_SETTINGS_MODULE['"]\s*,\s*['"]([\w.]+)['"]/.exec(manage)?.[1];
  if (settingsModule) {
    const base = settingsModule.split('.').join('/');
    for (const s of [`${base}.py`, `${base}/__init__.py`, `${base}/base.py`]) {
      const t = pb.current(s);
      const conf = t && /^ROOT_URLCONF\s*=\s*['"]([\w.]+)['"]/m.exec(t)?.[1];
      if (conf) {
        const f = `${conf.split('.').join('/')}.py`;
        if (pb.current(f) !== null) return f;
      }
    }
  }
  // Fallback: the one urls.py (two folders deep at most) that routes the admin site.
  const found: string[] = [];
  for (const d of ['', ...list(root).filter((n) => !SKIP.has(n) && !n.startsWith('.') && isDir(path.join(root, n)))]) {
    const f = d ? `${d}/urls.py` : 'urls.py';
    const t = pb.current(f);
    if (t && /urlpatterns/.test(t) && /admin\.site\.urls/.test(t)) found.push(f);
  }
  return found.length === 1 ? found[0] : undefined;
}

function planDjango(pb: PlanBuilder, ctx: KeepContext): KeepResult {
  const snippet = ['import clikgate.django', '', 'urlpatterns = [', `    path("${KEEP.slice(1)}", clikgate.django.keep_view()),`, '    # …your other routes', ']'].join('\n');
  const f = djangoRootUrls(pb, ctx.root);
  if (!f) {
    pb.manual(MANUAL_KEEP, "Your project's root urls.py (ROOT_URLCONF) wasn't found. Add the route to it:", snippet);
    return 'manual';
  }
  const text = pb.current(f)!;
  if (has(text, 'keep_view') || has(text, `"${KEEP.slice(1)}"`) || has(text, `'${KEEP.slice(1)}'`)) {
    pb.done(`${KEEP} route (${f})`);
    return 'present';
  }
  const ls = text.split(/\r?\n/);
  const at = ls.findIndex((l) => /^urlpatterns\s*=\s*\[\s*$/.test(l));
  const pathImported = /from\s+django\.urls\s+import\s+\(?[^)]*?\bpath\b/.test(text);
  if (at < 0 || !pathImported || afterImports(text, 'py') < 0) {
    pb.manual(MANUAL_KEEP, `${f} has a shape the setup command doesn't edit (it looks for "urlpatterns = [" on its own line and "from django.urls import path"). Add:`, snippet);
    return 'manual';
  }
  const indent = /^(\s+)\S/.exec(ls[at + 1] ?? '')?.[1] ?? '    ';
  let out = insertLines(text, at + 1, [`${indent}path("${KEEP.slice(1)}", clikgate.django.keep_view()),`]);
  if (!/^import clikgate\.django\s*$/m.test(text)) out = insertLines(out, afterImports(out, 'py'), ['import clikgate.django']);
  pb.change(f, out, `add the ${KEEP} route`);
  return 'added';
}

// Spring Boot: clikgate.keep-route.enabled=true

function planSpring(pb: PlanBuilder, ctx: KeepContext): KeepResult {
  const res = 'src/main/resources';
  const prop = 'clikgate.keep-route.enabled=true';
  const yamlBlock = ['clikgate:', '  keep-route:', '    enabled: true'];
  const props = `${res}/application.properties`;
  const yml = [`${res}/application.yml`, `${res}/application.yaml`].find((f) => pb.current(f) !== null);
  const ptext = pb.current(props);
  if (ptext !== null || !yml) {
    if (ptext === null && !isDir(path.join(ctx.root, res))) {
      pb.manual(MANUAL_KEEP, `${res} wasn't found. Add this to your application.properties:`, prop);
      return 'manual';
    }
    const m = ptext && /^\s*clikgate\.keep-route\.enabled\s*[=:]\s*(\S+)/m.exec(ptext);
    if (m) {
      if (m[1] === 'true') {
        pb.done(`${KEEP} route (${props})`);
        return 'present';
      }
      pb.manual(MANUAL_KEEP, `${props} sets clikgate.keep-route.enabled=${m[1]}; it was left as it is. To turn the route on:`, prop);
      return 'manual';
    }
    pb.change(props, ptext === null ? `${prop}\n` : appendBlock(ptext, ['# Saves the Clikgate click ID from your own server at /cg/keep (the web script\'s data-server-endpoint).', prop]), `turn on the ${KEEP} route`);
    return 'added';
  }
  const ytext = pb.current(yml)!;
  if (/keep-route:\s*\n\s+enabled:\s*true\b/.test(ytext)) {
    pb.done(`${KEEP} route (${yml})`);
    return 'present';
  }
  if (/^clikgate:/m.test(ytext) || /^---/m.test(ytext)) {
    pb.manual(MANUAL_KEEP, `${yml} already has a clikgate: section or several documents; add this to it yourself:`, yamlBlock.join('\n'));
    return 'manual';
  }
  pb.change(yml, appendBlock(ytext, yamlBlock), `turn on the ${KEEP} route`);
  return 'added';
}

// ASP.NET Core: app.MapClikgateKeep("/cg/keep"); in Program.cs

function planAspNet(pb: PlanBuilder): KeepResult {
  const f = 'Program.cs';
  const line = `app.MapClikgateKeep("${KEEP}");`;
  const text = pb.current(f);
  if (text !== null && has(text, 'MapClikgateKeep')) {
    pb.done(`${KEEP} route (${f})`);
    return 'present';
  }
  const ls = text?.split(/\r?\n/) ?? [];
  const built = ls.some((l) => /^var\s+app\s*=\s*\w+\.Build\(\s*\)\s*;/.test(l));
  const runs = ls.map((l, i) => [l, i] as const).filter(([l]) => /^app\.Run(Async)?\(.*\)\s*;/.test(l));
  if (text === null || !built || runs.length !== 1) {
    pb.manual(MANUAL_KEEP, `${f} has no top-level "var app = builder.Build();" and "app.Run();" the setup command can place the route between. Add this before app.Run():`, line);
    return 'manual';
  }
  pb.change(f, insertLines(text, runs[0][1], [line, '']), `add the ${KEEP} route`);
  return 'added';
}

function serverDependencyPresent(server: WebsiteServer, pb: PlanBuilder, root: string): boolean {
  switch (server) {
    case 'nextjs':
    case 'express':
      return pkgHas(readPkg(root), SERVER_SDK.node);
    case 'laravel':
      return has(pb.current('composer.json'), `"${SERVER_SDK.laravel}"`);
    case 'django':
      return ['requirements.txt', 'pyproject.toml', 'Pipfile'].some((f) => /(?<![\w.-])clikgate(?![\w-])/i.test(pb.current(f) ?? ''));
    case 'spring-boot':
      return ['pom.xml', 'build.gradle', 'build.gradle.kts'].some((f) => has(pb.current(f), 'clikgate-spring-boot-starter'));
    case 'aspnet-core':
      return csprojFiles(root).some((f) => has(pb.current(f), `"${SERVER_SDK.dotnet}"`));
    default:
      return false;
  }
}

/** Adds the keep route for a server framework (never WordPress or Shopify). */
export function planKeepRoute(pb: PlanBuilder, server: KeepServer, ctx: KeepContext): KeepResult {
  const r =
    server === 'nextjs' ? planNext(pb, ctx)
    : server === 'express' ? planExpress(pb, ctx)
    : server === 'laravel' ? planLaravel(pb)
    : server === 'django' ? planDjango(pb, ctx)
    : server === 'spring-boot' ? planSpring(pb, ctx)
    : planAspNet(pb);
  installStep(pb, server, ctx, serverDependencyPresent(server, pb, ctx.root));
  return r;
}

// ------------------------------------------------------------------------------- script tag

const ENDPOINT_ATTR = `data-server-endpoint="${KEEP}"`;
const TAG_FILE = /\.(html?|[jt]sx?|mjs|php|cshtml|razor|ejs|hbs|handlebars|njk|twig|liquid|erb|vue|svelte|astro)$/i;
const SCRIPT_TAG = /<script\b[^>]*clikgate\.js[^>]*>/gi;

export function scriptTag(webKey: string, endpoint: boolean): string {
  return `<script src="${WEB_SCRIPT_URL}" data-web-key="${webKey}"${endpoint ? ` ${ENDPOINT_ATTR}` : ''} async></script>`;
}

/** Files under root that contain the Clikgate web script tag. */
export function findScriptTags(root: string, maxDepth = 6): string[] {
  const out: string[] = [];
  walkDirs(root, maxDepth, (dir) => {
    for (const name of list(dir)) {
      if (!TAG_FILE.test(name)) continue;
      const p = path.join(dir, name);
      const t = readIfExists(p);
      if (t === undefined || t.length > 512 * 1024) continue;
      if (new RegExp(SCRIPT_TAG.source, 'i').test(t)) out.push(rel(root, p));
    }
  });
  return out.sort();
}

/** Adds `data-server-endpoint` after `data-web-key` (else after `src`) in every Clikgate script tag that lacks it. */
export function addEndpointAttribute(text: string): string {
  return text.replace(SCRIPT_TAG, (tag) => {
    if (/data-server-endpoint/i.test(tag)) return tag;
    const value = `=(?:"[^"]*"|'[^']*'|\\{[^}]*\\})`;
    for (const attr of ['data-web-key', 'src']) {
      const m = new RegExp(`\\s${attr}${value}`, 'i').exec(tag);
      if (m) return tag.slice(0, m.index + m[0].length) + ` ${ENDPOINT_ATTR}` + tag.slice(m.index + m[0].length);
    }
    return tag;
  });
}

/** Layout files a new tag can go into (before `</head>`), per server. */
const LAYOUTS: Record<WebsiteServer | 'none', string[]> = {
  none: ['index.html', 'public/index.html', 'src/index.html'],
  nextjs: [],
  express: ['public/index.html', 'views/layout.ejs', 'views/layout.hbs', 'views/layouts/main.hbs', 'index.html'],
  laravel: ['resources/views/layouts/app.blade.php', 'resources/views/layouts/guest.blade.php', 'resources/views/app.blade.php'],
  django: ['templates/base.html', 'templates/layout.html'],
  'spring-boot': ['src/main/resources/templates/layout.html', 'src/main/resources/static/index.html'],
  'aspnet-core': ['Pages/Shared/_Layout.cshtml', 'Views/Shared/_Layout.cshtml'],
  wordpress: [],
  shopify: [],
};

function insertBeforeHead(text: string, tag: string): string | undefined {
  const closes = text.match(/<\/head\s*>/gi) ?? [];
  if (closes.length !== 1) return undefined;
  const nl = eol(text);
  const ls = text.split(/\r?\n/);
  const i = ls.findIndex((l) => /<\/head\s*>/i.test(l));
  const line = ls[i];
  if (/^\s*<\/head\s*>\s*$/i.test(line)) {
    const own = /^(\s*)/.exec(line)![1];
    const prev = ls.slice(0, i).reverse().find((l) => l.trim() !== '');
    const prevIndent = prev ? /^(\s*)/.exec(prev)![1] : '';
    const indent = prevIndent.length > own.length ? prevIndent : own + (own.includes('\t') ? '\t' : '  ');
    ls.splice(i, 0, indent + tag);
    return ls.join(nl);
  }
  return text.replace(/<\/head\s*>/i, (m) => `${tag}${m}`);
}

export interface TagPlanInput {
  server: WebsiteServer | 'none';
  endpoint: boolean;
  webKey: string;
  existing: string[];
}

/** Finds the tag and adds the attribute, or inserts a new tag into a layout, or prints it as a manual step. */
export function planScriptTag(pb: PlanBuilder, input: TagPlanInput): void {
  const { existing, endpoint } = input;
  if (existing.length) {
    for (const f of existing) {
      const text = pb.current(f)!;
      if (/data-days\s*=\s*["']?7["'}]?/i.test(text.match(SCRIPT_TAG)?.join(' ') ?? '')) {
        pb.reminder(`${f}: the script tag sets data-days="7". The web script now keeps the click ID for 30 days by default; remove data-days to use it.`);
      }
      if (!endpoint) {
        pb.done(`Clikgate web script (${f})`);
        continue;
      }
      const out = addEndpointAttribute(text);
      if (out === text) {
        if ((text.match(SCRIPT_TAG) ?? []).every((t) => /data-server-endpoint/i.test(t))) pb.done(`${ENDPOINT_ATTR} (${f})`);
        else pb.manual('Script tag', `The Clikgate script tag in ${f} has a shape the setup command doesn't edit. Add ${ENDPOINT_ATTR} to it.`);
        continue;
      }
      pb.change(f, out, `add ${ENDPOINT_ATTR} to the Clikgate script`, `${ENDPOINT_ATTR} (${f})`);
    }
    return;
  }
  const tag = scriptTag(input.webKey, endpoint);
  if (input.server === 'nextjs') {
    pb.manual(
      'Web script',
      'Next.js layouts are JSX, so the setup command doesn\'t insert the tag. In app/layout.tsx (or pages/_document.tsx), add next/script:',
      [
        "import Script from 'next/script';",
        `<Script src="${WEB_SCRIPT_URL}" data-web-key="${input.webKey}"${endpoint ? ` ${ENDPOINT_ATTR}` : ''} strategy="afterInteractive" />`,
      ].join('\n')
    );
    return;
  }
  let inserted = 0;
  for (const f of LAYOUTS[input.server]) {
    const text = pb.current(f);
    if (text === null) continue;
    const out = insertBeforeHead(text, tag);
    if (out === undefined) continue;
    pb.change(f, out, 'add the Clikgate web script');
    inserted++;
  }
  if (inserted) {
    pb.reminder('Pages that use a different layout need the same script tag in their <head>.');
    return;
  }
  pb.manual('Web script', "No page layout the setup command can edit was found. Add this tag to the <head> of every page (in your shared layout):", tag);
}

// ------------------------------------------------------------------------------------- flow

async function chooseWebsite(opts: Options, ui: UI, root: string): Promise<{ server?: WebsiteServer | 'none'; root: string; detected: boolean }> {
  const found = detectWebsite(root);
  if (opts.websiteServer) {
    const match = opts.websiteServer === 'none' ? undefined : found.find((c) => c.server === opts.websiteServer);
    return { server: opts.websiteServer, root: match?.root ?? root, detected: false };
  }
  if (found.length === 0) return { root, detected: false };
  let pick = found[0];
  if (found.length > 1) {
    const [i] = await ui.choose(
      'Several websites were found. Which one should Clikgate set up?',
      found.map((c) => `${SERVER_LABEL[c.server]}  ${rel(root, c.root) || '.'}  (${c.evidence})`)
    );
    pick = found[i];
  }
  const where = pick.root !== root ? ` in ${rel(root, pick.root)}` : '';
  const kind = pick.server === 'shopify' ? 'a Shopify theme' : `a ${SERVER_LABEL[pick.server]} website`;
  ui.out(`Found ${kind}${where} (${pick.evidence}).`);
  return { server: pick.server, root: pick.root, detected: true };
}

async function askServer(opts: Options, ui: UI): Promise<KeepServer | 'none' | 'other'> {
  if (opts.yes || !ui.interactive) {
    ui.out(`No website server was recognised, so no ${KEEP} route is added. To add one, run again with --website-server <${WEBSITE_SERVERS.filter((s) => s !== 'wordpress' && s !== 'shopify').join('|')}>.`);
    return 'none';
  }
  if (!(await ui.confirm(OWN_SERVER_QUESTION, false))) return 'none';
  const options: (KeepServer | 'other')[] = ['nextjs', 'express', 'laravel', 'django', 'spring-boot', 'aspnet-core', 'other'];
  const [i] = await ui.choose(
    'Which framework does it use?',
    options.map((o) => (o === 'other' ? 'Something else' : SERVER_LABEL[o]))
  );
  return options[i];
}

async function chooseWebKey(opts: Options, ui: UI): Promise<{ key: string; placeholder: boolean }> {
  const check = (k: string) => {
    if (SDK_KEY_ANY.test(k) || /^cg_(live|test)_/.test(k)) {
      throw new Exit(EXIT.PROBLEMS, "That's not a web key. Use your publishable web key (cgw_test_… or cgw_live_…, from Settings › Developers › Web keys); never put an API key or SDK key in a page.");
    }
    if (!WEB_KEY.test(k)) throw new Exit(EXIT.PROBLEMS, '--web-key must be a publishable web key (cgw_test_… or cgw_live_…), from Settings › Developers › Web keys.');
    return k;
  };
  if (opts.webKey !== undefined) return { key: check(opts.webKey), placeholder: false };
  if (!opts.yes && ui.interactive) {
    const typed = await ui.ask('Your web key (cgw_test_… while setting up; Settings › Developers › Web keys), or Enter to add it later:');
    if (typed) return { key: check(typed), placeholder: false };
  }
  return { key: WEB_KEY_PLACEHOLDER, placeholder: true };
}

export async function runWebsite(opts: Options, deps: Deps): Promise<number> {
  const { ui } = deps;
  const cwd = path.resolve(opts.cwd);
  if (!exists(cwd)) throw new Exit(EXIT.PROBLEMS, `${opts.cwd} doesn't exist.`);
  const chosen = await chooseWebsite(opts, ui, cwd);
  const root = chosen.root;

  if (chosen.server === 'wordpress') {
    ui.out('The Clikgate WordPress plugin keeps the click ID from your server itself (its keep route), so no route is added and nothing in this folder is changed.');
    ui.out('Install it from WordPress › Plugins › Add New (search "Clikgate"), then connect it in its settings.');
    ui.out(SAFARI_NOTE);
    return EXIT.OK;
  }
  if (chosen.server === 'shopify') {
    ui.out('The Clikgate Shopify app keeps the click ID in cart attributes, so no route is added and nothing in this theme is changed.');
    ui.out('That covers visitors who create a cart in the same browser before the cookie expires. Install the app from the Shopify App Store and turn on its app embed in the theme editor.');
    ui.out(SAFARI_NOTE);
    return EXIT.OK;
  }

  let server: KeepServer | 'none' | 'other' | undefined = chosen.server;
  if (server === undefined) {
    ui.out(SAFARI_NOTE);
    server = await askServer(opts, ui);
  } else if (server !== 'none') {
    ui.out(SAFARI_NOTE);
  }

  const existing = findScriptTags(root);
  const key = existing.length ? { key: WEB_KEY_PLACEHOLDER, placeholder: false } : await chooseWebKey(opts, ui);
  const pb = new PlanBuilder(root);
  let keep: KeepResult | 'none' = 'none';
  if (server === 'other') {
    pb.manual(MANUAL_KEEP, `Add a POST ${KEEP} route on the server that serves your website, with the Clikgate server SDK's keep route (clickIds.keepRoute(), or your framework's equivalent; see https://clikgate.com/docs). Then add ${ENDPOINT_ATTR} to the script tag.`);
    keep = 'manual';
  } else if (server !== 'none') {
    keep = planKeepRoute(pb, server, { root, packageManager: detectPackageManager(root) });
  }
  let endpoint = keep === 'added' || keep === 'present';
  if (keep === 'manual' && !opts.yes && !opts.dryRun && ui.interactive) {
    endpoint = await ui.confirm(`Has your server already got the ${KEEP} route (so the script tag can use it)?`, false);
  }
  if (keep === 'manual' && !endpoint) {
    pb.manual('Script tag', `Once the ${KEEP} route is live on your server, add ${ENDPOINT_ATTR} to the Clikgate script tag (run this command again to do it).`);
  }
  planScriptTag(pb, { server: server === 'other' ? 'none' : server, endpoint, webKey: key.key, existing });
  if (key.placeholder && !existing.length) {
    pb.manual('Web key', `Replace ${WEB_KEY_PLACEHOLDER} with your publishable web key (Settings › Developers › Web keys). A web key isn't secret and isn't an API key.`);
  }
  const plan = pb.build();

  const tree = treeState(root);
  if (tree.isRepo && tree.dirty.length && !opts.dryRun && plan.steps.some((s) => s.kind === 'change')) {
    ui.out(paint(ui, 'yellow', `! This project has ${tree.dirty.length} uncommitted change${tree.dirty.length > 1 ? 's' : ''}. Committing first makes the setup easy to review and undo.`));
    if (!opts.yes && !(await ui.confirm('Continue anyway?', false))) return EXIT.CANCELLED;
  }
  const reviewed = await reviewAndApply(opts, deps, plan, tree);
  if ('exit' in reviewed) return reviewed.exit;
  printWebsiteSummary(ui, plan, reviewed.applied);
  ui.out('');
  ui.out(paint(ui, 'bold', SUCCESS_LINE));
  return EXIT.OK;
}

function printWebsiteSummary(ui: UI, plan: Plan, applied: { written: string[]; created: string[] } | undefined): void {
  ui.out('');
  ui.out(paint(ui, 'bold', 'Summary'));
  if (applied) {
    for (const f of applied.written) ui.out(`  ${paint(ui, 'green', '✓')} changed ${f}`);
    for (const f of applied.created) ui.out(`  ${paint(ui, 'green', '✓')} created ${f}`);
  }
  const done = plan.steps.filter((s) => s.kind === 'done');
  if (done.length) ui.out(`  ${paint(ui, 'green', '✓')} ${done.length} step${done.length > 1 ? 's were' : ' was'} already set up`);
  printManual(ui, plan);
  if (plan.reminders.length) {
    ui.out('');
    ui.out(paint(ui, 'bold', 'Reminders:'));
    for (const r of plan.reminders) ui.out(`  • ${r}`);
  }
}
