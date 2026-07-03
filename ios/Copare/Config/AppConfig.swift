import Foundation

enum AppConfig {
    static let neonAuthBaseURL: URL = {
        guard let url = url(for: "NEON_AUTH_BASE_URL") else {
            fatalError("NEON_AUTH_BASE_URL missing from Info.plist")
        }
        return url
    }()

    static let apiBaseURL: URL = {
        guard let url = url(for: "API_BASE_URL") else {
            fatalError("API_BASE_URL missing from Info.plist")
        }
        return url
    }()

    static let wsBaseURL: URL = {
        guard let url = url(for: "WS_BASE_URL") else {
            fatalError("WS_BASE_URL missing from Info.plist")
        }
        return url
    }()

    /// Origin sent to Neon Auth on sign-up/sign-in (must be in Neon trusted origins).
    static let authOrigin: String = {
        guard let value = string(for: "AUTH_ORIGIN") else {
            return "copare://"
        }
        return value
    }()

    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else {
            return nil
        }
        return value
    }

    private static func url(for key: String) -> URL? {
        guard let value = string(for: key), let url = URL(string: value) else {
            return nil
        }
        return url
    }
}
