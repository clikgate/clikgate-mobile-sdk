import 'dart:convert';

import 'package:clikgate_flutter_example/src/leaderboard.dart';
import 'package:clikgate_flutter_example/src/screens.dart';
import 'package:clikgate_flutter_example/src/variants/backend_features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

/// A fake of samples/backend (its HTTP API, not Clikgate's): the app never talks to Clikgate's
/// control plane itself.
class FakeSampleBackend {
  var score = 5;
  var hasReferrer = true;
  final requests = <http.Request>[];

  late final client = MockClient((req) async {
    requests.add(req);
    final route = '${req.method} ${req.url.path}';
    if (route == 'POST /auth/demo-login') {
      final body = jsonDecode(req.body) as Map;
      return json({
        'customer_user_id': body['user_id'],
        'display_name': body['display_name'],
        'session_token': 'sess-1',
        'identity_token': 'sig.1760000000',
      });
    }
    if (req.headers['Authorization'] != 'Bearer sess-1') {
      return json({'error': {'code': 'unauthenticated', 'message': 'Sign in first'}}, 401);
    }
    final period = {'key': '2026-W43', 'status': 'open', 'starts_at': '2026-10-19T23:00:00Z', 'ends_at': '2026-10-26T23:00:00Z'};
    switch (route) {
      case 'GET /me/referral-link':
        return json({'program_id': 'rpg_1', 'referrer_id': 'rfr_ada', 'code': 'ADA42X', 'url': 'https://inv.test/r/ADA42X', 'short_url': 'https://inv.test/aB'});
      case 'GET /me/referral-stats':
        return json({'referrer_id': 'rfr_ada', 'code': 'ADA42X', 'clicks': 7, 'installs': 3, 'signups': 2, 'in_progress': 1, 'qualified': 1, 'disqualified': 0, 'rejected': 0});
      case 'GET /leaderboards/lb_1':
        final ranked = [('rfr_bo', 'Bo', 12), ('rfr_ada', 'Ada', score)]..sort((a, b) => b.$3 - a.$3);
        return json({
          'leaderboard_id': 'lb_1', 'name': 'Weekly top inviters', 'metric': 'qualified', 'period': period, 'segment': null,
          'entries': [
            for (final (i, e) in ranked.indexed)
              {'rank': i + 1, 'referrer_id': e.$1, 'display': e.$2, 'score': e.$3, 'pending': 0, 'is_me': e.$1 == 'rfr_ada'},
          ],
        });
      case 'GET /leaderboards/lb_1/me':
        if (!hasReferrer) return json({'error': {'code': 'referrer_not_found', 'message': 'x'}}, 404);
        final rank = score > 12 ? 1 : 2;
        return json({
          'leaderboard_id': 'lb_1', 'referrer_id': 'rfr_ada', 'period': period, 'rank': rank, 'score': score, 'pending': 0,
          'gap_to_next': rank == 1 ? null : 12 - score, 'best_rank': rank, 'eligible': true, 'opted_out': false,
          'period_ends_at': '2026-10-26T23:00:00Z',
        });
      case 'GET /leaderboards/lb_1/around-me':
        return json({'leaderboard_id': 'lb_1', 'period': period, 'entries': []});
      case 'POST /orders':
        final body = jsonDecode(req.body) as Map;
        return json({'order_id': body['order_id'], 'event_id': 'order-${body['order_id']}', 'clikgate': {'accepted': 1, 'duplicates': 0, 'rejected': []}}, 201);
    }
    return json({'error': {'code': 'not_found', 'message': route}}, 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSampleBackend backend;
  late IdentifyLog identify;
  late BackendFeatures features;

  setUp(() {
    backend = FakeSampleBackend();
    identify = IdentifyLog();
    features = BackendFeatures(baseUrl: 'http://backend.test/', httpClient: backend.client, identify: identify.call);
  });

  testWidgets('sign-in uses the demo login and identifies with the backend-signed token', (tester) async {
    await tester.pumpWidget(wrap(features, const SignInScreen()));
    await tester.enterText(find.byKey(const Key('sign-in-user')), 'ada');
    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await settle(tester);
    expect(identify.calls, [('ada', 'sig.1760000000')]);
    expect(features.user?.userId, 'ada');
    expect(features.user?.verified, isTrue);
    expect(backend.requests.single.url.toString(), 'http://backend.test/auth/demo-login');
  });

  testWidgets('invite screen shows the link and stats from the backend', (tester) async {
    await features.signIn('ada', displayName: 'Ada');
    await tester.pumpWidget(wrap(features, const InviteScreen()));
    await tester.tap(find.byKey(const Key('get-invite-link')));
    await settle(tester);
    expect(find.text('Code: ADA42X\nhttps://inv.test/r/ADA42X'), findsOneWidget);
    await tester.tap(find.byKey(const Key('load-stats')));
    await settle(tester);
    expect(find.byKey(const Key('stats-table')), findsOneWidget);
    expect(find.text('Clicks'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(backend.requests.map((r) => r.url.path), containsAllInOrder(['/me/referral-link', '/me/referral-stats']));
    expect(backend.requests.skip(1).every((r) => r.headers['Authorization'] == 'Bearer sess-1'), isTrue);
  });

  testWidgets('invite screen before sign-in reports the backend error', (tester) async {
    await tester.pumpWidget(wrap(features, const InviteScreen()));
    expect(find.text('Sign in to get your invite link'), findsOneWidget);
    await tester.tap(find.byKey(const Key('get-invite-link')));
    await settle(tester);
    expect(find.textContaining('unauthenticated'), findsOneWidget);
    expect(backend.requests, isEmpty);
  });

  testWidgets('weekly leaderboard shows live ranks and my rank', (tester) async {
    await features.signIn('ada');
    await tester.pumpWidget(wrap(features, const LeaderboardScreen(leaderboardId: 'lb_1', refreshInterval: Duration(seconds: 1))));
    await settle(tester);
    expect(find.text('Weekly top inviters'), findsOneWidget);
    expect(find.text('Bo'), findsOneWidget);
    expect(find.text('Ada (you)'), findsOneWidget);
    expect(find.text('You are #2'), findsOneWidget);
    expect(find.textContaining('7 more to move up'), findsOneWidget);
    expect(find.byKey(const Key('leaderboard-opt-out')), findsNothing); // Engage-only switch

    // Live: Ada overtakes Bo between two polls.
    backend.score = 15;
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.text('You are #1'), findsOneWidget);
    expect(find.byKey(const Key('entry-1-rfr_ada')), findsOneWidget);
    expect(backend.requests.where((r) => r.url.path == '/leaderboards/lb_1').length, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('leaderboard explains a missing rank', (tester) async {
    backend.hasReferrer = false;
    await features.signIn('ada');
    await tester.pumpWidget(wrap(features, const LeaderboardScreen(leaderboardId: 'lb_1')));
    await settle(tester);
    expect(find.text('Invite a friend to get on the board.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('purchase is sent to the backend as an order (server-side event)', (tester) async {
    mockCoreChannel(referred: false);
    await features.signIn('ada');
    await tester.pumpWidget(wrap(features, HomeScreen(pushStatus: ValueNotifier('off'))));
    await tester.pumpAndSettle();
    expect(find.text('Signed in as ada (verified)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('record-purchase')));
    await settle(tester);
    final order = backend.requests.lastWhere((r) => r.url.path == '/orders');
    final body = jsonDecode(order.body) as Map;
    expect(body['amount_minor'], 1500000);
    expect(body['currency'], 'NGN');
    expect(find.textContaining('sent as a server-side event (accepted: 1)'), findsOneWidget);
  });
}
