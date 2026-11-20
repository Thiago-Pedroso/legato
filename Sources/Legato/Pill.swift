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
            .padding(.horizontal, 11)
            .frame(minWidth: 60, minHeight: 24, maxHeight: 24)
            .background(background)
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
            .contentShape(Capsule())
            .onTapGesture { model.onTap?() }
            .opacity(model.mode == .hidden ? 0 : 1)
            .scaleEffect(model.mode == .hidden ? 0.85 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: model.mode)
            .accessibilityElement(children: .combine)
    }

    /// Dark glass that lets the desktop show through. Still frames use a flat fill, since
    /// a blur has nothing behind it to blur in a rendered picture.
    @ViewBuilder private var background: some View {
        if still {
            Capsule().fill(Theme.pill)
        } else {
            Glass().clipShape(Capsule()).overlay(Capsule().fill(Color.black.opacity(0.28)))
        }
    }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .hidden:
            Color.clear.frame(width: 38)
        case .recording(let handsFree):
            HStack(spacing: 7) {
                bars
                if handsFree {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.cobaltSoft).frame(width: 7, height: 7)
                        .accessibilityLabel(L.t("Stop", "Parar"))
                }
            }
        case .working(let detail):
            HStack(spacing: 6) {
                WorkingArc(still: still).frame(width: 28, height: 7)
                if let detail {
                    Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                }
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Text("!").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.pill)
                    .frame(width: 13, height: 13).background(Circle().fill(Theme.cobaltSoft))
                Text(message).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
            }
        case .notice(let message):
            Text(message).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
        }
    }

    private var bars: some View {
        HStack(spacing: 2) {
            ForEach(0..<PillModel.barCount, id: \.self) { index in
                Capsule().fill(Theme.cobaltSoft.opacity(0.9))
                    .frame(width: 2, height: 3 + 9 * model.levels[index])
            }
        }
        .frame(height: 12)
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
            .stroke(Theme.cobaltSoft.opacity(0.9), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .padding(.top, 2)
            .onAppear {
                guard !still else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { phase = 2 }
            }
    }
}

private struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Lets a click act on the pill even though its panel never becomes the active window.
private final class PillHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless panel above the Dock that never takes focus from the app being typed into.
/// It is kept just big enough for the pill, so it never sits on top of anything else.
final class PillPanel {
    private let panel: NSPanel
    private let host: PillHost
    private var anchor = NSPoint.zero
    let model = PillModel()
    /// Where the window currently sits, for diagnostics.
    var frame: NSRect { panel.frame }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        // The padding leaves room for the spring that plays when the pill appears.
        host = PillHost(rootView: AnyView(PillView(model: model).padding(8)))
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
        let appearing = !panel.isVisible
        if appearing {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let area = screen?.visibleFrame { anchor = NSPoint(x: area.midX, y: area.minY) }
        }
        guard model.mode != mode || appearing else { return }
        model.mode = mode
        // SwiftUI lays the new content out on the next pass; fit the window to it then.
        DispatchQueue.main.async { [self] in
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            let grows = size.width >= panel.frame.width
            let frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height)
            if grows || appearing {
                panel.setFrame(frame, display: true)
            } else {
                // Shrink only after the pill has finished narrowing, or its edges would be cut off.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                    if model.mode == mode { panel.setFrame(frame, display: true) }
                }
            }
            if appearing { panel.orderFrontRegardless() }
        }
    }
}
