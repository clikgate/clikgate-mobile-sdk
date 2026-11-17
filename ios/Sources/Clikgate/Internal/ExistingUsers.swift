import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// What the phone says about how and when the app arrived on it.
protocol AppInstallFactsProviding: Sendable {
    /// `app_store`, `testflight` or `xcode`, from the receipt URL and the embedded profile only.
    func channel() -> String
    /// Creation date of the app's Documents directory (made when the app is installed), nil if unreadable.
    func containerCreatedAt() -> Date?
    /// Apple's signed app record (`AppTransaction.shared`, iOS 16+); never `refresh()`.
    func appRecord() async -> String?
}

struct SystemAppInstallFacts: AppInstallFactsProviding {
    func channel() -> String {
        #if targetEnvironment(simulator)
        return "xcode"
        #else
        if Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil { return "xcode" }
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt" ? "testflight" : "app_store"
        #endif
    }

    func containerCreatedAt() -> Date? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: docs.path))?[.creationDate] as? Date
    }

    func appRecord() async -> String? {
        #if canImport(StoreKit)
        // Never `AppTransaction.refresh()` (it can ask the person to sign in). No timeout wrapper (iOS size
        // ceiling): the call runs after the launch work, blocks nothing, and is tried at most twice.
        if #available(iOS 16.0, *) { return try? await AppTransaction.shared.jwsRepresentation }
        #endif
        return nil
    }
}

enum ExistingUserFields {
    /// The `/install` fields. `datesAllowed` false (opted out, attribution consent denied): only
    /// whether the app was here before `startAt`, never the dates.
    static func build(channel: String, installedAt: Date?, hint: Bool, restored: Bool, datesAllowed: Bool,
                      startAt: Date?, now: Date) -> JSONObject {
        var o: JSONObject = ["install_channel": channel]
        if hint || !datesAllowed { o["existing_user_hint"] = hint }
        if restored { o["keychain_restored_from_other_device"] = true }
        guard let at = installedAt else { return o }
        if datesAllowed {
            // Rounded down to the hour (the server keeps the day only)
            o["platform_installed_at"] = ISO8601.format(Date(timeIntervalSince1970: (at.timeIntervalSince1970 / 3600).rounded(.down) * 3600))
            o["platform_installed_source"] = "ios_container_created"
            o["device_time"] = ISO8601.format(now)
        } else if let start = startAt {
            o["installed_before_start"] = at < start
        }
        return o
    }
}
