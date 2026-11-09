import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Change 22: one method, `goal()` (R.9 `received` is a success), and `getInstallationId()` for identity Path B
/// (I.7, R.26). The plugin stays thin: the native SDKs decide the value (null when tracking is off).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel('com.clikgate/sdk');
  late List<MethodCall> calls;
  late Object? Function(MethodCall) answer;

  setUp(() {
    calls = [];
    answer = (_) => null;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return answer(call);
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('getInstallationId returns the native value', () async {
    answer = (_) => '6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11';
    expect(await Clikgate.getInstallationId(),
        '6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11');
    expect(calls.single.method, 'getInstallationId');
    expect(calls.single.arguments, anyOf(isNull, isEmpty));
  });

  test('getInstallationId is null when tracking is off natively', () async {
    answer = (_) => null;
    expect(await Clikgate.getInstallationId(), isNull);
  });

  test('getInstallationId before configure reports not_configured (iOS)',
      () async {
    answer = (_) => throw PlatformException(
        code: 'not_configured',
        message: 'Call Clikgate.configure first.',
        details: {'status': null, 'param': null});
    await expectLater(
        Clikgate.getInstallationId(),
        throwsA(isA<ClikgateException>()
            .having((e) => e.code, 'code', 'not_configured')));
  });

  test('received is a success status, with its reason', () async {
    answer = (_) => {
          'status': 'received',
          'reason': 'not_counted_yet',
          'goalKind': null,
          'valueIgnored': false
        };
    final r = await Clikgate.goal('level_completed', reference: 'APP-7');
    expect(r.status, GoalStatus.received);
    expect(r.reason, 'not_counted_yet');
    expect(GoalStatus.parse('received'), GoalStatus.received);
    expect(GoalStatus.parse('something_new'), GoalStatus.refused);
  });

  test('no track method on the plugin (goal() is the only method)', () async {
    final names = GoalStatus.values.map((s) => s.name).toList();
    expect(names, ['counted', 'waiting', 'received', 'refused']);
  });
}
