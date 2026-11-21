import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/testing.dart';
import 'package:clikgate_flutter_example/src/screens.dart';
import 'package:clikgate_flutter_example/src/variants/engage_features.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// The example's screens with the SDK's own test fake (package:clikgate_flutter/testing.dart):
/// no hand-written channel mocks, no fake Engage core, no mocked HTTP client.
void main() {
  late ClikgateFake clikgate;
  setUp(() {
    clikgate = ClikgateFake.install();
    clikgate.referredBy = const Referral(
        referralId: 'ref_1', programId: 'rpg_1', status: 'holding', referrerId: 'rfr_1', referrerDisplayName: 'Ada');
  });

  testWidgets('home: referred-by banner, goal and Payment goal', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(EngageFeatures(programId: 'rpg_1'), HomeScreen(pushStatus: ValueNotifier('off'))));
    await tester.pumpAndSettle();
    expect(find.text('Invited by Ada'), findsOneWidget);

    await tester.tap(find.byKey(const Key('record-goal')));
    await tester.pumpAndSettle();
    expect(find.text('account_opened: counted'), findsOneWidget);
    expect(clikgate.goals.single.value, '2000000');

    await tester.ensureVisible(find.byKey(const Key('record-payment-goal')));
    await tester.tap(find.byKey(const Key('record-payment-goal')));
    await tester.pumpAndSettle();
    expect(clikgate.goals.last.provider, ClikgateProvider.paystack);
    expect(clikgate.goals.last.result.status, GoalStatus.waiting);
  });

  testWidgets('Engage variant: sign in, then the invite link comes from the fake', (tester) async {
    final features = EngageFeatures(programId: 'rpg_1');
    await features.signIn('user_42'); // Clikgate.identifyUser(customerId: 'user_42')
    expect(clikgate.identifyCalls.single.customerId, 'user_42');

    await tester.pumpWidget(wrap(features, const InviteScreen()));
    await tester.tap(find.byKey(const Key('get-invite-link')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Code: ${clikgate.referralCode}'), findsOneWidget);
    expect(clikgate.engageRequests.single.path, '/v1/sdk/referrals/link');
  });
}
