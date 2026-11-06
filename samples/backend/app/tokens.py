"""Identity tokens (for Clikgate) and demo session tokens (for this sample's own API)."""

import base64
import hashlib
import hmac
import json
import time
from dataclasses import dataclass


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def sign_identity_token(secret: str, customer_user_id: str, issued_at: int | None = None) -> str:
    """Clikgate identity token: base64url_nopad(HMAC_SHA256(secret, "<user>.<issued_at>")) + "." + issued_at.

    The app passes it to `Clikgate.identifyUser(customerId: userId, identityToken: ...)`; Clikgate verifies it with
    the app's identity secret (programs with `require_identity_token` need it). Tokens expire on
    Clikgate's side (`IDENTITY_TOKEN_MAX_AGE_DAYS`), so mint a fresh one at each sign-in.
    """
    issued = int(time.time()) if issued_at is None else issued_at
    digest = hmac.new(secret.encode(), f"{customer_user_id}.{issued}".encode(), hashlib.sha256).digest()
    return f"{_b64(digest)}.{issued}"


@dataclass(frozen=True)
class Session:
    user_id: str
    display_name: str | None
    issued_at: int


def create_session_token(secret: str, user_id: str, display_name: str | None, now: int | None = None) -> str:
    """A tiny signed token for the demo login (use your real auth in production)."""
    payload = {"sub": user_id, "name": display_name, "iat": int(time.time()) if now is None else now}
    body = _b64(json.dumps(payload, separators=(",", ":")).encode())
    sig = _b64(hmac.new(secret.encode(), body.encode(), hashlib.sha256).digest())
    return f"{body}.{sig}"


def read_session_token(secret: str, token: str, max_age_seconds: int, now: int | None = None) -> Session | None:
    body, _, sig = token.partition(".")
    if not body or not sig:
        return None
    expected = _b64(hmac.new(secret.encode(), body.encode(), hashlib.sha256).digest())
    if not hmac.compare_digest(expected, sig):
        return None
    try:
        payload = json.loads(_unb64(body))
        issued = int(payload["iat"])
        user_id = str(payload["sub"])
    except (ValueError, KeyError, TypeError):
        return None
    current = int(time.time()) if now is None else now
    if current - issued > max_age_seconds or issued > current + 300:
        return None
    return Session(user_id=user_id, display_name=payload.get("name"), issued_at=issued)
