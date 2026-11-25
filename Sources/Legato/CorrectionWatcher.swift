import AppKit
import LegatoCore

/// After a dictation is pasted, rereads the text field it went into for a minute, looking for
/// the user fixing one of its words. Needs the Accessibility permission Legato already has.
/// Apps that do not expose their text (many terminals and Electron apps) are simply skipped.
///
/// The reading happens on a queue of its own: a busy app can take a while to answer, and the
/// keyboard and the pill must not wait for it. `watch` and `finish` are called on the main thread.
final class CorrectionWatcher {
    /// Delivered on the main thread.
    var onCorrection: ((_ heard: String, _ typed: String) -> Void)?
    /// Whether a lowercase word is ordinary language, as opposed to a name or jargon.
    /// Called on the main thread, where the spelling dictionaries live.
    var isWord: (String) -> Bool = { _ in false }

    private let queue = DispatchQueue(label: "Legato correction watcher", qos: .utility)
    // Owned by `queue`.
    private var field: AXUIElement?
    private var pasted = ""
    private var before = ""
    private var last = ""
    private var found: (heard: String, typed: String)?
    private var timer: DispatchSourceTimer?
    private var deadline = Date()

    func watch(pasted text: String) {
        finish()
        // Asked now, while the app the text went into is surely the one in front.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        queue.async { [self] in
            pasted = text
            // Give the paste a moment to land before taking the "before" picture.
            schedule(after: 0.6, repeating: nil) { [self] in begin(pid) }
        }
    }

    /// Reports what was found so far and stops. Called when the next dictation starts, too.
    func finish() {
        queue.async { [self] in end() }
    }

    private func end() {
        timer?.cancel()
        timer = nil
        field = nil
        if let found {
            DispatchQueue.main.async { self.onCorrection?(found.heard, found.typed) }
        }
        found = nil
    }

    private func schedule(after delay: TimeInterval, repeating interval: TimeInterval?, _ work: @escaping () -> Void) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        if let interval {
            timer.schedule(deadline: .now() + delay, repeating: interval)
        } else {
            timer.schedule(deadline: .now() + delay)
        }
        timer.setEventHandler(handler: work)
        timer.resume()
        self.timer = timer
    }

    private func begin(_ pid: pid_t) {
        // Asked of the app itself: the system-wide element often fails to answer this.
        let app = AXUIElementCreateApplication(pid)
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
        schedule(after: 2, repeating: 2) { [self] in check() }
    }

    private func check() {
        guard let field, Date() < deadline, let value = Self.value(of: field) else { return end() }
        // Judge only text that has settled, not a word halfway through being retyped.
        if value == last, value != before {
            let isWord = self.isWord
            let correction = Corrections.find(pasted: pasted, before: before, after: value) { word in
                DispatchQueue.main.sync { isWord(word) }
            }
            if let correction { found = correction }
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
