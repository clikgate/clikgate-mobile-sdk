import Foundation
import CryptoKit

/// Decides whether a URL is a Clikgate link (contract: host in link domains, or the app's scheme with `cg_click_id`).
enum LinkMatcher {
    static func isClikgateURL(_ url: URL, linkDomains: [String], appSchemes: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "https" || scheme == "http" {
            guard let host = url.host?.lowercased() else { return false }
            return linkDomains.contains { normalize($0) == host }
        }
        guard appSchemes.contains(scheme) else { return false }
        return clickId(in: url) != nil
    }

    static func clickId(in url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first { $0.name == "cg_click_id" }?.value.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func normalize(_ domain: String) -> String {
        var d = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = d.range(of: "://") { d = String(d[r.upperBound...]) }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        return d
    }
}

/// The path of a handled deep link as reported for the live check: no query or fragment, and every
/// segment that looks like an ID, an email address or a phone number replaced with `:id`.
enum DeepLinkPath {
    static func clean(_ path: String) -> String {
        let b = Array(path.utf8)
        var out: [UInt8] = [], start = 0, i = 0
        while true {
            let end = i == b.count || b[i] == 63 || b[i] == 35   // the end, `?` or `#`
            if end || b[i] == 47 {
                if isId(b, start, i) { out += [58, 105, 100] } else { out += b[start..<i] }
                if end { break }
                out.append(47)
                start = i + 1
            }
            i += 1
        }
        return out.isEmpty ? "/" : String(decoding: out.prefix(512), as: UTF8.self)
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        c >= 48 && c <= 57 ? c - 48 : (c | 32) >= 97 && (c | 32) <= 102 ? (c | 32) - 87 : nil
    }

    /// `b[from..<to]`, percent-decoded: an `@`; only digits and `+-.() ` (numbers, phone numbers); or a run of
    /// ASCII letters and digits with a digit and 6+ characters, or 16+ in mixed case (UUIDs, hex and
    /// base64-like tokens, codes).
    static func isId(_ b: [UInt8], _ from: Int, _ to: Int) -> Bool {
        var i = from, len = 0, digits = 0, upper = false, lower = false, seen = false, other = false
        while i <= to {
            var c: UInt8 = 0   // 0: the end of the segment
            if i < to {
                c = b[i]
                if c == 37, i + 2 < to, let h = hex(b[i + 1]), let l = hex(b[i + 2]) { c = h << 4 | l; i += 2 }
            }
            i += 1
            if c == 64 { return true }
            let d = c >= 48 && c <= 57, u = c >= 65 && c <= 90, l = c >= 97 && c <= 122
            if d || u || l {
                len += 1
                if d { digits += 1; seen = true } else { other = true }
                upper = upper || u
                lower = lower || l
                continue
            }
            if digits > 0 ? len >= 6 : len >= 16 && upper && lower { return true }
            if c != 0 && c != 43 && c != 45 && c != 46 && c != 40 && c != 41 && c != 32 { other = true }
            if c == 0 { return seen && !other }
            len = 0
            digits = 0
            upper = false
            lower = false
        }
        return false
    }
}

/// Clikgate's shared platform link domains (tests
/// compare it with the `shared_link_domains` fixture). An unmatched link there is another
/// organisation's and opens in an in-app browser.
enum SharedDomains {
    static let hosts = ["ciz.to", "clk.ng", "clkg.to", "dev.ciz.to"]

    static func host(_ url: URL) -> String? {
        guard let s = url.scheme?.lowercased(), s == "https" || s == "http",
              let h = url.host?.lowercased(), hosts.contains(h) else { return nil }
        return h
    }
}

/// Extracts the first `cgdl_[0-9A-Za-z]{26}` token from pasteboard text.
enum PasteboardToken {
    private static let regex = try! NSRegularExpression(pattern: "cgdl_[0-9A-Za-z]{26}")

    static func extract(from text: String?) -> String? {
        guard let text = text, !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range), let r = Range(m.range, in: text) else { return nil }
        return String(text[r])
    }
}

/// Maps a tracked event onto the conversion value schema. Values only go up.
enum ConversionValueMapper {
    struct Update: Equatable, Sendable {
        var fineValue: Int
        var coarseValue: String?
        var lockWindow: Bool
    }

    static func update(for name: String, revenue: ClikgateMoney?, schema: RemoteConfig.ConversionValueSchema?, lastValue: Int?) -> Update? {
        guard let schema = schema else { return nil }
        let matching = schema.rules.filter { rule in
            guard rule.event == name else { return false }
            if let min = rule.minRevenueMinor {
                guard let revenue = revenue else { return false }
                if let cur = rule.currency, cur.uppercased() != revenue.currency.uppercased() { return false }
                return revenue.amountMinor >= min
            }
            return true
        }
        guard let best = matching.max(by: { $0.fineValue < $1.fineValue }) else { return nil }
        guard (0...63).contains(best.fineValue) else { return nil }
        if let last = lastValue, best.fineValue <= last { return nil }
        return Update(fineValue: best.fineValue, coarseValue: best.coarseValue, lockWindow: best.lockWindow)
    }
}

enum PushTokens {
    static func hash(provider: String, token: String) -> String {
        hex(Data(SHA256.hash(data: Data((provider + token).utf8))))
    }

    static func hex(_ deviceToken: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for b in deviceToken { out.append(digits[Int(b >> 4)]); out.append(digits[Int(b & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }
}

enum RemoteNotification {
    /// True for Clikgate uninstall-check pushes: APNs `{"cg": {"t": "uc"}}` or FCM data `{"cg": "uc"}`.
    static func isClikgateMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let cg = userInfo["cg"] else { return false }
        if let s = cg as? String { return s == "uc" }
        if let d = cg as? [AnyHashable: Any] { return (d["t"] as? String) == "uc" }
        return false
    }
}

enum EventValidation {
    static let maxPropertiesBytes = 8 * 1024

    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        return name.unicodeScalars.allSatisfy { s in
            ("0"..."9").contains(s) || ("a"..."z").contains(s) || ("A"..."Z").contains(s) || "_.$:-".unicodeScalars.contains(s)
        }
    }

    static func isValidCurrency(_ c: String) -> Bool {
        c.count == 3 && c.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) }
    }

    /// Validates and converts app-supplied properties.
    static func properties(_ props: [String: Any]?) -> Result<[String: JSONValue]?, ClikgateError> {
        guard let props = props else { return .success(nil) }
        guard case .object(let obj)? = JSONValue(any: props as [String: Any?]) else {
            return .failure(ClikgateError(code: ClikgateError.invalidArgument, message: "Event properties must be JSON-compatible"))
        }
        guard JSON.size(obj.anyDictionary) <= maxPropertiesBytes else {
            return .failure(ClikgateError(code: ClikgateError.invalidArgument, message: "Event properties exceed 8 KB"))
        }
        return .success(obj)
    }
}
