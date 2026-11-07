import SessionDockCore
import SwiftUI

@MainActor
@Observable
final class MigrationCenterViewModel {
    enum Phase: Equatable {
        case idle
        case planning
        case planned
        case running(MigrationJobStatus)
        case finished
    }

    struct ProjectGroup: Identifiable, Hashable {
        var project: ProjectSummary
        var sessions: [SessionSummary]
        var children: [String: [SessionSummary]]
        var id: String { project.id }
    }

    // Source selection
    private(set) var groups: [ProjectGroup] = []
    var selectedIds: Set<String> = []
    private(set) var copiesInOpenCode: Set<String> = []

    // Backend and destination
    private(set) var writerStatus: WriterStatus?
    private(set) var destinationPath: String?
    private(set) var destinationStatus: InstallationStatus = .notFound
    private(set) var claudeRoot: String?
    private(set) var openCodeRunning: [String] = []

    // Plan, run and results
    private(set) var phase: Phase = .idle
    private(set) var plan: MigrationPlan?
    private(set) var report: MigrationReport?
    private(set) var verification: [MigrationValidationResult]?
    private(set) var errorMessage: String?

    // History
    private(set) var jobs: [MigrationJob] = []
    private(set) var backups: [BackupRecord] = []
    var selectedJobId: String?
    private(set) var selectedJobValidations: [MigrationValidationResult] = []
    private(set) var selectedJobMappings: [SessionMapping] = []

    var isBusy: Bool {
        switch phase {
        case .planning, .running: true
        default: false
        }
    }

    var canPlan: Bool { !selectedIds.isEmpty && !isBusy && destinationStatus.isAvailable }

    func load(_ services: AppServices) async {
        do {
            let installations = try services.index.installations()
            let openCode = installations.first { $0.agent == .openCode }
            destinationPath = openCode?.storePath
            destinationStatus = openCode?.status ?? .notFound
            claudeRoot = installations.first { $0.agent == .claudeCode }?.rootPath
            openCodeRunning = await OpenCodeProcessDetector.runningProcesses()
            if let destinationPath {
                writerStatus = try await services.engine.writerStatus(destination: URL(fileURLWithPath: destinationPath))
            } else {
                writerStatus = nil
            }
            let sessions = try services.index.sessions(SessionQuery(agent: .claudeCode, sort: .title, limit: 100_000))
            let projects = try services.index.projects(agent: .claudeCode)
            groups = Self.groups(sessions: sessions, projects: projects)
            if let destinationPath, destinationStatus.isAvailable {
                copiesInOpenCode = Set(try OpenCodeStore(databaseURL: URL(fileURLWithPath: destinationPath)).originMap().map(\.originId))
            } else {
                copiesInOpenCode = []
            }
            jobs = try services.migrations.jobs(limit: 100)
            backups = try services.migrations.backups(limit: 100)
            if let selectedJobId { await selectJob(selectedJobId, services) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func groups(sessions: [SessionSummary], projects: [ProjectSummary]) -> [ProjectGroup] {
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mains = sessions.filter { !$0.isSubagent }
        let children = Dictionary(grouping: sessions.filter(\.isSubagent)) { $0.parentSessionId ?? "" }
        return Dictionary(grouping: mains, by: \.projectId).compactMap { projectId, sessions -> ProjectGroup? in
            let project = projectsByID[projectId] ?? ProjectSummary(
                id: projectId,
                agent: .claudeCode,
                path: sessions.first?.projectPath ?? "",
                name: URL(fileURLWithPath: sessions.first?.projectPath ?? "").lastPathComponent
            )
            return ProjectGroup(
                project: project,
                sessions: sessions.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) },
                children: children.reduce(into: [:]) { result, pair in
                    if sessions.contains(where: { $0.id == pair.key }) { result[pair.key] = pair.value }
                }
            )
        }
        .sorted { ($0.project.lastActivityAt ?? .distantPast) > ($1.project.lastActivityAt ?? .distantPast) }
    }

    func toggle(_ id: String) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
        invalidatePlan()
    }

    func selectAll(in group: ProjectGroup, _ on: Bool) {
        var ids = group.sessions.map(\.id)
        ids += group.children.values.flatMap { $0.map(\.id) }
        if on { selectedIds.formUnion(ids) } else { selectedIds.subtract(ids) }
        invalidatePlan()
    }

    func invalidatePlan() {
        if case .planned = phase {
            plan = nil
            phase = .idle
        }
    }

    func makePlan(_ services: AppServices) async {
        guard let destinationPath else { return }
        phase = .planning
        errorMessage = nil
        verification = nil
        report = nil
        do {
            let selection = MigrationSelection(selectedSessionIds: Array(selectedIds))
            let plan = try await services.engine.plan(
                selection: selection,
                sourceRoot: claudeRoot ?? "",
                destination: URL(fileURLWithPath: destinationPath)
            )
            self.plan = plan
            openCodeRunning = await OpenCodeProcessDetector.runningProcesses()
            phase = .planned
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    func execute(_ services: AppServices) async {
        guard let plan, let destinationPath else { return }
        phase = .running(.backingUp)
        errorMessage = nil
        do {
            let result = try await services.engine.execute(
                plan: plan,
                destination: URL(fileURLWithPath: destinationPath),
                backupRoot: backupRoot(services)
            ) { [weak self] status in
                Task { @MainActor in self?.phase = .running(status) }
            }
            report = result
            phase = .finished
            selectedJobId = result.job.id
            await load(services)
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
            await load(services)
        }
    }

    func verifyExisting(_ services: AppServices) async {
        guard let destinationPath, !selectedIds.isEmpty else { return }
        phase = .planning
        errorMessage = nil
        do {
            verification = try await services.engine.verifyExisting(
                selection: MigrationSelection(selectedSessionIds: Array(selectedIds)),
                destination: URL(fileURLWithPath: destinationPath)
            )
            phase = .finished
        } catch {
            errorMessage = error.localizedDescription
            phase = .idle
        }
    }

    func selectJob(_ id: String, _ services: AppServices) async {
        selectedJobId = id
        selectedJobValidations = (try? await services.engine.validations(jobId: id)) ?? []
        selectedJobMappings = (try? await services.engine.mappings(jobId: id)) ?? []
    }

    func restore(backupId: String, _ services: AppServices) async -> MigrationJob? {
        guard let destinationPath else { return nil }
        do {
            let job = try await services.engine.restore(
                backupId: backupId,
                destination: URL(fileURLWithPath: destinationPath),
                backupRoot: backupRoot(services)
            )
            errorMessage = nil
            await load(services)
            return job
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func backupRoot(_ services: AppServices) -> URL {
        if let custom = (try? services.preferences.load())?.backupDirectory {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return services.paths.defaultBackups
    }
}
