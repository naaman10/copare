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
        if let restored = await AuthService.shared.restoreSession() {
            session = restored
            await configureServices()
            webSocket.connect()
        }
    }

    func signIn(email: String, password: String) async {
        await authenticate {
            try await AuthService.shared.signIn(email: email, password: password)
        }
    }

    func signUp(email: String, password: String, name: String) async {
        await authenticate {
            try await AuthService.shared.signUp(email: email, password: password, name: name)
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
    }
}
