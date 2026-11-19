import Foundation

/// 16 kHz mono 16-bit PCM, the format every speech engine here accepts.
public enum WAV {
    public static let sampleRate = 16_000

    public static func encode(_ samples: [Float]) -> Data {
        let byteCount = samples.count * 2
        var data = Data(capacity: 44 + byteCount)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(byteCount))
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }

    /// Reads back a file written by `encode`.
    public static func decode(_ data: Data) -> [Float]? {
        guard data.count >= 44, data.prefix(4) == Data("RIFF".utf8) else { return nil }
        let body = data.dropFirst(44)
        var samples = [Float]()
        samples.reserveCapacity(body.count / 2)
        body.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count - 1, by: 2) {
                let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
                samples.append(Float(value) / Float(Int16.max))
            }
        }
        return samples
    }
}
