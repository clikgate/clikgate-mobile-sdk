import * as http from 'node:http';
import type { AddressInfo } from 'node:net';

/**
 * A mock of the Clikgate API endpoints the setup command uses (backend spec B.1–B.3), with the
 * shapes the backend confirmed: error envelope, RFC 8628 token errors (428/429/403/410, or 400
 * with the same codes), list envelope, `mode: live|test` domains, setup-check with `applies`, and the
 * change 09 app link subdomains (contract B2: `link_subdomain`, `app_link_domains`, availability).
 */

export interface MockApp {
  id: string;
  platform: 'android' | 'ios';
  name: string;
  package_name?: string | null;
  bundle_id?: string | null;
  team_id?: string | null;
  sha256_cert_fingerprints: string[];
  sdk_key_test: string;
  sdk_settings: { shared_domain_app_links: boolean; test_domain_app_links: boolean };
  link_subdomain?: string;
  link_subdomain_confirmed?: boolean;
}

export interface MockOptions {
  /** Token endpoint answers before success, e.g. ['authorization_pending', 'slow_down']. */
  tokenSequence?: string[];
  /** Use 400 for token errors (RFC 8628 style) instead of 428/429/403/410. */
  rfcStatuses?: boolean;
  /** Seconds the server adds to the interval on slow_down (Clikgate: 5). */
  slowDownStep?: number;
  apps?: MockApp[];
  domains?: { id: string; hostname: string; status: string; mode: 'live' | 'test'; kind?: string; platform_tier?: string | null; eligible_for_new_links?: boolean | null }[];
  /** Link subdomains another organisation already uses. */
  takenSubdomains?: string[];
  setupCheck?: (app: MockApp, polls: number) => unknown;
  /** Parent of the apps' live link subdomain: `ciz.to` (Starter and up, default) or `clk.ng` (Free, change 10). */
  liveParent?: 'ciz.to' | 'clk.ng';
}

export interface MockServer {
  url: string;
  requests: { method: string; path: string; body: unknown; auth?: string }[];
  apps: MockApp[];
  close(): Promise<void>;
}

const TOKEN = 'cg_cli_SECRET_token_value_123';
const STATUS: Record<string, number> = { authorization_pending: 428, slow_down: 429, access_denied: 403, expired_token: 410, invalid_device_code: 422 };

