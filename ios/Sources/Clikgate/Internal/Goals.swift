import Foundation

/// `goal()` validation and the decimal wire value.
enum Goals {
    /// Normalises a plain non-negative decimal (`"1500.50"` → `"1500.5"`, `"007"` → `"7"`); nil otherwise.
    static func normalize(_ s: String) -> String? {
        guard s.range(of: #"^[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
        return s.replacingOccurrences(of: #"(\.[0-9]*[1-9])0+$|\.0+$|^0+(?=[0-9])"#, with: "$1", options: .regularExpression)
    }

    /// The wire string of a `Decimal` (plain, trailing fractional zeros removed); nil when NaN or negative.
    static func wire(_ d: Decimal) -> String? { d.isNaN || d < 0 ? nil : normalize(d.description) }

    /// Digits left after removing leading zeros (of a normalised value).
    static func significantDigits(_ wire: String) -> Int {
        wire.replacingOccurrences(of: #"^[0.]+|\."#, with: "", options: .regularExpression).count
    }

    static func validate(key: String, value: String?, currency: String?, reference: String?, provider: String? = nil) -> ClikgateError? {
        var m: String?, p = "goal"
        if key.range(of: "^[a-z][a-z0-9_]{1,39}$", options: .regularExpression) == nil {
            m = "Goal keys must be snake_case, 2-40 characters (^[a-z][a-z0-9_]*$)"
        } else if let v = value, (normalize(v).map(significantDigits) ?? 99) > 15 {
            m = "Goal value must be a plain decimal number, zero or more, with at most 15 significant digits"; p = "value"
        } else if let c = currency, !EventValidation.isValidCurrency(c) {
            m = "Currency must be 3 uppercase letters (ISO 4217)"; p = "currency"
        } else if let r = reference, r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || r.count > 128 {
            m = "Goal reference must be 1-128 characters"; p = "reference"
        } else if provider == "-" {
            m = "Provider must be a provider key such as paystack"; p = "provider"
        }
        return m.map { ClikgateError(code: ClikgateError.invalidArgument, message: $0, param: p) }
    }
}
