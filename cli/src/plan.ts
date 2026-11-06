import * as fs from 'node:fs';
import * as path from 'node:path';
import { createTwoFilesPatch } from 'diff';
import { paint, type UI } from './ui';

export type Step =
  | { kind: 'done'; label: string }
  | { kind: 'change'; file: string; before: string | null; after: string; summary: string }
  | { kind: 'manual'; label: string; detail: string; snippet?: string }
  | { kind: 'command'; label: string; command: string[]; cwd: string; ask?: string };

export interface Plan {
  root: string;
  steps: Step[];
  /** Printed in the summary (go-live, new development build…). */
  reminders: string[];
}

export class PlanBuilder {
  readonly steps: Step[] = [];
  readonly reminders: string[] = [];
  /** Pending file contents, so several edits to one file stack up. */
  private readonly pending = new Map<string, { before: string | null; after: string; summaries: string[] }>();

  constructor(readonly root: string) {}

  /** Current content of a file, including planned edits. */
  current(file: string): string | null {
    const p = this.pending.get(file);
    if (p) return p.after;
    try {
      return fs.readFileSync(path.join(this.root, file), 'utf8');
    } catch {
      return null;
    }
  }

  done(label: string): void {
    this.steps.push({ kind: 'done', label });
  }

  manual(label: string, detail: string, snippet?: string): void {
    this.steps.push({ kind: 'manual', label, detail, snippet });
  }

  command(label: string, command: string[], cwd: string, ask?: string): void {
    this.steps.push({ kind: 'command', label, command, cwd, ask });
  }

  reminder(text: string): void {
    if (!this.reminders.includes(text)) this.reminders.push(text);
  }

  /** Records a new file content. A no-op change becomes "already set up". */
  change(file: string, after: string, summary: string, doneLabel?: string): void {
    const before = this.current(file);
    if (before === after) {
      if (doneLabel) this.done(doneLabel);
      return;
    }
    const existing = this.pending.get(file);
    if (existing) {
      existing.after = after;
      existing.summaries.push(summary);
      return;
    }
    this.pending.set(file, { before, after, summaries: [summary] });
    this.steps.push({ kind: 'change', file, before, after, summary });
  }

  build(): Plan {
    // Fold stacked edits into their step.
    const steps = this.steps.map((s) => {
      if (s.kind !== 'change') return s;
      const p = this.pending.get(s.file)!;
      return { ...s, after: p.after, summary: p.summaries.join('; ') };
    });
    return { root: this.root, steps, reminders: this.reminders };
  }
}

export function changes(plan: Plan): Extract<Step, { kind: 'change' }>[] {
  return plan.steps.filter((s): s is Extract<Step, { kind: 'change' }> => s.kind === 'change');
}

export function renderPlan(ui: UI, plan: Plan): void {
  ui.out('Clikgate will make these changes:');
  for (const s of plan.steps) {
    switch (s.kind) {
      case 'done':
        ui.out(`  ${paint(ui, 'green', '✓ already set up')}   ${s.label}`);
        break;
      case 'change':
        ui.out(`  ${paint(ui, 'cyan', s.before === null ? '+ new file  ' : '+ change    ')}   ${s.file}  (${s.summary})`);
        break;
      case 'command':
        ui.out(`  ${paint(ui, 'cyan', '+ run       ')}   ${s.command.join(' ')}  (${s.label})`);
        break;
      case 'manual':
        ui.out(`  ${paint(ui, 'yellow', '! manual    ')}   ${s.label} (see summary)`);
        break;
    }
  }
}

export function unifiedDiff(file: string, before: string | null, after: string): string {
  return createTwoFilesPatch(before === null ? '/dev/null' : `a/${file}`, `b/${file}`, before ?? '', after, '', '', { context: 3 });
}

export function renderDiffs(ui: UI, plan: Plan): void {
  for (const s of changes(plan)) {
    const d = unifiedDiff(s.file, s.before, s.after);
    for (const line of d.split('\n').filter((l) => !/^={10,}$/.test(l))) {
      if (line.startsWith('+++') || line.startsWith('---')) ui.out(paint(ui, 'bold', line));
      else if (line.startsWith('+')) ui.out(paint(ui, 'green', line));
      else if (line.startsWith('-')) ui.out(paint(ui, 'red', line));
      else if (line.startsWith('@@')) ui.out(paint(ui, 'cyan', line));
      else ui.out(line);
    }
  }
}
