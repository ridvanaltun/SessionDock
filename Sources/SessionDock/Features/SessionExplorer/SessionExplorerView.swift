import SessionDockCore
import SwiftUI

@MainActor
@Observable
final class SessionExplorerViewModel {
    struct Node: Identifiable, Hashable {
        var session: SessionSummary
        var children: [SessionSummary]
        var id: String { session.id }
    }

    struct Group: Identifiable, Hashable {
        var id: String
        var name: String
        var path: String
        var pathIsInferred: Bool
        var nodes: [Node]
        var sessionCount: Int
    }

    var query = "" {
        didSet { scheduleReload() }
    }
    var agentFilter: AgentKind? {
        didSet { Task { await reload() } }
    }
    var sort: SessionSort = .recentActivity {
        didSet { Task { await reload() } }
    }
    var showSubagents = true {
        didSet { Task { await reload() } }
    }
    var projectFilter: String? {
        didSet { Task { await reload() } }
    }

    private(set) var groups: [Group] = []
    private(set) var flatResults: [SessionSummary] = []
    private(set) var copiesInOpenCode: Set<String> = []
    private(set) var openCodeAvailable = false
    private(set) var projectNames: [String: String] = [:]
    private(set) var totalMatches = 0
    private(set) var loadError: String?
    private var reloadTask: Task<Void, Never>?
    private var services: AppServices?

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    func attach(_ services: AppServices, preferences: AppPreferences) async {
        if self.services == nil {
            showSubagents = preferences.showSubagentsInExplorer
        }
        self.services = services
        await loadCopies()
        await reload()
    }

