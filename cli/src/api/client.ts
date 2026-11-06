import * as os from 'node:os';
import { CLI_VERSION } from '../constants';

/** Error envelope (backend spec 6.2): `{"error": {type, code, message, param, request_id}}`. */
export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly param?: string | null,
    readonly requestId?: string | null,
    /** Other fields of the error object (e.g. `interval` on slow_down). */
    readonly extra: Record<string, unknown> = {},
    /** Retry-After header, in seconds. */
    readonly retryAfter?: number
  ) {
    super(message);
  }
}

export class NetworkError extends Error {}

export type Fetch = typeof fetch;

export interface ClientOptions {
  baseUrl: string;
  fetch?: Fetch;
  /** cg_cli_ token, kept in memory only. */
  token?: string;
}

export function userAgent(): string {
  return `clikgate-setup/${CLI_VERSION} (node ${process.versions.node}; ${os.platform()} ${os.arch()})`;
}

export class ApiClient {
  private readonly fetchImpl: Fetch;
  token?: string;

  constructor(private readonly opts: ClientOptions) {
    this.fetchImpl = opts.fetch ?? fetch;
    this.token = opts.token;
  }

  get baseUrl(): string {
    return this.opts.baseUrl;
  }

  async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const headers: Record<string, string> = {
      Accept: 'application/json',
      'User-Agent': userAgent(),
    };
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    let res: Response;
    try {
      res = await this.fetchImpl(this.opts.baseUrl + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(30_000),
      });
    } catch (e) {
      throw new NetworkError(`Can't reach ${this.opts.baseUrl} (${(e as Error).message})`);
    }
    const text = await res.text();
    let json: unknown = undefined;
    if (text) {
      try {
        json = JSON.parse(text);
      } catch {
        json = undefined;
      }
    }
    if (!res.ok) {
      const err = (json as { error?: { code?: string; message?: string; param?: string; request_id?: string } & Record<string, unknown> } | undefined)?.error;
      const ra = Number(res.headers.get('retry-after'));
      throw new ApiError(
        res.status,
        err?.code ?? `http_${res.status}`,
        err?.message ?? `HTTP ${res.status}`,
        err?.param,
        err?.request_id,
        err ?? {},
        Number.isFinite(ra) && ra > 0 ? ra : undefined
      );
    }
    return json as T;
  }

  get<T>(path: string): Promise<T> {
    return this.request<T>('GET', path);
  }
  post<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>('POST', path, body);
  }
  patch<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>('PATCH', path, body);
  }

  /** Reads every page of a list endpoint (`{data, has_more, next_cursor}`, `starting_after`). */
  async list<T extends { id: string }>(path: string): Promise<T[]> {
    const out: T[] = [];
    let after: string | undefined;
    for (let page = 0; page < 50; page++) {
      const sep = path.includes('?') ? '&' : '?';
      const r = await this.get<{ data: T[]; has_more?: boolean; next_cursor?: string | null }>(
        `${path}${sep}limit=100${after ? `&starting_after=${encodeURIComponent(after)}` : ''}`
      );
      out.push(...(r.data ?? []));
      if (!r.has_more || !r.data?.length) break;
      after = r.next_cursor ?? r.data[r.data.length - 1].id;
    }
    return out;
  }
}
