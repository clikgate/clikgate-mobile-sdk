import 'package:clikgate_flutter/engage.dart';
import 'package:clikgate_flutter/clikgate_flutter.dart';

import 'backend_features.dart' show IdentifyFn;
import 'features.dart';

Future<void> _identify(String? id, {String? identityToken}) =>
    Clikgate.identifyUser(customerId: id, identityToken: identityToken);

/// No-backend variant: the Engage features (`package:clikgate_flutter/engage.dart`) calls the `/v1/sdk/*`
/// Engage endpoints with the core SDK's installation context.
///
/// Without a backend there is nobody to sign an identity token, so the referral program must
/// not use `require_identity_token` (docs/engage.md).
class EngageFeatures extends ReferralFeatures {
  EngageFeatures({required this.programId, ClikgateEngage? engage, IdentifyFn? identify})
      : engage = engage ?? ClikgateEngage(),
        _identifyFn = identify ?? _identify;

  final String programId;

  /// Also used directly by the promo-code screen (Engage only).
  final ClikgateEngage engage;
  final IdentifyFn _identifyFn;
  SignedInUser? _user;

  @override
  String get variant => 'engage';

  @override
  String get description => 'Engage variant: invite, stats, leaderboards and promo codes via the Engage features (no backend)';

  @override
  SignedInUser? get user => _user;

  Future<T> _wrap<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ClikgateException catch (e) {
      throw AppError(e.code, e.message);
    }
  }

  @override
  Future<SignedInUser> signIn(String userId, {String? displayName}) async {
    await _identifyFn(userId);
    _user = SignedInUser(userId, displayName: displayName);
    notifyListeners();
    return _user!;
  }

  @override
  Future<InviteLink> inviteLink() => _wrap(() async {
        final l = await engage.referrals.createLink(programId: programId, displayName: _user?.displayName);
        return InviteLink(code: l.code, url: l.url, shortUrl: l.shortUrl);
      });

  @override
  Future<InviteStats> stats() => _wrap(() async {
        final s = await engage.referrals.myStats(programId: programId);
        return InviteStats(
          code: s.code,
          clicks: s.clicks,
          installs: s.installs,
          signups: s.signups,
          inProgress: s.inProgress,
          qualified: s.qualified,
          disqualified: s.disqualified,
          rejected: s.rejected,
        );
      });

  @override
  // share.referralLink: each app gets its own version of the link, so Clikgate knows where it was shared.
  Future<void> share(InviteLink link, String message) =>
      _wrap(() => engage.share.referralLink(_referral(link), message: message));

  @override
  Future<bool> shareWhatsApp(InviteLink link, String message) =>
      _wrap(() => engage.share.referralLink(_referral(link), message: message, app: ShareApp.whatsapp));

  static ReferralLink _referral(InviteLink l) =>
      ReferralLink(referrerId: '', programId: '', code: l.code, url: l.url, shortUrl: l.shortUrl ?? '');

  @override
  Future<BoardPage> leaderboard(String leaderboardId, {int limit = 20}) => _wrap(() async {
        final p = await engage.leaderboards.top(leaderboardId, limit: limit);
        return BoardPage(name: p.name, metric: p.metric, period: _period(p.period), entries: _entries(p.entries));
      });

  @override
  Future<BoardRank> myRank(String leaderboardId) => _wrap(() async {
        final m = await engage.leaderboards.me(leaderboardId);
        return BoardRank(
          rank: m.rank,
          score: m.score,
          pending: m.pending,
          gapToNext: m.gapToNext,
          bestRank: m.bestRank,
          optedOut: m.optedOut,
          periodEndsAt: m.periodEndsAt,
        );
      });

  @override
  Future<List<BoardEntry>> aroundMe(String leaderboardId, {int radius = 2}) =>
      _wrap(() async => _entries((await engage.leaderboards.aroundMe(leaderboardId, radius: radius)).entries));

  @override
  bool get supportsLeaderboardOptOut => true;

  @override
  Future<void> setLeaderboardOptOut(bool optOut) =>
      _wrap(() => engage.leaderboards.setOptOut(programId: programId, optOut: optOut));

  /// Engage keeps reads for 60 s; live ranks need a fresh read.
  @override
  void clearCache() => engage.clearCache();

  /// Without a backend, the purchase is a goal sent from the app (value in normal units, the order as reference).
  @override
  Future<String> recordPurchase({required String orderId, required int amountMinor, required String currency}) =>
      _wrap(() async {
        final value = '${amountMinor ~/ 100}.${(amountMinor % 100).toString().padLeft(2, '0')}';
        final r = await Clikgate.goal('purchase', value: value, currency: currency, reference: orderId);
        return 'purchase goal: ${r.status.name}';
      });

  static BoardPeriod _period(LeaderboardPeriodInfo p) => BoardPeriod(key: p.key, status: p.status, endsAt: p.endsAt);

  static List<BoardEntry> _entries(List<LeaderboardEntry> list) => [
        for (final e in list)
          BoardEntry(rank: e.rank, referrerId: e.referrerId, display: e.display, score: e.score, pending: e.pending, isMe: e.isMe),
      ];
}
