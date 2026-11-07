import SessionDockCore
import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var app

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
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .safeAreaInset(edge: .bottom) {
                RefreshFooter()
            }
        } detail: {
            VStack(spacing: 0) {
                if let banner = app.banner {
                    BannerView(banner: banner) { app.banner = nil }
                }
                detail(for: app.route)
            }
            .animation(.snappy(duration: 0.2), value: app.banner)
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

private struct RefreshFooter: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if app.isRefreshing {
                let fraction = app.refreshProgress.values.map(\.fraction)
                ProgressView(value: fraction.isEmpty ? 0 : fraction.reduce(0, +) / Double(fraction.count))
                    .controlSize(.small)
                Text("Indexing sessions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let last = app.lastRefresh {
                Text("Indexed \(last.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await app.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(app.isRefreshing)
            .controlSize(.small)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
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
