import SwiftUI

@main
struct PaxIDXApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ProjectsView()
                    .tabItem {
                        Label("專案", systemImage: "folder")
                    }
                SettingsView()
                    .tabItem {
                        Label("設定", systemImage: "gearshape")
                    }
            }
        }
    }
}