export async function startMockServer(opts: MockOptions = {}): Promise<MockServer> {
  const requests: MockServer['requests'] = [];
  const apps: MockApp[] = opts.apps ? structuredClone(opts.apps) : [];
  const domains = opts.domains ?? [
    { id: 'dom_1', hostname: 'ciz.to', status: 'active', mode: 'live', kind: 'platform', platform_tier: 'paid', eligible_for_new_links: true },
    { id: 'dom_2', hostname: 'clk.ng', status: 'active', mode: 'live', kind: 'platform', platform_tier: 'free', eligible_for_new_links: false },
    { id: 'dom_3', hostname: 'go.acme.com', status: 'active', mode: 'live', kind: 'custom', platform_tier: null, eligible_for_new_links: null },
    { id: 'dom_5', hostname: 'old.acme.com', status: 'pending', mode: 'live', kind: 'custom', platform_tier: null, eligible_for_new_links: null },
    { id: 'dom_4', hostname: 'dev.ciz.to', status: 'active', mode: 'test', kind: 'platform', platform_tier: 'test', eligible_for_new_links: true },
  ];
  const taken = new Set(opts.takenSubdomains ?? []);
  const parent = opts.liveParent ?? 'ciz.to';
  const customs = () => domains.filter((d) => d.kind === 'custom' && d.status === 'active').map((d) => d.hostname);
  const slug = (name: string) => name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 30);
  /** The app object as GET /v1/apps returns it (B2.2). */
  const view = (a: MockApp) => {
    const sub = a.link_subdomain;
    const hostnames = sub ? { live: `${sub}.${parent}`, test: `${sub}.dev.ciz.to` } : null;
    const confirmed = a.link_subdomain_confirmed !== false;
    return {
      ...a,
      sdk_key: null,
      link_subdomain: sub ?? null,
      link_subdomain_confirmed: confirmed,
      link_subdomain_editable: true,
      link_hostnames: hostnames,
      app_link_domains: confirmed && hostnames ? { release: [hostnames.live, ...customs()], debug: [hostnames.test] } : { release: [], debug: [] },
    };
  };
  const available = (name: string, appId?: string) => {
    if (!/^[a-z0-9][a-z0-9-]{1,28}[a-z0-9]$/.test(name)) return 'invalid_format';
    if (['www', 'api', 'app', 'dev', 'go', 'clikgate'].includes(name)) return 'reserved';
    if (taken.has(name) || apps.some((a) => a.id !== appId && a.link_subdomain === name && a.link_subdomain_confirmed !== false)) return 'taken';
    return null;
  };
  const sequence = [...(opts.tokenSequence ?? ['authorization_pending'])];
  const polls = new Map<string, number>();
  let created = 0;

  const send = (res: http.ServerResponse, status: number, body: unknown) => {
    res.writeHead(status, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body));
  };
  const error = (res: http.ServerResponse, status: number, code: string, message = code, extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) => {
    res.writeHead(status, { 'Content-Type': 'application/json', ...headers });
    res.end(JSON.stringify({ error: { type: 'invalid_request', code, message, param: null, request_id: 'req_test', ...extra } }));
  };
  let interval = 5;

  const server = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const url = new URL(req.url ?? '/', 'http://localhost');
      const body = raw ? JSON.parse(raw) : undefined;
      requests.push({ method: req.method ?? 'GET', path: url.pathname + url.search, body, auth: req.headers.authorization });
      const authed = req.headers.authorization === `Bearer ${TOKEN}`;
      const p = url.pathname;
      if (req.method === 'POST' && p === '/v1/cli/device-codes') {
        return send(res, 200, {
          device_code: 'dc_secret',
          user_code: 'BCDF-GHJK',
          verification_uri: 'https://app.clikgate.com/cli',
          verification_uri_complete: 'https://app.clikgate.com/cli?code=BCDF-GHJK',
          expires_in: 600,
          interval: 5,
        });
      }
      if (req.method === 'POST' && p === '/v1/cli/token') {
        const next = sequence.shift();
        if (next === 'slow_down') {
          interval += opts.slowDownStep ?? 5;
          return error(res, opts.rfcStatuses ? 400 : 429, next, next, { interval }, { 'Retry-After': String(interval) });
        }
        if (next) return error(res, opts.rfcStatuses ? 400 : STATUS[next], next);
        return send(res, 200, { access_token: TOKEN, token_type: 'bearer', expires_in: 3600, organization: { id: 'org_1', name: 'Acme' } });
      }
      if (!authed) return error(res, 401, 'unauthenticated');
      if (req.method === 'GET' && p === '/v1/apps') return send(res, 200, { object: 'list', data: apps.map(view), has_more: false, next_cursor: null });
      if (req.method === 'GET' && p === '/v1/link-subdomains/availability') {
        const name = url.searchParams.get('name') ?? '';
        const reason = available(name, url.searchParams.get('app_id') ?? undefined);
        return send(res, 200, { object: 'link_subdomain_availability', name, available: !reason, reason, message: reason === 'taken' ? 'Another app already uses this name.' : reason, suggestion: reason ? `${name}-2` : null, hostnames: reason ? null : { live: `${name}.${parent}`, test: `${name}.dev.ciz.to` } });
      }
      if (req.method === 'POST' && p === '/v1/apps') {
        const app: MockApp = {
          id: `app_${++created}`,
          platform: body.platform,
          name: body.name,
          package_name: body.package_name ?? null,
          bundle_id: body.bundle_id ?? null,
          team_id: body.team_id ?? null,
          sha256_cert_fingerprints: body.sha256_cert_fingerprints ?? [],
          sdk_key_test: `cg_sdk_test_${body.platform}${created}`,
          sdk_settings: { shared_domain_app_links: false, test_domain_app_links: true },
          // B2.1: a new app gets a confirmed subdomain; a same-named app on the other platform reuses it.
          link_subdomain: apps.find((a) => a.name === body.name && a.platform !== body.platform)?.link_subdomain ?? slug(body.name),
          link_subdomain_confirmed: true,
        };
        apps.push(app);
        return send(res, 200, view(app));
      }
      const appMatch = /^\/v1\/apps\/([^/]+)(\/sdk-settings)?$/.exec(p);
      if (appMatch) {
        const app = apps.find((a) => a.id === appMatch[1]);
        if (!app) return error(res, 404, 'not_found');
        if (req.method === 'GET') return send(res, 200, view(app));
        if (req.method === 'PATCH' && appMatch[2]) {
          Object.assign(app.sdk_settings, body);
          return send(res, 200, app);
        }
        if (req.method === 'PATCH') {
          if (body.sha256_cert_fingerprints) app.sha256_cert_fingerprints = Array.from(new Set([...app.sha256_cert_fingerprints, ...body.sha256_cert_fingerprints]));
          if (body.team_id) app.team_id = body.team_id;
          if (body.link_subdomain !== undefined) {
            const reason = available(body.link_subdomain, app.id);
            if (reason) return error(res, 422, 'link_subdomain_unavailable', 'This link subdomain is not available.', { param: 'link_subdomain', reason });
            app.link_subdomain = body.link_subdomain;
            app.link_subdomain_confirmed = true;
          }
          return send(res, 200, view(app));
        }
      }
      if (req.method === 'GET' && p === '/v1/domains') return send(res, 200, { object: 'list', data: domains, has_more: false, next_cursor: null });
      if (req.method === 'GET' && p === '/v1/cli/setup-check') {
        const app = apps.find((a) => a.id === url.searchParams.get('app_id'));
        if (!app) return error(res, 404, 'not_found');
        const n = (polls.get(app.id) ?? 0) + 1;
        polls.set(app.id, n);
        if (opts.setupCheck) return send(res, 200, opts.setupCheck(app, n));
        return send(res, 200, defaultSetupCheck(app, n, customs(), parent));
      }
      return error(res, 403, 'cli_scope', 'Not allowed for CLI tokens');
    });
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', () => r()));
  const { port } = server.address() as AddressInfo;
  return {
    url: `http://127.0.0.1:${port}`,
    requests,
    apps,
    close: () => new Promise((r) => server.close(() => r())),
  };
}

