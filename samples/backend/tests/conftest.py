"""A fake Clikgate control-plane API behind httpx.MockTransport."""

import json
from dataclasses import dataclass, field
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient

from app.clikgate import ClikgateClient
from app.config import Settings
from app.main import create_app

API_KEY = "cg_test_secretkey"
IDENTITY_SECRET = "identity-secret"
PROGRAM = "rpg_1"
BOARD = "lb_week"


def error(status: int, code: str) -> httpx.Response:
    return httpx.Response(status, json={"error": {"type": "invalid_request", "code": code, "message": code}})


@dataclass
class FakeClikgate:
    referrers: dict[str, dict[str, Any]] = field(default_factory=dict)
    requests: list[httpx.Request] = field(default_factory=list)
    scores: dict[str, int] = field(default_factory=lambda: {"rfr_ada": 12})
    events: list[dict[str, Any]] = field(default_factory=list)
    down: bool = False

    def referrer(self, user: str, name: str | None) -> dict[str, Any]:
        rid = f"rfr_{user}"
        return {
            "id": rid, "object": "referrer", "program_id": PROGRAM, "customer_user_id": user,
            "display_name": name, "code": user.upper()[:6], "external_code": None, "link_id": "lnk_1",
            "url": f"https://inv.example.com/r/{user.upper()[:6]}", "short_url": "https://inv.example.com/aB3x",
            "status": "active", "stats": {"clicks": 7, "installs": 3, "qualified": 1},
        }

    def board_entries(self) -> list[dict[str, Any]]:
        ranked = sorted(self.scores.items(), key=lambda kv: -kv[1])
        return [
            {"rank": i + 1, "referrer_id": rid, "display": rid.removeprefix("rfr_").title(), "score": s,
             "pending": 0, "adjustments": 0, "opted_out": False}
            for i, (rid, s) in enumerate(ranked)
        ] + [{"rank": 99, "referrer_id": "rfr_hidden", "display": "Hidden", "score": 0, "pending": 0,
              "adjustments": 0, "opted_out": True}]

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        if self.down:
            raise httpx.ConnectError("down", request=request)
        if request.headers.get("authorization") != f"Bearer {API_KEY}":
            return error(401, "invalid_api_key")
        path, method = request.url.path, request.method
        period = {"period": "2026-W43", "status": "open", "starts_at": "2026-10-19T23:00:00Z",
                  "ends_at": "2026-10-26T23:00:00Z", "segment": None}
        if method == "POST" and path == f"/v1/referral-programs/{PROGRAM}/referrers":
            body = json.loads(request.content)
            user = body["customer_user_id"]
            created = user not in self.referrers
            self.referrers.setdefault(user, self.referrer(user, body.get("display_name")))
            self.scores.setdefault(self.referrers[user]["id"], 0)
            return httpx.Response(201 if created else 200, json=self.referrers[user])
        if method == "GET" and path.startswith(f"/v1/referral-programs/{PROGRAM}/referrers/by-user/"):
            user = path.rsplit("/", 1)[1]
            if user not in self.referrers:
                return error(404, "referrer_not_found")
            return httpx.Response(200, json=self.referrers[user])
        if path == f"/v1/leaderboards/{BOARD}":
            return httpx.Response(200, json={"id": BOARD, "name": "Weekly top inviters", "metric": {"type": "qualified"}})
        if path == f"/v1/leaderboards/{BOARD}/entries":
            limit = int(request.url.params.get("limit", 25))
            return httpx.Response(200, json={"object": "leaderboard_entries", "leaderboard_id": BOARD, **period,
                                             "entries": self.board_entries()[:limit], "has_more": False})
        if path.startswith(f"/v1/leaderboards/{BOARD}/entries/around/"):
            return httpx.Response(200, json={"object": "leaderboard_entries", "leaderboard_id": BOARD, **period,
                                             "entries": self.board_entries()})
        if path.startswith(f"/v1/leaderboards/{BOARD}/referrers/"):
            rid = path.rsplit("/", 1)[1]
            entries = {e["referrer_id"]: e for e in self.board_entries()}
            if rid not in entries:
                return error(404, "referrer_not_found")
            e = entries[rid]
            above = [x for x in entries.values() if x["rank"] == e["rank"] - 1]
            return httpx.Response(200, json={
                "object": "leaderboard_referrer", "leaderboard_id": BOARD, "period": "2026-W43", "status": "open",
                "segment": None, "referrer_id": rid, "display": e["display"], "rank": e["rank"], "score": e["score"],
                "pending": 0, "adjustments": 0, "gap_to_next": (above[0]["score"] - e["score"]) if above else None,
                "best_rank": e["rank"], "eligible": True, "opted_out": False, "period_ends_at": "2026-10-26T23:00:00Z"})
        if path.startswith("/v1/leaderboards/"):
            return error(404, "leaderboard_not_found")
        if method == "POST" and path == "/v1/apps/app_android/events":
            self.events.extend(json.loads(request.content)["events"])
            return httpx.Response(200, json={"accepted": 1, "duplicates": 0, "rejected": []})
        return error(404, "not_found")


@pytest.fixture
def fake() -> FakeClikgate:
    return FakeClikgate()


@pytest.fixture
def settings() -> Settings:
    return Settings(
        clikgate_api_key=API_KEY,
        clikgate_identity_secret=IDENTITY_SECRET,
        clikgate_program_id=PROGRAM,
        clikgate_app_id="app_android",
        clikgate_api_url="https://api.clikgate.test",
        clikgate_leaderboard_ids=(BOARD,),
        session_secret="session-secret",
    )


@pytest.fixture
def client(settings: Settings, fake: FakeClikgate):
    clikgate = ClikgateClient(settings.clikgate_api_url, settings.clikgate_api_key, transport=httpx.MockTransport(fake))
    with TestClient(create_app(settings, clikgate)) as c:
        yield c


def login(client: TestClient, user: str = "ada", name: str | None = "Ada") -> dict[str, Any]:
    r = client.post("/auth/demo-login", json={"user_id": user, "display_name": name})
    assert r.status_code == 200, r.text
    body = r.json()
    client.headers["Authorization"] = f"Bearer {body['session_token']}"
    return body
