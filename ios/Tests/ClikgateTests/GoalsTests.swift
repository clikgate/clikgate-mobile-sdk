import XCTest
@_spi(ClikgateWrapper) @testable import Clikgate

/// goal(): Decimal values, providers, results, the shared queue and private mode.
final class GoalsTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
        server.on("POST /v1/sdk/goals", .fixture("goals_response"))
        server.on("POST /v1/sdk/consent", .ok)
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func stubConfig(_ name: String) {
        server.on("GET /v1/sdk/config", .fixture(name))
    }

    private func sentGoals() -> [[String: Any]] {
        server.requests("POST /v1/sdk/goals").flatMap { ($0.json["goals"] as? [[String: Any]]) ?? [] }
    }

    private func make() -> Clikgate {
        let sdk = Clikgate()
        sdk.configure(sdkKey: "cg_sdk_test", options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .none),
                      deps: h.deps(), startTimers: false)
        return sdk
    }

    /// Waits for the facade's first /install, then flushes.
    private func installedThenFlush(_ sdk: Clikgate) async {
        let core = sdk.currentCore!
        for _ in 0..<300 {
            if await core.currentState().installDone { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await core.flush()
    }

    /// A goal refused before it is queued: the completion comes at once.
    private func refusal(_ sdk: Clikgate, _ key: String, value: Decimal? = nil, currency: String? = nil,
                         reference: String? = nil) async -> ClikgateGoalResult {
        await withCheckedContinuation { cont in
            sdk.goal(key, value: value, currency: currency, reference: reference) { cont.resume(returning: $0) }
        }
    }

    // MARK: - Values and validation

    func testDecimalWireValuesRoundTrip() {
        let cases: [(String, String)] = [
            ("2000000", "2000000"), ("2E+6", "2000000"), ("1500.50", "1500.5"), ("0.10", "0.1"), ("0", "0"),
            ("0.00", "0"), ("0.005", "0.005"), ("999999999999999", "999999999999999"), ("1234567890123.45", "1234567890123.45"),
        ]
        for (input, wire) in cases {
            let d = Decimal(string: input, locale: Locale(identifier: "en_US_POSIX"))!
            XCTAssertEqual(Goals.wire(d), wire, input)
            // The wire string parses back to the same Decimal: no floating point anywhere.
            XCTAssertEqual(Decimal(string: wire, locale: Locale(identifier: "en_US_POSIX")), d, input)
            XCTAssertNil(Goals.validate(key: "order_paid", value: wire, currency: nil, reference: nil), input)
        }
        XCTAssertEqual(Goals.wire(Decimal(2_000_000)), "2000000")
        XCTAssertNil(Goals.wire(Decimal(-1)))
        XCTAssertNil(Goals.wire(Decimal.nan))
        XCTAssertEqual(Goals.significantDigits("0.005"), 1)
        XCTAssertEqual(Goals.significantDigits("2000000"), 7)
        XCTAssertEqual(Goals.normalize("007.500"), "7.5")
        for bad in ["-1", "1e5", "abc", "", "1.", ".5", " 1"] { XCTAssertNil(Goals.normalize(bad), bad) }
        XCTAssertEqual(Goals.validate(key: "order_paid", value: "1234567890123456", currency: nil, reference: nil)?.param, "value")
        XCTAssertEqual(Goals.validate(key: "order_paid", value: "0.1234567890123456", currency: nil, reference: nil)?.param, "value")
    }

    func testLocalValidation() {
        for bad in ["a", "Account", "1abc", "account-opened", "account opened", String(repeating: "a", count: 41), "", "_x"] {
            XCTAssertEqual(Goals.validate(key: bad, value: nil, currency: nil, reference: nil)?.param, "goal", bad)
        }
        for ok in ["ab", String(repeating: "a", count: 40), "account_opened_2"] {
            XCTAssertNil(Goals.validate(key: ok, value: nil, currency: nil, reference: nil), ok)
        }
        XCTAssertEqual(Goals.validate(key: "order_paid", value: "-0.01", currency: nil, reference: nil)?.param, "value")
        XCTAssertEqual(Goals.validate(key: "order_paid", value: "1", currency: "ngn", reference: nil)?.param, "currency")
        XCTAssertEqual(Goals.validate(key: "order_paid", value: nil, currency: nil, reference: "")?.param, "reference")
        XCTAssertEqual(Goals.validate(key: "order_paid", value: nil, currency: nil, reference: "  ")?.param, "reference")
        XCTAssertEqual(Goals.validate(key: "order_paid", value: nil, currency: nil, reference: String(repeating: "x", count: 129))?.param, "reference")
        XCTAssertEqual(Goals.validate(key: "A", value: nil, currency: nil, reference: nil)?.code, ClikgateError.invalidArgument)
    }

    func testFacadeReportsErrorsAndSendsTheContractItem() async throws {
        let sdk = make()
        let bad = await refusal(sdk, "Bad")
        XCTAssertEqual(bad, .refused(ClikgateError.invalidArgument))
        let negative = await refusal(sdk, "order_paid", value: -5)
        XCTAssertEqual(negative.status, .refused)
        let results = GoalResults()
        sdk.goal("account_opened", value: 2_000_000, currency: "NGN", reference: "APP-55231") { results.add($0) }
        sdk.goal("kyc_passed") { results.add($0) }
        await installedThenFlush(sdk)
        await eventually { results.count == 2 }
        // An older answer without `results`: accepted items count.
        XCTAssertEqual(results.all.map(\.status), [.counted, .counted])
        let req = try XCTUnwrap(server.requests("POST /v1/sdk/goals").first)
        XCTAssertNotNil(req.headers["Idempotency-Key"])
        XCTAssertNotNil(req.json["consent"] as? [String: Any])
        let goals = sentGoals()
        XCTAssertEqual(goals.count, 2)
        XCTAssertEqual(goals[0]["value"] as? String, "2000000")
        XCTAssertEqual(goals[0]["reference"] as? String, "APP-55231")
        XCTAssertEqual(goals[0]["currency"] as? String, "NGN")
        let fixture = try XCTUnwrap((Fixtures.json("goals_request")["goals"] as? [[String: Any]])?.first)
        XCTAssertTrue(Set(goals[0].keys).isSubset(of: Set(fixture.keys)), "\(goals[0].keys)")
        let ref = try XCTUnwrap(goals[1]["reference"] as? String)
        XCTAssertNotNil(ref.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression), ref)
        XCTAssertEqual(Set(goals[1].keys), ["goal", "reference", "occurred_at"])
        XCTAssertNotNil(ISO8601.parse(goals[1]["occurred_at"] as? String))
    }

    func testWrapperStringValues() async {
        let sdk = make()
        sdk.goal("order_paid", decimalString: "1500.50", currency: "USD", reference: "ORD-1", providerKey: " Stripe ", isFirst: false)
        let bad: ClikgateGoalResult = await withCheckedContinuation { c in
            sdk.goal("order_paid", decimalString: "12.3e4") { c.resume(returning: $0) }
        }
        XCTAssertEqual(bad, .refused(ClikgateError.invalidArgument))
        let badProvider: ClikgateGoalResult = await withCheckedContinuation { c in
            sdk.goal("order_paid", decimalString: nil, reference: "ORD-2", providerKey: "pay stack") { c.resume(returning: $0) }
        }
        XCTAssertEqual(badProvider, .refused(ClikgateError.invalidArgument))
        await installedThenFlush(sdk)
        let g = sentGoals().first
        XCTAssertEqual(g?["value"] as? String, "1500.5", "sent: \(g ?? [:])")
        XCTAssertEqual(g?["is_first"] as? Bool, false)
        XCTAssertEqual(g?["provider"] as? String, "stripe")
        XCTAssertEqual(sentGoals().count, 1)
    }

    func testNotConfiguredIsRefused() async {
        let r = await refusal(Clikgate(), "account_opened")
        XCTAssertEqual(r, .refused(ClikgateError.notConfigured))
    }

    // MARK: - Providers and results

    func testProviderFromString() {
        XCTAssertEqual(ClikgateProvider.fromString(" PayStack "), .paystack)
        XCTAssertEqual(ClikgateProvider.fromString("mtn_momo"), .mtnMomo)
        XCTAssertEqual(ClikgateProvider.fromString("newpay")?.rawValue, "newpay")
        for bad in ["", "p", "1pay", "pay-stack", "pay stack", String(repeating: "a", count: 31)] {
            XCTAssertNil(ClikgateProvider.fromString(bad), bad)
        }
        XCTAssertEqual(ClikgateProvider.checkoutCom.rawValue, "checkout_com")
        XCTAssertEqual(ClikgateProvider.peachPayments.rawValue, "peach_payments")
        XCTAssertEqual(ClikgateProvider.custom, ClikgateProvider.fromString("custom"))
    }

    func testPaymentGoalSendsProviderAndReferenceOnTheGoalsRoute() async throws {
        server.on("POST /v1/sdk/goals", .fixture("goals_response_results"))
        let sdk = make()
        let results = GoalResults()
        sdk.goal("account_opened", reference: "APP-1") { results.add($0, "account_opened") }
        sdk.goal("purchase", value: 5000, reference: "T123456", provider: .paystack) { results.add($0, "purchase") }
        await installedThenFlush(sdk)
        await eventually { results.count == 2 }
        let goals = sentGoals()
        XCTAssertNil(goals[0]["provider"])
        XCTAssertEqual(goals[1]["provider"] as? String, "paystack")
        XCTAssertEqual(goals[1]["reference"] as? String, "T123456")
        XCTAssertEqual(goals[1]["value"] as? String, "5000", "sent; the server ignores it for a Payment goal")
        XCTAssertNil(goals[1]["kind"], "the kind is never in the call")
        let fixture = try XCTUnwrap(Fixtures.json("goals_request_payment")["goals"] as? [[String: Any]])
        // Organic install here: no click_id to attach.
        XCTAssertTrue(Set(fixture[0].keys).subtracting(["click_id"]).isSubset(of: Set(goals[1].keys)), "\(goals[1].keys)")
        XCTAssertTrue(server.requests.allSatisfy { !$0.path.hasSuffix("/payments") })
        // goals_response_results: index 0 counted (standard), index 1 waiting (payment, value ignored).
        XCTAssertEqual(results.byKey["account_opened"], ClikgateGoalResult(status: .counted, reason: nil, goalKind: .standard, valueIgnored: false))
        XCTAssertEqual(results.byKey["purchase"], ClikgateGoalResult(status: .waiting, reason: "waiting_for_confirmation",
                                                                      goalKind: .payment, valueIgnored: true))
    }

    func testResultsAreMatchedByIndexIncludingRejectedItems() async {
        server.on("POST /v1/sdk/goals", .fixture("goals_response_results"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let results = GoalResults()
        for (key, ref) in [("account_opened", "APP-1"), ("purchase", "T123456"), ("order_paid", "ORD-1")] {
            await core.goal(key, value: nil, currency: nil, reference: ref, isFirst: nil, done: { r in results.add(r, key) })
        }
        await core.flush()
        await eventually { results.count == 3 }
        XCTAssertEqual(results.byKey["account_opened"]?.status, .counted)
        XCTAssertEqual(results.byKey["purchase"]?.status, .waiting)
        XCTAssertEqual(results.byKey["purchase"]?.reason, "waiting_for_confirmation")
        XCTAssertEqual(results.byKey["order_paid"], ClikgateGoalResult(status: .refused, reason: "payment_goal_needs_confirmation",
                                                                        goalKind: .payment, valueIgnored: false))
    }

    func testAnswerWithoutResultsAndBatchFailures() async {
        // An older answer without `results` (and rejections without `index`): the goals count.
        server.on("POST /v1/sdk/goals", .fixture("goals_response_rejected"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        let results = GoalResults()
        await core.goal("kyc_passed", value: nil, currency: nil, reference: "0b7e4c1a-2f3d-4e5a-9b8c-7d6e5f4a3b2c", isFirst: nil,
                        done: { results.add($0, "kyc") })
        await core.goal("signup_done", value: nil, currency: nil, reference: "S1", isFirst: nil, done: { results.add($0, "ok") })
        await core.flush()
        await eventually { results.count == 2 }
        XCTAssertEqual(results.byKey["kyc"]?.status, .counted)
        XCTAssertEqual(results.byKey["ok"]?.status, .counted)

        server.on("POST /v1/sdk/goals", .json(#"{"error":{"type":"invalid_request","code":"validation_error","message":"x"}}"#, status: 422))
        await core.goal("kyc_passed", value: nil, currency: nil, reference: "K2", isFirst: nil, done: { results.add($0, "422") })
        await core.flush()
        await eventually { results.count == 3 }
        XCTAssertEqual(results.byKey["422"], .refused("validation_error"))
    }

    func testAlreadyQueuedGoalAndOptOutRefusesQueuedGoals() async {
        server.on("POST /v1/sdk/goals", .offline())
        let core = h.makeCore()
        await core.start(startTimers: false)
        let results = GoalResults()
        await core.goal("order_paid", value: nil, currency: nil, reference: "ORD-9", isFirst: nil, done: { results.add($0, "a") })
        await core.goal("order_paid", value: nil, currency: nil, reference: "ORD-9", isFirst: nil, done: { results.add($0, "b") })
        await core.flush()
        await eventually { results.count == 1 }
        // The second call with the same key and reference is ignored: it is already queued.
        XCTAssertEqual(results.byKey["b"], ClikgateGoalResult(status: .waiting, reason: "already_queued", goalKind: nil, valueIgnored: false))
        XCTAssertNil(results.byKey["a"], "waits while offline")
        await core.setTrackingEnabled(false)
        await eventually { results.count == 2 }
        XCTAssertEqual(results.byKey["a"], .refused(ClikgateError.optedOut))
        let after: ClikgateGoalResult = await withCheckedContinuation { c in
            Task { await core.goal("order_paid", value: nil, currency: nil, reference: "ORD-10", isFirst: nil, done: { c.resume(returning: $0) }) }
        }
        XCTAssertEqual(after, .refused(ClikgateError.optedOut))
    }

    func testTestModeKeyLogsPaymentGoalResults() async {
        let plain = await h.makeCore().testMode
        XCTAssertFalse(plain)
        server.on("POST /v1/sdk/goals", .fixture("goals_response_results"))
        let core = ClikgateCore(sdkKey: "cg_sdk_test_abc", options: ClikgateOptions(linkDomains: ["inv.myapp.com"], logLevel: .verbose),
                                deps: h.deps(), logger: ClikgateLogger(level: .verbose), dispatcher: h.dispatcher,
                                linkDomains: LinkDomainsBox(optionDomains: ["inv.myapp.com"]), wrapper: nil)
        let test = await core.testMode
        XCTAssertTrue(test)
        await core.start(startTimers: false)
        let results = GoalResults()
        await core.goal("account_opened", value: nil, currency: nil, reference: "APP-1", isFirst: nil, done: { results.add($0) })
        await core.goal("purchase", value: "10", currency: nil, reference: "T123456", provider: "paystack", isFirst: nil,
                        done: { results.add($0, "purchase") })
        await core.flush()
        await eventually { results.count == 2 }
        XCTAssertEqual(results.byKey["purchase"]?.status, .waiting)
        XCTAssertEqual(results.byKey["purchase"]?.valueIgnored, true)
    }

    // MARK: - Delivery

    func testClickOfTheInstallIsAttached() async {
        stubHappyPath(install: "install_response_referral")
        server.on("POST /v1/sdk/goals", .fixture("goals_response"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("signup_done", value: nil, currency: nil, reference: "S1", isFirst: nil)
        await core.flush()
        XCTAssertEqual(sentGoals().first?["click_id"] as? String, "clk_01JAB3C4D5E6F7G8H9JKMNPQRS")
    }

    func testGoalsKeepTheirOrder() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("g_one", value: nil, currency: nil, reference: "R1", isFirst: nil)
        await core.goal("g_two", value: "10", currency: nil, reference: "R2", isFirst: nil)
        await core.flush()
        XCTAssertEqual(sentGoals().map { $0["reference"] as? String }, ["R1", "R2"])
        let left = await core.queuedEventCount
        XCTAssertEqual(left, 0)
    }

    func testSameReferenceIsIdempotentRetriesAndPersistence() async throws {
        server.on("POST /v1/sdk/goals", .offline())
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("order_paid", value: "10", currency: nil, reference: "ORD-9", isFirst: nil)
        await core.goal("order_paid", value: "10", currency: nil, reference: "ORD-9", isFirst: nil)   // ignored
        await core.goal("order_paid", value: "10", currency: nil, reference: "ORD-10", isFirst: nil)
        await core.flush()
        let queued = await core.queuedEventCount
        XCTAssertEqual(queued, 2, "kept for retry")
        // Canonical JSON (sorted keys): a dictionary's description order can differ between parses.
        let attempts = server.requests("POST /v1/sdk/goals").map { req -> String in
            let goals = req.json["goals"] ?? []
            let data = (try? JSONSerialization.data(withJSONObject: goals, options: [.sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
        XCTAssertEqual(Set(attempts).count, 1, "the same items on every retry")
        XCTAssertFalse(attempts.contains("[]"), "every retry carried the goals")
        // Change 09 (X.E15): one random Idempotency-Key per call, reused by that call's retries.
        let firstKeys = Set(server.requests("POST /v1/sdk/goals").map { $0.headers["Idempotency-Key"] ?? "" })
        XCTAssertEqual(firstKeys.count, 1)
        XCTAssertGreaterThan(server.requests("POST /v1/sdk/goals").count, 1, "retried")

        // Next launch: the queue file keeps the goal fields.
        let file = EventQueue(directory: h.dir)
        XCTAssertEqual(file.events.compactMap { $0.goal?["reference"]?.anyValue as? String }, ["ORD-9", "ORD-10"])
        server.on("POST /v1/sdk/goals", .fixture("goals_response"))
        let next = h.makeCore()
        await next.start(startTimers: false)
        await next.flush()
        XCTAssertEqual(EventQueue(directory: h.dir).count, 0)
        XCTAssertEqual(sentGoals().suffix(2).map { $0["reference"] as? String }, ["ORD-9", "ORD-10"])
        let nextKey = server.requests("POST /v1/sdk/goals").last?.headers["Idempotency-Key"] ?? ""
        XCTAssertFalse(firstKeys.contains(nextKey), "a new call gets a new key")
    }

    func testRejectedItems422AndOldServer404AreDropped() async {
        server.on("POST /v1/sdk/goals", .fixture("goals_response_rejected"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("kyc_passed", value: nil, currency: nil, reference: "K1", isFirst: nil)
        await core.flush()
        var left = await core.queuedEventCount
        XCTAssertEqual(left, 0)

        server.on("POST /v1/sdk/goals", .json(#"{"error":{"type":"invalid_request","code":"validation_error","message":"x"}}"#, status: 422))
        await core.goal("kyc_passed", value: nil, currency: nil, reference: "K2", isFirst: nil)
        await core.flush()
        left = await core.queuedEventCount
        XCTAssertEqual(left, 0)

        server.on("POST /v1/sdk/goals", .json(#"{"error":{"type":"not_found","code":"not_found","message":"x"}}"#, status: 404))
        await core.goal("kyc_passed", value: nil, currency: nil, reference: "K3", isFirst: nil)
        await core.flush()
        left = await core.queuedEventCount
        XCTAssertEqual(left, 0, "the queue isn't blocked")
    }

    // MARK: - Consent

    func testGoalsAreBufferedForConsentAndDroppedOnDeny() async {
        stubConfig("config_response_consent_required")
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("account_opened", value: nil, currency: nil, reference: "A1", isFirst: nil)
        var queued = await core.queuedEventCount
        XCTAssertEqual(queued, 1)
        XCTAssertTrue(server.requests("POST /v1/sdk/goals").isEmpty)
        await core.setConsent(analytics: nil, attribution: .granted, adUserData: nil, adPersonalization: nil)
        await drainMain()
        await core.flush()
        XCTAssertEqual(sentGoals().map { $0["reference"] as? String }, ["A1"])
        XCTAssertEqual((server.requests("POST /v1/sdk/goals").first?.json["consent"] as? [String: Any])?["attribution"] as? String, "granted")

        await core.setConsent(analytics: nil, attribution: .denied, adUserData: nil, adPersonalization: nil)
        await core.goal("account_opened", value: nil, currency: nil, reference: "A2", isFirst: nil)
        queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    // MARK: - Private mode

    func testConfigWithoutPrivateModeMeansOff() async {
        XCTAssertFalse(RemoteConfig(json: Fixtures.json("config_response")).privateMode)
        XCTAssertFalse(RemoteConfig(json: Fixtures.json("config_response_legacy")).privateMode)
        XCTAssertTrue(RemoteConfig(json: Fixtures.json("config_response_private_mode")).privateMode)
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: nil)
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/identify").first?.json["customer_user_id"] as? String, "user_42")
    }

    func testPrivateModeDropsIdentifyButNotGoals() async throws {
        stubConfig("config_response_private_mode")
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: "tok")
        await core.goal("order_paid", value: "15", currency: "NGN", reference: "ORD-1", isFirst: nil)
        await core.flush()
        XCTAssertTrue(server.requests("POST /v1/sdk/identify").isEmpty)
        let st = await core.currentState()
        XCTAssertNil(st.customerUserId)
        XCTAssertEqual(sentGoals().first?["value"] as? String, "15")
        XCTAssertEqual(sentGoals().first?["reference"] as? String, "ORD-1")
    }

    // MARK: - Change 14: identifyUser and labels

    func testIdentifyUserWithOnlyALabelKeepsTheCustomerId() async throws {
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.identifyUser(label: nil, customerId: "user_42", identityToken: "sig.1")
        await core.identifyUser(label: "Ada (VIP)", customerId: "\u{0}", identityToken: nil)
        await core.identifyUser(label: nil, customerId: "\u{0}", identityToken: nil)   // nothing: no-op
        await core.flush()
        let sent = server.requests("POST /v1/sdk/identify")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.json["label"] as? String, "Ada (VIP)")
        XCTAssertEqual(sent.last?.json["customer_user_id"] as? String, "user_42")
        let st = await core.currentState()
        XCTAssertEqual(st.customerUserId, "user_42")
        XCTAssertNil(st.pendingLabel)
        XCTAssertFalse(st.identifyPending)
    }

    func testGoalCarriesALabelAndLongLabelsAreDropped() async {
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.goal("account_opened", value: nil, currency: nil, reference: "APP-1", isFirst: true, label: "Ada")
        await core.goal("account_opened", value: nil, currency: nil, reference: "APP-2", isFirst: nil,
                        label: String(repeating: "x", count: 81))
        await core.flush()
        XCTAssertEqual(sentGoals().first?["label"] as? String, "Ada")
        XCTAssertEqual(sentGoals().first?["is_first"] as? Bool, true)
        XCTAssertNil(sentGoals().last?["label"])
    }

    func testPrivateModeSendsOnlyAnAllowedLabel() async {
        stubConfig("config_response_private_mode_labels")
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.identifyUser(label: "Ada", customerId: "user_42", identityToken: "tok")
        await core.flush()
        let body = server.requests("POST /v1/sdk/identify").first?.json ?? [:]
        XCTAssertEqual(body["label"] as? String, "Ada")
        XCTAssertNil(body["customer_user_id"])
        XCTAssertNil(body["identity_token"])
    }

    func testPrivateModeDropsLabelsWithoutTheSwitch() async {
        stubConfig("config_response_private_mode")
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.identifyUser(label: "Ada", customerId: "\u{0}", identityToken: nil)
        await core.goal("order_paid", value: nil, currency: nil, reference: "ORD-2", isFirst: nil, label: "Ada")
        await core.flush()
        XCTAssertTrue(server.requests("POST /v1/sdk/identify").isEmpty)
        XCTAssertNil(sentGoals().first?["label"])
    }

    func testPrivateModeDiscardsAPendingIdentify() async throws {
        // Queued on an earlier launch, before private mode was known.
        let old = h.makeCore()
        server.on("POST /v1/sdk/install", .offline())
        await old.identifyUser(label: nil, customerId: "user_42", identityToken: nil)
        await old.goal("purchase", value: nil, currency: nil, reference: "P-1", isFirst: nil)

        stubHappyPath()
        stubConfig("config_response_private_mode")
        server.on("POST /v1/sdk/goals", .fixture("goals_response"))
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.flush()
        XCTAssertTrue(server.requests("POST /v1/sdk/identify").isEmpty)
        let st = await core.currentState()
        XCTAssertFalse(st.identifyPending)
        XCTAssertNil(st.customerUserId)
        XCTAssertEqual(sentGoals().map { $0["reference"] as? String }, ["P-1"], "goals queued before private mode are sent as they are")
    }
}

/// Collects goal results from completions on any thread.
final class GoalResults: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String?, ClikgateGoalResult)] = []
    func add(_ r: ClikgateGoalResult, _ key: String? = nil) { lock.lock(); items.append((key, r)); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var all: [ClikgateGoalResult] { lock.lock(); defer { lock.unlock() }; return items.map { $0.1 } }
    var byKey: [String: ClikgateGoalResult] {
        lock.lock(); defer { lock.unlock() }
        return Dictionary(items.compactMap { k, r in k.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
    }
}

extension ClikgateGoalResult: Equatable {
    public static func == (a: ClikgateGoalResult, b: ClikgateGoalResult) -> Bool {
        a.status == b.status && a.reason == b.reason && a.goalKind == b.goalKind && a.valueIgnored == b.valueIgnored
    }
}
