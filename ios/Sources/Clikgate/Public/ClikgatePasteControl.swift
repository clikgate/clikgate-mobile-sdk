import UIKit

/// A system Paste button (`UIPasteControl`, iOS 16+) that hands the pasteboard to Clikgate without
/// the iOS paste prompt. Use it with `pasteboardMode: .pasteControlOnly`, e.g. on a
/// "Were you invited?" screen during the first session. When the pasted text contains a Clikgate
/// token the SDK re-runs `/install` with it, and a deferred deep link (if any) arrives on `onDeepLink`.
///
/// On iOS 13–15 it shows a plain button that reads the pasteboard on tap (no prompt exists there).
@MainActor
public final class ClikgatePasteControl: UIView {
    /// Called on the main thread after a paste: `true` when a Clikgate token was found and sent.
    public var onPaste: (@MainActor @Sendable (Bool) -> Void)?

    private static let acceptedTypes = ["public.url", "public.plain-text", "public.utf8-plain-text", "public.text"]

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setUp(displayModeIconAndLabel: true)
    }

    /// - Parameter showsLabel: `true` for icon + "Paste", `false` for the icon only.
    public convenience init(showsLabel: Bool) {
        self.init(frame: .zero)
        subviews.forEach { $0.removeFromSuperview() }
        setUp(displayModeIconAndLabel: showsLabel)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp(displayModeIconAndLabel: true)
    }

    private func setUp(displayModeIconAndLabel: Bool) {
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: Self.acceptedTypes)
        let control: UIView
        if #available(iOS 16.0, *) {
            let config = UIPasteControl.Configuration()
            config.displayMode = displayModeIconAndLabel ? .iconAndLabel : .iconOnly
            config.cornerStyle = .capsule
            let paste = UIPasteControl(configuration: config)
            paste.target = self
            control = paste
        } else {
            let button = UIButton(type: .system)
            button.setTitle("Paste", for: .normal)
            button.addTarget(self, action: #selector(legacyPasteTapped), for: .touchUpInside)
            control = button
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.topAnchor.constraint(equalTo: topAnchor),
            control.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public override var intrinsicContentSize: CGSize { CGSize(width: 120, height: 44) }

    @objc private func legacyPasteTapped() {
        deliver(UIPasteboard.general.string)
    }

    public override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }

    public override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first else { deliver(nil); return }
        let callback = onPaste
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let s = url?.absoluteString
                DispatchQueue.main.async { Self.send(s, callback) }
            }
        } else if provider.canLoadObject(ofClass: NSString.self) {
            _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
                let s = (obj as? NSString).map { String($0) }
                DispatchQueue.main.async { Self.send(s, callback) }
            }
        } else {
            deliver(nil)
        }
    }

    private func deliver(_ text: String?) {
        Self.send(text, onPaste)
    }

    private static func send(_ text: String?, _ callback: (@MainActor @Sendable (Bool) -> Void)?) {
        Task { @MainActor in
            let ok = await Clikgate.shared.applyPastedText(text)
            callback?(ok)
        }
    }
}
