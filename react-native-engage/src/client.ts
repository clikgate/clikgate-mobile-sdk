import {
  ClikgateError,
  type ClikgateRequestContext,
} from '@clikgate/react-native';

import { asJson } from './models';

/** What Engage needs from the core package (`Clikgate` from `@clikgate/react-native`). */
export interface EngageCore {
  isFeatureEnabled(key: string): Promise<boolean>;
  getRequestContext(): Promise<ClikgateRequestContext>;
  reportServerError(code: string, feature?: string | null): Promise<void>;
}

export type FetchLike = (
  url: string,
  init: {
    method: string;
    headers: Record<string, string>;
    body?: string;
    signal?: AbortSignal;
  }
) => Promise<{
  status: number;
  text(): Promise<string>;
}>;

/** One `/v1/sdk/...` call. */
export interface EngageRequest<T> {
  /** Organisation feature of the endpoint (`referrals`, `leaderboards`, `offline_codes`). */
  feature: string;
  method: 'GET' | 'POST';
  /** Path below the base URL, starting with `/v1/sdk/`. */
  path: string;
  query?: Record<string, string | number | null | undefined>;
  body?: Record<string, unknown>;
  /** Acts on behalf of the user: `not_identified` without `Clikgate.identifyUser` (no network). */
  identified: boolean;
  /** GET whose result may be served from the 60 s in-memory cache. */
  cacheable: boolean;
  parse: (body: unknown) => T;
}

/** Read results are kept in memory for this long. */
export const CACHE_TTL_MS = 60_000;

/** Codes that the core SDK must apply globally (kill switch, bad key, lost installation). */
const GLOBAL_CODES = new Set([
  'invalid_sdk_key',
  'sdk_disabled',
  'installation_unknown',
]);

