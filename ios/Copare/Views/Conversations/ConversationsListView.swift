import SwiftUI

@MainActor
@Observable
final class ConversationsViewModel {
    var conversations: [Conversation] = []
    var isLoading = false
    var errorMessage: String?

    func load(groupId: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            conversations = try await CopareAPI.shared.listConversations(groupId: groupId)
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(groupId: String, title: String) async -> Bool {
        do {
            _ = try await CopareAPI.shared.createConversation(groupId: groupId, title: title)
            await load(groupId: groupId)
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

struct ConversationsListView: View {
    let groupId: String
    let currentUserRole: MemberRole?

    @State private var viewModel = ConversationsViewModel()
    @State private var showCreate = false

    init(
        groupId: String,
        currentUserRole: MemberRole? = nil
    ) {
        self.groupId = groupId
        self.currentUserRole = currentUserRole
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.conversations.isEmpty {
                ProgressView()
            } else if viewModel.conversations.isEmpty {
                ContentUnavailableView {
                    Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("New Conversation") { showCreate = true }
                }
            } else {
                List(viewModel.conversations) { conversation in
                    NavigationLink {
                        ChatView(
                            conversation: conversation,
                            currentUserRole: currentUserRole
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(conversation.title)
                                .font(.headline)
                            if let lastMessageAt = conversation.lastMessageAt {
                                Text(lastMessageAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .refreshable { await viewModel.load(groupId: groupId) }
            }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateConversationView(groupId: groupId, viewModel: viewModel)
        }
        .task { await viewModel.load(groupId: groupId) }
    }
}

struct CreateConversationView: View {
    @Environment(\.dismiss) private var dismiss
    let groupId: String
    @Bindable var viewModel: ConversationsViewModel

    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
            }
            .navigationTitle("New Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            if await viewModel.create(groupId: groupId, title: title) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
