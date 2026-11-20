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

extension TriggerKey {
    /// Whether this exact key is down. The right-hand modifiers are told apart from their left
    /// twins by the device-specific bits, since both set the same generic flag.
    func isDown(in flags: CGEventFlags) -> Bool {
        switch self {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return flags.rawValue & 0x40 != 0
        case .rightCommand: return flags.rawValue & 0x10 != 0
        case .rightControl: return flags.rawValue & 0x2000 != 0
        }
    }
}

/// Watches the keyboard for the trigger key. Needs the Accessibility permission;
/// `start` returns false until it is granted.
///
/// The tap lives on its own thread. Its callback only notes the time and hands the event
/// to the main thread, so slow work there (opening the microphone, writing audio) can never
/// stall the keyboard or get the tap disabled by macOS.
final class HotkeyMonitor {
    /// Marks the Cmd+V that Legato itself types, so it is not mistaken for the user's typing.
    static let syntheticTag: Int64 = 0x4C45_4741

    var onTrigger: ((_ down: Bool, _ time: TimeInterval) -> Void)?
    var onOtherKey: ((_ time: TimeInterval) -> Void)?
    var onEscape: (() -> Void)?

    private let lock = NSLock()
    private var currentTrigger = TriggerKey.fn
    private var isCapturing = false
    private var tap: CFMachPort?

    var trigger: TriggerKey {
        get { lock.withLock { currentTrigger } }
        set { lock.withLock { currentTrigger = newValue } }
    }

    /// While true, Esc is kept from the app in front and reported through `onEscape`.
    var capturing: Bool {
        get { lock.withLock { isCapturing } }
        set { lock.withLock { isCapturing = newValue } }
    }

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
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Legato hotkey"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Runs on the tap thread. Returns true when the event should be swallowed.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let time = ProcessInfo.processInfo.systemUptime
        let trigger = self.trigger
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A key-up may have been missed while the tap was off; do not leave a recording stuck.
            if !CGEventSource.flagsState(.combinedSessionState).contains(trigger.flag) {
                DispatchQueue.main.async { self.onTrigger?(false, time) }
            }
        case .flagsChanged:
            if event.getIntegerValueField(.keyboardEventKeycode) == trigger.keyCode {
                let down = trigger.isDown(in: event.flags)
                DispatchQueue.main.async { self.onTrigger?(down, time) }
            }
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag { return false }
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                guard capturing else { return false }
                DispatchQueue.main.async { self.onEscape?() }
                return true
            }
            DispatchQueue.main.async { self.onOtherKey?(time) }
        default: break
        }
        return false
    }
}
