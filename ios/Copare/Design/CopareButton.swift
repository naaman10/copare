import SwiftUI

struct CoparePrimaryButton: View {
    let title: String
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                buttonCore.buttonStyle(.glassProminent).tint(CopareTheme.brand)
            } else {
                buttonCore.buttonStyle(.borderedProminent).tint(CopareTheme.brand)
            }
        }
    }

    private var buttonCore: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title).font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .disabled(isDisabled || isLoading)
    }
}

struct CopareSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(CopareTheme.brand)
    }
}

struct CopareFloatingButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                buttonCore.buttonStyle(.glass).tint(CopareTheme.brand)
            } else {
                buttonCore.buttonStyle(.bordered).tint(CopareTheme.brand)
            }
        }
    }

    private var buttonCore: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .frame(width: 52, height: 52)
        }
    }
}
