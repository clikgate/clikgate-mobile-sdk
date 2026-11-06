import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:meta/meta.dart';

// Models of the Engage add-on, parsed from the API's snake_case JSON
//. Unknown fields are ignored.

/// The current user's referral link and code in a program
/// (`referrals.createLink`).
@immutable
class ReferralLink {
  const ReferralLink({
    required this.referrerId,
    required this.programId,
    required this.code,
    required this.url,
    required this.shortUrl,
  });

  factory ReferralLink.fromJson(Map<String, dynamic> j) => ReferralLink(
        referrerId: _s(j['referrer_id']),
        programId: _s(j['program_id']),
        code: _s(j['code']),
        url: _s(j['url']),
        shortUrl: j['short_url'] as String? ?? _s(j['url']),
      );

  final String referrerId;
  final String programId;
  final String code;
  final String url;
  final String shortUrl;
}

/// The current user's referrer stats in a program (`referrals.myStats`).
@immutable
class ReferralStats {
  const ReferralStats({
    required this.referrerId,
    required this.programId,
    required this.code,
    required this.url,
    required this.shortUrl,
    required this.status,
    this.clicks = 0,
    this.installs = 0,
    this.signups = 0,
    this.inProgress = 0,
    this.qualified = 0,
    this.disqualified = 0,
    this.rejected = 0,
  });

  factory ReferralStats.fromJson(Map<String, dynamic> j) {
    final s = _map(j['stats']);
    int n(String k) => (s[k] as num?)?.toInt() ?? 0;
    return ReferralStats(
      referrerId: _s(j['referrer_id']),
      programId: _s(j['program_id']),
      code: _s(j['code']),
      url: _s(j['url']),
      shortUrl: j['short_url'] as String? ?? _s(j['url']),
      status: j['status'] as String? ?? 'active',
      clicks: n('clicks'),
      installs: n('installs'),
      signups: n('signups'),
      inProgress: n('in_progress'),
      qualified: n('qualified'),
      disqualified: n('disqualified'),
      rejected: n('rejected'),
    );
  }

  final String referrerId;
  final String programId;
  final String code;
  final String url;
  final String shortUrl;

  /// `active` or `blocked`.
  final String status;
  final int clicks;
  final int installs;
  final int signups;
  final int inProgress;
  final int qualified;
  final int disqualified;
  final int rejected;
}

/// Which leaderboard period to read: [current] (default), [previous] or a
/// period by key ([LeaderboardPeriod.key], e.g. `2026-W43`).
@immutable
class LeaderboardPeriod {
  const LeaderboardPeriod.key(this.value);

  static const current = LeaderboardPeriod.key('current');
  static const previous = LeaderboardPeriod.key('previous');

  /// The `period` query value.
  final String value;

  @override
  bool operator ==(Object other) =>
      other is LeaderboardPeriod && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'LeaderboardPeriod($value)';
}

/// A leaderboard period as returned by the API.
@immutable
class LeaderboardPeriodInfo {
  const LeaderboardPeriodInfo(
      {required this.key, required this.status, this.startsAt, this.endsAt});

  factory LeaderboardPeriodInfo.fromJson(Map<String, dynamic> j) =>
      LeaderboardPeriodInfo(
        key: _s(j['key']),
        status: j['status'] as String? ?? 'open',
        startsAt: _date(j['starts_at']),
        endsAt: _date(j['ends_at']),
      );

  /// e.g. `2026-W43`.
  final String key;

  /// `open`, `closed_provisional` or `final`.
  final String status;
  final DateTime? startsAt;
  final DateTime? endsAt;
}

/// One ranked referrer. [display] follows the board's name mode (masked,
/// display name or code).
@immutable
class LeaderboardEntry {
  const LeaderboardEntry({
    required this.rank,
    required this.referrerId,
    required this.display,
    required this.score,
    this.pending,
    this.isMe = false,
  });

  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
        rank: (j['rank'] as num?)?.toInt() ?? 0,
        referrerId: _s(j['referrer_id']),
        display: _s(j['display']),
        score: (j['score'] as num?)?.toInt() ?? 0,
        pending: (j['pending'] as num?)?.toInt(),
        isMe: j['is_me'] as bool? ?? false,
      );

  final int rank;
  final String referrerId;
  final String display;
  final int score;

  /// Not-yet-qualified count; null when the board hides it.
  final int? pending;

  /// True for the current user's own entry.
  final bool isMe;
}

/// A page of leaderboard entries (`top` or `aroundMe`). [name], [metric] and
/// [segment] are null for `aroundMe`.
@immutable
class LeaderboardPage {
  const LeaderboardPage({
    required this.leaderboardId,
    required this.period,
    this.name,
    this.metric,
    this.segment,
    this.entries = const [],
  });

