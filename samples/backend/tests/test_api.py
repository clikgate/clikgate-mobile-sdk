from app.tokens import sign_identity_token

from .conftest import API_KEY, BOARD, IDENTITY_SECRET, PROGRAM, login


def test_demo_login_returns_session_and_identity_token_but_no_secrets(client):
    body = login(client)
    assert body["customer_user_id"] == "ada"
    sig, issued = body["identity_token"].rsplit(".", 1)
    assert body["identity_token"] == sign_identity_token(IDENTITY_SECRET, "ada", int(issued))
    text = str(body)
    assert API_KEY not in text and IDENTITY_SECRET not in text


def test_demo_login_validates_user_id(client):
    assert client.post("/auth/demo-login", json={"user_id": "a b/c"}).status_code == 422


def test_me_routes_need_a_session(client, fake):
    assert client.get("/me/referral-link").json()["error"]["code"] == "unauthenticated"
    client.headers["Authorization"] = "Bearer forged.token"
    assert client.get("/me/referral-link").status_code == 401
    assert fake.requests == []


def test_referral_link_get_or_create_uses_server_api_key(client, fake):
    login(client)
    r = client.get("/me/referral-link")
    assert r.status_code == 200
    assert r.json() == {"program_id": PROGRAM, "referrer_id": "rfr_ada", "code": "ADA",
                        "url": "https://inv.example.com/r/ADA", "short_url": "https://inv.example.com/aB3x"}
    req = fake.requests[-1]
    assert req.method == "POST" and req.url.path == f"/v1/referral-programs/{PROGRAM}/referrers"
    assert req.headers["authorization"] == f"Bearer {API_KEY}"
    assert b'"display_name":"Ada"' in req.content.replace(b" ", b"")
    # Second call: same referrer (get-or-create)
    assert client.get("/me/referral-link").json()["referrer_id"] == "rfr_ada"
    assert len(fake.referrers) == 1


def test_referral_stats(client):
    login(client)
    assert client.get("/me/referral-stats").json()["error"]["code"] == "referrer_not_found"
    client.get("/me/referral-link")
    stats = client.get("/me/referral-stats").json()
    assert stats == {"referrer_id": "rfr_ada", "code": "ADA", "clicks": 7, "installs": 3, "signups": 0,
                     "in_progress": 0, "qualified": 1, "disqualified": 0, "rejected": 0}


def test_leaderboard_live_ranks_marks_me_and_hides_opted_out(client, fake):
    login(client, "bob", "Bob")
    client.get("/me/referral-link")
    fake.scores["rfr_bob"] = 5
    page = client.get(f"/leaderboards/{BOARD}", params={"limit": 10}).json()
    assert page["name"] == "Weekly top inviters" and page["metric"] == "qualified"
    assert page["period"] == {"key": "2026-W43", "status": "open", "starts_at": "2026-10-19T23:00:00Z",
                              "ends_at": "2026-10-26T23:00:00Z"}
    assert [(e["rank"], e["referrer_id"], e["is_me"]) for e in page["entries"]] == [
        (1, "rfr_ada", False), (2, "rfr_bob", True)]
    entries_req = next(r for r in fake.requests if r.url.path.endswith("/entries"))
    assert entries_req.url.params["limit"] == "10"

    me = client.get(f"/leaderboards/{BOARD}/me").json()
    assert (me["rank"], me["score"], me["gap_to_next"]) == (2, 5, 7)

    # Live: the next poll sees the new score (board meta is cached, entries are not)
    fake.scores["rfr_bob"] = 20
    page = client.get(f"/leaderboards/{BOARD}").json()
    assert page["entries"][0]["referrer_id"] == "rfr_bob" and page["entries"][0]["is_me"]
    assert client.get(f"/leaderboards/{BOARD}/me").json()["rank"] == 1
    assert sum(r.url.path == f"/v1/leaderboards/{BOARD}" for r in fake.requests) == 1

    around = client.get(f"/leaderboards/{BOARD}/around-me").json()
    assert any(e["is_me"] for e in around["entries"])


def test_leaderboard_without_referrer(client):
    login(client, "carol")
    page = client.get(f"/leaderboards/{BOARD}").json()
    assert all(not e["is_me"] for e in page["entries"])
    assert client.get(f"/leaderboards/{BOARD}/me").json()["error"]["code"] == "referrer_not_found"


def test_leaderboard_allowlist(client, fake):
    login(client)
    r = client.get("/leaderboards/lb_other")
    assert r.status_code == 404 and r.json()["error"]["code"] == "leaderboard_not_found"
    assert fake.requests == []


def test_order_sends_the_purchase_goal_for_the_installation(client, fake):
    login(client)
    r = client.post("/orders", json={"order_id": "A-1001", "amount_minor": 1500000, "currency": "NGN",
                                     "installation_id": "6a1f0c2e-0000-4000-8000-000000000000"})
    assert r.status_code == 201, r.text
    assert r.json()["clikgate"]["status"] == "counted"
    (event,) = fake.events
    assert event["goal"] == "purchase" and event["reference"] == "order-A-1001"
    assert event["value"] == "15000" and event["currency"] == "NGN" and event["provider"] == "custom"
    assert event["app_id"] == "app_android" and event["installation_id"].startswith("6a1f0c2e")
    assert "customer_id" not in event
    assert event["occurred_at"].endswith("Z")
    assert fake.requests[-1].url.path == "/v1/goals/events"
    assert fake.requests[-1].headers["idempotency-key"] == "order-A-1001"


def test_order_without_installation_uses_the_customer_id(client, fake):
    login(client)
    r = client.post("/orders", json={"order_id": "A-1002", "amount_minor": 2500, "currency": "JPY"})
    assert r.status_code == 201, r.text
    (event,) = fake.events
    assert event["customer_id"] == "ada" and "installation_id" not in event
    assert event["value"] == "2500"


def test_order_validation(client):
    login(client)
    assert client.post("/orders", json={"amount_minor": 1, "currency": "ngn"}).status_code == 422


def test_clikgate_errors_are_mapped(client, fake, settings):
    login(client)
    fake.down = True
    r = client.get("/me/referral-link")
    assert r.status_code == 502 and r.json()["error"]["code"] == "clikgate_unavailable"


def test_bad_api_key_is_not_passed_through_as_401(settings, fake):
    import httpx
    from fastapi.testclient import TestClient

    from app.clikgate import ClikgateClient
    from app.main import create_app

    bad = ClikgateClient(settings.clikgate_api_url, "cg_test_wrong", transport=httpx.MockTransport(fake))
    with TestClient(create_app(settings, bad)) as c:
        login(c)
        r = c.get("/me/referral-link")
    assert r.status_code == 502 and r.json()["error"]["code"] == "invalid_api_key"
