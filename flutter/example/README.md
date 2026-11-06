# clikgate_flutter example

The primary Clikgate demo, in two variants (spec 17A.4) selected with
`--dart-define=CLIKGATE_VARIANT=backend|engage` (default `backend`):

- **backend** (recommended path): sign-in, invite link, stats, weekly leaderboard / "my rank"
  and purchases go through the sample backend in [`samples/backend`](../../samples/backend),
  which calls the Clikgate control-plane API. The app uses only `clikgate_flutter`.
- **engage** (no backend): the same screens plus promo codes via the optional
  [`clikgate_engage`](../../flutter_engage) add-on.

Both: product deep links (direct and deferred), referral welcome screen, apply-code screen,
referred-by banner, optional FCM token registration for uninstall tracking. Details and the
variant table: [docs/flutter.md §9](../../docs/flutter.md#9-example-app-two-variants).

```sh
# backend variant (start samples/backend on port 8080 first)
flutter run \
  --dart-define=CLIKGATE_VARIANT=backend \
  --dart-define=SAMPLE_BACKEND_URL=http://10.0.2.2:8080 \
  --dart-define=CLIKGATE_SDK_KEY=cg_sdk_... \
  --dart-define=CLIKGATE_API_BASE_URL=http://10.0.2.2:8000 \
  --dart-define=CLIKGATE_LINK_DOMAIN=inv.myapp.com \
  --dart-define=CLIKGATE_PROGRAM_ID=rpg_... \
  --dart-define=CLIKGATE_LEADERBOARD_ID=lb_... \
  -Pclikgate.linkDomain=inv.myapp.com          # App Link intent-filter host (Android)

# engage variant: the same with --dart-define=CLIKGATE_VARIANT=engage (no SAMPLE_BACKEND_URL)
```

Push is optional: add `--dart-define=FIREBASE_API_KEY=… FIREBASE_APP_ID=… FIREBASE_MESSAGING_SENDER_ID=… FIREBASE_PROJECT_ID=…`.
Without them the app runs and skips push (no `google-services.json` needed).

On Android the native SDK is built from `../../android` (Gradle composite build, see
`android/settings.gradle.kts`).

Try a direct link on the emulator:

```sh
adb shell am start -a android.intent.action.VIEW -d "https://inv.myapp.com/p/dress" com.clikgate.clikgate_flutter_example
```

Tests:

```sh
flutter test        # widget tests of both variants (backend_variant_test, engage_variant_test, core_screens_test)
flutter test integration_test --dart-define=CLIKGATE_API_BASE_URL=http://10.0.2.2:8000 --dart-define=CLIKGATE_SDK_KEY=cg_sdk_...
```

The integration tests are skipped unless `CLIKGATE_API_BASE_URL` is defined.

## Code layout

- `lib/main.dart`: configure, pick the variant, route deep links.
- `lib/src/variants/features.dart`: the `ReferralFeatures` interface the screens use;
  `backend_features.dart` (HTTP to the sample backend) and `engage_features.dart` (`clikgate_engage`).
- `lib/src/screens.dart` (home, sign-in, invite, apply code, product, welcome),
  `leaderboard.dart`, `promo_code.dart` (Engage only), `push.dart` (`firebase_messaging`).

## iOS signing

The Xcode project ships without a development team. Simulator builds don't need one
(`flutter build ios --simulator --no-codesign`). To run on a device, or to test Keychain-based
reinstall detection (which only works in signed builds), open `ios/Runner.xcworkspace`, select
**Runner → Signing & Capabilities** and choose your team. Don't commit that change.
