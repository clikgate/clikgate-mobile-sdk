import 'dart:io';

import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter/engage.dart';
import 'package:clikgate_flutter/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// The test fake itself (package:clikgate_flutter/testing.dart).
void main() {
  group('core', () {
    late ClikgateFake fake;
    setUp(() => fake = ClikgateFake.install());

    test('configure is recorded; installation ID and header look like the real ones', () async {
      await Clikgate.configure(sdkKey: 'cg_sdk_test_abc', linkDomains: ['inv.myapp.com']);
      expect(fake.configured, isTrue);
      expect(fake.configureArguments!['sdkKey'], 'cg_sdk_test_abc');

      final id = await Clikgate.getInstallationId();
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(fake.appId, matches(RegExp(r'^app_[0-7][0-9A-HJKMNP-TV-Z]{25}$')));
      final h = (await Clikgate.getInstallationHeader())!;
      expect(h.name, 'Clikgate-Installation');
      expect(h.value, '${fake.appId}:$id');
    });

    test('tracking off (or no installation ID) gives null ID and header', () async {
      await Clikgate.setTrackingEnabled(false);
      expect(fake.trackingEnabled, isFalse);
      expect(await Clikgate.getInstallationId(), isNull);
      expect(await Clikgate.getInstallationHeader(), isNull);
      await Clikgate.setTrackingEnabled(true);
      fake.installationId = null;
      expect(await Clikgate.getInstallationHeader(), isNull);
    });

    test('identifyUser calls are recorded and the identity is kept like the native SDK', () async {
      await Clikgate.identifyUser(customerId: 'user_42', identityToken: 'cgid_v2.token');
      await Clikgate.identifyUser(label: 'Ada (VIP)');
      expect(fake.customerId, 'user_42');
      await Clikgate.identifyUser(customerId: null);

      expect(fake.identifyCalls, hasLength(3));
      expect(fake.identifyCalls[0].customerId, 'user_42');
      expect(fake.identifyCalls[0].identityToken, 'cgid_v2.token');
      expect(fake.identifyCalls[1].customerIdPassed, isFalse);
      expect(fake.identifyCalls[1].label, 'Ada (VIP)');
      expect(fake.identifyCalls[2].isSignOut, isTrue);
      expect(fake.customerId, isNull);
      expect(fake.identityToken, isNull);
    });

    test('goal answers counted, Payment goals waiting, both configurable', () async {
      final counted = await Clikgate.goal('profile_completed');
      expect(counted.status, GoalStatus.counted);
      expect(counted.goalKind, GoalKind.standard);

      final paid = await Clikgate.goal('purchase',
          value: 1500, reference: 'T123', provider: ClikgateProvider.paystack);
      expect(paid.status, GoalStatus.waiting);
      expect(paid.reason, 'waiting_for_confirmation');
      expect(paid.goalKind, GoalKind.payment);
      expect(paid.valueIgnored, isTrue);

      fake.goalStatus = GoalStatus.received;
      expect((await Clikgate.goal('new_name')).reason, 'not_counted_yet');
      fake.onGoal = (g) => g.key == 'blocked' ? const GoalResult(status: GoalStatus.refused, reason: 'unknown_goal') : null;
      expect((await Clikgate.goal('blocked')).status, GoalStatus.refused);

      expect(fake.goals.map((g) => g.key), ['profile_completed', 'purchase', 'new_name', 'blocked']);
      expect(fake.goals[1].isPayment, isTrue);
      expect(fake.goals[1].provider, ClikgateProvider.paystack);
      expect(fake.goals[1].value, '1500');
      expect(fake.goals[1].reference, 'T123');
      expect(fake.goals[3].result.status, GoalStatus.refused);
    });

    test('isFeatureEnabled reads features (SDK defaults, unknown keys off)', () async {
      expect(await Clikgate.isFeatureEnabled(ClikgateFeatures.referrals), isTrue);
      expect(await Clikgate.isFeatureEnabled(ClikgateFeatures.uninstallTracking), isFalse);
      fake.features[ClikgateFeatures.referrals] = false;
      expect(await Clikgate.isFeatureEnabled(ClikgateFeatures.referrals), isFalse);
    });

    test('applyCode succeeds, or throws the configured ClikgateException', () async {
      final r = await Clikgate.referrals.applyCode(programId: 'rpg_1', code: 'ADA42');
      expect(r.programId, 'rpg_1');
      expect(r.referrerDisplayName, 'Ada');

      fake.applyCodeError = 'code_not_found';
      await expectLater(Clikgate.referrals.applyCode(programId: 'rpg_1', code: 'NOPE'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', 'code_not_found').having((e) => e.status, 'status', 404)));
      fake.applyCodeError = ClikgateException.existingUser;
      await expectLater(Clikgate.referrals.applyCode(programId: 'rpg_1', code: 'X'), throwsA(isA<ExistingUserException>()));
      expect(fake.appliedCodes.map((c) => c.code), ['ADA42', 'NOPE', 'X']);
    });

    test('attribution and referredBy are configurable', () async {
      expect((await Clikgate.getAttribution()).status, ClikgateAttributionStatus.organic);
      expect((await Clikgate.referrals.referredBy()).referred, isFalse);
      fake.attribution = const ClikgateAttribution(
          status: ClikgateAttributionStatus.attributed,
          clickId: 'clk_1',
          link: ClikgateLink(id: 'lnk_1', kind: 'referral'));
      fake.referredBy = const Referral(
          referralId: 'ref_1', programId: 'rpg_1', status: 'holding', referrerId: 'rfr_1', referrerDisplayName: 'Ada');
      final a = await Clikgate.getAttribution();
      expect(a.isAttributed, isTrue);
      expect(a.link!.isReferral, isTrue);
      expect(await Clikgate.attributionMetadata(), {'cg_click_id': 'clk_1', 'cg_link_id': 'lnk_1'});
      expect((await Clikgate.referrals.referredBy()).referral!.referrerDisplayName, 'Ada');
    });

    test('pushDeepLink reaches onDeepLink, also when pushed before anyone listens', () async {
      fake.pushDeepLink('https://yourapp.dev.ciz.to/summer', isDeferred: true, data: {'promo': 'SUMMER'});
      final links = <ClikgateDeepLink>[];
      final sub = Clikgate.onDeepLink.listen(links.add);
      fake.pushDeepLink('https://yourapp.dev.ciz.to/products/42');
      await pumpEventQueue();
      expect(links.map((l) => l.path), ['/summer', '/products/42']);
      expect(links.first.isDeferred, isTrue);
      expect(links.first.data, {'promo': 'SUMMER'});
      expect(links.last.matchType, 'app_link');

      expect(await Clikgate.handleUrl('https://yourapp.dev.ciz.to/qr'), isTrue);
      expect(await Clikgate.handleUrl('https://example.com/qr'), isFalse);
      await pumpEventQueue();
      expect(links.last.path, '/qr');

      final handoffs = <ClikgateBrowserHandoff>[];
      final sub2 = Clikgate.onBrowserHandoff.listen(handoffs.add);
      fake.pushBrowserHandoff('https://ciz.to/other');
      await pumpEventQueue();
      expect(handoffs.single.host, 'ciz.to');
      await sub.cancel();
      await sub2.cancel();
    });

    test('records every channel call', () async {
      await Clikgate.setPushToken('tok', provider: PushProvider.fcm);
      await Clikgate.setConsent(attribution: ConsentState.granted);
      expect(fake.pushToken, 'tok');
      expect((await Clikgate.getConsent()).attribution, ConsentState.granted);
      expect(fake.callsTo('setPushToken').single.arguments, {'token': 'tok', 'provider': 'fcm'});
      expect(fake.calls.map((c) => c.method), ['setPushToken', 'setConsent', 'getConsent']);
    });
  });

  test('uninstall restores the real channels (calls fail as without a device)', () async {
    final fake = ClikgateFake.install();
    expect(await Clikgate.isFeatureEnabled(ClikgateFeatures.referrals), isTrue);
    fake.uninstall();
    await expectLater(Clikgate.isFeatureEnabled(ClikgateFeatures.referrals),
        throwsA(isA<ClikgateException>().having((e) => e.code, 'code', ClikgateException.unsupportedPlatform)));
  });

  group('Engage', () {
    test('user calls need identifyUser, like on a device', () async {
      ClikgateFake.install();
      await expectLater(ClikgateEngage().referrals.createLink(programId: 'rpg_1'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', ClikgateEngageErrors.notIdentified)));
    });

    test('createLink returns a stable link; the request carries the installation context', () async {
      final fake = ClikgateFake.install();
      await Clikgate.configure(sdkKey: 'cg_sdk_test_abc');
      await Clikgate.identifyUser(customerId: 'user_42', identityToken: 'cgid_v2.token');
      final engage = ClikgateEngage();
      final link = await engage.referrals.createLink(programId: 'rpg_1', displayName: 'Ada');
      expect(link.code, 'ADA-7Q2ZPX');
      expect(link.url, 'https://yourapp.dev.ciz.to/r/ADA-7Q2ZPX');
      expect(link.programId, 'rpg_1');

      final r = fake.engageRequests.single;
      expect(r.method, 'POST');
      expect(r.path, '/v1/sdk/referrals/link');
      expect(r.body, {'program_id': 'rpg_1', 'display_name': 'Ada'});
      expect(r.headers['Clikgate-SDK-Key'], 'cg_sdk_test_abc');
      expect(r.headers['Clikgate-Installation-Id'], fake.installationId);
      expect(r.headers['Clikgate-Identity-Token'], 'cgid_v2.token');

      expect((await engage.referrals.myStats(programId: 'rpg_1')).code, 'ADA-7Q2ZPX');
    });

    test('install(customerId:) starts signed in; errors and switched-off features', () async {
      final fake = ClikgateFake.install(customerId: 'user_42');
      final engage = ClikgateEngage();
      fake.createLinkError = 'identity_required';
      await expectLater(engage.referrals.createLink(programId: 'rpg_1'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', 'identity_required')));
      fake.features[ClikgateFeatures.offlineCodes] = false;
      await expectLater(engage.codes.redeem('SUMMER'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', ClikgateException.featureDisabled)));
      expect(fake.engageRequests, hasLength(1)); // no request for a switched-off feature
    });

    test('codes, leaderboards and custom responses', () async {
      final fake = ClikgateFake.install(customerId: 'user_42');
      final engage = ClikgateEngage();
      expect((await engage.codes.redeem('sum-mer 25')).code.code, 'SUMMER25');
      fake.redeemError = 'code_expired';
      await expectLater(engage.codes.redeem('OLDCODE'),
          throwsA(isA<ClikgateException>().having((e) => e.code, 'code', 'code_expired')));

      final top = await engage.leaderboards.top('lb_1');
      expect(top.entries, hasLength(3));
      expect(top.myEntry!.rank, 2);
      expect((await engage.leaderboards.me('lb_1')).rank, 2);

      fake.onEngageRequest = (r) => r.url.path.endsWith('/around-me')
          ? http.Response('{"leaderboard_id":"lb_1","period":{"key":"current"},"entries":[]}', 200)
          : null;
      expect((await engage.leaderboards.aroundMe('lb_1')).entries, isEmpty);
    });

    test('share calls are recorded; a missing app falls back to the share menu', () async {
      final fake = ClikgateFake.install();
      final engage = ClikgateEngage();
      expect(await engage.share.whatsApp(text: 'Join me'), isTrue);
      fake.shareAppInstalled = false;
      expect(await engage.share.whatsApp(text: 'Join me'), isFalse);
      const link = ReferralLink(
          referrerId: 'rfr_1', programId: 'rpg_1', code: 'ADA-7Q2ZPX', url: 'https://x.test/r/ADA', shortUrl: 'https://x.test/r/ADA');
      expect(await engage.share.referralLink(link, message: 'Hi'), isFalse);
      await engage.share.system(text: 'Plain');

      expect(fake.shares.map((s) => s.method), ['openUrl', 'openUrl', 'shareText', 'shareLink', 'shareText']);
      expect(fake.shares.first.url, startsWith('whatsapp://send?text=Join%20me'));
      expect(fake.shares[3].code, 'ADA-7Q2ZPX');
      expect(fake.shares[3].message, 'Hi');
      expect(fake.shares.last.text, 'Plain');
    });
  });

  test('testing.dart stays out of the plugin: no other library imports it or flutter_test', () {
    final offending = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('lib/testing.dart'))
        .where((f) => RegExp(r"""import\s+['"](package:flutter_test/|package:clikgate_flutter/testing\.dart|(\.\./)*testing\.dart)""")
            .hasMatch(f.readAsStringSync()))
        .map((f) => f.path)
        .toList();
    expect(offending, isEmpty);
  });
}
