import AppKit
import LegatoCore

/// After a dictation is pasted, rereads the text field it went into for a minute, looking for
/// the user fixing one of its words. Needs the Accessibility permission Legato already has.
/// Apps that do not expose their text (many terminals and Electron apps) are simply skipped.
@MainActor
final class CorrectionWatcher {
    var onCorrection: ((_ heard: String, _ typed: String) -> Void)?
    /// Whether a lowercase word is ordinary language, as opposed to a name or jargon.
    var isWord: (String) -> Bool = { _ in false }

    private var field: AXUIElement?
    private var pasted = ""
    private var before = ""
    private var last = ""
    private var found: (heard: String, typed: String)?
    private var timer: Timer?
    private var deadline = Date()

    func watch(pasted text: String) {
        finish()
        pasted = text
        // Give the paste a moment to land before taking the "before" picture.
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.begin() }
        }
    }

    /// Reports what was found so far and stops. Called when the next dictation starts, too.
    func finish() {
        timer?.invalidate()
        timer = nil
        field = nil
        if let found { onCorrection?(found.heard, found.typed) }
        found = nil
    }

    private func begin() {
        // Asked of the app in front: the system-wide element often fails to answer this.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let app = AXUIElementCreateApplication(pid)
        // This runs on the main thread; a busy app must not stall the hotkey for AX's default 6 s.
        AXUIElementSetMessagingTimeout(app, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)
        guard let value = Self.value(of: element),
            value.contains(pasted.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        field = element
        before = value
        last = value
        deadline = Date().addingTimeInterval(60)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    private func check() {
        guard let field, Date() < deadline, let value = Self.value(of: field) else { return finish() }
        // Judge only text that has settled, not a word halfway through being retyped.
        if value == last, value != before,
            let correction = Corrections.find(pasted: pasted, before: before, after: value, isWord: isWord)
        {
            found = correction
        }
        last = value
    }

    /// The field's text, or nil when it has none to give or is too big to compare every two seconds.
    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
            let text = value as? String, text.utf16.count < 200_000
        else { return nil }
        return text
    }
}
