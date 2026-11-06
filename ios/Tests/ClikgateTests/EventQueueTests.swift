import XCTest
@testable import Clikgate

final class EventQueueTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    func testEventBodyMatchesFixtureShape() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.track(name: "purchase", revenue: ClikgateMoney.ofMinor(1_500_000, currency: "NGN"),
                         properties: ["order_id": .string("A-1001")])
        await core.flush()
        let req = try XCTUnwrap(server.requests("POST /v1/sdk/events").first)
        let sent = try XCTUnwrap((req.json["events"] as? [[String: Any]])?.first)
        let fixture = try XCTUnwrap((Fixtures.json("events_request")["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(sent.keys), Set(fixture.keys))
        XCTAssertEqual(sent["revenue_minor"] as? Int, fixture["revenue_minor"] as? Int)
        XCTAssertEqual(sent["currency"] as? String, "NGN")
        XCTAssertEqual((sent["properties"] as? [String: Any])?["order_id"] as? String, "A-1001")
        XCTAssertNotNil(ISO8601.parse(sent["occurred_at"] as? String))
        XCTAssertNotNil(req.headers["Idempotency-Key"])
        let queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testEventsWaitForInstallAndPersistAcrossLaunches() async throws {
        stubHappyPath()
        server.on("POST /v1/sdk/install", .offline())
        // Track before /install succeeds (install task not started yet).
        let core = h.makeCore()
        await core.track(name: "signup", revenue: nil, properties: nil)
        await core.track(name: "level_up", revenue: nil, properties: nil)
        await core.flush()
        XCTAssertTrue(server.requests("POST /v1/sdk/events").isEmpty, "no events before /install")

        // "Next launch": a fresh queue reads events.json.
        let queue = EventQueue(directory: h.dir)
        XCTAssertEqual(queue.events.map { $0.name }, ["signup", "level_up"])
        let ids = queue.events.map { $0.eventId }

        stubHappyPath()
        let next = h.makeCore()
        await next.start(startTimers: false)
        let sent = (server.requests("POST /v1/sdk/events").first?.json["events"] as? [[String: Any]])?.map { $0["event_id"] as? String }
        XCTAssertEqual(sent, ids, "event ids are kept from track() time")
        XCTAssertEqual(EventQueue(directory: h.dir).count, 0)
    }

    func testFailedFlushKeepsEventsAndRetriesWithSameIds() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        server.on("POST /v1/sdk/events", .json("{}", status: 500))
        await core.track(name: "signup", revenue: nil, properties: nil)
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/events").count, 5, "gives up after 5 attempts")
        var queued = await core.queuedEventCount
        XCTAssertEqual(queued, 1, "events stay queued")

        server.on("POST /v1/sdk/events", .fixture("events_response"))
        await core.flush()
        queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
        let ids = Set(server.requests("POST /v1/sdk/events").compactMap { ($0.json["events"] as? [[String: Any]])?.first?["event_id"] as? String })
        XCTAssertEqual(ids.count, 1)
    }

    func testValidationErrorDropsBatch() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        server.on("POST /v1/sdk/events", .json(#"{"error":{"type":"invalid_request","code":"validation_error","message":"bad"}}"#, status: 422))
        await core.track(name: "signup", revenue: nil, properties: nil)
        await core.flush()
        XCTAssertEqual(server.requests("POST /v1/sdk/events").count, 1, "422 is not retried")
        let queued = await core.queuedEventCount
        XCTAssertEqual(queued, 0)
    }

    func testFlushAtCountTriggersFlushAndBatchesAreCapped() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        for i in 0..<19 { await core.track(name: "e\(i)", revenue: nil, properties: nil) }
        XCTAssertTrue(server.requests("POST /v1/sdk/events").isEmpty)
        await core.track(name: "e19", revenue: nil, properties: nil)
        XCTAssertEqual(server.requests("POST /v1/sdk/events").count, 1, "flushes at 20 queued events")
        XCTAssertEqual((server.requests("POST /v1/sdk/events")[0].json["events"] as? [Any])?.count, 20)
    }

    func testQueueDropsOldestWhenFull() {
        let dir = h.dir
        let q = EventQueue(directory: dir, maxEvents: 3, maxBytes: 1_048_576)
        for i in 0..<5 {
            q.append(QueuedEvent(eventId: "id\(i)", name: "e\(i)", occurredAt: "2026-10-20T10:00:00Z"))
        }
        XCTAssertEqual(q.events.map { $0.eventId }, ["id2", "id3", "id4"])

        let small = EventQueue(directory: dir.appendingPathComponent("b"), maxEvents: 1000, maxBytes: 1024)
        let big: [String: JSONValue] = ["blob": .string(String(repeating: "x", count: 400))]
        for i in 0..<5 {
            small.append(QueuedEvent(eventId: "b\(i)", name: "e", occurredAt: "2026-10-20T10:00:00Z", properties: big))
        }
        XCTAssertLessThanOrEqual(small.totalBytes, 1024)
        XCTAssertEqual(small.events.last?.eventId, "b4")
    }

    @available(*, deprecated)   // exercises the deprecated initialiser alias
    func testMoneyOfMinorAndTheDeprecatedInit() {
        // Change 09 (X.E10): ClikgateMoney.ofMinor is the name on every platform.
        XCTAssertEqual(ClikgateMoney.ofMinor(1_500_000, currency: "NGN").amountMinor, 1_500_000)
        XCTAssertEqual(ClikgateMoney.ofMinor(1_500_000, currency: "NGN").amountMinor, 1_500_000)
    }

    func testLocalValidation() {
        XCTAssertNil(Clikgate.validate(name: "purchase", revenue: ClikgateMoney.ofMinor(1, currency: "NGN")))
        XCTAssertNil(Clikgate.validate(name: "a.b:c-d_e", revenue: nil))
        XCTAssertEqual(Clikgate.validate(name: "", revenue: nil)?.code, "invalid_argument")
        XCTAssertEqual(Clikgate.validate(name: "has space", revenue: nil)?.code, "invalid_argument")
        XCTAssertEqual(Clikgate.validate(name: String(repeating: "a", count: 65), revenue: nil)?.code, "invalid_argument")
        XCTAssertEqual(Clikgate.validate(name: "$identify", revenue: nil)?.code, "invalid_argument")
        XCTAssertEqual(Clikgate.validate(name: "purchase", revenue: ClikgateMoney.ofMinor(1, currency: "ngn"))?.code, "invalid_argument")
        if case .failure = EventValidation.properties(["k": String(repeating: "x", count: 9000)]) {} else { XCTFail("> 8 KB must fail") }
        if case .failure = EventValidation.properties(["k": NSObject()]) {} else { XCTFail("non-JSON must fail") }
        if case .success(let p) = EventValidation.properties(["n": 1, "b": true, "d": 1.5, "nested": ["a": [1, 2]]]) {
            let a = p?.anyDictionary ?? [:]
            XCTAssertEqual(a["n"] as? Int, 1); XCTAssertEqual(a["b"] as? Bool, true); XCTAssertEqual(a["d"] as? Double, 1.5)
            if case .bool(true)? = p?["b"] {} else { XCTFail("Bool must stay a JSON boolean") }
            if case .int(1)? = p?["n"] {} else { XCTFail("Int must stay a JSON integer") }
        } else { XCTFail() }
    }
}
