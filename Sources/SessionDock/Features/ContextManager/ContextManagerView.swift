import SessionDockCore
import SwiftUI

@MainActor
@Observable
final class ContextManagerViewModel {
    private(set) var files: [ContextFile] = []
    private(set) var projects: [ProjectSummary] = []
    private(set) var preview: ContextPreview?
    private(set) var previewError: String?
    private(set) var copyResult: ContextCopyResult?
    private(set) var copyError: String?
    var selectedPath: String? {
        didSet { if selectedPath != oldValue { loadPreview() } }
    }
    private var services: AppServices?

    var selectedFile: ContextFile? { files.first { $0.path == selectedPath } }

    func load(_ services: AppServices) async {
        self.services = services
        projects = ((try? services.index.projects()) ?? []).filter { FileManager.default.fileExists(atPath: $0.path) }
        let claudeRoot = (try? services.index.installations())?.first { $0.agent == .claudeCode }?.rootPath
        files = services.context.discover(
            claudeCodeRoot: claudeRoot.map { URL(fileURLWithPath: $0, isDirectory: true) },
            projectPaths: projects.map(\.path)
        )
        if selectedPath == nil || !files.contains(where: { $0.path == selectedPath }) {
            selectedPath = files.first?.path
        } else {
            loadPreview()
        }
    }

    private func loadPreview() {
        preview = nil
        previewError = nil
        guard let services, let file = selectedFile else { return }
        do {
            preview = try services.context.preview(file)
        } catch {
            previewError = error.localizedDescription
        }
    }

    func copy(_ source: ContextFile, to project: ProjectSummary, named name: String, overwrite: Bool) async {
        guard let services else { return }
        copyError = nil
        copyResult = nil
        do {
            let destination = URL(fileURLWithPath: project.path).appending(path: name)
            copyResult = try services.context.copyInstruction(from: source, to: destination, overwrite: overwrite)
            await load(services)
        } catch {
            copyError = error.localizedDescription
        }
    }

    func clearCopyState() {
        copyResult = nil
        copyError = nil
    }
}

struct ContextManagerView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model = ContextManagerViewModel()
    @State private var showCopy = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Context", subtitle: "Instructions, memory and rules that shape your agents. Read-only; copying is explicit.")
            if model.files.isEmpty {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: "No context files found",
                    message: "SessionDock looks for CLAUDE.md, AGENTS.md, memory and rule files in ~/.claude, ~/.config/opencode and your projects."
                )
            } else {
                MasterDetail {
                    fileList
                } detail: {
                    previewPane
                }
            }
        }
        .task(id: app.indexRevision) {
            guard let services = app.services else { return }
            await model.load(services)
        }
        .sheet(isPresented: $showCopy) {
            if let file = model.selectedFile {
                CopySheet(source: file, projects: model.projects) { project, name, overwrite in
                    await model.copy(file, to: project, named: name, overwrite: overwrite)
                }
            }
        }
    }

    private var fileList: some View {
        List(selection: $model.selectedPath) {
            ForEach(groups, id: \.id) { group in
                Section(group.title) {
                    ForEach(group.files) { file in
                        HStack(spacing: Theme.Spacing.s) {
                            Image(systemName: symbol(for: file.kind))
                                .foregroundStyle(file.agent?.accent ?? Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.displayName)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(URL(fileURLWithPath: file.path).deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                            Spacer()
                            Text(ByteFormat.string(file.sizeBytes))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .tag(file.path)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private struct Group {
        /// Project folders can share a name, so sections are keyed by full path.
        var id: String
        var title: String
        var files: [ContextFile]
    }

    private var groups: [Group] {
        var result: [Group] = []
        let global = model.files.filter { $0.projectPath == nil && $0.kind != .memory }
        if !global.isEmpty { result.append(Group(id: "global", title: "Global", files: global)) }
        let memory = model.files.filter { $0.kind == .memory }
        if !memory.isEmpty { result.append(Group(id: "memory", title: "Memory", files: memory)) }
        let projectPaths = Set(model.files.compactMap(\.projectPath).filter { path in
            model.files.contains { $0.projectPath == path && $0.kind != .memory }
        }).sorted()
        for path in projectPaths {
            result.append(Group(
                id: "project:\(path)",
                title: URL(fileURLWithPath: path).lastPathComponent,
                files: model.files.filter { $0.projectPath == path && $0.kind != .memory }
            ))
        }
        return result
    }

    private func symbol(for kind: ContextKind) -> String {
        switch kind {
        case .instructions: "doc.text"
        case .memory: "brain"
        case .rule: "checklist"
        case .settings: "gearshape"
        case .configuration: "slider.horizontal.3"
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let file = model.selectedFile {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(file.displayName)
                        .font(.title3.weight(.semibold))
                    StatusBadge(text: file.kind.label, tone: .neutral)
                    if let agent = file.agent {
                        StatusBadge(text: agent.displayName, tone: .info)
                    }
                    Spacer()
                    if file.isCopyableInstruction {
                        Button {
                            model.clearCopyState()
                            showCopy = true
                        } label: {
                            Label("Copy to project…", systemImage: "doc.on.doc")
                        }
                    }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
                InfoRow(label: "Path", value: file.path, monospaced: true)
                if let copyResult = model.copyResult {
                    Label(
                        "Copied to \(copyResult.destination)." + (copyResult.previousVersionBackup.map { " The previous version is at \($0)." } ?? ""),
                        systemImage: "checkmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(Theme.Tone.success.color)
                }
                if let error = model.copyError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Theme.Tone.warning.color)
                }
                Divider()
                if let preview = model.preview, preview.isReadable {
                    ScrollView {
                        Text(preview.text)
                            .font(Theme.mono(12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if preview.truncated {
                        Text("Showing the first 200 KB.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(model.previewError ?? "This file is not UTF-8 text and cannot be previewed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyStateView(symbol: "doc", title: "Select a file", message: "Its contents are shown here. Nothing is edited.")
        }
    }
}

private struct CopySheet: View {
    let source: ContextFile
    let projects: [ProjectSummary]
    var onCopy: (ProjectSummary, String, Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var projectId: String?
    @State private var targetName = "AGENTS.md"
    @State private var overwrite = false
    @State private var working = false

    private var target: ProjectSummary? { projects.first { $0.id == projectId } }

    private var targetExists: Bool {
        guard let target else { return false }
        return FileManager.default.fileExists(atPath: URL(fileURLWithPath: target.path).appending(path: targetName).path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Copy \(source.displayName)")
                .font(.title3.weight(.semibold))
            Text("Copies the file's contents into a project. The source is not changed. Nothing is merged.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Project", selection: $projectId) {
                ForEach(projects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            Picker("File name", selection: $targetName) {
                Text("AGENTS.md").tag("AGENTS.md")
                Text("CLAUDE.md").tag("CLAUDE.md")
            }
            .pickerStyle(.segmented)

            if let target {
                InfoRow(label: "Destination", value: URL(fileURLWithPath: target.path).appending(path: targetName).path, monospaced: true)
            }

            if targetExists {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Label("\(targetName) already exists in this project.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Tone.warning.color)
                    Toggle("Replace it. The current file is kept as a timestamped backup first.", isOn: $overwrite)
                }
                .font(.callout)
                .card(padding: Theme.Spacing.m)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    guard let target else { return }
                    working = true
                    Task {
                        await onCopy(target, targetName, overwrite)
                        working = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(target == nil || (targetExists && !overwrite) || working)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 520)
        .onAppear {
            projectId = projects.first?.id
        }
    }
}
