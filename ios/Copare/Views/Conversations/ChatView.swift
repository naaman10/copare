import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    var messages: [Message] = []
    var draft = ""
    var isLoading = false
    var isSending = false
    var errorMessage: String?

    private let conversationId: String
    private let currentUserId: String

    init(conversationId: String, currentUserId: String) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            messages = try await CopareAPI.shared.listMessages(conversationId: conversationId)
            if let last = messages.last {
                try? await CopareAPI.shared.markRead(
                    conversationId: conversationId,
                    lastMessageId: last.id
                )
            }
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
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
            if !messages.contains(where: { $0.id == message.id }) {
                messages.append(message)
            }
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleWebSocketEvent(_ event: WSEvent?) {
        guard let event,
              event.type == "message.new",
              event.conversationId == conversationId,
              let message = event.message,
              message.senderId != currentUserId,
              !messages.contains(where: { $0.id == message.id }) else {
            return
        }
        messages.append(message)
        Task {
            try? await CopareAPI.shared.markDelivered(messageId: message.id)
            try? await CopareAPI.shared.markRead(
                conversationId: conversationId,
                lastMessageId: message.id
            )
        }
    }
}

struct ChatView: View {
    @Environment(AppState.self) private var appState
    let conversation: Conversation

    @State private var viewModel: ChatViewModel

    init(conversation: Conversation) {
        self.conversation = conversation
        _viewModel = State(initialValue: ChatViewModel(
            conversationId: conversation.id,
            currentUserId: ""
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubble(
                                message: message,
                                isMine: message.senderId == appState.session?.user.id
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let last = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                TextField("Message", text: $viewModel.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(viewModel.isSending || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if viewModel.isLoading && viewModel.messages.isEmpty {
                ProgressView()
            }
        }
        .onAppear {
            viewModel = ChatViewModel(
                conversationId: conversation.id,
                currentUserId: appState.session?.user.id ?? ""
            )
        }
        .task { await viewModel.load() }
        .onReceive(appState.webSocket.$lastEvent) { event in
            viewModel.handleWebSocketEvent(event)
        }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

struct MessageBubble: View {
    let message: Message
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }

            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isMine ? Color.accentColor : Color(.systemGray5))
                    .foregroundStyle(isMine ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !isMine { Spacer(minLength: 48) }
        }
    }
}
