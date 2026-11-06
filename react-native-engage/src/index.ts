/**
 * Clikgate Engage add-on for React Native: referral links and stats, share helpers,
 * leaderboards and promo codes for apps without their own backend. TypeScript over
 * `@clikgate/react-native` (core); the share menu of `share.link` uses the native Engage add-on.
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
export { VERSION } from './version';
