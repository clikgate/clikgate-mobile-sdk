import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { describe, expect, it } from 'vitest';
import { parseArgs, UsageError } from '../src/args';
import { SAFARI_NOTE } from '../src/constants';
import { main } from '../src/index';
import { addEndpointAttribute, detectWebsite, detectWebsiteIn, OWN_SERVER_QUESTION } from '../src/website';
import { ScriptedUI, snapshotTree } from './helpers';

const KEY = 'cgw_test_abc123';
const TAG = `<script src="https://sdk.clikgate.com/v1/static/clikgate.js" data-web-key="${KEY}" async></script>`;
const TAG_WITH_ENDPOINT = `<script src="https://sdk.clikgate.com/v1/static/clikgate.js" data-web-key="${KEY}" data-server-endpoint="/cg/keep" async></script>`;

const HTML = '<!doctype html>\n<html>\n  <head>\n    <meta charset="utf-8">\n    <title>Acme Bakery</title>\n  </head>\n  <body></body>\n</html>\n';

function site(files: Record<string, string>): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'clikgate-site-'));
  for (const [f, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, f)), { recursive: true });
    fs.writeFileSync(path.join(dir, f), text);
  }
  return dir;
}

function read(dir: string, f: string): string {
  return fs.readFileSync(path.join(dir, f), 'utf8');
}

async function run(dir: string, extra: string[] = [], ui = new ScriptedUI([], false)): Promise<{ code: number; ui: ScriptedUI }> {
  const code = await main(['website', '--cwd', dir, '--web-key', KEY, ...extra], { ui });
  return { code, ui };
}

/** Applies with --yes, then runs again: the second run must change nothing. */
async function applyTwice(dir: string, extra: string[] = []): Promise<ScriptedUI> {
  const first = await run(dir, ['--yes', ...extra]);
  expect(first.code).toBe(0);
  const after = snapshotTree(dir);
  const second = await run(dir, ['--yes', ...extra]);
  expect(second.code).toBe(0);
  expect(second.ui.text).toContain('Everything is already set up.');
  expect(snapshotTree(dir)).toEqual(after);
  return first.ui;
}

const NEXT_PKG = JSON.stringify({ name: 'acme-web', dependencies: { next: '16.0.0', react: '19.2.0' } }, null, 2) + '\n';
const EXPRESS_PKG = JSON.stringify({ name: 'acme-api', main: 'server.js', dependencies: { express: '5.1.0' } }, null, 2) + '\n';

describe('website detection (R.2)', () => {
  it.each([
    ['nextjs', { 'package.json': NEXT_PKG }],
    ['express', { 'package.json': EXPRESS_PKG }],
    ['laravel', { 'composer.json': '{"require": {"php": "^8.3", "laravel/framework": "^12.0"}}' }],
    ['laravel', { artisan: '#!/usr/bin/env php\n' }],
    ['django', { 'manage.py': '#!/usr/bin/env python\n' }],
    ['django', { 'requirements.txt': 'Django==5.2\ngunicorn==23.0\n' }],
    ['django', { 'pyproject.toml': '[project]\ndependencies = ["django>=5.2"]\n' }],
    ['django', { Pipfile: '[packages]\ndjango = "*"\n' }],
    ['spring-boot', { 'pom.xml': '<project><parent><artifactId>spring-boot-starter-parent</artifactId></parent></project>' }],
    ['spring-boot', { 'build.gradle.kts': 'plugins { id("org.springframework.boot") version "3.5.0" }\ndependencies { implementation("org.springframework.boot:spring-boot-starter-web") }\n' }],
    ['aspnet-core', { 'AcmeWeb.csproj': '<Project Sdk="Microsoft.NET.Sdk.Web"></Project>' }],
    ['wordpress', { 'wp-config.php': '<?php\n' }],
    ['wordpress', { 'wp-content/index.php': '<?php\n' }],
    ['shopify', { 'config/settings_schema.json': '[]', 'layout/theme.liquid': '<html></html>' }],
  ])('%s', (server, files) => {
    expect(detectWebsiteIn(site(files)).map((c) => c.server)).toEqual([server]);
  });
  it('ignores packages that only start with "django" and plain .NET projects', () => {
    expect(detectWebsiteIn(site({ 'requirements.txt': 'django-environ==0.12\ndjangorestframework==3.16\n' }))).toEqual([]);
    expect(detectWebsiteIn(site({ 'Tool.csproj': '<Project Sdk="Microsoft.NET.Sdk"></Project>' }))).toEqual([]);
  });
  it('monorepo: finds the website below the workspace root', () => {
    const dir = site({ 'package.json': '{"name": "acme", "private": true}', 'apps/web/package.json': NEXT_PKG });
    expect(detectWebsite(dir).map((c) => [c.server, path.relative(dir, c.root)])).toEqual([['nextjs', path.join('apps', 'web')]]);
  });
  it('a detected server is announced, not asked about', async () => {
    const ui = new ScriptedUI([], true);
    const dir = site({ 'package.json': NEXT_PKG, 'tsconfig.json': '{}', 'app/layout.tsx': 'export default function L() {}\n' });
    await run(dir, ['--dry-run'], ui);
    expect(ui.text).toContain('Found a Next.js website (package.json lists next).');
    expect(ui.asked).not.toContain(OWN_SERVER_QUESTION);
  });
});

