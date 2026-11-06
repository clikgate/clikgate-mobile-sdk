import XCTest
@testable import Clikgate

final class PasteboardTests: XCTestCase {
    let server = StubServer.shared
    let token = "cgdl_9Xk2abcdefghijklmnopqrstuv"   // install_request_ios fixture

    override func setUp() { super.setUp(); server.reset() }

    func testTokenExtraction() {
        XCTAssertEqual(PasteboardToken.extract(from: "https://inv.myapp.com/_cg/p/\(token)"), token)
        XCTAssertEqual(PasteboardToken.extract(from: "copied: \(token) thanks"), token)
        XCTAssertEqual(PasteboardToken.extract(from: "\(token)XYZ"), token, "first match of the pattern, as in the contract")
        XCTAssertNil(PasteboardToken.extract(from: "cgdl_short"))
        XCTAssertNil(PasteboardToken.extract(from: "https://example.com"))
        XCTAssertNil(PasteboardToken.extract(from: nil))
        XCTAssertNil(PasteboardToken.extract(from: "cgdl_9Xk2abcdefghijklmnopqrs-uv"))
    }

    func testFirstLaunchReadsPasteboardWhenWebURLDetected() async throws {
        let h = Harness(pasteboard: FakePasteboard(detect: true, text: "https://inv.myapp.com/_cg/p/\(token)"))
        defer { h.cleanUp() }
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(h.pasteboard.reads, 1)
        XCTAssertEqual(server.requests("POST /v1/sdk/install").first?.json["pasteboard_token"] as? String, token)

        // Never read again after the first launch.
        server.reset(); stubHappyPath()
        let next = h.makeCore()
        await next.start(startTimers: false)
        XCTAssertEqual(h.pasteboard.reads, 1)
        XCTAssertEqual(h.pasteboard.detections, 1)
    }

    func testNoReadWhenDetectionSaysNoWebURL() async throws {
        let h = Harness(pasteboard: FakePasteboard(detect: false, text: token))
        defer { h.cleanUp() }
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        XCTAssertEqual(h.pasteboard.detections, 1)
        XCTAssertEqual(h.pasteboard.reads, 0, "string is read only when a web URL is likely")
        XCTAssertNil(server.requests("POST /v1/sdk/install").first?.json["pasteboard_token"] as? String)
    }

    func testIOS13FallbackUsesHasStrings() async throws {
        let h = Harness(pasteboard: FakePasteboard(detect: nil, hasStrings: false, text: token))
        defer { h.cleanUp() }
        stubHappyPath()
        await h.makeCore().start(startTimers: false)
        XCTAssertEqual(h.pasteboard.reads, 0)
    }

    func testPasteControlOnlyAndOffNeverReadAutomatically() async throws {
        for mode in [ClikgateOptions.PasteboardMode.pasteControlOnly, .off] {
            server.reset()
            let h = Harness(pasteboard: FakePasteboard(detect: true, text: token))
            stubHappyPath()
            let core = h.makeCore(options: ClikgateOptions(logLevel: .none, pasteboardMode: mode))
            await core.start(startTimers: false)
            XCTAssertEqual(h.pasteboard.detections, 0)
            XCTAssertEqual(h.pasteboard.reads, 0)
            h.cleanUp()
        }
    }

    func testServerSwitchOffDisablesPasteboard() async throws {
        let h = Harness(pasteboard: FakePasteboard(detect: true, text: token))
        defer { h.cleanUp() }
        stubHappyPath()
        var config = Fixtures.json("config_response")
        var features = config["features"] as! [String: Any]
        features["pasteboard_matching"] = "off"
        config["features"] = features
        server.on("GET /v1/sdk/config", StubResponse(status: 200, body: try JSONSerialization.data(withJSONObject: config)))
        await h.makeCore().start(startTimers: false)
        XCTAssertEqual(h.pasteboard.reads, 0)
    }

