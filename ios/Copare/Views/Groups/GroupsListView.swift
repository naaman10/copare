import SwiftUI

@MainActor
@Observable
final class GroupsViewModel {
    var groups: [CopareGroup] = []
    var recentConversations: [RecentConversation] = []
    var outstandingActions: [OutstandingAction] = []
    var isLoading = false
    var errorMessage: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            async let groupsTask = CopareAPI.shared.listGroups()
            async let recentTask = CopareAPI.shared.listRecentConversations()
            async let outstandingTask = CopareAPI.shared.listOutstandingActions()
            let (loadedGroups, loadedRecent, loadedOutstanding) = try await (
                groupsTask,
                recentTask,
                outstandingTask
            )
            groups = loadedGroups
            recentConversations = loadedRecent
            outstandingActions = loadedOutstanding
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func group(for id: String) -> CopareGroup? {
        groups.first { $0.id == id }
    }

    func role(forUserId userId: String, inGroupId groupId: String) -> MemberRole? {
        group(for: groupId)?.role(forUserId: userId)
    }

    func refreshHomeFeed() async {
        do {
            async let recentTask = CopareAPI.shared.listRecentConversations()
            async let outstandingTask = CopareAPI.shared.listOutstandingActions()
            let (loadedRecent, loadedOutstanding) = try await (recentTask, outstandingTask)
            recentConversations = loadedRecent
            outstandingActions = loadedOutstanding
        } catch {
            // Keep the last known feed if the refresh fails.
        }
    }

