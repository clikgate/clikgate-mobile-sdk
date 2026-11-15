import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 26 (existing users): the configure options pass through, an
/// existing user's attribution keeps `organic` with the flag, and the
/// `existing_user` error is an [ExistingUserException].
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

  test('configure sends existingUser false and no debug date by default',
      () async {
    await Clikgate.configure(sdkKey: 'cg_sdk_test');
    expect(configureArgs()['existingUser'], isFalse);
    expect(configureArgs()['debugPlatformInstalledAtMs'], isNull);
  });

  test('configure sends the hint and the debug install date', () async {
    await Clikgate.configure(
        sdkKey: 'cg_sdk_test',
        existingUser: true,
        debugPlatformInstalledAt:
            DateTime.fromMillisecondsSinceEpoch(1700000000000, isUtc: true));
    expect(configureArgs()['existingUser'], isTrue);
    expect(configureArgs()['debugPlatformInstalledAtMs'], 1700000000000);
  });

  test('an existing user is organic with isExistingUser', () {
    final a = ClikgateAttribution.fromMap(
        {'status': 'organic', 'isExistingUser': true});
    expect(a.status, ClikgateAttributionStatus.organic);
    expect(a.isExistingUser, isTrue);
    expect(a.isAttributed, isFalse);
    expect(ClikgateAttribution.fromMap({'status': 'organic'}).isExistingUser,
        isFalse);
  });

  test('existing_user maps to ExistingUserException', () {
    final e = ClikgateException.fromPlatformException(PlatformException(
        code: 'existing_user',
        message: 'already had the app',
        details: {'status': 409}));
    expect(e, isA<ExistingUserException>());
    expect(e.code, ClikgateException.existingUser);
    expect(e.status, 409);
  });
}
