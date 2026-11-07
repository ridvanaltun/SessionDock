import AppKit
import SessionDockCore
import SwiftUI

struct SessionInspectorView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var model: SessionInspectorViewModel
    @State private var showDetails = false

    init(sessionId: String) {
        _model = State(initialValue: SessionInspectorViewModel(sessionId: sessionId))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.session {
                header(session)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        if !model.issues.isEmpty {
                            issuesBanner
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { _, message in
                            MessageView(message: message)
                        }
                        if model.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                        } else if model.nextOffset != nil {
                            Button("Load more messages") {
                                Task { await loadMore() }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        } else if !model.messages.isEmpty {
                            Text("End of transcript · \(model.messages.count) message(s) shown")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        if let error = model.error {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(Theme.Tone.error.color)
                        }
                    }
                    .padding(Theme.Spacing.l)
                }
            } else if let error = model.error {
                EmptyStateView(symbol: "exclamationmark.triangle", title: "Session unavailable", message: error)
            } else {
                LoadingView(title: "Opening session")
            }
        }
        .task {
            guard let services = app.services else { return }
            await model.load(services)
        }
    }

    private func loadMore() async {
        guard let services = app.services else { return }
        await model.loadNextPage(services)
    }

    private func header(_ session: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                AgentMark(agent: session.agent)
                Text(session.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Button {
                    if let path = session.sourcePath {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .disabled(session.sourcePath == nil)
                .help("Show the source file in Finder. SessionDock never writes to it.")
            }

            HStack(spacing: Theme.Spacing.s) {
                if session.isSubagent {
                    StatusBadge(text: "Subagent" + (session.subagentType.map { " · \($0)" } ?? ""), tone: .info, symbol: "arrow.turn.down.right")
                }
                if session.agent == .claudeCode {
                    StatusBadge(
                        text: model.hasCopyInOpenCode ? "Copy in OpenCode" : "Not in OpenCode",
                        tone: model.hasCopyInOpenCode ? .success : .neutral,
                        symbol: model.hasCopyInOpenCode ? "checkmark.seal" : "circle.dashed"
                    )
                }
                if let modelName = session.model {
                    StatusBadge(text: modelName, tone: .neutral)
                }
                StatusBadge(text: "Read-only · historical", tone: .neutral, symbol: "lock")
                Spacer()
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                InfoRow(label: "Project", value: session.projectPath, monospaced: true)
                InfoRow(label: "Session ID", value: session.originalId, monospaced: true)
                if let created = session.createdAt, let updated = session.updatedAt {
                    InfoRow(label: "Activity", value: "\(created.formatted(date: .abbreviated, time: .shortened)) → \(updated.formatted(date: .abbreviated, time: .shortened))")
                }
                InfoRow(label: "Messages", value: "\(session.messageCount) · \(session.toolCallCount) tool call(s)")
            }

            if let parent = model.parent {
                relationButton(title: "Parent session", session: parent, symbol: "arrow.turn.up.left")
            }
            if !model.children.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Subagents (\(model.children.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.children) { child in
                        relationButton(title: child.subagentType ?? "subagent", session: child, symbol: "arrow.turn.down.right")
                    }
                }
            }

            DisclosureGroup("Source metadata", isExpanded: $showDetails) {
                Text(session.metadata.isEmpty ? "No metadata." : JSONValue.object(session.metadata).prettyText)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Theme.Spacing.xs)
            }
            .font(.callout)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.l)
    }

    private func relationButton(title: String, session: SessionSummary, symbol: String) -> some View {
        Button {
            app.selectedSessionId = session.id
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text("\(session.messageCount) msgs")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Theme.surface))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var issuesBanner: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label("\(model.issues.count) record(s) could not be decoded", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Tone.warning.color)
            ForEach(model.issues.prefix(3)) { issue in
                Text(issue.rawPreview ?? issue.detail)
                    .font(Theme.mono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("They are kept as raw lines and are not silently dropped.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

/// One message: role, time and model, followed by its parts.
struct MessageView: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: roleSymbol)
                    .foregroundStyle(roleTone.color)
                Text(roleName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(roleTone.color)
                if let model = message.model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let timestamp = message.timestamp {
                    Text(timestamp.formatted(date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(Array(message.contentParts.enumerated()), id: \.offset) { _, part in
                PartView(part: part)
            }
            if message.contentParts.isEmpty {
                Text("(no content)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(message.role == .user ? Theme.surfaceStrong : Theme.surface)
        )
    }

    private var roleName: String {
        switch message.role {
        case .user: "User"
        case .assistant: "Assistant"
        case .system: "System"
        case .tool: "Tool"
        case .unknown: "Unknown"
        }
    }

    private var roleSymbol: String {
        switch message.role {
        case .user: "person.fill"
        case .assistant: "sparkles"
        case .system: "gearshape"
        case .tool: "wrench.and.screwdriver"
        case .unknown: "questionmark.circle"
        }
    }

    private var roleTone: Theme.Tone {
        switch message.role {
        case .user: .info
        case .assistant: .success
        case .system, .unknown: .neutral
        case .tool: .warning
        }
    }
}

/// Renders one content part. Tool calls and results are display-only cards.
struct PartView: View {
    let part: ContentPart

    var body: some View {
        switch part {
        case .text(let text):
            Text(markdown(text))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .reasoning(let text):
            CollapsibleBlock(title: "Reasoning", symbol: "brain", tone: .neutral) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .toolCall(let call):
            CollapsibleBlock(
                title: "Tool call · \(call.name)",
                subtitle: call.status,
                symbol: "wrench",
                tone: .warning,
                footnote: "Historical record. This cannot be run from SessionDock."
            ) {
                CodeBlock(text: call.input.prettyText)
            }
        case .toolResult(let result):
            CollapsibleBlock(
                title: result.isError ? "Tool result · error" : "Tool result",
                symbol: result.isError ? "xmark.octagon" : "text.alignleft",
                tone: result.isError ? .error : .neutral
            ) {
                CodeBlock(text: result.output.isEmpty ? "(empty output)" : result.output)
            }
        case .fileReference(let file):
            Label(file.path, systemImage: "doc")
                .font(Theme.mono(12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .unknown(let kind, let raw):
            CollapsibleBlock(title: "Unrecognised · \(kind)", symbol: "questionmark.square.dashed", tone: .neutral) {
                CodeBlock(text: raw.prettyText)
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct CollapsibleBlock<Content: View>: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let tone: Theme.Tone
    var footnote: String?
    @ViewBuilder var content: () -> Content
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                content()
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, Theme.Spacing.xs)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(tone.color)
                Text(title)
                    .font(.callout.weight(.medium))
                if let subtitle {
                    StatusBadge(text: subtitle, tone: subtitle == "completed" ? .success : .neutral)
                }
            }
        }
        .padding(Theme.Spacing.s)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(tone.color.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small).strokeBorder(tone.color.opacity(0.18)))
    }
}

/// Monospaced, selectable text that is truncated for display with an explicit "show all".
struct CodeBlock: View {
    let text: String
    private let limit = 6_000
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(showAll || text.count <= limit ? text : String(text.prefix(limit)) + "…")
                .font(Theme.mono(11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.s)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.small).fill(Color.black.opacity(0.06)))
            if text.count > limit {
                Button(showAll ? "Show less" : "Show all \(text.count.formatted()) characters") {
                    showAll.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }
}
