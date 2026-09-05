import SwiftUI

/// A symbol and a colour for each of the faces she can pull.
enum MoodLook {
    static func symbol(for emotion: String) -> String {
        switch emotion.lowercased() {
        case "happy", "excited": return "sun.max.fill"
        case "love", "affectionate": return "heart.fill"
        case "angry", "annoyed": return "flame.fill"
        case "sad": return "cloud.rain.fill"
        case "sleepy": return "moon.zzz.fill"
        case "thinking", "curious": return "brain.head.profile"
        case "smug": return "sparkles"
        case "surprised": return "exclamationmark.circle.fill"
        case "confused": return "questionmark.circle.fill"
        case "embarrassed": return "face.smiling.inverse"
        default: return "circle.fill"
        }
    }

    static func tint(for emotion: String) -> Color {
        switch emotion.lowercased() {
        case "happy", "excited": return .yellow
        case "love", "affectionate": return .pink
        case "angry", "annoyed": return .red
        case "sad": return .blue
        case "sleepy": return .indigo
        case "thinking", "curious": return .teal
        case "smug": return .orange
        case "surprised", "confused", "embarrassed": return .purple
        default: return .secondary
        }
    }

    static func tint(forMeter label: String) -> Color {
        switch label {
        case "Affection": return .pink
        case "Energy": return .yellow
        case "Stress": return .red
        case "Sleepiness": return .indigo
        default: return .accentColor
        }
    }
}
