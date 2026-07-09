import SwiftUI

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var inviteToken = ""
    @State private var acceptDisplayName = ""
    @State private var profileDisplayName: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CopareTheme.sectionSpacing) {
                    if let user = appState.session?.user {
                        CopareCard {
                            VStack(alignment: .leading, spacing: 12) {
                                CopareSectionHeader(title: "Account")
                                LabeledContent("Name", value: profileDisplayName ?? user.name ?? "—")
                                LabeledContent("Email", value: user.email)
                            }
                        }
                    }

                    CopareCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Connection")
                                .font(.headline)
                            connectionStatus
                        }
                    }

                    CopareCard {
                        VStack(alignment: .leading, spacing: 14) {
                            CopareSectionHeader(
                                title: "Accept invitation",
                                subtitle: "Paste a token from an invite"
                            )
                            CopareField(
                                title: "Invitation token",
                                text: $inviteToken,
                                autocapitalization: .never
                            )
                            CopareField(
                                title: "Display name",
                                text: $acceptDisplayName,
                                contentType: .name
                            )
                            CoparePrimaryButton(
                                title: "Accept",
                                isDisabled: inviteToken.isEmpty || acceptDisplayName.isEmpty
                            ) {
                                Task { await acceptInvitation() }
                            }
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        appState.signOut()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                }
                .padding(.horizontal, CopareTheme.horizontalPadding)
                .padding(.vertical, 16)
            }
            .copareScreenBackground()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .task {
                await loadProfileDisplayName()
                if acceptDisplayName.isEmpty, let name = appState.session?.user.name?.nilIfBlank {
                    acceptDisplayName = name
                }
            }
        }
    }

    private func loadProfileDisplayName() async {
        do {
            profileDisplayName = try await CopareAPI.shared.fetchProfile()
        } catch {
            profileDisplayName = nil
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch appState.webSocket.state {
        case .connected:
            Label("Connected", systemImage: "circle.fill")
                .foregroundStyle(CopareTheme.sage)
        case .connecting:
            Label("Connecting…", systemImage: "circle.dotted")
                .foregroundStyle(CopareTheme.amber)
        case .disconnected:
            Label("Disconnected", systemImage: "circle")
                .foregroundStyle(.secondary)
        }
    }

    private func acceptInvitation() async {
        let name = acceptDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            _ = try await CopareAPI.shared.acceptInvitation(token: inviteToken, displayName: name)
            inviteToken = ""
            acceptDisplayName = ""
            await loadProfileDisplayName()
        } catch let error as CopareError {
            appState.errorMessage = error.errorDescription
        } catch {
            appState.errorMessage = error.localizedDescription
        }
    }
}
