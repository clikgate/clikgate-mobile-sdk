import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter_example/src/screens.dart';
import 'package:clikgate_flutter_example/src/variants/backend_features.dart';
import 'package:clikgate_flutter_example/src/variants/engage_features.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'support.dart';

/// Core SDK screens, identical in both variants.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final variant in ['backend', 'engage']) {
    testWidgets('$variant: home shows the referred-by banner, attribution and the variant', (tester) async {
      mockCoreChannel();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final features = variant == 'backend'
          ? BackendFeatures(baseUrl: 'http://backend.test', httpClient: MockClient((_) async => fail('no call')))
          : EngageFeatures(programId: 'rpg_1');
      await tester.pumpWidget(wrap(features, HomeScreen(pushStatus: ValueNotifier('Push disabled'))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('referred-by-banner')), findsOneWidget);
      expect(find.text('Invited by Ada'), findsOneWidget);
      expect(find.text('Attribution: ${ClikgateAttributionStatus.attributed.name}'), findsOneWidget);
      expect(find.text('Not signed in'), findsOneWidget);
      expect(find.textContaining('${variant[0].toUpperCase()}${variant.substring(1)} variant'), findsOneWidget);
      // Promo codes only exist in the Engage variant.
      expect(find.byKey(const Key('open-promo-code')), variant == 'engage' ? findsOneWidget : findsNothing);
    });
  }

  testWidgets('no banner for an install that was not referred', (tester) async {
    mockCoreChannel(referred: false);
    await tester.pumpWidget(wrap(EngageFeatures(programId: 'rpg_1'), HomeScreen(pushStatus: ValueNotifier('off'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('referred-by-banner')), findsNothing);
  });

  testWidgets('apply-code screen applies a code and shows friendly errors', (tester) async {
    final codes = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.clikgate/sdk'), (call) async {
      if (call.method == 'referrals.applyCode') {
        final code = (call.arguments as Map)['code'] as String;
        codes.add(code);
        if (code == 'NOPE') throw PlatformException(code: 'code_not_found', message: 'unknown');
        return {'referralId': 'ref_1', 'programId': 'rpg_1', 'status': 'installed', 'referrerId': 'rfr_1', 'referrerDisplayName': 'Ada'};
      }
      return null;
    });
    await tester.pumpWidget(wrap(EngageFeatures(programId: 'rpg_1'), const ApplyCodeScreen()));
    await tester.enterText(find.byType(TextField), 'ADA42');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('Referred by Ada (installed)'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'NOPE');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('That code does not exist.'), findsOneWidget);
    expect(codes, ['ADA42', 'NOPE']);
  });
}
