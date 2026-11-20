import AVFoundation
import AppKit
import Security
import ServiceManagement

enum Permissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { done(granted) } }
    }

    static var accessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// What macOS does when fn is pressed alone: 0 nothing, 1 input source, 2 emoji, 3 dictation.
    /// A Mac where the setting was never touched has no value stored and opens the emoji picker.
    static var fnKeyAction: Int {
        UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int ?? 2
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    static let microphonePane = "com.apple.preference.security?Privacy_Microphone"
    static let accessibilityPane = "com.apple.preference.security?Privacy_Accessibility"
    static let keyboardPane = "com.apple.Keyboard-Settings.extension"
}

/// API keys live in the login keychain, never in the settings file.
enum Keychain {
    private static let service = "Legato"

    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func set(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Legato: login item change failed: \(error.localizedDescription)")
        }
    }
}

/// Puts text where the cursor is: the text goes on the clipboard, Cmd+V is pressed,
/// and whatever was on the clipboard before comes back.
enum Inserter {
    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]
    /// What was on the clipboard before Legato borrowed it, until it has been put back.
    private static var original: Snapshot?

    /// Returns false when the text could only be copied (no Accessibility permission).
    static func insert(_ text: String) -> Bool {
        let board = NSPasteboard.general
        guard Permissions.accessibility else {
            copy(text)
            return false
        }
        // If an earlier paste has not been restored yet, the board holds that dictation,
        // not the user's content: keep the snapshot already taken.
        if original == nil {
            original = (board.pasteboardItems ?? []).map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            }
        }
        board.clearContents()
        board.setString(text, forType: .string)
        // Clipboard managers skip entries marked transient.
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let stamp = board.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: down)
            event?.flags = .maskCommand
            event?.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticTag)
            event?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            // A newer paste owns the restore now; or the user copied something, which stays.
            guard board.changeCount == stamp else {
                if !isLegatoEntry(board) { original = nil }
                return
            }
            let saved = original ?? []
            original = nil
            guard !saved.isEmpty else { return }
            board.clearContents()
            board.writeObjects(
                saved.map { entries in
                    let item = NSPasteboardItem()
                    for (type, data) in entries { item.setData(data, forType: type) }
                    return item
                })
        }
        return true
    }

    private static func isLegatoEntry(_ board: NSPasteboard) -> Bool {
        board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) ?? false
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
