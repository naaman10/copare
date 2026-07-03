import SwiftUI

struct CopareField: View {
    let title: String
    @Binding var text: String
    var isSecure = false
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(CopareTheme.textSecondary)

            Group {
                if isSecure {
                    SecureField("", text: $text)
                        .textContentType(contentType)
                } else {
                    TextField("", text: $text)
                        .textContentType(contentType)
                        .keyboardType(keyboard)
                        .textInputAutocapitalization(autocapitalization)
                        .autocorrectionDisabled(keyboard == .emailAddress)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(fieldBackground)
        }
    }

    @ViewBuilder
    private var fieldBackground: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: CopareTheme.fieldRadius)
                .fill(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: CopareTheme.fieldRadius))
        } else {
            RoundedRectangle(cornerRadius: CopareTheme.fieldRadius)
                .fill(.ultraThinMaterial)
        }
    }
}
