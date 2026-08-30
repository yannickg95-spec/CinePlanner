//
//  OnSetStepIntent.swift
//  Shared between the app and the On-Set widget extension.
//
//  The ‹ › buttons on the Live Activity. As a LiveActivityIntent it runs in the
//  APP's process (even when backgrounded), so it can update the app's real
//  SwiftData store through the bridge below — no App Group store sharing needed.
//  In the widget extension the bridge closure is never set, so the type simply
//  compiles; it only does work when performed inside the app.
//

#if os(iOS)
import AppIntents

/// Lets the app register how a Live Activity step should be handled. The app sets
/// `handler` at launch; the intent (running in-app) calls it.
final class OnSetActivityBridge {
    static let shared = OnSetActivityBridge()
    private init() {}
    /// (forward) → advance (mark the current setup shot) or step back (un-mark the
    /// last done setup). Set by the app; nil in the widget extension.
    var handler: ((Bool) -> Void)?
}

struct OnSetStepIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Step Setup"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Forward") var forward: Bool

    init() {}
    init(forward: Bool) { self.forward = forward }

    func perform() async throws -> some IntentResult {
        OnSetActivityBridge.shared.handler?(forward)
        return .result()
    }
}
#endif
