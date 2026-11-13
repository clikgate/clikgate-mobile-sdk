# Clikgate sample backend

A minimal "app backend" (FastAPI, Python 3.12) for the **recommended integration path**
(spec 0.4 / 17A.4): the mobile app uses only the core Clikgate SDK, and its own server calls the
Clikgate control-plane API with an API key for everything on the referrer side. The API key and
the app's identity secret stay on this server; the app never sees them.

The Flutter example's backend variant (`flutter/example`, `CLIKGATE_VARIANT=backend`) talks to
this service. Apps without a backend use the SDKs' Engage features instead ([docs/engage.md](../../docs/engage.md)).

## API (what the app calls)

All `/me`, `/leaderboards` and `/orders` routes need `Authorization: Bearer <session_token>`.
Errors are `{"error": {"code", "message"}}`; Clikgate's codes are passed through
(`referrer_not_found`, `leaderboard_not_found`, ...), Clikgate auth or server failures become
502 (`clikgate_unavailable` when it can't be reached).

| Route | Does | Clikgate call (server-side) |
|---|---|---|
| `POST /auth/demo-login {user_id, display_name?}` | Demo sign-in, **no password**: replace with your real auth. Returns `customer_user_id`, `session_token` and an **identity token** for `Clikgate.identifyUser(customerId: userId, identityToken:)` | none (token signed locally) |
| `POST /auth/identity-token` | A fresh identity token (30 days by default; the app passes the newest one). Return it from your "current user" route too | none |
| `GET /me/referral-link` | Get-or-create the user's referrer: `code`, `url` (code URL), `short_url`, `referrer_id` | `POST /v1/referral-programs/{id}/referrers` |
| `GET /me/referral-stats` | `clicks`, `installs`, `signups`, `in_progress`, `qualified`, `disqualified`, `rejected` (404 `referrer_not_found` before the first link) | `GET /v1/referral-programs/{id}/referrers/by-user/{user}` |
| `GET /leaderboards/{id}?period=&limit=20` | Board name, metric, period, top entries (live ranks; the user's row has `is_me: true`; opted-out referrers removed) | `GET /v1/leaderboards/{id}` (cached 5 min), `GET /v1/leaderboards/{id}/entries` |
| `GET /leaderboards/{id}/me?period=` | The user's standing: `rank` (null = not ranked), `score`, `pending`, `gap_to_next`, `best_rank`, `opted_out`, `period_ends_at` | `GET /v1/leaderboards/{id}/referrers/{referrer_id}` |
| `GET /leaderboards/{id}/around-me?radius=2` | Entries around the user | `GET /v1/leaderboards/{id}/entries/around/{referrer_id}` |
| `POST /orders {order_id?, amount_minor, currency, installation_id?, platform?}` | A confirmed purchase, sent from this server as the `purchase` goal (`reference = order-<order_id>`, also the `Idempotency-Key`; value converted to normal units; `provider: custom`). Credited to the installation (`app_id` + `installation_id` from the app's `getInstallationId()`), else to the customer ID | `POST /v1/goals/events` |
| `GET /health` | Liveness | none |

The shapes of `/leaderboards/*` mirror the SDK's Engage models (`leaderboard_page`, `my_rank`), so
an app can switch between the two paths without changing its screens.

Identity token (as Clikgate verifies it, `clikgate_api` `src/sdk/utils/identity_tokens.py`):

```
issued_at      = unix seconds
identity_token = base64url_nopad(HMAC_SHA256(identity_secret, "<customer_user_id>.<issued_at>")) + "." + issued_at
```

With a Clikgate server SDK this is one line: Node `createIdentityToken`, Python `create_identity_token`, PHP
`\Clikgate\IdentityToken::create`, Java / .NET `IdentityTokens.create` / `Create` (they read
`CLIKGATE_IDENTITY_SECRET`, or `CLIKGATE_IDENTITY_SECRETS` for several apps). The secret stays on the server; the app
never makes tokens. Without tokens (identity Path B), the app sends its `getInstallationId()` with the sign-in request
and the server calls the server SDK's `identifyUser({appId, installationId, customerId, label?})`. Guide:
https://clikgate.com/docs/identify-users

Leaderboard ids are restricted to `CLIKGATE_LEADERBOARD_IDS` (404 for others) so the app can't
read arbitrary boards through your API key. The user's referrer id and board metadata are cached
in memory; a real backend would store the referrer id with its user record.

## Run

```sh
cd samples/backend
python3.12 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
cp .env.example .env          # fill in the API key, identity secret, program, leaderboard, app id
.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8080
```

Settings (environment or `.env`, see [.env.example](.env.example)): `CLIKGATE_API_KEY`
(scopes `links:write`, `links:read`, `analytics:read`, `conversions:write`),
`CLIKGATE_IDENTITY_SECRET` (`POST /v1/apps/{app_id}/identity-secret/rotate`),
`CLIKGATE_PROGRAM_ID`, `CLIKGATE_LEADERBOARD_IDS`, `CLIKGATE_APP_ID` (or
`CLIKGATE_APP_ID_ANDROID` / `_IOS`), `CLIKGATE_API_URL` (default `https://api.clikgate.com`; a
local `clikgate_api` is `http://localhost:8000`), `SESSION_SECRET`.

From the Android emulator the backend is `http://10.0.2.2:8080`, from the iOS simulator
`http://localhost:8080`.

Try it:

```sh
TOKEN=$(curl -s -X POST localhost:8080/auth/demo-login -H 'content-type: application/json' \
  -d '{"user_id":"user_42","display_name":"Ada"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_token"])')
curl -s localhost:8080/me/referral-link -H "Authorization: Bearer $TOKEN"
curl -s localhost:8080/leaderboards/lb_... -H "Authorization: Bearer $TOKEN"
curl -s -X POST localhost:8080/orders -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"order_id":"A-1001","amount_minor":1500000,"currency":"NGN"}'
```

Docker:

```sh
docker build -t clikgate-sample-backend samples/backend
docker run --rm --env-file samples/backend/.env -p 8080:8080 clikgate-sample-backend
```

## Tests

```sh
.venv/bin/python -m pytest
```

The tests run the app against a fake Clikgate control plane (`httpx.MockTransport`,
`tests/conftest.py`): identity-token format, sessions, get-or-create referrers with the server's
API key, stats, live leaderboard ranks and "my rank", the leaderboard allowlist, server-side
order events and error mapping. No network.

## Files

- `app/main.py`: routes (`create_app(settings, clikgate_client)`).
- `app/clikgate.py`: control-plane client (API key auth, error decoding).
- `app/tokens.py`: identity tokens and the demo session tokens.
- `app/config.py`: settings.
