import Foundation

/// Neon Auth (Better Auth) REST client for native sign-up / sign-in.
actor AuthService {
    static let shared = AuthService()

    private let baseURL: URL
    private let authOrigin: String
    private let session: URLSession

    init(
        baseURL: URL = AppConfig.neonAuthBaseURL,
        authOrigin: String = AppConfig.authOrigin,
        session: URLSession = AuthService.makeSession()
    ) {
        self.baseURL = baseURL
        self.authOrigin = authOrigin
        self.session = session
    }

    func signUp(email: String, password: String, name: String) async throws -> AuthSession {
        let body = ["email": email, "password": password, "name": name]
        let (data, response) = try await post(path: "sign-up/email", body: body)
        return try await sessionFromAuthResponse(data: data, response: response)
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        let body = ["email": email, "password": password]
        let (data, response) = try await post(path: "sign-in/email", body: body)
        return try await sessionFromAuthResponse(data: data, response: response)
    }

    func restoreSession() -> AuthSession? {
        guard let user = KeychainStore.loadUser() else { return nil }

        if let jwt = KeychainStore.loadJWT() {
            return AuthSession(user: user, jwt: jwt)
        }
        return nil
    }

    /// Refresh JWT using stored session cookie (Neon JWT expires ~15 min).
    func refreshJWT() async throws -> String {
        guard let sessionCookie = KeychainStore.loadSessionCookie() else {
            throw CopareError.unauthorized
        }
        let jwt = try await fetchJWT(sessionCookie: sessionCookie)
        try KeychainStore.saveJWT(jwt)
        return jwt
    }

    func signOut() {
        KeychainStore.clearSession()
    }

    // MARK: - Private

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }

    private func applyAuthHeaders(to request: inout URLRequest) {
        request.setValue(authOrigin, forHTTPHeaderField: "Origin")
    }

    private func sessionFromAuthResponse(data: Data, response: URLResponse) async throws -> AuthSession {
        guard let http = response as? HTTPURLResponse else {
            throw CopareError.invalidResponse
        }
        if http.statusCode >= 400 {
            throw try decodeAPIError(from: data, status: http.statusCode)
        }

        let user = try parseUser(from: data)

        if let jwt = http.value(forHTTPHeaderField: "set-auth-jwt"), !jwt.isEmpty {
            try persist(user: user, jwt: jwt, sessionCookie: sessionCookie(from: http))
            return AuthSession(user: user, jwt: jwt)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let jwt = json?["token"] as? String, jwt.contains(".") {
            try persist(user: user, jwt: jwt, sessionCookie: sessionCookie(from: http))
            return AuthSession(user: user, jwt: jwt)
        }

        guard let sessionCookie = sessionCookie(from: http) else {
            throw CopareError.server("Sign-in succeeded but no session cookie was returned.")
        }

        let jwt = try await fetchJWT(sessionCookie: sessionCookie)
        try persist(user: user, jwt: jwt, sessionCookie: sessionCookie)
        return AuthSession(user: user, jwt: jwt)
    }

    /// Neon Auth returns JWT in `set-auth-jwt` when `/get-session` is called with the session cookie.
    private func fetchJWT(sessionCookie: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "get-session"))
        request.httpMethod = "GET"
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        applyAuthHeaders(to: &request)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CopareError.invalidResponse
        }
        if http.statusCode >= 400 {
            throw try decodeAPIError(from: data, status: http.statusCode)
        }

        if let jwt = http.value(forHTTPHeaderField: "set-auth-jwt"), !jwt.isEmpty {
            return jwt
        }

        throw CopareError.server("Could not retrieve JWT from Neon Auth.")
    }

    private func sessionCookie(from response: HTTPURLResponse) -> String? {
        guard let setCookie = response.value(forHTTPHeaderField: "Set-Cookie") else {
            return nil
        }
        // Keep only name=value (first segment before attributes like Path, HttpOnly).
        return setCookie.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
    }

    private func parseUser(from data: Data) throws -> AuthUser {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let userDict = (json?["user"] as? [String: Any]) ?? json

        guard let id = userDict?["id"] as? String,
              let email = userDict?["email"] as? String else {
            throw CopareError.invalidResponse
        }

        return AuthUser(
            id: id,
            email: email,
            name: userDict?["name"] as? String
        )
    }

    private func persist(user: AuthUser, jwt: String, sessionCookie: String?) throws {
        try KeychainStore.saveJWT(jwt)
        try KeychainStore.saveUser(user)
        if let sessionCookie {
            try KeychainStore.saveSessionCookie(sessionCookie)
        }
    }

    private func post(path: String, body: [String: String]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: baseURL.appendingAPIPath(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        applyAuthHeaders(to: &request)

        do {
            return try await session.data(for: request)
        } catch {
            throw CopareError.network(error)
        }
    }

    private func decodeAPIError(from data: Data, status: Int) throws -> CopareError {
        if status == 401 {
            return .unauthorized
        }
        if let apiError = try? JSONCoding.decoder.decode(APIErrorResponse.self, from: data) {
            let message = apiError.message ?? apiError.error ?? apiError.code ?? "Request failed."
            if apiError.code == "MISSING_ORIGIN" {
                return .server(
                    "Neon Auth requires an Origin header. Add \(authOrigin) to trusted origins in the Neon Console."
                )
            }
            return .server(message)
        }
        return .server("Request failed with status \(status).")
    }
}
