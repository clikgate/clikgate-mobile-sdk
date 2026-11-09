# Clikgate Change 23 — "Allow Unknown Goal Names" and Goal Groups

> **Instructions for the AI building this:**
> - Changes 01–22 are built; nothing is live yet. This is a small change on top of change 22's goal system.
> - **The parts, built in this order:**
>
>   | Section | What | Plan |
>   |---|---|---|
>   | U | **"Allow unknown goal names"** setting (on: keep names for 30 days; off: refuse them) | All |
>   | GG | **Goal groups** (labels to organise goals, filters everywhere) | All |
>
> - **Backend repository:** U, GG (backend), S, T. **Dashboard repository:** DB, T. **Website repository:** W (docs).
> - **How to build and test (owner's routine):**
>   - build all milestones with tests, without running the full suite after each;
>   - then run the full suite once, fix every failure, and re-run until all pass;
>   - then follow section T.
> - **Reuse:**
>   - change 22: G ("Seen from your app and website", `GoalStatus.received`), E (suggestions, aliases, typo warnings), P (Explore), M (targets), R.9, R.10, R.14, R.20, R.45 (`goal_names`, `goal_aliases`);
>   - change 12: goal kinds and responses;
>   - change 13: permissions;
>   - change 16: metric registry;
>   - change 20: default dashboards and sample organisations;
>   - the change 17 J catalogue.
> - **Section R (review fixes) at the end wins over earlier text.**
> - **Owner rules:**
>   - links never break;
>   - revenue counts confirmed payments only;
>   - describe, never predict;
>   - never log secrets, tokens, customer IDs or labels;
>   - Clikgate never messages the business's customers.

## 0. Decisions
| # | Decision |
|---|---|
| D1 | **Unknown goal names:** one organisation setting, default **on** (keep for 30 days, change 22 behaviour). **Off** refuses them immediately with `unknown_goal`. The server never auto-creates or auto-counts goals (Option B declined). |
| D2 | **Goal groups** are labels only. They never change counting, billing, attribution, ad network sending or webhook delivery. Every plan. |
| D3 | **Not in this change** (discussed, not decided): a "Confirmed by" label on payments; a strict "provider-confirmed only" setting per payment goal; a Paystack confirmation relay; repeat customers by channel; "check this value" warnings; offline goal CSV upload. |

## U. "Allow unknown goal names"
Builds on change 22 (G, R.9, R.10, R.14, R.20) and change 12.
- A new organisation setting in Goals settings: **"Allow unknown goal names"** (`goals.allow_unknown_names`).
  - **Default: on.** Only Owner and Admin can change it (`goals_payments:manage`), and changes are audit-logged.
  - **On (default):** names with no goal behind them are kept for 30 days as `received` and shown in "Seen from your app and website" (change 22 G, R.9, R.14). The response is `{status: "received", reason: "not_counted_yet", counted: false}`.
  - **Off (strict):** names with no goal behind them are **refused immediately**:
    - not stored and not shown in "Seen from your app and website", for every sender (server, app, website);
    - response `200 {status: "refused", reason: "unknown_goal", counted: false}` (SDKs treat it as final and don't retry; debug builds log "Goal `{name}` isn't set up in Clikgate");
    - E.1 suggestions, E.3 typo warnings and rename detection have nothing to work from, which the setting's help text says.
    - **The no-goals checks still run.** While refusals are happening, they add the fact "{n} calls were refused this week because the goal isn't set up: {top names}". Names are shown to members with `goals_payments:view` only. The counts also appear in the dashboard Goals page.
  - **Either way:** aliases count as set-up names; archived goals follow change 22 R.10 when the setting is on, and are refused with reason `goal_archived` when it's off.
  - **Switching off** doesn't delete names already kept; they expire after 30 days as usual. **Switching on** starts keeping new names from that moment.
  - **Help text:**
    - **On:** "Goal names your app, website or server sends before they're set up are kept for 30 days, so you can count them later. They never count until you choose."
    - **Off:** "Only goals you've set up are accepted. Anything else is refused, and your developer sees `unknown_goal`."
  - **Docs** ("Sending goals" and the "Identify your users" troubleshooting) explain both responses.
  - **Tests:**
    - both modes for every sender;
    - aliases and archived goals;
    - no storage when off;
    - the refusal counts in the no-goals check;
    - switching modes;
    - SDK no-retry behaviour.

## GG. Goal groups
- **Groups:** Owner and Admin, or `goals_payments:manage`, can create **goal groups** to organise goals, for example "Getting customers" (sign-up, account opened), "Getting started" (first deposit, KYC done) and "Money" (purchase).
  - Each goal belongs to **at most one group**, or none.
  - Groups have a name (≤ 40 characters), an optional colour from the dashboard palette, and an order.
  - At most 20 groups per organisation.
- **Default:** none. On the Goals page, a gentle "Organise your goals into groups" tip appears when an organisation has 6 or more goals.
  - An optional "Suggest groups" button proposes groups from goal types and names (for example payment goals → "Money"). It's applied only on click.
- **Where groups appear:**
  - **Goals page:** goals listed by group (collapsible), with drag-and-drop to move goals between groups.
  - **"Seen from your app and website"** (change 22): the "Count this as a goal" dialog can pick a group.
  - **Filters:** a "Goal group" filter and breakdown in reports, Explore (change 22 P), dashboards and widgets (metric registry dimension `goal_group`), funnels' goal picker, targets (change 22 M) and the campaign table goal columns (show or hide a whole group).
  - **Default dashboards:** the "Top goals" widget can be filtered by group.
- **Rules:**
  - groups are labels only: they never change counting, billing, attribution, ad network sending or webhooks;
  - deleting a group leaves its goals ungrouped;
  - archived goals keep their group;
  - groups are environment-scoped like goals (live and test separate).
- **API:**
  - `GET` / `POST` / `PATCH` / `DELETE /v1/goal-groups`;
  - goals gain `group_id` (nullable) on `GET` / `PATCH /v1/goals`;
  - `goal.completed` webhooks and exports carry `goal_group` (name), and this is noted in the webhook changelog.
- **Plans:** every plan.
- **Sample organisations** (change 20) get example groups.
- **Tests:**
  - CRUD and the limits;
  - one group per goal;
  - deleting leaves goals ungrouped;
  - filters and breakdowns in reports, Explore and widgets;
  - suggest groups only on click;
  - counting and billing unchanged;
  - test and live separation;
  - permissions.

## S. SDKs
- **All SDKs** (mobile, web script, server) recognise `status: "refused"` with `reason: "unknown_goal"` as final, with no retry and no offline re-queue, and log the debug message in debug builds only.
- If the SDKs already treat `refused` as final (change 12), only the debug message and tests are added.
- **Tests:** per SDK.

## Milestones
- **Backend:**
  1. **C23-B1:** U, plus the SDK changes (S).
  2. **C23-B2:** GG.

  Regenerate the OpenAPI files (change 21 R.41 audiences: `/v1/goal-groups` is `public`); update `docs/PROGRESS.md`.
- **Dashboard:** **C23-F1:**
  - Goals settings toggle with its help text;
  - refusal counts on the Goals page;
  - goal groups on the Goals page (collapsible, drag-and-drop, Suggest groups, tip);
  - the group picker in the tick dialog;
  - "Goal group" filters and breakdowns everywhere listed;
  - Playwright tests.
- **Website:** **C23-W1:** docs updates ("Sending goals" responses, "Goal groups" page, API reference, `.md` copies and llms files).

## DB. Dashboard
Every screen named in U and GG, with permissions, light and dark, phone and desktop, and axe. Groups show their colour as a small dot only (never the sole way to tell groups apart).

## W. Website
- **Docs:** "Sending goals" (`received` vs `refused`/`unknown_goal`) and a short "Goal groups" page.
- **API reference** for `/v1/goal-groups`.
- **Checks:** live features only; banned-word scan.

## T. Final test run, database reset and demo data
Follow change 16 T and change 22 T, with these additions:
- **Bloom Foods (demo):** setting on, with goals in three groups ("Getting customers", "Getting started", "Money") and one ungrouped goal.
- **A second demo organisation:** setting **off**, with 14 refused calls this week for `order_paid`, shown on the Goals page.
- **Sample organisations:** example groups.
- **The final report:** test counts and the sign-in table.

## Definition of done
- The setting works in both modes for every sender, with correct responses, no storage when off, and refusal counts shown.
- Goal groups can be created and used as filters and breakdowns everywhere listed, and change nothing about counting, billing or sending.
- Docs updated.
- All tests pass, including every earlier change.

## Before building: things only the owner can provide
Nothing.

---

## R. Review fixes (these win over every earlier section)
An independent review checked this change against changes 05, 09, 11, 12, 13, 16, 20, 21 and 22. Each rule replaces the earlier text it names.

### The setting
- **R.1 [U, change 12 B.2, change 22 G.1]** Status codes:
  - a strict-mode refusal is **`422 {status: "refused", reason: "unknown_goal", counted: false, goal_kind: null}`**, like `payment_goal_needs_confirmation`;
  - an archived goal in strict mode returns `422 {status: "refused", reason: "goal_archived"}`, never change 05's `410`;
  - `unknown_goal` is added to the OpenAPI reason list.

  Status-code tests for each sender.
- **R.2 [U]** The order of checks:
  1. name format (`422`, change 22 G.1);
  2. key and environment;
  3. unknown or archived name (`unknown_goal` / `goal_archived`);
  4. "Allow from browser" (change 09);
  5. payment fields (`payment_goal_needs_confirmation`).

  In strict mode, an unknown name sent with `provider` and `reference` gets `unknown_goal`. Tests in this order.
- **R.3 [U]** "Not stored" means no event row, no `goal_names` entry and no timeline entry.
  - **Refusals are kept only as daily counts** in `goal_name_refusals` (organisation, environment, source: app or website and platform, name), deleted after 30 days and included in privacy deletion.
  - At most 200 distinct refused names per app or website per day; the rest go into one "other names" count.
  - Refused calls don't count toward the change 22 R.14 caps or the `too_many_event_names` limit.
- **R.4 [U, change 22 R.20]** The refusal fact doesn't need a counted goal:
  - it shows on the Goals page and the Getting started item as soon as any call is refused, even when the R.20 check would skip;
  - "this week" means the last 7 days, Lagos time;
  - alerts use the existing `goals_stopped` key, routed to `goals_payments:view`;
  - the weekly summary shows counts only.
- **R.5 [U, change 22 G.0, E.3]** In strict mode, rename detection and typo warnings use the refusal counts, for example: "`purchase` stopped; `purchase_done` was refused 40 times since 6 Nov. Add as an alias?" This replaces the help text line saying they "have nothing to work from".
- **R.6 [U, change 20 F, change 22 E.4]** The setting is per organisation and applies **to live only**.
  - Test mode always keeps names as `received`, so "See it live" works.
  - While strict mode is on, test-mode names show "In live, this name would be refused (`unknown_goal`)".

  Tests.
- **R.7 [U, change 13]** Permissions and refresh:
  - changing the setting needs `goals_payments:manage` and reading it needs `goals_payments:view` (instead of "Only Owner and Admin"), so custom roles work;
  - every change is audit-logged with the old value, the new value and who made it;
  - the intake's cache picks up a change within 60 seconds.

  Test the custom-role case.
- **R.8 [U, change 22 R.12, R.15]** Switching modes:
  - **switching off:** names already kept stay listed, and can still be counted with the 30-day option until they expire;
  - **switching on:** previously refused names have no backfill. Their Goals page row offers "Set up this goal" (`POST /v1/goals`, counted from creation, change 22 R.11, "from now on" only);
  - **setting up a payment goal from a refused name** shows change 22 R.15's warning without the 30-day share, because no events were kept.
- **R.9 [U, S]** SDK behaviour:
  - SDKs never check names on the device and never cache the setting; only the server decides;
  - server SDKs show the message only when debug logging is on;
  - the message includes the goal name only, never `reference`, `customer_id`, values or labels.

  Tests for every SDK, including the web script's automatic payment detection (change 11) when the default payment goal is missing.

### Goal groups
- **R.10 [GG, change 13, change 22 R.45]** Data model:
  - **table** `goal_groups` (`ggr_`): organisation, environment, name, colour, position, created_at, updated_at;
  - **names** are unique per organisation and environment, case-insensitive (`409 goal_group_name_taken`);
  - **goal link:** `goals.group_id` references a group and is set to null when the group is deleted. A group from another environment is refused (`422 goal_group_environment_mismatch`);
  - **limit:** 20 groups per environment (`422 too_many_goal_groups`);
  - **routes:** `GET` / `POST /v1/goal-groups`; `GET` / `PATCH` / `DELETE /v1/goal-groups/{id}`; `POST /v1/goal-groups/reorder {ids[]}`;
  - **permissions:** `goals_payments:view` to read and `goals_payments:manage` to change (instead of "Owner and Admin, or"); changes are audit-logged.
- **R.11 [GG]** Order and membership:
  - goals within a group follow the existing goal order;
  - ungrouped goals come last under "No group", which isn't a stored group;
  - received names have no group;
  - aliases always take their canonical goal's group and never have their own.
- **R.12 [GG, change 16]** A group is a **current label**:
  - reports, Explore and widgets group all history by each goal's current group, so moving a goal re-files its past numbers (the help text says so);
  - `goal_group` returns `null` ("No group") for ungrouped goals; archived goals stay in their group;
  - a filter on a deleted group is dropped from saved widgets, Explore views, shared views and campaign table settings, with the note "A goal group in this filter was deleted". It never errors.
- **R.13 [GG, change 22 M]** Targets and funnel steps stay on single goals. Groups only narrow the goal picker.
- **R.14 [GG, backend 6.8, change 22 R.17]** Webhooks and exports:
  - `goal.completed` gains `goal_group: {id, name} | null` in every `api_version`: additive, no new version, with a dated changelog entry;
  - the value is the group at send time; backfilled events use the group when they're sent;
  - exports add `goal_group` (the name) after `goal` and `received_as`.

  Test that old-schema validation still passes, with and without a group.
- **R.15 [GG, change 22 E.4]** "Also count this in live" puts the live goal in the live group with the same name if one exists, otherwise in no group. Groups are never copied between environments automatically.
- **R.16 [GG]** Suggestions, the tip and sample organisations:
  - "Suggest groups" uses fixed rules only (goal kind: payment → "Money"; change 22 `goal_suggestions.yml` categories), stays within the 20 limit, and never moves an already-grouped goal;
  - the tip can be dismissed, remembered per user;
  - sample organisations' groups are read-only (change 20 D5).
- **R.17 [GG, change 05]** Private mode doesn't change groups. Group names are business-made and appear in webhooks and exports.
  - The name field's help text says "Don't use customer names or IDs".
  - Logs record `group_id` only, never the name.

### Tests
- **R.18 [T, DB]** Add:
  - the R.2 check order and R.1 status codes;
  - the refusal table's cap and its 30-day deletion;
  - the refusal fact for an organisation with no counted goals;
  - the R.6 test-mode note;
  - the R.7 cache refresh;
  - re-filed history and the dropped deleted-group filter (R.12);
  - the R.14 webhook schema check;
  - the R.15 copy to live;
  - the R.10 limit, name-clash and environment-mismatch errors;
  - an axe check of the group dot shown with the group name.
