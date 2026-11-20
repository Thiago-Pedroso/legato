import AppKit
import Combine
import LegatoCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarIcon()
        statusItem.button?.setAccessibilityLabel("Legato")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.launch()
        // First run, or a permission went missing: open the window that explains what to do.
        if !controller.settings.onboarded || !Permissions.accessibility || Permissions.microphone != .authorized {
            controller.settings.onboarded = true
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.restoreOutput()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return true
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusLine))
        menu.addItem(.separator())

        let recent = controller.entries.filter { $0.status == .done }.prefix(8)
        if let last = recent.first {
            menu.addItem(item(L.t("Copy Last Dictation", "Copiar último ditado")) { Inserter.copy(last.text) })
            let submenu = NSMenu()
            for entry in recent {
                let title = entry.text.count > 60 ? String(entry.text.prefix(60)) + "…" : entry.text
                submenu.addItem(item(title.trimmingCharacters(in: .whitespaces)) { Inserter.copy(entry.text) })
            }
            let parent = NSMenuItem(title: L.t("Recent", "Recentes"), action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        if let failed = controller.entries.first, failed.status == .failed, !controller.inFlight.contains(failed.id) {
            menu.addItem(item(L.t("Retry Failed Dictation", "Tentar de novo o ditado que falhou")) { [controller] in
                controller.retry(failed.id, paste: false)
            })
        }
        if recent.first != nil || controller.entries.first?.status == .failed { menu.addItem(.separator()) }

        let settings = item(L.t("Settings…", "Ajustes…")) { [weak self] in self?.openSettings() }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = item(L.t("Quit Legato", "Encerrar o Legato")) { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private var statusLine: String {
        guard controller.hotkeyActive else { return L.t("Needs Accessibility permission", "Precisa da permissão de Acessibilidade") }
        if controller.settings.engine == .local {
            switch controller.modelState {
            case .missing: return L.t("Speech model not downloaded", "Modelo de voz não baixado")
            case .downloading(let fraction): return L.t("Downloading model", "Baixando modelo") + " \(Int(fraction * 100))%"
            case .loading: return L.t("Loading model…", "Carregando modelo…")
            case .failed(let message): return message
            case .ready, .resting: break
            }
        }
        let key = controller.settings.trigger.title
        return L.t("Hold \(key) to dictate", "Segure \(key) para ditar")
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action
        return item
    }

    @objc private func run(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    // MARK: Windows

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(controller: controller)))
            window.title = "Legato"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// A menu-bar app has no visible menu, but text fields still need it for Cmd+C, Cmd+V and friends.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(app)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        edit.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.submenu?.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.submenu?.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(edit)
        return main
    }

    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: SlurMark().path(in: rect).cgPath).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
