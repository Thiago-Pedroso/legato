import AppKit
import FluidAudio
import Foundation
import LegatoCore

// `Legato --transcribe file.wav [--model v3]` runs the local engine on a file and exits.
// Useful to compare models on your own voice without opening the app.
let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--transcribe"), arguments.count > flag + 1 {
    let path = arguments[flag + 1]
    var model = LocalModel.parakeetUltra
    if let option = arguments.firstIndex(of: "--model"), arguments.count > option + 1, arguments[option + 1] == "v3" {
        model = .parakeetV3
    }
    func note(_ message: String) { FileHandle.standardError.write((message + "\n").data(using: .utf8)!) }
    let done = DispatchSemaphore(value: 0)
    Task {
        do {
            let samples = try AudioConverter().resampleAudioFile(path: path)
            let engine = ParakeetEngine()
            var clock = Date()
            try await engine.load(model)
            note("\(model.title) loaded in \(String(format: "%.2f", Date().timeIntervalSince(clock)))s")
            clock = Date()
            let text = try await engine.transcribe(samples, model: model, language: "pt")
            let seconds = Double(samples.count) / Double(WAV.sampleRate)
            note("\(String(format: "%.1f", seconds))s of audio in \(String(format: "%.2f", Date().timeIntervalSince(clock)))s")
            print(text)
        } catch {
            note("error: \(error.localizedDescription)")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

if let flag = arguments.firstIndex(of: "--render-assets"), arguments.count > flag + 1 {
    _ = NSApplication.shared
    do {
        try MainActor.assumeIsolated { try Assets.render(to: URL(fileURLWithPath: arguments[flag + 1])) }
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

if let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 {
    _ = NSApplication.shared
    try? MainActor.assumeIsolated { try Assets.snapshotSettings(to: URL(fileURLWithPath: arguments[flag + 1])) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