    func createGroup(displayName: String) async -> Bool {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            _ = try await CopareAPI.shared.createGroup(displayName: displayName)
            await load()
            return true
        } catch let error as CopareError {
            errorMessage = error.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct GroupsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = GroupsViewModel()
    @State private var showCreate = false

    private var currentUserId: String {
        appState.session?.user.id ?? ""
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: CopareTheme.sectionSpacing) {
                        if !viewModel.outstandingActions.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                CopareSectionHeader(
                                    title: "Your turn",
                                    subtitle: "Actions waiting for your response"
                                )

                                LazyVStack(spacing: 12) {
                                    ForEach(viewModel.outstandingActions) { outstanding in
                                        NavigationLink {
                                            if let group = viewModel.group(for: outstanding.action.groupId) {
                                                ChatView(
                                                    conversation: outstanding.conversation,
                                                    currentUserRole: viewModel.role(
                                                        forUserId: currentUserId,
                                                        inGroupId: outstanding.action.groupId
                                                    )
                                                )
                                            }
                                        } label: {
                                            OutstandingActionRow(outstanding: outstanding)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if !viewModel.recentConversations.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                CopareSectionHeader(
                                    title: "Recent conversations",
                                    subtitle: "Unread conversations appear first"
                                )

                                LazyVStack(spacing: 12) {
                                    ForEach(viewModel.recentConversations) { recent in
                                        NavigationLink {
                                            if let group = viewModel.group(for: recent.groupId) {
                                                ChatView(
                                                    conversation: recent.conversation,
                                                    currentUserRole: viewModel.role(
                                                        forUserId: currentUserId,
                                                        inGroupId: recent.groupId
                                                    )
                                                )
                                            }
                                        } label: {
                                            RecentConversationRow(recent: recent)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        CopareSectionHeader(
                            title: "Your groups",
                            subtitle: "Co-parenting spaces with mediators"
                        )

                        if viewModel.isLoading && viewModel.groups.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if viewModel.groups.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(viewModel.groups) { group in
                                    NavigationLink {
                                        GroupDetailView(group: group)
                                    } label: {
                                        GroupRow(group: group)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, CopareTheme.horizontalPadding)
                    .padding(.top, 8)
                    .padding(.bottom, 100)
                }
                .refreshable { await viewModel.load() }

                CopareFloatingButton(systemImage: "plus") {
                    showCreate = true
                }
                .padding(.trailing, CopareTheme.horizontalPadding)
                .padding(.bottom, 24)
            }
            .copareScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showCreate) {
                CreateGroupView(viewModel: viewModel)
            }
            .task(id: currentUserId) {
                guard !currentUserId.isEmpty else { return }
                await viewModel.load()
            }
            .onAppear {
                guard !currentUserId.isEmpty else { return }
                Task { await viewModel.refreshHomeFeed() }
            }
            .onReceive(appState.webSocket.$lastEvent) { event in
                guard let event else { return }
                if event.type == "message.new" || event.type == "action.new" || event.type == "action.updated" {
                    Task { await viewModel.refreshHomeFeed() }
                }
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var emptyState: some View {
        CopareCard {
            VStack(spacing: 12) {
                Image(systemName: "person.3.sequence")
                    .font(.title)
                    .foregroundStyle(CopareTheme.brand)
                Text("No groups yet")
                    .font(.headline)
                Text("Create a co-parenting group to invite your co-parent and mediators.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                CoparePrimaryButton(title: "Create Group") {
                    showCreate = true
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct OutstandingActionRow: View {
    let outstanding: OutstandingAction

    private var actionLabel: String {
        switch outstanding.action.actionType {
        case .confirmationRequest: "Confirmation request"
        case .mediationRequest: "Mediation request"
        }
    }

    private var symbolName: String {
        switch outstanding.action.actionType {
        case .confirmationRequest: "checkmark.seal"
        case .mediationRequest: "person.2.wave.2"
        }
    }

    var body: some View {
        CopareCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbolName)
                    .font(.title3)
                    .foregroundStyle(CopareTheme.amber)
                    .frame(width: 32, height: 32)
                    .background(CopareTheme.amber.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 6) {
                    Text(outstanding.conversationTitle)
                        .font(.headline)
                        .foregroundStyle(CopareTheme.textPrimary)

                    Text(actionLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CopareTheme.brand)

                    Text(outstanding.nextStep)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(outstanding.action.statement)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct RecentConversationRow: View {
    let recent: RecentConversation

    var body: some View {
        CopareCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recent.title)
                        .font(.headline)
                        .foregroundStyle(CopareTheme.textPrimary)

                    if let preview = recent.lastMessagePreview.nilIfBlank {
                        Text(preview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let lastMessageAt = recent.lastMessageAt {
                        Text(lastMessageAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if recent.hasUnread {
                    UnreadBadge(count: recent.unreadCount)
                }
            }
        }
    }
}

private struct UnreadBadge: View {
    let count: Int

    private var label: String {
        count > 99 ? "99+" : String(count)
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(CopareTheme.brand, in: Capsule())
            .accessibilityLabel("\(count) unread messages")
    }
}

struct GroupRow: View {
    let group: CopareGroup

    var body: some View {
        CopareCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Co-parenting group")
                        .font(.headline)
                    Text("\(group.memberList.count) of 4 members joined")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CopareStatusBadge(status: group.status)
            }
        }
    }
}

struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: GroupsViewModel

    @State private var displayName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CopareTheme.sectionSpacing) {
                    CopareCard {
                        VStack(alignment: .leading, spacing: 14) {
                            CopareSectionHeader(
                                title: "New group",
                                subtitle: "You'll join as Parent A"
                            )
                            CopareField(title: "Display name", text: $displayName, contentType: .name)
                            Text("Invite your co-parent and mediators once the group is created.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    CoparePrimaryButton(
                        title: "Create Group",
                        isLoading: viewModel.isLoading,
                        isDisabled: displayName.isEmpty
                    ) {
                        Task {
                            if await viewModel.createGroup(displayName: displayName) {
                                dismiss()
                            }
                        }
                    }
                }
                .padding(.horizontal, CopareTheme.horizontalPadding)
                .padding(.vertical, 16)
            }
            .copareScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