    func reloadIfAttached() async {
        guard services != nil else { return }
        await loadCopies()
        await reload()
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    func reload() async {
        guard let services else { return }
        do {
            let matches = try services.index.sessions(SessionQuery(
                agent: agentFilter,
                projectId: projectFilter,
                text: query,
                includeSubagents: true,
                sort: sort,
                limit: 5_000
            ))
            totalMatches = showSubagents ? matches.count : matches.filter { !$0.isSubagent }.count
            projectNames = Dictionary(
                try services.index.projects().map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            )
            if isSearching {
                flatResults = showSubagents ? matches : matches.filter { !$0.isSubagent }
                groups = []
            } else {
                flatResults = []
                groups = Self.buildGroups(matches, showSubagents: showSubagents, projects: try services.index.projects())
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadCopies() async {
        guard let services else { return }
        let installation = (try? services.index.installations())?.first { $0.agent == .openCode }
        guard let path = installation?.storePath, installation?.status.isAvailable == true else {
            openCodeAvailable = false
            copiesInOpenCode = []
            return
        }
        openCodeAvailable = true
        let store = OpenCodeStore(databaseURL: URL(fileURLWithPath: path))
        copiesInOpenCode = Set((try? store.originMap().map(\.originId)) ?? [])
    }

    static func buildGroups(_ sessions: [SessionSummary], showSubagents: Bool, projects: [ProjectSummary]) -> [Group] {
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mains = sessions.filter { !$0.isSubagent }
        let children = Dictionary(grouping: sessions.filter(\.isSubagent)) { $0.parentSessionId ?? "" }
        let orphans = sessions.filter { $0.isSubagent && ($0.parentSessionId.map { id in !mains.contains { $0.id == id } } ?? true) }

        var byProject: [String: [Node]] = [:]
        for main in mains {
            let kids = showSubagents ? (children[main.id] ?? []) : []
            byProject[main.projectId, default: []].append(Node(session: main, children: kids))
        }
        if showSubagents {
            for orphan in orphans {
                byProject[orphan.projectId, default: []].append(Node(session: orphan, children: []))
            }
        }

        return byProject.map { projectId, nodes -> Group in
            let project = projectsByID[projectId]
            let path = nodes.first?.session.projectPath ?? project?.path ?? ""
            return Group(
                id: projectId,
                name: project?.name ?? URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                pathIsInferred: project?.pathIsInferred ?? false,
                nodes: nodes,
                sessionCount: nodes.count + nodes.reduce(0) { $0 + $1.children.count }
            )
        }
        .sorted { ($0.nodes.first?.session.updatedAt ?? .distantPast) > ($1.nodes.first?.session.updatedAt ?? .distantPast) }
    }
}

struct SessionExplorerView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model = SessionExplorerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Sessions", subtitle: subtitle) {
                filters
            }
            HSplitView {
                list
                    .frame(minWidth: 380, idealWidth: 430, maxWidth: 560)
                inspector
                    .frame(minWidth: 480, maxWidth: .infinity)
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search titles, projects and text")
        .task(id: app.indexRevision) {
            guard let services = app.services else { return }
            await model.attach(services, preferences: app.preferences)
        }
        .onChange(of: app.explorerProjectId) { _, value in
            // Clearing the request below triggers this handler again with nil, which must not clear the filter.
            guard let value else { return }
            model.projectFilter = value
            app.explorerProjectId = nil
        }
        .onAppear {
            if let project = app.explorerProjectId {
                model.projectFilter = project
                app.explorerProjectId = nil
            }
        }
    }

    private var subtitle: String {
        if let projectFilter = model.projectFilter {
            return "Filtered to \(model.projectNames[projectFilter] ?? "a project") · \(model.totalMatches) session(s)"
        }
        return "\(model.totalMatches) session(s) across Claude Code and OpenCode"
    }

    private var filters: some View {
        HStack(spacing: Theme.Spacing.s) {
            Picker("Agent", selection: $model.agentFilter) {
                Text("All agents").tag(AgentKind?.none)
                ForEach(AgentKind.allCases) { agent in
                    Text(agent.displayName).tag(AgentKind?.some(agent))
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Picker("Sort", selection: $model.sort) {
                ForEach(SessionSort.allCases) { sort in
                    Text(sort.label).tag(sort)
                }
            }
            .frame(width: 170)

            Toggle("Subagents", isOn: $model.showSubagents)
                .toggleStyle(.checkbox)

            if let projectFilter = model.projectFilter {
                Button {
                    model.projectFilter = nil
                } label: {
                    Label(model.projectNames[projectFilter] ?? "Project", systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear project filter")
            }
        }
    }

    private var list: some View {
        Group {
            if let error = model.loadError {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Could not load sessions", message: error)
            } else if app.services != nil, model.totalMatches == 0, !model.isSearching, app.isRefreshing {
                LoadingView(title: "Indexing sessions", detail: "Large transcripts take a moment on the first run.")
            } else if model.totalMatches == 0 {
                EmptyStateView(
                    symbol: model.isSearching ? "magnifyingglass" : "tray",
                    title: model.isSearching ? "No matches" : "No sessions found",
                    message: model.isSearching
                        ? "Try a different word, or search by project path."
                        : "SessionDock looks in ~/.claude/projects and the OpenCode database. Adjust locations in Settings if yours differ.",
                    action: model.isSearching ? nil : ("Open Settings", { app.route = .settings })
                )
            } else {
                sessionList
            }
        }
        .background(Theme.surface)
    }

    private var sessionList: some View {
        @Bindable var app = app
        return List(selection: $app.selectedSessionId) {
            if model.isSearching {
                ForEach(model.flatResults) { session in
                    row(session)
                        .tag(session.id)
                }
            } else {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.nodes) { node in
                            row(node.session)
                                .tag(node.session.id)
                            ForEach(node.children) { child in
                                row(child)
                                    .padding(.leading, Theme.Spacing.xl)
                                    .tag(child.id)
                            }
                        }
                    } header: {
                        projectHeader(group)
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("sessions.list")
    }

    private func projectHeader(_ group: SessionExplorerViewModel.Group) -> some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(group.name)
                .font(.subheadline.weight(.semibold))
            if group.pathIsInferred {
                StatusBadge(text: "path inferred", tone: .warning)
            }
            Spacer()
            Text("\(group.sessionCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(group.path)
    }

    private func row(_ session: SessionSummary) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            SessionRowContent(session: session, projectName: model.projectNames[session.projectId])
            if session.agent == .claudeCode, model.copiesInOpenCode.contains(session.originalId) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Theme.Tone.success.color)
                    .help("A copy exists in OpenCode")
            }
        }
        .padding(.vertical, 2)
    }

    private var inspector: some View {
        Group {
            if let id = app.selectedSessionId {
                SessionInspectorView(sessionId: id)
                    .id(id)
            } else {
                EmptyStateView(
                    symbol: "sidebar.right",
                    title: "Select a session",
                    message: "Its conversation, tool calls and subagent relationships appear here. Nothing in this view can run a tool."
                )
            }
        }
        .background(Theme.canvas)
    }
}
