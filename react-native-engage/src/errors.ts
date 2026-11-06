/**
 * Error codes specific to the Engage add-on, in addition to the core `ClikgateError` codes.
 * Every failure is a `ClikgateError` from `@clikgate/react-native` (`code`, `status`, `param`,
 * `feature`, `offlineTouchId`).
 */
export const EngageErrorCodes = {
  /** `leaderboards.hostedPageUrl`: the server returned no `embed_url` (older server). */
  hostedPageUnavailable: 'hosted_page_unavailable',
  /** `share.*`: the system share sheet could not be shown. */
  shareUnavailable: 'share_unavailable',
  notIdentified: 'not_identified',
  identityRequired: 'identity_required',
  referrerNotFound: 'referrer_not_found',
  leaderboardNotFound: 'leaderboard_not_found',
  invalidSegment: 'invalid_segment',
  periodNotFound: 'period_not_found',
  codeNotFound: 'code_not_found',
  codeExpired: 'code_expired',
  codeDisabled: 'code_disabled',
  redemptionLimitReached: 'redemption_limit_reached',
  serverError: 'server_error',
  validationError: 'validation_error',
} as const;
