/**
 * The command the person typed to start setup, for every command this tool prints ("Run `…`", usage lines,
 * doctor fixes). Default `npx @clikgate/setup`. `dart run clikgate_flutter` (the Flutter runner, which runs
 * this same program as a compiled binary) sets CLIKGATE_SETUP_COMMAND so the messages name the command the
 * person can actually run; doctor is then its own executable, `dart run clikgate_flutter:doctor`.
 */
export const DEFAULT_SETUP_COMMAND = 'npx @clikgate/setup';

// Printed only; still kept to a short, plain command line.
const SAFE = /^[A-Za-z0-9@_./:+ -]{1,80}$/;

export function setupCommand(env: NodeJS.ProcessEnv = process.env): string {
  const v = env.CLIKGATE_SETUP_COMMAND?.trim();
  return v && SAFE.test(v) ? v : DEFAULT_SETUP_COMMAND;
}

/** `<command> doctor` / `<command> website`; with `dart run <package>`, doctor is `dart run <package>:doctor`. */
export function setupSubcommand(sub: 'doctor' | 'website', env: NodeJS.ProcessEnv = process.env): string {
  const base = setupCommand(env);
  const dart = /^((?:fvm )?dart run [a-z0-9_]+)$/.exec(base);
  if (dart && sub === 'doctor') return `${dart[1]}:doctor`;
  return `${base} ${sub}`;
}
