import Foundation

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// The cleanup pass on Apple's on-device model, for when the text should not leave the Mac.
enum OnDeviceCleanup {
    /// Nil when the model can be used; otherwise why not, in words for the settings window.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                switch SystemLanguageModel.default.availability {
                case .available:
                    return nil
                case .unavailable(.appleIntelligenceNotEnabled):
                    return L.t(
                        "Turn on Apple Intelligence in System Settings to use it.",
                        "Ligue o Apple Intelligence nos Ajustes do Sistema para usar.")
                case .unavailable(.modelNotReady):
                    return L.t("Apple's model is still downloading.", "O modelo da Apple ainda está baixando.")
                case .unavailable:
                    return L.t("This Mac cannot run Apple's model.", "Este Mac não roda o modelo da Apple.")
                }
            }
        #endif
        return L.t("Needs macOS 26 with Apple Intelligence.", "Precisa do macOS 26 com Apple Intelligence.")
    }

    static func cleanUp(_ text: String, prompt: String) async throws -> String {
        #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                // Same budget as the API pass: a slow answer is dropped and the plain text goes through.
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        let session = LanguageModelSession(instructions: prompt)
                        let response = try await session.respond(to: text, options: GenerationOptions(temperature: 0))
                        let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        return cleaned.isEmpty ? text : cleaned
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(8))
                        throw CancellationError()
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? text
                }
            }
        #endif
        throw EngineError.api(unavailableReason ?? "")
    }
}