/** RFC 3986 percent-encoding (unreserved characters only are kept). */
export function encodeRfc3986(s: string): string {
  return encodeURIComponent(s).replace(
    /[!'()*]/g,
    (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase()
  );
}

function queryString(q: EngageRequest<unknown>['query']): string {
  if (q == null) return '';
  const parts = Object.entries(q)
    .filter(([, v]) => v != null)
    .map(([k, v]) => `${encodeRfc3986(k)}=${encodeRfc3986(String(v))}`);
  return parts.length === 0 ? '' : `?${parts.join('&')}`;
}

/**
 * The Engage HTTP layer: feature switch, request context, identity rule, cache, a single retry
 * for network errors, and error mapping.
 */
export class EngageClient {
  private readonly cache = new Map<string, { at: number; value: unknown }>();

  constructor(
    private readonly core: EngageCore,
    private readonly fetchFn: FetchLike,
    private readonly now: () => number,
    private readonly timeoutMs: number,
    private readonly retryDelayMs: number
  ) {}

  clearCache(): void {
    this.cache.clear();
  }

  async call<T>(req: EngageRequest<T>): Promise<T> {
    // 1. Feature switch, no network.
    if (!(await this.core.isFeatureEnabled(req.feature))) {
      throw featureDisabled(req.feature);
    }
    // 2. Context from the core SDK (not_configured, opted_out, install_pending, ...).
    const ctx = await this.core.getRequestContext();
    // 3. Identity rule.
    if (req.identified && ctx.customerUserId == null) {
      throw new ClikgateError(
        'not_identified',
        'Call Clikgate.identifyUser({ customerId }) first.'
      );
    }
    const pathAndQuery = req.path + queryString(req.query);
    const key = req.cacheable
      ? [
          ctx.installationId,
          ctx.customerUserId ?? '',
          ctx.identityToken != null ? '1' : '0',
          pathAndQuery,
        ].join('|')
      : null;
    if (key != null) {
      const hit = this.cache.get(key);
      if (hit != null && this.now() - hit.at < CACHE_TTL_MS) {
        return hit.value as T;
      }
    }
    // Any write invalidates every cached read.
    if (req.method !== 'GET') this.cache.clear();

    const { status, text } = await this.send(ctx, req, pathAndQuery);
    let json: unknown = {};
    if (text.trim().length > 0) {
      try {
        json = JSON.parse(text);
      } catch {
        if (status >= 200 && status < 300) {
          throw new ClikgateError('server_error', 'Invalid JSON response', {
            status,
          });
        }
      }
    }
    if (status >= 200 && status < 300) {
      const body = asJson(json);
      if (body.accepted === false && body.reason === 'feature_disabled') {
        const named =
          typeof body.feature === 'string' && body.feature.length > 0
            ? body.feature
            : req.feature;
        await this.core.reportServerError('feature_disabled', named);
        throw featureDisabled(named);
      }
      const value = req.parse(json);
      if (key != null) this.cache.set(key, { at: this.now(), value });
      return value;
    }
    const error = errorFromBody(status, json);
    if (GLOBAL_CODES.has(error.code)) {
      await this.core.reportServerError(error.code, null);
    } else if (error.code === 'feature_disabled') {
      await this.core.reportServerError(
        'feature_disabled',
        error.feature ?? req.feature
      );
    }
    throw error;
  }

  /** At most one retry, only for network errors (connection failure or timeout). */
  private async send(
    ctx: ClikgateRequestContext,
    req: EngageRequest<unknown>,
    pathAndQuery: string
  ): Promise<{ status: number; text: string }> {
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'Clikgate-SDK-Key': ctx.sdkKey,
      'Clikgate-SDK-Version': ctx.sdkVersion,
      'Clikgate-Installation-Id': ctx.installationId,
    };
    if (ctx.nativeSdkVersion != null) {
      headers['Clikgate-SDK-Native-Version'] = ctx.nativeSdkVersion;
    }
    if (ctx.identityToken != null) {
      headers['Clikgate-Identity-Token'] = ctx.identityToken;
    }
    let body: string | undefined;
    if (req.body != null) {
      body = JSON.stringify(req.body);
      headers['Content-Type'] = 'application/json; charset=utf-8';
    }
    const url = ctx.apiBaseUrl.replace(/\/+$/, '') + pathAndQuery;
    for (let attempt = 0; ; attempt++) {
      try {
        return await this.once(url, req.method, headers, body);
      } catch (e) {
        if (attempt >= 1) throw e;
        await new Promise((r) => setTimeout(r, this.retryDelayMs));
      }
    }
  }

  private async once(
    url: string,
    method: string,
    headers: Record<string, string>,
    body: string | undefined
  ): Promise<{ status: number; text: string }> {
    const controller =
      typeof AbortController === 'function' ? new AbortController() : null;
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      controller?.abort();
    }, this.timeoutMs);
    try {
      const res = await this.fetchFn(url, {
        method,
        headers,
        body,
        signal: controller?.signal,
      });
      return { status: res.status, text: await res.text() };
    } catch (e) {
      throw new ClikgateError(
        timedOut ? 'timeout' : 'network_error',
        timedOut
          ? 'Request timed out'
          : e instanceof Error && e.message.length > 0
            ? e.message
            : 'Network request failed'
      );
    } finally {
      clearTimeout(timer);
    }
  }
}

function featureDisabled(feature: string): ClikgateError {
  return new ClikgateError(
    'feature_disabled',
    `The '${feature}' feature is switched off for this app.`,
    { feature }
  );
}

/** The standard Clikgate error body, or a code derived from the HTTP status. */
export function errorFromBody(status: number, json: unknown): ClikgateError {
  const e = asJson(asJson(json).error);
  const code = typeof e.code === 'string' && e.code.length > 0 ? e.code : null;
  const str = (v: unknown) => (typeof v === 'string' ? v : null);
  if (code != null) {
    return new ClikgateError(code, str(e.message) ?? code, {
      status,
      param: str(e.param),
      feature: str(e.feature),
      offlineTouchId: str(e.offline_touch_id),
    });
  }
  const fallback =
    status === 401
      ? 'invalid_sdk_key'
      : status === 422
        ? 'validation_error'
        : status === 429
          ? 'rate_limited'
          : status >= 500
            ? 'server_error'
            : `http_${status}`;
  return new ClikgateError(fallback, `HTTP ${status}`, { status });
}
