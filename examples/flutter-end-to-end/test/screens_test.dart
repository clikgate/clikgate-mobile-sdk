import 'dart:async';
import 'dart:convert';

import 'package:clikgate_end_to_end/src/app.dart';
import 'package:clikgate_end_to_end/src/auth_service.dart';
import 'package:clikgate_end_to_end/src/deep_links.dart';
import 'package:clikgate_end_to_end/src/screens/product_screen.dart';
import 'package:clikgate_end_to_end/src/session_store.dart';
import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/engage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';
import 'support/fake_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeClikgatePlatform platform;
  late FakeBackend backend;
  late StreamController<ClikgateDeepLink> deepLinks;
  late List<http.Request> engageRequests;

  setUp(() {
    platform = FakeClikgatePlatform();
    backend = FakeBackend();
    deepLinks = StreamController<ClikgateDeepLink>.broadcast();
    engageRequests = [];
  });
  tearDown(() {
    platform.dispose();
    deepLinks.close();
  });

  /// Clikgate's Engage API, answered locally.
  ClikgateEngage engage() => ClikgateEngage(
        httpClient: MockClient((request) async {
          engageRequests.add(request);
          final link = {
            'referrer_id': 'rfr_1',
            'program_id': 'rpg_test',
            'code': 'ADA42',
            'url': 'https://inv.myapp.test/r/ADA42',
            'short_url': 'https://inv.myapp.test/r/ADA42',
          };
          return http.Response(jsonEncode(link), 200, headers: {'content-type': 'application/json'});
        }),
      );

  Future<void> pumpApp(WidgetTester tester, {bool signedIn = true}) async {
    SharedPreferences.setMockInitialValues(signedIn ? {'access_token': 'session-1', 'used_app_before': true} : {});
    final session = await SessionStore.open();
    final api = backend.api(session);
    await tester.pumpWidget(SampleApp(
      auth: AuthService(api, session),
      backend: api,
      engage: engage(),
      referralProgramId: 'rpg_test',
      deepLinks: deepLinks.stream,
    ));
    await settle(tester);
  }

  testWidgets('signed out: the sign-in screen; creating an account opens the home screen', (tester) async {
    await pumpApp(tester, signedIn: false);
    await tester.enterText(find.byType(TextField).first, 'ada@example.com');
    await tester.enterText(find.byType(TextField).last, 'correct horse');
    await tester.tap(find.text('Create an account'));
    await settle(tester);

    expect(find.text('ada@example.com'), findsOneWidget); // the home screen's title
    expect(backend.requests.last.path, '/auth/sign-up');
  });

  testWidgets('an app goal, and a payment goal with the provider that the backend then confirms', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Complete my profile'));
    await settle(tester);
    await tester.tap(find.text('Buy for ₦7,500'));
    await settle(tester);

    final goals = platform.callsTo('goal').map((c) => c.arguments as Map).toList();
    expect(goals[0]['key'], 'profile_completed');
    expect(goals[0]['reference'], isNull); // no customer data in goal calls
    expect(goals[1]['key'], 'order_paid');
    expect(goals[1]['provider'], 'paystack');
    expect(goals[1]['value'], isNull); // the amount comes from the backend's confirmation, never the app
    final confirm = backend.requests.last;
    expect(confirm.path, '/payments/paystack/confirm');
    expect((confirm.data as Map)['reference'], goals[1]['reference']);
  });

  testWidgets('the referral screen shows the Engage link, shares it, and applies a code', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Invite friends'));
    await settle(tester);

    expect(find.text('Your code: ADA42'), findsOneWidget);
    expect(engageRequests.single.url.path, '/v1/sdk/referrals/link');
    await tester.tap(find.text('Share'));
    await settle(tester);
    expect((platform.callsTo('shareLink').single.arguments as Map)['code'], 'ADA42');

    await tester.enterText(find.byType(TextField), 'NOPE');
    await tester.tap(find.text('Apply code'));
    await settle(tester);
    expect(find.textContaining('code_not_found'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ADA42');
    await tester.tap(find.text('Apply code'));
    await settle(tester);
    expect(find.text('Code applied. Thanks!'), findsOneWidget);
  });

  testWidgets('sign-out returns to the sign-in screen', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Sign out'));
    await settle(tester);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('a deep link opens its screen; a blocked link only shows its message', (tester) async {
    await pumpApp(tester);
    deepLinks.add(const ClikgateDeepLink(path: '/product/42', isDeferred: true));
    await settle(tester);
    expect(find.text('Product 42'), findsOneWidget);

    deepLinks.add(const ClikgateDeepLink(blockMessage: 'Not available in your country'));
    await settle(tester);
    expect(find.text('Not available in your country'), findsOneWidget);
  });

  test('pageFor maps paths to screens', () {
    expect(pageFor(const ClikgateDeepLink(path: '/product/7')), isA<ProductScreen>());
    expect(pageFor(const ClikgateDeepLink(path: '/somewhere-else')), isNull);
  });
}

/// Lets the fake HTTP and platform calls finish, then rebuilds.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
  }
}
