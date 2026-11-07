import SessionDockCore
import SwiftUI

struct MigrationCenterView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model = MigrationCenterViewModel()
    @State private var panel: Panel = .plan
    @State private var confirmRun = false
    @State private var confirmRestore: BackupRecord?

    enum Panel: String, CaseIterable, Identifiable {
        case plan = "Plan"
        case history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Migration", subtitle: "Claude Code → OpenCode. Preview first, then back up, migrate and verify.") {
                pairSelector
            }
            HStack(alignment: .top, spacing: 0) {
                sourcePicker
                    .frame(width: 340)
                Divider()
                VStack(spacing: 0) {
                    Picker("Panel", selection: $panel) {
                        ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(Theme.Spacing.l)
                    ScrollView {
                        Group {
                            switch panel {
                            case .plan: planPanel
                            case .history: historyPanel
                            }
                        }
                        .padding([.horizontal, .bottom], Theme.Spacing.l)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .task(id: app.indexRevision) {
            guard let services = app.services else { return }
            await model.load(services)
        }
        .confirmationDialog(
            "Back up OpenCode and migrate \(model.plan?.sessionsToMigrate.count ?? 0) session(s)?",
            isPresented: $confirmRun,
            titleVisibility: .visible
        ) {
            Button("Back up and migrate") {
                guard let services = app.services else { return }
                Task {
                    await model.execute(services)
                    await app.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A verified backup of the OpenCode database is written first. Original Claude Code files are never modified. Results are checked against the database before anything is reported as successful.")
        }
        .confirmationDialog(
            "Restore this backup over the live OpenCode database?",
            isPresented: Binding(get: { confirmRestore != nil }, set: { if !$0 { confirmRestore = nil } }),
            titleVisibility: .visible,
            presenting: confirmRestore
        ) { backup in
            Button("Restore backup", role: .destructive) {
                guard let services = app.services else { return }
                Task {
                    if let job = await model.restore(backupId: backup.id, services) {
                        app.show(job.summary, tone: .success)
                        await app.refresh()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("Restores \(URL(fileURLWithPath: backup.backupPath).lastPathComponent) (\(backup.sessionCount) session rows). Quit OpenCode first; SessionDock refuses to restore while it runs. The current state is kept as a pre-restore backup.")
        }
    }

    // MARK: - Header

    private var pairSelector: some View {
        HStack(spacing: Theme.Spacing.s) {
            agentChip(.claudeCode, role: "Source")
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
            agentChip(.openCode, role: "Destination")
                .help("Claude Code to OpenCode is the only direction in this version. Other pairs are planned.")
        }
    }

    private func agentChip(_ agent: AgentKind, role: String) -> some View {
        HStack(spacing: 6) {
            AgentMark(agent: agent)
            VStack(alignment: .leading, spacing: 0) {
                Text(role)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(agent.displayName)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.surfaceStrong))
    }

    // MARK: - Source selection

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionTitle("Claude Code sessions")
                Spacer()
                Text("\(model.selectedIds.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.l)

            if model.groups.isEmpty {
                EmptyStateView(
                    symbol: "tray",
                    title: "No Claude Code sessions",
                    message: "Refresh after Claude Code has written a session under ~/.claude/projects."
                )
            } else {
                List {
                    ForEach(model.groups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                selectableRow(session)
                                ForEach(group.children[session.id] ?? []) { child in
                                    selectableRow(child, indent: true)
                                }
                            }
                        } header: {
                            HStack {
                                Text(group.project.name)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("All") { model.selectAll(in: group, true) }
                                Button("None") { model.selectAll(in: group, false) }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                }
                .listStyle(.inset)
            }

            Text("Subagents are migrated with their parent, so the set you see here is the set that gets written. A subagent selected alone also brings its parent.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(Theme.Spacing.l)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func selectableRow(_ session: SessionSummary, indent: Bool = false) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Toggle(isOn: Binding(
                get: { model.selectedIds.contains(session.id) },
                set: { _ in model.toggle(session.id) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)
                Text("\(session.messageCount) msgs · \(session.toolCallCount) tools")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.copiesInOpenCode.contains(session.originalId) {
                StatusBadge(text: "in OpenCode", tone: .success)
            }
        }
        .padding(.leading, indent ? Theme.Spacing.xl : 0)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(session.id) }
    }

    // MARK: - Plan

    private var planPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            backendCard
            switch model.phase {
            case .idle:
                actionsRow
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(Theme.Tone.error.color)
                }
                if let verification = model.verification {
                    verificationCard(verification)
                }
                if model.plan == nil && model.verification == nil {
                    EmptyStateView(
                        symbol: "list.bullet.rectangle",
                        title: "Preview before you write",
                        message: "Select sessions on the left, then preview. The preview runs against a snapshot of the OpenCode database and never writes to it."
                    )
                    .frame(height: 260)
                }
            case .planning:
                LoadingView(title: "Previewing", detail: "Reading the transcripts and building the rows in memory. The database is not written.")
                    .frame(height: 220)
            case .planned:
                if let plan = model.plan {
                    planCard(plan)
                }
            case .running(let status):
                runningCard(status)
            case .finished:
                if let report = model.report {
                    reportCard(report)
                } else if let verification = model.verification {
                    verificationCard(verification)
                }
                actionsRow
            }
        }
    }

    private var backendCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                SectionTitle("Writer and destination")
                Spacer()
                Button {
                    Task { await reload() }
                } label: {
                    Label("Check again", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            if let status = model.writerStatus {
                HStack(spacing: Theme.Spacing.s) {
                    StatusBadge(text: "Built-in writer \(status.writerVersion)", tone: status.isReady ? .success : .error)
                    StatusBadge(text: status.isReady ? "Schema ready" : "Schema not supported", tone: status.isReady ? .success : .error)
                }
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            InfoRow(label: "OpenCode DB", value: model.destinationPath ?? "Not found", monospaced: true)
            HStack(spacing: Theme.Spacing.s) {
                StatusBadge(text: model.destinationStatus.label, tone: model.destinationStatus.tone)
                if model.openCodeRunning.isEmpty {
                    StatusBadge(text: "OpenCode not running", tone: .success, symbol: "checkmark")
                } else {
                    StatusBadge(text: "OpenCode running", tone: .warning, symbol: "exclamationmark.triangle")
                }
            }
        }
        .card()
    }

    private var actionsRow: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                guard let services = app.services else { return }
                Task { await model.makePlan(services) }
            } label: {
                Label("Preview migration", systemImage: "eye")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canPlan)
            .keyboardShortcut(.return, modifiers: .command)

            Button {
                guard let services = app.services else { return }
                Task { await model.verifyExisting(services) }
            } label: {
                Label("Verify existing copies", systemImage: "checkmark.seal")
            }
            .disabled(model.selectedIds.isEmpty || model.isBusy)
            .help("Read-only. Checks copies that already exist in OpenCode against the transcripts.")

            Spacer()
        }
    }

    private func planCard(_ plan: MigrationPlan) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(spacing: Theme.Spacing.m) {
                planStat("To write", plan.sessionsToMigrate.count, .info)
                planStat("Already in OpenCode", plan.alreadyMigrated.count, .success)
                planStat("Subagents", plan.sessionsToMigrate.filter(\.isSubagent).count, .neutral)
            }

            if !plan.issues.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    ForEach(Array(plan.issues.enumerated()), id: \.offset) { _, issue in
                        Label {
                            Text(issue.message)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: issue.severity.symbol)
                                .foregroundStyle(issue.severity.tone.color)
                        }
                    }
                }
                .card()
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionTitle("Will write")
                ForEach(plan.sessionsToMigrate) { session in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: session.isSubagent ? "arrow.turn.down.right" : "bubble.left")
                            .foregroundStyle(.secondary)
                        Text(session.title)
                            .font(.callout)
                            .lineLimit(1)
                        if session.inclusionReason != .selected {
                            StatusBadge(text: session.inclusionReason == .requiredParent ? "parent" : "subagent", tone: .info)
                        }
                        Spacer()
                        Text("\(session.expectedMessageCount) msgs · \(session.expectedToolCallCount) tools")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !plan.alreadyMigrated.isEmpty {
                    Divider()
                    Text("Already in OpenCode, not touched")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(plan.alreadyMigrated) { existing in
                        HStack {
                            Text(existing.title).font(.callout).lineLimit(1)
                            Spacer()
                            Text("\(existing.targetMessageCount) rows in OpenCode")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .card()

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                SectionTitle("Rows to write")
                HStack(spacing: Theme.Spacing.m) {
                    rowStat("Sessions", plan.expected.sessions)
                    rowStat("Messages", plan.expected.messages)
                    rowStat("Parts", plan.expected.parts)
                    rowStat("Tool calls", plan.expected.toolCalls)
                    rowStat("Projects", plan.expected.projects)
                }
                if !plan.skipped.isEmpty {
                    Label("Not written, because OpenCode has no equivalent: " + plan.skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.Tone.warning.color)
                }
                InfoRow(label: "Source root", value: plan.sourceRoot, monospaced: true)
                InfoRow(label: "Destination", value: plan.destinationDatabase, monospaced: true)
                InfoRow(label: "Backup", value: "Verified online-backup copy in the backup folder, before any write. The write is one transaction.")
            }
            .card()

            HStack {
                Button("Discard preview") {
                    model.invalidatePlan()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    confirmRun = true
                } label: {
                    Label("Back up and migrate", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!plan.canExecute || model.isBusy)
                .help(plan.canExecute ? "Creates a backup, runs the migration and verifies it." : "Resolve the blockers above first.")
            }
        }
    }

    private func rowStat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.callout.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func planStat(_ title: String, _ value: Int, _ tone: Theme.Tone) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(tone.color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Theme.Spacing.m)
    }

    private func runningCard(_ status: MigrationJobStatus) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Migrating")
            ProgressView(value: progressValue(status))
            Text(status.label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Do not quit SessionDock until this finishes. The verification step decides what is reported as successful.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private func progressValue(_ status: MigrationJobStatus) -> Double {
        switch status {
        case .backingUp: 0.2
        case .migrating: 0.55
        case .verifying: 0.85
        default: 1
        }
    }

    private func reportCard(_ report: MigrationReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                SectionTitle("Result")
                Spacer()
                StatusBadge(text: report.job.status.label, tone: report.job.status.tone)
            }
            Text(report.job.summary)
                .font(.callout)
            if let backup = report.backup {
                InfoRow(label: "Backup", value: backup.backupPath, monospaced: true)
                InfoRow(label: "Backup check", value: "\(backup.integrityResult) · sha256 \(backup.sha256.prefix(12))…")
            }
            validationList(report.validations)
            mappingList(report.mappings)
            if report.job.status == .failedVerification, let backup = report.backup {
                Button("Restore backup…", role: .destructive) {
                    confirmRestore = backup
                }
                .help("Use this only if the verification failed and the migration result is not usable.")
            }
        }
        .card()
    }

    private func verificationCard(_ results: [MigrationValidationResult]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            SectionTitle("Verification of existing copies")
            Text("Read-only. Nothing was written.")
                .font(.caption)
                .foregroundStyle(.secondary)
            validationList(results)
        }
        .card()
    }

    private func validationList(_ results: [MigrationValidationResult]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(results) { result in
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : (result.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"))
                        .foregroundStyle(result.passed ? Theme.Tone.success.color : result.severity.tone.color)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(result.check)
                                .font(.caption.weight(.semibold))
                            StatusBadge(text: result.severity.rawValue, tone: result.severity.tone)
                        }
                        Text(result.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func mappingList(_ mappings: [SessionMapping]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Mappings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(mappings) { mapping in
                HStack {
                    Text(mapping.sourceSessionId)
                        .font(Theme.mono(11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Text(mapping.targetSessionId ?? "—")
                        .font(Theme.mono(11))
                        .lineLimit(1)
                    Spacer()
                    StatusBadge(text: mapping.status.rawValue, tone: mapping.status == .verified ? .success : .error)
                }
            }
        }
    }

    // MARK: - History

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            if model.jobs.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "No migrations yet", message: "Completed runs and their verification results appear here.")
                    .frame(height: 240)
            } else {
                ForEach(model.jobs) { job in
                    Button {
                        guard let services = app.services else { return }
                        Task { await model.selectJob(job.id, services) }
                    } label: {
                        HStack {
                            StatusBadge(text: job.status.label, tone: job.status.tone)
                            Text("\(job.sessionCount) session(s)")
                                .font(.callout)
                            Spacer()
                            Text(job.createdAt.shortRelative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(Theme.Spacing.s)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(model.selectedJobId == job.id ? Theme.surfaceStrong : Color.clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let jobId = model.selectedJobId, let job = model.jobs.first(where: { $0.id == jobId }) {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    SectionTitle("Run details")
                    Text(job.summary).font(.callout)
                    InfoRow(label: "Operation", value: job.operation.isEmpty ? "—" : job.operation)
                    InfoRow(label: "Writer", value: job.writerVersion ?? "—")
                    if !job.stderrExcerpt.isEmpty {
                        DisclosureGroup("Error details") {
                            Text(job.stderrExcerpt).font(Theme.mono(11)).textSelection(.enabled)
                        }
                    }
                    validationList(model.selectedJobValidations)
                    mappingList(model.selectedJobMappings)
                }
                .card()
            }

            SectionTitle("Backups")
            if model.backups.isEmpty {
                Text("No backups yet. A backup is created before every write.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.backups) { backup in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.callout)
                            Text(backup.backupPath)
                                .font(Theme.mono(10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteFormat.string(backup.sizeBytes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Restore…") { confirmRestore = backup }
                            .controlSize(.small)
                            .disabled(model.isBusy || backup.restoredAt != nil)
                    }
                    .card(padding: Theme.Spacing.m)
                }
            }
        }
    }

    private func reload() async {
        guard let services = app.services else { return }
        await model.load(services)
    }
}
