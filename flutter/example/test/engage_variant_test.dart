import 'dart:convert';

import 'package:clikgate_engage/clikgate_engage.dart';
import 'package:clikgate_flutter_example/src/leaderboard.dart';
import 'package:clikgate_flutter_example/src/promo_code.dart';
import 'package:clikgate_flutter_example/src/screens.dart';
import 'package:clikgate_flutter_example/src/variants/engage_features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final period = {'key': '2026-W43', 'status': 'open', 'starts_at': '2026-10-19T23:00:00Z', 'ends_at': '2026-10-26T23:00:00Z'};
  Map<String, Object?> page(int myScore) => {
        'leaderboard_id': 'lb_1',
        'name': 'Weekly top inviters',
        'metric': 'qualified',
        'segment': null,
        'period': period,
        'entries': [
          {'rank': 1, 'referrer_id': 'rfr_a', 'display': 'Ada O.', 'score': 12, 'pending': 3, 'is_me': false},
          {'rank': 2, 'referrer_id': 'rfr_b', 'display': 'B**42X', 'score': myScore, 'pending': 0, 'is_me': true},
        ],
      };

  testWidgets('sign-in identifies without a token (no backend)', (tester) async {
    final identify = IdentifyLog();
    final features = EngageFeatures(programId: 'rpg_1', identify: identify.call);
    await tester.pumpWidget(wrap(features, const SignInScreen()));
    await tester.enterText(find.byKey(const Key('sign-in-user')), 'user_42');
    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await settle(tester);
    expect(identify.calls, [('user_42', null)]);
    expect(features.user?.verified, isFalse);
  });

  testWidgets('invite screen creates the link and loads stats via Engage', (tester) async {
    final calls = <http.Request>[];
    final engage = ClikgateEngage(
      core: FakeCore(),
      httpClient: MockClient((req) async {
        calls.add(req);
        if (req.url.path == '/v1/sdk/referrals/link') {
          return json({'referrer_id': 'rfr_b', 'program_id': 'rpg_1', 'code': 'B42X', 'url': 'https://inv.test/r/B42X', 'short_url': 'https://inv.test/x'});
        }
        return json({
          'referrer_id': 'rfr_b', 'program_id': 'rpg_1', 'code': 'B42X', 'url': 'https://inv.test/r/B42X', 'short_url': 'https://inv.test/x',
          'status': 'active', 'stats': {'clicks': 4, 'installs': 2, 'qualified': 1},
        });
      }),
    );
    final features = EngageFeatures(programId: 'rpg_1', engage: engage, identify: IdentifyLog().call);
    await features.signIn('user_42', displayName: 'Bea');
    await tester.pumpWidget(wrap(features, const InviteScreen()));
    await tester.tap(find.byKey(const Key('get-invite-link')));
    await settle(tester);
    expect(find.text('Code: B42X\nhttps://inv.test/r/B42X'), findsOneWidget);
    expect(jsonDecode(calls.first.body), {'program_id': 'rpg_1', 'display_name': 'Bea'});
    await tester.tap(find.byKey(const Key('load-stats')));
    await settle(tester);
    expect(find.text('4'), findsOneWidget);
    expect(calls.last.url.path, '/v1/sdk/referrals/me');
  });

  testWidgets('leaderboard shows live ranks, my rank and toggles opt-out', (tester) async {
    var score = 9;
    var optedOut = false;
    final calls = <http.Request>[];
    final engage = ClikgateEngage(
      core: FakeCore(),
      retryDelay: Duration.zero,
      httpClient: MockClient((req) async {
        calls.add(req);
        switch ('${req.method} ${req.url.path}') {
          case 'GET /v1/sdk/leaderboards/lb_1':
            return json(page(score));
          case 'GET /v1/sdk/leaderboards/lb_1/around-me':
            return json({...page(score), 'name': null, 'metric': null});
          case 'GET /v1/sdk/leaderboards/lb_1/me':
            return json({
              'leaderboard_id': 'lb_1', 'period': period, 'referrer_id': 'rfr_b', 'rank': 2, 'score': score,
              'pending': 0, 'gap_to_next': 12 - score, 'best_rank': 2, 'period_ends_at': '2026-10-26T23:00:00Z', 'opted_out': optedOut,
            });
          case 'POST /v1/sdk/leaderboards/opt-out':
            optedOut = (jsonDecode(req.body) as Map)['opt_out'] as bool;
            return json({'program_id': 'rpg_1', 'opt_out': optedOut});
        }
        return json({'error': {'code': 'not_found', 'message': 'x'}}, 404);
      }),
    );
    final features = EngageFeatures(programId: 'rpg_1', engage: engage);
    await tester.pumpWidget(wrap(features, const LeaderboardScreen(leaderboardId: 'lb_1', refreshInterval: Duration(seconds: 1))));
    await settle(tester);
    expect(find.text('Weekly top inviters'), findsOneWidget);
    expect(find.text('Ada O.'), findsOneWidget);
    expect(find.text('B**42X (you)'), findsOneWidget);
    expect(find.byKey(const Key('my-rank-card')), findsOneWidget);
    expect(find.text('You are #2'), findsOneWidget);
    expect(find.textContaining('3 more to move up'), findsOneWidget);

    // Live refresh (clears Engage's 60 s cache) picks up the new score.
    score = 11;
    await tester.pump(const Duration(seconds: 1));
    await settle(tester);
    expect(find.textContaining('1 more to move up'), findsOneWidget);
    expect(calls.where((c) => c.url.path == '/v1/sdk/leaderboards/lb_1').length, greaterThanOrEqualTo(2));

    await tester.tap(find.byKey(const Key('leaderboard-opt-out')));
    await settle(tester);
    expect(jsonDecode(calls.firstWhere((c) => c.url.path.endsWith('/opt-out')).body), {'program_id': 'rpg_1', 'opt_out': true});
    expect(find.textContaining('Hidden from the board'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // dispose: stops the timer
  });

  testWidgets('leaderboard shows a notice when the feature is off', (tester) async {
    final engage = ClikgateEngage(core: FakeCore(enabled: false), httpClient: MockClient((_) async => fail('no network')));
    await tester.pumpWidget(wrap(EngageFeatures(programId: 'rpg_1', engage: engage), const LeaderboardScreen(leaderboardId: 'lb_1')));
    await settle(tester);
    expect(find.byKey(const Key('leaderboard-disabled')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('promo code redemption shows success and friendly errors', (tester) async {
    final engage = ClikgateEngage(
      core: FakeCore(),
      httpClient: MockClient((req) async {
        final code = (jsonDecode(req.body) as Map)['code'] as String;
        if (code == 'OLD') return json({'error': {'code': 'code_expired', 'message': 'expired'}}, 409);
        return json({
          'offline_touch_id': 'oft_1',
          'code': {'code': code, 'kind': 'link', 'link_id': 'lnk_1', 'campaign_id': null, 'referrer_id': null, 'program_id': null},
          'referral': null,
        });
      }),
    );
    await tester.pumpWidget(MaterialApp(home: PromoCodeScreen(engage: engage)));
    await tester.enterText(find.byKey(const Key('promo-code-field')), 'LAGOS50');
    await tester.tap(find.byKey(const Key('promo-code-redeem')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Code LAGOS50 applied'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('promo-code-field')), 'OLD');
    await tester.tap(find.byKey(const Key('promo-code-redeem')));
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('That code has expired.'), findsOneWidget);
  });
}
