/// The app's settings, passed at build time with `--dart-define` (see README.md).
/// The SDK key is the only Clikgate key an app ever holds; server keys stay on your backend.
class AppConfig {
  const AppConfig({
    required this.sdkKey,
    required this.linkDomains,
    required this.backendUrl,
    required this.referralProgramId,
  });

  factory AppConfig.fromEnvironment() => AppConfig(
        sdkKey: const String.fromEnvironment('CLIKGATE_SDK_KEY'),
        linkDomains: const String.fromEnvironment('CLIKGATE_LINK_DOMAINS')
            .split(',')
            .where((domain) => domain.isNotEmpty)
            .toList(),
        backendUrl: const String.fromEnvironment('BACKEND_URL',
            defaultValue: 'http://10.0.2.2:8080'), // the Android emulator's address for your computer
        referralProgramId: const String.fromEnvironment('CLIKGATE_REFERRAL_PROGRAM_ID'),
      );

  /// `cg_sdk_test_…` in debug builds, the live key in release builds.
  final String sdkKey;

  /// Every link domain of your Clikgate domain group, e.g. `inv.myapp.com`.
  final List<String> linkDomains;

  /// One of the sample backends (examples/end-to-end in the server SDK repository).
  final String backendUrl;

  /// Your referral program (`rpg_…`).
  final String referralProgramId;
}
