import SwiftUI

enum CopareGlass {
    @ViewBuilder
    static func surface<Content: View>(
        cornerRadius: CGFloat = CopareTheme.cardRadius,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if #available(iOS 26.0, *) {
            content()
                .glassEffect(
                    .regular.tint(CopareTheme.brand.opacity(0.06)),
                    in: .rect(cornerRadius: cornerRadius)
                )
        } else {
            content()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

struct CopareCard<Content: View>: View {
    var cornerRadius: CGFloat = CopareTheme.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        CopareGlass.surface(cornerRadius: cornerRadius) {
            content
                .padding(CopareTheme.sectionSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CopareSectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(CopareTheme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(CopareTheme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
