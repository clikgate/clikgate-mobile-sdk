import 'package:flutter/widgets.dart';

/// What the referrer-side screens (sign-in, invite, stats, leaderboard, purchase) need, with two
/// implementations:
///
/// - [BackendFeatures] (`CLIKGATE_VARIANT=backend`, the recommended path): the app's own
///   backend (`samples/backend`) calls the Clikgate control-plane API with its API key.
/// - [EngageFeatures] (`CLIKGATE_VARIANT=engage`): no backend; the Engage features
///   (`package:clikgate_flutter/engage.dart`) call the `/v1/sdk/*` Engage endpoints.
///
/// Core SDK features (deep links, attribution, apply code, referred-by, push) are the same in
/// both variants and use `clikgate_flutter` directly.
abstract class ReferralFeatures extends ChangeNotifier {
  /// `backend` or `engage`.
  String get variant;

  /// One line for the home screen.
  String get description;

  SignedInUser? get user;

  /// Signs the user in and calls `Clikgate.identifyUser` (with an identity token when there is a
  /// backend to sign one).
  Future<SignedInUser> signIn(String userId, {String? displayName});

  /// The user's invite link (created on first use).
  Future<InviteLink> inviteLink();

  Future<InviteStats> stats();

  /// The share menu with [message] and the link.
  Future<void> share(InviteLink link, String message);

  /// WhatsApp when possible; `false` when the share sheet was used instead.
  Future<bool> shareWhatsApp(InviteLink link, String message);

  Future<BoardPage> leaderboard(String leaderboardId, {int limit = 20});

  Future<BoardRank> myRank(String leaderboardId);

  Future<List<BoardEntry>> aroundMe(String leaderboardId, {int radius = 2});

  /// Whether the "hide me from leaderboards" switch is available.
  bool get supportsLeaderboardOptOut => false;

  Future<void> setLeaderboardOptOut(bool optOut) =>
      Future.error(const AppError('unsupported', 'Not available in this variant.'));

  /// Called before an explicit refresh (live ranks): drop client-side caches.
  void clearCache() {}

  /// Records a purchase; returns a status line.
  Future<String> recordPurchase({required String orderId, required int amountMinor, required String currency});
}

/// Gives the screens below it the app's [ReferralFeatures]; rebuilds them on sign-in.
class FeaturesScope extends InheritedNotifier<ReferralFeatures> {
  const FeaturesScope({super.key, required ReferralFeatures features, required super.child})
      : super(notifier: features);

  static ReferralFeatures of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeaturesScope>()!.notifier!;
}

/// An error of either variant: a backend error code (`referrer_not_found`, `unauthenticated`,
/// ...) or an Engage / core `ClikgateException` code (`feature_disabled`, `not_identified`, ...).
class AppError implements Exception {
  const AppError(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class SignedInUser {
  const SignedInUser(this.userId, {this.displayName, this.verified = false});
  final String userId;
  final String? displayName;

  /// Identified with an identity token signed by a backend.
  final bool verified;
}

class InviteLink {
  const InviteLink({required this.code, required this.url, this.shortUrl});
  final String code;
  final String url;
  final String? shortUrl;
}

class InviteStats {
  const InviteStats({
    required this.code,
    this.clicks = 0,
    this.installs = 0,
    this.signups = 0,
    this.inProgress = 0,
    this.qualified = 0,
    this.disqualified = 0,
    this.rejected = 0,
  });
  final String code;
  final int clicks, installs, signups, inProgress, qualified, disqualified, rejected;

  Map<String, int> get rows => {
        'Clicks': clicks,
        'Installs': installs,
        'Signups': signups,
        'In progress': inProgress,
        'Qualified': qualified,
        'Disqualified': disqualified,
        'Rejected': rejected,
      };
}

class BoardPeriod {
  const BoardPeriod({required this.key, required this.status, this.endsAt});
  final String key;
  final String status;
  final DateTime? endsAt;
}

class BoardEntry {
  const BoardEntry({
    required this.rank,
    required this.referrerId,
    required this.display,
    required this.score,
    this.pending,
    this.isMe = false,
  });
  final int rank;
  final String referrerId;
  final String display;
  final int score;
  final int? pending;
  final bool isMe;
}

class BoardPage {
  const BoardPage({required this.period, this.name, this.metric, this.entries = const []});
  final String? name;
  final String? metric;
  final BoardPeriod period;
  final List<BoardEntry> entries;
}

class BoardRank {
  const BoardRank({
    this.rank,
    this.score = 0,
    this.pending,
    this.gapToNext,
    this.bestRank,
    this.optedOut = false,
    this.periodEndsAt,
  });

  /// Null = not ranked yet.
  final int? rank;
  final int score;
  final int? pending;
  final int? gapToNext;
  final int? bestRank;
  final bool optedOut;
  final DateTime? periodEndsAt;
}
