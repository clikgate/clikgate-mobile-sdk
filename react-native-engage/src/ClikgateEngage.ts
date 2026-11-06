import { Clikgate, ClikgateError } from '@clikgate/react-native';
import { Linking, Share } from 'react-native';

import {
  CACHE_TTL_MS,
  EngageClient,
  encodeRfc3986,
  type EngageCore,
  type FetchLike,
} from './client';
import { EngageErrorCodes } from './errors';
import NativeClikgateEngage from './NativeClikgateEngage';
import type { ShareApp } from './shareApp';
import {
  asJson,
  leaderboardPageFromJson,
  myRankFromJson,
  redemptionFromJson,
  referralLinkFromJson,
  referralStatsFromJson,
  type LeaderboardPage,
  type LeaderboardPeriodSelector,
  type MyRank,
  type Redemption,
  type ReferralLink,
  type ReferralStats,
} from './models';
import { VERSION } from './version';

/** Largest `limit` of `leaderboards.top` (API maximum; larger values are clamped). */
export const MAX_LEADERBOARD_LIMIT = 100;
/** Largest `radius` of `leaderboards.aroundMe` (API maximum; larger values are clamped). */
export const MAX_AROUND_ME_RADIUS = 25;

/** The share sheet (React Native `Share`). */
export interface EngageShareSheet {
  share(content: { message: string; title?: string }): Promise<unknown>;
}

/** URL opener (React Native `Linking`). */
export interface EngageLinking {
  openURL(url: string): Promise<unknown>;
}

/**
 * Hands a `share.link()` call to the native Engage add-on (the `ClikgateEngage` TurboModule);
 * resolves `true` when the app itself opened.
 */
export type EngageLinkSharer = (
  args: Record<string, unknown>
) => Promise<boolean>;

/** Options of `new ClikgateEngage()`; the defaults are right for apps (overrides are for tests). */
export interface ClikgateEngageOptions {
  /** The core SDK (default: `Clikgate` from `@clikgate/react-native`). */
  core?: EngageCore;
  /** Default: the global `fetch`. */
  fetch?: FetchLike;
  /** Clock for the 60 s read cache (default `Date.now`). */
  now?: () => number;
  /** Default: React Native `Share`. */
  shareSheet?: EngageShareSheet;
  /** Default: React Native `Linking`. */
  linking?: EngageLinking;
  /** Default: the native `ClikgateEngage` module. */
  shareLink?: EngageLinkSharer;
  /** Per-attempt timeout (default 10 000 ms, the contract's timeout). */
  timeoutMs?: number;
  /** Wait before the single network-error retry (default 500 ms). */
  retryDelayMs?: number;
}

function requireString(value: unknown, param: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new ClikgateError('invalid_argument', `${param} is required`, {
      param,
    });
  }
  return value;
}

function requireId(value: unknown, param: string): string {
  const s = requireString(value, param);
  if (s.includes('/')) {
    throw new ClikgateError('invalid_argument', `${param} is invalid`, {
      param,
    });
  }
  return encodeRfc3986(s);
}

function clamp(value: unknown, fallback: number, min: number, max: number) {
  const n =
    typeof value === 'number' && Number.isFinite(value)
      ? Math.trunc(value)
      : fallback;
  return Math.min(max, Math.max(min, n));
}

function period(p: LeaderboardPeriodSelector | undefined | null): string {
  return typeof p === 'string' && p.trim().length > 0 ? p : 'current';
}

/**
 * Clikgate Engage add-on: referral links and stats, share helpers, leaderboards and
 * promo-code redemption for apps **without their own backend**. Apps with a backend should call
 * the Clikgate control-plane API from their server instead.
 *
 * Calls the same `/v1/sdk/...` endpoints with the core SDK's request context; keeps no
 * attribution state. Every call checks `Clikgate.isFeatureEnabled` first (`feature_disabled`
 * without network), user calls need `Clikgate.identifyUser` (`not_identified`), reads are cached in
 * memory for 60 s, network errors are retried once. Failures are `ClikgateError`s.
 *
 * ```ts
 * const engage = new ClikgateEngage();
 * const link = await engage.referrals.createLink({ programId: 'rpg_...', displayName: 'Ada' });
 * await engage.share.whatsApp({ text: `Join me on MyApp: ${link.url}` });
 * ```
 */
export class ClikgateEngage {
  /** Version of this package. */
  static readonly version: string = VERSION;

  private readonly client: EngageClient;
  private readonly shareSheet: EngageShareSheet;
  private readonly linking: EngageLinking;
  private readonly shareLink: EngageLinkSharer;

  constructor(options: ClikgateEngageOptions = {}) {
    const fetchFn =
      options.fetch ??
      ((url, init) => (globalThis.fetch as unknown as FetchLike)(url, init));
    this.client = new EngageClient(
      options.core ?? Clikgate,
      fetchFn,
      options.now ?? Date.now,
      options.timeoutMs ?? 10_000,
      options.retryDelayMs ?? 500
    );
    this.shareSheet = options.shareSheet ?? Share;
    this.linking = options.linking ?? Linking;
    this.shareLink = options.shareLink ?? nativeShareLink;
  }

