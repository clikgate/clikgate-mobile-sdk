import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// `getInstallationHeader()`: a thin bridge; the native SDKs decide the value
/// (null when tracking is off, consent is missing, deep-link-only mode, or the
/// app ID isn't known yet).
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

  test('returns the native name and value', () async {
    answer = (_) => {
          'name': 'Clikgate-Installation',
          'value':
              'app_01JAB3C4D5E6F7G8H9JKMNPQRS:6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11',
        };
    final h = await Clikgate.getInstallationHeader();
    expect(h?.name, 'Clikgate-Installation');
    expect(h?.name, ClikgateInstallationHeader.headerName);
    expect(h?.value,
        'app_01JAB3C4D5E6F7G8H9JKMNPQRS:6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11');
    expect(calls.single.method, 'getInstallationHeader');
    expect(h.toString(), isNot(contains('6a1f0c2e')));
  });

  test('null when the native SDK answers null (tracking off and the like)',
      () async {
    answer = (_) => null;
    expect(await Clikgate.getInstallationHeader(), isNull);
  });

  test('never throws: a platform error is null', () async {
    answer = (_) => throw PlatformException(
        code: 'not_configured',
        message: 'Call Clikgate.configure first.',
        details: {'status': null, 'param': null});
    expect(await Clikgate.getInstallationHeader(), isNull);
  });

  test('never throws: no plugin is null', () async {
    messenger.setMockMethodCallHandler(methods, null);
    expect(await Clikgate.getInstallationHeader(), isNull);
  });

  test('an unexpected answer is null', () async {
    answer = (_) => {'name': 'Clikgate-Installation'};
    expect(await Clikgate.getInstallationHeader(), isNull);
    answer = (_) => 'nope';
    expect(await Clikgate.getInstallationHeader(), isNull);
  });

  test('equality by name and value', () {
    const a = ClikgateInstallationHeader(name: 'Clikgate-Installation', value: 'a:b');
    const b = ClikgateInstallationHeader(name: 'Clikgate-Installation', value: 'a:b');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
