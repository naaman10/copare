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
        let cookie = KeychainStore.loadSessionCookie() ?? sessionCookieHeader(for: baseURL)
        guard cookie != nil || hasStoredSessionCookies(for: baseURL) else {
            throw CopareError.unauthorized
        }
        let jwt = try await fetchJWT(sessionCookie: cookie)
        try KeychainStore.saveJWT(jwt)
        if let cookie {
            try KeychainStore.saveSessionCookie(cookie)
        }
        return jwt
    }

    func signOut() {
        session.configuration.httpCookieStorage?.cookies(for: baseURL)?.forEach {
            session.configuration.httpCookieStorage?.deleteCookie($0)
        }
        KeychainStore.clearSession()
    }

    // MARK: - Private

    /// iOS blocks reading `Set-Cookie` from responses; enable the cookie jar so
    /// sign-in cookies are available for `/get-session` in the same session.
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
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
        let resolvedCookie = resolveSessionCookie(from: http)

        if let jwt = headerValue("set-auth-jwt", from: http), !jwt.isEmpty {
            try persist(user: user, jwt: jwt, sessionCookie: resolvedCookie)
            return AuthSession(user: user, jwt: jwt)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let jwt = json?["token"] as? String, jwt.contains(".") {
            try persist(user: user, jwt: jwt, sessionCookie: resolvedCookie)
            return AuthSession(user: user, jwt: jwt)
        }

        let jwt = try await fetchJWT(sessionCookie: resolvedCookie)
        try persist(user: user, jwt: jwt, sessionCookie: resolvedCookie)
        return AuthSession(user: user, jwt: jwt)
    }

    /// Neon Auth returns JWT in `set-auth-jwt` when `/get-session` is called with the session cookie.
    private func fetchJWT(sessionCookie: String?) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "get-session"))
        request.httpMethod = "GET"
        applyAuthHeaders(to: &request)
        if let sessionCookie {
            request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CopareError.invalidResponse
        }
        if http.statusCode >= 400 {
            throw try decodeAPIError(from: data, status: http.statusCode)
        }

        if let jwt = headerValue("set-auth-jwt", from: http), !jwt.isEmpty {
            return jwt
        }

        throw CopareError.server("Could not retrieve JWT from Neon Auth.")
    }

    private func resolveSessionCookie(from response: HTTPURLResponse) -> String? {
        sessionCookie(from: response) ?? sessionCookieHeader(for: baseURL)
    }

    private func sessionCookie(from response: HTTPURLResponse) -> String? {
        guard let setCookie = headerValue("Set-Cookie", from: response) else {
            return nil
        }
        return setCookie.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces)
    }

    private func sessionCookieHeader(for url: URL) -> String? {
        guard let cookies = session.configuration.httpCookieStorage?.cookies(for: url), !cookies.isEmpty else {
            return nil
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func hasStoredSessionCookies(for url: URL) -> Bool {
        guard let cookies = session.configuration.httpCookieStorage?.cookies(for: url) else {
            return false
        }
        return !cookies.isEmpty
    }

    private func headerValue(_ name: String, from response: HTTPURLResponse) -> String? {
        if let direct = response.value(forHTTPHeaderField: name), !direct.isEmpty {
            return direct
        }
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            return value as? String
        }
        return nil
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
        if let apiError = try? JSONCoding.decoder.decode(APIErrorResponse.self, from: data) {
            let message = apiError.message ?? apiError.error ?? apiError.code ?? "Request failed."
            if apiError.code == "MISSING_ORIGIN" {
                return .server(
                    "Neon Auth requires an Origin header. Add \(authOrigin) to trusted origins in the Neon Console."
                )
            }
            if apiError.code == "INVALID_EMAIL_OR_PASSWORD" {
                return .server("Invalid email or password.")
            }
            return .server(message)
        }
        if status == 401 {
            return .unauthorized
        }
        return .server("Request failed with status \(status).")
    }
}