  private async callShareLink(args: Record<string, unknown>): Promise<boolean> {
    requireString(args.url, 'url');
    try {
      return await this.shareLink(args);
    } catch (e) {
      if (e instanceof ClikgateError) throw e;
      const err = e as { code?: unknown; message?: unknown };
      throw new ClikgateError(
        typeof err?.code === 'string'
          ? err.code
          : EngageErrorCodes.shareUnavailable,
        typeof err?.message === 'string'
          ? err.message
          : 'The share menu could not be shown'
      );
    }
  }

  /** How long read results are cached in memory (ms). */
  static readonly cacheTtlMs = CACHE_TTL_MS;

  /** Drops every cached read (e.g. after the user logs out). */
  clearCache(): void {
    this.client.clearCache();
  }

  /** Referrer side (feature `referrals`); both need `Clikgate.identifyUser`. */
  readonly referrals = {
    /**
     * Gets or creates the current user's referral link and code. Errors: `not_identified`,
     * `identity_required`, `client_link_creation_disabled`, `referral_link_limit`, ...
     */
    createLink: async (options: {
      programId: string;
      displayName?: string | null;
    }): Promise<ReferralLink> => {
      const programId = requireString(options?.programId, 'programId');
      const body: Record<string, unknown> = { program_id: programId };
      if (options.displayName != null) body.display_name = options.displayName;
      return this.client.call({
        feature: 'referrals',
        method: 'POST',
        path: '/v1/sdk/referrals/link',
        body,
        identified: true,
        cacheable: false,
        parse: referralLinkFromJson,
      });
    },

    /** The user's code, link and counts. `referrer_not_found` before `createLink`. Cached 60 s. */
    myStats: async (options: { programId: string }): Promise<ReferralStats> =>
      this.client.call({
        feature: 'referrals',
        method: 'GET',
        path: '/v1/sdk/referrals/me',
        query: { program_id: requireString(options?.programId, 'programId') },
        identified: true,
        cacheable: true,
        parse: referralStatsFromJson,
      }),
  };

  /**
   * Share helpers (no feature switch).
   *
   * `link` / `referralLink` share a Clikgate link through the native Engage add-on: each app
   * Clikgate knows gets its own version of the link (a short ending that tells Clikgate where it
   * was shared), other apps the plain link, and the share is recorded (the app and the link, no
   * personal data; a share count, never a click). `system` / `whatsApp` share plain text and
   * record nothing.
   */
  readonly share = {
    /**
     * Shares a Clikgate link (`url`, e.g. `https://inv.myapp.com/summer`) with an optional
     * `message` in front of it. Without `app`, opens the share menu (the app the person picks is
     * recorded when the phone reports it); with `app`, opens that app where the phone can, else
     * the share menu. `shareUrls`: the link's `share_urls` from your backend (the Clikgate API's
     * link object), used as they are. Resolves `true` when `app` itself opened.
     */
    link: (
      url: string,
      options: {
        message?: string;
        app?: ShareApp;
        shareUrls?: Partial<Record<ShareApp, string>>;
      } = {}
    ): Promise<boolean> =>
      this.callShareLink({
        url,
        message: options.message ?? null,
        app: options.app ?? null,
        ...(options.shareUrls ? { shareUrls: { ...options.shareUrls } } : {}),
      }),

    /**
     * `link` for the user's referral link (`referrals.createLink`): each app's version keeps the
     * referral code, so the referrer is still credited.
     */
    referralLink: (
      link: ReferralLink,
      options: { message?: string; app?: ShareApp } = {}
    ): Promise<boolean> =>
      this.callShareLink({
        url: link?.url,
        code: link?.code,
        shortUrl: link?.shortUrl ?? null,
        message: options.message ?? null,
        app: options.app ?? null,
      }),

    /** Opens the system share sheet with `text`. */
    system: async (options: {
      text: string;
      title?: string;
    }): Promise<void> => {
      const text = requireString(options?.text, 'text');
      try {
        await this.shareSheet.share(
          options.title != null
            ? { message: text, title: options.title }
            : { message: text }
        );
      } catch (e) {
        throw new ClikgateError(
          EngageErrorCodes.shareUnavailable,
          e instanceof Error ? e.message : 'The share sheet could not be shown'
        );
      }
    },

    /**
     * Opens WhatsApp with `text` (`whatsapp://send?text=...`); if WhatsApp isn't installed (the
     * URL can't be opened), shows the system share sheet instead. Resolves `true` when WhatsApp
     * itself was opened, `false` when the share sheet was used.
     */
    whatsApp: async (options: { text: string }): Promise<boolean> => {
      const text = requireString(options?.text, 'text');
      try {
        await this.linking.openURL(
          `whatsapp://send?text=${encodeRfc3986(text)}`
        );
        return true;
      } catch {
        await this.share.system({ text });
        return false;
      }
    },
  };

