import SwiftUI

/// Her lines with some life in them: **bold** and *italics* as she writes
/// them, ==highlights== and words in CAPITALS in the colour of her mood.
/// Markdown is read inline only, so nothing she says turns into a heading
/// or a list by accident, and a line with none of it comes back untouched.
enum Lively {
    static func text(_ raw: String, tint: Color) -> AttributedString {
        // Built from pieces rather than edited in place: ==highlights== are
        // split out before the markdown pass, so no character is ever removed
        // from an attributed string afterwards. Foundation asserts when its
        // character view is replaced wholesale, which is what removeAll does —
        // build 41 crashed on every launch that way.
        var out = AttributedString()
        for (piece, highlighted) in segments(raw) {
            var part = parse(piece)
            if highlighted {
                part.backgroundColor = tint.opacity(0.22)
                part.foregroundColor = tint
            }
            // Bold, in her colour.
            let bold = part.runs.compactMap { run in run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true ? run.range : nil }
            for range in bold { part[range].foregroundColor = tint }
            out.append(part)
        }
        // A word she shouts.
        for range in ranges(in: out, matching: #"\b[A-Z]{3,}\b"#) {
            out[range].foregroundColor = tint
            out[range].font = .body.weight(.semibold)
        }
        return out
    }

    /// The line cut at its ==highlights==: the text between, and each
    /// highlight's inside, in order, marked which is which.
    private static func segments(_ raw: String) -> [(String, Bool)] {
        guard let regex = try? NSRegularExpression(pattern: "==(.+?)==") else { return [(raw, false)] }
        var pieces: [(String, Bool)] = []
        var cursor = raw.startIndex
        for match in regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
            guard let whole = Range(match.range, in: raw), let inner = Range(match.range(at: 1), in: raw) else { continue }
            if whole.lowerBound > cursor { pieces.append((String(raw[cursor..<whole.lowerBound]), false)) }
            pieces.append((String(raw[inner]), true))
            cursor = whole.upperBound
        }
        if cursor < raw.endIndex { pieces.append((String(raw[cursor...]), false)) }
        return pieces.isEmpty ? [(raw, false)] : pieces
    }

    /// Inline markdown only: bold, italics, strikethrough, code. Never a
    /// heading or a list, and a line that fails to parse comes back as it was.
    private static func parse(_ piece: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: piece, options: options)) ?? AttributedString(piece)
    }

    /// Every match of the pattern in the text as it reads, as ranges into the
    /// attributed string. Attributes do not move characters, so the ranges
    /// hold while they are painted.
    private static func ranges(in out: AttributedString, matching pattern: String) -> [Range<AttributedString.Index>] {
        let plain = String(out.characters)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let count = out.characters.count
        return regex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).compactMap { match in
            guard let stringRange = Range(match.range, in: plain) else { return nil }
            let from = plain.distance(from: plain.startIndex, to: stringRange.lowerBound)
            let to = plain.distance(from: plain.startIndex, to: stringRange.upperBound)
            guard from >= 0, to <= count, from < to else { return nil }
            let lower = out.characters.index(out.startIndex, offsetBy: from)
            let upper = out.characters.index(out.startIndex, offsetBy: to)
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
