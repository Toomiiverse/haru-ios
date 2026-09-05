import SwiftUI

/// The seam between her stage and the talk, made into something: a glass
/// plate across the join with her feeling, her mood in her own words, and
/// the meters that matter — the way a game names a character over the
/// scene. Tap for the full Status page. Numbers come from /api/status.
struct Nameplate: View {
    let standing: Standing?
    let emotion: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: MoodLook.symbol(for: emotion))
                        .font(.caption)
                        .foregroundStyle(MoodLook.tint(for: emotion))
                    Text(emotion.isEmpty ? "Haru" : emotion.capitalized)
                        .font(.caption.weight(.semibold))
                    if let mood = standing?.mood, !mood.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(mood)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    if let bond = standing?.bond {
                        bar(label: "\(bond.title) · Lv \(Int(bond.level))", value: bond.level, of: max(bond.of, 1), tint: Color.accentColor, width: 84)
                    }
                    ForEach(picked) { meter in
                        bar(label: meter.label, value: meter.value, of: 100, tint: MoodLook.tint(forMeter: meter.label), width: 48)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: Color.accentColor.opacity(0.22), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How she is: \(emotion). \(standing?.mood ?? "")")
    }

    /// The two that say the most at a glance; the rest are on Status.
    private var picked: [Meter] {
        ["Affection", "Energy"].compactMap { want in standing?.meters.first { $0.label == want } }
    }

    private func bar(label: String, value: Double, of: Double, tint: Color, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Capsule()
                .fill(Color.white.opacity(0.12))
                .frame(width: width, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: width * CGFloat(min(max(value / of, 0), 1)), height: 4)
                }
        }
    }
}
