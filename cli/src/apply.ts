import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { changes, type Plan } from './plan';
import { paint, type UI } from './ui';

export interface ApplyDeps {
  writeFile?: (file: string, text: string) => void;
  run?: (command: string[], cwd: string) => { ok: boolean; output: string };
}

export interface ApplyResult {
  ok: boolean;
  written: string[];
  created: string[];
  commandsRun: string[];
  commandsSkipped: string[];
  failure?: string;
}

function defaultWrite(file: string, text: string): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}

function defaultRun(command: string[], cwd: string): { ok: boolean; output: string } {
  const r = spawnSync(command[0], command.slice(1), { cwd, stdio: 'inherit', shell: process.platform === 'win32' });
  if (r.error) return { ok: false, output: r.error.message };
  return { ok: r.status === 0, output: r.status === 0 ? '' : `exit code ${r.status}` };
}

export async function applyPlan(ui: UI, plan: Plan, opts: { yes: boolean }, deps: ApplyDeps = {}): Promise<ApplyResult> {
  const write = deps.writeFile ?? defaultWrite;
  const run = deps.run ?? defaultRun;
  const res: ApplyResult = { ok: true, written: [], created: [], commandsRun: [], commandsSkipped: [] };
  for (const c of changes(plan)) {
    try {
      write(path.join(plan.root, c.file), c.after);
      (c.before === null ? res.created : res.written).push(c.file);
    } catch (e) {
      res.ok = false;
      res.failure = `Couldn't write ${c.file}: ${(e as Error).message}`;
      return res;
    }
  }
  for (const s of plan.steps) {
    if (s.kind !== 'command') continue;
    const cmd = s.command.join(' ');
    if (s.ask && !opts.yes) {
      if (!(await ui.confirm(s.ask, true))) {
        res.commandsSkipped.push(cmd);
        continue;
      }
    }
    ui.out(paint(ui, 'dim', `$ ${cmd}`));
    const r = run(s.command, s.cwd);
    if (!r.ok) {
      res.ok = false;
      res.failure = `\`${cmd}\` failed (${r.output || 'see the output above'})`;
      return res;
    }
    res.commandsRun.push(cmd);
  }
  return res;
}

/** What changed and how to undo it, after a failed apply. */
export function undoInstructions(res: ApplyResult, git: { isRepo: boolean }, backupDir?: string, root = '.'): string[] {
  const lines: string[] = [];
  if (res.written.length === 0 && res.created.length === 0) {
    lines.push('No files were changed.');
    return lines;
  }
  lines.push('These files were changed:');
  for (const f of res.written) lines.push(`  ~ ${f}`);
  for (const f of res.created) lines.push(`  + ${f} (new)`);
  lines.push('To undo:');
  if (git.isRepo) {
    if (res.written.length) lines.push(`  git checkout -- ${res.written.map(q).join(' ')}`);
  } else if (backupDir) {
    lines.push(`  copy the files in ${path.relative(root, backupDir) || backupDir} back over the project`);
  }
  if (res.created.length) lines.push(`  delete ${res.created.map(q).join(' ')}`);
  return lines;
}

function q(f: string): string {
  return /[\s'"$]/.test(f) ? `'${f.replace(/'/g, "'\\''")}'` : f;
}
