import type { Referral } from '@clikgate/react-native';

/** JSON object of an API body (snake_case keys). */
type Json = { [key: string]: unknown };

/** Which leaderboard period to read: `current`, `previous` or a period key such as `2026-W43`. */
export type LeaderboardPeriodSelector = 'current' | 'previous' | (string & {});

/** The current user's referral link and code in a program. */
export interface ReferralLink {
  referrerId: string;
  programId: string;
  code: string;
  url: string;
  shortUrl: string;
}

/** The current user's referrer stats in a program. */
export interface ReferralStats {
  referrerId: string;
  programId: string;
  code: string;
  url: string;
  shortUrl: string;
  /** `active` or `blocked`. */
  status: string;
  clicks: number;
  installs: number;
  signups: number;
  inProgress: number;
  qualified: number;
  disqualified: number;
  rejected: number;
}

/** A leaderboard period. */
export interface LeaderboardPeriod {
  /** e.g. `2026-W43`, `2026-10`, `all_time`. */
  key: string;
  /** `open`, `closed_provisional` or `final`. */
  status: string;
  startsAt: Date | null;
  endsAt: Date | null;
}

/** One row of a leaderboard. */
export interface LeaderboardEntry {
  rank: number;
  referrerId: string;
  /** Masked name, display name or code, per the board's name mode. */
  display: string;
  score: number;
  /** Pending (not yet qualified) referrals; null when the board hides them. */
  pending: number | null;
  /** True for the current user's own row. */
  isMe: boolean;
}

/**
 * A page of a leaderboard (`top` or `aroundMe`). `aroundMe` results only carry
 * `leaderboardId`, `period` and `entries`, so `name`, `metric` and `segment` are null there.
 */
export interface LeaderboardPage {
  leaderboardId: string;
  name: string | null;
  /** e.g. `qualified`, `signups`. */
  metric: string | null;
  segment: string | null;
  period: LeaderboardPeriod;
  entries: LeaderboardEntry[];
}

/** The current user's standing on a leaderboard. */
export interface MyRank {
  leaderboardId: string;
  period: LeaderboardPeriod;
  referrerId: string;
  /** Null when the user has no score yet, opted out, or is below the board's minimum score. */
  rank: number | null;
  score: number;
  pending: number | null;
  /** Score needed to reach the next rank; null at rank 1 or when unranked. */
  gapToNext: number | null;
  bestRank: number | null;
  periodEndsAt: Date | null;
  optedOut: boolean;
}

/** The code behind a redemption. */
export interface RedeemedCode {
  /** The normalised code (uppercase, no spaces or dashes). */
  code: string;
  /** `link` or `referral`. */
  kind: string;
  linkId: string | null;
  campaignId: string | null;
  referrerId: string | null;
  programId: string | null;
}

/** Result of `engage.codes.redeem`. */
export interface Redemption {
  /** The recorded offline touch (`oft_...`). */
  offlineTouchId: string;
  code: RedeemedCode;
  /** The referral created for a referral code (`source: "offline_code"`), else null. */
  referral: Referral | null;
}

// ------------------------------------------------------------------ decoding (API bodies)

export function asJson(v: unknown): Json {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
    ? (v as Json)
    : {};
}

function str(v: unknown, fallback: string): string {
  return typeof v === 'string' ? v : fallback;
}

function optStr(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function int(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? Math.trunc(v) : 0;
}

function optInt(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? Math.trunc(v) : null;
}

function date(v: unknown): Date | null {
  if (typeof v !== 'string') return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}

function isObject(v: unknown): boolean {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

export function referralFromJson(input: unknown): Referral {
  const m = asJson(input);
  return {
    referralId: str(m.referral_id, ''),
    programId: str(m.program_id, ''),
    status: str(m.status, 'installed'),
    source: optStr(m.source),
    referrerId: str(m.referrer_id, ''),
    referrerDisplayName: optStr(m.referrer_display_name),
    createdAt: date(m.created_at),
  };
}

export function referralLinkFromJson(input: unknown): ReferralLink {
  const m = asJson(input);
  const url = str(m.url, '');
  return {
    referrerId: str(m.referrer_id, ''),
    programId: str(m.program_id, ''),
    code: str(m.code, ''),
    url,
    shortUrl: str(m.short_url, url),
  };
}

export function referralStatsFromJson(input: unknown): ReferralStats {
  const m = asJson(input);
  const s = asJson(m.stats);
  const url = str(m.url, '');
  return {
    referrerId: str(m.referrer_id, ''),
    programId: str(m.program_id, ''),
    code: str(m.code, ''),
    url,
    shortUrl: str(m.short_url, url),
    status: str(m.status, 'active'),
    clicks: int(s.clicks),
    installs: int(s.installs),
    signups: int(s.signups),
    inProgress: int(s.in_progress),
    qualified: int(s.qualified),
    disqualified: int(s.disqualified),
    rejected: int(s.rejected),
  };
}

function periodFromJson(input: unknown): LeaderboardPeriod {
  const m = asJson(input);
  return {
    key: str(m.key, ''),
    status: str(m.status, 'open'),
    startsAt: date(m.starts_at),
    endsAt: date(m.ends_at),
  };
}

function entryFromJson(input: unknown): LeaderboardEntry {
  const m = asJson(input);
  return {
    rank: int(m.rank),
    referrerId: str(m.referrer_id, ''),
    display: str(m.display, ''),
    score: int(m.score),
    pending: optInt(m.pending),
    isMe: m.is_me === true,
  };
}

export function leaderboardPageFromJson(input: unknown): LeaderboardPage {
  const m = asJson(input);
  return {
    leaderboardId: str(m.leaderboard_id, ''),
    name: optStr(m.name),
    metric: optStr(m.metric),
    segment: optStr(m.segment),
    period: periodFromJson(m.period),
    entries: Array.isArray(m.entries)
      ? m.entries.filter(isObject).map(entryFromJson)
      : [],
  };
}

export function myRankFromJson(input: unknown): MyRank {
  const m = asJson(input);
  return {
    leaderboardId: str(m.leaderboard_id, ''),
    period: periodFromJson(m.period),
    referrerId: str(m.referrer_id, ''),
    rank: optInt(m.rank),
    score: int(m.score),
    pending: optInt(m.pending),
    gapToNext: optInt(m.gap_to_next),
    bestRank: optInt(m.best_rank),
    periodEndsAt: date(m.period_ends_at),
    optedOut: m.opted_out === true,
  };
}

export function redemptionFromJson(input: unknown): Redemption {
  const m = asJson(input);
  const c = asJson(m.code);
  return {
    offlineTouchId: str(m.offline_touch_id, ''),
    code: {
      code: str(c.code, ''),
      kind: str(c.kind, 'link'),
      linkId: optStr(c.link_id),
      campaignId: optStr(c.campaign_id),
      referrerId: optStr(c.referrer_id),
      programId: optStr(c.program_id),
    },
    referral: isObject(m.referral) ? referralFromJson(m.referral) : null,
  };
}
