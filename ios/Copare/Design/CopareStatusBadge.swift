import SwiftUI

struct CopareStatusBadge: View {
    let status: GroupStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private var tint: Color {
        switch status {
        case .forming: CopareTheme.amber
        case .active: CopareTheme.sage
        case .archived: .gray
        }
    }
}

struct CopareRoleChip: View {
    let member: GroupMember

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(CopareTheme.brand)
                .frame(width: 28, height: 28)
                .background(CopareTheme.brand.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(.subheadline.weight(.medium))
                Text(member.role.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var icon: String {
        switch member.role {
        case .parentA, .parentB: "heart.fill"
        case .mediatorA, .mediatorB: "scale.3d"
        }
    }
}
