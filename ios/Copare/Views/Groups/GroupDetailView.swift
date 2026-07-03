import SwiftUI

struct GroupDetailView: View {
    let group: CopareGroup

    @State private var showInvite = false
    @State private var invitationResult: Invitation?
    @State private var errorMessage: String?

    private var openRoles: [MemberRole] {
        let taken = Set(group.memberList.map(\.role))
        return MemberRole.allCases.filter { !taken.contains($0) && $0 != .parentA }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: CopareTheme.sectionSpacing) {
                CopareCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Group status")
                                .font(.headline)
                            Text("\(group.memberList.count) of 4 members")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        CopareStatusBadge(status: group.status)
                    }
                }

                CopareCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Members")
                            .font(.headline)
                        ForEach(group.memberList) { member in
                            CopareRoleChip(role: member.role)
                            if member.id != group.memberList.last?.id {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }

                if group.status == .active {
                    NavigationLink {
                        ConversationsListView(groupId: group.id)
                    } label: {
                        CopareCard {
                            HStack {
                                Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                                    .font(.headline)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    CopareCard {
                        Label {
                            Text("All four members must join before conversations can begin.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "hourglass")
                                .foregroundStyle(CopareTheme.amber)
                        }
                    }
                }

                if !openRoles.isEmpty {
                    CoparePrimaryButton(title: "Invite member") {
                        showInvite = true
                    }
                }

                if let invitation = invitationResult {
                    CopareCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Invitation token")
                                .font(.headline)
                            Text(invitation.token)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text("Share this token with the invitee until email delivery is built.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, CopareTheme.horizontalPadding)
            .padding(.vertical, 16)
        }
        .copareScreenBackground()
        .navigationTitle("Group")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showInvite) {
            InviteMemberView(groupId: group.id, roles: openRoles) { invitation in
                invitationResult = invitation
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

struct InviteMemberView: View {
    @Environment(\.dismiss) private var dismiss

    let groupId: String
    let roles: [MemberRole]
    let onCreated: (Invitation) -> Void

    @State private var email = ""
    @State private var role: MemberRole = .parentB
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CopareTheme.sectionSpacing) {
                    CopareCard {
                        VStack(alignment: .leading, spacing: 14) {
                            CopareSectionHeader(title: "Invite member")

                            Picker("Role", selection: $role) {
                                ForEach(roles, id: \.self) { role in
                                    Text(role.label).tag(role)
                                }
                            }
                            .pickerStyle(.menu)
                            .onAppear {
                                if let first = roles.first { role = first }
                            }

                            CopareField(
                                title: "Email",
                                text: $email,
                                contentType: .emailAddress,
                                keyboard: .emailAddress,
                                autocapitalization: .never
                            )
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    CoparePrimaryButton(
                        title: "Send invitation",
                        isLoading: isLoading,
                        isDisabled: email.isEmpty
                    ) {
                        Task { await sendInvite() }
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

    private func sendInvite() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let invitation = try await CopareAPI.shared.createInvitation(
                groupId: groupId,
                role: role,
                email: email
            )
            onCreated(invitation)
            dismiss()
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
