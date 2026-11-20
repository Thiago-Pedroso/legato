import AppKit
import FluidAudio
import Foundation
import LegatoCore

/// The command-line side of the binary: test a model on a file, or work on the vocabulary.
enum CLI {
    static func note(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }

    /// Runs async work to completion from the synchronous entry point.
    static func wait(_ work: @escaping () async throws -> Void) -> Int32 {
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            do { try await work() } catch {
                note("error: \(error.localizedDescription)")
                status = 1
            }
            done.signal()
        }
        done.wait()
        return status
    }

    static func run(_ arguments: [String]) -> Int32 {
        var rest = arguments
        let command = rest.removeFirst()
        switch command {
        case "--transcribe":
            return transcribe(rest)
        case "--render-assets":
            guard let folder = rest.first else { return usage() }
            _ = NSApplication.shared
            do {
                try MainActor.assumeIsolated { try Assets.render(to: URL(fileURLWithPath: folder)) }
                return 0
            } catch {
                note("error: \(error.localizedDescription)")
                return 1
            }
        case "--snapshot":
            guard let folder = rest.first else { return usage() }
            _ = NSApplication.shared
            try? MainActor.assumeIsolated { try Assets.snapshotSettings(to: URL(fileURLWithPath: folder)) }
            return 0
        case "vocab":
            return Vocab.run(rest)
        default:
            return usage()
        }
    }

    static func usage() -> Int32 {
        note(
            """
            usage:
              Legato --transcribe <audio>... [--model v3]   transcribe files with the local model
              Legato vocab candidates <folder>...           list names and jargon found in the folders' prose
              Legato vocab probe <term>...                  speak each term and report how the model hears it
              Legato vocab suggest --source <label>         read probe results on stdin and queue them for approval
            """)
        return 2
    }

    /// `--transcribe a.wav b.wav [--model v3]`: all files go through one loaded model, in order.
    private static func transcribe(_ arguments: [String]) -> Int32 {
        var paths = arguments
        var model = LocalModel.parakeetUltra
        if let option = paths.firstIndex(of: "--model") {
            if paths.count > option + 1, paths[option + 1] == "v3" { model = .parakeetV3 }
            paths.removeSubrange(option..<min(option + 2, paths.count))
        }
        guard !paths.isEmpty else { return usage() }
        return wait {
            let engine = ParakeetEngine()
            var clock = Date()
            try await engine.load(model)
            note("\(model.title) loaded in \(String(format: "%.2f", Date().timeIntervalSince(clock)))s")
            for path in paths {
                let samples = try AudioConverter().resampleAudioFile(path: path)
                clock = Date()
                let text = try await engine.transcribe(samples, model: model, language: "pt")
                let seconds = Double(samples.count) / Double(WAV.sampleRate)
                note("\(String(format: "%.1f", seconds))s of audio in \(String(format: "%.2f", Date().timeIntervalSince(clock)))s")
                print(text)
            }
        }
    }
}
