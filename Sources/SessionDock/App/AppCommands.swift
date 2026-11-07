import SwiftUI

struct AppCommands: Commands {
    let environment: AppEnvironment

    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(AppRoute.allCases) { route in
                Button(route.title) {
                    environment.route = route
                }
                .keyboardShortcut(KeyEquivalent(route.shortcutKey), modifiers: .command)
            }
            Divider()
            Button("Find Sessions") {
                environment.route = .sessions
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button("Refresh Index") {
                Task { await environment.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(environment.isRefreshing)
        }
    }
}
