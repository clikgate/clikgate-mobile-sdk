import 'dart:convert';

import 'package:clikgate_flutter/engage.dart';
import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:clikgate_flutter_example/src/variants/features.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Engage's view of the core plugin, without the platform channel.
class FakeCore implements EngageCore {
  FakeCore({this.enabled = true});
  final bool enabled;

  @override
  Future<bool> isFeatureEnabled(String key) async => enabled;

  @override
  Future<ClikgateRequestContext> requestContext() async => const ClikgateRequestContext(
        installationId: 'inst-1',
        sdkKey: 'cg_sdk_test',
        environment: 'production',
        apiBaseUrl: 'https://sdk.test',
        customerUserId: 'user_42',
        sdkVersion: 'flutter/1.0.0',
      );

  @override
  Future<void> reportServerError(String code, {String? feature}) async {}
}

/// Records `Clikgate.identifyUser` calls.
class IdentifyLog {
  final calls = <(String?, String?)>[];
  Future<void> call(String? id, {String? identityToken}) async => calls.add((id, identityToken));
}

/// Mocks the core plugin's channel for the home screen (attribution + referred-by).
void mockCoreChannel({bool referred = true}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.clikgate/sdk'), (call) async {
    switch (call.method) {
      case 'getAttribution':
        return {'status': 'attributed', 'matchType': 'install_referrer', 'isReinstall': false, 'installId': 'ins_1'};
      case 'referrals.referredBy':
        return referred
            ? {
                'referred': true,
                'referral': {'referralId': 'ref_1', 'programId': 'rpg_1', 'status': 'holding', 'referrerId': 'rfr_1', 'referrerDisplayName': 'Ada'},
              }
            : {'referred': false, 'referral': null};
    }
    return null;
  });
}

Widget wrap(ReferralFeatures features, Widget home) =>
    FeaturesScope(features: features, child: MaterialApp(home: home));

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// Lets real async work (mock HTTP) finish, then rebuilds.
Future<void> settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump();
}