  /** Leaderboards with `visibility = sdk` (feature `leaderboards`). Build your own UI. */
  readonly leaderboards = {
    /** Top entries (default `period: 'current'`, `limit: 50`, clamped to 1..100). Cached 60 s. */
    top: async (
      leaderboardId: string,
      options: {
        period?: LeaderboardPeriodSelector;
        segment?: string | null;
        limit?: number;
      } = {}
    ): Promise<LeaderboardPage> =>
      this.client.call({
        feature: 'leaderboards',
        method: 'GET',
        path: `/v1/sdk/leaderboards/${requireId(leaderboardId, 'leaderboardId')}`,
        query: {
          period: period(options.period),
          segment: options.segment ?? null,
          limit: clamp(options.limit, 50, 1, MAX_LEADERBOARD_LIMIT),
        },
        identified: false,
        cacheable: true,
        parse: leaderboardPageFromJson,
      }),

    /** The user's rank, score, pending, gap to next and period end. Needs identify. Cached 60 s. */
    me: async (
      leaderboardId: string,
      options: {
        period?: LeaderboardPeriodSelector;
        segment?: string | null;
      } = {}
    ): Promise<MyRank> =>
      this.client.call({
        feature: 'leaderboards',
        method: 'GET',
        path: `/v1/sdk/leaderboards/${requireId(leaderboardId, 'leaderboardId')}/me`,
        query: {
          period: period(options.period),
          segment: options.segment ?? null,
        },
        identified: true,
        cacheable: true,
        parse: myRankFromJson,
      }),

    /**
     * Entries around the user (default `radius: 5`, clamped to 1..25). `name`, `metric` and
     * `segment` are null. Needs identify. Cached 60 s.
     */
    aroundMe: async (
      leaderboardId: string,
      options: {
        radius?: number;
        period?: LeaderboardPeriodSelector;
        segment?: string | null;
      } = {}
    ): Promise<LeaderboardPage> =>
      this.client.call({
        feature: 'leaderboards',
        method: 'GET',
        path: `/v1/sdk/leaderboards/${requireId(leaderboardId, 'leaderboardId')}/around-me`,
        query: {
          radius: clamp(options.radius, 5, 1, MAX_AROUND_ME_RADIUS),
          period: period(options.period),
          segment: options.segment ?? null,
        },
        identified: true,
        cacheable: true,
        parse: leaderboardPageFromJson,
      }),

    /** Hides (`optOut: true`) or shows the user on every board of a program. Needs identify. */
    setOptOut: async (options: {
      programId: string;
      optOut: boolean;
    }): Promise<void> => {
      await this.client.call({
        feature: 'leaderboards',
        method: 'POST',
        path: '/v1/sdk/leaderboards/opt-out',
        body: {
          program_id: requireString(options?.programId, 'programId'),
          opt_out: options.optOut === true,
        },
        identified: true,
        cacheable: false,
        parse: () => undefined,
      });
    },

    /**
     * Signed URL of the hosted leaderboard page highlighting the user, for a web
     * view. Short-lived: fetch it right before showing the page (never cached). Needs identify.
     * `hosted_page_unavailable` when the server doesn't return one.
     */
    hostedPageUrl: async (
      leaderboardId: string,
      options: { period?: LeaderboardPeriodSelector } = {}
    ): Promise<string> =>
      this.client.call({
        feature: 'leaderboards',
        method: 'GET',
        path: `/v1/sdk/leaderboards/${requireId(leaderboardId, 'leaderboardId')}/me`,
        query: { period: period(options.period), embed: 1 },
        identified: true,
        cacheable: false,
        parse: (body) => {
          const url = asJson(body).embed_url;
          if (typeof url !== 'string' || url.length === 0) {
            throw new ClikgateError(
              EngageErrorCodes.hostedPageUnavailable,
              'The server returned no hosted page URL (embed_url).'
            );
          }
          return url;
        },
      }),
  };

  /** Promo / offline codes typed in the app (feature `offline_codes`). */
  readonly codes = {
    /**
     * Redeems a code (3-30 characters after trimming; case, spaces and dashes are ignored by the
     * server). Errors: `code_not_found`, `code_expired`, `code_disabled`,
     * `redemption_limit_reached`, `rate_limited`, and the referral errors of `applyCode` (with
     * `offlineTouchId` set: the touch is still recorded).
     */
    redeem: async (code: string): Promise<Redemption> => {
      const trimmed = typeof code === 'string' ? code.trim() : '';
      if (trimmed.length < 3 || trimmed.length > 30) {
        throw new ClikgateError(
          'invalid_argument',
          'The code must be 3-30 characters',
          {
            param: 'code',
          }
        );
      }
      return this.client.call({
        feature: 'offline_codes',
        method: 'POST',
        path: '/v1/sdk/codes/redeem',
        body: { code: trimmed },
        identified: false,
        cacheable: false,
        parse: redemptionFromJson,
      });
    },
  };
}

async function nativeShareLink(
  args: Record<string, unknown>
): Promise<boolean> {
  if (!NativeClikgateEngage) {
    throw new ClikgateError(
      EngageErrorCodes.shareUnavailable,
      'The ClikgateEngage native module is not linked (rebuild the app after installing @clikgate/react-native-engage)'
    );
  }
  return NativeClikgateEngage.shareLink(args);
}
