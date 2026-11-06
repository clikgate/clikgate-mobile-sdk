import XCTest
@testable import Clikgate

/// Change 17 R.2: Universal Links skip the redirect, so `/resolve` runs the link gates and the SDK must honour them.
final class LinkGateTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() {
        super.setUp()
        server.reset()
        h = Harness()
        stubHappyPath()
    }

    override func tearDown() {
        h.cleanUp()
        super.tearDown()
    }

    private func options() -> ClikgateOptions {
        ClikgateOptions(linkDomains: ["inv.myapp.com", "ciz.to"], logLevel: .none)
    }

    func testPasswordLinkOpensTheSystemBrowserAndDeliversNothing() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_password_required"))
        let links = collect(h.dispatcher)
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/vip-offer?utm_source=x")!)
        await eventually { self.h.browser.external.count == 1 }
        XCTAssertEqual(h.browser.external.map(\.absoluteString), ["https://inv.myapp.com/vip-offer"])   // web_url
        XCTAssertTrue(h.browser.opened.isEmpty)   // not the in-app browser
        await drainMain()
        XCTAssertTrue(links.items.isEmpty)
        let state = await core.currentState()
        XCTAssertNil(state.lastClickId)
    }

    func testPasswordLinkOnASharedDomainStillUsesTheSystemBrowser() async throws {
        var body = Fixtures.json("resolve_response_password_required")
        body["web_url"] = "https://ciz.to/vip"
        server.on("POST /v1/sdk/resolve", .json(String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!))
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://ciz.to/vip")!)
        await eventually { self.h.browser.external.count == 1 }
        await drainMain()
        XCTAssertTrue(h.browser.opened.isEmpty)
    }

    func testTheSamePasswordLinkIsNotReopenedWithin30Seconds() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_password_required"))
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        let url = URL(string: "https://inv.myapp.com/vip-offer")!
        await core.resolve(url: url)
        await core.resolve(url: url)   // the browser handed the link straight back to the app
        await drainMain()
        XCTAssertEqual(h.browser.external.count, 1)
    }

    func testBlockedLinkDeliversTheMessageWithoutARoute() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_blocked"))
        let links = collect(h.dispatcher)
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        let url = URL(string: "https://inv.myapp.com/offer")!
        await core.resolve(url: url)
        await eventually { links.items.count == 1 }
        let r = try XCTUnwrap(links.items.first)
        XCTAssertEqual(r.blockMessage, "This offer is only for customers in Nigeria.")
        XCTAssertEqual(r.url, url)
        XCTAssertNil(r.path)
        XCTAssertNil(r.clickId)
        XCTAssertNil(r.link)
        XCTAssertNil(r.referral)
        XCTAssertNil(r.matchType)
        XCTAssertTrue(r.data.isEmpty)
        XCTAssertFalse(r.isDeferred)
        let state = await core.currentState()
        XCTAssertNil(state.lastClickId)
        await drainMain()
        XCTAssertTrue(h.browser.opened.isEmpty)
        XCTAssertTrue(h.browser.external.isEmpty)
    }

    func testMatchedLinkHasNoBlockMessage() async throws {
        let links = collect(h.dispatcher)
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await eventually { links.items.count == 1 }
        XCTAssertNil(links.items.first?.blockMessage)
        XCTAssertEqual(links.items.first?.matchType, "app_link")
    }

    func testABTestDeliversTheVariantPathTheServerChose() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_ab_variant"))
        let links = collect(h.dispatcher)
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/menu")!)
        await eventually { links.items.count == 1 }
        XCTAssertEqual(links.items.first?.path, "/menu/b")
        XCTAssertNotNil(links.items.first?.clickId)
        XCTAssertNil(links.items.first?.blockMessage)
    }

    /// A gated answer never hands over a destination, even if it (wrongly) carries a deferred deep link.
    func testGatedAnswerCarryingADeepLinkDeliversNoDestination() async throws {
        for (fixture, delivered) in [("resolve_response_password_required", 0), ("resolve_response_blocked", 1)] {
            server.reset()
            stubHappyPath()
            var body = Fixtures.json(fixture)
            body["matched"] = true
            body["click_id"] = "clk_01JAB3C4D5E6F7G8H9JKMNPQRS"
            body["deep_link"] = ["url": "https://inv.myapp.com/vip", "path": "/vip/secret", "data": ["k": "v"], "is_deferred": true]
            body["link"] = ["id": "lnk_01JAB3C4D5E6F7G8H9JKMNPQRS", "kind": "standard", "metadata": [:]]
            server.on("POST /v1/sdk/resolve", .json(String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!))
            let h2 = Harness()
            let links = collect(h2.dispatcher)
            let core = h2.makeCore(options: options())
            await core.start(startTimers: false)
            await core.resolve(url: URL(string: "https://inv.myapp.com/vip")!)
            await drainMain()
            await eventually { links.items.count == delivered }
            XCTAssertEqual(links.items.count, delivered, fixture)
            for r in links.items {
                XCTAssertNil(r.path, fixture)
                XCTAssertTrue(r.data.isEmpty, fixture)
                XCTAssertFalse(r.isDeferred, fixture)
                XCTAssertNil(r.clickId, fixture)
                XCTAssertNil(r.link, fixture)
            }
            let state = await core.currentState()
            XCTAssertNil(state.lastClickId, fixture)
            h2.cleanUp()
        }
    }

    /// First launch: the launch URL goes with /install, which returns no deferred deep link for a gated link; the
    /// SDK then resolves the URL and the gate applies.
    func testGatedLaunchUrlOnFirstLaunchDeliversNoDestination() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_password_required"))
        let links = collect(h.dispatcher)
        let core = h.makeCore(options: options())
        await core.resolve(url: URL(string: "https://inv.myapp.com/vip-offer")!)   // before start: launch_url
        await core.start(startTimers: false)
        await eventually { self.h.browser.external.count == 1 }
        XCTAssertEqual(server.requests("POST /v1/sdk/install").first?.json["launch_url"] as? String, "https://inv.myapp.com/vip-offer")
        await drainMain()
        XCTAssertTrue(links.items.isEmpty)
    }

    /// Change 17 R.2: /install answers for a gated launch URL too. Even if it carried a deep link, iOS ignores it and
    /// re-resolves the launch URL, so only the gate's answer reaches the app.
    func testGatedInstallAnswerCarryingADeepLinkDeliversNoDestination() async throws {
        var install = Fixtures.json("install_response_password_required")
        install["deep_link"] = ["url": "https://inv.myapp.com/vip", "path": "/vip/secret", "data": ["k": "v"], "is_deferred": true]
        server.on("POST /v1/sdk/install", .json(String(data: try JSONSerialization.data(withJSONObject: install), encoding: .utf8)!))
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_password_required"))
        let links = collect(h.dispatcher)
        let core = h.makeCore(options: options())
        await core.resolve(url: URL(string: "https://inv.myapp.com/vip-offer")!)   // before start: launch_url
        await core.start(startTimers: false)
        await eventually { self.h.browser.external.count == 1 }
        await drainMain()
        XCTAssertTrue(links.items.isEmpty)
        XCTAssertEqual(server.requests("POST /v1/sdk/resolve").count, 1)
    }

    func testSilentReResolveAfterConsentOpensNothing() async throws {
        server.on("POST /v1/sdk/resolve", .fixture("resolve_response_blocked"))
        let links = collect(h.dispatcher)
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/offer")!, deliver: false)
        await drainMain()
        XCTAssertTrue(links.items.isEmpty)
        XCTAssertTrue(h.browser.external.isEmpty)
    }

    func testOlderServerWithoutStatusBehavesAsBefore() async throws {
        var body = Fixtures.json("resolve_response_matched")
        body.removeValue(forKey: "status"); body.removeValue(forKey: "web_url"); body.removeValue(forKey: "block_message")
        server.on("POST /v1/sdk/resolve", .json(String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!))
        let links = collect(h.dispatcher)
        let core = h.makeCore(options: options())
        await core.start(startTimers: false)
        await core.resolve(url: URL(string: "https://inv.myapp.com/p/dress")!)
        await eventually { links.items.count == 1 }
        XCTAssertEqual(links.items.first?.path, "/products/42")
    }

    func testContractFixturesParse() throws {
        let pw = try XCTUnwrap(ResolveResponse(json: Fixtures.json("resolve_response_password_required")))
        XCTAssertFalse(pw.matched)
        XCTAssertEqual(pw.webUrl, "https://inv.myapp.com/vip-offer")
        XCTAssertNil(pw.blockMessage)
        let blocked = try XCTUnwrap(ResolveResponse(json: Fixtures.json("resolve_response_blocked")))
        XCTAssertEqual(blocked.blockMessage, "This offer is only for customers in Nigeria.")
        XCTAssertNil(blocked.webUrl)
        let matched = try XCTUnwrap(ResolveResponse(json: Fixtures.json("resolve_response_matched")))
        XCTAssertTrue(matched.matched)
        XCTAssertNil(matched.webUrl)
        XCTAssertNil(matched.blockMessage)
        for name in ["install_response_password_required", "install_response_blocked"] {
            let install = try XCTUnwrap(InstallResponse(json: Fixtures.json(name)))
            XCTAssertNil(install.deepLink)
        }
    }
}
