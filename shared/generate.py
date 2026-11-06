"""
Generates shared/schemas/*.schema.json and shared/fixtures/*.json.

The schemas and fixtures are checked in; rerun this after editing it:
    python3 shared/generate.py
The backend test suite validates its SDK responses against these schemas, and each SDK's
unit tests decode the fixtures.
"""

import json
from pathlib import Path

ROOT = Path(__file__).parent
DRAFT = "https://json-schema.org/draft/2020-12/schema"

ID = {"type": "string", "pattern": r"^[a-z]{2,4}_[0-9A-HJKMNP-TV-Z]{26}$"}
INSTALLATION_ID = {"type": "string", "pattern": r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"}
TIMESTAMP = {"type": "string", "format": "date-time"}
NULLABLE_STRING = {"type": ["string", "null"]}
CURRENCY = {"type": "string", "pattern": "^[A-Z]{3}$"}
MATCH_TYPE = {
    "enum": [
        "app_link",
        "install_referrer",
        "pasteboard",
        "probabilistic",
        "apple_search_ads",
        "code_entry",
        None,
    ]
}
# Platform short domains shared by many organisations (change 06 A.4): paid, free, test, spare.
SHARED_LINK_DOMAINS = ["ciz.to", "clk.ng", "clkg.to", "dev.ciz.to"]
REFERRAL_STATUS = {
    "enum": ["installed", "signed_up", "in_progress", "holding", "qualified", "disqualified", "rejected"]
}


def nullable(schema: dict) -> dict:
    return {"anyOf": [schema, {"type": "null"}]}


def obj(properties: dict, required: list[str] | None = None, additional: bool = True) -> dict:
    schema = {"type": "object", "properties": properties, "additionalProperties": additional}
    if required:
        schema["required"] = required
    return schema


LINK = obj(
    {
        "id": ID,
        "kind": {"enum": ["standard", "referral"]},
        "external_reference": NULLABLE_STRING,
        "campaign_id": NULLABLE_STRING,
        "metadata": {"type": "object"},
    },
    ["id", "kind", "metadata"],
)
DEEP_LINK = obj(
    {
        "url": NULLABLE_STRING,
        "path": NULLABLE_STRING,
        "data": {"type": "object"},
        "is_deferred": {"type": "boolean"},
    },
    ["url", "path", "data", "is_deferred"],
)
REFERRAL = obj(
    {
        "referral_id": ID,
        "program_id": ID,
        "status": REFERRAL_STATUS,
        "source": {"enum": ["link", "code_entry", "byo_code", "offline_code", None]},
        "referrer_id": ID,
        "referrer_display_name": NULLABLE_STRING,
        "created_at": nullable(TIMESTAMP),
    },
    ["referral_id", "program_id", "status", "referrer_id", "referrer_display_name"],
)
PERIOD = obj(
    {
        "key": {"type": "string"},
        "status": {"enum": ["open", "closed_provisional", "final"]},
        "starts_at": nullable(TIMESTAMP),
        "ends_at": nullable(TIMESTAMP),
    },
    ["key", "status"],
)
ENTRY = obj(
    {
        "rank": {"type": "integer", "minimum": 1},
        "referrer_id": ID,
        "display": {"type": "string"},
        "score": {"type": "integer"},
        "pending": {"type": ["integer", "null"]},
        "is_me": {"type": "boolean"},
    },
    ["rank", "referrer_id", "display", "score", "is_me"],
)
PUSH = obj(
    {
        "provider": {"enum": ["apns", "fcm"]},
        "token": {"type": "string", "minLength": 1, "maxLength": 4096},
        "apns_environment": {"enum": ["production", "sandbox", None]},
    },
    ["provider", "token"],
    additional=False,
)

# Change 03 (B.3): consent purposes and the request-side consent object. Sent on every SDK request
# body from SDK 1.2.0 (install, open, resolve, events, identify, push-token, attest, consent).
CONSENT_STATE = {"enum": ["granted", "denied", "unknown"]}
# Region hint (`setConsentRegion`): an ISO 3166-1 alpha-2 country code or one of the region codes
# EEA / UK (Switzerland is the country code CH).
REGION = {"type": "string", "pattern": "^(EEA|UK|[A-Z]{2})$"}
CONSENT = obj(
    {
        # Deprecated (change 09, X.E23): SDKs before 1.5.0 (React Native 1.6.0) sent it on /install,
        # false = the user opted out (`setTrackingEnabled(false)`) before the first install. Newer SDKs
        # never send it: the opted-out install says so with every purpose `denied` (the backend reads
        # `attribution: denied` as "no attribution"). Kept so old SDKs' bodies still validate.
        "tracking_allowed": {"type": "boolean"},
        "analytics": CONSENT_STATE,
        "attribution": CONSENT_STATE,
        "ad_user_data": CONSENT_STATE,
        "ad_personalization": CONSENT_STATE,
        "region": nullable(REGION),
        # When the app last called setConsent (null: never, all purposes `unknown`).
        "updated_at": nullable(TIMESTAMP),
    }
)
# Change 03 (B.4): Google click ids read from the app link / universal link that opened the app or
# from the Android install referrer. Each optional; the backend applies the precedence
# gclid > gbraid > wbraid.
CLICK_ID = {"type": "string", "minLength": 1, "maxLength": 512}
GOOGLE_CLICK_IDS = obj(
    {
        "gclid": nullable(CLICK_ID),
        "gbraid": nullable(CLICK_ID),
        "wbraid": nullable(CLICK_ID),
        "source": {"enum": ["deep_link", "install_referrer"]},
    },
    ["source"],
    additional=False,
)
# Firebase Analytics app instance id (B.5), sent only when the app enabled Firebase forwarding and
# analytics consent allows it.
APP_INSTANCE_ID = {"type": ["string", "null"], "minLength": 1, "maxLength": 128}
# Apple DeviceCheck token (`DCDevice.generateToken`, base64), for the backend's per-device bits query.
DEVICE_CHECK_TOKEN = {"type": ["string", "null"], "minLength": 1, "maxLength": 16384}
ATTESTATION = obj(
    {
        "type": {"enum": ["app_attest", "app_attest_assertion", "play_integrity"]},
        "token": {"type": "string"},
        "key_id": NULLABLE_STRING,
        "challenge": {"type": "string"},
        # Change 03: Play Integrity request flavour (standard: requestHash = nonce; classic: nonce).
        # Optional; absent means classic (SDK <= 1.1).
        "request_type": {"enum": ["standard", "classic"]},
    },
    ["type", "token", "challenge"],
)
VERSION = {"type": "string", "pattern": r"^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$"}
SDK_CALL = {
    "enum": ["config", "install", "install_ping", "open", "resolve", "events", "identify", "push_token",
             "opt_out", "consent", "attest", "apple_search_ads", "referrals", "leaderboards", "codes",
             # Change 06: POST /v1/sdk/goals
             "goals"]
}

# ---- Change 06 (S.1): goals ----
# Goal key (backend B.1): snake_case, 2-40 characters.
GOAL_KEY = {"type": "string", "pattern": r"^[a-z][a-z0-9_]{1,39}$"}
# Change 12: payment provider keys (shared/providers.json, from the backend's OpenAPI Provider enum).
# The schema takes any provider key so SDKs can send providers added after their release
# (`Provider.fromString`); the server answers unknown_provider for keys it doesn't know.
PROVIDER = {"type": "string", "pattern": r"^[a-z][a-z0-9_]{1,29}$"}
PROVIDERS = json.loads((Path(__file__).parent / "providers.json").read_text())["providers"]
# The business's own unique id for this goal event (backend B.2): 1-128 characters. SDKs send a
# UUIDv4 when the app passes none (app-side idempotency only).
GOAL_REFERENCE = {"type": "string", "minLength": 1, "maxLength": 128}
# Goal value in normal units (never minor units), always a JSON *string* from the SDKs so no
# floating point touches the wire: a plain non-negative decimal, no sign, exponent or leading zeros,
# trailing fractional zeros stripped by the SDKs ("2000000", "1500.5", "0.25"). At most 15
# significant digits (counted after removing leading zeros and trailing fractional zeros) - checked
# by the SDKs and the backend, not expressible here; maxLength bounds it loosely. Decimal places
# allowed by the currency (ISO 4217 exponent) are checked by the backend only.
GOAL_VALUE = {"type": "string", "pattern": r"^(0|[1-9][0-9]*)(\.[0-9]*[1-9])?$", "minLength": 1, "maxLength": 32}
GOAL_ITEM = obj(
    {
        "goal": GOAL_KEY,
        "reference": GOAL_REFERENCE,
        "value": {"anyOf": [GOAL_VALUE, {"type": "null"}]},
        "currency": nullable(CURRENCY),
        "is_first": {"type": ["boolean", "null"]},
        # Change 14: the person's label (source device), trimmed, 1-80 characters ("" clears); dropped on the
        # device in private mode unless config `allow_labels`
        "label": {"type": ["string", "null"], "maxLength": 80},
        # Set at goal() time and kept across retries.
        "occurred_at": TIMESTAMP,
        # The click of the most recent Clikgate deep link that opened the app (/resolve match), else
        # the install's click; null/absent = the backend uses the installation's attribution
        # (Clikgate-Installation-Id header). Same value attributionMetadata() returns as cg_click_id.
        "click_id": NULLABLE_STRING,
        # Change 12: a Provider value (shared/providers.json, generated into each SDK). Required by
        # the server for a Payment goal (with reference), checked and otherwise ignored for a
        # Standard goal. There is never a goal kind in the call: it lives in the goal's settings.
        "provider": nullable(PROVIDER),
    },
    ["goal", "reference", "occurred_at"],
    additional=False,
)
# Per-item rejection codes of POST /v1/sdk/goals (never retried by the SDKs).
GOAL_REJECTION_CODES = [
    "invalid_goal_key",
    "goal_not_found",
    "goal_archived",
    "invalid_value",
    "value_not_allowed",
    "value_required",
    "invalid_currency",
    "invalid_reference",
    "occurred_at_in_future",
    "private_mode_field_rejected",
    "validation_error",
    # Change 12: a Payment goal sent without provider or reference (`missing` lists which).
    "payment_goal_needs_confirmation",
    "unknown_provider",
]

# ---- Change 12 (S.1): one goal() method, enums (backend contract C12 B2, B3) ----
# GoalStatus and GoalKind (OpenAPI enums). The SDKs map unknown values defensively.
GOAL_STATUS = {"enum": ["counted", "waiting", "refused"]}
GOAL_KIND = {"enum": ["standard", "payment"]}
# The result of one goal item, in request order (`index`).
GOAL_RESULT = obj(
    {
        "index": {"type": "integer", "minimum": 0},
        "goal": {"type": "string"},
        "reference": {"type": "string"},
        "status": GOAL_STATUS,
        # null when counted; else a reason code (waiting_for_confirmation, pending_click, unattributed,
        # rejected_bot, outside_window, already_counted, already_counted_for_click, a report status, or
        # the rejection code of a refused item).
        "reason": NULLABLE_STRING,
        "goal_kind": nullable(GOAL_KIND),
        # Always status == "counted".
        "counted": {"type": "boolean"},
        # True when the app sent a value for a Payment goal: it was dropped (the value comes from the confirmation).
        "value_ignored": {"type": "boolean"},
        "id": NULLABLE_STRING,
    },
    ["index", "goal", "reference", "status", "counted"],
)

SCHEMAS: dict[str, dict] = {
    "error": obj(
        {
            "error": obj(
                {
                    "type": {"type": "string"},
                    "code": {"type": "string"},
                    "message": {"type": "string"},
                    "param": NULLABLE_STRING,
                    "request_id": NULLABLE_STRING,
                },
                ["type", "code", "message"],
            )
        },
        ["error"],
    ),
    "config_response": obj(
        {
            "app_id": ID,
            "environment": {"enum": ["production", "sandbox"]},
            "server_time": TIMESTAMP,
            # Part 3 (connected domains, 31.3): every active link domain in the org's domain groups,
            # as lowercase host names. Optional (older servers omit it); SDKs default to [] and add
            # these to the app's configured `linkDomains`.
            "link_domains": {"type": "array", "items": {"type": "string", "minLength": 1}, "default": []},
            "features": obj(
                {
                    "deferred_deep_linking": {"type": "boolean"},
                    "pasteboard_matching": {"enum": ["off", "on_interstitial_tap"]},
                    "probabilistic_matching": {"type": "boolean"},
                    "apple_search_ads": {"type": "boolean"},
                    "uninstall_tracking": {"type": "boolean"},
                    "collect_advertising_id": {"type": "boolean"},
                    "restricted_mode": {"type": "boolean"},
                    "attestation": obj(
                        {
                            "ios_app_attest": {"enum": ["off", "monitor", "enforce"]},
                            "android_play_integrity": {"enum": ["off", "monitor", "enforce"]},
                            # Change 03 (S.2): the customer's Google Cloud project number. When set (or
                            # passed in ClikgateOptions) Android uses Play Integrity standard requests.
                            "android_cloud_project_number": {"type": ["integer", "null"], "minimum": 1},
                        },
                        ["ios_app_attest", "android_play_integrity"],
                    ),
                },
                [
                    "deferred_deep_linking",
                    "pasteboard_matching",
                    "probabilistic_matching",
                    "apple_search_ads",
                    "uninstall_tracking",
                    "collect_advertising_id",
                    "restricted_mode",
                    "attestation",
                ],
            ),
            "referral_programs": {
                "type": "array",
                "items": obj(
                    {
                        "id": ID,
                        "name": {"type": "string"},
                        "status": {"enum": ["active", "paused"]},
                        "client_link_creation": {"type": "boolean"},
                        "allow_manual_code_entry": {"type": "boolean"},
                        "require_identity_token": {"type": "boolean"},
                    },
                    ["id", "name", "status", "client_link_creation", "allow_manual_code_entry"],
                ),
            },
            "conversion_value_schema": nullable(
                obj(
                    {
                        "id": ID,
                        "version": {"type": "integer"},
                        "rules": {
                            "type": "array",
                            "items": obj(
                                {
                                    "fine_value": {"type": "integer", "minimum": 0, "maximum": 63},
                                    "coarse_value": {"enum": ["low", "medium", "high"]},
                                    "event": {"type": "string"},
                                    "min_revenue_minor": {"type": ["integer", "null"]},
                                    "currency": NULLABLE_STRING,
                                    "lock_window": {"type": "boolean"},
                                },
                                ["fine_value", "coarse_value", "event"],
                            ),
                        },
                    },
                    ["id", "version", "rules"],
                )
            ),
            "batching": obj(
                {
                    "max_batch_size": {"type": "integer"},
                    "flush_interval_seconds": {"type": "integer"},
                    "flush_at_count": {"type": "integer"},
                    "max_queue_events": {"type": "integer"},
                    "max_queue_bytes": {"type": "integer"},
                },
                ["max_batch_size", "flush_interval_seconds", "flush_at_count", "max_queue_events", "max_queue_bytes"],
            ),
            "reattestation_interval_days": {"type": "integer"},
            "session_timeout_minutes": {"type": "integer"},
            # ---- Change 03 (all optional: servers before change 03 omit them) ----
            # B.3 consent mode, already resolved for this device's region (the `region_hint` query
            # parameter if the SDK sent one, else the IP-derived country).
            "consent": obj(
                {
                    "mode": {"enum": ["not_required", "required_in_regions", "required_everywhere"]},
                    "required": {"type": "boolean"},
                    "region": nullable(REGION),
                    "required_regions": {"type": "array", "items": REGION},
                    "anonymous_counts": {"type": "boolean"},
                    "buffer_max_days": {"type": "integer", "minimum": 1, "maximum": 7},
                    "buffer_max_events": {"type": "integer", "minimum": 1, "maximum": 1000},
                    "identity_checks_basis": {"enum": ["consent", "fraud_prevention"]},
                },
                ["mode", "required"],
            ),
            # B.4 minimum SDK version policy, evaluated for the Clikgate-SDK-Version header (and the
            # native version header when wrapped).
            "min_supported_version": nullable(VERSION),
            "latest_version": nullable(VERSION),
            "version_status": {"enum": ["current", "supported", "deprecated", "blocked", None]},
            "blocked_instructions": nullable(
                obj(
                    {
                        "allowed_calls": {"type": "array", "items": SDK_CALL},
                        "allowed_events": {"type": ["array", "null"], "items": {"type": "string"}},
                        "strip_event_properties": {"type": "boolean"},
                        "message": NULLABLE_STRING,
                    },
                    ["allowed_calls"],
                )
            ),
            # B.5 client-side Firebase / GA4 forwarding (plan feature ga4_forwarding). The SDK forwards
            # only when the app called enableFirebaseForwarding *and* `enabled` is true.
            "firebase_forwarding": obj(
                {
                    "enabled": {"type": "boolean"},
                    "log_attribution_event": {"type": "boolean"},
                    "set_user_properties": {"type": "boolean"},
                    "mirror_events": {"type": "boolean"},
                    "report_app_instance_id": {"type": "boolean"},
                },
                ["enabled"],
            ),
            # ---- Change 06 (optional: servers before change 06 omit it; absent = false) ----
            # B.5 organisation private mode. When true the SDK sends no /identify, no event
            # `properties` (nor event revenue: value only through goal()), and logs one warning in
            # debug builds. goal() works normally.
            "private_mode": {"type": "boolean", "default": False},
            # ---- Change 14 (absent = true): false in private mode without "Allow labels in private mode";
            # the SDKs then drop labels on the device with one debug warning.
            "allow_labels": {"type": "boolean", "default": True},
        },
        [
            "app_id",
            "environment",
            "server_time",
            "features",
            "referral_programs",
            "conversion_value_schema",
            "batching",
        ],
    ),
    "install_request": obj(
        {
            "installation_id": INSTALLATION_ID,
            "keychain_previous_installation_id": nullable(INSTALLATION_ID),
            "app_version": {"type": "string", "maxLength": 50},
            "sdk_version": {"type": "string", "maxLength": 50},
            "platform": {"enum": ["ios", "android"]},
            "os_version": {"type": ["string", "null"], "maxLength": 30},
            "device_model": {"type": ["string", "null"], "maxLength": 60},
            "locale": {"type": ["string", "null"], "maxLength": 35},
            "timezone": {"type": ["string", "null"], "maxLength": 64},
            "screen": nullable(
                obj(
                    {"w": {"type": "integer"}, "h": {"type": "integer"}, "scale": {"type": "number"}},
                    ["w", "h", "scale"],
                    additional=False,
                )
            ),
            "launch_url": {"type": ["string", "null"], "maxLength": 4096},
            "install_referrer": nullable(
                obj(
                    {
                        "referrer": {"type": ["string", "null"], "maxLength": 4096},
                        "referrer_click_timestamp_seconds": {"type": ["integer", "null"]},
                        "install_begin_timestamp_seconds": {"type": ["integer", "null"]},
                        "referrer_click_timestamp_server_seconds": {"type": ["integer", "null"]},
                        "install_begin_timestamp_server_seconds": {"type": ["integer", "null"]},
                        "install_version": NULLABLE_STRING,
                        "google_play_instant": {"type": ["boolean", "null"]},
                    }
                )
            ),
            "installer_package": {"type": ["string", "null"], "maxLength": 255},
            "pasteboard_token": {"type": ["string", "null"], "pattern": "^cgdl_[0-9A-Za-z]{26}$"},
            "push": nullable(PUSH),
            "attestation": nullable(ATTESTATION),
            "apple_search_ads_token": {"type": ["string", "null"], "maxLength": 8192},
            "consent": nullable(CONSENT),
            # ---- Change 03 (optional) ----
            "google_click_ids": nullable(GOOGLE_CLICK_IDS),
            "app_instance_id": APP_INSTANCE_ID,
            "device_check_token": DEVICE_CHECK_TOKEN,
            # iOS identifierForVendor, only with features.identity_checks and identity-check consent.
            "idfv": {"type": ["string", "null"], "maxLength": 64},
            # B.4 iOS on-device conversion measurement pass-through (GoogleAdsOnDeviceConversion
            # `fetchAggregateConversionInfo(for: .installation)`), sent once with the first install.
            "google_on_device_measurement": nullable(
                obj(
                    {"odm_info": {"type": "string", "minLength": 1, "maxLength": 16384}, "sdk_version": NULLABLE_STRING},
                    ["odm_info"],
                    additional=False,
                )
            ),
            # Fraud signals (change 02, B.5.2): device heuristics, hints rather than proof. Optional;
            # omitted when a check fails (old SDKs send fewer of them).
            "is_emulator": {"type": ["boolean", "null"]},
            "is_rooted": {"type": ["boolean", "null"]},
        },
        ["installation_id", "app_version", "sdk_version", "platform"],
        additional=False,
    ),
    "install_response": obj(
        {
            "install_id": ID,
            "attribution": obj(
                {
                    "status": {"enum": ["pending", "attributed", "organic"]},
                    "match_type": MATCH_TYPE,
                    "confidence": {"type": ["number", "null"]},
                    "click_id": NULLABLE_STRING,
                    "clicked_at": nullable(TIMESTAMP),
                    "is_reinstall": {"type": "boolean"},
                    "link": nullable(LINK),
                    # Change 03 (B.5, optional): attribution source for Firebase forwarding.
                    "source": NULLABLE_STRING,
                    "medium": NULLABLE_STRING,
                    "campaign": NULLABLE_STRING,
                    "channel": {"enum": ["ads", "whatsapp", "referral", "offline_code", "link", "organic", None]},
                },
                ["status", "match_type", "confidence", "click_id", "clicked_at", "is_reinstall", "link"],
            ),
            "deep_link": nullable(DEEP_LINK),
            "referral": nullable(REFERRAL),
            "retry_after_ms": {"type": ["integer", "null"]},
        },
        ["install_id", "attribution", "deep_link", "referral", "retry_after_ms"],
    ),
    "open_request": obj(
        {
            "app_version": NULLABLE_STRING,
            "os_version": NULLABLE_STRING,
            "is_cold_start": {"type": "boolean"},
            "push": nullable(PUSH),
            "consent": nullable(CONSENT),
            "google_click_ids": nullable(GOOGLE_CLICK_IDS),
            "app_instance_id": APP_INSTANCE_ID,
        },
        ["is_cold_start"],
        additional=False,
    ),
    "open_response": obj(
        {"open_id": ID, "uninstall_status": {"enum": ["installed", "uninstalled", "unknown"]}},
        ["open_id"],
    ),
    "resolve_request": obj(
        {
            "url": {"type": ["string", "null"], "maxLength": 4096},
            "click_id": NULLABLE_STRING,
            "consent": nullable(CONSENT),
            "google_click_ids": nullable(GOOGLE_CLICK_IDS),
        },
        additional=False,
    ),
    "resolve_response": obj(
        {
            "matched": {"type": "boolean"},
            "click_id": NULLABLE_STRING,
            "deep_link": nullable(DEEP_LINK),
            "link": nullable(LINK),
            "is_reengagement": {"type": "boolean"},
            "referral": nullable(REFERRAL),
            "match_type": MATCH_TYPE,
        },
        ["matched", "click_id", "deep_link", "link", "is_reengagement", "referral"],
    ),
    "events_request": obj(
        {
            "events": {
                "type": "array",
                "minItems": 1,
                "maxItems": 100,
                "items": obj(
                    {
                        "event_id": {"type": "string", "minLength": 1, "maxLength": 64},
                        "name": {"type": "string", "pattern": r"^[A-Za-z0-9_.$:-]{1,64}$"},
                        "occurred_at": TIMESTAMP,
                        "revenue_minor": {"type": ["integer", "null"]},
                        "currency": nullable(CURRENCY),
                        "properties": {"type": ["object", "null"]},
                    },
                    ["event_id", "name", "occurred_at"],
                    additional=False,
                ),
            },
            "consent": nullable(CONSENT),
        },
        ["events"],
        additional=False,
    ),
    "events_response": obj(
        {
            "accepted": {"type": "integer"},
            "duplicates": {"type": "integer"},
            "rejected": {
                "type": "array",
                "items": obj(
                    {"event_id": {"type": "string"}, "code": {"type": "string"}, "message": {"type": "string"}},
                    ["event_id", "code"],
                ),
            },
        },
        ["accepted", "duplicates", "rejected"],
    ),
    # Change 14 identifyUser(): `customer_user_id` absent keeps it, null clears it (never sent in private mode);
    # `label` trimmed, 1-80 characters, "" clears.
    "identify_request": obj(
        {
            "customer_user_id": {"type": ["string", "null"], "minLength": 1, "maxLength": 255},
            "identity_token": {"type": ["string", "null"], "maxLength": 512},
            "consent": nullable(CONSENT),
            "label": {"type": ["string", "null"], "maxLength": 80},
        },
        additional=False,
    ),
    "identify_response": obj(
        {
            "customer_user_id": NULLABLE_STRING,
            "identity_verified": {"type": "boolean"},
            "person_id": NULLABLE_STRING,
            # "plan": below Growth the label isn't stored; "lower_rank": a label from your server or team was kept
            "label_ignored": {"enum": ["plan", "lower_rank", None]},
        },
        ["customer_user_id", "identity_verified"],
    ),
    "push_token_request": obj({**PUSH["properties"], "consent": nullable(CONSENT)}, ["provider", "token"], additional=False),
    "opt_out_request": obj({"opt_out": {"type": "boolean"}}, ["opt_out"], additional=False),
    "attest_challenge_response": obj(
        {"challenge": {"type": "string"}, "nonce": {"type": "string"}, "expires_at": TIMESTAMP},
        ["challenge", "nonce", "expires_at"],
    ),
    "attest_request": obj(
        {
            "type": {"enum": ["app_attest", "app_attest_assertion", "play_integrity"]},
            "challenge": {"type": "string"},
            "token": {"type": "string"},
            "key_id": NULLABLE_STRING,
            "request_type": {"enum": ["standard", "classic"]},
            "device_check_token": DEVICE_CHECK_TOKEN,
            "consent": nullable(CONSENT),
        },
        ["type", "challenge", "token"],
        additional=False,
    ),
    # Change 03 (B.3): consent record (`consent_records`, source `sdk`). Sent whenever the app changes
    # consent or the region hint, once the installation exists.
    "consent_request": obj({"consent": CONSENT}, ["consent"], additional=False),
    "consent_response": obj({"ok": {"type": "boolean"}}, ["ok"]),
    # Change 03 (B.3): anonymous install count when consent is required and `attribution` is denied
    # (only if config consent.anonymous_counts). No installation id header, no identifiers.
    "install_ping_request": obj(
        {
            "platform": {"enum": ["ios", "android"]},
            "app_version": {"type": "string", "maxLength": 50},
            "sdk_version": {"type": "string", "maxLength": 50},
            "consent": CONSENT,
        },
        ["platform", "app_version", "sdk_version", "consent"],
        additional=False,
    ),
    "install_ping_response": obj({"ok": {"type": "boolean"}}, ["ok"]),
    "referral_link_request": obj(
        {"program_id": ID, "display_name": {"type": ["string", "null"], "maxLength": 100}},
        ["program_id"],
        additional=False,
    ),
    "referral_link_response": obj(
        {
            "referrer_id": ID,
            "program_id": ID,
            "code": {"type": "string"},
            "url": {"type": "string"},
            "short_url": {"type": "string"},
        },
        ["referrer_id", "program_id", "code", "url", "short_url"],
    ),
    "referral_stats_response": obj(
        {
            "referrer_id": ID,
            "program_id": ID,
            "code": {"type": "string"},
            "url": {"type": "string"},
            "short_url": {"type": "string"},
            "status": {"enum": ["active", "blocked"]},
            "stats": obj(
                {
                    k: {"type": "integer"}
                    for k in (
                        "clicks",
                        "installs",
                        "signups",
                        "in_progress",
                        "qualified",
                        "disqualified",
                        "rejected",
                    )
                },
                ["clicks", "installs", "signups", "in_progress", "qualified", "disqualified", "rejected"],
            ),
        },
        ["referrer_id", "program_id", "code", "url", "short_url", "status", "stats"],
    ),
    "apply_code_request": obj(
        {"program_id": ID, "code": {"type": "string", "minLength": 1, "maxLength": 64}},
        ["program_id", "code"],
        additional=False,
    ),
    "referral": REFERRAL,
    "referred_by_response": obj(
        {"referred": {"type": "boolean"}, "referral": nullable(REFERRAL)}, ["referred", "referral"]
    ),
    # v3
    "feature_disabled": obj(
        {"accepted": {"const": False}, "reason": {"const": "feature_disabled"}, "feature": {"type": "string"}},
        ["accepted", "reason", "feature"],
    ),
    "leaderboard_page": obj(
        {
            "leaderboard_id": ID,
            "name": {"type": "string"},
            "metric": {"enum": ["qualified", "installs", "signups", "step", "points"]},
            "segment": NULLABLE_STRING,
            "period": PERIOD,
            "entries": {"type": "array", "items": ENTRY},
        },
        ["leaderboard_id", "period", "entries"],
    ),
    "my_rank": obj(
        {
            "leaderboard_id": ID,
            "period": PERIOD,
            "referrer_id": ID,
            "rank": {"type": ["integer", "null"]},
            "score": {"type": "integer"},
            "pending": {"type": ["integer", "null"]},
            "gap_to_next": {"type": ["integer", "null"]},
            "best_rank": {"type": ["integer", "null"]},
            "period_ends_at": nullable(TIMESTAMP),
            "opted_out": {"type": "boolean"},
            "embed_token": NULLABLE_STRING,
            "embed_url": NULLABLE_STRING,
        },
        ["leaderboard_id", "period", "referrer_id", "rank", "score"],
    ),
    "leaderboard_opt_out_request": obj(
        {"program_id": ID, "opt_out": {"type": "boolean"}}, ["program_id", "opt_out"], additional=False
    ),
    "code_redeem_request": obj({"code": {"type": "string", "minLength": 3, "maxLength": 30}}, ["code"], additional=False),
    "code_redemption_response": obj(
        {
            "offline_touch_id": ID,
            "code": obj(
                {
                    "code": {"type": "string"},
                    "kind": {"enum": ["referral", "link"]},
                    "link_id": NULLABLE_STRING,
                    "campaign_id": NULLABLE_STRING,
                    "referrer_id": NULLABLE_STRING,
                    "program_id": NULLABLE_STRING,
                },
                ["code", "kind"],
            ),
            "referral": nullable(REFERRAL),
        },
        ["offline_touch_id", "code", "referral"],
    ),
    # ---- Change 06 (S.1): POST /v1/sdk/goals ----
    "goals_request": obj(
        {
            "goals": {"type": "array", "minItems": 1, "maxItems": 100, "items": GOAL_ITEM},
            "consent": nullable(CONSENT),
        },
        ["goals"],
        additional=False,
    ),
    "goals_response": obj(
        {
            # New goal events stored (counted or not: the SDK doesn't care).
            "accepted": {"type": "integer", "minimum": 0},
            # Items whose (goal, reference) was already received: success, removed from the queue.
            "duplicates": {"type": "integer", "minimum": 0},
            "rejected": {
                "type": "array",
                "items": obj(
                    {
                        "goal": {"type": "string"},
                        "reference": {"type": "string"},
                        "code": {"type": "string"},  # GOAL_REJECTION_CODES; unknown codes are treated as rejections
                        # For private_mode_field_rejected / validation_error: the field *name*
                        # (never its content).
                        "param": NULLABLE_STRING,
                        "message": {"type": "string"},
                        # Change 12: the item's position in the request, and for
                        # payment_goal_needs_confirmation the missing fields ("provider", "reference").
                        "index": {"type": ["integer", "null"]},
                        "missing": {"type": ["array", "null"], "items": {"enum": ["provider", "reference"]}},
                    },
                    ["goal", "reference", "code"],
                ),
            },
            # Change 12: one result per item, in request order (also for rejected items, as refused).
            # Absent from older servers: the SDKs then report accepted items as counted.
            "results": {"type": "array", "items": GOAL_RESULT},
        },
        ["accepted", "duplicates", "rejected"],
    ),
}

ULID = "01JAB3C4D5E6F7G8H9JKMNPQRS"

FIXTURES: dict[str, dict] = {
    "config_response": {
        "app_id": f"app_{ULID}",
        "environment": "production",
        "server_time": "2026-10-20T10:00:00Z",
        "link_domains": ["inv.myapp.com", "ciz.to"],
        "features": {
            "deferred_deep_linking": True,
            "pasteboard_matching": "on_interstitial_tap",
            "probabilistic_matching": False,
            "apple_search_ads": False,
            "uninstall_tracking": True,
            "collect_advertising_id": False,
            "restricted_mode": False,
            "attestation": {"ios_app_attest": "off", "android_play_integrity": "off"},
            "app_attribution": True,
            "referrals": True,
            "leaderboards": True,
            "identity_checks": False,
            "whatsapp_attribution": False,
            "offline_codes": True,
            "skan_postbacks": False,
        },
        "referral_programs": [
            {
                "id": f"rpg_{ULID}",
                "name": "Invite friends",
                "status": "active",
                "client_link_creation": True,
                "allow_manual_code_entry": True,
                "require_identity_token": True,
            }
        ],
        "conversion_value_schema": {
            "id": f"cvs_{ULID}",
            "version": 1,
            "rules": [
                {"fine_value": 1, "coarse_value": "low", "event": "signup", "lock_window": False},
                {
                    "fine_value": 20,
                    "coarse_value": "medium",
                    "event": "purchase",
                    "min_revenue_minor": 500000,
                    "currency": "NGN",
                    "lock_window": False,
                },
            ],
        },
        "batching": {
            "max_batch_size": 100,
            "flush_interval_seconds": 15,
            "flush_at_count": 20,
            "max_queue_events": 1000,
            "max_queue_bytes": 1048576,
        },
        "reattestation_interval_days": 7,
        "session_timeout_minutes": 30,
        "consent": {
            "mode": "required_in_regions",
            "required": False,
            "region": "NG",
            "required_regions": ["EEA", "UK", "CH"],
            "anonymous_counts": False,
            "buffer_max_days": 7,
            "buffer_max_events": 1000,
            "identity_checks_basis": "fraud_prevention",
        },
        "min_supported_version": "1.0.0",
        "latest_version": "1.2.0",
        "version_status": "current",
        "blocked_instructions": None,
        "firebase_forwarding": {
            "enabled": False,
            "log_attribution_event": True,
            "set_user_properties": True,
            "mirror_events": False,
            "report_app_instance_id": True,
        },
    },
    "install_request_android": {
        "installation_id": "6a1f0c2e-4b7d-4c1a-9e2f-0d3b5a7c9e11",
        "app_version": "3.4.1",
        "sdk_version": "1.5.0",
        "platform": "android",
        "os_version": "14",
        "device_model": "Pixel 8",
        "locale": "en-NG",
        "timezone": "Africa/Lagos",
        "screen": {"w": 1080, "h": 2400, "scale": 2.625},
        "launch_url": None,
        "install_referrer": {
            "referrer": f"cg_click_id%3Dclk_{ULID}%26cg_link%3Dlnk_{ULID}%26gclid%3DCj0KCQjw-test_gclid",
            "referrer_click_timestamp_seconds": 1760954400,
            "install_begin_timestamp_seconds": 1760954460,
            "referrer_click_timestamp_server_seconds": 1760954400,
            "install_begin_timestamp_server_seconds": 1760954460,
            "install_version": "3.4.1",
            "google_play_instant": False,
        },
        "installer_package": "com.android.vending",
        "push": {"provider": "fcm", "token": "fcm-token-123", "apns_environment": None},
        "consent": {
            "analytics": "granted",
            "attribution": "granted",
            "ad_user_data": "denied",
            "ad_personalization": "unknown",
            "region": None,
            "updated_at": "2026-10-20T09:58:00.000Z",
        },
        "google_click_ids": {"gclid": "Cj0KCQjw-test_gclid", "gbraid": None, "wbraid": None, "source": "install_referrer"},
        "attestation": {"type": "play_integrity", "token": "eyJhbGciOi.test", "challenge": f"atc_{ULID}", "request_type": "standard"},
        "is_emulator": False,
        "is_rooted": False,
    },
    "install_request_ios": {
        "installation_id": "b8c2d4e6-1a3c-4e5f-8a7b-9c0d1e2f3a4b",
        "keychain_previous_installation_id": None,
        "app_version": "3.4.1",
        "sdk_version": "1.5.0",
        "platform": "ios",
        "os_version": "18.1",
        "device_model": "iPhone15,2",
        "locale": "en-NG",
        "timezone": "Africa/Lagos",
        "launch_url": None,
        "pasteboard_token": "cgdl_9Xk2abcdefghijklmnopqrstuv",
        "push": {"provider": "apns", "token": "a1b2c3d4", "apns_environment": "production"},
        "consent": {
            "analytics": "granted",
            "attribution": "granted",
            "ad_user_data": "denied",
            "ad_personalization": "unknown",
            "region": None,
            "updated_at": "2026-10-20T09:58:00.000Z",
        },
        "google_click_ids": {"gclid": None, "gbraid": "0AAAAAtestgbraid", "wbraid": None, "source": "deep_link"},
        "device_check_token": "ZGV2aWNlY2hlY2stdG9rZW4=",
        "google_on_device_measurement": {"odm_info": "abcdEfadGdaf", "sdk_version": "3.7.0"},
        "is_emulator": False,
    },
    "install_response_referral": {
        "install_id": f"ins_{ULID}",
        "attribution": {
            "status": "attributed",
            "match_type": "install_referrer",
            "confidence": 1.0,
            "click_id": f"clk_{ULID}",
            "clicked_at": "2026-10-20T09:59:00Z",
            "is_reinstall": False,
            "link": {
                "id": f"lnk_{ULID}",
                "kind": "referral",
                "external_reference": None,
                "campaign_id": None,
                "metadata": {},
            },
        },
        "deep_link": {
            "url": "https://inv.myapp.com/r/ADA42",
            "path": "/welcome",
            "data": {"ref": "ADA42", "screen": "referral_welcome"},
            "is_deferred": True,
        },
        "referral": {
            "referral_id": f"ref_{ULID}",
            "program_id": f"rpg_{ULID}",
            "status": "installed",
            "source": "link",
            "referrer_id": f"rfr_{ULID}",
            "referrer_display_name": "Ada",
            "created_at": "2026-10-20T10:00:01Z",
        },
        "retry_after_ms": None,
    },
    "install_response_organic": {
        "install_id": f"ins_{ULID}",
        "attribution": {
            "status": "organic",
            "match_type": None,
            "confidence": None,
            "click_id": None,
            "clicked_at": None,
            "is_reinstall": False,
            "link": None,
        },
        "deep_link": None,
        "referral": None,
        "retry_after_ms": None,
    },
    "install_response_pending": {
        "install_id": f"ins_{ULID}",
        "attribution": {
            "status": "pending",
            "match_type": None,
            "confidence": None,
            "click_id": None,
            "clicked_at": None,
            "is_reinstall": False,
            "link": None,
        },
        "deep_link": None,
        "referral": None,
        "retry_after_ms": 2000,
    },
    "resolve_response_matched": {
        "matched": True,
        "click_id": f"clk_{ULID}",
        "deep_link": {
            "url": "https://inv.myapp.com/p/dress",
            "path": "/products/42",
            "data": {"product_id": "42"},
            "is_deferred": False,
        },
        "link": {
            "id": f"lnk_{ULID}",
            "kind": "standard",
            "external_reference": "off_7",
            "campaign_id": None,
            "metadata": {"creator_id": "cr_91"},
        },
        "is_reengagement": False,
        "referral": None,
        "match_type": "app_link",
    },
    "resolve_response_unmatched": {
        "matched": False,
        "click_id": None,
        "deep_link": None,
        "link": None,
        "is_reengagement": False,
        "referral": None,
    },
    "events_request": {
        "events": [
            {
                "event_id": "4f1c2b3a-5d6e-4f70-8a9b-0c1d2e3f4a5b",
                "name": "purchase",
                "occurred_at": "2026-10-20T10:02:41.123Z",
                "revenue_minor": 1500000,
                "currency": "NGN",
                "properties": {"order_id": "A-1001"},
            }
        ]
    },
    "events_response": {"accepted": 1, "duplicates": 0, "rejected": []},
    "identify_response": {"customer_user_id": "user_42", "identity_verified": True, "person_id": f"per_{ULID}", "label_ignored": None},
    "referral_link_response": {
        "referrer_id": f"rfr_{ULID}",
        "program_id": f"rpg_{ULID}",
        "code": "ADA42X",
        "url": "https://inv.myapp.com/r/ADA42X",
        "short_url": "https://inv.myapp.com/a8K2bq",
    },
    "referral_stats_response": {
        "referrer_id": f"rfr_{ULID}",
        "program_id": f"rpg_{ULID}",
        "code": "ADA42X",
        "url": "https://inv.myapp.com/r/ADA42X",
        "short_url": "https://inv.myapp.com/a8K2bq",
        "status": "active",
        "stats": {
            "clicks": 12,
            "installs": 4,
            "signups": 3,
            "in_progress": 1,
            "qualified": 2,
            "disqualified": 0,
            "rejected": 1,
        },
    },
    "referral": {
        "referral_id": f"ref_{ULID}",
        "program_id": f"rpg_{ULID}",
        "status": "installed",
        "source": "code_entry",
        "referrer_id": f"rfr_{ULID}",
        "referrer_display_name": "Ada",
        "created_at": "2026-10-20T10:00:01Z",
    },
    "referred_by_response": {
        "referred": True,
        "referral": {
            "referral_id": f"ref_{ULID}",
            "program_id": f"rpg_{ULID}",
            "status": "holding",
            "source": "link",
            "referrer_id": f"rfr_{ULID}",
            "referrer_display_name": "Ada",
            "created_at": "2026-10-20T10:00:01Z",
        },
    },
    "error_code_not_found": {
        "error": {
            "type": "not_found",
            "code": "code_not_found",
            "message": "No active referrer has this code.",
            "param": "code",
            "request_id": f"req_{ULID}",
        }
    },
    "error_rate_limited": {
        "error": {
            "type": "rate_limited",
            "code": "rate_limited",
            "message": "Too many requests. Retry later.",
            "param": None,
            "request_id": f"req_{ULID}",
        }
    },
    "feature_disabled": {"accepted": False, "reason": "feature_disabled", "feature": "leaderboards"},
    "leaderboard_page": {
        "leaderboard_id": f"lb_{ULID}",
        "name": "Weekly top inviters",
        "metric": "qualified",
        "segment": None,
        "period": {"key": "2026-W43", "status": "open", "starts_at": "2026-10-19T23:00:00Z", "ends_at": "2026-10-26T23:00:00Z"},
        "entries": [
            {"rank": 1, "referrer_id": f"rfr_{ULID}", "display": "Ada O.", "score": 12, "pending": 3, "is_me": False},
            {"rank": 2, "referrer_id": "rfr_01JAB3C4D5E6F7G8H9JKMNPQRT", "display": "B**42X", "score": 9, "pending": 0, "is_me": True},
        ],
    },
    "my_rank": {
        "leaderboard_id": f"lb_{ULID}",
        "period": {"key": "2026-W43", "status": "open", "starts_at": "2026-10-19T23:00:00Z", "ends_at": "2026-10-26T23:00:00Z"},
        "referrer_id": "rfr_01JAB3C4D5E6F7G8H9JKMNPQRT",
        "rank": 2,
        "score": 9,
        "pending": 0,
        "gap_to_next": 3,
        "best_rank": 2,
        "period_ends_at": "2026-10-26T23:00:00Z",
        "opted_out": False,
        "embed_token": None,
        "embed_url": None,
    },
    "code_redemption_response": {
        "offline_touch_id": f"oft_{ULID}",
        "code": {"code": "LAGOS50", "kind": "link", "link_id": f"lnk_{ULID}", "campaign_id": None, "referrer_id": None, "program_id": None},
        "referral": None,
    },
    "error_code_expired": {
        "error": {"type": "conflict", "code": "code_expired", "message": "This code has expired.", "param": "code", "request_id": f"req_{ULID}"}
    },
    "push_fcm_uninstall_check": {"cg": "uc"},
    "push_apns_uninstall_check": {"aps": {"content-available": 1}, "cg": {"t": "uc"}},
    # Not an API body: Clikgate's shared platform link domains (API_CONTRACT.md "Shared platform
    # domains"). Each SDK keeps the same list in one place and its tests compare it with this file.
    "shared_link_domains": {"shared_link_domains": SHARED_LINK_DOMAINS},
    "push_app_message": {"type": "chat", "body": "hi"},
}

# A pre-Part-3 server: `/config` without `link_domains` (SDKs fall back to the configured linkDomains).
FIXTURES["config_response_legacy"] = {k: v for k, v in FIXTURES["config_response"].items() if k != "link_domains"}

# Fraud signals set (change 02, B.5.2; SDK 1.2 body without consent set or attestation): an emulator / rooted Android install whose Play install-begin
# time is earlier than the referrer click (`install_before_click`), and a jailbroken iOS install.
UNKNOWN_CONSENT = {
    "analytics": "unknown",
    "attribution": "unknown",
    "ad_user_data": "unknown",
    "ad_personalization": "unknown",
    "region": None,
    "updated_at": None,
}
FIXTURES["install_request_android_signals"] = {
    **{k: v for k, v in FIXTURES["install_request_android"].items() if k not in ("attestation", "screen")},
    "consent": UNKNOWN_CONSENT,
    "device_model": "sdk_gphone64_arm64",
    "install_referrer": {
        **FIXTURES["install_request_android"]["install_referrer"],
        "referrer_click_timestamp_seconds": 1760954400,
        "install_begin_timestamp_seconds": 1760954395,
        "referrer_click_timestamp_server_seconds": 1760954400,
        "install_begin_timestamp_server_seconds": 1760954395,
    },
    "is_emulator": True,
    "is_rooted": True,
}
# iOS SDK 1.1.0 sent `is_rooted` (jailbreak heuristics) and `screen`; 1.2.0 sends neither (change 03,
# S.2). The fixture keeps the 1.1 shape: old SDKs in the field still send it and the schema accepts it.
FIXTURES["install_request_ios_signals"] = {
    **{k: v for k, v in FIXTURES["install_request_ios"].items() if k not in ("google_click_ids", "device_check_token", "google_on_device_measurement")},
    "sdk_version": "1.1.0",
    "consent": {"tracking_allowed": True},
    "screen": {"w": 1179, "h": 2556, "scale": 3},
    "is_emulator": False,
    "is_rooted": True,
}

# Change 09 (X.E23): the opted-out first /install (`setTrackingEnabled(false)` before the first
# launch): the required fields and the consent object with every purpose denied, nothing else. It
# replaces the old `{"tracking_allowed": false}` body.
FIXTURES["install_request_opted_out"] = {
    "installation_id": FIXTURES["install_request_android"]["installation_id"],
    "app_version": "3.4.1",
    "sdk_version": "1.5.0",
    "platform": "android",
    "consent": {
        "analytics": "denied",
        "attribution": "denied",
        "ad_user_data": "denied",
        "ad_personalization": "denied",
        "region": None,
        "updated_at": None,
    },
}

# ---- Change 03 fixtures ----
FIXTURES["config_response_consent_required"] = {
    **FIXTURES["config_response"],
    "consent": {
        "mode": "required_in_regions",
        "required": True,
        "region": "DE",
        "required_regions": ["EEA", "UK", "CH"],
        "anonymous_counts": True,
        "buffer_max_days": 7,
        "buffer_max_events": 1000,
        "identity_checks_basis": "consent",
    },
    "firebase_forwarding": {
        "enabled": True,
        "log_attribution_event": True,
        "set_user_properties": True,
        "mirror_events": True,
        "report_app_instance_id": True,
    },
}
FIXTURES["config_response_deprecated"] = {
    **FIXTURES["config_response"],
    "min_supported_version": "1.2.0",
    "latest_version": "1.4.0",
    "version_status": "deprecated",
}
FIXTURES["config_response_blocked"] = {
    **FIXTURES["config_response"],
    "min_supported_version": "1.3.0",
    "latest_version": "1.4.0",
    "version_status": "blocked",
    "blocked_instructions": {
        "allowed_calls": ["config", "install", "open", "events", "opt_out", "consent", "install_ping"],
        "allowed_events": ["purchase", "sign_up"],
        "strip_event_properties": True,
        "message": "Clikgate SDK 1.2.x is blocked. Update to 1.4.0 or later.",
    },
}
FIXTURES["install_response_attributed_source"] = {
    **FIXTURES["install_response_referral"],
    "attribution": {
        **FIXTURES["install_response_referral"]["attribution"],
        "match_type": "app_link",
        "source": "google",
        "medium": "cpc",
        "campaign": "lagos_launch",
        "channel": "ads",
    },
}
FIXTURES["open_request"] = {
    "app_version": "3.4.1",
    "os_version": "14",
    "is_cold_start": True,
    "consent": FIXTURES["install_request_android"]["consent"],
    "google_click_ids": {"gclid": "Cj0KCQjw-test_gclid", "gbraid": None, "wbraid": None, "source": "deep_link"},
    "app_instance_id": "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d",
}
FIXTURES["resolve_request"] = {
    "url": "https://inv.myapp.com/p/dress?gclid=Cj0KCQjw-test_gclid",
    "consent": FIXTURES["install_request_android"]["consent"],
    "google_click_ids": {"gclid": "Cj0KCQjw-test_gclid", "gbraid": None, "wbraid": None, "source": "deep_link"},
}
FIXTURES["events_request_consent"] = {**FIXTURES["events_request"], "consent": FIXTURES["install_request_android"]["consent"]}
FIXTURES["consent_request"] = {
    "consent": {
        "analytics": "granted",
        "attribution": "denied",
        "ad_user_data": "denied",
        "ad_personalization": "denied",
        "region": "EEA",
        "updated_at": "2026-10-20T10:05:00Z",
    }
}
FIXTURES["consent_response"] = {"ok": True}
FIXTURES["install_ping_request"] = {
    "platform": "android",
    "app_version": "3.4.1",
    "sdk_version": "1.5.0",
    "consent": {"analytics": "unknown", "attribution": "denied", "ad_user_data": "denied", "ad_personalization": "denied", "region": "DE", "updated_at": "2026-10-20T10:05:00Z"},
}
FIXTURES["install_ping_response"] = {"ok": True}
FIXTURES["attest_request_device_check"] = {
    "type": "app_attest_assertion",
    "challenge": f"atc_{ULID}",
    "token": "YXNzZXJ0aW9u",
    "key_id": "a2V5LWlk",
    "device_check_token": "ZGV2aWNlY2hlY2stdG9rZW4=",
    "consent": FIXTURES["install_request_android"]["consent"],
}

# ---- Change 06 fixtures ----
FIXTURES["config_response_private_mode"] = {**FIXTURES["config_response"], "latest_version": "1.3.0", "private_mode": True, "allow_labels": False}
FIXTURES["goals_request"] = {
    "goals": [
        {
            "goal": "account_opened",
            "reference": "APP-55231",
            "value": "2000000",
            "currency": "NGN",
            "is_first": True,
            "occurred_at": "2026-10-23T09:12:00.000Z",
            "click_id": f"clk_{ULID}",
        },
        {
            # No value, no reference from the app (SDK-generated UUID), no click known on the device.
            "goal": "kyc_passed",
            "reference": "0b7e4c1a-2f3d-4e5a-9b8c-7d6e5f4a3b2c",
            "occurred_at": "2026-10-23T09:10:02.512Z",
        },
        {"goal": "order_paid", "reference": "ORD-1001", "value": "1500.5", "currency": "USD", "is_first": False, "occurred_at": "2026-10-23T09:13:00.000Z", "click_id": None},
    ],
    "consent": FIXTURES["install_request_android"]["consent"],
}
FIXTURES["goals_response"] = {"accepted": 2, "duplicates": 1, "rejected": []}
FIXTURES["goals_response_rejected"] = {
    "accepted": 1,
    "duplicates": 0,
    "rejected": [
        {"goal": "kyc_passed", "reference": "0b7e4c1a-2f3d-4e5a-9b8c-7d6e5f4a3b2c", "code": "goal_not_found", "param": "goal", "message": "No active goal has this key."},
        {"goal": "order_paid", "reference": "ORD-1001", "code": "invalid_value", "param": "value", "message": "USD allows at most 2 decimal places."},
    ],
}

# Change 10 (D.5, contract B3a.2): deep-link-only mode (Free, Starter, or an app with attribution
# switched off). /config says app_attribution off and deep_linking on; the Free app subdomain is
# under clk.ng (an app subdomain, not the shared domain clk.ng itself).
FIXTURES["config_response_deep_link_only"] = {
    **FIXTURES["config_response"],
    "link_domains": ["yourapp.clk.ng", "inv.myapp.com"],
    "features": {**FIXTURES["config_response"]["features"], "app_attribution": False, "deep_linking": True},
}
# /events and /goals answer 200 with this no-op body: drop the batch, warn once ("needs Growth"), never retry.
FIXTURES["events_response_feature_disabled"] = {"accepted": False, "reason": "feature_disabled", "feature": "app_attribution"}
FIXTURES["goals_response_feature_disabled"] = {"accepted": False, "reason": "feature_disabled", "feature": "app_attribution"}
# /install: attribution is always the organic shape; deep_link is the deferred link when one matched...
ORGANIC_DEEP_LINK_ONLY = {
    "status": "organic",
    "match_type": None,
    "confidence": None,
    "click_id": None,
    "clicked_at": None,
    "is_reinstall": False,
    "link": None,
    "source": None,
    "medium": None,
    "campaign": None,
    "channel": "organic",
}
FIXTURES["install_response_deep_link_only"] = {
    "install_id": f"ins_{ULID}",
    "attribution": ORGANIC_DEEP_LINK_ONLY,
    "deep_link": {
        "url": "https://yourapp.clk.ng/p/dress",
        "path": "/products/42",
        "data": {"product_id": "42"},
        "is_deferred": True,
    },
    "referral": None,
    "retry_after_ms": None,
}
# ...and null at the monthly deferred deep link cap (the normal "no deferred link" result, never an error).
FIXTURES["install_response_deferred_cap"] = {**FIXTURES["install_response_deep_link_only"], "deep_link": None}

FIXTURE_SCHEMA = {
    "config_response": "config_response",
    "config_response_legacy": "config_response",
    "install_request_android": "install_request",
    "install_request_ios": "install_request",
    "install_request_android_signals": "install_request",
    "install_request_ios_signals": "install_request",
    "install_response_referral": "install_response",
    "install_response_organic": "install_response",
    "install_response_pending": "install_response",
    "resolve_response_matched": "resolve_response",
    "resolve_response_unmatched": "resolve_response",
    "events_request": "events_request",
    "events_response": "events_response",
    "identify_response": "identify_response",
    "referral_link_response": "referral_link_response",
    "referral_stats_response": "referral_stats_response",
    "referral": "referral",
    "referred_by_response": "referred_by_response",
    "error_code_not_found": "error",
    "error_rate_limited": "error",
    "feature_disabled": "feature_disabled",
    "leaderboard_page": "leaderboard_page",
    "my_rank": "my_rank",
    "code_redemption_response": "code_redemption_response",
    "error_code_expired": "error",
    "config_response_consent_required": "config_response",
    "config_response_deprecated": "config_response",
    "config_response_blocked": "config_response",
    "install_response_attributed_source": "install_response",
    "open_request": "open_request",
    "resolve_request": "resolve_request",
    "events_request_consent": "events_request",
    "consent_request": "consent_request",
    "consent_response": "consent_response",
    "install_ping_request": "install_ping_request",
    "install_ping_response": "install_ping_response",
    "attest_request_device_check": "attest_request",
    "config_response_private_mode": "config_response",
    "goals_request": "goals_request",
    "goals_response": "goals_response",
    "goals_response_rejected": "goals_response",
    "install_request_opted_out": "install_request",
    "config_response_deep_link_only": "config_response",
    "events_response_feature_disabled": "feature_disabled",
    "goals_response_feature_disabled": "feature_disabled",
    "install_response_deep_link_only": "install_response",
    "install_response_deferred_cap": "install_response",
}


# ---- Change 12 fixtures ----
# A Payment goal reported by the app: provider and reference, no value (the server would ignore it).
FIXTURES["goals_request_payment"] = {
    "goals": [
        {"goal": "purchase", "reference": "T123456", "occurred_at": "2026-10-28T10:00:00.000Z", "click_id": f"clk_{ULID}", "provider": "paystack"},
        {"goal": "account_opened", "reference": "APP-1", "occurred_at": "2026-10-28T10:00:01.000Z"},
    ],
    "consent": FIXTURES["install_request_android"]["consent"],
}
FIXTURES["goals_response_results"] = {
    "accepted": 2,
    "duplicates": 0,
    "rejected": [
        {"index": 2, "goal": "order_paid", "reference": "ORD-1", "code": "payment_goal_needs_confirmation", "param": "provider",
         "message": "order_paid is a Payment goal: send provider and reference so your payment provider or server can confirm it.",
         "missing": ["provider"]},
    ],
    "results": [
        {"index": 0, "goal": "account_opened", "reference": "APP-1", "status": "counted", "reason": None, "goal_kind": "standard",
         "counted": True, "value_ignored": False, "id": f"cnv_{ULID}"},
        {"index": 1, "goal": "purchase", "reference": "T123456", "status": "waiting", "reason": "waiting_for_confirmation",
         "goal_kind": "payment", "counted": False, "value_ignored": True, "id": f"prp_{ULID}"},
        {"index": 2, "goal": "order_paid", "reference": "ORD-1", "status": "refused", "reason": "payment_goal_needs_confirmation",
         "goal_kind": "payment", "counted": False, "value_ignored": False, "id": None},
    ],
}
FIXTURE_SCHEMA.update(
    {
        "goals_request_payment": "goals_request",
        "goals_response_results": "goals_response",
    }
)


# ---- Change 13: share helpers (Engage share.link, website share widget) ----
SHARE_APP = {"enum": json.loads((ROOT / "share_targets.json").read_text())["share_apps"]}
# POST /v1/share-events (SDK key, or a web key from the website widget). The SDKs send the URL that was shared
# (its ending tells Clikgate the version); `link_id` is the alternative. Endings in examples are made up.
SCHEMAS["share_event_request"] = obj(
    {
        "link_id": {"type": "string", "maxLength": 40},
        "url": {"type": "string", "maxLength": 2048},
        "app": SHARE_APP,
        "share_ending": {"anyOf": [{"type": "string", "pattern": "^[A-Za-z]$"}, {"type": "null"}]},
        "web_key": {"type": "string", "maxLength": 80},
    },
    ["app"],
    additional=False,
)
SCHEMAS["share_event_request"]["anyOf"] = [{"required": ["link_id"]}, {"required": ["url"]}]
SCHEMAS["share_event_response"] = obj(
    {
        "object": {"const": "share_event"},
        "id": ID,
        "link_id": ID,
        "app": SHARE_APP,
        "share_ending": NULLABLE_STRING,
        "source": {"enum": ["preview", "helper"]},
        "occurred_at": TIMESTAMP,
        "livemode": {"type": "boolean"},
    },
    ["object", "id", "link_id", "app", "source", "occurred_at"],
)
FIXTURES["share_event_request"] = {"url": "https://inv.myapp.com/summer-z", "app": "other"}
FIXTURES["share_event_response"] = {
    "object": "share_event",
    "id": f"shv_{ULID}",
    "link_id": f"lnk_{ULID}",
    "app": "other",
    "share_ending": "z",
    "source": "helper",
    "occurred_at": "2026-10-29T10:00:00Z",
    "livemode": False,
}
FIXTURE_SCHEMA.update({"share_event_request": "share_event_request", "share_event_response": "share_event_response"})

# ---- Change 14: identifyUser() and goal labels ----
FIXTURES["config_response_private_mode_labels"] = {**FIXTURES["config_response_private_mode"], "allow_labels": True}
FIXTURES["identify_request_label"] = {"label": "Ada (VIP)"}
FIXTURES["identify_request_user"] = {"customer_user_id": "user_42", "identity_token": "sig.1760954400", "label": "Ada"}
FIXTURES["identify_response_plan"] = {**FIXTURES["identify_response"], "label_ignored": "plan"}
FIXTURE_SCHEMA.update({
    "config_response_private_mode_labels": "config_response",
    "identify_request_label": "identify_request",
    "identify_request_user": "identify_request",
    "identify_response_plan": "identify_response",
    "identify_response": "identify_response",
})
# Test cases for every share.link implementation (Android, iOS, the web script): the URL each app gets.
# Internal test data, not documentation.
FIXTURES["share_cases"] = {
    "links": [
        {"url": "https://inv.myapp.com/summer", "app": "whatsapp", "expected": "https://inv.myapp.com/summer-w"},
        {"url": "https://inv.myapp.com/summer/", "app": "telegram", "expected": "https://inv.myapp.com/summer-g"},
        {"url": "https://inv.myapp.com/summer?utm_source=news#top", "app": "email",
         "expected": "https://inv.myapp.com/summer-e?utm_source=news#top"},
        {"url": "https://inv.myapp.com/summer-i", "app": "whatsapp", "expected": "https://inv.myapp.com/summer-w"},
        {"url": "https://inv.myapp.com/summer-W", "app": "sms", "expected": "https://inv.myapp.com/summer-s"},
        {"url": "https://inv.myapp.com/summer-q3", "app": "x", "expected": "https://inv.myapp.com/summer-x"},
        {"url": "https://inv.myapp.com/summer-dress-2026", "app": "linkedin",
         "expected": "https://inv.myapp.com/summer-dress-2026-l"},
        {"url": "https://inv.myapp.com/summer", "app": "slack", "expected": "https://inv.myapp.com/summer"},
        {"url": "https://inv.myapp.com/summer-w", "app": "other", "expected": "https://inv.myapp.com/summer"},
        {"url": "https://inv.myapp.com/", "app": "whatsapp", "expected": "https://inv.myapp.com/"},
        {"url": "https://inv.myapp.com", "app": "whatsapp", "expected": "https://inv.myapp.com"},
        {"url": "myapp://open/summer", "app": "whatsapp", "expected": "myapp://open/summer"},
        {"url": "https://inv.myapp.com/r/ADA42X", "code": "ADA42X", "app": "facebook",
         "expected": "https://inv.myapp.com/r/ADA42X-f"},
        {"url": "https://myapp.example/invite?ref=ADA42X&lang=en", "code": "ADA42X", "app": "sms",
         "expected": "https://myapp.example/invite?ref=ADA42X-s&lang=en"},
        {"url": "https://myapp.example/invite?ref=ADA42X", "code": "ADA42X", "app": "other",
         "expected": "https://myapp.example/invite?ref=ADA42X"},
    ],
    "texts": [
        {"message": None, "url": "https://inv.myapp.com/summer-w", "expected": "https://inv.myapp.com/summer-w"},
        {"message": "Join me on MyApp", "url": "https://inv.myapp.com/summer-w",
         "expected": "Join me on MyApp https://inv.myapp.com/summer-w"},
        {"message": "  ", "url": "https://inv.myapp.com/summer", "expected": "https://inv.myapp.com/summer"},
    ],
    "android_packages": {"com.whatsapp.w4b": "whatsapp", "com.facebook.orca": "facebook", "com.google.android.gm": "email",
                         "com.example.notes": "other"},
    "ios_activity_types": {
        "net.whatsapp.WhatsApp.ShareExtension": "whatsapp",
        "com.burbn.instagram.shareextension": "instagram",
        "ph.telegra.Telegraph.Share": "telegram",
        "com.apple.UIKit.activity.Message": "sms",
        "com.apple.UIKit.activity.Mail": "email",
        "com.apple.UIKit.activity.CopyToPasteboard": "other",
        "com.example.notes.share": "other",
        "net.whatsappfake.app": "other",
    },
}


# ---- Change 17 (R.2): opening the app directly must not skip the link gates ----
# Universal Links / App Links skip the redirect, so `/resolve` runs the same gates (allowed countries, password,
# smart-routing block rules, A/B split). `status` says which answer it is; `web_url` and `block_message` go with
# the gated ones. A gated answer carries no click, destination, deep link, link or referral, and `matched` is
# false, so SDKs from before Change 17 simply see no match.
RESOLVE_STATUS = {"enum": ["matched", "no_match", "password_required", "blocked"]}
_resolve = SCHEMAS["resolve_response"]
_resolve["properties"].update({
    "status": RESOLVE_STATUS,
    # password_required: the link's own URL (the password page); the SDK opens it in the system browser.
    "web_url": NULLABLE_STRING,
    # blocked: the text to show (the link's message, else the organisation's default); the SDK hands it to the app.
    "block_message": NULLABLE_STRING,
})
_resolve["required"] += ["status", "web_url", "block_message"]
_GATED_NULLS = {k: {"type": "null"} for k in ("click_id", "deep_link", "link", "referral", "match_type")}
_resolve["allOf"] = [
    {
        "if": {"properties": {"status": {"const": "password_required"}}, "required": ["status"]},
        "then": {"properties": {"matched": {"const": False}, "web_url": {"type": "string", "minLength": 1},
                                **_GATED_NULLS}},
    },
    {
        "if": {"properties": {"status": {"const": "blocked"}}, "required": ["status"]},
        "then": {"properties": {"matched": {"const": False}, "block_message": {"type": "string"}, **_GATED_NULLS}},
    },
    {
        "if": {"properties": {"status": {"const": "matched"}}, "required": ["status"]},
        "then": {"properties": {"matched": {"const": True}}},
    },
]
FIXTURES["resolve_response_matched"].update({"status": "matched", "web_url": None, "block_message": None})
FIXTURES["resolve_response_unmatched"].update({"status": "no_match", "web_url": None, "block_message": None})
_GATED = {"matched": False, "click_id": None, "deep_link": None, "link": None, "is_reengagement": False,
          "referral": None, "match_type": None}
FIXTURES["resolve_response_password_required"] = {
    **_GATED, "status": "password_required", "web_url": "https://inv.myapp.com/vip-offer", "block_message": None,
}
FIXTURES["resolve_response_blocked"] = {
    **_GATED, "status": "blocked", "web_url": None, "block_message": "This offer is only for customers in Nigeria.",
}
# An A/B test on the link: the server picked version B for this app open (R.3, the unit is the click) and the
# deep link path is that version's. The SDK delivers it unchanged.
FIXTURES["resolve_response_ab_variant"] = {
    **FIXTURES["resolve_response_matched"],
    "deep_link": {"url": "https://inv.myapp.com/menu", "path": "/menu/b", "data": {}, "is_deferred": False},
}
FIXTURE_SCHEMA.update({
    "resolve_response_password_required": "resolve_response",
    "resolve_response_blocked": "resolve_response",
    "resolve_response_ab_variant": "resolve_response",
})

# Change 17 (R.2), first launch: `/install` reports what the launch URL gave with the same `status` / `web_url` /
# `block_message` as `/resolve`. Optional (SDKs from before Change 17 ignore them) and null when the app wasn't
# opened with a launch URL. A gated launch URL carries no click and no deep link: Android opens `web_url` in the
# system browser (password) or delivers the blocked result; iOS re-resolves every launch URL and ignores the
# install deep link when the status is gated.
_install = SCHEMAS["install_response"]
_install["properties"].update({
    "status": {"enum": [*RESOLVE_STATUS["enum"], None]},
    "web_url": NULLABLE_STRING,
    "block_message": NULLABLE_STRING,
})
_INSTALL_GATED_NULLS = {"deep_link": {"type": "null"}}
_install["allOf"] = [
    {
        "if": {"properties": {"status": {"const": "password_required"}}, "required": ["status"]},
        "then": {"properties": {"web_url": {"type": "string", "minLength": 1}, **_INSTALL_GATED_NULLS,
                                "attribution": {"properties": {"click_id": {"type": "null"}}}}},
    },
    {
        "if": {"properties": {"status": {"const": "blocked"}}, "required": ["status"]},
        "then": {"properties": {"block_message": {"type": "string"}, **_INSTALL_GATED_NULLS,
                                "attribution": {"properties": {"click_id": {"type": "null"}}}}},
    },
]
FIXTURES["install_response_password_required"] = {
    **FIXTURES["install_response_organic"],
    "deep_link": None,
    "status": "password_required",
    "web_url": "https://shop.myapp.com/vip-offer",
    "block_message": None,
}
FIXTURES["install_response_blocked"] = {
    **FIXTURES["install_response_organic"],
    "deep_link": None,
    "status": "blocked",
    "web_url": None,
    "block_message": "This offer is only for customers in Nigeria.",
}
FIXTURE_SCHEMA.update({
    "install_response_password_required": "install_response",
    "install_response_blocked": "install_response",
})


# ---- Change 20 (S.1, R.40): `deeplink_handled` for the live check ("See it live") and the debug view ----
# When the app is handed a matched Clikgate deep link (direct from /resolve, deferred from /install), the SDK sends
# the path it handled: no query or fragment, every segment that looks like an ID, an email address or a phone number
# replaced with `:id` on the device (cases below). Only with a test SDK key (`cg_sdk_test_`), or when the /resolve or
# /install answer says the dashboard's debug view is open for this app (`debug_view: true`, optional, absent =
# false); never in normal live use. A call of its own: never queued with events, never metered, never an attributed
# event; one retry, failures dropped. Not sent while consent is pending or denied, after opt-out, for a blocked
# SDK version (unless `deeplink_handled` is in `allowed_calls`), for a gated (password / blocked) link, or for a
# link delivered locally without a server answer.
SCHEMAS["deeplink_handled_request"] = obj(
    {
        "path": {"type": "string", "minLength": 1, "maxLength": 512, "pattern": "^[^?#]*$"},
        "is_deferred": {"type": "boolean"},
    },
    ["path", "is_deferred"],
    additional=False,
)
SCHEMAS["deeplink_handled_response"] = obj({"ok": {"type": "boolean"}})
for _name in ("resolve_response", "install_response"):
    SCHEMAS[_name]["properties"]["debug_view"] = {"type": "boolean"}
FIXTURES["deeplink_handled_request"] = {"path": "/products/:id", "is_deferred": False}
FIXTURES["deeplink_handled_request_deferred"] = {"path": "/products/:id", "is_deferred": True}
FIXTURES["deeplink_handled_response"] = {"ok": True}
FIXTURES["resolve_response_debug_view"] = {
    **FIXTURES["resolve_response_matched"],
    "deep_link": {
        "url": "https://inv.myapp.com/p/dress",
        "path": "/u/ada%40example.com/orders/8f14e45f-ceea-467f-a0e6-0d2a0f7e3b9c?coupon=SAVE10#top",
        "data": {},
        "is_deferred": False,
    },
    "debug_view": True,
}
FIXTURES["install_response_debug_view"] = {**FIXTURES["install_response_deep_link_only"], "debug_view": True}
FIXTURE_SCHEMA.update({
    "deeplink_handled_request": "deeplink_handled_request",
    "deeplink_handled_request_deferred": "deeplink_handled_request",
    "deeplink_handled_response": "deeplink_handled_response",
    "resolve_response_debug_view": "resolve_response",
    "install_response_debug_view": "install_response",
})
# Test cases for every SDK's path cleaning (internal test data, not documentation): `path` → `expected`.
FIXTURES["deeplink_path_cases"] = {
    "cases": [
        {"path": "/products/42", "expected": "/products/:id"},
        {"path": "/products/42?ref=summer&cg_click_id=clk_1#reviews", "expected": "/products/:id"},
        {"path": "/menu/b#top", "expected": "/menu/b"},
        {"path": "/orders/8f14e45f-ceea-467f-a0e6-0d2a0f7e3b9c/receipt", "expected": "/orders/:id/receipt"},
        {"path": "/orders/8F14E45FCEEA467FA0E60D2A0F7E3B9C", "expected": "/orders/:id"},
        {"path": "/u/ada@example.com", "expected": "/u/:id"},
        {"path": "/u/ada%40example.com/settings", "expected": "/u/:id/settings"},
        {"path": "/call/+2348055550100", "expected": "/call/:id"},
        {"path": "/call/%2B234%20805%20555%200100", "expected": "/call/:id"},
        {"path": "/call/(555)%20010-0199", "expected": "/call/:id"},
        {"path": "/t/AbCdEfGhIjKlMnOpQrSt", "expected": "/t/:id"},
        {"path": "/t/eyJhbGciOiJIUzI1NiJ9", "expected": "/t/:id"},
        {"path": "/invite/ADA42XYZ", "expected": "/invite/:id"},
        {"path": "/order-1234567/track", "expected": "/:id/track"},
        {"path": "/blog/2026/11/04/new-menu", "expected": "/blog/:id/:id/:id/new-menu"},
        {"path": "/sale/summer-2026", "expected": "/sale/summer-2026"},
        {"path": "/products/iphone-15-pro", "expected": "/products/iphone-15-pro"},
        {"path": "/help/internationalization", "expected": "/help/internationalization"},
        {"path": "/v2/home/", "expected": "/v2/home/"},
        {"path": "products/42", "expected": "products/:id"},
        {"path": "/", "expected": "/"},
        {"path": "", "expected": "/"},
        {"path": "?tab=1", "expected": "/"},
    ],
}

def main() -> None:
    (ROOT / "schemas").mkdir(exist_ok=True)
    (ROOT / "fixtures").mkdir(exist_ok=True)
    for name, schema in SCHEMAS.items():
        body = {"$schema": DRAFT, "$id": f"https://sdk.clikgate.com/schemas/{name}.schema.json", "title": name}
        body.update(schema)
        (ROOT / "schemas" / f"{name}.schema.json").write_text(json.dumps(body, indent=2) + "\n")
    for name, fixture in FIXTURES.items():
        (ROOT / "fixtures" / f"{name}.json").write_text(json.dumps(fixture, indent=2) + "\n")
    (ROOT / "fixtures" / "_schema_map.json").write_text(json.dumps(FIXTURE_SCHEMA, indent=2) + "\n")
    try:
        import jsonschema
    except ImportError:
        print("jsonschema not installed; skipped fixture validation")
        return
    for p in PROVIDERS:
        jsonschema.validate(p, PROVIDER)
    for fixture, schema_name in FIXTURE_SCHEMA.items():
        schema = json.loads((ROOT / "schemas" / f"{schema_name}.schema.json").read_text())
        jsonschema.validate(FIXTURES[fixture], schema)
    print(f"{len(SCHEMAS)} schemas, {len(FIXTURES)} fixtures, all fixtures valid")


if __name__ == "__main__":
    main()