describe('"Does your website have its own server?"', () => {
  it('is asked when nothing is detected; no → only the script tag', async () => {
    const dir = site({ 'index.html': HTML });
    // Interactive: the plan is confirmed with "Apply?".
    const scripted = new ScriptedUI([[/own server/, false], [/Apply\?/, true]], true);
    expect((await run(dir, [], scripted)).code).toBe(0);
    expect(scripted.asked).toContain(OWN_SERVER_QUESTION);
    expect(scripted.text).toContain(SAFARI_NOTE);
    expect(read(dir, 'index.html')).toContain(`    ${TAG}\n  </head>`);
  });
  it('yes → asks the framework and adds its route and the attribute', async () => {
    const dir = site({ 'index.html': HTML, 'server.js': "const express = require('express');\n\nconst app = express();\n\napp.listen(3000);\n" });
    const ui = new ScriptedUI([[/own server/, true], [/Which framework/, [1]], [/Apply\?/, true]], true);
    expect((await run(dir, [], ui)).code).toBe(0);
    expect(read(dir, 'server.js')).toContain("app.post('/cg/keep', clikgate.clickIds.keepRoute().express);");
    expect(read(dir, 'index.html')).toContain(TAG_WITH_ENDPOINT);
  });
  it('"Something else" → manual route step, and no attribute unless the route already exists', async () => {
    const dir = site({ 'index.html': HTML });
    const ui = new ScriptedUI([[/own server/, true], [/Which framework/, [6]], [/already got the \/cg\/keep route/, false], [/Apply\?/, true]], true);
    expect((await run(dir, [], ui)).code).toBe(0);
    expect(read(dir, 'index.html')).toContain(TAG);
    expect(ui.text).toContain('Keep route: Add a POST /cg/keep route');
    const yes = site({ 'index.html': HTML });
    const ui2 = new ScriptedUI([[/own server/, true], [/Which framework/, [6]], [/already got the \/cg\/keep route/, true], [/Apply\?/, true]], true);
    expect((await run(yes, [], ui2)).code).toBe(0);
    expect(read(yes, 'index.html')).toContain(TAG_WITH_ENDPOINT);
  });
  it('non-interactive or --yes: not asked; no route, with the flag to use', async () => {
    const dir = site({ 'index.html': HTML });
    const { code, ui } = await run(dir, ['--yes']);
    expect(code).toBe(0);
    expect(ui.asked).not.toContain(OWN_SERVER_QUESTION);
    expect(ui.text).toContain('run again with --website-server <nextjs|express|laravel|django|spring-boot|aspnet-core>');
    expect(read(dir, 'index.html')).toContain(TAG);
    expect(read(dir, 'index.html')).not.toContain('data-server-endpoint');
  });
  it('non-interactive without --yes prints the diff and applies nothing (exit 2)', async () => {
    const dir = site({ 'index.html': HTML });
    const before = snapshotTree(dir);
    const { code, ui } = await run(dir);
    expect(code).toBe(2);
    expect(ui.text).toContain('Not applied: run in a terminal to confirm, or pass --yes.');
    expect(snapshotTree(dir)).toEqual(before);
  });
});

