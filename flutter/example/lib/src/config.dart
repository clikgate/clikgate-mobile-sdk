/// Example configuration, passed with --dart-define (see README.md):
///
///   flutter run \
///     --dart-define=CLIKGATE_VARIANT=backend \             # backend (default) | engage
///     --dart-define=SAMPLE_BACKEND_URL=http://10.0.2.2:8080 \   # backend variant: samples/backend
///     --dart-define=CLIKGATE_SDK_KEY=cg_sdk_... \
///     --dart-define=CLIKGATE_API_BASE_URL=http://10.0.2.2:8000 \
///     --dart-define=CLIKGATE_LINK_DOMAIN=inv.myapp.com \
///     --dart-define=CLIKGATE_PROGRAM_ID=rpg_... \
///     --dart-define=CLIKGATE_LEADERBOARD_ID=lb_...
///
/// Push (optional): FIREBASE_API_KEY, FIREBASE_APP_ID, FIREBASE_MESSAGING_SENDER_ID,
/// FIREBASE_PROJECT_ID. Without them the app runs without push.
class ExampleConfig {
  /// `backend` (recommended path, needs samples/backend) or `engage` (no backend, clikgate_engage).
  static const variant = String.fromEnvironment('CLIKGATE_VARIANT', defaultValue: 'backend');

  /// Base URL of the sample backend (backend variant). 10.0.2.2 = the host from the Android emulator.
  static const backendUrl = String.fromEnvironment('SAMPLE_BACKEND_URL', defaultValue: 'http://10.0.2.2:8080');

  static const sdkKey = String.fromEnvironment('CLIKGATE_SDK_KEY', defaultValue: 'cg_sdk_example');
  static const apiBaseUrl = String.fromEnvironment('CLIKGATE_API_BASE_URL');
  static const linkDomain = String.fromEnvironment('CLIKGATE_LINK_DOMAIN', defaultValue: 'inv.example.com');

  /// Apply-code screen (both variants) and Engage calls. The backend variant's own links and
  /// stats use the backend's CLIKGATE_PROGRAM_ID.
  static const programId = String.fromEnvironment('CLIKGATE_PROGRAM_ID', defaultValue: 'rpg_example');
  static const leaderboardId = String.fromEnvironment('CLIKGATE_LEADERBOARD_ID', defaultValue: 'lb_example');

  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

  static bool get firebaseConfigured =>
      firebaseApiKey.isNotEmpty && firebaseAppId.isNotEmpty && firebaseSenderId.isNotEmpty && firebaseProjectId.isNotEmpty;
}
