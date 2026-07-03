import SwiftUI

@MainActor
@Observable
final class GroupsViewModel {
    var groups: [CopareGroup] = []
    var isLoading = false
    var errorMessage: String?

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            groups = try await CopareAPI.shared.listGroups()
        } catch let error as CopareError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
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
    @State private var viewModel = GroupsViewModel()
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: CopareTheme.sectionSpacing) {
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
            .task { await viewModel.load() }
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
