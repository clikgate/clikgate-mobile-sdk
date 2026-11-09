// Runs the plugin against a real (sandbox) Clikgate backend. Skipped unless
// CLIKGATE_API_BASE_URL is defined:
//
//   flutter test integration_test \
//     --dart-define=CLIKGATE_API_BASE_URL=http://10.0.2.2:8000 \
//     --dart-define=CLIKGATE_SDK_KEY=cg_sdk_... \
//     --dart-define=CLIKGATE_PROGRAM_ID=rpg_... \
//     [--dart-define=CLIKGATE_IDENTITY_TOKEN=<token for user CLIKGATE_USER_ID>]
import 'package:clikgate_engage/clikgate_engage.dart';
import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const apiBaseUrl = String.fromEnvironment('CLIKGATE_API_BASE_URL');
const sdkKey = String.fromEnvironment('CLIKGATE_SDK_KEY');
const programId = String.fromEnvironment('CLIKGATE_PROGRAM_ID');
const userId = String.fromEnvironment('CLIKGATE_USER_ID', defaultValue: 'it_user_1');
const identityToken = String.fromEnvironment('CLIKGATE_IDENTITY_TOKEN');
const linkDomain = String.fromEnvironment('CLIKGATE_LINK_DOMAIN', defaultValue: 'inv.example.com');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = apiBaseUrl.isEmpty ? 'CLIKGATE_API_BASE_URL not defined' : null;

  group('sandbox backend', () {
    setUpAll(() async {
      if (skip != null) return;
      await Clikgate.configure(
        sdkKey: sdkKey,
        apiBaseUrl: apiBaseUrl,
        linkDomains: [linkDomain],
        environment: ClikgateEnvironment.sandbox,
        logLevel: ClikgateLogLevel.debug,
        deferredDeepLinkTimeout: const Duration(seconds: 15),
      );
    });

    testWidgets('install is recorded and attribution resolves', (tester) async {
      final a = await Clikgate.getAttribution();
      expect(a.status, isNot(ClikgateAttributionStatus.pending));
      expect(a.installId, startsWith('ins_'));
      expect(await Clikgate.nativeSdkVersion(), isNotEmpty);
    }, skip: skip != null);

    testWidgets('goals, identifyUser and push token are accepted', (tester) async {
      final signup = Clikgate.goal('signup', reference: 'it-signup-1');
      final purchase = Clikgate.goal('purchase', value: '1500', currency: 'NGN', reference: 'it-1');
      expect(await Clikgate.getInstallationId(), isNotNull);
      await Clikgate.identifyUser(
          label: 'Integration test', customerId: userId, identityToken: identityToken.isEmpty ? null : identityToken);
      await Clikgate.setPushToken('integration-test-token', provider: PushProvider.fcm);
      expect((await Clikgate.goal('bad name')).reason, ClikgateException.invalidArgument);
      // Don't wait for the goal results here: they complete once the batch is sent.
      signup.ignore();
      purchase.ignore();
      // The SDK flushes its queue every 15 s; stay alive long enough for the batch to reach the
      // backend (flutter test uninstalls the app afterwards, taking the queue with it)
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 17)));
    }, skip: skip != null);

    testWidgets('referral calls round-trip', (tester) async {
      final info = await Clikgate.referrals.referredBy();
      expect(info.referred, isA<bool>());
      if (programId.isEmpty) return;
      try {
        // Referrer side: the Engage add-on (pure Dart, same installation via the core's context).
        final engage = ClikgateEngage();
        final link = await engage.referrals.createLink(programId: programId, displayName: 'IT');
        expect(link.code, isNotEmpty);
        final stats = await engage.referrals.myStats(programId: programId);
        expect(stats.code, link.code);
      } on ClikgateException catch (e) {
        // Programs that require an identity token reject calls without one.
        expect(e.code, anyOf('identity_required', 'identity_invalid', 'not_identified'));
      }
      await expectLater(
        Clikgate.referrals.applyCode(programId: programId, code: 'NO-SUCH-CODE-XYZ'),
        throwsA(isA<ClikgateException>()),
      );
    }, skip: skip != null);
  });
}
