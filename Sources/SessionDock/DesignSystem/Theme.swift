import SwiftUI

/// Design tokens. Colours are semantic so that light and dark appearance both work without overrides.
enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let card: CGFloat = 10
    }

    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color.primary.opacity(0.045)
    static let surfaceStrong = Color.primary.opacity(0.08)
    static let hairline = Color.primary.opacity(0.10)

    enum Tone {
        case success
        case warning
        case error
        case info
        case neutral

        var color: Color {
            switch self {
            case .success: .green
            case .warning: .orange
            case .error: .red
            case .info: .blue
            case .neutral: .secondary
            }
        }
    }

    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, design: .monospaced)
    }
}

extension View {
    /// A calm, bordered card used for grouped content.
    func card(padding: CGFloat = Theme.Spacing.l) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
    }
}
