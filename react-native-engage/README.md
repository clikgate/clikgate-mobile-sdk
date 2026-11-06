# @clikgate/react-native-engage

Optional **Engage add-on** for [`@clikgate/react-native`](../react-native):
referral links and stats, share helpers (system share sheet, WhatsApp), leaderboards and promo / offline
code redemption, for apps **without their own backend**.

Apps with a backend should not use it: call the Clikgate control-plane API from your server (referrers,
referral stats, leaderboards) and render your own screens — see [docs/engage.md](../docs/engage.md).

- Pure TypeScript: no native code, nothing to link, no extra pod or Gradle module.
- Uses the core SDK's request context (installation id, SDK key, base URL, identity token) and calls the
  same `/v1/sdk/...` endpoints. No attribution state, no UI components.

```sh
npm install @clikgate/react-native @clikgate/react-native-engage
```

```ts
import { Clikgate } from '@clikgate/react-native';
import { ClikgateEngage } from '@clikgate/react-native-engage';

const engage = new ClikgateEngage();
await Clikgate.identifyUser({ customerId: 'user_42', identityToken }); // referrer-side calls need identifyUser

const link = await engage.referrals.createLink({ programId: 'rpg_...', displayName: 'Ada' });
const stats = await engage.referrals.myStats({ programId: 'rpg_...' });
await engage.share.referralLink(link, { message: 'Join me on MyApp:' }); // share menu, a version of the link per app
await engage.share.link('https://inv.myapp.com/summer', { app: ShareApp.WhatsApp }); // menu if no WhatsApp

const page = await engage.leaderboards.top('lb_...', { period: 'current', limit: 50 });
const me = await engage.leaderboards.me('lb_...');
const around = await engage.leaderboards.aroundMe('lb_...', { radius: 5 });
await engage.leaderboards.setOptOut({ programId: 'rpg_...', optOut: true });
const hostedUrl = await engage.leaderboards.hostedPageUrl('lb_...'); // for a WebView

const redemption = await engage.codes.redeem('LAGOS50');
```

Rules: `feature_disabled` without a network call when the feature is switched off; `not_identified`
before `Clikgate.identifyUser` for user calls; reads cached in memory for 60 s (writes and `clearCache()`
drop it); one retry for network errors only; failures are `ClikgateError`s from the core package.
Full guide: [docs/react-native.md](../docs/react-native.md) section 5b.

## Development

```sh
(cd ../react-native && npm ci)
npm run devlink    # node_modules -> ../react-native/node_modules (or `npm install`)
npm test && npm run typecheck && npm run lint
(cd ../react-native && npm run build:lib) && npm run build
```

`api/public-api.txt` is the checked-in public-API snapshot (`UPDATE_API_SNAPSHOT=1 npx jest publicApi`).
