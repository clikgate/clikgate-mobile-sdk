# Changelog

## Unreleased

### Share a link, a version per app (Engage)
- `ClikgateEngage.share.link(...)` and `share.referralLink(...)`: the share menu (or one app) with a Clikgate link; each app gets its own version of the link (a short ending so Clikgate knows where you shared it), other apps the plain link, and the share is recorded with `POST /v1/share-events` (no personal data). `ShareApp` names the apps. Referral links keep the code; `shareUrls` takes the API's `share_urls`. The package now contains a TurboModule `ClikgateEngage` (one method, `shareLink`) over the native Engage add-on (`com.clikgate:clikgate-engage`, `Clikgate/Engage`); rebuild the app after installing. Ships in 1.0.0 if that is still unpublished.

## 1.0.0 (unreleased)

- First version: `ClikgateEngage` with `referrals.{createLink, myStats}`,
  `share.{system, whatsApp}`, `leaderboards.{top, me, aroundMe, setOptOut, hostedPageUrl}`,
  `codes.redeem`, `clearCache()`. Pure TypeScript over `@clikgate/react-native` (request context via
  `Clikgate.getRequestContext()`), 60 s in-memory read cache, one retry for network errors.
