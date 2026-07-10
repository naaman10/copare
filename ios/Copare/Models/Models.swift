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

    var name: String { displayName.nilIfBlank ?? role.label }
}

extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct MemberDirectory: Sendable {
    private let byUserId: [String: GroupMember]

    init(members: [GroupMember]) {
        byUserId = Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0) })
    }

    func displayName(for userId: String) -> String? {
        byUserId[userId]?.displayName.nilIfBlank
    }

    /// profiles.display_name when set, otherwise the member's role label.
    func resolvedName(userId: String, apiDisplayName: String? = nil) -> String {
        if let profileName = displayName(for: userId) {
            return profileName
        }
        if let apiName = apiDisplayName.nilIfBlank {
            return apiName
        }
        return byUserId[userId]?.role.label ?? "Member"
    }

    func name(for userId: String) -> String {
        resolvedName(userId: userId)
    }
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
        if let parent {
            if let mediator {
                return "\(parent.name) & \(mediator.name)"
            }
            return parent.name
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

    var isParent: Bool {
        self == .parentA || self == .parentB
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
    let displayName: String?
    let deliveredAt: Date?
    let readAt: Date?

    func resolvedName(using directory: MemberDirectory) -> String {
        directory.resolvedName(userId: userId, apiDisplayName: displayName)
    }

    enum ReceiptStatus {
        case read
        case delivered
        case pending
    }

    var status: ReceiptStatus {
        if readAt != nil { return .read }
        if deliveredAt != nil { return .delivered }
        return .pending
    }
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

    func senderName(using directory: MemberDirectory) -> String {
        directory.resolvedName(userId: senderId, apiDisplayName: senderDisplayName)
    }

    func updatingReceipt(
        userId: String,
        directory: MemberDirectory,
        deliveredAt: Date? = nil,
        readAt: Date? = nil
    ) -> Message {
        var updated = receipts ?? []
        if let index = updated.firstIndex(where: { $0.userId == userId }) {
            let existing = updated[index]
            updated[index] = MessageReceipt(
                userId: existing.userId,
                displayName: existing.displayName.nilIfBlank ?? directory.displayName(for: userId),
                deliveredAt: deliveredAt ?? existing.deliveredAt,
                readAt: readAt ?? existing.readAt
            )
        } else {
            updated.append(
                MessageReceipt(
                    userId: userId,
                    displayName: directory.displayName(for: userId),
                    deliveredAt: deliveredAt,
                    readAt: readAt
                )
            )
        }
        return Message(
            id: id,
            conversationId: conversationId,
            senderId: senderId,
            senderDisplayName: senderDisplayName,
            parentId: parentId,
            rootId: rootId,
            body: body,
            clientId: clientId,
            deletedAt: deletedAt,
            createdAt: createdAt,
            editedAt: editedAt,
            receipts: updated
        )
    }
}

enum ConversationActionType: String, Codable, Sendable {
    case confirmationRequest = "confirmation_request"
}

enum ConversationActionStatus: String, Codable, Sendable {
    case pending
    case confirmed
    case declined
    case alternativePending = "alternative_pending"

    var label: String {
        switch self {
        case .pending: "Pending"
        case .confirmed: "Confirmed"
        case .declined: "Declined"
        case .alternativePending: "Alternative proposed"
        }
    }
}

struct ConversationAction: Codable, Identifiable, Sendable {
    let id: String
    let conversationId: String
    let groupId: String
    let actionType: ConversationActionType
    let status: ConversationActionStatus
    let statement: String
    let responseNote: String?
    let alternativeStatement: String?
    let acceptedStatement: String?
    let createdBy: String
    let createdByDisplayName: String?
    let assignedTo: String
    let assignedToDisplayName: String?
    let resolvedBy: String?
    let resolvedByDisplayName: String?
    let createdAt: Date
    let resolvedAt: Date?
    let receipts: [MessageReceipt]?

    func creatorName(using directory: MemberDirectory) -> String {
        directory.resolvedName(userId: createdBy, apiDisplayName: createdByDisplayName)
    }

    func assigneeName(using directory: MemberDirectory) -> String {
        directory.resolvedName(userId: assignedTo, apiDisplayName: assignedToDisplayName)
    }

    func resolverName(using directory: MemberDirectory) -> String? {
        guard let resolvedBy else { return nil }
        return directory.resolvedName(userId: resolvedBy, apiDisplayName: resolvedByDisplayName)
    }

    /// True when the action went through decline / alternative negotiation.
    var hasNegotiationHistory: Bool {
        responseNote.nilIfBlank != nil
            || alternativeStatement.nilIfBlank != nil
            || acceptedStatement.nilIfBlank != nil
    }
}

enum TimelineItem: Identifiable, Sendable {
    case message(Message)
    case action(ConversationAction)

    var id: String {
        switch self {
        case .message(let message): "msg-\(message.id)"
        case .action(let action): "act-\(action.id)"
        }
    }

    var createdAt: Date {
        switch self {
        case .message(let message): message.createdAt
        case .action(let action): action.createdAt
        }
    }
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
