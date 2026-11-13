# Engage features vs the backend path

Each Clikgate SDK is one package with two layers (spec v3, sections 0.4 and 17A; one package per
platform since 2.1.0, owner decision 2026-11-12):

| Layer | Where | What it does |
|---|---|---|
| **Core SDK** | `com.clikgate:clikgate-android`, `Clikgate` (SPM product / pod), `clikgate_flutter`, `@clikgate/react-native` | Only what must happen on the device: installation id, first launch / reinstall / opens, Play Install Referrer, pasteboard token, deep links (direct + deferred), events with an offline queue, `identify`, push token + uninstall-check filtering, attestation, SKAN values, Apple Search Ads token, opt-out, feature switches, and the referee-side referral calls `referrals.applyCode` / `referrals.referredBy`. |
| **Engage features** (use them only without a backend) | In the same packages: `com.clikgate.engage` (Android), the `ClikgateEngage` module of the `Clikgate` SPM product (`import ClikgateEngage`; with CocoaPods it's in the `Clikgate` module), `package:clikgate_flutter/engage.dart` (Dart, plus the plugin's share-menu channel), `ClikgateEngage` exported by `@clikgate/react-native` (TypeScript, plus a share-menu TurboModule) | Convenience reads and actions for apps **without their own backend**: the user's referral link, "my referral stats", leaderboards (top / me / around me / opt-out / hosted page URL), promo/offline code redemption, share helpers (share a link with a version per app, system share sheet, WhatsApp). |

Engage uses the core, never the other way round: the core code never calls Engage, and an app that
doesn't call Engage doesn't ship it (R8, the iOS linker and Dart tree-shaking drop unused code). There
is nothing extra to install. Neither layer decides anything the backend decides (qualification,
ranking, rewards, fraud).

## Which one should I use?

**Your app has a backend → don't use Engage.** This is the recommended path in every guide:

1. The app uses the core SDK (deep links, attribution, events, `identify`, apply code /
   referred-by, push token).
2. Your backend calls the Clikgate control-plane API with an API key and returns what your screens
   need:
   - referral links and stats: `/v1/referral-programs/{id}/referrers` (create / get a referrer for
     your user id, its code, URL and counts);
   - leaderboards: `/v1/leaderboards/{id}/entries` and `/v1/leaderboards/{id}/referrers/{id}`;
   - identity checks: `POST /v1/identity-signals` (server-to-server only, see below);
   - confirmed purchases and other goals from your server: `POST /v1/goals/events` (with the app's
     `installation_id` from `getInstallationId()`, or the customer ID);
   - offline / USSD / agent codes: `POST /v1/codes/redeem`.
3. The app renders its own screens from your backend's responses.

**Trophies, challenges and progress are server-only.** Leaderboard trophies and winners, progress
bands (`progress_pct`, `gap_to_target`), challenges, their results and opt-in joining are not in any
SDK, core or Engage, and they never will be. Read them on your server (`/v1/leaderboards/{id}/trophy`,
`/v1/leaderboards/{id}/entries`, `/v1/challenges/...`; join opt-in challenges with
`POST /v1/challenges/{id}/participants`), react to the `leaderboard.target_reached` and `challenge.*`
webhooks, and show them in your own screens. Clikgate never messages participants: you decide how
to tell and reward them. The Engage leaderboard calls below stay as they are, without these fields.

Why: your server can authenticate the user properly, cache, combine with your own data, and change
without an app release (apps update slowly; the SDK key is public).

**Your app has no backend → use Engage.** It calls the same `/v1/sdk/*` endpoints the old core
methods used, with the core SDK's installation context, so you can build invite, stats,
leaderboard and promo-code screens without a server:

```dart
final engage = ClikgateEngage();
final link = await engage.referrals.createLink(programId: 'rpg_...', displayName: 'Ada');
final stats = await engage.referrals.myStats(programId: 'rpg_...');
await engage.share.referralLink(link, message: 'Join me on MyApp:');   // each app gets its own version
final page = await engage.leaderboards.top('lb_...', period: LeaderboardPeriod.current, limit: 50);
final me = await engage.leaderboards.me('lb_...');
final around = await engage.leaderboards.aroundMe('lb_...', radius: 5);
await engage.leaderboards.setOptOut(programId: 'rpg_...', optOut: true);
final embedUrl = await engage.leaderboards.hostedPageUrl('lb_...');   // hosted page for a web view
final redemption = await engage.codes.redeem('LAGOS50');
```

