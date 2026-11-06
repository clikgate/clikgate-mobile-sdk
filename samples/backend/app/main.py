"""Sample "app backend" for the Clikgate recommended integration path (spec 0.4 / 17A.4).

The mobile app uses only the core Clikgate SDK. Everything the referrer side needs (invite link,
referral stats, leaderboards) and confirmed purchases go through this server, which calls the
Clikgate control-plane API with its API key. The API key and the identity secret never leave
the server.

Run: `uvicorn app.main:app --port 8080` (settings from the environment or `.env`).
"""

import re
import time
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, Query, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from .clikgate import ClikgateClient, ClikgateError
from .config import Settings
from .tokens import Session, create_session_token, read_session_token, sign_identity_token

USER_ID = re.compile(r"^[A-Za-z0-9_.@:-]{1,64}$")
STAT_KEYS = ("clicks", "installs", "signups", "in_progress", "qualified", "disqualified", "rejected")
BOARD_META_TTL = 300.0


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        self.status, self.code, self.message = status, code, message


# ------------------------------------------------------------------ request bodies


class DemoLoginBody(BaseModel):
    user_id: str = Field(min_length=1, max_length=64)
    display_name: str | None = Field(default=None, max_length=100)


class OrderBody(BaseModel):
    order_id: str | None = Field(default=None, max_length=64)
    amount_minor: int = Field(ge=0)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    # Optional: the SDK installation id, to tie the event to this device's install too
    installation_id: str | None = Field(default=None, max_length=36)
    # android | ios: picks CLIKGATE_APP_ID_ANDROID / _IOS when set
    platform: str | None = Field(default=None, pattern=r"^(android|ios)$")


# ------------------------------------------------------------------ helpers


def _period(entries_or_standing: dict[str, Any]) -> dict[str, Any]:
    return {
        "key": entries_or_standing.get("period"),
        "status": entries_or_standing.get("status"),
        "starts_at": entries_or_standing.get("starts_at"),
        "ends_at": entries_or_standing.get("ends_at") or entries_or_standing.get("period_ends_at"),
    }


def _entries(raw: dict[str, Any], my_referrer_id: str | None) -> list[dict[str, Any]]:
    # The owner API lists opted-out referrers (flagged); the app must not show them.
    return [
        {
            "rank": e["rank"],
            "referrer_id": e["referrer_id"],
            "display": e["display"],
            "score": e["score"],
            "pending": e.get("pending"),
            "is_me": e["referrer_id"] == my_referrer_id,
        }
        for e in raw.get("entries", [])
        if not e.get("opted_out")
    ]


