import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { createTwoFilesPatch } from 'diff';
import type { UI } from '../src/ui';

export const FIXTURES = path.join(__dirname, 'fixtures');
export const FIXTURE_NAMES = ['flutter', 'react-native', 'expo-blank', 'expo-router', 'expo-native', 'android-compose', 'android-views', 'ios-swiftui', 'ios-uikit', 'monorepo'] as const;

export function copyFixture(name: string): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `clikgate-${name}-`));
  fs.cpSync(path.join(FIXTURES, name), dir, { recursive: true });
  return dir;
}

export function listFiles(root: string, dir = root, out: string[] = []): string[] {
  for (const n of fs.readdirSync(dir).sort()) {
    const p = path.join(dir, n);
    if (fs.statSync(p).isDirectory()) {
      if (n === '.clikgate-setup-backup' || n === '.git') continue;
      listFiles(root, p, out);
    } else out.push(path.relative(root, p).split(path.sep).join('/'));
  }
  return out;
}

export function snapshotTree(root: string): Map<string, string> {
  return new Map(listFiles(root).map((f) => [f, fs.readFileSync(path.join(root, f), 'utf8')]));
}

/** Unified diff of every changed or new file between the fixture and `dir`. */
export function treeDiff(fixture: string, dir: string): string {
  const before = snapshotTree(path.join(FIXTURES, fixture));
  const after = snapshotTree(dir);
  const files = Array.from(new Set([...before.keys(), ...after.keys()])).sort();
  const parts: string[] = [];
  for (const f of files) {
    const a = before.get(f);
    const b = after.get(f);
    if (a === b) continue;
    parts.push(
      createTwoFilesPatch(a === undefined ? '/dev/null' : `a/${f}`, b === undefined ? '/dev/null' : `b/${f}`, a ?? '', b ?? '', '', '', { context: 2 })
        .split('\n')
        .filter((l) => !/^={10,}$/.test(l))
        .map((l) => l.replace(/\t$/, ''))
        .join('\n')
    );
  }
  return parts.join('\n');
}

type Answer = boolean | string | number[];

/** A UI driven by a list of [question pattern, answer] rules; records everything printed. */
export class ScriptedUI implements UI {
  readonly lines: string[] = [];
  readonly asked: string[] = [];
  readonly color = false;
  readonly verbose = false;
  constructor(
    private readonly rules: [RegExp, Answer][] = [],
    readonly interactive = true
  ) {}
  get text(): string {
    return this.lines.join('\n');
  }
  out(line = ''): void {
    this.lines.push(line);
  }
  err(line: string): void {
    this.lines.push(line);
  }
  debug(): void {}
  private answer(q: string): Answer | undefined {
    this.asked.push(q);
    return this.rules.find(([re]) => re.test(q))?.[1];
  }
  async confirm(q: string, def: boolean): Promise<boolean> {
    if (!this.interactive) return false;
    const a = this.answer(q);
    return typeof a === 'boolean' ? a : def;
  }
  async ask(q: string): Promise<string> {
    if (!this.interactive) return '';
    const a = this.answer(q);
    return typeof a === 'string' ? a : '';
  }
  async choose(q: string, options: string[], opts: { multi?: boolean; defaults?: number[] } = {}): Promise<number[]> {
    const def = opts.defaults ?? (opts.multi ? options.map((_, i) => i) : [0]);
    if (!this.interactive) return def;
    const a = this.answer(q);
    return Array.isArray(a) ? a : def;
  }
  waitForEnter(signal: AbortSignal): Promise<boolean> {
    return new Promise((resolve) => {
      const t = setTimeout(() => resolve(true), 0);
      signal.addEventListener('abort', () => {
        clearTimeout(t);
        resolve(false);
      });
    });
  }
}

export const OFFLINE = ['--sdk-key', 'cg_sdk_test_abc123', '--domain', 'acme.ciz.to,go.acme.com', '--yes', '--no-install'];
