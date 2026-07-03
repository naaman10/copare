import SwiftUI

/// Warm Fundio-style canvas that shows through Liquid Glass surfaces.
struct CopareBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [CopareTheme.canvasTopDark, CopareTheme.canvasBottomDark]
                    : [CopareTheme.canvasTop, CopareTheme.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(CopareTheme.brand.opacity(colorScheme == .dark ? 0.12 : 0.18))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: -120, y: -220)

            Circle()
                .fill(CopareTheme.sage.opacity(colorScheme == .dark ? 0.08 : 0.14))
                .frame(width: 240, height: 240)
                .blur(radius: 50)
                .offset(x: 140, y: 320)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func copareScreenBackground() -> some View {
        background {
            CopareBackground()
        }
    }
}