  factory LeaderboardPage.fromJson(Map<String, dynamic> j) => LeaderboardPage(
        leaderboardId: _s(j['leaderboard_id']),
        name: j['name'] as String?,
        metric: j['metric'] as String?,
        segment: j['segment'] as String?,
        period: LeaderboardPeriodInfo.fromJson(_map(j['period'])),
        entries: [
          for (final e in (j['entries'] as List? ?? const []))
            if (e is Map) LeaderboardEntry.fromJson(_map(e)),
        ],
      );

  final String leaderboardId;
  final String? name;

  /// `qualified`, `installs`, `signups`, `step` or `points`.
  final String? metric;
  final String? segment;
  final LeaderboardPeriodInfo period;
  final List<LeaderboardEntry> entries;

  /// The current user's entry on this page, if listed.
  LeaderboardEntry? get myEntry {
    for (final e in entries) {
      if (e.isMe) return e;
    }
    return null;
  }
}

/// The current user's standing on a leaderboard (`leaderboards.me`).
@immutable
class MyRank {
  const MyRank({
    required this.leaderboardId,
    required this.period,
    required this.referrerId,
    this.rank,
    this.score = 0,
    this.pending,
    this.gapToNext,
    this.bestRank,
    this.periodEndsAt,
    this.optedOut = false,
  });

  factory MyRank.fromJson(Map<String, dynamic> j) => MyRank(
        leaderboardId: _s(j['leaderboard_id']),
        period: LeaderboardPeriodInfo.fromJson(_map(j['period'])),
        referrerId: _s(j['referrer_id']),
        rank: (j['rank'] as num?)?.toInt(),
        score: (j['score'] as num?)?.toInt() ?? 0,
        pending: (j['pending'] as num?)?.toInt(),
        gapToNext: (j['gap_to_next'] as num?)?.toInt(),
        bestRank: (j['best_rank'] as num?)?.toInt(),
        periodEndsAt: _date(j['period_ends_at']),
        optedOut: j['opted_out'] as bool? ?? false,
      );

  final String leaderboardId;
  final LeaderboardPeriodInfo period;
  final String referrerId;

  /// Null when the user has no score yet, opted out, or is below the board's
  /// minimum score.
  final int? rank;
  final int score;
  final int? pending;

  /// Points needed to move up one rank.
  final int? gapToNext;
  final int? bestRank;
  final DateTime? periodEndsAt;
  final bool optedOut;
}

/// The code a [Redemption] matched.
@immutable
class RedeemedCode {
  const RedeemedCode({
    required this.code,
    required this.kind,
    this.linkId,
    this.campaignId,
    this.referrerId,
    this.programId,
  });

  factory RedeemedCode.fromJson(Map<String, dynamic> j) => RedeemedCode(
        code: _s(j['code']),
        kind: j['kind'] as String? ?? 'link',
        linkId: j['link_id'] as String?,
        campaignId: j['campaign_id'] as String?,
        referrerId: j['referrer_id'] as String?,
        programId: j['program_id'] as String?,
      );

  /// The normalised code.
  final String code;

  /// `link` (promo / campaign code) or `referral` (a referrer's code).
  final String kind;
  final String? linkId;
  final String? campaignId;
  final String? referrerId;
  final String? programId;

  bool get isReferral => kind == 'referral';
}

/// Result of `codes.redeem`.
@immutable
class Redemption {
  const Redemption(
      {required this.offlineTouchId, required this.code, this.referral});

  factory Redemption.fromJson(Map<String, dynamic> j) => Redemption(
        offlineTouchId: _s(j['offline_touch_id']),
        code: RedeemedCode.fromJson(_map(j['code'])),
        referral: j['referral'] is Map ? referralFromJson(_map(j['referral'])) : null,
      );

  /// The recorded offline touch (`oft_...`).
  final String offlineTouchId;
  final RedeemedCode code;

  /// For a referral code: the new referral (`source == 'offline_code'`).
  final Referral? referral;
}

/// The core plugin's [Referral] from the API's snake_case referral object.
Referral referralFromJson(Map<String, dynamic> j) => Referral(
      referralId: _s(j['referral_id']),
      programId: _s(j['program_id']),
      status: j['status'] as String? ?? 'installed',
      source: j['source'] as String?,
      referrerId: _s(j['referrer_id']),
      referrerDisplayName: j['referrer_display_name'] as String?,
      createdAt: _date(j['created_at']),
    );

String _s(Object? v) => v is String ? v : (v?.toString() ?? '');

Map<String, dynamic> _map(Object? v) =>
    v is Map ? v.map((k, value) => MapEntry(k.toString(), value)) : <String, dynamic>{};

DateTime? _date(Object? v) => v is String ? DateTime.tryParse(v) : null;
