import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An organisation that accepts only goals it has set up: the native SDKs
/// refuse unknown names with `unknown_goal` (archived goals with
/// `goal_archived`) and never retry them. The plugin passes the result through
/// and never checks names itself.
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

  test('unknown_goal is a refusal with its reason', () async {
    answer = (_) => {
          'status': 'refused',
          'reason': 'unknown_goal',
          'goalKind': null,
          'valueIgnored': false
        };
    final r = await Clikgate.goal('level_complete', reference: 'APP-11');
    expect(r,
        const GoalResult(status: GoalStatus.refused, reason: 'unknown_goal'));
  });

  test('goal_archived is a refusal with its reason and kind', () async {
    answer = (_) => {
          'status': 'refused',
          'reason': 'goal_archived',
          'goalKind': 'standard',
          'valueIgnored': false
        };
    final r = await Clikgate.goal('old_signup', reference: 'APP-12');
    expect(r.status, GoalStatus.refused);
    expect(r.reason, 'goal_archived');
    expect(r.goalKind, GoalKind.standard);
  });

  test('every name goes to the native SDK, even after a refusal', () async {
    answer = (_) => {'status': 'refused', 'reason': 'unknown_goal'};
    await Clikgate.goal('level_complete', reference: 'APP-11');
    await Clikgate.goal('level_complete', reference: 'APP-13');
    expect(calls.where((c) => c.method == 'goal').length, 2);
  });
}
