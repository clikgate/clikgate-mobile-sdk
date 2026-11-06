import base64
import hashlib
import hmac

from app.tokens import create_session_token, read_session_token, sign_identity_token


def test_identity_token_matches_clikgate_formula():
    token = sign_identity_token("s3cret", "user_42", issued_at=1_760_000_000)
    sig, issued = token.rsplit(".", 1)
    assert issued == "1760000000"
    expected = base64.urlsafe_b64encode(
        hmac.new(b"s3cret", b"user_42.1760000000", hashlib.sha256).digest()
    ).rstrip(b"=").decode()
    assert sig == expected and "=" not in sig


def test_session_round_trip_and_rejections():
    token = create_session_token("k", "ada", "Ada", now=1000)
    s = read_session_token("k", token, max_age_seconds=60, now=1030)
    assert s is not None and s.user_id == "ada" and s.display_name == "Ada"
    assert read_session_token("other", token, 60, now=1030) is None       # wrong key
    assert read_session_token("k", token, 60, now=2000) is None           # expired
    body, sig = token.split(".")
    assert read_session_token("k", body + "x." + sig, 60, now=1030) is None  # tampered
    assert read_session_token("k", "garbage", 60, now=1030) is None
