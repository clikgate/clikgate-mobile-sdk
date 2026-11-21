import 'package:clikgate_end_to_end/src/auth_service.dart';
import 'package:clikgate_end_to_end/src/clikgate_setup.dart';
import 'package:clikgate_end_to_end/src/config.dart';
import 'package:clikgate_end_to_end/src/session_store.dart';
import 'package:clikgate_flutter/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_backend.dart';

const config = AppConfig(
  sdkKey: 'cg_sdk_test_sample',
  linkDomains: ['inv.myapp.test'],
  backendUrl: 'https://backend.test',
  referralProgramId: 'rpg_test',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The SDK's own test fake answers every Clikgate call without a phone or the network.
  late ClikgateFake clikgate;
  late FakeBackend backend;

  setUp(() {
    clikgate = ClikgateFake.install();
    backend = FakeBackend();
  });

  Future<SessionStore> session([Map<String, Object> saved = const {}]) async {
    SharedPreferences.setMockInitialValues(saved);
    return SessionStore.open();
  }

  test('configure passes the link domains, and existingUser from the app\'s own storage', () async {
    await startClikgate(config, await session());
    await startClikgate(config, await session({'used_app_before': true}));

    final configures = clikgate.callsTo('configure').map((c) => c.arguments as Map).toList();
    expect(configures[0]['linkDomains'], ['inv.myapp.test']);
    expect(configures[0]['existingUser'], isFalse);
    expect(configures[1]['existingUser'], isTrue);
  });

  test('sign-up identifies the user with the token from the backend, and is remembered', () async {
    final store = await session();
    await AuthService(backend.api(store), store).signUp('ada@example.com', 'correct horse');

    final identify = clikgate.identifyCalls.single;
    expect(identify.customerId, 'user_42');
    expect(identify.identityToken, 'token-1');
    expect(store.accessToken, 'session-1');
    expect(store.hasUsedAppBefore, isTrue);
  });

  test('every backend request carries the installation header (the no-token option)', () async {
    final store = await session();
    await AuthService(backend.api(store), store).signIn('ada@example.com', 'correct horse');
    expect(backend.requests.single.headers['Clikgate-Installation'], '${clikgate.appId}:${clikgate.installationId}');
  });

  test('no installation header while tracking is off', () async {
    clikgate.installationId = null; // what the SDK answers while tracking is off
    final store = await session();
    await AuthService(backend.api(store), store).signIn('ada@example.com', 'correct horse');
    expect(backend.requests.single.headers.containsKey('Clikgate-Installation'), isFalse);
  });

  test('a saved session is refreshed with /me at app open, with the access token', () async {
    final store = await session({'access_token': 'session-1', 'used_app_before': true});
    final auth = AuthService(backend.api(store), store);
    await auth.restore();

    expect(backend.requests.single.path, '/me');
    expect(backend.requests.single.headers['Authorization'], 'Bearer session-1');
    expect(auth.user?.id, 'user_42');
    expect(clikgate.identifyCalls.single.identityToken, 'token-from-me');
  });

  test('sign-out clears the session and the customer on this phone', () async {
    final store = await session({'access_token': 'session-1', 'used_app_before': true});
    final auth = AuthService(backend.api(store), store);
    await auth.signOut();

    expect(clikgate.identifyCalls.single.isSignOut, isTrue);
    expect(store.accessToken, isNull);
    expect(store.hasUsedAppBefore, isTrue); // they have still used the app
  });

  test('a wrong password is refused and nobody is identified', () async {
    backend.rejectPassword = true;
    final store = await session();
    final auth = AuthService(backend.api(store), store);
    await expectLater(auth.signIn('ada@example.com', 'nope'), throwsA(anything));
    expect(clikgate.identifyCalls, isEmpty);
    expect(auth.user, isNull);
  });
}
