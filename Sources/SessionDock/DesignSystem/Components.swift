import SessionDockCore
import SwiftUI

struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.m)
    }
}

/// A list column and a flexible detail column. The list keeps a fixed width so that the layout never
/// exceeds the window, whatever the content of either side.
struct MasterDetail<Master: View, Detail: View>: View {
    var masterWidth: CGFloat = 320
    @ViewBuilder var master: () -> Master
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 0) {
            master()
                .frame(width: masterWidth)
                .frame(maxHeight: .infinity)
            Divider()
            detail()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

struct StatusBadge: View {
    let text: String
    let tone: Theme.Tone
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(tone.color)
        .background(Capsule().fill(tone.color.opacity(0.14)))
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .card()
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, Theme.Spacing.s)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

struct LoadingView: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(monospaced ? Theme.mono(12) : .callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

struct AgentMark: View {
    let agent: AgentKind
    var size: CGFloat = 14

    var body: some View {
        AgentLogo(agent: agent, size: size)
            .help(agent.displayName)
    }
}

extension InstallationStatus {
    var tone: Theme.Tone {
        switch self {
        case .available: .success
        case .notFound: .neutral
        case .unreadable: .error
        }
    }
}

extension MigrationJobStatus {
    var tone: Theme.Tone {
        switch self {
        case .succeeded, .restored: .success
        case .succeededWithWarnings: .warning
        case .backingUp, .migrating, .verifying: .info
        case .failed, .failedVerification: .error
        }
    }
}

extension PlanIssueSeverity {
    var tone: Theme.Tone {
        switch self {
        case .info: .info
        case .warning: .warning
        case .blocker: .error
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .blocker: "xmark.octagon"
        }
    }
}

extension ValidationSeverity {
    var tone: Theme.Tone {
        switch self {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }
}

extension Date {
    var shortRelative: String {
        formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
}
