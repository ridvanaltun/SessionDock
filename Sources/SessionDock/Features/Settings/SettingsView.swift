import AppKit
import SessionDockCore
import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    private(set) var writerStatus: WriterStatus?
    private(set) var backupBytes: Int64 = 0
    private(set) var backupCount = 0

    func load(_ services: AppServices) async {
        if let destination = (try? services.index.installations())?.first(where: { $0.agent == .openCode })?.storePath {
            writerStatus = try? await services.engine.writerStatus(destination: URL(fileURLWithPath: destination))
        } else {
            writerStatus = nil
        }
        let totals = (try? services.migrations.backupTotals()) ?? (count: 0, sizeBytes: 0)
        backupCount = totals.count
        backupBytes = totals.sizeBytes
    }
}

/// Every change is saved and applied at once, as in System Settings.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model = SettingsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Settings", subtitle: "Changes are saved and applied immediately. Everything stays on this Mac.")
            Form {
                locationsSection
                scanningSection
                backupsSection
                appearanceSection
                writerSection
                aboutSection
            }
            .formStyle(.grouped)
        }
        .task(id: app.indexRevision) {
            guard let services = app.services else { return }
            await model.load(services)
        }
    }

    /// A binding into one preference that saves the whole set on every change.
    private func preference<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(
            get: { app.preferences[keyPath: keyPath] },
            set: { value in
                var updated = app.preferences
                updated[keyPath: keyPath] = value
                app.savePreferences(updated)
            }
        )
    }

    // MARK: - Sections

    private var locationsSection: some View {
        Section {
            ForEach(app.installations, id: \.agent) { installation in
                LabeledContent {
                    StatusBadge(text: installation.status.label, tone: installation.status.tone)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(installation.agent.displayName)
                            Text(installation.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    } icon: {
                        AgentMark(agent: installation.agent)
                    }
                }
            }
            PathField(
                title: "Claude Code home",
                placeholder: "~/.claude",
                value: preference(\.pathOverrides.claudeCodeRoot),
                chooseDirectories: true
            )
            PathField(
                title: "OpenCode database",
                placeholder: "~/.local/share/opencode/opencode.db",
                value: preference(\.pathOverrides.openCodeDatabase),
                chooseDirectories: false
            )
        } header: {
            Text("Agent locations")
        } footer: {
            Text("Leave a field empty to find the agent automatically. A new location is scanned as soon as it is set.")
        }
    }

    private var scanningSection: some View {
        Section("Scanning") {
            Toggle("Refresh automatically", isOn: preference(\.autoScanEnabled))
            Stepper("Every \(app.preferences.scanIntervalMinutes) minute(s)", value: preference(\.scanIntervalMinutes), in: 1...120)
            .disabled(!app.preferences.autoScanEnabled)
            Toggle("Show subagents in the session list", isOn: preference(\.showSubagentsInExplorer))
        }
    }

    private var backupsSection: some View {
        Section {
            LabeledContent("Folder") {
                HStack {
                    Text(app.preferences.backupDirectory ?? (app.services?.paths.defaultBackups.path ?? "—"))
                        .font(Theme.mono(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                    if app.preferences.backupDirectory != nil {
                        Button("Use Default") { preference(\.backupDirectory).wrappedValue = nil }
                    }
                    Button("Choose…") {
                        if let url = Self.pick(directories: true) {
                            preference(\.backupDirectory).wrappedValue = url.path
                        }
                    }
                }
            }
            Stepper("Keep the newest \(app.preferences.backupRetentionCount)", value: preference(\.backupRetentionCount), in: 1...100)
            LabeledContent("Current backups", value: "\(model.backupCount) · \(ByteFormat.string(model.backupBytes))")
        } header: {
            Text("Backups")
        } footer: {
            Text("A verified copy of the OpenCode database is made before every migration. Older copies beyond the limit are removed.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: preference(\.theme)) {
                ForEach(ThemePreference.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var writerSection: some View {
        Section {
            if let status = model.writerStatus {
                LabeledContent("Writer", value: status.writerVersion)
                LabeledContent("Destination schema") {
                    StatusBadge(text: status.isReady ? "Ready" : "Not supported", tone: status.isReady ? .success : .error)
                }
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No OpenCode database found yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("OpenCode writer")
        } footer: {
            Text("Migration is built in and needs no other tool. It writes in a single transaction, after a verified backup.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: SessionDockVersion.current)
            LabeledContent("Index database") {
                Text(app.services?.paths.indexDatabase.path ?? "—")
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }
        }
    }

    @MainActor
    static func pick(directories: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = directories
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// A path that is saved when editing ends (Return or leaving the field), not on every keystroke,
/// because each saved location starts a scan.
private struct PathField: View {
    let title: String
    let placeholder: String
    @Binding var value: String?
    let chooseDirectories: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $text, prompt: Text(placeholder))
                    .labelsHidden()
                    .font(Theme.mono(11))
                    .focused($focused)
                    .onSubmit(commit)
                Button("Choose…") {
                    if let url = SettingsView.pick(directories: chooseDirectories) {
                        text = url.path
                        commit()
                    }
                }
            }
        }
        .onAppear { text = value ?? "" }
        .onChange(of: value) { _, newValue in
            if !focused { text = newValue ?? "" }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newValue: String? = trimmed.isEmpty ? nil : trimmed
        if newValue != value { value = newValue }
    }
}
