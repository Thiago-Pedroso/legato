import Foundation

/// Turns raw presses of the trigger key into dictation actions.
///
/// Hold the key: record while it is down. Tap it twice: keep recording hands-free
/// until the next tap. A single short tap is treated as an accident and discarded.
public struct HotkeyStateMachine: Equatable {
    public enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        /// A short tap just ended; recording continues while we wait for the second tap.
        case tapPending(deadline: TimeInterval)
        case locked
        /// The tap that ends hands-free is down. The dictation ends when the key lifts,
        /// so the text is never pasted while the trigger is still held.
        case ending
    }

    public enum Action: Equatable {
        case start, finish, cancel, lock
    }

    public private(set) var state: State = .idle
    /// A press shorter than this is a tap, not a hold.
    public var tapThreshold: TimeInterval = 0.35
    /// How long after a tap the second tap may arrive.
    public var doubleTapWindow: TimeInterval = 0.45
    /// Another key pressed this soon after the trigger means the trigger was used as a modifier.
    public var modifierUseWindow: TimeInterval = 1.0

    public init() {}

    public var isRecording: Bool { state != .idle }

    public mutating func triggerDown(at time: TimeInterval) -> Action? {
        switch state {
        case .idle:
            state = .holding(since: time)
            return .start
        case .tapPending:
            state = .locked
            return .lock
        case .locked:
            state = .ending
            return nil
        case .holding, .ending:
            return nil
        }
    }

    public mutating func triggerUp(at time: TimeInterval) -> Action? {
        if state == .ending {
            state = .idle
            return .finish
        }
        guard case .holding(let since) = state else { return nil }
        if time - since >= tapThreshold {
            state = .idle
            return .finish
        }
        state = .tapPending(deadline: time + doubleTapWindow)
        return nil
    }

    /// Call periodically (or at `pendingDeadline`) so an unanswered tap gets discarded.
    public mutating func tick(at time: TimeInterval) -> Action? {
        guard case .tapPending(let deadline) = state, time >= deadline else { return nil }
        state = .idle
        return .cancel
    }

    public var pendingDeadline: TimeInterval? {
        if case .tapPending(let deadline) = state { return deadline }
        return nil
    }

    public mutating func otherKeyDown(at time: TimeInterval) -> Action? {
        guard case .holding(let since) = state, time - since < modifierUseWindow else { return nil }
        state = .idle
        return .cancel
    }

    public mutating func escape() -> Action? {
        guard state != .idle else { return nil }
        state = .idle
        return .cancel
    }

    /// The recording ended for an outside reason (error, microphone lost).
    public mutating func reset() {
        state = .idle
    }
}
