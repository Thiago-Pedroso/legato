import Foundation
import NaturalLanguage

/// A word or two gives the speech model little to tell languages apart, and now and then it
/// answers a Portuguese "teste" with "says she". Pasting that is worse than asking again.
public enum LanguageCheck {
    /// True when a short, low-confidence transcript reads as some other language than the one
    /// being dictated. Vocabulary terms count as expected, since they are often English names.
    public static func soundsLikeAnotherLanguage(
        _ text: String, expected: String, duration: TimeInterval, confidence: Float, vocabulary: [String]
    ) -> Bool {
        guard expected != "auto", duration < 2, confidence < 0.9 else { return false }
        let key = TextProcessor.normalize(text)
        guard !key.isEmpty else { return false }
        if vocabulary.contains(where: { !TextProcessor.normalize($0).isEmpty && key.contains(TextProcessor.normalize($0)) }) {
            return false
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let expectedShare = recognizer.languageHypotheses(withMaximum: 10)[NLLanguage(rawValue: expected)] ?? 0
        return expectedShare < 0.1
    }
}
