import Foundation

@MainActor
final class WebSocketManager: ObservableObject {
    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
    }

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastEvent: WSEvent?

    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private let session = URLSession(configuration: .default)
    private var jwtProvider: (() -> String?)?

    func setJWTProvider(_ provider: @escaping () -> String?) {
        jwtProvider = provider
    }

    func connect() {
        guard state != .connected && state != .connecting else { return }
        guard let jwt = jwtProvider?(), !jwt.isEmpty else { return }

        disconnect()
        state = .connecting

        var components = URLComponents(url: AppConfig.wsBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "token", value: jwt)]

        guard let url = components.url else {
            state = .disconnected
            return
        }

        task = session.webSocketTask(with: url)
        task?.resume()
        listen()
    }

    func disconnect() {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    func sendPing() {
        task?.send(.string("ping")) { _ in }
    }

    private func listen() {
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = self.task else { return }
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    await MainActor.run {
                        self.state = .disconnected
                    }
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let event = try? JSONCoding.decoder.decode(WSEvent.self, from: data) else {
                return
            }
            if event.type == "connected" {
                state = .connected
            }
            lastEvent = event
        case .data(let data):
            guard let event = try? JSONCoding.decoder.decode(WSEvent.self, from: data) else {
                return
            }
            if event.type == "connected" {
                state = .connected
            }
            lastEvent = event
        @unknown default:
            break
        }
    }
}

struct WSEvent: Decodable, Sendable {
    let type: String
    let userId: String?
    let conversationId: String?
    let messageId: String?
    let message: Message?
    let at: String?
}
