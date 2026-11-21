import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const installationHeaderValue = 'app_01JAB3C4D5E6F7G8H9JKMNPQRS:6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11';

/// Stands in for the native Clikgate SDK: answers the plugin's platform channels and records every call,
/// so the tests run without a phone, a simulator or the network.
class FakeClikgatePlatform {
  FakeClikgatePlatform() {
    _messenger.setMockMethodCallHandler(const MethodChannel('com.clikgate/sdk'), _core);
    _messenger.setMockMethodCallHandler(const MethodChannel('com.clikgate/engage'), _engage);
  }

  final calls = <MethodCall>[];

  /// What getInstallationHeader answers; null is "tracking is off".
  Map<String, String>? installationHeader = {'name': 'Clikgate-Installation', 'value': installationHeaderValue};

  static final _messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  List<MethodCall> callsTo(String method) => calls.where((c) => c.method == method).toList();

  void dispose() {
    _messenger.setMockMethodCallHandler(const MethodChannel('com.clikgate/sdk'), null);
    _messenger.setMockMethodCallHandler(const MethodChannel('com.clikgate/engage'), null);
  }

  Future<Object?> _core(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'getInstallationHeader':
        return installationHeader;
      case 'goal':
        return {'status': 'counted'};
      case 'isFeatureEnabled':
        return true;
      case 'getRequestContext':
        return {
          'installationId': '6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11',
          'sdkKey': 'cg_sdk_test_sample',
          'apiBaseUrl': 'https://sdk.test',
          'customerUserId': 'user_42',
          'sdkVersion': 'flutter/test',
        };
      case 'referrals.applyCode':
        final code = (call.arguments as Map)['code'];
        if (code != 'ADA42') {
          throw PlatformException(code: 'code_not_found', message: 'No such code.', details: {'status': 404});
        }
        return {'referralId': 'ref_1', 'programId': 'rpg_test', 'status': 'installed', 'referrerId': 'rfr_1'};
    }
    return null; // configure, identifyUser, ...
  }

  Future<Object?> _engage(MethodCall call) async {
    calls.add(call);
    return call.method == 'shareLink' ? false : null; // no saved link; the share menu was shown
  }
}
