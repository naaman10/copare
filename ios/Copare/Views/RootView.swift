import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if appState.isAuthenticated {
                MainTabView()
            } else {
                AuthFlowView()
            }
        }
        .animation(.easeInOut, value: appState.isAuthenticated)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            GroupsListView()
                .tabItem {
                    Label("Groups", systemImage: "person.3")
                }

            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
        }
        .tint(CopareTheme.brand)
    }
}
