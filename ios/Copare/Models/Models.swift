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
    let displayName: String?
    let joinedAt: Date

    var name: String { displayName ?? role.label }
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

    /// Parent ↔ mediator pairs in a co-parenting group.
    static let sides: [(parent: MemberRole, mediator: MemberRole)] = [
        (.parentA, .mediatorA),
        (.parentB, .mediatorB),
    ]

    var pairedMediator: MemberRole? {
        switch self {
        case .parentA: .mediatorA
        case .parentB: .mediatorB
        case .mediatorA: .parentA
        case .mediatorB: .parentB
        }
    }

    var sideTitle: String {
        switch self {
        case .parentA, .mediatorA: "Parent A & Mediator A"
        case .parentB, .mediatorB: "Parent B & Mediator B"
        }
    }

    static func sideDisplayTitle(
        parent: GroupMember?,
        mediator: GroupMember?,
        fallback: MemberRole
    ) -> String {
        if let parentName = parent?.displayName {
            if let mediatorName = mediator?.displayName {
                return "\(parentName) & \(mediatorName)"
            }
            return parentName
        }
        return fallback.sideTitle
    }

    /// Roles this member is allowed to invite.
    func invitableRoles(openRoles: Set<MemberRole>) -> [MemberRole] {
        let permitted: [MemberRole]
        switch self {
        case .parentA: permitted = [.parentB, .mediatorA]
        case .parentB: permitted = [.mediatorB]
        default: permitted = []
        }
        return permitted.filter { openRoles.contains($0) }
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

    func member(for role: MemberRole) -> GroupMember? {
        memberList.first { $0.role == role }
    }

    func role(forUserId userId: String) -> MemberRole? {
        memberList.first { $0.userId == userId }?.role
    }

    var openRoles: Set<MemberRole> {
        let taken = Set(memberList.map(\.role))
        return Set(MemberRole.allCases.filter { !taken.contains($0) && $0 != .parentA })
    }
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
    let senderDisplayName: String?
    let parentId: String?
    let rootId: String?
    let body: String
    let clientId: String
    let deletedAt: Date?
    let createdAt: Date
    let editedAt: Date?
    let receipts: [MessageReceipt]?

    var senderName: String { senderDisplayName ?? "Member" }
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
