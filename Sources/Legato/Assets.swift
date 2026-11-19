import AppKit
import SwiftUI

/// `Legato --render-assets <folder>` draws the app icon and the README pictures from the
/// same views the app uses, so the pictures never drift from the product.
@MainActor
enum Assets {
    static func render(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png(AppIcon().frame(width: 1024, height: 1024), scale: 1).write(to: folder.appendingPathComponent("icon.png"))
        try png(Hero(), scale: 2).write(to: folder.appendingPathComponent("hero.png"))
    }

    /// `Legato --snapshot <folder>` saves a picture of each settings tab, drawn off screen.
    static func snapshotSettings(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let controller = Controller()
        for (index, name) in ["general", "transcription", "vocabulary", "history"].enumerated() {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(controller: controller, tab: index)))
            window.styleMask = [.titled, .closable]
            window.title = "Legato"
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            guard let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
            else { continue }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("settings-\(name).png"))
            window.close()
        }
    }

    private static func png<V: View>(_ view: V, scale: CGFloat) throws -> Data {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage,
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}

struct AppIcon: View {
    var body: some View {
        // Apple's icon grid: an 824-point rounded square centred on a 1024 canvas.
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(Theme.cobalt)
            .frame(width: 824, height: 824)
            .overlay(SlurMark().fill(Theme.paper).frame(width: 600, height: 600).offset(y: -28))
            .frame(width: 1024, height: 1024)
    }
}

/// The three things the pill can tell you, side by side.
private struct Hero: View {
    var body: some View {
        HStack(spacing: 36) {
            state(.recording(handsFree: false), levels: [0.2, 0.55, 0.9, 0.6, 0.3, 0.75, 1, 0.5, 0.25], "listening")
            state(.working(nil), levels: [], "transcribing")
            state(.failed("Failed. Click to retry"), levels: [], "nothing is lost")
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 44)
        .background(Theme.ink)
    }

    private func state(_ mode: PillModel.Mode, levels: [CGFloat], _ caption: String) -> some View {
        let model = PillModel()
        model.mode = mode
        if !levels.isEmpty { model.levels = levels }
        return VStack(spacing: 12) {
            PillView(model: model, still: true)
            Text(caption).font(.system(size: 12)).foregroundStyle(Theme.paper.opacity(0.55))
        }
    }
}