Kotlin (`ClikgateEngage.referrals.createLink(...)`, callback + `suspend`), Swift
(`ClikgateEngage.referrals.createLink(programId:displayName:)`, async + completion) and TypeScript
(`new ClikgateEngage().referrals.createLink({programId, displayName})`) use the same names. Setup
per platform: [android.md](android.md) (6d), [ios.md](ios.md) (7b), [flutter.md](flutter.md) (5d),
[react-native.md](react-native.md) (5b).

Things Engage cannot do: anything that needs a secret (creating referrers in bulk, awarding
rewards, server events for confirmed purchases) and identity checks.

## Engage behaviour

- **Feature switches.** Every call first checks `Clikgate.isFeatureEnabled(...)` (`referrals`,
  `leaderboards`, `offline_codes`) and fails with `feature_disabled` without a network call.
- **Identity.** Calls on behalf of a user (link, stats, my rank, around me, opt-out, hosted page)
  need `Clikgate.identifyUser(...)` first (`not_identified` otherwise, no network call). Programs with
  `require_identity_token` answer `identity_required` until `identify` got a valid identity token
  from a backend, so apps without one should leave `require_identity_token` off.
- **Caching.** Read results are kept in memory for 60 s (per installation, user and request);
  nothing is written to disk. Writes (`createLink`, `setOptOut`, `redeem`) clear the cache, and
  `clearCache()` does it on demand (e.g. pull-to-refresh). The hosted page URL is never cached.
- **Errors and retries.** Errors are the core SDK's typed error (`ClikgateError` /
  `ClikgateException`) with the backend code (`referrer_not_found`, `leaderboard_not_found`,
  `code_expired`, `rate_limited`, ...). These are interactive calls: at most one retry, and only
  for network errors; nothing is queued.
- **No UI.** Engage has no screens or widgets; apps render their own.
- **Share a link (Change 13).** `share.link(url, message?, app?, shareUrls?)` and
  `share.referralLink(link, message?, app?)` open the phone's share menu (or one app): each app Clikgate knows gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps get the plain link, and the share is recorded as a share count (the app and the link; no personal data, never a click),
  with `POST /v1/share-events` and the SDK key. Referral links keep the referral code. Apps with a
  backend can pass the link's `share_urls` from the Clikgate API instead. `ShareApp` names the apps.
  Flutter and React Native use the native Engage share menu through a small bridge in their plugin.
- **Share helpers.** `share.system(text)` opens the share sheet; `share.whatsApp(text)` opens
  WhatsApp when installed and otherwise the share sheet, and tells you which happened. iOS apps
  should list `whatsapp` in `LSApplicationQueriesSchemes` (Info.plist) so the SDK can detect it.

## Identity signals are server-to-server only

There is no SDK endpoint or method for identity-check signals: hashing with your secret pepper
must never ship inside an app, and identity data must not travel from devices. Send them from your
backend with `POST /v1/identity-signals`. Apps without a backend can't use identity checks.

## How Engage talks to the core (for SDK maintainers)

The core exposes a small internal request context (installation id, SDK key, environment, base
URL, identity token, user id, version headers) and an error report-back; Engage gets a fresh
context per call and reports `feature_disabled` / invalid-key / kill-switch / unknown-installation
answers back so the core reacts as it does for its own calls. Details:
[shared/SDK_BEHAVIOUR.md](../shared/SDK_BEHAVIOUR.md) ("Core SDK vs Engage features") and
[shared/PLATFORM_CHANNEL.md](../shared/PLATFORM_CHANNEL.md) ("Engage split"). CI checks the split
with `scripts/check_sdk_boundaries.sh` (public-API snapshots, "no Engage API in core", "core code
never uses Engage", size budgets for core and Engage separately).