def create_app(settings: Settings | None = None, clikgate: ClikgateClient | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    client = clikgate or ClikgateClient(settings.clikgate_api_url, settings.clikgate_api_key)
    # In-memory caches (a real backend would store the referrer id with its user record).
    referrer_ids: dict[str, str] = {}
    board_meta: dict[str, tuple[float, dict[str, Any]]] = {}

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        yield
        await client.aclose()

    app = FastAPI(title="Clikgate sample backend", version="1.0.0", lifespan=lifespan)

    @app.exception_handler(ApiError)
    async def _api_error(_: Request, e: ApiError) -> JSONResponse:
        return JSONResponse({"error": {"code": e.code, "message": e.message}}, status_code=e.status)

    @app.exception_handler(ClikgateError)
    async def _clikgate_error(_: Request, e: ClikgateError) -> JSONResponse:
        # Pass Clikgate's error code through (referrer_not_found, leaderboard_not_found, ...), but
        # never its auth failures as-is: a bad API key is this server's problem, not the user's.
        status = 502 if e.status in (401, 403) or e.status >= 500 else e.status
        return JSONResponse({"error": {"code": e.code, "message": e.message}}, status_code=status)

    def current_user(authorization: Annotated[str | None, Header()] = None) -> Session:
        scheme, _, token = (authorization or "").partition(" ")
        session = (
            read_session_token(settings.session_secret, token, settings.session_ttl_seconds)
            if scheme.lower() == "bearer" and token
            else None
        )
        if session is None:
            raise ApiError(401, "unauthenticated", "Sign in first (POST /auth/demo-login).")
        return session

    User = Annotated[Session, Depends(current_user)]

    async def my_referrer_id(user: Session) -> str:
        cached = referrer_ids.get(user.user_id)
        if cached:
            return cached
        referrer = await client.referrer_by_user(settings.clikgate_program_id, user.user_id)
        referrer_ids[user.user_id] = referrer["id"]
        return referrer["id"]

    def check_board(leaderboard_id: str) -> None:
        if not settings.leaderboard_allowed(leaderboard_id):
            raise ApiError(404, "leaderboard_not_found", "Unknown leaderboard.")

    async def meta(leaderboard_id: str) -> dict[str, Any]:
        hit = board_meta.get(leaderboard_id)
        if hit and time.monotonic() - hit[0] < BOARD_META_TTL:
            return hit[1]
        board = await client.leaderboard(leaderboard_id)
        metric = board.get("metric") or {}
        value = {"name": board.get("name"), "metric": metric.get("type") if isinstance(metric, dict) else metric}
        board_meta[leaderboard_id] = (time.monotonic(), value)
        return value

    # -------------------------------------------------------------- routes

    @app.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.post("/auth/demo-login")
    async def demo_login(body: DemoLoginBody) -> dict[str, Any]:
        """Demo sign-in: no password. Replace with your real authentication.

        Returns this backend's session token and a Clikgate identity token; the app calls
        `Clikgate.identifyUser(customerId: customer_user_id, identityToken: identity_token)`.
        """
        if not USER_ID.match(body.user_id):
            raise ApiError(422, "invalid_user_id", "Use 1-64 letters, digits or _ . @ : -")
        return {
            "customer_user_id": body.user_id,
            "display_name": body.display_name,
            "session_token": create_session_token(settings.session_secret, body.user_id, body.display_name),
            "identity_token": sign_identity_token(settings.clikgate_identity_secret, body.user_id),
        }

    @app.post("/auth/identity-token")
    async def identity_token(user: User) -> dict[str, str]:
        """A fresh identity token for the signed-in user (they expire on Clikgate's side)."""
        return {
            "customer_user_id": user.user_id,
            "identity_token": sign_identity_token(settings.clikgate_identity_secret, user.user_id),
        }

    @app.get("/me/referral-link")
    async def referral_link(user: User) -> dict[str, Any]:
        """Get-or-create the user's referrer in the program and return its code and links."""
        referrer = await client.get_or_create_referrer(
            settings.clikgate_program_id, user.user_id, user.display_name
        )
        referrer_ids[user.user_id] = referrer["id"]
        return {
            "program_id": referrer.get("program_id", settings.clikgate_program_id),
            "referrer_id": referrer["id"],
            "code": referrer["code"],
            "url": referrer.get("url") or referrer.get("short_url"),
            "short_url": referrer.get("short_url"),
        }

    @app.get("/me/referral-stats")
    async def referral_stats(user: User) -> dict[str, Any]:
        """The user's live referral counters (404 `referrer_not_found` before their first link)."""
        referrer = await client.referrer_by_user(settings.clikgate_program_id, user.user_id)
        referrer_ids[user.user_id] = referrer["id"]
        stats = referrer.get("stats") or {}
        return {
            "referrer_id": referrer["id"],
            "code": referrer["code"],
            **{key: int(stats.get(key) or 0) for key in STAT_KEYS},
        }

    @app.get("/leaderboards/{leaderboard_id}")
    async def leaderboard(
        leaderboard_id: str,
        user: User,
        period: Annotated[str | None, Query(max_length=20)] = None,
        limit: Annotated[int, Query(ge=1, le=100)] = 20,
    ) -> dict[str, Any]:
        """Top entries of a board (live ranks), with the signed-in user's row marked `is_me`."""
        check_board(leaderboard_id)
        raw = await client.leaderboard_entries(leaderboard_id, period=period, limit=limit)
        try:
            mine = await my_referrer_id(user)
        except ClikgateError as e:
            if e.code != "referrer_not_found":
                raise
            mine = None
        return {
            "leaderboard_id": leaderboard_id,
            **(await meta(leaderboard_id)),
            "period": _period(raw),
            "segment": raw.get("segment"),
            "entries": _entries(raw, mine),
        }

    @app.get("/leaderboards/{leaderboard_id}/me")
    async def leaderboard_me(
        leaderboard_id: str, user: User, period: Annotated[str | None, Query(max_length=20)] = None
    ) -> dict[str, Any]:
        """The signed-in user's standing: rank (null = not ranked), score, gap to the next rank."""
        check_board(leaderboard_id)
        referrer_id = await my_referrer_id(user)
        s = await client.leaderboard_standing(leaderboard_id, referrer_id, period=period)
        return {
            "leaderboard_id": leaderboard_id,
            "referrer_id": referrer_id,
            "period": _period(s),
            "rank": s.get("rank"),
            "score": s.get("score", 0),
            "pending": s.get("pending"),
            "gap_to_next": s.get("gap_to_next"),
            "best_rank": s.get("best_rank"),
            "eligible": s.get("eligible", True),
            "opted_out": s.get("opted_out", False),
            "period_ends_at": s.get("period_ends_at"),
        }

    @app.get("/leaderboards/{leaderboard_id}/around-me")
    async def leaderboard_around_me(
        leaderboard_id: str,
        user: User,
        radius: Annotated[int, Query(ge=1, le=50)] = 2,
        period: Annotated[str | None, Query(max_length=20)] = None,
    ) -> dict[str, Any]:
        check_board(leaderboard_id)
        referrer_id = await my_referrer_id(user)
        raw = await client.leaderboard_around(leaderboard_id, referrer_id, radius=radius, period=period)
        return {"leaderboard_id": leaderboard_id, "period": _period(raw), "entries": _entries(raw, referrer_id)}

    @app.post("/orders", status_code=201)
    async def create_order(body: OrderBody, user: User) -> dict[str, Any]:
        """A confirmed purchase: report it to Clikgate as a server-side event (`purchase`).

        Server events can't be forged by a modified app, so referral steps such as "first purchase
        over N" should rely on them rather than on the SDK's `track`.
        """
        app_id = settings.app_id_for(body.platform)
        if not app_id:
            raise ApiError(500, "app_id_not_configured", "Set CLIKGATE_APP_ID (or _ANDROID / _IOS).")
        order_id = body.order_id or f"ord_{uuid.uuid4().hex[:12]}"
        event: dict[str, Any] = {
            "customer_user_id": user.user_id,
            "event_id": f"order-{order_id}",
            "name": "purchase",
            "occurred_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "revenue_minor": body.amount_minor,
            "currency": body.currency,
            "properties": {"order_id": order_id},
        }
        if body.installation_id:
            event["installation_id"] = body.installation_id
        result = await client.send_events(app_id, [event], idempotency_key=f"order-{order_id}")
        return {"order_id": order_id, "event_id": event["event_id"], "clikgate": result}

    return app


def __getattr__(name: str) -> Any:
    # `uvicorn app.main:app`: build the app lazily so importing this module (tests) needs no env.
    if name == "app":
        return create_app()
    raise AttributeError(name)
