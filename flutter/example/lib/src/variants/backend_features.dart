import 'dart:async';
import 'dart:convert';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

import 'features.dart';

/// `Clikgate.identifyUser`, injectable for tests.
typedef IdentifyFn = Future<void> Function(String? customerUserId, {String? identityToken});

Future<void> _identify(String? id, {String? identityToken}) =>
    Clikgate.identifyUser(customerId: id, identityToken: identityToken);

/// Recommended variant: the app talks to its own backend (`samples/backend`), which calls the
/// Clikgate control-plane API (referrers, leaderboards, server-side events) with its API key.
/// The app holds no Clikgate secret and doesn't use the Engage features (`package:clikgate_flutter/engage.dart`).
class BackendFeatures extends ReferralFeatures {
  BackendFeatures({required String baseUrl, http.Client? httpClient, IdentifyFn? identify})
      : _base = baseUrl.replaceFirst(RegExp(r'/+$'), ''),
        _http = httpClient ?? http.Client(),
        _identifyFn = identify ?? _identify;

  final String _base;
  final http.Client _http;
  final IdentifyFn _identifyFn;
  String? _session;
  SignedInUser? _user;

  @override
  String get variant => 'backend';

  @override
  String get description => 'Backend variant: invite, stats and leaderboards from $_base';

  @override
  SignedInUser? get user => _user;

  Future<Map<String, dynamic>> _call(String method, String path, {Map<String, Object?>? body, Map<String, String>? query}) async {
    final uri = Uri.parse('$_base$path').replace(queryParameters: query);
    final request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json'
      ..headers.addAll({if (_session != null) 'Authorization': 'Bearer $_session'});
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _http.send(request).timeout(const Duration(seconds: 15)));
    } on Exception catch (e) {
      throw AppError('backend_unreachable', 'Sample backend at $_base: $e');
    }
    Object? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      json = null;
    }
    if (response.statusCode >= 400) {
      final error = json is Map ? json['error'] : null;
      if (error is Map) throw AppError('${error['code']}', '${error['message'] ?? ''}');
      throw AppError('http_${response.statusCode}', 'Sample backend answered ${response.statusCode}');
    }
    return json is Map<String, dynamic> ? json : <String, dynamic>{};
  }

  void _requireUser() {
    if (_session == null) throw const AppError('unauthenticated', 'Sign in first.');
  }

  @override
  Future<SignedInUser> signIn(String userId, {String? displayName}) async {
    final r = await _call('POST', '/auth/demo-login', body: {'user_id': userId, 'display_name': displayName});
    _session = r['session_token'] as String?;
    final id = r['customer_user_id'] as String;
    // The identity token is signed by the backend with the app's identity secret: Clikgate then
    // trusts this user id (programs with require_identity_token need it).
    await _identifyFn(id, identityToken: r['identity_token'] as String?);
    _user = SignedInUser(id, displayName: r['display_name'] as String?, verified: true);
    notifyListeners();
    return _user!;
  }

  @override
  Future<InviteLink> inviteLink() async {
    _requireUser();
    final r = await _call('GET', '/me/referral-link');
    return InviteLink(code: '${r['code']}', url: '${r['url']}', shortUrl: r['short_url'] as String?);
  }

  @override
  Future<InviteStats> stats() async {
    _requireUser();
    final r = await _call('GET', '/me/referral-stats');
    int n(String k) => (r[k] as num?)?.toInt() ?? 0;
    return InviteStats(
      code: '${r['code']}',
      clicks: n('clicks'),
      installs: n('installs'),
      signups: n('signups'),
      inProgress: n('in_progress'),
      qualified: n('qualified'),
      disqualified: n('disqualified'),
      rejected: n('rejected'),
    );
  }

  @override
  // With a backend, share the link's share_urls from your server so each app gets its own version.
  Future<void> share(InviteLink link, String message) =>
      SharePlus.instance.share(ShareParams(text: '$message ${link.url}'));

  /// No WhatsApp deep link here (that helper is in Engage); the share sheet offers WhatsApp.
  @override
  Future<bool> shareWhatsApp(InviteLink link, String message) async {
    await share(link, message);
    return false;
  }

  @override
  Future<BoardPage> leaderboard(String leaderboardId, {int limit = 20}) async {
    _requireUser();
    final r = await _call('GET', '/leaderboards/${Uri.encodeComponent(leaderboardId)}', query: {'limit': '$limit'});
    return BoardPage(
      name: r['name'] as String?,
      metric: r['metric'] as String?,
      period: _period(r['period']),
      entries: _entries(r['entries']),
    );
  }

  @override
  Future<BoardRank> myRank(String leaderboardId) async {
    _requireUser();
    final r = await _call('GET', '/leaderboards/${Uri.encodeComponent(leaderboardId)}/me');
    return BoardRank(
      rank: (r['rank'] as num?)?.toInt(),
      score: (r['score'] as num?)?.toInt() ?? 0,
      pending: (r['pending'] as num?)?.toInt(),
      gapToNext: (r['gap_to_next'] as num?)?.toInt(),
      bestRank: (r['best_rank'] as num?)?.toInt(),
      optedOut: r['opted_out'] as bool? ?? false,
      periodEndsAt: DateTime.tryParse('${r['period_ends_at']}'),
    );
  }

  @override
  Future<List<BoardEntry>> aroundMe(String leaderboardId, {int radius = 2}) async {
    _requireUser();
    final r = await _call('GET', '/leaderboards/${Uri.encodeComponent(leaderboardId)}/around-me', query: {'radius': '$radius'});
    return _entries(r['entries']);
  }

  /// A confirmed purchase goes to the backend, which reports it to Clikgate as a server-side
  /// event (`POST /v1/apps/{app_id}/events`): it can't be forged by a modified app.
  @override
  Future<String> recordPurchase({required String orderId, required int amountMinor, required String currency}) async {
    _requireUser();
    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      _ => null,
    };
    final r = await _call('POST', '/orders', body: {
      'order_id': orderId,
      'amount_minor': amountMinor,
      'currency': currency,
      'platform': ?platform,
    });
    final accepted = (r['clikgate'] as Map?)?['accepted'];
    return 'Order ${r['order_id']} sent as a server-side event (accepted: $accepted)';
  }

  static BoardPeriod _period(Object? p) {
    final m = p is Map ? p : const {};
    return BoardPeriod(
      key: '${m['key'] ?? ''}',
      status: '${m['status'] ?? 'open'}',
      endsAt: m['ends_at'] == null ? null : DateTime.tryParse('${m['ends_at']}'),
    );
  }

  static List<BoardEntry> _entries(Object? list) => [
        for (final e in (list is List ? list : const []))
          if (e is Map)
            BoardEntry(
              rank: (e['rank'] as num?)?.toInt() ?? 0,
              referrerId: '${e['referrer_id']}',
              display: '${e['display']}',
              score: (e['score'] as num?)?.toInt() ?? 0,
              pending: (e['pending'] as num?)?.toInt(),
              isMe: e['is_me'] as bool? ?? false,
            ),
      ];
}
