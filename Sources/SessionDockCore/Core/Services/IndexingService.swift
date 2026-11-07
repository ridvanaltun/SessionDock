import Foundation

public struct AgentRegistry: Sendable {
    public let adapters: [any AgentAdapter]

    public init(adapters: [any AgentAdapter]) {
        self.adapters = adapters
    }

    public func adapter(for kind: AgentKind) -> (any AgentAdapter)? {
        adapters.first { $0.kind == kind }
    }
}

/// Refreshes the local index from every registered agent. Refreshes are serialised: a request that
/// arrives during a refresh joins the running one instead of starting a second scan.
public actor IndexingService {
    public struct AgentRefresh: Sendable, Hashable {
        public var agent: AgentKind
        public var installation: AgentInstallation
        public var sessionCount: Int
        public var filesScanned: Int
        public var filesReused: Int
        public var error: String?
    }

    public struct RefreshReport: Sendable {
        public var startedAt: Date
        public var finishedAt: Date
        public var agents: [AgentRefresh]

        public var totalSessions: Int { agents.reduce(0) { $0 + $1.sessionCount } }
    }

    private let registry: AgentRegistry
    private let index: IndexRepository
    private let preferences: PreferenceStore
    private var inFlight: Task<RefreshReport, Never>?

    public init(registry: AgentRegistry, index: IndexRepository, preferences: PreferenceStore) {
        self.registry = registry
        self.index = index
        self.preferences = preferences
    }

    public var isRefreshing: Bool { inFlight != nil }

    /// Refreshes every agent. Progress is reported per agent while its transcripts are scanned.
    public func refresh(progress: (@Sendable (AgentKind, ScanProgress) -> Void)? = nil) async -> RefreshReport {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.performRefresh(progress: progress) }
        inFlight = task
        let report = await task.value
        inFlight = nil
        return report
    }

    private func performRefresh(progress: (@Sendable (AgentKind, ScanProgress) -> Void)?) async -> RefreshReport {
        let started = Date()
        let overrides = (try? preferences.load())?.pathOverrides ?? PathOverrides()
        var results: [AgentRefresh] = []
        for adapter in registry.adapters {
            let kind = adapter.kind
            results.append(await refreshAgent(adapter, overrides: overrides, progress: progress.map { callback in
                { @Sendable (update: ScanProgress) in callback(kind, update) }
            }))
        }
        return RefreshReport(startedAt: started, finishedAt: Date(), agents: results)
    }

    private func refreshAgent(
        _ adapter: any AgentAdapter,
        overrides: PathOverrides,
        progress: (@Sendable (ScanProgress) -> Void)?
    ) async -> AgentRefresh {
        var installation = await adapter.discover(overrides: overrides)
        do {
            guard installation.status.isAvailable else {
                try index.replaceIndex(agent: adapter.kind, sessions: [], sourceStates: [])
                installation.sessionCount = 0
                installation.projectCount = 0
                try index.saveInstallations([installation])
                return AgentRefresh(agent: adapter.kind, installation: installation, sessionCount: 0, filesScanned: 0, filesReused: 0, error: nil)
            }

            let previous = try index.sourceStates(agent: adapter.kind)
            let outcome = try await adapter.scanner.scan(installation: installation, previousStates: previous, progress: progress)
            installation.sessionCount = outcome.sessions.count
            installation.projectCount = outcome.projects.count
            installation.scannedAt = Date()
            try index.replaceIndex(
                agent: adapter.kind,
                sessions: outcome.sessions,
                sourceStates: outcome.sourceStates
            )
            try index.saveInstallations([installation])
            AppLog.scanning.info("Indexed \(outcome.sessions.count, privacy: .public) \(adapter.kind.rawValue, privacy: .public) sessions, scanned \(outcome.filesScanned, privacy: .public) files, reused \(outcome.filesReused, privacy: .public)")
            return AgentRefresh(
                agent: adapter.kind,
                installation: installation,
                sessionCount: outcome.sessions.count,
                filesScanned: outcome.filesScanned,
                filesReused: outcome.filesReused,
                error: nil
            )
        } catch is CancellationError {
            return AgentRefresh(agent: adapter.kind, installation: installation, sessionCount: 0, filesScanned: 0, filesReused: 0, error: "Refresh cancelled")
        } catch {
            AppLog.scanning.error("Refresh failed for \(adapter.kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            installation.status = .unreadable(error.localizedDescription)
            installation.detail = "Scan failed: \(error.localizedDescription)"
            try? index.saveInstallations([installation])
            return AgentRefresh(agent: adapter.kind, installation: installation, sessionCount: 0, filesScanned: 0, filesReused: 0, error: error.localizedDescription)
        }
    }
}
