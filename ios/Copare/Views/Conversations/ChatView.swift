import SwiftUI
import UIKit

@MainActor
@Observable
final class ChatViewModel {
    var timeline: [TimelineItem] = []
    var draft = ""
    var isLoading = false
    var isSending = false
    var isSubmittingAction = false
    var errorMessage: String?
    var mediationRefreshToken = 0

    private let conversationId: String
    private let groupId: String
    private(set) var memberDirectory: MemberDirectory

    init(conversationId: String, groupId: String) {
        self.conversationId = conversationId
        self.groupId = groupId
        self.memberDirectory = MemberDirectory(members: [])
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        await refreshMembers()

        do {
            async let messagesTask = CopareAPI.shared.listMessages(conversationId: conversationId)
            async let actionsTask = CopareAPI.shared.listActions(conversationId: conversationId)
            let (messages, actions) = try await (messagesTask, actionsTask)
            timeline = mergeTimeline(messages: messages, actions: actions)
            await markTimelineSeen(messages: messages, actions: actions)
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshMembers() async {
        do {
            let members = try await CopareAPI.shared.listGroupMembers(groupId: groupId)
            memberDirectory = MemberDirectory(members: members)
        } catch {
            // Keep the last known directory if the members request fails.
        }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSending = true
        defer { isSending = false }

        do {
            let message = try await CopareAPI.shared.sendMessage(
                conversationId: conversationId,
                body: text,
                clientId: UUID()
            )
            draft = ""
            appendMessageIfNeeded(message)
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createConfirmationRequest(statement: String) async -> Bool {
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        isSubmittingAction = true
        errorMessage = nil
        defer { isSubmittingAction = false }

        do {
            let action = try await CopareAPI.shared.createConfirmationRequest(
                conversationId: conversationId,
                statement: text
            )
            appendActionIfNeeded(action)
            return true
        } catch let error as CopareError {
            errorMessage = error.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func confirmAction(_ action: ConversationAction) async {
        await resolveAction(actionId: action.id) {
            try await CopareAPI.shared.confirmAction(actionId: action.id)
        }
    }

    func declineAction(_ action: ConversationAction, reason: String, alternativeStatement: String?) async {
        await resolveAction(actionId: action.id) {
            try await CopareAPI.shared.declineAction(
                actionId: action.id,
                reason: reason,
                alternativeStatement: alternativeStatement
            )
        }
    }

    func confirmAlternative(_ action: ConversationAction) async {
        await resolveAction(actionId: action.id) {
            try await CopareAPI.shared.confirmAlternative(actionId: action.id)
        }
    }

    func declineAlternative(_ action: ConversationAction) async {
        await resolveAction(actionId: action.id) {
            try await CopareAPI.shared.declineAlternative(actionId: action.id)
        }
    }

    func createMediationRequest(topic: String) async -> Bool {
        let text = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        isSubmittingAction = true
        errorMessage = nil
        defer { isSubmittingAction = false }

        do {
            let action = try await CopareAPI.shared.createMediationRequest(
                conversationId: conversationId,
                topic: text
            )
            appendActionIfNeeded(action)
            return true
        } catch let error as CopareError {
            errorMessage = error.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func respondToMediation(_ action: ConversationAction, response: String) async {
        await resolveAction(actionId: action.id) {
            try await CopareAPI.shared.respondToMediation(actionId: action.id, response: response)
        }
    }

    func resolveMediation(_ action: ConversationAction, resolution: String) async {
        await resolveAction(actionId: action.id) {
            try await CopareAPI.shared.resolveMediation(actionId: action.id, resolution: resolution)
        }
    }

    func approveMediationResolution(_ action: ConversationAction) async {
        await resolveAction(actionId: action.id) {
            try await CopareAPI.shared.approveMediationResolution(actionId: action.id)
        }
    }

    func declineMediationResolution(_ action: ConversationAction, reason: String) async {
        await resolveAction(actionId: action.id) {
            try await CopareAPI.shared.declineMediationResolution(actionId: action.id, reason: reason)
        }
    }

    func sendMediationMessage(actionId: String, body: String) async -> Message? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        do {
            return try await CopareAPI.shared.sendMediationMessage(
                actionId: actionId,
                body: text,
                clientId: UUID()
            )
        } catch let error as CopareError {
            errorMessage = error.errorDescription
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func loadMediationMessages(actionId: String) async -> [Message] {
        do {
            return try await CopareAPI.shared.listMediationMessages(actionId: actionId)
        } catch {
            return []
        }
    }

    func handleWebSocketEvent(_ event: WSEvent?, currentUserId: String) {
        guard let event, event.conversationId == conversationId else { return }

        switch event.type {
        case "message.new":
            guard let message = event.message else { return }
            if message.rootId != nil {
                if message.senderId != currentUserId {
                    mediationRefreshToken += 1
                }
                return
            }
            guard message.senderId != currentUserId else {
                return
            }
            appendMessageIfNeeded(message)
            Task {
                try? await CopareAPI.shared.markDelivered(messageId: message.id)
                try? await CopareAPI.shared.markRead(
                    conversationId: conversationId,
                    lastMessageId: message.id
                )
            }
        case "action.new":
            guard let action = event.action,
                  action.createdBy != currentUserId else {
                return
            }
            appendActionIfNeeded(action)
            Task {
                try? await CopareAPI.shared.markActionDelivered(actionId: action.id)
                try? await CopareAPI.shared.markRead(
                    conversationId: conversationId,
                    lastActionId: action.id
                )
            }
        case "action.updated":
            guard let action = event.action else { return }
            updateAction(action)
            if action.status == .alternativePending || action.status == .parentApprovalPending {
                Task { await refreshAction(action.id) }
            }
            if action.createdBy != currentUserId && action.resolvedBy != currentUserId {
                Task {
                    try? await CopareAPI.shared.markActionDelivered(actionId: action.id)
                    try? await CopareAPI.shared.markRead(
                        conversationId: conversationId,
                        lastActionId: action.id
                    )
                }
            }
        case "message.delivered":
            guard let messageId = event.messageId,
                  let userId = event.userId,
                  let at = parseEventDate(event.at) else {
                return
            }
            updateMessageReceipt(messageId: messageId, userId: userId, deliveredAt: at)
        case "message.read":
            guard let messageId = event.messageId,
                  let userId = event.userId,
                  let at = parseEventDate(event.at) else {
                return
            }
            updateMessageReceipt(messageId: messageId, userId: userId, readAt: at)
        default:
            break
        }
    }

    private func parseEventDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func updateMessageReceipt(
        messageId: String,
        userId: String,
        deliveredAt: Date? = nil,
        readAt: Date? = nil
    ) {
        guard let index = timeline.firstIndex(where: {
            if case .message(let message) = $0 { return message.id == messageId }
            return false
        }), case .message(let message) = timeline[index] else {
            return
        }
        timeline[index] = .message(
            message.updatingReceipt(
                userId: userId,
                directory: memberDirectory,
                deliveredAt: deliveredAt,
                readAt: readAt
            )
        )
    }

    private func resolveAction(
        actionId: String,
        operation: () async throws -> ConversationAction
    ) async {
        isSubmittingAction = true
        errorMessage = nil
        defer { isSubmittingAction = false }

        do {
            let action = try await operation()
            updateAction(action)
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeTimeline(
        messages: [Message],
        actions: [ConversationAction]
    ) -> [TimelineItem] {
        let messageItems = messages.map { TimelineItem.message($0) }
        let actionItems = actions.map { TimelineItem.action($0) }
        return (messageItems + actionItems).sorted { $0.createdAt < $1.createdAt }
    }

    private func appendMessageIfNeeded(_ message: Message) {
        guard !timeline.contains(where: {
            if case .message(let existing) = $0 { return existing.id == message.id }
            return false
        }) else {
            return
        }
        timeline.append(.message(message))
        timeline.sort { $0.createdAt < $1.createdAt }
    }

    private func appendActionIfNeeded(_ action: ConversationAction) {
        guard !timeline.contains(where: {
            if case .action(let existing) = $0 { return existing.id == action.id }
            return false
        }) else {
            return
        }
        timeline.append(.action(action))
        timeline.sort { $0.createdAt < $1.createdAt }
    }

    private func updateAction(_ action: ConversationAction) {
        if let index = timeline.firstIndex(where: {
            if case .action(let existing) = $0 { return existing.id == action.id }
            return false
        }) {
            timeline[index] = .action(action)
        } else {
            appendActionIfNeeded(action)
        }
    }

    private func refreshAction(_ actionId: String) async {
        do {
            let actions = try await CopareAPI.shared.listActions(conversationId: conversationId)
            guard let fresh = actions.first(where: { $0.id == actionId }) else { return }
            updateAction(fresh)
        } catch {
            // Keep the WebSocket payload if the refresh fails.
        }
    }

    private func markTimelineSeen(
        messages: [Message],
        actions: [ConversationAction]
    ) async {
        guard messages.last != nil || actions.last != nil else { return }
        try? await CopareAPI.shared.markRead(
            conversationId: conversationId,
            lastMessageId: messages.last?.id,
            lastActionId: actions.last?.id
        )
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var appState
    let conversation: Conversation
    let currentUserRole: MemberRole?

    @State private var viewModel: ChatViewModel
    @State private var showActionsMenu = false

    init(
        conversation: Conversation,
        currentUserRole: MemberRole? = nil
    ) {
        self.conversation = conversation
        self.currentUserRole = currentUserRole
        _viewModel = State(initialValue: ChatViewModel(
            conversationId: conversation.id,
            groupId: conversation.groupId
        ))
    }

    private var canCreateActions: Bool {
        currentUserRole?.isParent == true
    }

    private var currentUserId: String {
        appState.session?.user.id ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            ChatTimelineView(
                timeline: viewModel.timeline,
                currentUserId: currentUserId,
                currentUserRole: currentUserRole,
                memberDirectory: viewModel.memberDirectory,
                isSubmittingAction: viewModel.isSubmittingAction,
                onConfirm: { action in
                    Task { await viewModel.confirmAction(action) }
                },
                onDecline: { action, reason, alternative in
                    Task { await viewModel.declineAction(action, reason: reason, alternativeStatement: alternative) }
                },
                onApproveAlternative: { action in
                    Task { await viewModel.confirmAlternative(action) }
                },
                onDeclineAlternative: { action in
                    Task { await viewModel.declineAlternative(action) }
                },
                onRespondToMediation: { action, response in
                    Task { await viewModel.respondToMediation(action, response: response) }
                },
                onResolveMediation: { action, resolution in
                    Task { await viewModel.resolveMediation(action, resolution: resolution) }
                },
                onApproveMediationResolution: { action in
                    Task { await viewModel.approveMediationResolution(action) }
                },
                onDeclineMediationResolution: { action, reason in
                    Task { await viewModel.declineMediationResolution(action, reason: reason) }
                },
                onLoadMediationMessages: { actionId in
                    await viewModel.loadMediationMessages(actionId: actionId)
                },
                onSendMediationMessage: { actionId, body in
                    await viewModel.sendMediationMessage(actionId: actionId, body: body)
                },
                mediationRefreshToken: viewModel.mediationRefreshToken
            )

            Divider()

            ChatComposerBar(
                draft: $viewModel.draft,
                canCreateActions: canCreateActions,
                isSending: viewModel.isSending,
                isSubmittingAction: viewModel.isSubmittingAction,
                onCreateAction: { showActionsMenu = true },
                onSend: { Task { await viewModel.send() } }
            )
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .copareHidesTabBarOnPush()
        .overlay {
            if viewModel.isLoading && viewModel.timeline.isEmpty {
                ProgressView()
            }
        }
        .task(id: currentUserId) {
            guard !currentUserId.isEmpty else { return }
            viewModel = ChatViewModel(
                conversationId: conversation.id,
                groupId: conversation.groupId
            )
            await viewModel.load()
        }
        .onReceive(appState.webSocket.$lastEvent) { event in
            viewModel.handleWebSocketEvent(event, currentUserId: currentUserId)
        }
        .sheet(isPresented: $showActionsMenu) {
            ChatActionsFlowView(
                isSubmitting: viewModel.isSubmittingAction,
                onCreateConfirmation: { statement in
                    await viewModel.createConfirmationRequest(statement: statement)
                },
                onCreateMediation: { topic in
                    await viewModel.createMediationRequest(topic: topic)
                }
            )
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

private struct ChatTimelineView: View {
    let timeline: [TimelineItem]
    let currentUserId: String
    let currentUserRole: MemberRole?
    let memberDirectory: MemberDirectory
    let isSubmittingAction: Bool
    let onConfirm: (ConversationAction) -> Void
    let onDecline: (ConversationAction, String, String?) -> Void
    let onApproveAlternative: (ConversationAction) -> Void
    let onDeclineAlternative: (ConversationAction) -> Void
    let onRespondToMediation: (ConversationAction, String) -> Void
    let onResolveMediation: (ConversationAction, String) -> Void
    let onApproveMediationResolution: (ConversationAction) -> Void
    let onDeclineMediationResolution: (ConversationAction, String) -> Void
    let onLoadMediationMessages: (String) async -> [Message]
    let onSendMediationMessage: (String, String) async -> Message?
    let mediationRefreshToken: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(timeline) { item in
                        TimelineRowView(
                            item: item,
                            currentUserId: currentUserId,
                            currentUserRole: currentUserRole,
                            memberDirectory: memberDirectory,
                            isSubmittingAction: isSubmittingAction,
                            onConfirm: onConfirm,
                            onDecline: onDecline,
                            onApproveAlternative: onApproveAlternative,
                            onDeclineAlternative: onDeclineAlternative,
                            onRespondToMediation: onRespondToMediation,
                            onResolveMediation: onResolveMediation,
                            onApproveMediationResolution: onApproveMediationResolution,
                            onDeclineMediationResolution: onDeclineMediationResolution,
                            onLoadMediationMessages: onLoadMediationMessages,
                            onSendMediationMessage: onSendMediationMessage,
                            mediationRefreshToken: mediationRefreshToken
                        )
                        .id(item.id)
                    }
                }
                .padding()
            }
            .onChange(of: timeline.count) { _, _ in
                guard let last = timeline.last else { return }
                withAnimation {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
}

private struct TimelineRowView: View {
    let item: TimelineItem
    let currentUserId: String
    let currentUserRole: MemberRole?
    let memberDirectory: MemberDirectory
    let isSubmittingAction: Bool
    let onConfirm: (ConversationAction) -> Void
    let onDecline: (ConversationAction, String, String?) -> Void
    let onApproveAlternative: (ConversationAction) -> Void
    let onDeclineAlternative: (ConversationAction) -> Void
    let onRespondToMediation: (ConversationAction, String) -> Void
    let onResolveMediation: (ConversationAction, String) -> Void
    let onApproveMediationResolution: (ConversationAction) -> Void
    let onDeclineMediationResolution: (ConversationAction, String) -> Void
    let onLoadMediationMessages: (String) async -> [Message]
    let onSendMediationMessage: (String, String) async -> Message?
    let mediationRefreshToken: Int

    var body: some View {
        switch item {
        case .message(let message):
            MessageBubble(
                message: message,
                isMine: message.senderId == currentUserId,
                currentUserId: currentUserId,
                memberDirectory: memberDirectory
            )
        case .action(let action):
            switch action.actionType {
            case .confirmationRequest:
                ConfirmationRequestCard(
                    action: action,
                    currentUserId: currentUserId,
                    memberDirectory: memberDirectory,
                    isSubmitting: isSubmittingAction,
                    onConfirm: { onConfirm(action) },
                    onDecline: { reason, alternative in
                        onDecline(action, reason, alternative)
                    },
                    onApproveAlternative: { onApproveAlternative(action) },
                    onDeclineAlternative: { onDeclineAlternative(action) }
                )
            case .mediationRequest:
                MediationRequestCard(
                    action: action,
                    currentUserId: currentUserId,
                    currentUserRole: currentUserRole,
                    memberDirectory: memberDirectory,
                    isSubmitting: isSubmittingAction,
                    onLoadMessages: { await onLoadMediationMessages(action.id) },
                    onSendMessage: { body in await onSendMediationMessage(action.id, body) },
                    onRespond: { response in onRespondToMediation(action, response) },
                    onResolve: { resolution in onResolveMediation(action, resolution) },
                    onApproveResolution: { onApproveMediationResolution(action) },
                    onDeclineResolution: { reason in onDeclineMediationResolution(action, reason) },
                    mediationRefreshToken: mediationRefreshToken
                )
            }
        }
    }
}

private struct ChatComposerBar: View {
    @Binding var draft: String
    let canCreateActions: Bool
    let isSending: Bool
    let isSubmittingAction: Bool
    let onCreateAction: () -> Void
    let onSend: () -> Void

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 12) {
            if canCreateActions {
                Button(action: onCreateAction) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(CopareTheme.brand)
                }
                .disabled(isSubmittingAction)
            }

            TextField("Message", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(!canSend)
        }
        .padding()
    }
}

struct ConfirmationRequestCard: View {
    let action: ConversationAction
    let currentUserId: String
    let memberDirectory: MemberDirectory
    let isSubmitting: Bool
    let onConfirm: () -> Void
    let onDecline: (String, String?) -> Void
    let onApproveAlternative: () -> Void
    let onDeclineAlternative: () -> Void

    @State private var showDeclineSheet = false

    private var isAssignee: Bool {
        action.assignedTo == currentUserId
    }

    private var isCreator: Bool {
        action.createdBy == currentUserId
    }

    private var statusColor: Color {
        switch action.status {
        case .pending: CopareTheme.amber
        case .confirmed: CopareTheme.sage
        case .declined: .red
        case .alternativePending: CopareTheme.brand
        case .mediationInProgress, .parentApprovalPending: CopareTheme.brand
        }
    }

    var body: some View {
        CopareCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(CopareTheme.brand)
                    Text("Confirmation requested")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(action.status.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                Text("From \(action.creatorName(using: memberDirectory)) to \(action.assigneeName(using: memberDirectory))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if action.hasNegotiationHistory || action.status == .alternativePending {
                    ActionHistorySection(action: action)
                } else {
                    Text(action.statement)
                        .font(.body)
                }

                if action.status == .alternativePending, isCreator {
                    Text("Your co-parent proposed an alternative. Review it above and approve or decline.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if action.status == .pending, isAssignee {
                    HStack(spacing: 12) {
                        Button("Decline") {
                            showDeclineSheet = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSubmitting)

                        Button("Confirm") {
                            onConfirm()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CopareTheme.sage)
                        .disabled(isSubmitting)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if action.status == .alternativePending, isCreator {
                    HStack(spacing: 12) {
                        Button("Decline alternative") {
                            onDeclineAlternative()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSubmitting)

                        Button("Approve alternative") {
                            onApproveAlternative()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CopareTheme.sage)
                        .disabled(isSubmitting)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Text(action.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showDeclineSheet) {
            DeclineConfirmationView(isSubmitting: isSubmitting) { reason, alternative in
                onDecline(reason, alternative)
                showDeclineSheet = false
            }
        }
    }
}

private struct ActionHistorySection: View {
    let action: ConversationAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActionHistoryBlock(
                title: "Original request",
                text: action.statement
            )

            if let reason = action.responseNote.nilIfBlank {
                ActionHistoryBlock(
                    title: "Decline reason",
                    text: reason,
                    style: .secondary
                )
            }

            if let alternative = action.alternativeStatement.nilIfBlank {
                ActionHistoryBlock(
                    title: "Proposed alternative",
                    text: alternative
                )
            }

            if let accepted = action.acceptedStatement.nilIfBlank {
                ActionHistoryBlock(
                    title: "Confirmed statement",
                    text: accepted,
                    style: .confirmed
                )
            } else if action.status == .declined, action.alternativeStatement.nilIfBlank != nil {
                Text("Alternative declined")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct ActionHistoryBlock: View {
    enum Style {
        case normal
        case secondary
        case confirmed
    }

    let title: String
    let text: String
    var style: Style = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(labelColor)
            Text(text)
                .font(style == .secondary ? .footnote : .body)
                .foregroundStyle(textColor)
        }
    }

    private var labelColor: Color {
        switch style {
        case .confirmed: CopareTheme.sage
        case .normal, .secondary: .secondary
        }
    }

    private var textColor: Color {
        switch style {
        case .confirmed: .primary
        case .normal: .primary
        case .secondary: .secondary
        }
    }
}

struct MediationRequestCard: View {
    let action: ConversationAction
    let currentUserId: String
    let currentUserRole: MemberRole?
    let memberDirectory: MemberDirectory
    let isSubmitting: Bool
    let onLoadMessages: () async -> [Message]
    let onSendMessage: (String) async -> Message?
    let onRespond: (String) -> Void
    let onResolve: (String) -> Void
    let onApproveResolution: () -> Void
    let onDeclineResolution: (String) -> Void
    let mediationRefreshToken: Int

    @State private var showRespondSheet = false
    @State private var showResolveSheet = false
    @State private var showDeclineResolutionSheet = false
    @State private var mediationMessages: [Message] = []
    @State private var mediatorDraft = ""
    @State private var isSendingMediatorMessage = false

    private var isAssignee: Bool { action.assignedTo == currentUserId }
    private var isMediator: Bool { currentUserRole?.isMediator == true }
    private var isParent: Bool { currentUserRole?.isParent == true }

    private var statusColor: Color {
        switch action.status {
        case .pending: CopareTheme.amber
        case .mediationInProgress: CopareTheme.brand
        case .parentApprovalPending: CopareTheme.amber
        case .confirmed: CopareTheme.sage
        case .declined: .red
        default: CopareTheme.brand
        }
    }

    var body: some View {
        CopareCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "person.2.wave.2")
                        .foregroundStyle(CopareTheme.brand)
                    Text("Mediation requested")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(action.status.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                Text("From \(action.creatorName(using: memberDirectory)) to \(action.assigneeName(using: memberDirectory))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                MediationHistorySection(action: action)

                if action.status == .mediationInProgress || action.status == .parentApprovalPending || action.status == .confirmed {
                    MediationThreadSection(
                        messages: mediationMessages,
                        currentUserId: currentUserId,
                        memberDirectory: memberDirectory,
                        canPost: isMediator && action.status == .mediationInProgress,
                        draft: $mediatorDraft,
                        isSending: isSendingMediatorMessage,
                        onSend: sendMediatorMessage
                    )

                    if isMediator && action.status == .mediationInProgress {
                        Text("Your role is to help find a solution that works for everyone — not to take sides.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if action.status == .parentApprovalPending {
                    ParentApprovalStatusView(action: action)
                }

                if action.status == .pending, isAssignee {
                    Button("Respond to topic") {
                        showRespondSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CopareTheme.brand)
                    .disabled(isSubmitting)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if action.status == .mediationInProgress, isMediator {
                    Button("Propose resolution") {
                        showResolveSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CopareTheme.sage)
                    .disabled(isSubmitting)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if action.status == .parentApprovalPending, isParent,
                   !action.hasApprovedResolution(role: currentUserRole) {
                    HStack(spacing: 12) {
                        Button("Decline resolution") {
                            showDeclineResolutionSheet = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSubmitting)

                        Button("Approve resolution") {
                            onApproveResolution()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(CopareTheme.sage)
                        .disabled(isSubmitting)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                Text(action.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(action.mediatorThreadRootId ?? "")-\(mediationRefreshToken)") {
            guard action.mediatorThreadRootId != nil else { return }
            mediationMessages = await onLoadMessages()
        }
        .onChange(of: action.status) { _, _ in
            Task {
                guard action.mediatorThreadRootId != nil else { return }
                mediationMessages = await onLoadMessages()
            }
        }
        .sheet(isPresented: $showRespondSheet) {
            RespondToMediationView(isSubmitting: isSubmitting) { response in
                onRespond(response)
                showRespondSheet = false
            }
        }
        .sheet(isPresented: $showResolveSheet) {
            ResolveMediationView(isSubmitting: isSubmitting) { resolution in
                onResolve(resolution)
                showResolveSheet = false
            }
        }
        .sheet(isPresented: $showDeclineResolutionSheet) {
            DeclineMediationResolutionView(isSubmitting: isSubmitting) { reason in
                onDeclineResolution(reason)
                showDeclineResolutionSheet = false
            }
        }
    }

    private func sendMediatorMessage() {
        let text = mediatorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        isSendingMediatorMessage = true
        Task {
            if let message = await onSendMessage(text) {
                mediatorDraft = ""
                if !mediationMessages.contains(where: { $0.id == message.id }) {
                    mediationMessages.append(message)
                }
            }
            isSendingMediatorMessage = false
        }
    }
}

private struct MediationHistorySection: View {
    let action: ConversationAction

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActionHistoryBlock(title: "Topic for mediation", text: action.statement)

            if let response = action.responseNote.nilIfBlank {
                ActionHistoryBlock(title: "Co-parent's response", text: response)
            }

            if let resolution = action.resolutionText.nilIfBlank {
                ActionHistoryBlock(
                    title: "Proposed resolution",
                    text: resolution,
                    style: action.status == .confirmed ? .confirmed : .normal
                )
            }
        }
    }
}

private struct ParentApprovalStatusView: View {
    let action: ConversationAction

    var body: some View {
        HStack(spacing: 12) {
            approvalChip(label: MemberRole.parentA.label, approved: action.parentAApprovedAt != nil)
            approvalChip(label: MemberRole.parentB.label, approved: action.parentBApprovedAt != nil)
        }
    }

    private func approvalChip(label: String, approved: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: approved ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(approved ? CopareTheme.sage : .secondary)
            Text(label)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(.systemGray6), in: Capsule())
    }
}

private struct MediationThreadSection: View {
    let messages: [Message]
    let currentUserId: String
    let memberDirectory: MemberDirectory
    let canPost: Bool
    @Binding var draft: String
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mediator discussion")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if messages.isEmpty {
                Text("No mediator messages yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.senderName(using: memberDirectory))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(message.body)
                                .font(.footnote)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }

            if canPost {
                HStack(spacing: 8) {
                    TextField("Message…", text: $draft, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct RespondToMediationView: View {
    @Environment(\.dismiss) private var dismiss

    let isSubmitting: Bool
    let onRespond: (String) -> Void

    @State private var response = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your response to the topic", text: $response, axis: .vertical)
                        .lineLimit(4...8)
                } footer: {
                    Text("Share your perspective so mediators can help find a fair solution.")
                }
            }
            .navigationTitle("Respond to mediation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onRespond(response.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(isSubmitting || response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct ResolveMediationView: View {
    @Environment(\.dismiss) private var dismiss

    let isSubmitting: Bool
    let onResolve: (String) -> Void

    @State private var resolution = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Proposed resolution", text: $resolution, axis: .vertical)
                        .lineLimit(4...10)
                } footer: {
                    Text("Describe a solution that works for both parents. Both parents must approve before it is final.")
                }
            }
            .navigationTitle("Propose resolution")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onResolve(resolution.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(isSubmitting || resolution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct DeclineMediationResolutionView: View {
    @Environment(\.dismiss) private var dismiss

    let isSubmitting: Bool
    let onDecline: (String) -> Void

    @State private var reason = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reason for declining", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("Explain why this resolution does not work for you.")
                }
            }
            .navigationTitle("Decline resolution")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Decline") {
                        onDecline(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .disabled(isSubmitting || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct CreateMediationRequestView: View {
    let isSubmitting: Bool
    let onSubmit: (String) async -> Bool
    var onComplete: () -> Void = {}

    @State private var topic = ""

    var body: some View {
        ScrollView {
            VStack(spacing: CopareTheme.sectionSpacing) {
                CopareCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CopareSectionHeader(
                            title: "Mediation request",
                            subtitle: "Ask your co-parent to respond, then mediators will help resolve the issue."
                        )

                        TextEditor(text: $topic)
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                CoparePrimaryButton(
                    title: "Request mediation",
                    isLoading: isSubmitting,
                    isDisabled: topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task {
                        if await onSubmit(topic) {
                            onComplete()
                        }
                    }
                }
            }
            .padding(.horizontal, CopareTheme.horizontalPadding)
            .padding(.vertical, 16)
        }
        .copareScreenBackground()
        .navigationTitle("Mediation request")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ChatActionsFlowView: View {
    @Environment(\.dismiss) private var dismiss

    let isSubmitting: Bool
    let onCreateConfirmation: (String) async -> Bool
    let onCreateMediation: (String) async -> Bool

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ChatActionsMenuView { kind in
                path.append(kind)
            }
            .navigationTitle("Chat actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .navigationDestination(for: ChatActionKind.self) { kind in
                switch kind {
                case .confirmationRequest:
                    CreateConfirmationRequestView(
                        isSubmitting: isSubmitting,
                        onSubmit: onCreateConfirmation,
                        onComplete: { dismiss() }
                    )
                case .mediationRequest:
                    CreateMediationRequestView(
                        isSubmitting: isSubmitting,
                        onSubmit: onCreateMediation,
                        onComplete: { dismiss() }
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct ChatActionsMenuView: View {
    let onSelect: (ChatActionKind) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: CopareTheme.sectionSpacing) {
                CopareSectionHeader(
                    title: "Choose an action",
                    subtitle: "Structured actions help you and your co-parent agree on important decisions."
                )

                CopareCard {
                    VStack(spacing: 0) {
                        ForEach(Array(ChatActionKind.menuCases.enumerated()), id: \.element.id) { index, kind in
                            Button {
                                onSelect(kind)
                            } label: {
                                ChatActionMenuRow(kind: kind)
                            }
                            .buttonStyle(.plain)

                            if index < ChatActionKind.menuCases.count - 1 {
                                Divider()
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, CopareTheme.horizontalPadding)
            .padding(.vertical, 16)
        }
        .copareScreenBackground()
    }
}

private struct ChatActionMenuRow: View {
    let kind: ChatActionKind

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind.symbolName)
                .font(.title3)
                .foregroundStyle(CopareTheme.brand)
                .frame(width: 36, height: 36)
                .background(CopareTheme.brand.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(CopareTheme.textPrimary)
                Text(kind.subtitle)
                    .font(.caption)
                    .foregroundStyle(CopareTheme.textSecondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct CreateConfirmationRequestView: View {
    let isSubmitting: Bool
    let onSubmit: (String) async -> Bool
    var onComplete: () -> Void = {}

    @State private var statement = ""

    var body: some View {
        ScrollView {
            VStack(spacing: CopareTheme.sectionSpacing) {
                CopareCard {
                    VStack(alignment: .leading, spacing: 14) {
                        CopareSectionHeader(
                            title: "Confirmation request",
                            subtitle: "Ask your co-parent to officially confirm a statement."
                        )

                        TextEditor(text: $statement)
                            .frame(minHeight: 120)
                            .padding(8)
                            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                CoparePrimaryButton(
                    title: "Request confirmation",
                    isLoading: isSubmitting,
                    isDisabled: statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    Task {
                        if await onSubmit(statement) {
                            onComplete()
                        }
                    }
                }
            }
            .padding(.horizontal, CopareTheme.horizontalPadding)
            .padding(.vertical, 16)
        }
        .copareScreenBackground()
        .navigationTitle("Confirmation request")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DeclineConfirmationView: View {
    @Environment(\.dismiss) private var dismiss

    let isSubmitting: Bool
    let onDecline: (String, String?) -> Void

    @State private var reason = ""
    @State private var alternative = ""

    private var trimmedReason: String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedAlternative: String? {
        let value = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reason for declining", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                } footer: {
                    Text("Explain why you cannot confirm this statement. A reason is required.")
                }

                Section {
                    TextField("Alternative wording (optional)", text: $alternative, axis: .vertical)
                        .lineLimit(3...8)
                } footer: {
                    Text("Suggest different wording you would be willing to confirm.")
                }
            }
            .navigationTitle("Decline request")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Decline") {
                        onDecline(trimmedReason, trimmedAlternative)
                    }
                    .disabled(isSubmitting || trimmedReason.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct MessageBubble: View {
    let message: Message
    let isMine: Bool
    let currentUserId: String
    let memberDirectory: MemberDirectory

    @State private var showReadStatus = false

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                if !isMine {
                    Text(message.senderName(using: memberDirectory))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Text(message.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isMine ? Color.accentColor : Color(.systemGray5))
                    .foregroundStyle(isMine ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .onLongPressGesture(minimumDuration: 0.45) {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        showReadStatus = true
                    }

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !isMine { Spacer(minLength: 48) }
        }
        .sheet(isPresented: $showReadStatus) {
            MessageReadStatusSheet(
                message: message,
                currentUserId: currentUserId,
                memberDirectory: memberDirectory
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

struct MessageReadStatusSheet: View {
    @Environment(\.dismiss) private var dismiss

    let message: Message
    let currentUserId: String
    let memberDirectory: MemberDirectory

    private var receipts: [MessageReceipt] {
        message.receipts ?? []
    }

    private var readReceipts: [MessageReceipt] {
        receipts.filter { $0.readAt != nil }
            .sorted { ($0.readAt ?? .distantPast) < ($1.readAt ?? .distantPast) }
    }

    private var deliveredOnlyReceipts: [MessageReceipt] {
        receipts.filter { $0.deliveredAt != nil && $0.readAt == nil }
    }

    private var pendingReceipts: [MessageReceipt] {
        receipts.filter { $0.deliveredAt == nil && $0.readAt == nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CopareTheme.sectionSpacing) {
                    if receipts.isEmpty {
                        CopareCard {
                            Text("Read receipts are not available for this message yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        if !readReceipts.isEmpty {
                            receiptSection(
                                title: "Seen by",
                                systemImage: "eye.fill",
                                tint: CopareTheme.sage,
                                receipts: readReceipts,
                                dateKeyPath: \.readAt
                            )
                        }

                        if !deliveredOnlyReceipts.isEmpty {
                            receiptSection(
                                title: "Delivered to",
                                systemImage: "checkmark",
                                tint: CopareTheme.amber,
                                receipts: deliveredOnlyReceipts,
                                dateKeyPath: \.deliveredAt
                            )
                        }

                        if !pendingReceipts.isEmpty {
                            receiptSection(
                                title: "Not yet received",
                                systemImage: "clock",
                                tint: .secondary,
                                receipts: pendingReceipts,
                                dateKeyPath: nil
                            )
                        }
                    }
                }
                .padding(.horizontal, CopareTheme.horizontalPadding)
                .padding(.vertical, 16)
            }
            .copareScreenBackground()
            .navigationTitle("Message status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func receiptSection(
        title: String,
        systemImage: String,
        tint: Color,
        receipts: [MessageReceipt],
        dateKeyPath: KeyPath<MessageReceipt, Date?>?
    ) -> some View {
        CopareCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)

                ForEach(receipts, id: \.userId) { receipt in
                    HStack {
                        Text(label(for: receipt))
                            .font(.subheadline)
                        Spacer()
                        if let dateKeyPath, let date = receipt[keyPath: dateKeyPath] {
                            Text(date, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func label(for receipt: MessageReceipt) -> String {
        if receipt.userId == currentUserId { return "You" }
        let name = receipt.resolvedName(using: memberDirectory)
        if receipt.userId == message.senderId { return "\(name) (sender)" }
        return name
    }
}
