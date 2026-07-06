import SwiftUI

struct GroupDetailView: View {
    @Environment(AppState.self) private var appState

    let initialGroup: CopareGroup

    @State private var group: CopareGroup
    @State private var inviteRole: MemberRole?
    @State private var invitationResult: Invitation?
    @State private var errorMessage: String?

    init(group: CopareGroup) {
        initialGroup = group
        _group = State(initialValue: group)
    }

    private var currentUserRole: MemberRole? {
        guard let userId = appState.session?.user.id else { return nil }
        return group.role(forUserId: userId)
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

                VStack(alignment: .leading, spacing: 12) {
                    Text("Members")
                        .font(.headline)
                        .padding(.horizontal, 4)

                    ForEach(MemberRole.sides, id: \.parent) { side in
                        MemberSideCard(
                            side: side,
                            group: group,
                            currentUserRole: currentUserRole,
                            onInvite: { inviteRole = $0 }
                        )
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
        .task { await reloadGroup() }
        .refreshable { await reloadGroup() }
        .sheet(item: $inviteRole) { role in
            InviteMemberView(groupId: group.id, role: role) { invitation in
                invitationResult = invitation
                Task { await reloadGroup() }
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func reloadGroup() async {
        do {
            let groups = try await CopareAPI.shared.listGroups()
            if let updated = groups.first(where: { $0.id == initialGroup.id }) {
                group = updated
            }
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Member side (parent + mediator pair)

private struct MemberSideCard: View {
    let side: (parent: MemberRole, mediator: MemberRole)
    let group: CopareGroup
    let currentUserRole: MemberRole?
    let onInvite: (MemberRole) -> Void

    private var isYourSide: Bool {
        guard let currentUserRole else { return false }
        return currentUserRole == side.parent || currentUserRole.pairedMediator == side.parent
    }

    var body: some View {
        CopareCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(MemberRole.sideDisplayTitle(
                        parent: group.member(for: side.parent),
                        mediator: group.member(for: side.mediator),
                        fallback: side.parent
                    ))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if isYourSide {
                        Text("Your side")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(CopareTheme.brand)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(CopareTheme.brand.opacity(0.12), in: Capsule())
                    }
                }

                MemberSlotRow(
                    role: side.parent,
                    member: group.member(for: side.parent),
                    canInvite: canInvite(side.parent),
                    onInvite: { onInvite(side.parent) }
                )

                Divider().opacity(0.35)

                MemberSlotRow(
                    role: side.mediator,
                    member: group.member(for: side.mediator),
                    canInvite: canInvite(side.mediator),
                    onInvite: { onInvite(side.mediator) }
                )
            }
        }
    }

    private func canInvite(_ role: MemberRole) -> Bool {
        guard group.openRoles.contains(role),
              let currentUserRole else {
            return false
        }
        return currentUserRole.invitableRoles(openRoles: group.openRoles).contains(role)
    }
}

private struct MemberSlotRow: View {
    let role: MemberRole
    let member: GroupMember?
    let canInvite: Bool
    let onInvite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: role.isMediator ? "scale.3d" : "heart.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CopareTheme.brand)
                .frame(width: 28, height: 28)
                .background(CopareTheme.brand.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(member?.displayName ?? role.label)
                    .font(.subheadline.weight(.medium))
                Text(member == nil ? "Not yet joined" : role.label)
                    .font(.caption)
                    .foregroundStyle(member == nil ? CopareTheme.amber : .secondary)
            }

            Spacer()

            if canInvite {
                Button("Invite", action: onInvite)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(CopareTheme.brand)
            } else if member != nil {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(CopareTheme.sage)
            }
        }
    }
}

private extension MemberRole {
    var isMediator: Bool {
        self == .mediatorA || self == .mediatorB
    }
}

// MARK: - Invite sheet

struct InviteMemberView: View {
    @Environment(\.dismiss) private var dismiss

    let groupId: String
    let role: MemberRole
    let onCreated: (Invitation) -> Void

    @State private var email = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: CopareTheme.sectionSpacing) {
                    CopareCard {
                        VStack(alignment: .leading, spacing: 14) {
                            CopareSectionHeader(
                                title: "Invite \(role.label)",
                                subtitle: inviteSubtitle
                            )

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

    private var inviteSubtitle: String {
        switch role {
        case .parentB:
            "Invite your co-parent to join this group."
        case .mediatorA:
            "Only Parent A can invite Mediator A."
        case .mediatorB:
            "Only Parent B can invite Mediator B."
        default:
            "Send an invitation by email."
        }
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

extension MemberRole: Identifiable {
    var id: String { rawValue }
}
