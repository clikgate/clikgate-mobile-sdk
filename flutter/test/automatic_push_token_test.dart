import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2.1.0: `automaticPushToken` (default true) is passed to both native SDKs
/// (shared/PLATFORM_CHANNEL.md "configure").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');

  late List<MethodCall> calls;

  setUp(() async {
    await Clikgate.resetForTesting();
    calls = [];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  Map<Object?, Object?> configureArgs() =>
      calls.firstWhere((c) => c.method == 'configure').arguments as Map;

  test('configure sends automaticPushToken true by default', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    expect(configureArgs()['automaticPushToken'], isTrue);
  });

  test('configure sends automaticPushToken false when turned off', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test', automaticPushToken: false);
    expect(configureArgs()['automaticPushToken'], isFalse);
  });

  test('setPushToken still sends the token and provider', () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    await Clikgate.setPushToken('fcm-token', provider: PushProvider.fcm);
    final call = calls.lastWhere((c) => c.method == 'setPushToken');
    expect(call.arguments, {'token': 'fcm-token', 'provider': 'fcm'});
  });
}
