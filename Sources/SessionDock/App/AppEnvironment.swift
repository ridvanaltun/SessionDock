import Observation
import SessionDockCore
import SwiftUI

enum AppRoute: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case projects
    case sessions
    case migration
    case context
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .projects: "Projects"
        case .sessions: "Sessions"
        case .migration: "Migration"
        case .context: "Context"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .projects: "folder"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .migration: "arrow.triangle.swap"
        case .context: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        }
    }

    var shortcutKey: Character {
        switch self {
        case .dashboard: "1"
        case .projects: "2"
        case .sessions: "3"
        case .migration: "4"
        case .context: "5"
        case .settings: "6"
        }
    }
}

/// Everything the features need. Created once at launch and passed down through the environment.
struct AppServices: Sendable {
    let environment: HostEnvironment
    let paths: AppPaths
    let database: AppDatabase
    let index: IndexRepository
    let migrations: MigrationRepository
    let preferences: PreferenceStore
    let registry: AgentRegistry
    let indexing: IndexingService
    let engine: MigrationEngine
    let context: ContextService
}

@MainActor
@Observable
final class AppEnvironment {
    enum Startup: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var startup: Startup = .loading
    private(set) var services: AppServices?
    var route: AppRoute = .dashboard

    /// Session selected in the explorer, so that dashboard and migration screens can link to it.
    var selectedSessionId: String?
    /// Project to filter the explorer by, set when navigating from Projects.
    var explorerProjectId: String?

    private(set) var installations: [AgentInstallation] = []
    private(set) var isRefreshing = false
    private(set) var refreshProgress: [AgentKind: ScanProgress] = [:]
    private(set) var lastRefresh: Date?
    /// Bumped whenever the index changes, so that screens can reload.
    private(set) var indexRevision = 0
    var banner: Banner?
    private(set) var preferences = AppPreferences()

    private var autoScanTask: Task<Void, Never>?

    struct Banner: Equatable, Identifiable {
        enum Tone: Equatable { case info, success, warning, error }
        let id = UUID()
        var tone: Tone
        var message: String

        static func == (lhs: Banner, rhs: Banner) -> Bool { lhs.id == rhs.id }
    }

    func bootstrap() async {
        guard services == nil else { return }
        do {
            let environment = HostEnvironment.current
            let paths = AppPaths.standard(in: environment)
            let database = try AppDatabase.open(paths: paths)
            let index = IndexRepository(database: database)
            let migrations = MigrationRepository(database: database)
            let preferenceStore = PreferenceStore(database: database)
            let registry = AgentRegistry(adapters: [
                ClaudeCodeAdapter(environment: environment),
                OpenCodeAdapter(environment: environment),
            ])
            let indexing = IndexingService(registry: registry, index: index, preferences: preferenceStore)
            let engine = MigrationEngine(
                environment: environment,
                paths: paths,
                index: index,
                migrations: migrations,
                preferences: preferenceStore
            )
            let services = AppServices(
                environment: environment,
                paths: paths,
                database: database,
                index: index,
                migrations: migrations,
                preferences: preferenceStore,
                registry: registry,
                indexing: indexing,
                engine: engine,
                context: ContextService(environment: environment)
            )
            self.services = services
            self.preferences = try preferenceStore.load()
            startup = .ready
            await refresh()
            startAutoScan()
        } catch {
            AppLog.database.error("Startup failed: \(error.localizedDescription, privacy: .public)")
            startup = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        guard let services, !isRefreshing else { return }
        isRefreshing = true
        refreshProgress = [:]
        let report = await services.indexing.refresh { [weak self] agent, progress in
            Task { @MainActor in self?.refreshProgress[agent] = progress }
        }
        isRefreshing = false
        lastRefresh = report.finishedAt
        installations = (try? services.index.installations()) ?? []
        indexRevision += 1
        let failures = report.agents.compactMap { agent -> String? in
            guard let error = agent.error else { return nil }
            return "\(agent.agent.displayName): \(error)"
        }
        if !failures.isEmpty {
            banner = Banner(tone: .warning, message: "Some sources could not be scanned. " + failures.joined(separator: " "))
        }
    }

    func reloadPreferences() {
        guard let services else { return }
        preferences = (try? services.preferences.load()) ?? AppPreferences()
    }

    func savePreferences(_ updated: AppPreferences) {
        guard let services else { return }
        do {
            try services.preferences.save(updated)
            preferences = updated
            startAutoScan()
        } catch {
            banner = Banner(tone: .error, message: "Preferences could not be saved: \(error.localizedDescription)")
        }
    }

    func show(_ message: String, tone: Banner.Tone = .info) {
        banner = Banner(tone: tone, message: message)
    }

    func openSession(_ id: String) {
        selectedSessionId = id
        route = .sessions
    }

    func openProject(_ id: String) {
        explorerProjectId = id
        route = .sessions
    }

    private func startAutoScan() {
        autoScanTask?.cancel()
        guard preferences.autoScanEnabled else { return }
        let minutes = max(1, preferences.scanIntervalMinutes)
        autoScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }
}
