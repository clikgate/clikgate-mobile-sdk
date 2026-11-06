import { parse } from '@bacons/xcode/json';

/**
 * Xcode project files: parsed with @bacons/xcode's pbxproj parser (read-only use), edited by
 * inserting one build-setting line into the right XCBuildConfiguration so the rest of the file
 * stays exactly as Xcode wrote it. The result is parsed again to check it.
 */

type Obj = Record<string, unknown> & { isa?: string };

export interface BuildConfig {
  id: string;
  name: string;
  settings: Record<string, unknown>;
}

export interface AppTarget {
  id: string;
  name: string;
  configs: BuildConfig[];
}

export interface XcodeProjectInfo {
  targets: AppTarget[];
}

export function parsePbxproj(text: string): { objects: Record<string, Obj>; rootObject: string } {
  const json = parse(text) as unknown as { objects: Record<string, Obj>; rootObject: string };
  if (!json || typeof json !== 'object' || !json.objects) throw new Error('Not an Xcode project file');
  return json;
}

/** Application targets (product type application) with their build configurations. */
export function appTargets(text: string): AppTarget[] {
  const { objects } = parsePbxproj(text);
  const out: AppTarget[] = [];
  for (const [id, o] of Object.entries(objects)) {
    if (o.isa !== 'PBXNativeTarget') continue;
    const type = String(o.productType ?? '').replace(/"/g, '');
    if (type !== 'com.apple.product-type.application') continue;
    const list = objects[String(o.buildConfigurationList)] as Obj | undefined;
    const ids = (list?.buildConfigurations as string[] | undefined) ?? [];
    const configs = ids.map((cid) => {
      const c = objects[cid] as Obj;
      return { id: cid, name: String(c.name), settings: (c.buildSettings as Record<string, unknown>) ?? {} };
    });
    out.push({ id, name: String(o.name), configs });
  }
  return out;
}

export function setting(config: BuildConfig, key: string): string | undefined {
  const v = config.settings[key];
  return typeof v === 'string' || typeof v === 'number' ? String(v) : undefined;
}

/** Debug-like configurations: the name contains "Debug" (Flutter, RN and Xcode use Debug). */
export function isDebugConfig(name: string): boolean {
  return /debug/i.test(name);
}

function quote(value: string): string {
  return /^[A-Za-z0-9_./$()-]+$/.test(value) && !value.includes('//') ? value : `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

function unquote(k: string): string {
  return k.startsWith('"') && k.endsWith('"') ? k.slice(1, -1) : k;
}

/**
 * Inserts `KEY = value;` into a configuration's buildSettings (alphabetical position, Xcode's
 * own order). Refuses to change a key that already has a value.
 */
export function addBuildSetting(text: string, configId: string, key: string, value: string): string {
  const header = new RegExp(`\\n(\\t*)${configId}(?: /\\*[^*]*\\*/)? = \\{`);
  const m = header.exec(text);
  if (!m) throw new Error(`Build configuration ${configId} not found`);
  const bsIdx = text.indexOf('buildSettings = {', m.index);
  if (bsIdx < 0) throw new Error(`buildSettings not found for ${configId}`);
  const bodyStart = text.indexOf('\n', bsIdx) + 1;
  const lines: { start: number; indent: string; key: string }[] = [];
  let pos = bodyStart;
  let keyIndent: string | undefined;
  let closeAt = -1;
  for (;;) {
    const nl = text.indexOf('\n', pos);
    if (nl < 0) throw new Error('Unterminated buildSettings');
    const line = text.slice(pos, nl);
    const indent = /^\t*/.exec(line)![0];
    if (keyIndent === undefined) keyIndent = indent;
    if (indent.length < keyIndent.length && line.trim() === '};') {
      closeAt = pos;
      break;
    }
    if (indent === keyIndent) {
      const km = /^\t*("(?:[^"\\]|\\.)*"|[A-Za-z0-9_[\]=*.,$-]+)\s*=/.exec(line);
      if (km) lines.push({ start: pos, indent, key: unquote(km[1]) });
    }
    pos = nl + 1;
  }
  if (lines.some((l) => l.key === key)) throw new Error(`${key} is already set`);
  const indent = keyIndent ?? '\t\t\t\t';
  const next = lines.find((l) => l.key > key);
  const at = next ? next.start : closeAt;
  const out = text.slice(0, at) + `${indent}${key} = ${quote(value)};\n` + text.slice(at);
  const check = appTargets(out)
    .flatMap((t) => t.configs)
    .find((c) => c.id === configId);
  if (!check || setting(check, key) !== value) throw new Error(`Could not set ${key} in ${configId}`);
  return out;
}

/** Replaces the value of an existing build setting line in one configuration. */
export function replaceBuildSetting(text: string, configId: string, key: string, value: string): string {
  const header = new RegExp(`\\n(\\t*)${configId}(?: /\\*[^*]*\\*/)? = \\{`);
  const m = header.exec(text);
  if (!m) throw new Error(`Build configuration ${configId} not found`);
  const bsIdx = text.indexOf('buildSettings = {', m.index);
  const end = text.indexOf('name = ', bsIdx);
  const region = text.slice(bsIdx, end < 0 ? undefined : end);
  const lineRe = new RegExp(`\\n(\\t*)("?)${key.replace(/[[\]*]/g, '\\$&')}\\2 = [^\\n]*;`);
  const lm = lineRe.exec(region);
  if (!lm) throw new Error(`${key} isn't set in ${configId}`);
  const at = bsIdx + lm.index;
  const out = text.slice(0, at) + `\n${lm[1]}${key} = ${quote(value)};` + text.slice(at + lm[0].length);
  const check = appTargets(out).flatMap((t) => t.configs).find((c) => c.id === configId);
  if (!check || setting(check, key) !== value) throw new Error(`Could not set ${key} in ${configId}`);
  return out;
}

/** Sets a build setting: inserts it, or replaces it when `replace` is true. */
export function setBuildSetting(text: string, configId: string, key: string, value: string, replace = false): string {
  const c = appTargets(text).flatMap((t) => t.configs).find((x) => x.id === configId);
  if (c && setting(c, key) !== undefined) {
    if (setting(c, key)?.replace(/^"|"$/g, '') === value) return text;
    if (!replace) throw new Error(`${key} is already set`);
    return replaceBuildSetting(text, configId, key, value);
  }
  return addBuildSetting(text, configId, key, value);
}