describe('--website-server', () => {
  it('parses, and refuses bad values or other commands', () => {
    expect(parseArgs(['website', '--website-server', 'django']).websiteServer).toBe('django');
    expect(parseArgs(['website', '--website-server=none']).websiteServer).toBe('none');
    expect(() => parseArgs(['website', '--website-server', 'rails'])).toThrow(UsageError);
    expect(() => parseArgs(['--website-server', 'django'])).toThrow(/website command only/);
    expect(() => parseArgs(['website', '--platform', 'ios'])).toThrow(UsageError);
  });
  it('skips detection and the question', async () => {
    const dir = site({ 'index.html': HTML, 'server.js': "const express = require('express');\nconst app = express();\n" });
    const ui = new ScriptedUI([[/Apply\?/, true]], true);
    expect((await run(dir, ['--website-server', 'express'], ui)).code).toBe(0);
    expect(ui.asked).not.toContain(OWN_SERVER_QUESTION);
    expect(read(dir, 'server.js')).toContain("app.post('/cg/keep'");
  });
  it('none: a detected framework gets no route', async () => {
    const dir = site({ 'package.json': EXPRESS_PKG, 'server.js': "const express = require('express');\nconst app = express();\n", 'public/index.html': HTML });
    expect((await run(dir, ['--yes', '--website-server', 'none'])).code).toBe(0);
    expect(read(dir, 'server.js')).not.toContain('/cg/keep');
    expect(read(dir, 'public/index.html')).toContain(TAG);
  });
});

