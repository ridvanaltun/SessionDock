import SessionDockCore
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    /// Every screen is laid out to fit this width, so that wide content never pushes the columns.
    static let detailMinWidth: CGFloat = 760

    var body: some View {
        Group {
            switch app.startup {
            case .loading:
                LoadingView(title: "Starting SessionDock", detail: "Opening the local index.")
            case .failed(let message):
                EmptyStateView(
                    symbol: "exclamationmark.triangle",
                    title: "SessionDock could not start",
                    message: message
                )
            case .ready:
                shell
            }
        }
        .background(Theme.canvas)
    }

    private var shell: some View {
        @Bindable var app = app
        return NavigationSplitView {
            List(selection: Binding<AppRoute?>(
                get: { app.route },
                set: { if let route = $0 { app.route = route } }
            )) {
                Section {
                    ForEach(AppRoute.allCases) { route in
                        Label(route.title, systemImage: route.symbol)
                            .tag(route)
                            .accessibilityIdentifier("sidebar.\(route.rawValue)")
                    }
                }
                Section("Agents") {
                    AgentSidebarStatus()
                    RefreshStatus()
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let banner = app.banner {
                    BannerView(banner: banner) { app.banner = nil }
                }
                detail(for: app.route)
                    .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .animation(.snappy(duration: 0.2), value: app.banner)
            .navigationSplitViewColumnWidth(min: Self.detailMinWidth, ideal: 1000)
        }
    }

    @ViewBuilder
    private func detail(for route: AppRoute) -> some View {
        switch route {
        case .dashboard: DashboardView()
        case .projects: ProjectsView()
        case .sessions: SessionExplorerView()
        case .migration: MigrationCenterView()
        case .context: ContextManagerView()
        case .settings: SettingsView()
        }
    }
}

private struct AgentSidebarStatus: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        ForEach(app.installations, id: \.agent) { installation in
            HStack(spacing: Theme.Spacing.s) {
                Circle()
                    .fill(installation.status.isAvailable ? Theme.Tone.success.color : Theme.Tone.neutral.color)
                    .frame(width: 7, height: 7)
                Text(installation.agent.displayName)
                Spacer()
                Text("\(installation.sessionCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .help(installation.detail)
        }
    }
}

/// Index state and the refresh action, as the last row of the Agents section.
private struct RefreshStatus: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if app.isRefreshing {
                ProgressView()
                    .controlSize(.mini)
                Text("Indexing…")
            } else {
                Text(app.lastRefresh.map { "Indexed \($0.formatted(.relative(presentation: .named)))" } ?? "Not indexed yet")
            }
            Spacer()
            Button {
                Task { await app.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(app.isRefreshing)
            .help("Refresh the index (⌘R)")
            .accessibilityLabel("Refresh")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, Theme.Spacing.xs)
    }
}

struct BannerView: View {
    let banner: AppEnvironment.Banner
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(tone.color)
            Text(banner.message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .background(tone.color.opacity(0.12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var tone: Theme.Tone {
        switch banner.tone {
        case .info: .info
        case .success: .success
        case .warning: .warning
        case .error: .error
        }
    }

    private var symbol: String {
        switch banner.tone {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}
