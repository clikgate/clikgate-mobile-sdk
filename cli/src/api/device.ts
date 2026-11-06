import { spawn } from 'node:child_process';
import * as os from 'node:os';
import { CLI_VERSION } from '../constants';
import { ApiClient, ApiError, NetworkError } from './client';

/**
 * OAuth 2.0 Device Authorization Grant client (RFC 8628), against Clikgate's endpoints (B.1):
 * POST /v1/cli/device-codes, then poll POST /v1/cli/token every `interval` seconds, adding
 * 5 seconds on `slow_down` (§3.5), until approved, denied or expired. The token lives only in
 * memory and is never printed or written anywhere.
 */

export interface DeviceCode {
  device_code: string;
  user_code: string;
  verification_uri: string;
  verification_uri_complete?: string;
  expires_in: number;
  interval?: number;
}

export interface CliSession {
  accessToken: string;
  expiresIn: number;
  organization: { id: string; name: string };
}

export class SignInError extends Error {
  constructor(
    readonly reason: 'denied' | 'expired' | 'failed',
    message: string
  ) {
    super(message);
  }
}

export interface DeviceFlowDeps {
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
  print: (line: string) => void;
  openBrowser?: (url: string) => void;
}

export function clientInfo(projectType: string) {
  return {
    cli_version: CLI_VERSION,
    os: `${os.platform()} ${os.release()}`,
    hostname_hint: os.hostname().slice(0, 32),
    project_type: projectType,
  };
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

export async function signIn(api: ApiClient, projectType: string, deps: DeviceFlowDeps): Promise<CliSession> {
  const sleep = deps.sleep ?? defaultSleep;
  const now = deps.now ?? Date.now;
  let code: DeviceCode;
  try {
    code = await api.post<DeviceCode>('/v1/cli/device-codes', { client_info: clientInfo(projectType) });
  } catch (e) {
    if (e instanceof ApiError && e.status === 429) throw new SignInError('failed', 'Too many sign-in attempts from this network. Try again in an hour, or use offline mode (--sdk-key, --domain).');
    throw new SignInError('failed', `Couldn't start sign-in: ${(e as Error).message}`);
  }
  const url = code.verification_uri_complete ?? `${code.verification_uri}?code=${encodeURIComponent(code.user_code)}`;
  deps.print('To connect this project to Clikgate, open:');
  deps.print(`  ${url}`);
  deps.print(`and check that the code shown is ${code.user_code}.`);
  // Change 09 (N.3): two-factor is asked for on the approval page; polling is unchanged.
  deps.print('If your account uses two-factor sign-in, the page also asks for your authenticator code (or a recovery code).');
  deps.openBrowser?.(url);

  let interval = Math.max(1, code.interval ?? 5) * 1000;
  const deadline = now() + Math.max(1, code.expires_in) * 1000;
  let networkFailures = 0;
  const started = now();
  let pendingHinted = false;
  for (;;) {
    await sleep(interval);
    if (now() > deadline) throw new SignInError('expired', 'The sign-in code expired. Run the command again.');
    try {
      const r = await api.post<{ access_token: string; expires_in: number; organization: { id: string; name: string } }>('/v1/cli/token', {
        device_code: code.device_code,
      });
      return { accessToken: r.access_token, expiresIn: r.expires_in, organization: r.organization };
    } catch (e) {
      if (e instanceof ApiError) {
        networkFailures = 0;
        switch (e.code) {
          case 'authorization_pending':
            if (!pendingHinted && now() - started > 60_000) {
              pendingHinted = true;
              deps.print('Still waiting: approve the sign-in in the browser (you may be asked for your authenticator code).');
            }
            continue;
          case 'slow_down': {
            // RFC 8628 §3.5: +5 s for this and all later requests; Clikgate also sends the new
            // interval (error.interval, seconds) and Retry-After: use the largest.
            const server = Number(e.extra.interval);
            interval = Math.max(interval + 5000, Number.isFinite(server) ? server * 1000 : 0, (e.retryAfter ?? 0) * 1000);
            continue;
          }
          case 'access_denied':
            throw new SignInError('denied', 'Sign-in was denied in the browser.');
          case 'expired_token':
            throw new SignInError('expired', 'The sign-in code expired or was already used. Run the command again.');
          case 'invalid_device_code':
            throw new SignInError('failed', 'Clikgate didn\'t recognise the sign-in code. Run the command again.');
          default:
            if (e.status >= 500) continue;
            throw new SignInError('failed', `Sign-in failed: ${e.message}`);
        }
      }
      if (e instanceof NetworkError && ++networkFailures < 5) continue;
      throw new SignInError('failed', `Sign-in failed: ${(e as Error).message}`);
    }
  }
}

/** Opens a URL in the default browser when there is one (never in CI or over SSH). */
export function openBrowser(url: string): void {
  if (process.env.CI || process.env.SSH_CONNECTION || process.env.CLIKGATE_NO_BROWSER) return;
  const platform = os.platform();
  let cmd: string;
  let args: string[];
  if (platform === 'darwin') {
    cmd = 'open';
    args = [url];
  } else if (platform === 'win32') {
    cmd = 'cmd';
    args = ['/c', 'start', '""', url.replace(/&/g, '^&')];
  } else {
    if (!process.env.DISPLAY && !process.env.WAYLAND_DISPLAY) return;
    cmd = 'xdg-open';
    args = [url];
  }
  try {
    const child = spawn(cmd, args, { stdio: 'ignore', detached: true });
    child.on('error', () => undefined);
    child.unref();
  } catch {
    // The URL is printed; opening it is a convenience.
  }
}
