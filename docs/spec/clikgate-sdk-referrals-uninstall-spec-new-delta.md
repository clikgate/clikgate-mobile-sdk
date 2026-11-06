# Clikgate SDK spec v3 (new edition) — what changed

The customer issued a new, consolidated edition of the SDK spec ("Clikgate Mobile SDKs, Install
Attribution, Referrals, Leaderboards, Identity Checks, WhatsApp & Offline Attribution, Uninstall
Tracking — Build Specification (v3)"). It **supersedes** `clikgate-sdk-referrals-uninstall-spec.md`
(v2) and `clikgate-spec-v3-additions.md` in this folder. Almost everything in it is identical to
v2 + v3-additions, which are already built. This file holds, **verbatim**, the sections that are
new or different, followed by a list of what that means for the code as it stands.

---

## Verbatim: new / changed sections

### 0.4 What the mobile SDK does — and doesn't do

**Principle: the core SDK only does what must happen on the device.** Everything else lives in the backend, the dashboard, or the app owner's own server. Apps update slowly (users don't upgrade), the SDK key is public, and SDK size matters on budget Android phones — so business logic and frequently changing features must not live in the SDK.

| Layer | Responsibilities |
|---|---|
| **Core SDK** (`clikgate`, required) | Installation ID, first launch, reinstall (Keychain), opens; Play Install Referrer; pasteboard token; Universal Links / App Links / URI schemes → deep link delivery; event capture with offline queue; `identify`; push token registration and silent-push filtering (uninstall tracking); App Attest / Play Integrity; SKAN/AdAttributionKit conversion values; Apple Search Ads token; opt-out; feature flags from `/sdk/config`; **referee-side referral calls tied to this installation**: `referrals.applyCode()` and `referrals.referredBy()` |
| **Engage add-on** (`clikgate_engage`, optional) | Convenience reads and actions for apps **without their own backend**: create/get the user's referral link, "my referral stats", leaderboard top / me / around-me / opt-out, promo/offline code redemption, share helpers (system share, WhatsApp). No attribution logic; calls the same `/v1/sdk/*` endpoints using the core SDK's context |
| **Backend only** (never in any SDK) | Attribution decisions, referral qualification, hold periods, fraud rules, rewards, leaderboard ranking and finalisation, uninstall detection, alerts, reports, analytics |
| **App owner's server only** (never in any SDK) | **Identity-check signals** (hashing with the customer's secret pepper must never ship inside an app); creating referrers in bulk; server-side events for confirmed purchases; awarding rewards |

**Recommended integration path in all docs:** core SDK in the app + the app's backend calling the Clikgate control-plane API (referrers, referral stats, leaderboards, identity signals, server events) and rendering its own screens. The Engage add-on is the shortcut for apps with no backend.

Rules for whoever builds the SDKs:
- The core SDK must not import or contain code for leaderboards, referral stats, link creation, codes or sharing. CI checks this (section 20).
- The Engage add-on depends on the core SDK, never the other way round; installing core alone must not pull in Engage.
- Neither SDK computes anything the backend decides (no client-side qualification, ranking or reward logic).
- Size budgets: core Android < 150 KB, core iOS < 400 KB; Engage Android < 40 KB, Engage iOS < 80 KB.

### 1. Deliverables (changed items)

4. **Flutter plugin** `clikgate_flutter` (pub.dev) over both native core SDKs — built **in the same milestones** as each native SDK, not at the end.
4a. **Engage add-on** (0.4): `com.clikgate:clikgate-engage` (Android), `ClikgateEngage` product in the Swift package / `Clikgate/Engage` CocoaPods subspec (iOS), `clikgate_engage` (pure Dart, pub.dev), `@clikgate/react-native-engage` (pure TypeScript).
6. **Sample apps**: Flutter (primary demo), native Android, native iOS, React Native — each demonstrating direct and deferred deep links, apply code / referred-by, push-token registration, and a **sample backend** (small FastAPI or Node service) showing the recommended server-side path for referral links, stats and leaderboards. The Flutter sample also has a second variant using the Engage add-on with no backend.
7. **Docs**: integration guides per platform, `docs/REFERRALS.md`, `docs/LEADERBOARDS.md`, `docs/IDENTITY_CHECKS.md` (with hashing helper code in Python, Node, Kotlin, Swift, Dart), `docs/WHATSAPP.md`, `docs/OFFLINE_CODES.md` (incl. USSD integration example), `docs/UNINSTALL_TRACKING.md`, `docs/PRIVACY.md`, `docs/TESTING_DEEP_LINKS.md`, API reference additions.

### 5.2 SDK endpoints (Engage annotations)

