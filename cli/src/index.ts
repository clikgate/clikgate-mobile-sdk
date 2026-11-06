import { HELP, parseArgs, UsageError } from './args';
import { CLI_VERSION, EXIT } from './constants';
import { runDoctor } from './doctorCommand';
import { describeError, runSetup, type Deps } from './setup';
import { colorEnabled, TerminalUI, type UI } from './ui';
import { runWebsite } from './website';

/** Entry point. No telemetry: the only network calls are to the Clikgate API, after sign-in. */
export async function main(argv: string[], deps: Partial<Deps> = {}): Promise<number> {
  let opts;
  try {
    opts = parseArgs(argv);
  } catch (e) {
    if (e instanceof UsageError) {
      process.stderr.write(`${e.message}\nRun with --help for usage.\n`);
      return EXIT.PROBLEMS;
    }
    throw e;
  }
  if (opts.version) {
    process.stdout.write(`${CLI_VERSION}\n`);
    return EXIT.OK;
  }
  if (opts.help) {
    process.stdout.write(`${HELP}\n`);
    return EXIT.OK;
  }
  if (Number(process.versions.node.split('.')[0]) < 18) {
    process.stderr.write('The Clikgate setup command needs Node.js 18 or newer.\n');
    return EXIT.PROBLEMS;
  }
  const ui: UI = deps.ui ?? new TerminalUI(colorEnabled(opts.color, opts.json ? process.stderr : process.stdout), opts.verbose, opts.json);
  const full: Deps = { ...deps, ui };
  try {
    if (opts.command === 'doctor') return (await runDoctor(opts, full)).code;
    if (opts.command === 'website') return await runWebsite(opts, full);
    return await runSetup(opts, full);
  } catch (e) {
    const { code, message } = describeError(e);
    if (message) ui.err(message);
    if (opts.verbose && e instanceof Error && e.stack) ui.err(e.stack);
    return code;
  }
}

// Run when executed as the CLI (not when imported by tests).
if (typeof require !== "undefined" && typeof module !== "undefined" && require.main === module) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (e) => {
      process.stderr.write(`${(e as Error)?.stack ?? e}\n`);
      process.exitCode = EXIT.PROBLEMS;
    }
  );
}
