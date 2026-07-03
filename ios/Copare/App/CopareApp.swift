import SwiftUI

@main
struct CopareApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .tint(CopareTheme.brand)
        }
    }
}