`POST /v1/sdk/referrals/link`, `GET /v1/sdk/referrals/me`, `GET /v1/sdk/leaderboards/{id}`, `/me`, `/around-me`, `POST /v1/sdk/leaderboards/opt-out` and `POST /v1/sdk/codes/redeem` are marked *(Engage add-on)*: they are called only by the Engage packages. `POST /v1/sdk/referrals/apply-code` and `GET /v1/sdk/referrals/referred-by` stay core. **There is no `/v1/sdk/identity-signals` endpoint** (see 9B.3).

### 5.3 Server-to-server (customer backend → Clikgate), control-plane auth

| Method | Path | Scope | Purpose |
|---|---|---|---|
| POST | `/v1/apps/{app_id}/events` | conversions:write | Server-side events identified by `installation_id` or `customer_user_id` |
| POST | `/v1/apps/{app_id}/identify` | conversions:write | Link a customer user ID to an installation server-side (verified identity) |
| POST | `/v1/identity-signals` | identity:write | Preferred path for identity hashes (9B) |
| POST | `/v1/codes/redeem` | conversions:write | Offline/USSD/agent code redemption (9D) |

Add the new scopes `identity:write`, `identity:read` and `leaderboards:manage` to the backend's scope list and role mapping (`developer` gets all three; `viewer` gets `identity:read`).

### 9A.7 Optional hosted leaderboard page

`GET https://{program link domain}/leaderboard/{leaderboard_id}` — server-rendered, mobile-first, light page (< 40 KB) showing top entries for `visibility = sdk` boards, styled with the program's OG image and colours (`display.theme`), embeddable in a web view. `?me=<signed token>` (token minted by `/v1/sdk/leaderboards/{id}/me?embed=1`) highlights the viewer.

### 9B.3 (end) Identity signals are server-to-server only

**Server-to-server only.** There is no SDK endpoint or SDK method for identity signals: the customer's pepper must never be shipped in an app, and identity data must not travel from devices. Apps without a backend cannot use identity checks; the dashboard explains this on the feature card.

### 9E.7 SDK behaviour

`/v1/sdk/config` returns `features: {referrals: true, leaderboards: true, identity_checks: false, ...}` (only those relevant to SDKs). SDKs expose `Clikgate.isFeatureEnabled(key)` and make disabled feature calls resolve with a `feature_disabled` result without network calls. Config is refreshed on launch and at most hourly.

### 15.2 Android public API (core)

```kotlin
Clikgate.configure(context, sdkKey = "cg_sdk_...", options = ClikgateOptions(
    linkDomains = listOf("inv.myapp.com"), logLevel = LogLevel.WARN,
    environment = Environment.PRODUCTION, attestation = Attestation.PLAY_INTEGRITY_IF_AVAILABLE))

Clikgate.handleIntent(activity, intent): Boolean           // onCreate + onNewIntent
Clikgate.onDeepLink { result -> }                           // path, data, isDeferred, link, matchType, referral
Clikgate.attribution { attribution -> }  ;  suspend fun Clikgate.awaitAttribution()

Clikgate.track("purchase", revenue = ClikgateMoney(1_500_000, "NGN"), properties = mapOf("order_id" to "A-1001"))
Clikgate.identify(customerUserId = "user_42", identityToken = "...")   // null to clear
Clikgate.setTrackingEnabled(false)

// Push / uninstall
Clikgate.setPushToken(token = fcmToken, provider = PushProvider.FCM)
Clikgate.isClikgateMessage(remoteMessageData: Map<String, String>): Boolean  // call in FirebaseMessagingService.onMessageReceived; return early if true

// Referee-side referral calls (tied to this installation)
Clikgate.referrals.applyCode(programId, "ADA42") { result -> }           // referral or typed error
Clikgate.referrals.referredBy { info -> }                               // was this install referred?

Clikgate.isFeatureEnabled("referrals")
```
Link creation, referral stats, leaderboards, codes and share helpers are **not** in the core SDK — see section 17A.

### 16.2 iOS public API (core)

