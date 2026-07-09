import Foundation

actor CopareAPI {
    static let shared = CopareAPI()

    private let baseURL: URL
    private let session: URLSession
    private var jwtProvider: (@Sendable () -> String?)?

    init(baseURL: URL = AppConfig.apiBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func setJWTProvider(_ provider: @escaping @Sendable () -> String?) {
        jwtProvider = provider
    }

    private func currentJWT() -> String? {
        if let jwt = jwtProvider?(), !jwt.isEmpty {
            return jwt
        }
        return KeychainStore.loadJWT()
    }

    // MARK: - Groups

    func listGroups() async throws -> [CopareGroup] {
        let response: GroupsResponse = try await get("groups")
        return response.groups
    }

    func createGroup(displayName: String) async throws -> CopareGroup {
        let response: CreateGroupResponse = try await post("groups", body: ["displayName": displayName])
        return response.group
    }

    func createInvitation(groupId: String, role: MemberRole, email: String) async throws -> Invitation {
        let response: CreateInvitationResponse = try await post(
            "groups/\(groupId)/invitations",
            body: ["role": role.rawValue, "email": email]
        )
        return response.invitation
    }

    func acceptInvitation(token: String, displayName: String) async throws -> AcceptInvitationResponse {
        try await post(
            "groups/invitations/\(token)/accept",
            body: ["displayName": displayName]
        )
    }

    // MARK: - Conversations

    func listConversations(groupId: String) async throws -> [Conversation] {
        let response: ConversationsResponse = try await get("groups/\(groupId)/conversations")
        return response.conversations
    }

    func createConversation(groupId: String, title: String) async throws -> Conversation {
        let response: CreateConversationResponse = try await post(
            "groups/\(groupId)/conversations",
            body: ["title": title]
        )
        return response.conversation
    }

    // MARK: - Messages

    func listMessages(conversationId: String, limit: Int = 50) async throws -> [Message] {
        let response: MessagesResponse = try await get(
            "conversations/\(conversationId)/messages",
            query: [URLQueryItem(name: "limit", value: String(limit))]
        )
        return response.messages.reversed()
    }

    func sendMessage(conversationId: String, body: String, clientId: UUID) async throws -> Message {
        let response: SendMessageResponse = try await post(
            "conversations/\(conversationId)/messages",
            body: [
                "body": body,
                "clientId": clientId.uuidString,
            ]
        )
        return response.message
    }

    func markRead(
        conversationId: String,
        lastMessageId: String? = nil,
        lastActionId: String? = nil
    ) async throws {
        var body: [String: String] = [:]
        if let lastMessageId { body["lastMessageId"] = lastMessageId }
        if let lastActionId { body["lastActionId"] = lastActionId }
        let _: OkResponse = try await put(
            "conversations/\(conversationId)/read",
            body: body
        )
    }

    func markDelivered(messageId: String) async throws {
        let _: DeliveredResponse = try await post("messages/\(messageId)/delivered", body: [:])
    }

    func markActionDelivered(actionId: String) async throws {
        let _: DeliveredResponse = try await post("actions/\(actionId)/delivered", body: [:])
    }

    func registerDevice(token: String) async throws {
        let _: OkResponse = try await post(
            "devices",
            body: ["token": token, "platform": "ios"]
        )
    }

    func syncProfile(displayName: String) async throws {
        let _: ProfileResponse = try await put(
            "profile",
            body: ["displayName": displayName]
        )
    }

    func fetchProfile() async throws -> String? {
        let response: ProfileResponse = try await get("profile")
        return response.displayName
    }

    // MARK: - Actions

    func listActions(conversationId: String) async throws -> [ConversationAction] {
        let response: ActionsResponse = try await get("conversations/\(conversationId)/actions")
        return response.actions
    }

    func createConfirmationRequest(
        conversationId: String,
        statement: String
    ) async throws -> ConversationAction {
        let response: ActionResponse = try await post(
            "conversations/\(conversationId)/actions",
            body: [
                "actionType": ConversationActionType.confirmationRequest.rawValue,
                "statement": statement,
            ]
        )
        return response.action
    }

    func confirmAction(actionId: String) async throws -> ConversationAction {
        let response: ActionResponse = try await post("actions/\(actionId)/confirm", body: [:])
        return response.action
    }

    func declineAction(actionId: String, responseNote: String?) async throws -> ConversationAction {
        var body: [String: String] = [:]
        if let responseNote, !responseNote.isEmpty {
            body["responseNote"] = responseNote
        }
        let response: ActionResponse = try await post("actions/\(actionId)/decline", body: body)
        return response.action
    }

    // MARK: - HTTP helpers

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        try await request(path: path, method: "GET", body: nil as [String: String]?, query: query)
    }

    private func post<T: Decodable>(
        _ path: String,
        body: [String: String]
    ) async throws -> T {
        try await request(path: path, method: "POST", body: body)
    }

    private func put<T: Decodable>(
        _ path: String,
        body: [String: String]
    ) async throws -> T {
        try await request(path: path, method: "PUT", body: body)
    }

    private func request<T: Decodable>(
        path: String,
        method: String,
        body: [String: String]?,
        query: [URLQueryItem] = [],
        retried: Bool = false
    ) async throws -> T {
        guard let jwt = currentJWT() else {
            throw CopareError.unauthorized
        }

        var urlRequest = URLRequest(url: baseURL.appendingAPIPath(path, query: query))
        urlRequest.httpMethod = method
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        if let body {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw CopareError.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CopareError.invalidResponse
        }

        if http.statusCode == 401 {
            if !retried {
                _ = try await AuthService.shared.refreshJWT()
                return try await request(path: path, method: method, body: body, query: query, retried: true)
            }
            throw CopareError.unauthorized
        }

        if http.statusCode >= 400 {
            if let apiError = try? JSONCoding.decoder.decode(APIErrorResponse.self, from: data) {
                throw CopareError.server(apiError.error ?? apiError.message ?? "Request failed.")
            }
            throw CopareError.server("Request failed with status \(http.statusCode).")
        }

        do {
            return try JSONCoding.decoder.decode(T.self, from: data)
        } catch {
            throw CopareError.invalidResponse
        }
    }
}

// MARK: - Response wrappers

private struct GroupsResponse: Decodable {
    let groups: [CopareGroup]
}

private struct CreateGroupResponse: Decodable {
    let group: CopareGroup
}

private struct CreateInvitationResponse: Decodable {
    let invitation: Invitation
}

struct AcceptInvitationResponse: Decodable, Sendable {
    let groupId: String
    let role: String
}

private struct ConversationsResponse: Decodable {
    let conversations: [Conversation]
}

private struct CreateConversationResponse: Decodable {
    let conversation: Conversation
}

private struct MessagesResponse: Decodable {
    let messages: [Message]
}

private struct SendMessageResponse: Decodable {
    let message: Message
}

private struct OkResponse: Decodable {
    let ok: Bool?
}

private struct DeliveredResponse: Decodable {
    let deliveredAt: String?
}

private struct ActionsResponse: Decodable {
    let actions: [ConversationAction]
}

private struct ActionResponse: Decodable {
    let action: ConversationAction
}

private struct ProfileResponse: Decodable {
    let displayName: String?
}

extension URL {
    func appendingAPIPath(_ path: String, query: [URLQueryItem] = []) -> URL {
        let url = path.split(separator: "/").reduce(into: self) { url, component in
            url.append(path: String(component))
        }

        guard !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.queryItems = query
        return components.url ?? url
    }
}
