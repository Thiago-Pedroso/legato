import Foundation
import LegatoCore

/// Asks GitHub whether a newer release is out. The request carries nothing about the user.
enum UpdateCheck {
    struct Available: Equatable {
        let version: String
        let page: URL
    }

    static let latestURL = URL(string: "https://api.github.com/repos/Thiago-Pedroso/legato/releases/latest")!

    /// The newest release when it is newer than this build; nil otherwise or when offline.
    static func newer() async -> Available? {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String,
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard Release.isNewer(tag, than: current) else { return nil }
        return Available(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, page: page)
    }
}
