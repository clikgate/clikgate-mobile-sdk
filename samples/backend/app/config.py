"""Settings from the environment (or a `.env` file next to this package's parent directory).

Secrets (the Clikgate API key, the app's identity secret, the session secret) live only here,
on the server. The mobile app never sees them: it gets a session token and an identity token
from `POST /auth/demo-login`.
"""

import os
import secrets
from dataclasses import dataclass, field
from pathlib import Path

ENV_FILE = Path(__file__).resolve().parent.parent / ".env"


def load_env_file(path: Path = ENV_FILE) -> None:
    """Minimal `.env` loader (KEY=VALUE lines, `#` comments); real env vars win."""
    if not path.is_file():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key.strip(), value)


def _csv(value: str | None) -> tuple[str, ...]:
    return tuple(v.strip() for v in (value or "").split(",") if v.strip())


@dataclass(frozen=True)
class Settings:
    # Control-plane API key (Bearer cg_live_... / cg_test_...). Scopes used: links:write (referrers),
    # links:read (referrer by user), analytics:read (leaderboards), conversions:write (events).
    clikgate_api_key: str
    # The app's identity secret (POST /v1/apps/{id}/identity-secret/rotate), used to sign identity tokens.
    clikgate_identity_secret: str
    # Referral program whose links and stats the app shows.
    clikgate_program_id: str
    # App id for server-side events; per-platform ids override it when the order says its platform.
    clikgate_app_id: str = ""
    clikgate_app_id_android: str = ""
    clikgate_app_id_ios: str = ""
    clikgate_api_url: str = "https://api.clikgate.com"
    # Leaderboards the app may read through this backend (empty: any id).
    clikgate_leaderboard_ids: tuple[str, ...] = ()
    # Signs the demo session tokens. Random per process if unset (sessions end on restart).
    session_secret: str = field(default_factory=lambda: secrets.token_urlsafe(32))
    session_ttl_seconds: int = 7 * 24 * 3600

    @classmethod
    def from_env(cls) -> "Settings":
        load_env_file()
        env = os.environ
        missing = [
            k
            for k in ("CLIKGATE_API_KEY", "CLIKGATE_IDENTITY_SECRET", "CLIKGATE_PROGRAM_ID")
            if not env.get(k)
        ]
        if missing:
            raise RuntimeError(f"Missing settings: {', '.join(missing)} (see .env.example)")
        extra = {}
        if env.get("SESSION_SECRET"):
            extra["session_secret"] = env["SESSION_SECRET"]
        return cls(
            clikgate_api_key=env["CLIKGATE_API_KEY"],
            clikgate_identity_secret=env["CLIKGATE_IDENTITY_SECRET"],
            clikgate_program_id=env["CLIKGATE_PROGRAM_ID"],
            clikgate_app_id=env.get("CLIKGATE_APP_ID", ""),
            clikgate_app_id_android=env.get("CLIKGATE_APP_ID_ANDROID", ""),
            clikgate_app_id_ios=env.get("CLIKGATE_APP_ID_IOS", ""),
            clikgate_api_url=env.get("CLIKGATE_API_URL", "https://api.clikgate.com").rstrip("/"),
            clikgate_leaderboard_ids=_csv(env.get("CLIKGATE_LEADERBOARD_IDS")),
            session_ttl_seconds=int(env.get("SESSION_TTL_SECONDS", 7 * 24 * 3600)),
            **extra,
        )

    def app_id_for(self, platform: str | None) -> str:
        if platform == "android" and self.clikgate_app_id_android:
            return self.clikgate_app_id_android
        if platform == "ios" and self.clikgate_app_id_ios:
            return self.clikgate_app_id_ios
        return self.clikgate_app_id or self.clikgate_app_id_android or self.clikgate_app_id_ios

    def leaderboard_allowed(self, leaderboard_id: str) -> bool:
        return not self.clikgate_leaderboard_ids or leaderboard_id in self.clikgate_leaderboard_ids
