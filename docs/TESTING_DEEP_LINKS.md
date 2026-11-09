# Testing deep links, deferred deep links, referrals and uninstalls

How to exercise every path in the device matrix (spec section 20) before a release. Use a
**sandbox** app in Clikgate (`"environment": "sandbox"`) so you can reset installations and
use App Attest development keys.

## 0. Setup

1. Register the apps (`POST /v1/apps`) with bundle id + team id (iOS) and package name + signing
   fingerprints (Android), `ios_app_store_id`, `uri_scheme`, and `"environment": "sandbox"`.
   Copy each app's `sdk_key` from the response.
2. Create a link that opens the apps:
   ```bash
   curl -s https://api.clikgate.com/v1/links -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' -d '{
     "domain": "inv.myapp.com",
     "destination_url": "https://myapp.com/products/42",
     "app_ids": ["app_ios_...", "app_android_..."],
     "deep_link_path": "/products/42",
     "deep_link_data": {"product_id": "42"}
   }'
   ```
3. Check what each platform will be served, without recording a click:
   `GET /v1/links/{id}/debug?platform=ios&in_app_browser=instagram`.
4. Check integration health at any time: `GET /v1/apps/{id}/sdk-status` (warnings for missing
   team id / fingerprints, Play installs without referrer data, missing push tokens or
   credentials, outdated SDKs, referral programs that never qualify).
5. Re-run first-launch flows: `POST /v1/apps/{id}/sandbox/reset-installation
   {"installation_id": "..."}`, then uninstall/reinstall the app (or clear its data).

Local backend: run clikgate_api (`make dev`, `make dev-redirect`, `make worker`, `make ingest`) and
point the SDK at it with `apiBaseUrl` (Android emulator: `http://10.0.2.2:8000`; iOS
simulator: `http://localhost:8000`). Universal Links / App Links need a real HTTPS domain; for
local link tests use the custom scheme or `adb shell am start` / `xcrun simctl openurl`.

## 1. App installed, link opened directly

| Platform | How | Expect |
|---|---|---|
| Android | `adb shell am start -a android.intent.action.VIEW -d "https://inv.myapp.com/<slug>"`. Verify App Links first: `adb shell pm verify-app-links --re-verify com.myapp.android` then `adb shell pm get-app-links com.myapp.android` (domain `verified`) | App opens, `onDeepLink` fires with `isDeferred = false`, `matchType = app_link` |
| iOS simulator | `xcrun simctl openurl booted "https://inv.myapp.com/<slug>"` (needs the Associated Domains entitlement and a reachable AASA; with `?mode=developer` on the entitlement the simulator fetches AASA directly) | Same |
| iOS device | Paste the link in Notes and tap it (typing it into Safari's address bar does **not** trigger Universal Links) | Same |
| Custom scheme | `adb shell am start -d "myapp://products/42?cg_click_id=clk_..."` / `xcrun simctl openurl booted "myapp://..."` | `/v1/sdk/resolve` reuses the click id |
| Password link (Change 17) | Set a password on a link, open it as above | The password page opens in the browser app (Android: not a Custom Tab; iOS: Safari, not over the app), `onDeepLink` doesn't fire. **iOS device: confirm Safari opens and the app isn't reopened** (if iOS hands the link back, the SDK opens it once per 30 s and stops: see DECISIONS.md "Change 17") |
| Country-blocked link (Change 17) | Restrict a link's countries to one you're not in, open it as above | `onDeepLink` fires with `blockMessage` set and no `path` / `clickId` |

Check the AASA and assetlinks Clikgate serves: `curl https://inv.myapp.com/.well-known/apple-app-site-association`
and `.../.well-known/assetlinks.json`.

## 2. In-app browsers (Instagram, WhatsApp, TikTok, ...)

These don't hand links to the OS, so the request reaches Clikgate even with the app installed.

- iOS: Clikgate serves the interstitial; "Open in app" uses the custom scheme. Without the app,
  "Get" copies the pasteboard link and goes to the App Store.
- Android Chrome-based browsers get an `intent://` URL (opens the app, or the Play Store via
  `browser_fallback_url`); WebView-based in-app browsers go straight to the Play Store.

Simulate with the debugger (`in_app_browser=instagram|facebook|tiktok|...`) or by sending the
link to yourself in each app.

## 3. Deferred deep links (not installed → install → open)

**Android (Install Referrer).** The Play URL carries `referrer=cg_click_id=...&cg_link=...`. The
Install Referrer API only returns it for installs from Google Play:
1. Upload the app to an **internal test track**, add yourself as a tester, uninstall the app.
2. Open the Clikgate link on the device; it lands on the Play listing (the referrer is attached).
3. Install from Play and open the app: `/v1/sdk/install` gets the referrer; the deep link arrives
   with `isDeferred = true`, `matchType = install_referrer`.

Without Play (e.g. `adb install`), you can test the server side with `curl`:
```bash
curl -s https://sdk.clikgate.com/v1/sdk/install -H "Clikgate-SDK-Key: $SDK_KEY" -H 'Content-Type: application/json' \
  -H "Clikgate-Installation-Id: $(uuidgen | tr A-Z a-z)" -d '{"installation_id": "...", "platform": "android",
  "app_version": "1.0", "sdk_version": "1.0.0", "install_referrer": {"referrer": "cg_click_id=clk_...&cg_link=lnk_..."}}'
```

**iOS (pasteboard).** With `pasteboard_matching = on_interstitial_tap` (default): open the link in
Safari without the app installed → interstitial → tap "Get" (copies a `https://<domain>/_cg/p/cgdl_...`
link) → install (TestFlight / Xcode) → first launch. On iOS 16+ the system asks to allow paste
(or use `ClikgatePasteControl`, which needs no prompt). Expect `matchType = pasteboard`.

**iOS (probabilistic)** — only if an org owner enabled it (see [PRIVACY.md](PRIVACY.md)): open the
link on the device, install within the window from the **same network**, open the app. Expect
`matchType = probabilistic` with a confidence score.

**Organic**: install without clicking anything: `attribution.status = organic`, no deep link.

## 4. Referrals

1. Create a program (`POST /v1/referral-programs`) on the app pair, with `code_url_patterns`
   such as `["/r/{code}"]` and the qualification steps you want to test (use small
   `within_days` / `hold.days` values on a sandbox app).
2. On device A: sign in, `identifyUser(customerId: userId, identityToken)`, get the user's link (from your
   backend via `/v1/referral-programs/{id}/referrers`, or with the Engage add-on's
   `referrals.createLink(programId)`), share the link. With the samples: run
   [`samples/backend`](../samples/backend/README.md) and the Flutter example's backend variant
   (sign in → "Invite friends"), or the Engage variant without a backend (section 7).
