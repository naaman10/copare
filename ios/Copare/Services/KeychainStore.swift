import Foundation
import Security

enum KeychainStore {
    private static let service = "com.copare.app"
    private static let jwtAccount = "auth.jwt"
    private static let userAccount = "auth.user"
    private static let sessionCookieAccount = "auth.session_cookie"

    static func saveJWT(_ token: String) throws {
        try save(token.data(using: .utf8)!, account: jwtAccount)
    }

    static func loadJWT() -> String? {
        guard let data = load(account: jwtAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteJWT() {
        delete(account: jwtAccount)
    }

    static func saveSessionCookie(_ cookie: String) throws {
        try save(cookie.data(using: .utf8)!, account: sessionCookieAccount)
    }

    static func loadSessionCookie() -> String? {
        guard let data = load(account: sessionCookieAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteSessionCookie() {
        delete(account: sessionCookieAccount)
    }

    static func saveUser(_ user: AuthUser) throws {
        let data = try JSONCoding.encoder.encode(user)
        try save(data, account: userAccount)
    }

    static func loadUser() -> AuthUser? {
        guard let data = load(account: userAccount) else { return nil }
        return try? JSONCoding.decoder.decode(AuthUser.self, from: data)
    }

    static func deleteUser() {
        delete(account: userAccount)
    }

    static func clearSession() {
        deleteJWT()
        deleteUser()
        deleteSessionCookie()
    }

    private static func save(_ data: Data, account: String) throws {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CopareError.server("Could not save credentials (code \(status)).")
        }
    }

    private static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
