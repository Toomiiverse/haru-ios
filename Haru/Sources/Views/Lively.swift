import SwiftUI

/// Her lines with some life in them: **bold** and *italics* as she writes
/// them, ==highlights== and words in CAPITALS in the colour of her mood.
/// Markdown is read inline only, so nothing she says turns into a heading
/// or a list by accident, and a line with none of it comes back untouched.
enum Lively {
    private static let open: Character = "\u{E000}"
    private static let close: Character = "\u{E001}"

    static func text(_ raw: String, tint: Color) -> AttributedString {
        // Highlights first: ==like this== is wrapped in sentinels the markdown
        // pass leaves alone, so they can be found afterwards.
        let marked = raw.replacingOccurrences(of: #"==(.+?)=="#, with: "\(open)$1\(close)", options: .regularExpression)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var out = (try? AttributedString(markdown: marked, options: options)) ?? AttributedString(marked)
        // Bold, in her colour.
        let bold = out.runs.compactMap { run in run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? run.range : nil }
        for range in bold { out[range].foregroundColor = tint }
        for range in ranges(in: out, matching: "\(open)[^\(close)]*\(close)") {
            out[range].backgroundColor = tint.opacity(0.22)
            out[range].foregroundColor = tint
        }
        out.characters.removeAll { $0 == open || $0 == close }
        // A word she shouts.
        for range in ranges(in: out, matching: #"\b[A-Z]{3,}\b"#) {
            out[range].foregroundColor = tint
            out[range].font = .body.weight(.semibold)
        }
        return out
    }

    /// Every match of the pattern in the text as it reads, as ranges into the
    /// attributed string. Attributes do not move characters, so the ranges
    /// hold while they are painted.
    private static func ranges(in out: AttributedString, matching pattern: String) -> [Range<AttributedString.Index>] {
        let plain = String(out.characters)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).compactMap { match in
            guard let stringRange = Range(match.range, in: plain) else { return nil }
            let lower = out.characters.index(out.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: stringRange.lowerBound))
            let upper = out.characters.index(out.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: stringRange.upperBound))
            return lower..<upper
        }
    }
}

/// One pass of light across a bubble as it lands, in her colour.
struct Shimmer: ViewModifier {
    let tint: Color
    let on: Bool
    @State private var phase: CGFloat = -0.7

    func body(content: Content) -> some View {
        content.overlay {
            if on {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, tint.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                        .blendMode(.plusLighter)
                }
                .allowsHitTesting(false)
                .onAppear { withAnimation(.easeInOut(duration: 1.1).delay(0.1)) { phase = 1.3 } }
            }
        }
    }
}
