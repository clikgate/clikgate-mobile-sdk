import 'package:clikgate_flutter/clikgate_flutter.dart';
import 'package:flutter/foundation.dart';

import 'backend/backend_api.dart';
import 'session_store.dart';

/// Sign-up, sign-in, the signed-in state at app open, and sign-out, each followed by the matching
/// `Clikgate.identifyUser` call.
class AuthService extends ChangeNotifier {
  AuthService(this._backend, this._session);

  final BackendApi _backend;
  final SessionStore _session;

  AppUser? _user;
  AppUser? get user => _user;

  Future<void> signUp(String email, String password) async => _signedIn(await _backend.signUp(email, password));

  Future<void> signIn(String email, String password) async => _signedIn(await _backend.signIn(email, password));

  /// At every app open with a saved session: `/me` returns a fresh identity token, so it never expires.
  Future<void> restore() async {
    if (_session.accessToken == null) return;
    try {
      _signedIn(await _backend.me());
    } catch (_) {
      await signOut(); // the saved session is no longer valid
    }
  }

  Future<void> signOut() async {
    await _session.clearSession();
    _user = null;
    notifyListeners();
    await Clikgate.identifyUser(customerId: null); // clears the customer ID and token on this phone
  }

  Future<void> _signedIn(SignedIn signedIn) async {
    final accessToken = signedIn.accessToken;
    if (accessToken != null) await _session.saveSignedIn(accessToken);
    _user = signedIn.user;
    notifyListeners();
    // The newest token from your backend, and exactly the same user ID string the backend uses.
    await Clikgate.identifyUser(customerId: signedIn.user.id, identityToken: signedIn.identityToken);
  }
}
