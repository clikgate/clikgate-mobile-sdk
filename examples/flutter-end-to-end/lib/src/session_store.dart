import 'package:shared_preferences/shared_preferences.dart';

/// What the app keeps on the phone between launches: the backend's access token, and whether this person has
/// used the app before. Use secure storage (the Keychain / Keystore) for a real access token.
class SessionStore {
  SessionStore(this._prefs);

  static const _accessTokenKey = 'access_token';
  static const _usedBeforeKey = 'used_app_before';

  final SharedPreferences _prefs;

  static Future<SessionStore> open() async => SessionStore(await SharedPreferences.getInstance());

  String? get accessToken => _prefs.getString(_accessTokenKey);

  /// True once someone has signed in on this phone. It stays true after sign-out: the person has still used the app.
  bool get hasUsedAppBefore => _prefs.getBool(_usedBeforeKey) ?? false;

  Future<void> saveSignedIn(String accessToken) async {
    await _prefs.setString(_accessTokenKey, accessToken);
    await _prefs.setBool(_usedBeforeKey, true);
  }

  Future<void> clearSession() => _prefs.remove(_accessTokenKey);
}
