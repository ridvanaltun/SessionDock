import SessionDockCore
import SwiftUI

@main
struct SessionDockApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .frame(minWidth: 1080, minHeight: 680)
                .task { await environment.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
        .commands {
            AppCommands(environment: environment)
        }
    }
}
