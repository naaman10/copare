import Foundation

struct AuthUser: Codable, Identifiable, Sendable {
    let id: String
    let email: String
    let name: String?
}

struct AuthSession: Sendable {
    let user: AuthUser
    let jwt: String
}

struct GroupMember: Codable, Identifiable, Sendable {
    var id: String { userId }
    let userId: String
    let role: MemberRole
    let joinedAt: Date
}

enum MemberRole: String, Codable, CaseIterable, Sendable {
    case parentA = "parent_a"
    case parentB = "parent_b"
    case mediatorA = "mediator_a"
    case mediatorB = "mediator_b"

    var label: String {
        switch self {
        case .parentA: "Parent A"
        case .parentB: "Parent B"
        case .mediatorA: "Mediator A"
        case .mediatorB: "Mediator B"
        }
    }
}

enum GroupStatus: String, Codable, Sendable {
    case forming
    case active
    case archived

    var label: String {
        switch self {
        case .forming: "Forming"
        case .active: "Active"
        case .archived: "Archived"
        }
    }
}

struct CopareGroup: Codable, Identifiable, Sendable {
    let id: String
    let status: GroupStatus
    let createdAt: Date?
    let activatedAt: Date?
    let members: [GroupMember]?

    var memberList: [GroupMember] { members ?? [] }
}

struct Conversation: Codable, Identifiable, Sendable {
    let id: String
    let groupId: String
    let title: String
    let createdBy: String
    let lastMessageAt: Date?
    let createdAt: Date
}

struct MessageReceipt: Codable, Sendable {
    let userId: String
    let deliveredAt: Date?
    let readAt: Date?
}

struct Message: Codable, Identifiable, Sendable {
    let id: String
    let conversationId: String
    let senderId: String
    let parentId: String?
    let rootId: String?
    let body: String
    let clientId: String
    let deletedAt: Date?
    let createdAt: Date
    let editedAt: Date?
    let receipts: [MessageReceipt]?
}

struct Invitation: Codable, Sendable {
    let id: String
    let token: String
    let expiresAt: Date
}

struct APIErrorResponse: Codable, Sendable {
    let error: String?
    let message: String?
    let code: String?
}

enum CopareError: LocalizedError, Sendable {
    case invalidResponse
    case unauthorized
    case server(String)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Unexpected response from server."
        case .unauthorized:
            "Session expired. Please sign in again."
        case .server(let message):
            message
        case .network(let error):
            error.localizedDescription
        }
    }
}
