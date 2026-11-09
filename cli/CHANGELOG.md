# Changelog

## 2.0.0 (unreleased) (Change 22)

- **Breaking: installs the 2.0.0 SDKs, where `track()` was removed in favour of `goal()`.** Android, iOS, Flutter and React Native 2.0.0 (`~> 2.0` for the pod); doctor's minimum versions follow, so projects on 1.x get a warning to upgrade. The setup command never wrote `track()` calls, so no generated code changes. This is the first public release.
- **Android backup rules are merged.** An app that declares its own `android:fullBackupContent` / `android:dataExtractionRules` (every Android Studio template) no longer fails the manifest merge after setup: Clikgate's excludes go into the app's backup rules files (a missing file or `<cloud-backup>` / `<device-transfer>` section is created) and the attributes are listed in `tools:replace`. Running setup again changes nothing. New doctor check `android.backup_rules`.
- Next steps add "Identify signed-in users": Path A by default (a token from the server's `createIdentityToken`, then `identifyUser`), Path B mentioned (`getInstallationId()` sent to the business's server), with the guide link https://clikgate.com/docs/identify-users. The generated code never had `track()`; tests now assert it stays out.

## 1.1.1 (unreleased)

- Installs the SDK patch releases: Android, iOS and Flutter 1.5.1, React Native 1.6.1 (Change 21: one tap is one
  click, X `twclid`). Doctor's minimum versions follow. Nothing else changes.

## Unreleased

- **Websites (change 16 S, R.2): `npx @clikgate/setup website`.** Detects Next.js, Express, Laravel, Django,
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

## 1.1.0 (unreleased): app link subdomains (change 09)

- **Free plan app subdomains (change 10, folded into this unreleased version).** On the Free plan the app's live
  hostname is `yourapp.clk.ng`: release builds get it from `app_link_domains.release`, debug builds still get
  `yourapp.dev.ciz.to` from `app_link_domains.debug`. `yourapp.clk.ng` is an app subdomain, not a shared domain
  (the shared-domain check stays an exact match on `ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`), so setup writes it
  and doctor passes it. Offline mode accepts `--domain yourapp.clk.ng` and derives `yourapp.dev.ciz.to` for debug
  builds. Prompts and messages name the plan's parent (`ciz.to` or `clk.ng`) from the server's `link_hostnames`.

- **App links on the app's own subdomain (N.1).** Release builds get the hosts in the app's
  `app_link_domains.release` (`yourapp.ciz.to` plus the organisation's active custom domains), debug builds
  also `app_link_domains.debug` (`yourapp.dev.ciz.to`). Never a shared domain (`ciz.to`, `clk.ng`, `clkg.to`,
  `dev.ciz.to`), on iOS entitlements and Android intent filters alike. Each platform's files get only its own
  app's hosts.
- An unconfirmed link subdomain (apps from before change 09) is confirmed after asking, with
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
- **Device sign-in (N.3):** prints that the approval page asks for the authenticator code when the account uses
  two-factor; after a minute of waiting, reminds the person to approve in the browser. Polling is unchanged.
- Writes the SDKs of change 09: `clikgate_flutter ^1.5.0`, `@clikgate/react-native ^1.6.0`,
  `com.clikgate:clikgate-android:1.5.0`, `pod 'Clikgate', '~> 1.5'`.

## 1.0.0 (unreleased)

First release of `npx @clikgate/setup` (Change 06 S.1–S.6, S.8).

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
