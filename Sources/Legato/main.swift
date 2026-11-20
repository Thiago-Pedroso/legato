import AppKit
import Foundation

// With arguments the binary works as a command-line tool (see CLI.swift); without, it is the app.
let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty, !arguments[0].hasPrefix("-psn") {
    exit(CLI.run(arguments))
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
