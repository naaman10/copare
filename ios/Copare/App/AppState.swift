import Foundation

@MainActor
@Observable
final class AppState {
    var session: AuthSession?
    var isLoading = false
    var errorMessage: String?

    let webSocket = WebSocketManager()

    init() {
        Task { await restoreSession() }
    }

    var isAuthenticated: Bool { session != nil }

    func restoreSession() async {
        guard await AuthService.shared.restoreSession() != nil,
              let user = KeychainStore.loadUser() else {
            return
        }

        do {
            let jwt: String
            if KeychainStore.loadSessionCookie() != nil {
                jwt = try await AuthService.shared.refreshJWT()
            } else if let existing = KeychainStore.loadJWT() {
                jwt = existing
            } else {
                return
            }
            session = AuthSession(user: user, jwt: jwt)
            await configureServices()
            webSocket.connect()
        } catch {
            KeychainStore.clearSession()
            session = nil
        }
    }

    func signIn(email: String, password: String) async {
        await authenticate {
            try await AuthService.shared.signIn(email: email, password: password)
        }
    }

    func signUp(email: String, password: String, name: String) async {
        await authenticate {
            let session = try await AuthService.shared.signUp(email: email, password: password, name: name)
            try? await CopareAPI.shared.syncProfile(displayName: name)
            return session
        }
    }

    func signOut() {
        webSocket.disconnect()
        Task { await AuthService.shared.signOut() }
        session = nil
    }

    private func authenticate(_ action: () async throws -> AuthSession) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let newSession = try await action()
            session = newSession
            await configureServices()
            webSocket.connect()
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func configureServices() async {
        let provider: @Sendable () -> String? = { KeychainStore.loadJWT() }
        await CopareAPI.shared.setJWTProvider(provider)
        webSocket.setJWTProvider { KeychainStore.loadJWT() }
        if let name = session?.user.name, !name.isEmpty {
            try? await CopareAPI.shared.syncProfile(displayName: name)
        }
        await PushNotificationManager.shared.registerForRemoteNotifications()
    }
}
