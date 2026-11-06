import { invoke } from './native';
import {
  referralResultFromMap,
  referredByFromMap,
  type Referral,
  type ReferredBy,
} from './models';

/**
 * Referee-side referral calls tied to this installation (`Clikgate.referrals`). All logic runs
 * in the native SDKs.
 *
 * Errors are thrown as `ClikgateError` with the backend code (`code_not_found`,
 * `already_referred`, `window_expired`, `self_referral`, `not_identified`,
 * `identity_required`, `program_paused`, ...), or `feature_disabled` when referrals are
 * switched off for the organisation (no network call).
 *
 * Referrer-side features (the user's link and stats, sharing, leaderboards, promo codes) are not
 * in the core package: call the Clikgate API from your backend (recommended), or use
 * `@clikgate/react-native-engage` in apps without a backend.
 */
export const referrals = {
  /** Applies a friend's referral code for this installation. */
  async applyCode(options: {
    programId: string;
    code: string;
  }): Promise<Referral> {
    const m = await invoke<unknown>('referralsApplyCode', {
      programId: options.programId,
      code: options.code,
    });
    return referralResultFromMap(m);
  },

  /** Whether this installation was referred (most recent referral). */
  async referredBy(): Promise<ReferredBy> {
    const m = await invoke<unknown>('referralsReferredBy', {});
    return referredByFromMap(m);
  },
};

export type ClikgateReferrals = typeof referrals;
