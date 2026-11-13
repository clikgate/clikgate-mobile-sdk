import UIKit
import Clikgate
import ClikgateEngage   // Engage features (same Clikgate package): invite link, stats, share helpers (apps without a backend)

/// Demo screen: attribution, last deep link, referral link sharing, code entry, stats, push status.
final class MainViewController: UIViewController {
    private let stack = UIStackView()
    private let attributionLabel = MainViewController.label()
    private let deepLinkLabel = MainViewController.label()
    private let referralLabel = MainViewController.label()
    private let pushLabel = MainViewController.label()
    private let bannerLabel = MainViewController.label()
    private let consentLabel = MainViewController.label()
    private let metadataLabel = MainViewController.label()
    private let programField = UITextField()
    private let userField = UITextField()
    private let tokenField = UITextField()
    private let codeField = UITextField()

    var pushStatus = "Waiting for an APNs token…" {
        didSet { pushLabel.text = pushStatus }
    }

    private var programId: String {
        let typed = programField.text?.trimmingCharacters(in: .whitespaces) ?? ""
        if !typed.isEmpty { return typed }
        return Bundle.main.object(forInfoDictionaryKey: "ClikgateProgramId") as? String ?? ""
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Clikgate \(Clikgate.sdkVersion)"
        if #available(iOS 13.0, *) { view.backgroundColor = .systemBackground } else { view.backgroundColor = .white }

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])

        // Referred-by banner (hidden unless this install was referred).
        bannerLabel.isHidden = true
        bannerLabel.backgroundColor = UIColor(red: 0.91, green: 0.96, blue: 0.91, alpha: 1)
        bannerLabel.accessibilityIdentifier = "referred-by-banner"
        stack.addArrangedSubview(bannerLabel)

        section("Attribution")
        attributionLabel.text = "Loading…"
        stack.addArrangedSubview(attributionLabel)
        button("Refresh attribution") { [weak self] in self?.loadAttribution() }

        section("Last deep link")
        deepLinkLabel.text = "None yet. Open https://\(Bundle.main.object(forInfoDictionaryKey: "ClikgateLinkDomain") ?? "")/… or clikgatesample://…?cg_click_id=…"
        stack.addArrangedSubview(deepLinkLabel)

        section("Referrals")
        field(programField, placeholder: "Program id (default from Config.xcconfig)")
        field(userField, placeholder: "Customer user id (e.g. user_42)")
        field(tokenField, placeholder: "Identity token from your backend (optional)")
        button("Identify") { [weak self] in
            guard let self = self else { return }
            let id = self.userField.text?.trimmingCharacters(in: .whitespaces)
            let token = self.tokenField.text?.trimmingCharacters(in: .whitespaces)
            // The token is signed by your backend (samples/backend POST /auth/demo-login), never in the app.
            let customerId = (id?.isEmpty ?? true) ? nil : id
            Clikgate.shared.identifyUser(label: customerId.map { "Customer \($0)" }, customerId: customerId,
                                         identityToken: (token?.isEmpty ?? true) ? nil : token)
            self.referralLabel.text = "Identified as \(id ?? "nobody")"
        }
        button("Share my invite link") { [weak self] in
            guard let self = self else { return }
            ClikgateEngage.referrals.createLink(programId: self.programId) { result in
                switch result {
                case .success(let link):
                    self.referralLabel.text = "Code \(link.code) · \(link.shortUrl ?? link.url)"
                    // Each app gets its own version of the link, so Clikgate knows where it was shared.
                    Task { @MainActor in
                        _ = try? await ClikgateEngage.share.referralLink(link, message: "Join me on Clikgate Sample!", from: self)
                    }
                case .failure(let e): self.referralLabel.text = "createLink failed: \(e.code)"
                }
            }
        }
        field(codeField, placeholder: "Friend's code (e.g. ADA42)")
        button("Apply code") { [weak self] in
            guard let self = self else { return }
            Clikgate.shared.referrals.applyCode(programId: self.programId, code: self.codeField.text ?? "") { result in
                switch result {
                case .success(let r):
                    self.referralLabel.text = "Referred by \(r.referrerDisplayName ?? r.referrerId) (\(r.status))"
                    self.loadReferredBy()
                case .failure(let e): self.referralLabel.text = "applyCode failed: \(e.code) — \(e.message)"
                }
            }
        }
        button("My stats") { [weak self] in
            guard let self = self else { return }
            ClikgateEngage.referrals.myStats(programId: self.programId) { result in
                switch result {
                case .success(let s):
                    self.referralLabel.text = "\(s.code): \(s.clicks) clicks · \(s.installs) installs · \(s.qualified) qualified"
                case .failure(let e): self.referralLabel.text = "myStats failed: \(e.code)"
                }
            }
        }
        button("Was I referred?") { [weak self] in
            Clikgate.shared.referrals.referredBy { result in
                switch result {
                case .success(let r):
                    self?.referralLabel.text = r.referred ? "Referred by \(r.referral?.referrerDisplayName ?? "someone") — \(r.referral?.status ?? "")" : "Not referred"
                case .failure(let e): self?.referralLabel.text = "referredBy failed: \(e.code)"
                }
            }
        }
        referralLabel.text = "—"
        stack.addArrangedSubview(referralLabel)

        section("Invite link on the clipboard? (no paste prompt)")
        let paste = ClikgatePasteControl(showsLabel: true)
        paste.onPaste = { [weak self] found in
            self?.referralLabel.text = found ? "Invite found — checking…" : "No Clikgate invite on the clipboard"
        }
        stack.addArrangedSubview(paste)

        section("Push (uninstall tracking)")
        pushLabel.text = pushStatus
        stack.addArrangedSubview(pushLabel)

        section("Consent (EEA / UK / CH: required by default)")
        consentLabel.text = consentText()
        stack.addArrangedSubview(consentLabel)
        button("Grant all") { [weak self] in
            Clikgate.shared.setConsent(analytics: .granted, attribution: .granted, adUserData: .granted, adPersonalization: .granted)
            self?.consentLabel.text = self?.consentText()
        }
        button("Deny all") { [weak self] in
            Clikgate.shared.setConsent(analytics: .denied, attribution: .denied, adUserData: .denied, adPersonalization: .denied)
            self?.consentLabel.text = self?.consentText()
        }
        button("Pretend I'm in Germany (region hint DE)") { [weak self] in
            Clikgate.shared.setConsentRegion("DE")
            self?.consentLabel.text = self?.consentText()
        }

        section("Sales metadata (Paystack metadata / Flutterwave meta)")
        metadataLabel.text = "—"
        stack.addArrangedSubview(metadataLabel)
        button("Show attributionMetadata()") { [weak self] in
            let m = Clikgate.shared.attributionMetadata()
            self?.metadataLabel.text = m.isEmpty ? "Nothing attributed (or consent not granted)"
                : m.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        }

        section("Track your end goal")
        // The business's own reference only: never customer data in a goal.
        button("Goal: account opened (₦2,000,000)") { [weak self] in
            Clikgate.shared.goal("account_opened", value: 2_000_000, currency: "NGN", reference: "APP-55231", isFirst: true) { result in
                self?.metadataLabel.text = "account_opened: \(result.status)" + (result.reason.map { " (\($0))" } ?? "")
            }
        }
        // A Payment goal: pass the payment reference your checkout returned and the provider. It waits until
        // your payment provider or server confirms it; the amount comes from that confirmation.
        button("Payment goal: purchase (Paystack)") { [weak self] in
            Clikgate.shared.goal("purchase", reference: "T123456", provider: .paystack) { result in
                self?.metadataLabel.text = "purchase: \(result.status)" + (result.reason.map { " (\($0))" } ?? "")
            }
        }

        section("Identity & privacy")
        // Identity Path B: send this to your own server with the sign-in request; your server calls identifyUser.
        button("Show installation ID") { [weak self] in
            Task { @MainActor in
                let id = try? await Clikgate.shared.installationId()
                self?.metadataLabel.text = id.map { "Installation \($0.prefix(8))…" } ?? "Tracking is off: no installation ID"
            }
        }
        let toggle = UISwitch()
        toggle.isOn = true
        toggle.addAction(for: .valueChanged) { Clikgate.shared.setTrackingEnabled(toggle.isOn) }
        let row = UIStackView(arrangedSubviews: [Self.label("Tracking enabled"), toggle])
        stack.addArrangedSubview(row)

        loadAttribution()
        loadReferredBy()
    }

    private func consentText() -> String {
        let c = Clikgate.shared.getConsent()
        let required = c.isRequired.map { $0 ? "required" : "not required" } ?? "not known yet"
        return "analytics \(c.analytics.rawValue) · attribution \(c.attribution.rawValue) · ad user data \(c.adUserData.rawValue) · "
            + "ad personalization \(c.adPersonalization.rawValue)\nregion \(c.region ?? "—") · consent \(required)"
    }

    /// Shows the banner when this install was referred (link, deferred link or code entry).
    private func loadReferredBy() {
        Clikgate.shared.referrals.referredBy { [weak self] result in
            guard let self = self, case .success(let r) = result, r.referred, let ref = r.referral else { return }
            self.bannerLabel.text = "  Invited by \(ref.referrerDisplayName ?? "a friend") (\(ref.status))"
            self.bannerLabel.isHidden = false
        }
    }

    func show(deepLink r: ClikgateDeepLinkResult) {
        loadViewIfNeeded()
        var text = "\(r.isDeferred ? "Deferred" : "Direct") → \(r.path ?? "/")"
        if !r.data.isEmpty { text += "\ndata: \(r.data)" }
        if let ref = r.referral { text += "\nInvited by \(ref.referrerDisplayName ?? ref.referrerId)" }
        deepLinkLabel.text = text
        if r.referral != nil { loadReferredBy() }
        // Product links (`/products/{id}`) open their screen, for direct and deferred links alike.
        if let path = r.path, path.hasPrefix("/products/") {
            navigationController?.pushViewController(ProductViewController(deepLink: r), animated: true)
        }
    }

    private func loadAttribution() {
        Clikgate.shared.attribution { [weak self] result in
            switch result {
            case .success(let a):
                self?.attributionLabel.text = "\(a.status.rawValue) · \(a.matchType ?? "no match")\(a.isReinstall ? " · reinstall" : "")"
            case .failure(let e):
                self?.attributionLabel.text = "Error: \(e.code)"
            }
        }
    }

    // MARK: UI helpers

    private static func label(_ text: String? = nil) -> UILabel {
        let l = UILabel()
        l.numberOfLines = 0
        l.font = .preferredFont(forTextStyle: .body)
        l.text = text
        return l
    }

    private func section(_ title: String) {
        let l = Self.label(title)
        l.font = .preferredFont(forTextStyle: .headline)
        stack.addArrangedSubview(l)
    }

    private func field(_ f: UITextField, placeholder: String) {
        f.placeholder = placeholder
        f.borderStyle = .roundedRect
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        stack.addArrangedSubview(f)
    }

    private func button(_ title: String, _ action: @escaping () -> Void) {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.contentHorizontalAlignment = .leading
        b.addAction(for: .touchUpInside, action)
        stack.addArrangedSubview(b)
    }
}

/// Destination of product deep links.
final class ProductViewController: UIViewController {
    private let deepLink: ClikgateDeepLinkResult

    init(deepLink: ClikgateDeepLinkResult) {
        self.deepLink = deepLink
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Product"
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        let product = (deepLink.data["product_id"] as? String) ?? deepLink.path ?? ""
        label.text = "Product \(product)\n\npath: \(deepLink.path ?? "/")\ndata: \(deepLink.data)\n\(deepLink.isDeferred ? "deferred (after install)" : "direct")"
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        ])
    }
}

private final class ClosureTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

private var targetsKey: UInt8 = 0

extension UIControl {
    /// `addAction(_:for:)` needs iOS 14; this keeps the sample on iOS 13.
    func addAction(for events: UIControl.Event, _ action: @escaping () -> Void) {
        let target = ClosureTarget(action)
        addTarget(target, action: #selector(ClosureTarget.fire), for: events)
        var targets = objc_getAssociatedObject(self, &targetsKey) as? [ClosureTarget] ?? []
        targets.append(target)
        objc_setAssociatedObject(self, &targetsKey, targets, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
