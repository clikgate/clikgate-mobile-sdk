export type Platform = 'flutter' | 'react-native' | 'expo' | 'android' | 'ios';
export const PLATFORMS: Platform[] = ['flutter', 'react-native', 'expo', 'android', 'ios'];

/** Website servers the `website` command recognises (change 16 S, R.2). */
export type WebsiteServer = 'nextjs' | 'express' | 'laravel' | 'django' | 'spring-boot' | 'aspnet-core' | 'wordpress' | 'shopify';
export const WEBSITE_SERVERS: WebsiteServer[] = ['nextjs', 'express', 'laravel', 'django', 'spring-boot', 'aspnet-core', 'wordpress', 'shopify'];

export interface Options {
  command: 'setup' | 'doctor' | 'website';
  dryRun: boolean;
  yes: boolean;
  cwd: string;
  platform?: Platform;
  app?: string;
  sdkKey?: string;
  domains?: string[];
  json: boolean;
  apiUrl?: string;
  /** website: the server framework (`none`: no server of its own), instead of detecting or asking. */
  websiteServer?: WebsiteServer | 'none';
  /** website: the publishable web key (`cgw_test_…` / `cgw_live_…`) for a new script tag. */
  webKey?: string;
  color?: boolean;
  verbose: boolean;
  version: boolean;
  help: boolean;
  /** Extra (documented) flags: skip the package install / the doctor live-event wait. */
  install: boolean;
  wait: boolean;
}

export class UsageError extends Error {}

const BOOLEAN: Record<string, keyof Options> = {
  '--dry-run': 'dryRun',
  '--yes': 'yes',
  '-y': 'yes',
  '--json': 'json',
  '--verbose': 'verbose',
  '--version': 'version',
  '-v': 'version',
  '--help': 'help',
  '-h': 'help',
};
const VALUE = new Set(['--cwd', '--platform', '--app', '--sdk-key', '--domain', '--api-url', '--website-server', '--web-key']);

export function parseArgs(argv: string[], cwd = process.cwd()): Options {
  const o: Options = {
    command: 'setup',
    dryRun: false,
    yes: false,
    cwd,
    json: false,
    verbose: false,
    version: false,
    help: false,
    install: true,
    wait: true,
  };
  let sawCommand = false;
  for (let i = 0; i < argv.length; i++) {
    let arg = argv[i];
    let inline: string | undefined;
    const eq = arg.indexOf('=');
    if (arg.startsWith('--') && eq > 0) {
      inline = arg.slice(eq + 1);
      arg = arg.slice(0, eq);
    }
    if (arg in BOOLEAN && inline === undefined) {
      (o as unknown as Record<string, unknown>)[BOOLEAN[arg]] = true;
      continue;
    }
    if (arg === '--no-color') { o.color = false; continue; }
    if (arg === '--no-install') { o.install = false; continue; }
    if (arg === '--no-wait') { o.wait = false; continue; }
    if (VALUE.has(arg)) {
      const value = inline ?? argv[++i];
      if (value === undefined || (inline === undefined && value.startsWith('--'))) {
        throw new UsageError(`${arg} needs a value`);
      }
      switch (arg) {
        case '--cwd': o.cwd = value; break;
        case '--platform':
          if (!PLATFORMS.includes(value as Platform)) {
            throw new UsageError(`--platform must be one of ${PLATFORMS.join(', ')}`);
          }
          o.platform = value as Platform;
          break;
        case '--app': o.app = value; break;
        case '--sdk-key': o.sdkKey = value.trim(); break;
        case '--domain':
          o.domains = [...(o.domains ?? []), ...value.split(',').map(normaliseHost).filter(Boolean)];
          break;
        case '--api-url': o.apiUrl = value.replace(/\/+$/, ''); break;
        case '--website-server': {
          const v = value.trim().toLowerCase();
          if (v !== 'none' && !WEBSITE_SERVERS.includes(v as WebsiteServer)) {
            throw new UsageError(`--website-server must be one of ${WEBSITE_SERVERS.join(', ')}, none`);
          }
          o.websiteServer = v as WebsiteServer | 'none';
          break;
        }
        case '--web-key': o.webKey = value.trim(); break;
      }
      continue;
    }
    if (!arg.startsWith('-') && !sawCommand) {
      if (arg === 'doctor' || arg === 'setup' || arg === 'website') {
        o.command = arg;
        sawCommand = true;
        continue;
      }
      throw new UsageError(`Unknown command "${arg}". Use "doctor", "website" or no command.`);
    }
    throw new UsageError(`Unknown option ${arg}`);
  }
  if (o.json && o.command !== 'doctor') throw new UsageError('--json works with doctor only');
  if ((o.websiteServer || o.webKey !== undefined) && o.command !== 'website') throw new UsageError('--website-server and --web-key work with the website command only (npx @clikgate/setup website)');
  if (o.command === 'website' && (o.platform || o.sdkKey !== undefined || o.domains || o.app)) {
    throw new UsageError('--platform, --app, --sdk-key and --domain are for app projects, not the website command');
  }
  if (o.domains && !o.sdkKey && o.command === 'setup') throw new UsageError('--domain is used with --sdk-key (offline mode)');
  if (o.domains) {
    const bad = o.domains.find((d) => !/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(d));
    if (bad) throw new UsageError(`"${bad}" isn't a host name (expected e.g. yourapp.ciz.to or go.acme.com)`);
  }
  return o;
}

export function normaliseHost(d: string): string {
  return d
    .trim()
    .replace(/^https?:\/\//i, '')
    .replace(/^applinks:/i, '')
    .replace(/\/.*$/, '')
    .toLowerCase();
}

export const HELP = `Set up Clikgate in this app project.

Usage
  npx @clikgate/setup [options]          interactive setup
  npx @clikgate/setup doctor [options]   checks only, changes nothing
  npx @clikgate/setup website [options]  add the web script (and, with your own server, the /cg/keep route)

Options
  --dry-run          show the plan and diffs, change nothing
  --yes              apply without the confirmation prompt (diffs are still printed)
  --cwd <path>       project folder (default: current)
  --platform <flutter|react-native|expo|android|ios>   skip detection
  --app <app_id>     use this Clikgate app
  --sdk-key <cg_sdk_test_…> --domain <host>[,<host>]   offline mode: no sign-in. Hosts: your app's
                     link subdomain (yourapp.ciz.to, or yourapp.clk.ng on the Free plan; debug
                     builds get yourapp.dev.ciz.to) and custom domains, never a shared domain
                     (ciz.to, clk.ng, clkg.to, dev.ciz.to)
  --json             machine-readable output (doctor only)
  --api-url <url>    for Clikgate's own development
  --no-install       don't run the package manager (you run it yourself)
  --no-wait          doctor: don't wait for the first event from your app
  --website-server <nextjs|express|laravel|django|spring-boot|aspnet-core|wordpress|shopify|none>
                     website: skip detection and the "own server" question (none: no route)
  --web-key <cgw_test_…>   website: the publishable web key for a new script tag
  --no-color, --verbose, --version, --help

Exit codes: 0 success, 1 problems found or a step failed, 2 cancelled, 3 sign-in failed.
Docs: https://clikgate.com/docs/setup-command`;
