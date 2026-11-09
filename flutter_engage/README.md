# clikgate_engage

Optional **Engage add-on** for Flutter apps that use [Clikgate](https://clikgate.com) and have
**no backend of their own**: the user's referral link and stats, leaderboards, promo / offline
code redemption and share helpers (system share sheet, WhatsApp).

> Apps with a backend should use the recommended path instead: the core plugin
> (`clikgate_flutter`) in the app, and the app's server calling the Clikgate control-plane API
> (referrers, referral stats, leaderboards, identity signals, server events) and rendering its
> own screens. See `docs/engage.md` in the repository.

Engage is pure Dart. It contains no attribution logic and keeps no state of its own: it calls
the same `/v1/sdk/*` endpoints as the native SDKs with the request context (installation id,
SDK key, environment, base URL, identity token) of the core plugin.

## Install

```yaml
dependencies:
  clikgate_flutter: ^2.0.0
  clikgate_engage: ^2.0.0
```

Configure the core plugin first (`Clikgate.configure(...)`, see `clikgate_flutter`).

## Use

```dart
final engage = ClikgateEngage();

await Clikgate.identifyUser(customerId: 'user_42', identityToken: token);   // core plugin
final link = await engage.referrals.createLink(programId: 'rpg_...', displayName: 'Ada');
final stats = await engage.referrals.myStats(programId: 'rpg_...');
await engage.share.referralLink(link, message: 'Join me on MyApp:');   // share menu, a version of the link per app
await engage.share.link('https://inv.myapp.com/summer', app: ShareApp.whatsapp);   // true = WhatsApp opened

final page = await engage.leaderboards.top('lb_...', period: LeaderboardPeriod.current, limit: 50);
final me = await engage.leaderboards.me('lb_...');
final around = await engage.leaderboards.aroundMe('lb_...', radius: 5);
await engage.leaderboards.setOptOut(programId: 'rpg_...', optOut: true);
final embedUrl = await engage.leaderboards.hostedPageUrl('lb_...');   // for a web view

final redemption = await engage.codes.redeem('LAGOS50');
```

## Rules

- Every network call checks `Clikgate.isFeatureEnabled` first; a switched-off feature throws
  `ClikgateException(feature_disabled)` without a network call.
- Calls acting for the user (link, stats, my rank, around me, opt-out, hosted page) throw
  `not_identified` until `Clikgate.identifyUser` was called. If the program requires a verified
  identity token, the server answers `identity_required`.
- Reads (stats, top, me, around me) are cached in memory for 60 s; writes clear the cache;
  `clearCache()` drops it. Nothing is persisted.
- At most one retry, for network errors only. Errors are `ClikgateException`s (`code`,
  `status`, `param`, `feature`, `offlineTouchId`).
- No UI components.

## Platform setup for sharing

- **`share.link` / `share.referralLink`** use the native Engage add-on's share menu through this
  package's small Android / iOS plugin (dependencies `com.clikgate:clikgate-engage` and
  `Clikgate/Engage`, added for you). Each app gets its own version of the link (a short ending so
  Clikgate knows where you shared it) and the share is recorded. Nothing to configure.

- **iOS**: nothing required (`url_launcher` opens `whatsapp://send` with `UIApplication.open`,
  no `canOpenURL` check). Listing `whatsapp` in `LSApplicationQueriesSchemes` is recommended for
  consistency with the native SDK.
- **Android**: nothing required. `whatsapp://send` is opened with `url_launcher`
  (`launchUrl`, which needs no `<queries>` entry); if WhatsApp isn't installed the system share
  sheet (`share_plus`) is shown.

## Development (monorepo)

`pubspec_overrides.yaml` points `clikgate_flutter` at `../flutter`; it is excluded from the
published archive (`.pubignore`). Publish `clikgate_flutter` first, then this package.