3. On device B (not installed): open the link → install (as in section 3) → launch. The install
   response carries `referral` with `status = installed`; webhook `referral.created`.
4. On device B: sign up → `identifyUser()`, `goal("sign_up")`, `goal("purchase", reference, provider)` (ticked as goals in the dashboard); watch
   `referral.step_completed`, then `referral.holding`.
5. Hold: the worker's `referral_hold_evaluator` qualifies it after `hold_until` if the referee is
   still installed and was active on `min_active_days` distinct days → `referral.qualified`.
6. Manual code entry: install without a link, then `referrals.applyCode(programId, "CODE")`.
7. Self-referral: install on a second device signed in as the referrer → `referral.rejected`
   (`self_referral`).

## 5. Uninstall tracking

1. Upload APNs (`.p8`) and/or FCM credentials: `PUT /v1/apps/{id}/push-credentials/{apns|fcm}`.
   Test them with a device token: `POST /v1/apps/{id}/push-credentials/test {"provider", "token"}`.
2. Enable `uninstall_tracking` in `PATCH /v1/apps/{id}/sdk-settings` (for testing, set
   `schedule.first_check_after_hours` to 1).
3. Make sure the app forwards the push token (`setPushToken`) and silent messages
   (`isClikgateMessage` / `handleRemoteNotification`).
4. Uninstall the app and wait for the next scheduled check. APNs sandbox tokens need
   `apns_environment = sandbox` (debug builds); iOS may report the uninstall only days later.
   Expect `install.uninstalled`; reinstalling and opening (same Keychain installation on iOS)
   produces `install.uninstall_reverted`.

## 6. Opt-out and offline

- `setTrackingEnabled(false)` → no more requests from the device (check with a proxy such as
  Proxyman / Charles); `/v1/installs/{id}` shows `opt_out: true` and no device fields.
- Offline first launch: launch in airplane mode, then reconnect; the install is retried and the
  deferred deep link arrives late (`isDeferred = true`).

## 7. With the sample apps

Every sample handles `/products/{id}` links (product screen, for direct and deferred links),
referral links (welcome screen / "Invited by" banner), code entry (apply code) and push-token
registration. Create the link of section 0 with `"deep_link_path": "/products/42"`.

| Sample | Run | Direct link test | Push |
|---|---|---|---|
| Flutter (primary), [docs/flutter.md §9](flutter.md#9-example-app-two-variants) | `cd flutter/example && flutter run --dart-define=CLIKGATE_VARIANT=backend\|engage …` | `adb shell am start -a android.intent.action.VIEW -d "https://inv.myapp.com/<slug>" com.clikgate.clikgate_flutter_example` | FCM with `FIREBASE_*` defines |
| Android, `android/sample` | `cd android && ./gradlew :sample:installDebug -Pclikgate.sdkKey=… -Pclikgate.linkDomain=inv.myapp.com -Pclikgate.apiBaseUrl=http://10.0.2.2:8000 -Pclikgate.programId=rpg_…` | `adb shell am start -a android.intent.action.VIEW -d "https://inv.myapp.com/<slug>" com.clikgate.sample`, or `clikgatesample://products/42?cg_click_id=clk_…` | FCM with `-Pclikgate.firebaseApiKey/AppId/ProjectId/SenderId` |
| iOS, `ios/Sample` | `cd ios/Sample && xcodegen generate`, set the values in `Local.xcconfig` (see `Config.xcconfig`), run from Xcode | `xcrun simctl openurl booted "clikgatesample://products/42?cg_click_id=clk_…"`; Universal Links need the real domain | APNs device token (device build with a team) |
| React Native, `react-native/example` | `CLIKGATE_SDK_KEY=… CLIKGATE_LINK_DOMAIN=… npx react-native start`, then `npm run android` / `npm run ios` | as Android / iOS above (package `com.clikgate.reactnative.example`) | iOS: APNs natively in `AppDelegate`; Android FCM needs `@react-native-firebase/messaging` (see `src/push.ts`) |

Deferred links on every sample: uninstall, open the link (lands on the store / interstitial),
install as in section 3, launch; the product screen opens with "deferred" shown.
