import SessionDockCore
import SwiftUI

@main
struct SessionDockApp: App {
    @State private var environment = AppEnvironment()

    init() {
        Self.forgetSidebarState()
    }

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

    /// AppKit saves the sidebar's width and collapsed state and restores them at launch, which
    /// overrides the layout: a sidebar hidden once came back hidden or narrow. The sidebar has a fixed
    /// width and is always shown, so the saved state is dropped before the window is created.
    private static func forgetSidebarState() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSSplitView Subview Frames") && key.contains("SidebarNavigationSplitView") {
            defaults.removeObject(forKey: key)
        }
    }
}
