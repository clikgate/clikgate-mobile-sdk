import 'channel.dart';
import 'models.dart';

/// Referee-side referral calls tied to this installation
/// (`Clikgate.referrals`). All logic runs in the native SDKs.
///
/// Referrer-side features (the user's own link, stats, sharing,
/// leaderboards, promo codes) are not in the core plugin: call the Clikgate
/// API from your backend (recommended), or use the optional
/// `clikgate_engage` package in apps without a backend.
///
/// Errors are thrown as `ClikgateException` with the backend code
/// (`code_not_found`, `already_referred`, `window_expired`, `self_referral`,
/// `program_paused`, ...), or `feature_disabled` when referrals are switched
/// off for the app.
class ClikgateReferrals {
  const ClikgateReferrals();

  /// Applies a friend's referral code for this installation.
  Future<Referral> applyCode(
      {required String programId, required String code}) async {
    final m = await ClikgateChannels.invokeMap('referrals.applyCode', {
      'programId': programId,
      'code': code,
    });
    return Referral.fromMap(m);
  }

  /// Whether this installation was referred (most recent referral).
  Future<ReferredBy> referredBy() async {
    final m = await ClikgateChannels.invokeMap('referrals.referredBy');
    return ReferredBy.fromMap(m);
  }
}
