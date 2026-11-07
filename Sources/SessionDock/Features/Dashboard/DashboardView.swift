import SessionDockCore
import SwiftUI

@MainActor
@Observable
final class DashboardViewModel {
    var installations: [AgentInstallation] = []
    var counts = IndexCounts.empty
    var recentSessions: [SessionSummary] = []
    var recentJobs: [MigrationJob] = []
    var jobCount = 0
    var backupCount = 0
    var totalBackupBytes: Int64 = 0
    var projectCount = 0
    var loadError: String?

    func load(_ services: AppServices) async {
        do {
            installations = try services.index.installations()
            counts = try services.index.counts()
            recentSessions = try services.index.sessions(SessionQuery(sort: .recentActivity, limit: 8))
            recentJobs = try services.migrations.jobs(limit: 5)
            jobCount = try services.migrations.jobCount()
            (backupCount, totalBackupBytes) = try services.migrations.backupTotals()
            projectCount = try services.index.projects().count
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    var lastJob: MigrationJob? { recentJobs.first }
    var failedRecently: Int { recentJobs.filter { $0.status == .failed || $0.status == .failedVerification }.count }
}

struct DashboardView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model = DashboardViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ScreenHeader("Dashboard", subtitle: "Your coding agents, sessions and migrations on this Mac.")

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Spacing.m)], spacing: Theme.Spacing.m) {
                    MetricCard(title: "Sessions", value: "\(model.counts.sessions)", symbol: "bubble.left.and.bubble.right",
                               detail: "\(model.counts.mainSessions) main · \(model.counts.subagents) subagents")
                    MetricCard(title: "Projects", value: "\(model.projectCount)", symbol: "folder",
                               detail: "Grouped by working directory")
                    MetricCard(title: "Migrations", value: "\(model.jobCount)", symbol: "arrow.triangle.swap",
                               detail: model.lastJob.map { "Last: \($0.status.label.lowercased())" } ?? "None yet")
                    MetricCard(title: "Backups", value: "\(model.backupCount)", symbol: "externaldrive.badge.timemachine",
                               detail: ByteFormat.string(model.totalBackupBytes))
                }
                .padding(.horizontal, Theme.Spacing.xl)

                SectionTitle("Agents")
                    .padding(.horizontal, Theme.Spacing.xl)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: Theme.Spacing.m)], spacing: Theme.Spacing.m) {
                    ForEach(model.installations, id: \.agent) { installation in
                        AgentCard(installation: installation)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)

                HStack(alignment: .top, spacing: Theme.Spacing.l) {
                    recentSessions
                    VStack(spacing: Theme.Spacing.l) {
                        migrationHealth
                        recentMigrations
                    }
                    .frame(width: 380)
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
        .task(id: app.indexRevision) {
            guard let services = app.services else { return }
            await model.load(services)
        }
        .overlay {
            if app.startup == .ready, model.installations.isEmpty, app.isRefreshing {
                LoadingView(title: "Discovering agents", detail: "Looking for Claude Code and OpenCode.")
            }
        }
    }

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Recent sessions")
            if model.recentSessions.isEmpty {
                EmptyStateView(
                    symbol: "tray",
                    title: "No sessions indexed yet",
                    message: "Refresh to scan Claude Code and OpenCode on this Mac."
                )
                .frame(height: 220)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recentSessions) { session in
                        Button {
                            app.openSession(session.id)
                        } label: {
                            SessionRowContent(session: session)
                                .padding(.vertical, Theme.Spacing.s)
                                .padding(.horizontal, Theme.Spacing.m)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().opacity(0.5)
                    }
                }
                .card(padding: Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var migrationHealth: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Migration health")
            if let job = model.lastJob {
                HStack {
                    StatusBadge(text: job.status.label, tone: job.status.tone, symbol: nil)
                    Spacer()
                    Text(job.createdAt.shortRelative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(job.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.failedRecently > 0 {
                    Label("\(model.failedRecently) recent migration(s) did not verify. Open Migration to review them.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.Tone.warning.color)
                }
            } else {
                Text("No migrations have run from SessionDock yet. Preview a migration in the Migration Center first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var recentMigrations: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Recent migrations")
            if model.recentJobs.isEmpty {
                Text("Nothing yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.recentJobs) { job in
                    HStack(alignment: .firstTextBaseline) {
                        StatusBadge(text: job.status.label, tone: job.status.tone)
                        Text("\(job.sessionCount) session(s)")
                            .font(.callout)
                        Spacer()
                        Text(job.createdAt.shortRelative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card()
    }
}

struct AgentCard: View {
    let installation: AgentInstallation

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                AgentMark(agent: installation.agent)
                    .font(.title3)
                Text(installation.agent.displayName)
                    .font(.headline)
                Spacer()
                StatusBadge(text: installation.status.label, tone: installation.status.tone)
            }
            Text(installation.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: Theme.Spacing.l) {
                Label("\(installation.sessionCount) sessions", systemImage: "bubble.left")
                Label("\(installation.projectCount) projects", systemImage: "folder")
                if let version = installation.version {
                    Label(version, systemImage: "tag")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let schema = installation.schemaSummary {
                Text("Schema: \(schema)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .unreadable(let reason) = installation.status {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Theme.Tone.error.color)
            }
        }
        .card()
    }
}

/// Shared row layout for session lists.
struct SessionRowContent: View {
    let session: SessionSummary
    var projectName: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AgentMark(agent: session.agent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.s) {
                    if session.isSubagent {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Subagent")
                    }
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Text(projectName ?? URL(fileURLWithPath: session.projectPath).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.s)
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.updatedAt?.shortRelative ?? "—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(session.messageCount) msgs")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
