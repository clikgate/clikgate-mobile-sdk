/**
 * Clikgate Engage features (part of `@clikgate/react-native` since 2.1.0; was
 * `@clikgate/react-native-engage`): referral links and stats, share helpers, leaderboards and promo
 * codes for apps without their own backend. TypeScript over the core; the share menu of
 * `share.link` uses the native SDK's Engage features. Re-exported by src/index.ts. Core code never
 * imports this folder.
 */
export {
  ClikgateEngage,
  MAX_AROUND_ME_RADIUS,
  MAX_LEADERBOARD_LIMIT,
  type ClikgateEngageOptions,
  type EngageLinkSharer,
  type EngageLinking,
  type EngageShareSheet,
} from './ClikgateEngage';
export type { EngageCore, FetchLike } from './client';
export { EngageErrorCodes } from './errors';
export type {
  LeaderboardEntry,
  LeaderboardPage,
  LeaderboardPeriod,
  LeaderboardPeriodSelector,
  MyRank,
  RedeemedCode,
  Redemption,
  ReferralLink,
  ReferralStats,
} from './models';
export { SHARE_APPS, ShareApp } from './shareApp';
