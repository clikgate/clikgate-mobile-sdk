import Foundation

/// Referee-side referral calls tied to this installation: apply a friend's code and
/// ask whether this install was referred. Both need a completed first `/install`
/// (`install_pending` otherwise). Errors are `ClikgateError` with the backend code
/// (`code_not_found`, `already_referred`, `window_expired`, `self_referral`, ...).
///
/// Referrer-side features (creating the user's link, "my stats", leaderboards, promo codes,
/// share helpers) are not in the core SDK: call the control-plane API from your backend
/// (recommended) or use the optional `ClikgateEngage` add-on.
///
/// When the `referrals` feature is switched off for the app, every call fails with
/// ``ClikgateError/featureDisabled`` without a network call (or after the server's
/// `feature_disabled` no-op answer, if the cached config was out of date).
public final class ClikgateReferrals: @unchecked Sendable {
    weak var owner: Clikgate?

    init() {}

    private func core() throws -> ClikgateCore {
        try ClikgateAsync.core(owner)
    }

    /// The referee typed a friend's code.
    public func applyCode(programId: String, code: String) async throws -> ClikgateReferral {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClikgateError(code: ClikgateError.invalidArgument, message: "The code is empty", param: "code")
        }
        let c = try core()
        return try await c.referralCall({ ClikgateReferral(json: $0) }, method: "POST", path: "v1/sdk/referrals/apply-code",
                                        body: JSON.data(["program_id": programId, "code": trimmed]))
    }

    /// Whether this installation was referred (most recent referral across programs).
    public func referredBy() async throws -> ClikgateReferredBy {
        let c = try core()
        return try await c.referralCall({ ClikgateReferredBy(json: $0) }, method: "GET", path: "v1/sdk/referrals/referred-by", body: nil)
    }

    // MARK: Completion-handler variants (Objective-C style call sites, wrappers)

    public func applyCode(programId: String, code: String,
                          completion: @escaping @MainActor @Sendable (Result<ClikgateReferral, ClikgateError>) -> Void) {
        ClikgateAsync.run(completion) { try await self.applyCode(programId: programId, code: code) }
    }

    public func referredBy(completion: @escaping @MainActor @Sendable (Result<ClikgateReferredBy, ClikgateError>) -> Void) {
        ClikgateAsync.run(completion) { try await self.referredBy() }
    }
}

/// Plumbing shared by the public async APIs.
enum ClikgateAsync {
    static func core(_ owner: Clikgate?) throws -> ClikgateCore {
        guard let c = owner?.currentCore else { throw ClikgateError.notConfiguredError() }
        return c
    }

    /// Runs `work` and hands the result to `completion` on the main actor.
    static func run<T: Sendable>(_ completion: @escaping @MainActor @Sendable (Result<T, ClikgateError>) -> Void,
                                 _ work: @escaping @Sendable () async throws -> T) {
        Task {
            let result: Result<T, ClikgateError>
            do { result = .success(try await work()) } catch let e as ClikgateError { result = .failure(e) } catch {
                result = .failure(ClikgateError(code: ClikgateError.networkError, message: error.localizedDescription))
            }
            await MainActor.run { completion(result) }
        }
    }
}