export function defaultSetupCheck(app: MockApp, polls: number, customDomains: string[] = ['go.acme.com'], parent = 'ciz.to') {
  const ios = app.platform === 'ios';
  const file = (applies: boolean) => ({ applies, served: true, contains_app: applies, problem: null });
  return {
    object: 'cli_setup_check',
    app: {
      id: app.id,
      platform: app.platform,
      bundle_id: app.bundle_id,
      package_name: app.package_name,
      team_id: app.team_id,
      team_id_present: Boolean(app.team_id),
      sha256_cert_fingerprints: app.sha256_cert_fingerprints,
      fingerprints_present: app.sha256_cert_fingerprints.length > 0,
      link_subdomain: app.link_subdomain ?? null,
      link_subdomain_confirmed: app.link_subdomain_confirmed !== false,
      link_hostnames: app.link_subdomain ? { live: `${app.link_subdomain}.${parent}`, test: `${app.link_subdomain}.dev.ciz.to` } : null,
    },
    // B2.4: the app's live and test subdomains plus the custom domains; shared domains aren't checked.
    domains: [...(app.link_subdomain ? [`${app.link_subdomain}.${parent}`, `${app.link_subdomain}.dev.ciz.to`] : []), ...customDomains].map((hostname) => ({
      hostname,
      mode: hostname.endsWith('.dev.ciz.to') ? 'test' : 'live',
      aasa: file(ios),
      assetlinks: file(!ios),
    })),
    app_link_domains: app.link_subdomain ? { release: [`${app.link_subdomain}.${parent}`, ...customDomains], debug: [`${app.link_subdomain}.dev.ciz.to`] } : { release: [], debug: [] },
    shared_domains: ['ciz.to', 'clk.ng', 'clkg.to', 'dev.ciz.to'],
    sdk: {
      first_test_request_at: polls >= 2 ? '2026-10-26T10:00:00Z' : null,
      last_test_request_at: polls >= 2 ? '2026-10-26T10:00:00Z' : null,
      sdk_version: polls >= 2 ? '2.0.0' : null,
      platform: polls >= 2 ? app.platform : null,
      warnings: [],
    },
    next_steps: [],
  };
}

export const MOCK_TOKEN = TOKEN;
