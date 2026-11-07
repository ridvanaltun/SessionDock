import AppKit
import SessionDockCore
import SwiftUI

@MainActor
@Observable
final class ProjectsViewModel {
    private(set) var projects: [ProjectSummary] = []
    private(set) var selectedProjectSessions: [SessionSummary] = []
    private(set) var contextFiles: [ContextFile] = []
    var selectedId: String? {
        didSet { if selectedId != oldValue { Task { await loadSelection() } } }
    }
    private var services: AppServices?

    func load(_ services: AppServices) async {
        self.services = services
        projects = (try? services.index.projects()) ?? []
        if selectedId == nil || !projects.contains(where: { $0.id == selectedId }) {
            selectedId = projects.first?.id
        } else {
            await loadSelection()
        }
    }

    private func loadSelection() async {
        guard let services, let id = selectedId, let project = projects.first(where: { $0.id == id }) else {
            selectedProjectSessions = []
            contextFiles = []
            return
        }
        selectedProjectSessions = (try? services.index.sessions(SessionQuery(projectId: id, sort: .recentActivity, limit: 25))) ?? []
        contextFiles = services.context.discover(
            claudeCodeRoot: nil,
            projectPaths: [project.path]
        ).filter { $0.projectPath == project.path }
    }

    var selectedProject: ProjectSummary? { projects.first { $0.id == selectedId } }
}

struct ProjectsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model = ProjectsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Projects", subtitle: "Working directories that hold sessions, grouped by the path each session recorded.")
            if model.projects.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.questionmark",
                    title: "No projects yet",
                    message: "Projects appear after SessionDock has indexed at least one session."
                )
            } else {
                HSplitView {
                    List(selection: $model.selectedId) {
                        ForEach(model.projects) { project in
                            ProjectRow(project: project).tag(project.id)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)

                    detail
                        .frame(minWidth: 460, maxWidth: .infinity)
                }
            }
        }
        .task(id: app.indexRevision) {
            guard let services = app.services else { return }
            await model.load(services)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let project = model.selectedProject {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    HStack(alignment: .firstTextBaseline) {
                        ForEach(project.agents, id: \.self) { AgentMark(agent: $0) }
                        Text(project.name)
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Button {
                            app.openProject(project.id)
                        } label: {
                            Label("Show in Sessions", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        InfoRow(label: "Path", value: project.path, monospaced: true)
                        InfoRow(label: "Sessions", value: "\(project.sessionCount) main · \(project.subagentCount) subagents")
                        if let activity = project.lastActivityAt {
                            InfoRow(label: "Last activity", value: activity.formatted(date: .abbreviated, time: .shortened))
                        }
                    }
                    .card()

                    if project.pathIsInferred {
                        Label("This path was reconstructed from the directory name because no working directory was recorded. Verify it before relying on it.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(Theme.Tone.warning.color)
                            .card()
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionTitle("Recent sessions")
                        ForEach(model.selectedProjectSessions) { session in
                            Button {
                                app.openSession(session.id)
                            } label: {
                                SessionRowContent(session: session)
                                    .padding(.vertical, 4)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.4)
                        }
                    }
                    .card()

                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        HStack {
                            SectionTitle("Context files")
                            Spacer()
                            Button("Open Context") { app.route = .context }
                                .controlSize(.small)
                        }
                        if model.contextFiles.isEmpty {
                            Text("No CLAUDE.md, AGENTS.md or rule files in this project.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.contextFiles) { file in
                                Label(file.displayName, systemImage: "doc.text")
                                    .font(.callout)
                            }
                        }
                    }
                    .card()

                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: project.path))
                    } label: {
                        Label("Open in Finder", systemImage: "folder")
                    }
                    .disabled(!FileManager.default.fileExists(atPath: project.path))
                }
                .padding(Theme.Spacing.xl)
            }
        } else {
            EmptyStateView(symbol: "folder", title: "Select a project", message: "Its sessions and context files appear here.")
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    ForEach(project.agents, id: \.self) { AgentMark(agent: $0) }
                    if project.pathIsInferred {
                        Image(systemName: "questionmark.circle")
                            .foregroundStyle(Theme.Tone.warning.color)
                            .help("Path inferred from the directory name")
                    }
                }
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            Text("\(project.sessionCount + project.subagentCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
