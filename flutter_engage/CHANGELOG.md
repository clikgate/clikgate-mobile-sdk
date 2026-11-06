## Unreleased

### Share a link, a version per app (Engage)
- `ClikgateEngage.share.link(...)` and `share.referralLink(...)`: the share menu (or one app) with a Clikgate link; each app gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps the plain link, and the share is recorded with `POST /v1/share-events` (no personal data). `ShareApp` names the apps. Referral links keep the code; `shareUrls` takes the API's `share_urls`. clikgate_engage now has a small Android / iOS plugin (MethodChannel `com.clikgate/engage`, method `shareLink`) over the native Engage add-on; everything else is still Dart. Ships in 1.0.0 if that is still unpublished.

## 1.0.0

- First release of the optional Engage add-on, split out of
  `clikgate_flutter` 1.0.0: `referrals.createLink` / `myStats`, `share.system` / `whatsApp`,
  `leaderboards.top` / `me` / `aroundMe` / `setOptOut` / `hostedPageUrl`, `codes.redeem`,
  `clearCache`.
- Pure Dart (`http`, `share_plus`, `url_launcher`); gets the installation's request context from
  `clikgate_flutter`. 60 s in-memory read cache, at most one retry on network errors.
