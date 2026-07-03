import SwiftUI

struct AuthFlowView: View {
    @State private var mode: AuthMode = .signIn

    enum AuthMode {
        case signIn
        case signUp
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    authHero

                    Group {
                        switch mode {
                        case .signIn:
                            SignInView(onSwitch: { mode = .signUp })
                        case .signUp:
                            SignUpView(onSwitch: { mode = .signIn })
                        }
                    }
                }
                .padding(.horizontal, CopareTheme.horizontalPadding)
                .padding(.bottom, 32)
            }
            .copareScreenBackground()
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var authHero: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 36))
                .foregroundStyle(CopareTheme.brand)
                .frame(width: 72, height: 72)
                .background(CopareTheme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))

            Text("Copare")
                .font(.largeTitle.weight(.bold))

            Text("Calm, mediated co-parenting conversations.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }
}

struct SignInView: View {
    @Environment(AppState.self) private var appState
    let onSwitch: () -> Void

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: CopareTheme.sectionSpacing) {
            CopareCard {
                VStack(spacing: 14) {
                    CopareSectionHeader(title: "Welcome back", subtitle: "Sign in to your groups")

                    CopareField(
                        title: "Email",
                        text: $email,
                        contentType: .emailAddress,
                        keyboard: .emailAddress,
                        autocapitalization: .never
                    )

                    CopareField(
                        title: "Password",
                        text: $password,
                        isSecure: true,
                        contentType: .password
                    )
                }
            }

            if let error = appState.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            CoparePrimaryButton(
                title: "Sign In",
                isLoading: appState.isLoading,
                isDisabled: email.isEmpty || password.isEmpty
            ) {
                Task { await appState.signIn(email: email, password: password) }
            }

            CopareSecondaryButton(title: "Create an account") {
                onSwitch()
            }
        }
    }
}

struct SignUpView: View {
    @Environment(AppState.self) private var appState
    let onSwitch: () -> Void

    @State private var name = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: CopareTheme.sectionSpacing) {
            CopareCard {
                VStack(spacing: 14) {
                    CopareSectionHeader(title: "Get started", subtitle: "Create your Copare account")

                    CopareField(
                        title: "Display name",
                        text: $name,
                        contentType: .name
                    )

                    CopareField(
                        title: "Email",
                        text: $email,
                        contentType: .emailAddress,
                        keyboard: .emailAddress,
                        autocapitalization: .never
                    )

                    CopareField(
                        title: "Password",
                        text: $password,
                        isSecure: true,
                        contentType: .newPassword
                    )
                }
            }

            if let error = appState.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            CoparePrimaryButton(
                title: "Sign Up",
                isLoading: appState.isLoading,
                isDisabled: name.isEmpty || email.isEmpty || password.isEmpty
            ) {
                Task { await appState.signUp(email: email, password: password, name: name) }
            }

            CopareSecondaryButton(title: "Already have an account?") {
                onSwitch()
            }
        }
    }
}
