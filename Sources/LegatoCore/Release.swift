import Foundation

public enum Release {
    /// Whether a release tag such as "v0.4.0" names a newer version than `current` ("0.3.0").
    /// Anything that is not plain dotted numbers, like a "-beta" tag, never counts as newer.
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        guard let new = numbers(tag), let old = numbers(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int]? {
        let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = trimmed.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }
}
