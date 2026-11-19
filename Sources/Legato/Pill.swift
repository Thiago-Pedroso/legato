import AppKit
import SwiftUI

/// What the floating indicator is showing.
final class PillModel: ObservableObject {
    enum Mode: Equatable {
        case hidden
        case recording(handsFree: Bool)
        case working(String?)
        case failed(String)
        case notice(String)
    }

    static let barCount = 9
    @Published var mode: Mode = .hidden
    @Published var levels = [CGFloat](repeating: 0, count: PillModel.barCount)
    var onTap: (() -> Void)?

    func push(level: CGFloat) {
        levels.removeFirst()
        levels.append(level)
    }

    func resetLevels() {
        levels = [CGFloat](repeating: 0, count: PillModel.barCount)
    }
}

struct PillView: View {
    @ObservedObject var model: PillModel
    /// Static frames for screenshots: no running animations.
    var still = false

    var body: some View {
        content
            .padding(.horizontal, 16)
            .frame(minWidth: 92, minHeight: 34, maxHeight: 34)
            .background(Capsule().fill(Theme.pill))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .contentShape(Capsule())
            .onTapGesture { model.onTap?() }
            .opacity(model.mode == .hidden ? 0 : 1)
            .scaleEffect(model.mode == .hidden ? 0.85 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.mode)
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .hidden:
            Color.clear.frame(width: 60)
        case .recording(let handsFree):
            HStack(spacing: 10) {
                bars
                if handsFree {
                    RoundedRectangle(cornerRadius: 2.5).fill(Theme.cobaltSoft).frame(width: 10, height: 10)
                        .accessibilityLabel(L.t("Stop", "Parar"))
                }
            }
        case .working(let detail):
            HStack(spacing: 8) {
                WorkingArc(still: still).frame(width: 40, height: 10)
                if let detail {
                    Text(detail).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                }
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text("!").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.pill)
                    .frame(width: 16, height: 16).background(Circle().fill(Theme.cobaltSoft))
                Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
        case .notice(let message):
            Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).lineLimit(1)
        }
    }

    private var bars: some View {
        HStack(spacing: 3) {
            ForEach(0..<PillModel.barCount, id: \.self) { index in
                Capsule().fill(Theme.cobaltSoft)
                    .frame(width: 3, height: 4 + 14 * model.levels[index])
            }
        }
        .frame(height: 18)
        .animation(.linear(duration: 0.09), value: model.levels)
    }
}

/// The slur drawing itself over and over while Legato works.
private struct WorkingArc: View {
    var still: Bool
    @State private var phase: CGFloat = 0

    var body: some View {
        SlurLine()
            .trim(from: still ? 0 : max(0, phase - 1), to: still ? 1 : min(1, phase))
            .stroke(Theme.cobaltSoft, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .padding(.top, 3)
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 2 }
            }
    }
}

/// A borderless panel above the Dock that never takes focus from the app being typed into.
final class PillPanel {
    private let panel: NSPanel
    let model = PillModel()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 60),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: PillView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity))
        panel.contentView = host
    }

    func show(_ mode: PillModel.Mode) {
        if mode == .hidden {
            model.mode = .hidden
            // Let the fade finish before the window goes away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
                if model.mode == .hidden { panel.orderOut(nil) }
            }
            return
        }
        // Only states the user can act on take clicks; otherwise clicks pass through.
        switch mode {
        case .recording(handsFree: true), .failed: panel.ignoresMouseEvents = false
        default: panel.ignoresMouseEvents = true
        }
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
        model.mode = mode
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 12))
    }
}
