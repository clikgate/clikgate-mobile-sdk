import { SHARED_PLATFORM_DOMAINS, TEST_LINK_DOMAIN } from '../constants';
import { ApiClient } from './client';

/** The CLI token's allow-list (B.2). Responses are read leniently: unknown fields are ignored. */

export interface App {
  id: string;
  platform: 'ios' | 'android';
  name: string;
  bundle_id?: string | null;
  team_id?: string | null;
  package_name?: string | null;
  sha256_cert_fingerprints?: string[];
  /** Publishable test key; the CLI token never receives the live `sdk_key`. */
  sdk_key_test?: string;
  sdk_settings?: { shared_domain_app_links?: boolean; test_domain_app_links?: boolean; [k: string]: unknown };
  /** Change 09 (N.1): the app's link subdomain (never null; an unconfirmed suggestion for older apps). */
  link_subdomain?: string | null;
  link_subdomain_confirmed?: boolean;
  link_subdomain_editable?: boolean;
  link_hostnames?: { live: string; test: string } | null;
  /** The hosts to write: release = the app subdomain + active custom domains, debug = the test subdomain. Empty while unconfirmed; never a shared domain. */
  app_link_domains?: { release: string[]; debug: string[] } | null;
}

export interface SubdomainAvailability {
  name: string;
  available: boolean;
  reason?: 'invalid_format' | 'reserved' | 'blocked' | 'taken' | null;
  message?: string | null;
  suggestion?: string | null;
  hostnames?: { live: string; test: string } | null;
}

export interface Domain {
  id: string;
  hostname: string;
  status?: string;
  mode?: string;
  platform_tier?: string | null;
  eligible_for_new_links?: boolean | null;
  /** Change 09: `custom`, `platform` or `app_subdomain`. */
  kind?: string;
}

export interface FileCheck {
  applies?: boolean;
  served?: boolean;
  contains_app?: boolean;
  problem?: string | null;
}

export interface SetupCheck {
  object?: string;
  app?: {
    id?: string;
    platform?: string;
    bundle_id?: string | null;
    package_name?: string | null;
    team_id?: string | null;
    team_id_present?: boolean;
    sha256_cert_fingerprints?: string[];
    fingerprints_present?: boolean;
    link_subdomain?: string | null;
    link_subdomain_confirmed?: boolean;
    link_hostnames?: { live: string; test: string } | null;
  };
  app_link_domains?: { release: string[]; debug: string[] } | null;
  shared_domains?: string[];
  domains?: { hostname: string; mode?: string; aasa?: FileCheck; assetlinks?: FileCheck }[];
  sdk?: {
    first_test_request_at?: string | null;
    last_test_request_at?: string | null;
    sdk_version?: string | null;
    platform?: string | null;
    warnings?: { code?: string; severity?: string; message?: string }[];
  };
  next_steps?: { message: string; doc_url?: string | null }[];
}

export function isTestDomain(d: Domain): boolean {
  return d.mode === 'test' || d.platform_tier === 'test' || d.hostname === TEST_LINK_DOMAIN;
}

export function isSharedPlatformDomain(host: string): boolean {
  return SHARED_PLATFORM_DOMAINS.includes(host);
}

/** Live domains new links can use: active, not the test domain, eligible for this plan. */
export function liveDomains(domains: Domain[]): string[] {
  return domains
    .filter((d) => !isTestDomain(d) && (d.status === undefined || d.status === 'active') && d.eligible_for_new_links !== false)
    .map((d) => d.hostname.toLowerCase());
}

export class Clikgate {
  constructor(readonly api: ApiClient) {}

  listApps(): Promise<App[]> {
    return this.api.list<App>('/v1/apps');
  }
  getApp(id: string): Promise<App> {
    return this.api.get<App>(`/v1/apps/${encodeURIComponent(id)}`);
  }
  createApp(body: Record<string, unknown>): Promise<App> {
    return this.api.post<App>('/v1/apps', body);
  }
  updateApp(id: string, body: Record<string, unknown>): Promise<App> {
    return this.api.patch<App>(`/v1/apps/${encodeURIComponent(id)}`, body);
  }
  checkSubdomain(name: string, platform: 'ios' | 'android', appId?: string): Promise<SubdomainAvailability> {
    const q = new URLSearchParams({ name, platform, ...(appId ? { app_id: appId } : {}) });
    return this.api.get<SubdomainAvailability>(`/v1/link-subdomains/availability?${q.toString()}`);
  }
  listDomains(): Promise<Domain[]> {
    return this.api.list<Domain>('/v1/domains');
  }
  setupCheck(appId: string): Promise<SetupCheck> {
    return this.api.get<SetupCheck>(`/v1/cli/setup-check?app_id=${encodeURIComponent(appId)}`);
  }
}
