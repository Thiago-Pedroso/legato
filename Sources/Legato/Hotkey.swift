import AppKit
import LegatoCore

extension TriggerKey {
    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        }
    }

    var title: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return L.t("Right Option", "Option direito")
        case .rightCommand: return L.t("Right Command", "Command direito")
        case .rightControl: return L.t("Right Control", "Control direito")
        }
    }
}

/// Watches the keyboard for the trigger key. Needs the Accessibility permission;
/// `start` returns false until it is granted.
final class HotkeyMonitor {
    var trigger: TriggerKey = .fn
    var onTrigger: ((_ down: Bool) -> Void)?
    var onOtherKey: (() -> Void)?
    /// Return true to keep Esc from reaching the app in front.
    var onEscape: (() -> Bool)?
    private var tap: CFMachPort?

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(mask), callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true when the event should be swallowed.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            if event.getIntegerValueField(.keyboardEventKeycode) == trigger.keyCode {
                onTrigger?(event.flags.contains(trigger.flag))
            }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { return onEscape?() ?? false }
            onOtherKey?()
        default: break
        }
        return false
    }
}
