import Foundation
import UIKit
import XCTest
@_spi(ClikgateEngage) import Clikgate
@testable import ClikgateEngage

/// Change 13 S.1: share.link / share.referralLink, the per-activity item and share events.
@MainActor
final class EngageShareLinkTests: XCTestCase {
    private func app(_ v: String) -> ClikgateShareApp { ClikgateShareApp(rawValue: v)! }

    private func rig() -> (ClikgateEngageShare, FakeShareUI, EngageRig) {
        let rig = EngageRig()
        rig.transport.on("POST /v1/share-events", .fixture("share_event_response", status: 201))
        let share = ClikgateEngageShare()
        let ui = FakeShareUI()
        share.ui = ui
        share.client = rig.client
        return (share, ui, rig)
    }

    private func events(_ rig: EngageRig, _ count: Int) async -> [(String, String)] {
        for _ in 0..<200 where rig.transport.requests("POST /v1/share-events").count < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return rig.transport.requests("POST /v1/share-events").map { ($0.json["url"] as? String ?? "", $0.json["app"] as? String ?? "") }
    }

    func testSharedCases() {
        let cases = EFixtures.json("share_cases")
        for c in cases["links"] as! [[String: Any]] {
            let got = EngageShareLink.withEnding(c["url"] as! String, app(c["app"] as! String), c["code"] as? String)
            XCTAssertEqual(got, c["expected"] as? String, "\(c)")
        }
        for c in cases["texts"] as! [[String: Any]] {
            let link = EngageShareLink("https://inv.myapp.com/x", nil, ["whatsapp": c["url"] as! String], c["message"] as? String)
            XCTAssertEqual(link.text(.whatsapp), c["expected"] as? String)
        }
        for (type, expected) in cases["ios_activity_types"] as! [String: String] {
            XCTAssertEqual(EngageShareLink.app(type).rawValue, expected, type)
        }
        for v in EFixtures.json("share_event_response")["app"] as? [String] ?? ["other"] { XCTAssertNotNil(ClikgateShareApp(rawValue: v)) }
    }

    func testEachActivityGetsItsOwnLink() async throws {
        let (share, ui, _) = rig()
        try await share.link("https://inv.myapp.com/summer", message: "Join me")
        let item = try XCTUnwrap(ui.sheets.first?.first as? EngageShareLink)
        let vc = UIActivityViewController(activityItems: [], applicationActivities: nil)
        XCTAssertEqual(item.activityViewControllerPlaceholderItem(vc) as? String, "Join me https://inv.myapp.com/summer")
        let wa = item.activityViewController(vc, itemForActivityType: UIActivity.ActivityType("net.whatsapp.WhatsApp.ShareExtension")) as? String
        let mail = item.activityViewController(vc, itemForActivityType: .mail) as? String
        let notes = item.activityViewController(vc, itemForActivityType: UIActivity.ActivityType("com.example.notes.share")) as? String
        XCTAssertTrue(wa?.hasPrefix("Join me https://inv.myapp.com/summer-") == true)
        XCTAssertTrue(mail?.hasPrefix("Join me https://inv.myapp.com/summer-") == true)
        XCTAssertNotEqual(wa, mail)
        XCTAssertEqual(notes, "Join me https://inv.myapp.com/summer")
    }

    func testCompletionRecordsThePickedApp() async throws {
        let (share, ui, rig) = rig()
        try await share.link("https://inv.myapp.com/summer", shareUrls: ["whatsapp": "https://inv.myapp.com/summer-z"])
        ui.done[0]?(nil, false) // dismissed: nothing
        ui.done[0]?("net.whatsapp.WhatsApp.ShareExtension", false) // cancelled inside the app: nothing
        ui.done[0]?("net.whatsapp.WhatsApp.ShareExtension", true)
        let sent = await events(rig, 1)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.0, "https://inv.myapp.com/summer-z")
        XCTAssertEqual(sent.first?.1, "whatsapp")
        let req = rig.transport.requests("POST /v1/share-events")[0]
        XCTAssertEqual(req.request.value(forHTTPHeaderField: "Clikgate-SDK-Key").map { !$0.isEmpty }, true)
        XCTAssertEqual(req.json.count, 2)
    }

    func testReferralLinkKeepsTheCodeAndRecordsTheReferralUrl() async throws {
        let (share, ui, rig) = rig()
        let j = EngageJSON(object: EFixtures.json("referral_link_response"))
        let link = try XCTUnwrap(ClikgateReferralLink(json: j))
        try await share.referralLink(link)
        let item = try XCTUnwrap(ui.sheets.first?.first as? EngageShareLink)
        XCTAssertTrue(item.urlFor(.telegram).hasPrefix("https://inv.myapp.com/r/ADA42X-"))
        ui.done[0]?("ph.telegra.Telegraph.Share", true)
        let sent = await events(rig, 1)
        XCTAssertEqual(sent.first?.0, item.urlFor(.telegram))
        XCTAssertEqual(sent.first?.1, "telegram")
    }

    func testDirectShare() async throws {
        let (share, ui, rig) = rig()
        ui.canOpenResult = true
        let opened = try await share.link("https://inv.myapp.com/summer", message: "Hi", app: .telegram)
        XCTAssertTrue(opened)
        let url = try XCTUnwrap(ui.opened.first?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://t.me/share/url?url=https%3A%2F%2Finv.myapp.com%2Fsummer-"), url)
        XCTAssertTrue(url.hasSuffix("&text=Hi"))
        let sent = await events(rig, 1)
        XCTAssertEqual(sent.first?.1, "telegram")

        // WhatsApp needs canOpenURL; without it, and for apps without a share URL, the menu opens.
        ui.canOpenResult = false
        let viaSheet = try await share.link("https://inv.myapp.com/summer", app: .whatsapp)
        let instagram = try await share.link("https://inv.myapp.com/summer", app: .instagram)
        XCTAssertFalse(viaSheet)
        XCTAssertFalse(instagram)
        XCTAssertEqual(ui.sheetCount, 2)
    }

    func testShareUnavailable() async {
        let (share, _, _) = rig()
        share.ui = FakeShareUI(canPresent: false)
        _ = await expectEngageError(ClikgateError.shareUnavailable) { try await share.link("https://inv.myapp.com/summer") }
    }
}
