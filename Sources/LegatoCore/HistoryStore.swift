import Foundation

public struct HistoryEntry: Codable, Equatable, Identifiable {
    public enum Status: String, Codable {
        case done, failed
    }

    public var id: UUID
    public var date: Date
    public var text: String
    public var duration: TimeInterval
    public var engine: String
    public var status: Status
    public var error: String?

    public init(
        id: UUID = UUID(), date: Date = Date(), text: String = "", duration: TimeInterval,
        engine: String, status: Status, error: String? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.duration = duration
        self.engine = engine
        self.status = status
        self.error = error
    }
}

/// Dictations and their audio on disk. The audio is written before transcription starts,
/// so a failed or interrupted transcription can always be retried.
public final class HistoryStore {
    public private(set) var entries: [HistoryEntry] = []
    public let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("history.json") }
    private var audioDirectory: URL { directory.appendingPathComponent("recordings", isDirectory: true) }

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
            let saved = try? Self.decoder.decode([HistoryEntry].self, from: data)
        {
            entries = saved
        }
    }

    public func audioURL(for id: UUID) -> URL {
        audioDirectory.appendingPathComponent("\(id.uuidString).wav")
    }

    public func hasAudio(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: audioURL(for: id).path)
    }

    /// Saves the audio and records the dictation as failed until a transcript arrives.
    public func begin(samples: [Float], engine: String, error: String) throws -> HistoryEntry {
        let entry = HistoryEntry(
            duration: Double(samples.count) / Double(WAV.sampleRate), engine: engine, status: .failed, error: error)
        try WAV.encode(samples).write(to: audioURL(for: entry.id), options: .atomic)
        entries.insert(entry, at: 0)
        save()
        return entry
    }

    public func update(_ id: UUID, _ change: (inout HistoryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        change(&entries[index])
        save()
    }

    public func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: audioURL(for: id))
        save()
    }

    public func removeAll() {
        for entry in entries { try? FileManager.default.removeItem(at: audioURL(for: entry.id)) }
        entries = []
        save()
    }

    /// Keeps the newest `limit` dictations. Failed ones are kept too: they are the ones worth retrying.
    public func prune(keeping limit: Int) {
        guard entries.count > limit else { return }
        for entry in entries[limit...] { try? FileManager.default.removeItem(at: audioURL(for: entry.id)) }
        entries = Array(entries.prefix(limit))
        save()
    }

    private func save() {
        guard let data = try? Self.encoder.encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
