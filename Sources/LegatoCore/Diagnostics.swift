import Foundation

/// How one dictation went, minus what was said: which microphone, how long each step took.
/// When Legato feels slow "sometimes", these are what tell a cold model from a sleepy headset.
public struct DictationTiming: Codable, Equatable, Sendable {
    public var date = Date()
    public var microphone: String?
    public var microphoneRate: Double = 0
    /// The speakers' sample rate when they are Bluetooth. A headset in its call profile drops to
    /// 16 or 24 kHz, which is what recording from its microphone does to music.
    public var bluetoothOutputRate: Double?
    /// Seconds from the key press to the first sound from the microphone.
    public var soundDelay: Double?
    /// Seconds recorded after the key came up, to the end of the last word.
    public var tail: Double = 0
    public var reopenings = 0
    public var audio: Double = 0
    /// Where the model stood when the recording ended: ready, loading, resting, downloading…
    public var model = ""
    /// Seconds the speech engine took, including any wait for the model to load.
    public var transcription: Double = 0
    public var cleanup: Double?
    /// Seconds from the key coming up to the text landing.
    public var total: Double = 0
    public var outcome = ""

    public init() {}
}

public enum DiagnosticsLog {
    /// Enough for a few days of dictation; older lines go.
    public static let limit = 300

    public static func append(_ timing: DictationTiming, to url: URL) {
        var lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        guard let data = try? encoder.encode(timing), let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line)
        try? (lines.suffix(limit).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    public static func load(_ url: URL) -> [DictationTiming] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? decoder.decode(DictationTiming.self, from: Data($0.utf8)) }
    }

    /// A plain-text table to paste into a message, newest last.
    public static func report(_ timings: [DictationTiming], version: String) -> String {
        var lines = [
            "Legato \(version), \(timings.count) dictations. Times in ms: sound = key press to the first sound,",
            "tail = kept after the key came up, engine = speech model, total = key up to the text landing.", "",
        ]
        lines.append("date              mic                      kHz  sound  tail  audio  model      engine  total  outcome")
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm"
        format.locale = Locale(identifier: "en_US_POSIX")
        for t in timings {
            var mic = String((t.microphone ?? "?").prefix(24))
            mic += String(repeating: " ", count: 24 - mic.count)
            if let output = t.bluetoothOutputRate, output < 44_100 { mic = String(mic.prefix(20)) + " HFP" }
            let cells = [
                format.string(from: t.date), mic, pad(String(format: "%.0f", t.microphoneRate / 1000), 3),
                pad(t.soundDelay.map { ms($0) } ?? "none", 5), pad(ms(t.tail), 4), pad(String(format: "%.1fs", t.audio), 5),
                t.model.padding(toLength: 9, withPad: " ", startingAt: 0), pad(ms(t.transcription), 6),
                pad(ms(t.total), 5), t.outcome + (t.reopenings > 0 ? " (reopened \(t.reopenings)x)" : ""),
            ]
            lines.append(cells.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    private static func ms(_ seconds: Double) -> String { String(format: "%.0f", seconds * 1000) }
    private static func pad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
