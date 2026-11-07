import AppKit
import SessionDockCore
import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    var draft = AppPreferences()
    private(set) var writerStatus: WriterStatus?
    private(set) var installations: [AgentInstallation] = []
    private(set) var backupBytes: Int64 = 0
    private(set) var backupCount = 0
    private(set) var savedMessage: String?

    func load(_ services: AppServices, current: AppPreferences) async {
        draft = current
        if let destination = (try? services.index.installations())?.first(where: { $0.agent == .openCode })?.storePath {
            writerStatus = try? await services.engine.writerStatus(destination: URL(fileURLWithPath: destination))
        }
        installations = (try? services.index.installations()) ?? []
        let backups = (try? services.migrations.backups(limit: 1_000)) ?? []
        backupCount = backups.count
        backupBytes = backups.reduce(0) { $0 + $1.sizeBytes }
    }

    var isDirty: Bool { draft != savedBaseline }
    private var savedBaseline = AppPreferences()

    func markSaved(_ preferences: AppPreferences) {
        savedBaseline = preferences
        savedMessage = "Saved"
    }

    func setBaseline(_ preferences: AppPreferences) {
        savedBaseline = preferences
    }
}

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model = SettingsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                ScreenHeader("Settings", subtitle: "Everything stays on this Mac. Changes take effect on the next refresh.") {
                    HStack {
                        if model.isDirty {
                            Text("Unsaved changes")
                                .font(.caption)
                                .foregroundStyle(Theme.Tone.warning.color)
                        }
                        Button("Revert") {
                            model.draft = app.preferences
                        }
                        .disabled(!model.isDirty)
                        Button("Save") {
                            if app.savePreferences(model.draft) {
                                model.setBaseline(model.draft)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isDirty)
                        .keyboardShortcut("s", modifiers: .command)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    discoverySection
                    scanningSection
                    storageSection
                    migrationBackendSection
                    appearanceSection
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
        .task {
            guard let services = app.services else { return }
            app.reloadPreferences()
            await model.load(services, current: app.preferences)
            model.setBaseline(app.preferences)
        }
    }

    // MARK: - Sections

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Agent locations")
            ForEach(model.installations, id: \.agent) { installation in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        AgentMark(agent: installation.agent)
                        Text(installation.agent.displayName).font(.callout.weight(.medium))
                        StatusBadge(text: installation.status.label, tone: installation.status.tone)
                        Spacer()
                        Text(installation.locationSource == .override ? "Manual path" : "Discovered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(installation.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
            pathField(
                title: "Claude Code home",
                placeholder: "~/.claude (leave empty to discover)",
                value: $model.draft.pathOverrides.claudeCodeRoot,
                chooseDirectories: true
            )
            pathField(
                title: "OpenCode database",
                placeholder: "~/.local/share/opencode/opencode.db (leave empty to discover)",
                value: $model.draft.pathOverrides.openCodeDatabase,
                chooseDirectories: false
            )
        }
        .card()
    }

    private var scanningSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Scanning")
            Toggle("Refresh automatically", isOn: $model.draft.autoScanEnabled)
            Stepper(value: $model.draft.scanIntervalMinutes, in: 1...120) {
                Text("Every \(model.draft.scanIntervalMinutes) minute(s)")
            }
            .disabled(!model.draft.autoScanEnabled)
            Text("Unchanged transcripts are skipped. Only appended lines are read for files that grew. The first scan of a large history takes longer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Storage")
            InfoRow(label: "Index database", value: app.services?.paths.indexDatabase.path ?? "—", monospaced: true)
            HStack {
                InfoRow(label: "Backups", value: model.draft.backupDirectory ?? (app.services?.paths.defaultBackups.path ?? "—"), monospaced: true)
                Spacer()
                Button("Choose…") { chooseBackupFolder() }
                if model.draft.backupDirectory != nil {
                    Button("Use default") { model.draft.backupDirectory = nil }
                }
            }
            Stepper(value: $model.draft.backupRetentionCount, in: 1...100) {
                Text("Keep the newest \(model.draft.backupRetentionCount) backup(s)")
            }
            InfoRow(label: "Current backups", value: "\(model.backupCount) · \(ByteFormat.string(model.backupBytes))")
            Text("Indexed metadata lives in the local database. Conversation text is read from the original files on demand.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var migrationBackendSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("OpenCode writer")
            Text("Migration is built into SessionDock. It needs no other tool installed. It writes OpenCode's legacy session tables in a single transaction, after a verified backup.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let status = model.writerStatus {
                HStack(spacing: Theme.Spacing.s) {
                    StatusBadge(text: "Writer v\(status.writerVersion)", tone: .success)
                    StatusBadge(text: status.isReady ? "Schema ready" : "Schema not supported", tone: status.isReady ? .success : .error)
                }
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Appearance and logging")
            Picker("Theme", selection: $model.draft.theme) {
                ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Show subagents in the session list", isOn: $model.draft.showSubagentsInExplorer)
            Text("Logs go to the macOS unified log under dev.sessiondock. They never contain conversation text. Use Console to choose which levels are shown.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: - Helpers

    private func pathField(title: String, placeholder: String, value: Binding<String?>, chooseDirectories: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.callout)
                .frame(width: 170, alignment: .leading)
            TextField(placeholder, text: Binding(
                get: { value.wrappedValue ?? "" },
                set: { value.wrappedValue = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(Theme.mono(11))
            Button("Choose…") {
                if let url = Self.pick(directories: chooseDirectories) {
                    value.wrappedValue = url.path
                }
            }
        }
    }

    private func chooseBackupFolder() {
        if let url = Self.pick(directories: true) {
            model.draft.backupDirectory = url.path
        }
    }

    @MainActor
    private static func pick(directories: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = directories
        return panel.runModal() == .OK ? panel.url : nil
    }
}
