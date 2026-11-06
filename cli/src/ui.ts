import * as readline from 'node:readline';

/** Everything the command prints or asks goes through this interface (tests script it). */
export interface UI {
  readonly interactive: boolean;
  readonly color: boolean;
  readonly verbose: boolean;
  out(line?: string): void;
  err(line: string): void;
  debug(line: string): void;
  /** Yes/no question. `def` is the answer for Enter. */
  confirm(question: string, def: boolean): Promise<boolean>;
  /** Free text. Returns '' on Enter. */
  ask(question: string): Promise<string>;
  /** Pick one or more options (indexes). */
  choose(question: string, options: string[], opts?: { multi?: boolean; defaults?: number[] }): Promise<number[]>;
  /** Wait for Enter or until the signal aborts; resolves true when Enter was pressed. */
  waitForEnter(signal: AbortSignal): Promise<boolean>;
}

const codes = { reset: 0, bold: 1, dim: 2, red: 31, green: 32, yellow: 33, blue: 34, cyan: 36 } as const;
export type Style = keyof typeof codes;

export function paint(ui: Pick<UI, 'color'>, style: Style, text: string): string {
  if (!ui.color) return text;
  return `\u001b[${codes[style]}m${text}\u001b[0m`;
}

export function colorEnabled(flag: boolean | undefined, stream: NodeJS.WriteStream = process.stdout): boolean {
  if (flag === false) return false;
  if (process.env.NO_COLOR !== undefined && process.env.NO_COLOR !== '') return false;
  if (process.env.FORCE_COLOR && process.env.FORCE_COLOR !== '0') return true;
  return Boolean(stream.isTTY);
}

export class TerminalUI implements UI {
  readonly interactive: boolean;
  constructor(
    readonly color: boolean,
    readonly verbose: boolean,
    private readonly jsonMode = false
  ) {
    this.interactive = Boolean(process.stdin.isTTY && process.stdout.isTTY);
  }

  out(line = ''): void {
    // In --json mode stdout carries only the JSON document; human text goes to stderr.
    (this.jsonMode ? process.stderr : process.stdout).write(line + '\n');
  }
  err(line: string): void {
    process.stderr.write(line + '\n');
  }
  debug(line: string): void {
    if (this.verbose) process.stderr.write(paint(this, 'dim', `· ${line}`) + '\n');
  }

  private question(q: string): Promise<string> {
    const rl = readline.createInterface({ input: process.stdin, output: this.jsonMode ? process.stderr : process.stdout });
    return new Promise((resolve) => {
      rl.question(q, (answer) => {
        rl.close();
        resolve(answer.trim());
      });
      rl.on('SIGINT', () => {
        rl.close();
        process.stdout.write('\n');
        process.exit(2);
      });
    });
  }

  async confirm(question: string, def: boolean): Promise<boolean> {
    if (!this.interactive) return false;
    const hint = def ? '(Y/n)' : '(y/N)';
    for (;;) {
      const a = (await this.question(`${question} ${hint} `)).toLowerCase();
      if (a === '') return def;
      if (a === 'y' || a === 'yes') return true;
      if (a === 'n' || a === 'no') return false;
    }
  }

  async ask(question: string): Promise<string> {
    if (!this.interactive) return '';
    return this.question(`${question} `);
  }

  async choose(question: string, options: string[], opts: { multi?: boolean; defaults?: number[] } = {}): Promise<number[]> {
    const defaults = opts.defaults ?? (opts.multi ? options.map((_, i) => i) : [0]);
    if (!this.interactive) return defaults;
    this.out(question);
    options.forEach((o, i) => this.out(`  ${i + 1}) ${o}${defaults.includes(i) ? paint(this, 'dim', '  (default)') : ''}`));
    for (;;) {
      const a = await this.question(opts.multi ? 'Numbers separated by commas, Enter for the defaults: ' : 'Number, Enter for the default: ');
      if (a === '') return defaults;
      const picks = a.split(/[\s,]+/).filter(Boolean).map((s) => Number.parseInt(s, 10) - 1);
      if (picks.every((p) => Number.isInteger(p) && p >= 0 && p < options.length) && (opts.multi || picks.length === 1)) {
        return Array.from(new Set(picks));
      }
    }
  }

  waitForEnter(signal: AbortSignal): Promise<boolean> {
    if (!this.interactive) {
      return new Promise((resolve) => signal.addEventListener('abort', () => resolve(false), { once: true }));
    }
    return new Promise((resolve) => {
      const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
      const done = (v: boolean) => {
        rl.close();
        resolve(v);
      };
      rl.once('line', () => done(true));
      signal.addEventListener('abort', () => done(false), { once: true });
    });
  }
}
