import XCTest
@testable @_spi(ClikgateWrapper) import Clikgate

final class DeepLinkTests: XCTestCase {
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

    // MARK: URL parsing

    func testLinkMatcher() {
        let domains = ["inv.myapp.com", "ciz.to"]
        let schemes = ["myapp"]
        func m(_ s: String) -> Bool { LinkMatcher.isClikgateURL(URL(string: s)!, linkDomains: domains, appSchemes: schemes) }
        XCTAssertTrue(m("https://inv.myapp.com/r/ADA42?utm_source=x"))
        XCTAssertTrue(m("https://INV.MYAPP.COM/p/dress"))
        XCTAssertTrue(m("https://ciz.to/a8K2"))
        XCTAssertFalse(m("https://evil.com/r/ADA42"))
        XCTAssertFalse(m("https://sub.inv.myapp.com/r/ADA42"))
        XCTAssertTrue(m("myapp://products/42?cg_click_id=clk_01J"))
        XCTAssertFalse(m("myapp://products/42"), "app scheme without cg_click_id")
        XCTAssertFalse(m("myapp://products/42?cg_click_id="))
        XCTAssertFalse(m("otherapp://x?cg_click_id=clk_1"))
        XCTAssertEqual(LinkMatcher.clickId(in: URL(string: "myapp://p?a=1&cg_click_id=clk_9")!), "clk_9")
        XCTAssertEqual(LinkMatcher.normalize(" https://Inv.MyApp.com/path "), "inv.myapp.com")
    }

    func testLinkDomainsCombineOptionsAndConfig() {
        let box = LinkDomainsBox(optionDomains: ["links.example.com"])
        box.setConfigDomains(["inv.myapp.com"])
        XCTAssertEqual(Set(box.all), ["links.example.com", "inv.myapp.com"])
    }

    // MARK: Delivery

    func testDeferredDeepLinkAndReferralFromInstall() async throws {
        stubHappyPath(install: "install_response_referral")
        let box = collect(h.dispatcher)
        let core = h.makeCore()
        await core.start(startTimers: false)
        await eventually { box.items.count == 1 }
        let r = try XCTUnwrap(box.items.first)
        XCTAssertTrue(r.isDeferred)
        XCTAssertEqual(r.url?.absoluteString, "https://inv.myapp.com/r/ADA42")
        XCTAssertEqual(r.path, "/welcome")
        XCTAssertEqual(r.data["ref"] as? String, "ADA42")
        XCTAssertEqual(r.clickId, "clk_01JAB3C4D5E6F7G8H9JKMNPQRS")
        XCTAssertEqual(r.matchType, "install_referrer")
        XCTAssertEqual(r.link?.kind, "referral")
        XCTAssertEqual(r.referral?.referrerDisplayName, "Ada")
        XCTAssertEqual(r.referral?.status, "installed")

        let a = await core.attribution(timeout: 1)
        XCTAssertEqual(a.status, .attributed)
        XCTAssertEqual(a.installId, "ins_01JAB3C4D5E6F7G8H9JKMNPQRS")
        XCTAssertNotNil(a.clickedAt)
    }

    func testDeepLinksBufferedUntilHandlerRegistered() async throws {
        let d = DeepLinkDispatcher()
        for i in 0..<12 {
            d.deliver(ClikgateDeepLinkResult(url: nil, path: "/\(i)", dataJSON: [:], isDeferred: false, clickId: nil,
                                             matchType: nil, link: nil, referral: nil))
        }
        XCTAssertEqual(d.bufferedCount, 10, "latest 10 kept")
        let box = collect(d)
        await eventually { box.items.count == 10 }
        XCTAssertEqual(box.items.first?.path, "/2")
        XCTAssertEqual(box.items.last?.path, "/11")
        XCTAssertEqual(d.bufferedCount, 0)
    }

    func testResolveDeliversMatchedLink() async throws {
        stubHappyPath()
        let box = collect(h.dispatcher)
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await eventually { box.items.count == 1 }
        let r = try XCTUnwrap(box.items.first)
        XCTAssertFalse(r.isDeferred)
        XCTAssertEqual(r.path, "/products/42")
        XCTAssertEqual(r.data["product_id"] as? String, "42")
        XCTAssertEqual(r.link?.externalReference, "off_7")
        XCTAssertEqual(r.link?.metadata["creator_id"] as? String, "cr_91")
        XCTAssertEqual(server.requests("POST /v1/sdk/resolve").first?.json["url"] as? String, "https://inv.myapp.com/p/dress")
    }

    func testUnmatchedResolveDeliversNothing() async throws {
        stubHappyPath()
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_unmatched"))
        let box = collect(h.dispatcher)
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/unknown")!)
        await drainMain()
        XCTAssertTrue(box.items.isEmpty)
    }

    func testURLBeforeInstallIsSentAsLaunchUrl() async throws {
        stubHappyPath(install: "install_response_organic")
        let core = h.makeCore()
        await core.resolve(url: URL(string: "myapp://p?cg_click_id=clk_1")!)   // before start
        XCTAssertTrue(server.requests.isEmpty)
        await core.start(startTimers: false)
        XCTAssertEqual(server.requests("POST /v1/sdk/install").first?.json["launch_url"] as? String, "myapp://p?cg_click_id=clk_1")
        // organic response without deep_link: fall back to /resolve for that URL
        XCTAssertEqual(server.requests("POST /v1/sdk/resolve").count, 1)
    }

    func testPendingAttributionPollsInstallAndTimesOut() async throws {
        stubHappyPath()
        server.on("POST /v1/sdk/install", .fixture("install_response_pending"), .fixture("install_response_pending"),
                  .fixture("install_response_referral"))
        let box = collect(h.dispatcher)
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(server.requests("POST /v1/sdk/install").count, 3)
        XCTAssertTrue(h.clock.sleeps.contains(2.0), "retry_after_ms = 2000")
        await eventually { box.items.count == 1 }
        XCTAssertTrue(box.items[0].isDeferred)
        let a = await core.attribution(timeout: 1)
        XCTAssertEqual(a.status, .attributed)
    }

    func testAttributionTimesOutAsPending() async throws {
        stubHappyPath()
        server.on("POST /v1/sdk/install", .fixture("install_response_pending"))
        let core = h.makeCore()
        await core.start(startTimers: false)   // polls 3 times, still pending
        XCTAssertEqual(server.requests("POST /v1/sdk/install").count, 4, "initial + at most 3 polls")
        let a = await core.attribution(timeout: 5)
        XCTAssertEqual(a.status, .pending)
    }

    func testPublicFacadeHandleURLSync() {
        // Not configured → false
        XCTAssertFalse(Clikgate.shared.handle(url: URL(string: "https://inv.myapp.com/r/x")!) && !Clikgate.shared.isConfigured)
        let activity = NSUserActivity(activityType: "com.example.other")
        XCTAssertFalse(Clikgate.shared.continue(userActivity: activity))
    }
}