describe('keep route edits', () => {
  it('Next.js App Router: creates app/cg/keep/route.ts (src/app too); idempotent', async () => {
    const dir = site({ 'package.json': NEXT_PKG, 'tsconfig.json': '{}', 'src/app/layout.tsx': 'export default function L() {}\n' });
    const ui = await applyTwice(dir);
    const route = read(dir, 'src/app/cg/keep/route.ts');
    expect(route).toContain("import { Clikgate } from '@clikgate/node';");
    expect(route).toContain('export const POST = clikgate.clickIds.keepRoute();');
    expect(ui.text).toContain('npm install @clikgate/node');
    expect(ui.text).toContain('import Script from \'next/script\';');
    expect(ui.text).toContain('data-server-endpoint="/cg/keep" strategy="afterInteractive"');
  });
  it('Next.js: an existing different route file is never overwritten', async () => {
    const mine = 'export async function POST() { return new Response(null); }\n';
    const dir = site({ 'package.json': NEXT_PKG, 'app/cg/keep/route.ts': mine });
    expect((await run(dir, ['--yes'])).code).toBe(0);
    expect(read(dir, 'app/cg/keep/route.ts')).toBe(mine);
  });
  it('Next.js Pages Router only: manual step', async () => {
    const dir = site({ 'package.json': NEXT_PKG, 'pages/index.tsx': 'export default function H() {}\n' });
    const { ui } = await run(dir, ['--yes']);
    expect(ui.text).toContain("a Pages Router API route can't answer at /cg/keep");
    expect(fs.existsSync(path.join(dir, 'pages/cg'))).toBe(false);
  });
  it('Express (CommonJS): require, client and route after express(); idempotent', async () => {
    const dir = site({ 'package.json': EXPRESS_PKG, 'server.js': "const express = require('express');\n\nconst app = express();\napp.use(express.json());\n\napp.listen(3000);\n", 'public/index.html': HTML });
    await applyTwice(dir);
    expect(read(dir, 'server.js')).toBe(
      "const express = require('express');\nconst { Clikgate } = require('@clikgate/node');\n\nconst app = express();\nconst clikgate = new Clikgate();\napp.post('/cg/keep', clikgate.clickIds.keepRoute().express);\napp.use(express.json());\n\napp.listen(3000);\n"
    );
    expect(read(dir, 'public/index.html')).toContain(TAG_WITH_ENDPOINT);
  });
  it('Express (ESM, existing Clikgate client): reuses it', async () => {
    const src = "import express from 'express';\nimport { Clikgate } from '@clikgate/node';\n\nconst cg = new Clikgate();\nconst server = express();\n";
    const dir = site({ 'package.json': JSON.stringify({ dependencies: { express: '5.1.0', '@clikgate/node': '^1.2.0' } }), 'index.js': src });
    const ui = await applyTwice(dir);
    expect(read(dir, 'index.js')).toBe(src + "server.post('/cg/keep', cg.clickIds.keepRoute().express);\n");
    expect(ui.text).not.toContain('npm install @clikgate/node');
  });
  it('Express: an app created inside a function is a manual step', async () => {
    const src = "import express from 'express';\nexport function make() {\n  const app = express();\n  return app;\n}\n";
    const dir = site({ 'package.json': EXPRESS_PKG, 'server.js': src });
    const { ui } = await run(dir, ['--yes']);
    expect(read(dir, 'server.js')).toBe(src);
    expect(ui.text).toContain("app.post('/cg/keep', clikgate.clickIds.keepRoute().express);");
  });
  it('Laravel: Route::clikgateKeep in routes/web.php; idempotent; skipped when present', async () => {
    const web = "<?php\n\nuse Illuminate\\Support\\Facades\\Route;\n\nRoute::get('/', function () {\n    return view('welcome');\n});\n";
    const dir = site({ artisan: '', 'routes/web.php': web, 'resources/views/layouts/app.blade.php': HTML });
    await applyTwice(dir);
    expect(read(dir, 'routes/web.php')).toMatch(/\n\n\/\/ Saves the Clikgate click ID[^\n]*\nRoute::clikgateKeep\('\/cg\/keep'\);\n$/);
    expect(read(dir, 'resources/views/layouts/app.blade.php')).toContain(TAG_WITH_ENDPOINT);
    const already = site({ artisan: '', 'routes/web.php': web + "Route::clikgateKeep('/cg/keep');\n" });
    const before = snapshotTree(already);
    await run(already, ['--yes']);
    expect(read(already, 'routes/web.php')).toBe(before.get('routes/web.php'));
  });
  it('Django: path() in the ROOT_URLCONF urls.py; idempotent', async () => {
    const dir = site({
      'manage.py': "import os\nos.environ.setdefault('DJANGO_SETTINGS_MODULE', 'acme.settings')\n",
      'acme/settings.py': "ROOT_URLCONF = 'acme.urls'\n",
      'acme/urls.py': 'from django.contrib import admin\nfrom django.urls import path\n\nurlpatterns = [\n    path("admin/", admin.site.urls),\n]\n',
      'templates/base.html': HTML,
    });
    await applyTwice(dir);
    expect(read(dir, 'acme/urls.py')).toBe(
      'from django.contrib import admin\nfrom django.urls import path\nimport clikgate.django\n\nurlpatterns = [\n    path("cg/keep", clikgate.django.keep_view()),\n    path("admin/", admin.site.urls),\n]\n'
    );
    expect(read(dir, 'templates/base.html')).toContain(TAG_WITH_ENDPOINT);
  });
  it('Django: an unusual urls.py is a manual step', async () => {
    const urls = 'from django.urls import path\nurlpatterns = [path("admin/", None)]\n';
    const dir = site({ 'manage.py': "os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'acme.settings')\n", 'acme/settings.py': "ROOT_URLCONF = 'acme.urls'\n", 'acme/urls.py': urls });
    const { ui } = await run(dir, ['--yes']);
    expect(read(dir, 'acme/urls.py')).toBe(urls);
    expect(ui.text).toContain('path("cg/keep", clikgate.django.keep_view())');
  });
  it('Spring Boot: application.properties, or application.yml; idempotent', async () => {
    const pom = '<project><artifactId>spring-boot-starter-parent</artifactId></project>';
    const props = site({ 'pom.xml': pom, 'src/main/resources/application.properties': 'spring.application.name=acme\n' });
    await applyTwice(props);
    expect(read(props, 'src/main/resources/application.properties')).toMatch(/^spring\.application\.name=acme\n\n#[^\n]*\nclikgate\.keep-route\.enabled=true\n$/);
    const yml = site({ 'pom.xml': pom, 'src/main/resources/application.yml': 'spring:\n  application:\n    name: acme\n' });
    await applyTwice(yml);
    expect(read(yml, 'src/main/resources/application.yml')).toBe('spring:\n  application:\n    name: acme\n\nclikgate:\n  keep-route:\n    enabled: true\n');
    const off = site({ 'pom.xml': pom, 'src/main/resources/application.properties': 'clikgate.keep-route.enabled=false\n' });
    const { ui } = await run(off, ['--yes']);
    expect(read(off, 'src/main/resources/application.properties')).toBe('clikgate.keep-route.enabled=false\n');
    expect(ui.text).toContain('it was left as it is');
  });
  it('ASP.NET Core: MapClikgateKeep before app.Run(); idempotent', async () => {
    const program = 'var builder = WebApplication.CreateBuilder(args);\nvar app = builder.Build();\n\napp.MapGet("/", () => "Hello");\n\napp.Run();\n';
    const dir = site({ 'AcmeWeb.csproj': '<Project Sdk="Microsoft.NET.Sdk.Web"></Project>', 'Program.cs': program, 'Pages/Shared/_Layout.cshtml': HTML });
    const ui = await applyTwice(dir);
    expect(read(dir, 'Program.cs')).toBe('var builder = WebApplication.CreateBuilder(args);\nvar app = builder.Build();\n\napp.MapGet("/", () => "Hello");\n\napp.MapClikgateKeep("/cg/keep");\n\napp.Run();\n');
    expect(ui.text).toContain('dotnet add package Clikgate.AspNetCore');
  });
});

describe('script tag', () => {
  it('adds data-server-endpoint to an existing tag (after data-web-key); JSX too', () => {
    expect(addEndpointAttribute(`<head>${TAG}</head>`)).toBe(`<head>${TAG_WITH_ENDPOINT}</head>`);
    expect(addEndpointAttribute(TAG_WITH_ENDPOINT)).toBe(TAG_WITH_ENDPOINT);
    expect(addEndpointAttribute('<Script src="https://sdk.clikgate.com/v1/static/clikgate.js" strategy="afterInteractive" />')).toBe(
      '<Script src="https://sdk.clikgate.com/v1/static/clikgate.js" data-server-endpoint="/cg/keep" strategy="afterInteractive" />'
    );
  });
  it('finds the tag in the project and edits it only (no new tag); idempotent', async () => {
    const page = HTML.replace('  </head>', `    ${TAG}\n  </head>`);
    const dir = site({ artisan: '', 'routes/web.php': '<?php\n', 'resources/views/welcome.blade.php': page });
    await applyTwice(dir);
    const out = read(dir, 'resources/views/welcome.blade.php');
    expect(out).toContain(TAG_WITH_ENDPOINT);
    expect(out.match(/clikgate\.js/g)).toHaveLength(1);
  });
  it('an existing tag without a keep route is left alone; data-days="7" gets a reminder', async () => {
    const page = HTML.replace('  </head>', `    ${TAG.replace(' async', ' data-days="7" async')}\n  </head>`);
    const dir = site({ 'index.html': page });
    const { ui } = await run(dir, ['--yes', '--website-server', 'none']);
    expect(read(dir, 'index.html')).toBe(page);
    expect(ui.text).toContain('The web script now keeps the click ID for 30 days by default');
  });
  it('no layout found: the tag is a manual step', async () => {
    const { ui } = await run(site({ 'README.md': '# Acme\n' }), ['--yes']);
    expect(ui.text).toContain(`Web script: No page layout the setup command can edit was found.`);
    expect(ui.text).toContain(TAG);
  });
  it('refuses an API key or SDK key as the web key, and writes a placeholder without one', async () => {
    const dir = site({ 'index.html': HTML });
    const ui = new ScriptedUI([], false);
    expect(await main(['website', '--cwd', dir, '--yes', '--web-key', 'cg_live_abc'], { ui })).toBe(1);
    expect(ui.text).toContain("That's not a web key");
    expect(await main(['website', '--cwd', dir, '--yes'], { ui })).toBe(0);
    expect(read(dir, 'index.html')).toContain('data-web-key="cgw_test_REPLACE_ME"');
  });
});

describe('WordPress and Shopify keep the click ID themselves', () => {
  it.each([
    ['WordPress', { 'wp-config.php': '<?php\n', 'index.php': '<?php\n' }, 'The Clikgate WordPress plugin keeps the click ID from your server itself'],
    ['Shopify', { 'config/settings_schema.json': '[]', 'layout/theme.liquid': HTML }, 'The Clikgate Shopify app keeps the click ID in cart attributes'],
  ])('%s: says so and changes nothing', async (_name, files, message) => {
    const dir = site(files);
    const before = snapshotTree(dir);
    const { code, ui } = await run(dir, ['--yes']);
    expect(code).toBe(0);
    expect(ui.text).toContain(message);
    expect(ui.text).toContain('no route is added');
    expect(snapshotTree(dir)).toEqual(before);
  });
});

describe('wording', () => {
  it('is honest about Safari and never promises forever', async () => {
    const dir = site({ 'package.json': EXPRESS_PKG, 'server.js': "const express = require('express');\nconst app = express();\n", 'public/index.html': HTML });
    const { ui } = await run(dir, ['--yes']);
    expect(ui.text).toContain("Safari, and every browser on iPhone, keeps a click ID saved by a script for up to 7 days (sometimes less). When your server saves it, it lasts as long as you choose, up to the browser's limit.");
    expect(ui.text).not.toMatch(/never lost|forever|guaranteed/i);
    expect(fs.readFileSync(path.join(__dirname, '../src/website.ts'), 'utf8')).not.toMatch(/never lost|forever|guaranteed/i);
  });
});
