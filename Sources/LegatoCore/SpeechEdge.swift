import Foundation

/// Whether someone is still talking when the dictation key comes up.
///
/// People let go of the key on their last syllable, not after it. A recording that stops right
/// there loses the end of the last word, so it runs on while the sound stays at speech level.
/// A recording that already ends in silence stops at once and costs no time.
public enum SpeechEdge {
    /// The longest Legato keeps listening after the key is released.
    public static let longestTail = 0.6
    /// Whether the latest buffer, about a tenth of a second, held speech. Finer steps mistake the
    /// pause between two words for the end.
    public static func speaking(_ levels: [Float], above threshold: Float) -> Bool {
        levels.last.map { $0 > threshold } ?? false
    }

    /// The level above which a stretch of audio counts as speech, from the loudness of each
    /// buffer recorded so far: well above the room's own noise or close to how loud the speaker
    /// has been, whichever is lower, and never below -50 dBFS. A short dictation is nearly all
    /// speech, so its quietest moments say little about the room; its loudest say how the
    /// speaker sounds.
    public static func threshold(levels: [Float]) -> Float {
        let heard = levels.filter { $0 > -90 }.sorted()
        guard !heard.isEmpty else { return 0 }
        let floor = heard[heard.count / 10]
        let speech = heard[heard.count * 9 / 10]
        return max(-50, min(floor + 12, speech - 12))
    }
}