```swift
Clikgate.configure(sdkKey: "cg_sdk_...", options: ClikgateOptions(
    linkDomains: ["inv.myapp.com"], logLevel: .warning, environment: .production,
    pasteboardMode: .automatic,            // .off | .automatic | .pasteControlOnly
    waitForATT: false, attestation: .appAttestIfAvailable))

Clikgate.shared.handle(url: URL) -> Bool
Clikgate.shared.continue(userActivity: NSUserActivity) -> Bool
Clikgate.shared.onDeepLink { (result: ClikgateDeepLinkResult) in }   // includes .referral
let attribution = try await Clikgate.shared.attribution()

Clikgate.shared.track("purchase", revenue: ClikgateMoney(amountMinor: 1_500_000, currency: "NGN"), properties: ["order_id": "A-1001"])
Clikgate.shared.identify(customerUserId: "user_42", identityToken: "...")
Clikgate.shared.setTrackingEnabled(false)

// Push / uninstall
Clikgate.shared.setPushToken(deviceToken: Data)                       // APNs (from didRegisterForRemoteNotificationsWithDeviceToken)
Clikgate.shared.setPushToken(fcmToken: String)                        // if the app uses FCM on iOS
Clikgate.shared.handleRemoteNotification(_ userInfo: [AnyHashable: Any]) -> Bool  // true = Clikgate check; call completionHandler(.noData)

// Referee-side referral calls (tied to this installation)
let referral = try await Clikgate.shared.referrals.applyCode(programId: "rpg_...", code: "ADA42")
let info = try await Clikgate.shared.referrals.referredBy()

Clikgate.shared.isFeatureEnabled("referrals")

ClikgatePasteControl(...)   // UIPasteControl wrapper (iOS 16+) to read pasteboard tokens without the system prompt
```

### 17.1 Flutter Dart API (core)

```dart
await Clikgate.configure(sdkKey: 'cg_sdk_...', linkDomains: ['inv.myapp.com']);

Clikgate.onDeepLink.listen((ClikgateDeepLink r) => router.go(r.path ?? '/', extra: r.data));
final attribution = await Clikgate.getAttribution();

await Clikgate.track('purchase', revenue: const ClikgateMoney(1500000, 'NGN'), properties: {'order_id': 'A-1001'});
await Clikgate.identify('user_42', identityToken: token);
await Clikgate.setTrackingEnabled(false);

// Push / uninstall (works with firebase_messaging)
await Clikgate.setPushToken(await FirebaseMessaging.instance.getToken(), provider: PushProvider.fcm);
FirebaseMessaging.instance.onTokenRefresh.listen((t) => Clikgate.setPushToken(t, provider: PushProvider.fcm));
// In the background handler and onMessage:
if (Clikgate.isClikgateMessage(message.data)) return;

// Referee-side referral calls (tied to this installation)
final referral = await Clikgate.referrals.applyCode(programId: 'rpg_...', code: 'ADA42');
final info = await Clikgate.referrals.referredBy();

Clikgate.isFeatureEnabled('referrals');
```

17.2 (changed bullet): Example app: product deep link, apply-code screen, referred-by banner, push token registration with `firebase_messaging`. Invite, stats and leaderboard screens are in the two variants described in 17A.4.

## 17A. Engage add-on (optional)

For apps **without their own backend**. Apps with a backend should call the control-plane API from their server instead (0.4).

### 17A.1 Packages
| Platform | Package | Implementation |
|---|---|---|
| Android | `com.clikgate:clikgate-engage` | Kotlin module depending on `clikgate-android` |
| iOS | `ClikgateEngage` (SPM product) / `Clikgate/Engage` (pod subspec) | Swift module depending on core |
| Flutter | `clikgate_engage` | **Pure Dart** (no native code), depends on `clikgate_flutter` |
| React Native | `@clikgate/react-native-engage` | Pure TypeScript, depends on `@clikgate/react-native` |

The core SDK exposes a small, documented-as-internal **request context** (`installation_id`, SDK key, environment, base URL, current identity token) that Engage uses to call `/v1/sdk/*`. Engage keeps no attribution state of its own.

### 17A.2 API (same shape on every platform; Dart shown)
```dart
final engage = ClikgateEngage();

// Referrer side
final link = await engage.referrals.createLink(programId: 'rpg_...', displayName: 'Ada');   // code, url, shortUrl
final stats = await engage.referrals.myStats(programId: 'rpg_...');                        // invited, installed, qualified
await engage.share.system(text: 'Join me on MyApp: ${link.url}');
await engage.share.whatsApp(text: 'Join me on MyApp: ${link.url}');                        // WhatsApp if installed, else share sheet

// Leaderboards (build your own UI)
final page = await engage.leaderboards.top('lb_...', period: LeaderboardPeriod.current, limit: 50);
final me = await engage.leaderboards.me('lb_...');            // rank, score, pending, gapToNext, periodEndsAt
final around = await engage.leaderboards.aroundMe('lb_...', radius: 5);
await engage.leaderboards.setOptOut(programId: 'rpg_...', optOut: true);
final embedUrl = await engage.leaderboards.hostedPageUrl('lb_...'); // signed URL for the hosted page (9A.7) in a web view

// Codes typed in the app (promo/offline codes)
final redemption = await engage.codes.redeem('LAGOS50');
```
Kotlin/Swift/TS mirror these names (`ClikgateEngage.referrals.createLink(...)`, etc.). Share helpers on iOS need `LSApplicationQueriesSchemes` → `whatsapp`; on Android use an `ACTION_SEND` intent with package `com.whatsapp`, falling back to the chooser.

