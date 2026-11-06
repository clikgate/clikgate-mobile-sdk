import { MARKER_END, MARKER_START, SDK } from '../constants';

/**
 * Gradle build files (Groovy and Kotlin DSL). No Gradle parser exists for Node, so this reads
 * only well-known statements and finds blocks with a brace scanner that skips strings and
 * comments. Anything it can't place becomes a manual step.
 */

export interface Block {
  name: string;
  /** Offset of the `{`. */
  open: number;
  /** Offset of the matching `}`. */
  close: number;
  depth: number;
}

/** Top-level and nested `name {` blocks with their brace offsets. */
export function blocks(text: string): Block[] {
  const out: Block[] = [];
  const stack: Block[] = [];
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    const n = text[i + 1];
    if (c === '/' && n === '/') { i = text.indexOf('\n', i); if (i < 0) break; continue; }
    if (c === '/' && n === '*') { const e = text.indexOf('*/', i + 2); i = e < 0 ? text.length : e + 2; continue; }
    if (c === '"' && text.startsWith('"""', i)) { const e = text.indexOf('"""', i + 3); i = e < 0 ? text.length : e + 3; continue; }
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < text.length && text[j] !== c && text[j] !== '\n') j += text[j] === '\\' ? 2 : 1;
      i = j + 1;
      continue;
    }
    if (c === '{') {
      const before = text.slice(Math.max(0, i - 120), i);
      const m = /([A-Za-z_][A-Za-z0-9_.]*)\s*(\([^()]*\))?\s*$/.exec(before);
      const b: Block = { name: m ? m[1] : '', open: i, close: -1, depth: stack.length };
      stack.push(b);
      out.push(b);
    } else if (c === '}') {
      const b = stack.pop();
      if (b) b.close = i;
    }
    i++;
  }
  return out;
}

export function isKotlinDsl(path: string): boolean {
  return path.endsWith('.kts');
}

/** `applicationId` values (defaultConfig and flavours) in an app module build file. */
export function applicationIds(text: string): string[] {
  const ids = new Set<string>();
  for (const m of text.matchAll(/\bapplicationId\s*(?:=\s*)?["']([A-Za-z0-9_.]+)["']/g)) ids.add(m[1]);
  return [...ids];
}

export function namespace(text: string): string | undefined {
  return /\bnamespace\s*(?:=\s*)?["']([A-Za-z0-9_.]+)["']/.exec(text)?.[1];
}

export function hasProductFlavors(text: string): boolean {
  return blocks(text).some((b) => b.name === 'productFlavors');
}

export function isAppModule(text: string): boolean {
  return /com\.android\.application|android\.application|id\s*\(?\s*["']com\.android\.application["']/.test(text) || /alias\(libs\.plugins\.android\.application\)/.test(text);
}

export function hasClikgateDependency(text: string, catalog?: string): boolean {
  if (text.includes(`${SDK.android.group}:${SDK.android.artifact}`)) return true;
  if (/libs\.clikgate\.android\b/.test(text)) return true;
  if (catalog && /libs\.[A-Za-z0-9_.]+/.test(text)) {
    const alias = catalogAliasFor(catalog);
    if (alias && text.includes(`libs.${alias.replace(/[-_]/g, '.')}`)) return true;
  }
  return false;
}

/** The catalog alias that points at com.clikgate:clikgate-android, if any. */
export function catalogAliasFor(catalog: string): string | undefined {
  for (const line of catalog.split('\n')) {
    const m = /^\s*([A-Za-z0-9_-]+)\s*=\s*(.*)$/.exec(line);
    if (!m) continue;
    if (
      m[2].includes(`"${SDK.android.group}:${SDK.android.artifact}`) ||
      (m[2].includes(`"${SDK.android.group}"`) && m[2].includes(`"${SDK.android.artifact}"`))
    ) {
      return m[1];
    }
  }
  return undefined;
}

function topLevelDependencies(text: string): Block | undefined {
  return blocks(text).find((b) => b.depth === 0 && b.name === 'dependencies');
}

function indentOfBlockBody(text: string, b: Block): string {
  const body = text.slice(b.open + 1, b.close);
  const m = /\n([ \t]+)\S/.exec(body);
  return m ? m[1] : '    ';
}

/** Adds the dependency line (between markers) as the last entry of the top-level dependencies block. */
export function addDependency(text: string, line: string): string {
  const deps = topLevelDependencies(text);
  const block = (indent: string) => [`${indent}// ${MARKER_START}`, `${indent}${line}`, `${indent}// ${MARKER_END}`].join('\n');
  if (!deps) {
    const sep = text.endsWith('\n') ? '' : '\n';
    return `${text}${sep}\ndependencies {\n${block('    ')}\n}\n`;
  }
  const indent = indentOfBlockBody(text, deps);
  const lineStart = text.lastIndexOf('\n', deps.close - 1) + 1;
  const ownLine = /^[ \t]*$/.test(text.slice(lineStart, deps.close));
  if (ownLine) return text.slice(0, lineStart) + block(indent) + '\n' + text.slice(lineStart);
  return text.slice(0, deps.close) + '\n' + block(indent) + '\n' + text.slice(deps.close);
}

export function dependencyLine(kotlinDsl: boolean, useCatalog: boolean): string {
  if (useCatalog) return kotlinDsl ? 'implementation(libs.clikgate.android)' : 'implementation libs.clikgate.android';
  const coord = `${SDK.android.group}:${SDK.android.artifact}:${SDK.android.version}`;
  return kotlinDsl ? `implementation("${coord}")` : `implementation '${coord}'`;
}

/** Adds `clikgate = "x"` under [versions] and the library under [libraries] in libs.versions.toml. */
export function addCatalogEntries(toml: string): string {
  if (catalogAliasFor(toml)) return toml;
  let out = toml;
  out = appendToTomlSection(out, 'versions', `clikgate = "${SDK.android.version}"`, /^\s*clikgate\s*=/m);
  out = appendToTomlSection(
    out,
    'libraries',
    `clikgate-android = { group = "${SDK.android.group}", name = "${SDK.android.artifact}", version.ref = "clikgate" }`,
    /^\s*clikgate-android\s*=/m
  );
  return out;
}

function appendToTomlSection(toml: string, section: string, line: string, exists: RegExp): string {
  const header = new RegExp(`^\\[${section}\\][ \\t]*$`, 'm');
  const h = header.exec(toml);
  if (!h) {
    const sep = toml.endsWith('\n') ? '' : '\n';
    return `${toml}${sep}\n[${section}]\n${line}\n`;
  }
  const after = h.index + h[0].length;
  const nextHeader = /^\[[^\]]+\][ \t]*$/m.exec(toml.slice(after));
  const sectionEnd = nextHeader ? after + nextHeader.index : toml.length;
  const body = toml.slice(after, sectionEnd);
  if (exists.test(body)) return toml;
  // Insert after the last non-empty line of the section.
  const trimmed = body.replace(/\s+$/, '');
  const insertAt = after + trimmed.length;
  return toml.slice(0, insertAt) + `\n${line}` + toml.slice(insertAt);
}
