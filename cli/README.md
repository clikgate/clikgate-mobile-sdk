# @clikgate/setup

Set up [Clikgate](https://clikgate.com) in your app project with one command: Flutter, React Native, Expo, Android or iOS.

```sh
npx @clikgate/setup          # set up (shows every change and asks first)
npx @clikgate/setup doctor   # check an existing setup; changes nothing
npx @clikgate/setup website  # a website: the web script and, with your own server, the /cg/keep route
```

What it does:
- detects the project;
- signs in through your browser;
- picks or creates your Clikgate app;
- adds the SDK and the start-up code;
- configures app links: your app's link subdomain (`yourapp.ciz.to`) and custom domains in every build, the test subdomain `yourapp.dev.ciz.to` in **debug builds only**, never a shared domain (`ciz.to`, `clk.ng`, `clkg.to`, `dev.ciz.to`);
- sends your app's signing details to Clikgate;
- checks that events arrive.

Every file change is shown as a diff before anything is written. It uses only your **test** SDK key and never handles live keys.

- `--dry-run` shows the plan and the diffs and changes nothing.
- `--yes` applies without asking (the diffs are still printed).
- Offline, without signing in (for AI assistants and CI): `npx @clikgate/setup --sdk-key cg_sdk_test_… --domain ciz.to,go.yourbrand.com`.
- `doctor --json` prints a machine-readable report (schema: `schema/doctor-report.schema.json`).

Websites: `website` finds the Clikgate script tag (or adds it to your layout) and detects your server from its package files (Next.js, Express, Laravel, Django, Spring Boot, ASP.NET Core); when it can't tell, it asks "Does your website have its own server?". With a server it adds the `/cg/keep` route and `data-server-endpoint="/cg/keep"`. Safari, and every browser on iPhone, keeps a click ID saved by a script for up to 7 days (sometimes less). When your server saves it, it lasts as long as you choose, up to the browser's limit. WordPress and Shopify need no route: the Clikgate plugin and app keep the click ID themselves. `--website-server <nextjs|express|laravel|django|spring-boot|aspnet-core|wordpress|shopify|none>` skips detection and the question; `--web-key cgw_test_…` sets the key for a new tag.

Exit codes: 0 success, 1 problems found or a step failed, 2 cancelled, 3 sign-in failed.

Node.js 18 or newer. No telemetry. MIT licence. Docs: https://clikgate.com/docs/setup-command