### 17A.3 Rules
- Every call checks `Clikgate.isFeatureEnabled(...)` first and returns a typed `feature_disabled` result without a network call.
- Calls that act on behalf of a user require an identified installation; if the program has `require_identity_token`, they fail with `identity_required` until `identify()` was called with a valid token.
- Read results may be cached in memory for 60 s; nothing is persisted to disk.
- No retries beyond one for network errors (these are interactive calls); errors surface as typed exceptions.
- No UI components: apps render their own screens.

### 17A.4 Samples
- **Recommended variant**: Flutter sample + sample backend; the backend calls `/v1/referral-programs/{id}/referrers`, `/v1/leaderboards/{id}/entries`, `/v1/leaderboards/{id}/referrers/{id}` and returns data to the app.
- **No-backend variant**: Flutter sample using `clikgate_engage` for invite, stats, leaderboard and promo-code screens.

## 18. React Native package

Same surface as Flutter (TypeScript): `configure`, `onDeepLink`, `getAttribution`, `track`, `identify`, `setTrackingEnabled`, `setPushToken`, `isClikgateMessage`, `referrals.{applyCode, referredBy}`, `isFeatureEnabled`. Engage features live in `@clikgate/react-native-engage` (17A). Expo config plugin for associated domains, intent filters, background modes. Early-event buffering. Example app.

### 19. Milestones (changed items)

10. **Android core SDK + Flutter plugin (Android side) + Flutter example on Android + native Android sample** — device responsibilities only (0.4): attribution, deep links, events, identify, applyCode/referredBy, push token and message filtering.
11. **iOS core SDK + Flutter plugin (iOS side) + Flutter example on iOS + native iOS sample** — Universal Links, pasteboard, Keychain, attribution, events, identify, applyCode/referredBy, push token and remote notification filtering.
11a. **Engage add-on** on all four platforms + sample backend + both Flutter sample variants (17A).
14. **React Native core package + Expo plugin + example** (Engage TS package built in 11a once RN core exists, otherwise here).

### 20. Definition of done (new items)

- The core SDKs contain no leaderboard, referral-stats, link-creation, code or share code, and no identity-signal API (checked in CI by a public-API snapshot test and a dependency check that core never depends on Engage); size budgets in 0.4 are met.
- The Flutter example's leaderboard screen shows live ranks and "my rank"; a final weekly snapshot matches a full recomputation.

---

## What this means for the current code (written for the builders)

1. **Split Engage out of core on all four platforms.** Today the core SDKs contain
   `referrals.createLink` (`/v1/sdk/referrals/link`), `referrals.myStats`/`me`
   (`/v1/sdk/referrals/me`), `referrals.shareToWhatsApp`, `leaderboards.*`, `codes.redeem`.
   Move them into new Engage packages (17A.1) with the 17A.2 names
   (`engage.referrals.createLink/myStats`, `engage.share.system/whatsApp`,
   `engage.leaderboards.top/me/aroundMe/setOptOut/hostedPageUrl`, `engage.codes.redeem`). Core
   keeps `isFeatureEnabled`, `referrals.applyCode`, `referrals.referredBy` and exposes the internal
   request context. Flutter's Engage is pure Dart (HTTP from Dart using the context obtained
   from the native core through the plugin), RN Engage pure TS (same idea).
2. **No SDK identity signals.** Remove `POST /v1/sdk/identity-signals` from the backend, contract
   and docs (no SDK implemented a method for it). The `identity_checks.config.accept_from_sdk`
   option goes away.
3. **Scopes**: `developer` gets identity:read/write + leaderboards:manage; `viewer` gets
   `identity:read` (check `src/auth/utils/scopes.py`).
4. **`hostedPageUrl`** needs a URL: `/v1/sdk/leaderboards/{id}/me?embed=1` should also return
   `embed_url` (`https://{program link domain}/leaderboard/{id}?me=<token>`).
5. **Engage rules (17A.3)** differ from what core v3 did: 60 s in-memory read cache, at most one
   retry for network errors.
6. **CI checks**: public-API snapshot tests per core SDK, a dependency check (core never depends on
   Engage), and size budgets (core Android < 150 KB, core iOS < 400 KB, Engage < 40 KB / < 80 KB).
7. **Samples**: a sample backend (FastAPI or Node) for the recommended server-side path, and two
   Flutter example variants (with backend; no-backend with `clikgate_engage`); native Android,
   iOS and RN samples show deep links, apply code / referred-by and push token registration.
8. **Backend Part 2 test mode** (`../../../clikgate_api/docs/spec/clikgate-backend-part2-spec.md`)
   introduces SDK keys `cg_sdk_live_*` / `cg_sdk_test_*` — SDKs must accept both (don't validate
   the old `cg_sdk_` + random shape too strictly).
