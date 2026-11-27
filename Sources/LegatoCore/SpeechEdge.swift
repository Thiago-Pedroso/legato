import Foundation

/// Whether someone is still talking when the dictation key comes up.
///
/// People let go of the key on their last syllable, not after it. A recording that stops right
/// there loses the end of the last word, so it runs on while the sound stays at speech level.
/// A recording that already ends in silence stops at once and costs no time.
public enum SpeechEdge {
    /// The longest Legato keeps listening after the key is released. Replaying releases up to
    /// 0.4 s early over recorded dictations, half a second never cut a word and 0.4 s did.
    public static let longestTail = 0.5
    /// Whether either of the latest two buffers, about a tenth of a second each, held speech.
    /// A single buffer can fall in the pause between two words, and a key released there lost
    /// the last word.
    public static func speaking(_ levels: [Float], above threshold: Float) -> Bool {
        levels.suffix(2).contains { $0 > threshold }
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
