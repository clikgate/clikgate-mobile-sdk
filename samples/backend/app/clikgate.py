"""Thin client for the Clikgate control-plane API (server-to-server, API key auth).

Only the calls the sample needs (see clikgate_api docs/API.md):

- referrers: `POST /v1/referral-programs/{id}/referrers` (get-or-create by customer user id),
  `GET /v1/referral-programs/{id}/referrers/by-user/{customer_user_id}`
- leaderboards: `GET /v1/leaderboards/{id}`, `/entries`, `/entries/around/{referrer_id}`,
  `/referrers/{referrer_id}`
- server-side events: `POST /v1/apps/{app_id}/events`
"""

from typing import Any
from urllib.parse import quote

import httpx


class ClikgateError(Exception):
    """An error answer from Clikgate (or no answer: `clikgate_unavailable`)."""

    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message


def _seg(value: str) -> str:
    return quote(value, safe="")


class ClikgateClient:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        transport: httpx.AsyncBaseTransport | None = None,
        timeout: float = 10.0,
    ) -> None:
        self._http = httpx.AsyncClient(
            base_url=base_url,
            headers={
                "Authorization": f"Bearer {api_key}",
                "User-Agent": "clikgate-sample-backend/1.0",
            },
            timeout=timeout,
            transport=transport,
        )

    async def aclose(self) -> None:
        await self._http.aclose()

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json: Any = None,
        headers: dict[str, str] | None = None,
    ) -> dict[str, Any]:
        clean = {k: v for k, v in (params or {}).items() if v is not None}
        try:
            response = await self._http.request(method, path, params=clean, json=json, headers=headers)
        except httpx.HTTPError as e:
            raise ClikgateError(502, "clikgate_unavailable", f"Clikgate API unreachable: {e}") from e
        if response.status_code >= 400:
            code, message = f"http_{response.status_code}", response.text[:200]
            try:
                error = response.json().get("error") or {}
                code = error.get("code") or code
                message = error.get("message") or message
            except ValueError:
                pass
            raise ClikgateError(response.status_code, code, message)
        return response.json()

    # Referrers

    async def get_or_create_referrer(
        self, program_id: str, customer_user_id: str, display_name: str | None
    ) -> dict[str, Any]:
        body: dict[str, Any] = {"customer_user_id": customer_user_id}
        if display_name:
            body["display_name"] = display_name
        return await self._request("POST", f"/v1/referral-programs/{_seg(program_id)}/referrers", json=body)

    async def referrer_by_user(self, program_id: str, customer_user_id: str) -> dict[str, Any]:
        return await self._request(
            "GET", f"/v1/referral-programs/{_seg(program_id)}/referrers/by-user/{_seg(customer_user_id)}"
        )

    # Leaderboards

    async def leaderboard(self, leaderboard_id: str) -> dict[str, Any]:
        return await self._request("GET", f"/v1/leaderboards/{_seg(leaderboard_id)}")

    async def leaderboard_entries(
        self, leaderboard_id: str, *, period: str | None = None, limit: int = 25
    ) -> dict[str, Any]:
        return await self._request(
            "GET", f"/v1/leaderboards/{_seg(leaderboard_id)}/entries", params={"period": period, "limit": limit}
        )

    async def leaderboard_around(
        self, leaderboard_id: str, referrer_id: str, *, radius: int = 5, period: str | None = None
    ) -> dict[str, Any]:
        return await self._request(
            "GET",
            f"/v1/leaderboards/{_seg(leaderboard_id)}/entries/around/{_seg(referrer_id)}",
            params={"radius": radius, "period": period},
        )

    async def leaderboard_standing(
        self, leaderboard_id: str, referrer_id: str, *, period: str | None = None
    ) -> dict[str, Any]:
        return await self._request(
            "GET",
            f"/v1/leaderboards/{_seg(leaderboard_id)}/referrers/{_seg(referrer_id)}",
            params={"period": period},
        )

    # Server-side events

    async def send_events(self, app_id: str, events: list[dict[str, Any]], *, idempotency_key: str) -> dict[str, Any]:
        return await self._request(
            "POST",
            f"/v1/apps/{_seg(app_id)}/events",
            json={"events": events},
            headers={"Idempotency-Key": idempotency_key},
        )