    func testPasteControlTextReRunsInstallWithToken() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        stubHappyPath()
        let core = h.makeCore(options: ClikgateOptions(logLevel: .none, pasteboardMode: .pasteControlOnly))
        await core.start(startTimers: false)
        server.on("POST /v1/sdk/install", .fixture("install_response_referral"))
        let box = collect(h.dispatcher)
        let ok = await core.applyPastedText("https://inv.myapp.com/_cg/p/\(token)")
        XCTAssertTrue(ok)
        let installs = server.requests("POST /v1/sdk/install")
        XCTAssertEqual(installs.count, 2)
        XCTAssertEqual(installs[1].json["pasteboard_token"] as? String, token)
        await eventually { box.items.count == 1 }
        let none = await core.applyPastedText("no token here")
        XCTAssertFalse(none)
    }
}

final class PushTests: XCTestCase {
    var h: Harness!
    let server = StubServer.shared

    override func setUp() { super.setUp(); server.reset(); h = Harness() }
    override func tearDown() { h.cleanUp(); super.tearDown() }

    func testDeviceTokenHex() {
        XCTAssertEqual(PushTokens.hex(Data([0xa1, 0xb2, 0xc3, 0xd4])), "a1b2c3d4")
        XCTAssertNotEqual(PushTokens.hash(provider: "apns", token: "t"), PushTokens.hash(provider: "fcm", token: "t"))
    }

    func testTokenBeforeInstallGoesInInstallBody() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.setPushToken("a1b2c3d4", provider: "apns")
        await core.start(startTimers: false)
        let push = try XCTUnwrap(server.requests("POST /v1/sdk/install").first?.json["push"] as? [String: Any])
        XCTAssertEqual(push["provider"] as? String, "apns")
        XCTAssertEqual(push["token"] as? String, "a1b2c3d4")
        XCTAssertEqual(push["apns_environment"] as? String, "sandbox")
        XCTAssertTrue(server.requests("POST /v1/sdk/push-token").isEmpty)
    }

    func testTokenChangeDetection() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        await core.setPushToken("fcm-token-123", provider: "fcm")
        await core.setPushToken("fcm-token-123", provider: "fcm")
        var sent = server.requests("POST /v1/sdk/push-token")
        XCTAssertEqual(sent.count, 1, "unchanged token is not re-sent")
        XCTAssertEqual(sent[0].json["provider"] as? String, "fcm")
        XCTAssertTrue(sent[0].json.keys.contains("apns_environment"))
        XCTAssertTrue(sent[0].json["apns_environment"] is NSNull)

        await core.setPushToken("fcm-token-456", provider: "fcm")
        sent = server.requests("POST /v1/sdk/push-token")
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[1].json["token"] as? String, "fcm-token-456")
    }

    func testUnsentTokenIsSentOnNextLaunchViaOpen() async throws {
        stubHappyPath()
        let core = h.makeCore()
        await core.start(startTimers: false)
        server.on("POST /v1/sdk/push-token", .json("{}", status: 500))
        await core.setPushToken("tok", provider: "apns")

        server.reset(); stubHappyPath()
        let next = h.makeCore()
        await next.start(startTimers: false)
        let open = try XCTUnwrap(server.requests("POST /v1/sdk/open").first)
        XCTAssertEqual((open.json["push"] as? [String: Any])?["token"] as? String, "tok")
        XCTAssertTrue(server.requests("POST /v1/sdk/push-token").isEmpty, "acknowledged through /open")

        server.reset(); stubHappyPath()
        await h.makeCore().start(startTimers: false)
        XCTAssertNil(server.requests("POST /v1/sdk/open").first?.json["push"])
    }

    func testRemoteNotificationRecognition() {
        let apns = Fixtures.json("push_apns_uninstall_check")
        let fcm = Fixtures.json("push_fcm_uninstall_check")
        let app = Fixtures.json("push_app_message")
        XCTAssertTrue(Clikgate.shared.handleRemoteNotification(apns))
        XCTAssertTrue(Clikgate.isClikgateMessage(fcm))
        XCTAssertFalse(Clikgate.shared.handleRemoteNotification(app))
        XCTAssertFalse(Clikgate.isClikgateMessage(["cg": ["t": "other"]]))
        XCTAssertFalse(Clikgate.isClikgateMessage(["aps": ["content-available": 1]]))
    }
}
