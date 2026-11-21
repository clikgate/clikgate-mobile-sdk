import 'dart:async';

import 'package:clikgate_end_to_end/src/app.dart';
import 'package:clikgate_end_to_end/src/auth_service.dart';
import 'package:clikgate_end_to_end/src/deep_links.dart';
import 'package:clikgate_end_to_end/src/screens/product_screen.dart';
import 'package:clikgate_end_to_end/src/session_store.dart';
import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/engage.dart';
import 'package:clikgate_flutter/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The SDK's own test fake answers every Clikgate call (and the Engage API) without a phone or the network.
  late ClikgateFake clikgate;
  late FakeBackend backend;

  setUp(() {
    clikgate = ClikgateFake.install()
      ..referralCode = 'ADA42'
      ..linkDomain = 'inv.myapp.test';
    backend = FakeBackend();
  });

  /// [deepLinks] replaces `Clikgate.onDeepLink` when a test needs a link the fake can't deliver.
  Future<void> pumpApp(WidgetTester tester, {bool signedIn = true, Stream<ClikgateDeepLink>? deepLinks}) async {
    SharedPreferences.setMockInitialValues(signedIn ? {'access_token': 'session-1', 'used_app_before': true} : {});
    final session = await SessionStore.open();
    final api = backend.api(session);
    await tester.pumpWidget(SampleApp(
      auth: AuthService(api, session),
      backend: api,
      engage: ClikgateEngage(),
      referralProgramId: 'rpg_test',
      deepLinks: deepLinks,
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

    final goals = clikgate.goals;
    expect(goals[0].key, 'profile_completed');
    expect(goals[0].reference, isNull); // no customer data in goal calls
    expect(goals[1].key, 'order_paid');
    expect(goals[1].provider, ClikgateProvider.paystack);
    expect(goals[1].value, isNull); // the amount comes from the backend's confirmation, never the app
    final confirm = backend.requests.last;
    expect(confirm.path, '/payments/paystack/confirm');
    expect((confirm.data as Map)['reference'], goals[1].reference);
  });

  testWidgets('the referral screen shows the Engage link, shares it, and applies a code', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Invite friends'));
    await settle(tester);

    expect(find.text('Your code: ADA42'), findsOneWidget);
    expect(clikgate.engageRequests.single.path, '/v1/sdk/referrals/link');
    await tester.tap(find.text('Share'));
    await settle(tester);
    expect(clikgate.shares.single.code, 'ADA42');

    clikgate.applyCodeError = 'code_not_found';
    await tester.enterText(find.byType(TextField), 'NOPE');
    await tester.tap(find.text('Apply code'));
    await settle(tester);
    expect(find.textContaining('code_not_found'), findsOneWidget);

    clikgate.applyCodeError = null;
    await tester.enterText(find.byType(TextField), 'ADA42');
    await tester.tap(find.text('Apply code'));
    await settle(tester);
    expect(find.text('Code applied. Thanks!'), findsOneWidget);
    expect(clikgate.appliedCodes.map((c) => c.code), ['NOPE', 'ADA42']);
  });

  testWidgets('sign-out returns to the sign-in screen', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Sign out'));
    await settle(tester);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('a deep link from Clikgate.onDeepLink opens its screen', (tester) async {
    await pumpApp(tester);
    clikgate.pushDeepLink('https://inv.myapp.test/product/42', isDeferred: true);
    await settle(tester);
    expect(find.text('Product 42'), findsOneWidget);
  });

  testWidgets('a blocked link only shows its message', (tester) async {
    final deepLinks = StreamController<ClikgateDeepLink>.broadcast();
    addTearDown(deepLinks.close);
    await pumpApp(tester, deepLinks: deepLinks.stream);
    deepLinks.add(const ClikgateDeepLink(blockMessage: 'Not available in your country'));
    await settle(tester);
    expect(find.text('Not available in your country'), findsOneWidget);
    expect(find.text('Product 42'), findsNothing);
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
