import SessionDockCore
import SwiftUI

/// The agents' own logos, drawn as shapes so that they stay sharp at every size and follow the
/// appearance. Used only to identify each agent, with the colours from their brand guidelines.
struct AgentLogo: View {
    let agent: AgentKind
    var size: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch agent {
            case .claudeCode:
                ClaudeMark()
                    .fill(AgentBrand.claude)
                    .aspectRatio(1, contentMode: .fit)
            case .openCode:
                let ink = colorScheme == .dark ? AgentBrand.openCodeInkDark : AgentBrand.openCodeInkLight
                ZStack {
                    OpenCodeShade()
                        .fill(ink.opacity(colorScheme == .dark ? 0.28 : 0.2))
                    OpenCodeFrame()
                        .fill(ink, style: FillStyle(eoFill: true))
                }
                .aspectRatio(240.0 / 300.0, contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(agent.displayName)
    }
}

enum AgentBrand {
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
    static let openCodeInkLight = Color(red: 0x1F / 255, green: 0x1F / 255, blue: 0x1F / 255)
    static let openCodeInkDark = Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255)
}

extension AgentKind {
    /// Accent for small agent-specific details, such as file icons.
    var accent: Color {
        switch self {
        case .claudeCode: AgentBrand.claude
        case .openCode: .primary
        }
    }
}

/// The OpenCode logo's outline: a 240×300 block with a 120×180 opening.
private struct OpenCodeFrame: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = CGAffineTransform(scaleX: rect.width / 240, y: rect.height / 300)
        var path = Path()
        path.addRect(CGRect(x: 0, y: 0, width: 240, height: 300))
        path.addRect(CGRect(x: 60, y: 60, width: 120, height: 180))
        return path.applying(scale).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The OpenCode logo's inner shade, the lower two thirds of the opening.
private struct OpenCodeShade: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = CGAffineTransform(scaleX: rect.width / 240, y: rect.height / 300)
        return Path(CGRect(x: 60, y: 120, width: 120, height: 120)).applying(scale).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// The Claude mark, from its 24×24 SVG path.
private struct ClaudeMark: Shape {
    private static let base = SVGPath.parse(claudePathData)

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return Self.base
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .offsetBy(dx: rect.minX + (rect.width - 24 * scale) / 2, dy: rect.minY + (rect.height - 24 * scale) / 2)
    }

    private static let claudePathData = "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"
}

/// A minimal SVG path-data reader: M, L, H, V, C and Z, absolute and relative, with implicit
/// repetition and compact numbers such as `.079-.2307`.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var path = Path()
        var scanner = NumberScanner(Array(data.utf8))
        var command: UInt8 = 0
        var current = CGPoint.zero
        var start = CGPoint.zero

        while let next = scanner.nextCommandOrNumber() {
            if case .command(let letter) = next {
                command = letter
                if letter == UInt8(ascii: "Z") || letter == UInt8(ascii: "z") {
                    path.closeSubpath()
                    current = start
                    continue
                }
            } else {
                scanner.rewindNumber()
            }
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                start = current
                path.move(to: current)
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                path.addLine(to: current)
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current.x = origin.x + x
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current.y = origin.y + y
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let x1 = scanner.number(), let y1 = scanner.number(),
                      let x2 = scanner.number(), let y2 = scanner.number(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let control1 = CGPoint(x: origin.x + x1, y: origin.y + y1)
                let control2 = CGPoint(x: origin.x + x2, y: origin.y + y2)
                current = CGPoint(x: origin.x + x, y: origin.y + y)
                path.addCurve(to: current, control1: control1, control2: control2)
            default:
                return path
            }
        }
        return path
    }

    private enum Token {
        case command(UInt8)
        case number
    }

    private struct NumberScanner {
        let bytes: [UInt8]
        var index = 0
        var lastNumberStart = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",")
                || bytes[index] == UInt8(ascii: "\n") || bytes[index] == UInt8(ascii: "\t") {
                index += 1
            }
        }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) {
                index += 1
                return .command(byte)
            }
            lastNumberStart = index
            return .number
        }

        mutating func rewindNumber() {
            index = lastNumberStart
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var seenDot = false
            var seenDigit = false
            while index < bytes.count {
                let byte = bytes[index]
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    seenDigit = true
                    index += 1
                } else if byte == UInt8(ascii: "."), !seenDot {
                    seenDot = true
                    index += 1
                } else {
                    break
                }
            }
            guard seenDigit, let text = String(bytes: bytes[begin..<index], encoding: .ascii), let value = Double(text) else {
                index = begin
                return nil
            }
            return CGFloat(value)
        }
    }
}
