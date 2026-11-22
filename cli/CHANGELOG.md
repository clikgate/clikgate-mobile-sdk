# Changelog

## 2.1.6

- Installs the 2.1.6 SDKs (`clikgate-android` 2.1.6, `Clikgate` 2.1.6, `clikgate_flutter` ^2.1.6, `@clikgate/react-native` ^2.1.6): they add the installation header for your own server, and on iOS each app has its own installation ID.
- The sign-in snippet setup prints passes `response.clikgateIdentityToken` to `identifyUser`, the field name the identity guide uses.
- Messages name the dashboard pages where they are now: apps, link subdomains and store links under Connect › Apps, branded domains under Connect › Branded domains, SDK keys under Developers › SDKs, and web keys under Developers › SDKs › Website.
- Includes the 2.1.5 changes below (your app's download link, and your website for computer visitors). 2.1.5 wasn't published on its own.

## 2.1.5

- **Your app's download link.** After the files are written, setup has Clikgate make one link to share anywhere, `https://<your link subdomain>/download`: phones open the app, or the App Store / Google Play when it isn't installed; computers go to your website, or to a page with your store buttons. Setup prints it at the end. It's an ordinary link you can edit in the dashboard (Links), and running setup again never undoes your edits.
- **Your website, for computer visitors.** Setup asks for the company website once (`acme.com` is enough; Enter skips) and saves it on the apps. Not asked with `--yes`, or when Clikgate already has one.
- Installs `clikgate_flutter` ^2.1.5 (the other SDKs stay 2.1.3).

## 2.1.4

- **URI scheme, set up for you.** Setup finds the app's scheme (in Clikgate or the project) or suggests one from the link subdomain, adds it to Info.plist and AndroidManifest.xml (Expo: `scheme` in app.json), and saves it on the Clikgate apps after the files are written. The link page can then offer "Open in app".
- **App Store ID, filled in for you.** For an iOS app on the App Store, setup finds it by bundle ID and saves the App Store link, so visitors without the app go to the App Store. Not published yet: a manual step says what to do later.
- **Dropped connections are retried.** Requests to Clikgate are retried twice (after 1 and 3 seconds) when the connection drops or Cloudflare reports the origin unreachable, with one `Idempotency-Key` per request so a retry is never applied twice.
- Installs `clikgate_flutter` ^2.1.4 (the other SDKs stay 2.1.3).

## 2.1.3

- Installs the 2.1.3 SDKs (constraints `^2.1.3` / `~> 2.1`).
- The Play App Signing fingerprint is now found under Play Console › Protected with Play › Play Store protection ›
  Manage Play app signing (Google renamed the page). The setup prompt and `doctor`'s `wrong_fingerprint` fix say so.

## 2.1.2

- Installs the 2.1.2 SDKs. Free plan apps get `yourapp.ciz.ng` (was `yourapp.clk.ng`) as their link domain, and
  `ciz.ng` is treated as a shared domain. Constraints `^2.1.2` / `~> 2.1`.

## 2.1.1

- Installs the 2.1.1 SDKs (existing users: the first launch says how and when the app arrived on the phone, so people
  who had the app before Clikgate aren't counted as new installs). Constraints `^2.1.1` / `~> 2.1`.

## 2.1.0

- **Also runs as `dart run clikgate_flutter`** (Flutter projects, no Node.js): the same code compiled with Bun into
  self-contained binaries (`scripts/build_setup_binaries.sh`), downloaded and verified by `clikgate_flutter`. When
  `CLIKGATE_SETUP_COMMAND` is set (the Flutter runner sets `dart run clikgate_flutter`), `--help`, the "Run `…`"
  hints and doctor's fixes (also in `--json`) name that command, and `…:doctor` for doctor. Default unchanged:
  `npx @clikgate/setup`.
- Installs the 2.1.0 SDKs, which contain the Engage features (no separate Engage package exists any more; the command
  never installed one). Constraints `^2.1.0` / `~> 2.1`; doctor's minimum is 2.1.0.
- **Uninstall tracking without notification permission (iOS).** The 2.1.0 SDKs get a push token by themselves
  (`automaticPushToken`). Setup now adds `aps-environment` (Push Notifications capability) to the entitlements it
  edits, always (`development` in Debug, `production` in Release; an existing value is kept), and the one line that
  passes the APNs token to Clikgate to a UIKit AppDelegate (Swift or Objective-C) when missing:
  `Clikgate.shared.setPushToken(deviceToken:)` for iOS apps, `ClikgateRN.setPushToken(deviceToken:)` for React Native
  and Expo with `ios/` (Expo's `ExpoAppDelegate` gets a `public override` that calls `super`). Flutter needs no line
  (the plugin forwards the token). SwiftUI apps without an AppDelegate get a manual step. Running setup again changes
  nothing. New doctor warnings `ios.push.aps_environment` and `ios.push.token_forward` (the latter not for Flutter).

## 2.0.0 (unreleased)

- **Breaking: installs the 2.0.0 SDKs, where `track()` was removed in favour of `goal()`.** Android, iOS, Flutter and React Native 2.0.0 (`~> 2.0` for the pod); doctor's minimum versions follow, so projects on 1.x get a warning to upgrade. The setup command never wrote `track()` calls, so no generated code changes. This is the first public release.
- **Android backup rules are merged.** An app that declares its own `android:fullBackupContent` / `android:dataExtractionRules` (every Android Studio template) no longer fails the manifest merge after setup: Clikgate's excludes go into the app's backup rules files (a missing file or `<cloud-backup>` / `<device-transfer>` section is created) and the attributes are listed in `tools:replace`. Running setup again changes nothing. New doctor check `android.backup_rules`.
- Next steps add "Identify signed-in users": Path A by default (a token from the server's `createIdentityToken`, then `identifyUser`), Path B mentioned (`getInstallationId()` sent to the business's server), with the guide link https://clikgate.com/docs/identify-users. The generated code never had `track()`; tests now assert it stays out.

## 1.1.1 (unreleased)

- Installs the SDK patch releases: Android, iOS and Flutter 1.5.1, React Native 1.6.1 (one tap is one
  click, X `twclid`). Doctor's minimum versions follow. Nothing else changes.

## Unreleased

- **Websites: `npx @clikgate/setup website`.** Detects Next.js, Express, Laravel, Django,
  Spring Boot, ASP.NET Core, WordPress and Shopify themes by their package files (also a few folders down in a
  monorepo); when nothing is recognised it asks "Does your website have its own server?". With a server it adds the
  `/cg/keep` route with the framework's Clikgate server SDK and `data-server-endpoint="/cg/keep"` on the web script
  tag (found in the project, or added before `</head>` in the layout). WordPress and Shopify get no edits: the
  plugin and the app keep the click ID themselves. New flags: `--website-server <framework|none>`, `--web-key
  <cgw_test_…>`. The server SDK is never added as a dependency; the install command is printed. Anything the
  command can't place safely is a manual step with the exact code. `data-days` is never written (the web script's
  default is now 30 days).
- The summary's next steps show how to send goals: one `goal()` call per SDK with the `Provider` enum
  (`Clikgate.goal("purchase", reference = "T123456", provider = Provider.PAYSTACK)` on Android). The SDKs'
  `payment()` method is gone; a Payment goal is reported with `goal()`.

## 1.1.0 (unreleased): app link subdomains

- **Free plan app subdomains (folded into this unreleased version).** On the Free plan the app's live
  hostname is `yourapp.ciz.ng`: release builds get it from `app_link_domains.release`, debug builds still get
  `yourapp.dev.ciz.to` from `app_link_domains.debug`. `yourapp.ciz.ng` is an app subdomain, not a shared domain
  (the shared-domain check stays an exact match on `ciz.to`, `ciz.ng`, `dev.ciz.to`), so setup writes it
  and doctor passes it. Offline mode accepts `--domain yourapp.ciz.ng` and derives `yourapp.dev.ciz.to` for debug
  builds. Prompts and messages name the plan's parent (`ciz.to` or `ciz.ng`) from the server's `link_hostnames`.

- **App links on the app's own subdomain.** Release builds get the hosts in the app's
  `app_link_domains.release` (`yourapp.ciz.to` plus the organisation's active custom domains), debug builds
  also `app_link_domains.debug` (`yourapp.dev.ciz.to`). Never a shared domain (`ciz.to`, `ciz.ng`,
  `dev.ciz.to`), on iOS entitlements and Android intent filters alike. Each platform's files get only its own
  app's hosts.
- An unconfirmed link subdomain (apps from before 1.1.0) is confirmed after asking, with
  `PATCH /v1/apps/{id} {"link_subdomain"}`; another name is checked with `GET /v1/link-subdomains/availability`.
  `--yes` confirms the suggestion.
- The shared-domain opt-in (`sdk-settings`) is gone.
- Offline mode: `--domain yourapp.ciz.to,go.acme.com`; the debug host is derived (`yourapp.dev.ciz.to`). A
  shared domain in `--domain` is refused.
- Existing shared-domain entries are reported as manual steps, never removed.
- **doctor:** `android.shared_domains`, `ios.shared_domains` and `expo.shared_domains` warn "remove this: shared
  domains can't open your app". Test-domain checks accept any `*.dev.ciz.to`. Signed in, the setup check's
  `domains[]` holds the app's subdomains (their AASA / assetlinks must contain the app), and
  `clikgate.<platform>.link_subdomain` fails while the subdomain is unconfirmed (`link_subdomain_not_confirmed`).
  The `not_listed_on_shared_domain` and `shared_domain_file_full` fixes are removed.
- **Device sign-in:** prints that the approval page asks for the authenticator code when the account uses
  two-factor; after a minute of waiting, reminds the person to approve in the browser. Polling is unchanged.
- Writes the 1.5.0 SDKs: `clikgate_flutter ^1.5.0`, `@clikgate/react-native ^1.6.0`,
  `com.clikgate:clikgate-android:1.5.0`, `pod 'Clikgate', '~> 1.5'`.

## 1.0.0 (unreleased)

First release of `npx @clikgate/setup`.

- Sets up Flutter, React Native, Expo, native Android and native iOS projects:
  - browser sign-in (RFC 8628 device flow; the token is kept in memory only);
  - app matching or creation, and signing details;
  - link domains, with the shared-domain opt-in;
  - plan, diff and confirm, then apply and install;
  - doctor, and a summary that ends "Clikgate sees every click. Setup complete."
- Writes the current mobile SDKs, which include the shared-domain browser fallback:
  - `clikgate_flutter ^1.4.0`;
  - `@clikgate/react-native ^1.5.0` (Expo plugin with `testLinkDomain`);
  - `com.clikgate:clikgate-android:1.4.0` (plain or version-catalog `clikgate = "1.4.0"`);
  - `pod 'Clikgate', '~> 1.4'`.
- `dev.ciz.to` goes only into debug manifests and Debug entitlements.
- The SDKs' `platformDomainBrowserFallback` option is never written, so it keeps its default (on).
- An existing older SDK constraint is never rewritten. Setup reports it as a manual step, and doctor warns (`sdk.version`).
- `doctor --json`: schema `schema/doctor-report.schema.json`, `schema_version` 1.
- Offline mode (`--sdk-key cg_sdk_test_… --domain …`) refuses live keys. Extra flags: `--no-install`, `--no-wait`.
- Doctor's fix for a missing iOS dependency without a Podfile points to Xcode's "Add Package Dependencies" (the Swift package can't be added by the command).
