import { isMap, isScalar, parseDocument, type Pair, type YAMLMap } from 'yaml';

/**
 * pubspec.yaml: parsed with `yaml` (eemeli/yaml, keeps comments and source ranges). The new
 * dependency line is inserted after the last entry of `dependencies:` so comments, blank lines
 * and quoting stay exactly as they were; the result is parsed again to check it.
 */

export function readPubspec(text: string): Record<string, unknown> {
  const doc = parseDocument(text);
  if (doc.errors.length) throw new Error(doc.errors[0].message);
  return (doc.toJS() ?? {}) as Record<string, unknown>;
}

export function isFlutterApp(text: string): boolean {
  try {
    const p = readPubspec(text);
    const deps = p.dependencies as Record<string, unknown> | undefined;
    return Boolean(p.flutter !== undefined || (deps && 'flutter' in deps));
  } catch {
    return false;
  }
}

export function dependencyConstraint(text: string, name: string): string | undefined {
  const p = readPubspec(text);
  const v = (p.dependencies as Record<string, unknown> | undefined)?.[name];
  if (v === undefined) return undefined;
  if (typeof v === 'string') return v;
  if (v === null) return 'any';
  return JSON.stringify(v);
}

export function addDependency(text: string, name: string, constraint: string): string {
  const doc = parseDocument(text, { keepSourceTokens: true });
  if (doc.errors.length) throw new Error(doc.errors[0].message);
  if (!isMap(doc.contents)) throw new Error('pubspec.yaml is not a map');
  const root = doc.contents as YAMLMap;
  const depsPair = root.items.find((p) => isScalar(p.key) && p.key.value === 'dependencies') as Pair | undefined;
  let out: string;
  if (!depsPair || !isMap(depsPair.value) || (depsPair.value as YAMLMap).items.length === 0) {
    if (depsPair) throw new Error('dependencies: is not a block map');
    const sep = text.endsWith('\n') ? '' : '\n';
    out = `${text}${sep}\ndependencies:\n  ${name}: ${constraint}\n`;
  } else {
    const deps = depsPair.value as YAMLMap;
    const first = deps.items[0];
    const last = deps.items[deps.items.length - 1];
    const firstKey = first.key as { range?: [number, number, number] };
    if (!firstKey.range) throw new Error('No source range');
    const col = firstKey.range[0] - (text.lastIndexOf('\n', firstKey.range[0] - 1) + 1);
    const lastNode = (last.value ?? last.key) as { range?: [number, number, number] };
    if (!lastNode.range) throw new Error('No source range');
    // End of the line holding the end of the last value.
    let at = text.indexOf('\n', Math.max(lastNode.range[1] - 1, 0));
    if (at < 0) at = text.length;
    out = text.slice(0, at) + `\n${' '.repeat(col)}${name}: ${constraint}` + text.slice(at);
  }
  if (dependencyConstraint(out, name) !== constraint) throw new Error('Could not add the dependency to pubspec.yaml');
  return out;
}
