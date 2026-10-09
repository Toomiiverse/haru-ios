import SwiftUI

/// A symbol and a colour for each of the faces she can pull.
enum MoodLook {
    static func symbol(for emotion: String) -> String {
        switch emotion.lowercased() {
        case "happy", "excited", "joy", "hope", "optimism", "schadenfreude": return "sun.max.fill"
        case "love", "affectionate", "affection", "trust", "gratitude", "admiration", "pity": return "heart.fill"
        case "angry", "annoyed", "anger", "frustration", "resentment": return "flame.fill"
        case "sad", "sadness", "hurt", "disappointment", "melancholy": return "cloud.rain.fill"
        case "sleepy": return "moon.zzz.fill"
        case "thinking", "curious", "interest", "curiosity": return "brain.head.profile"
        case "smug", "pride": return "sparkles"
        case "surprised", "surprise": return "exclamationmark.circle.fill"
        case "confused", "confusion": return "questionmark.circle.fill"
        case "embarrassed", "embarrassment", "guilt", "shame", "humiliation": return "face.smiling.inverse"
        case "bored", "unimpressed", "boredom", "disgust", "contempt": return "ellipsis"
        case "worried", "concerned", "fear", "dread": return "cloud.fill"
        case "determined", "determination": return "scope"
        case "awe", "wonder": return "sparkles"
        case "jealousy", "envy": return "eye.fill"
        case "longing", "nostalgia": return "clock.arrow.circlepath"
        case "serenity", "relief": return "leaf.fill"
        case "playfulness": return "face.smiling.fill"
        case "restlessness": return "waveform.path"
        default: return "circle.fill"
        }
    }

    static func tint(for emotion: String) -> Color {
        switch emotion.lowercased() {
        case "happy", "excited", "joy", "hope", "optimism", "schadenfreude": return .yellow
        case "love", "affectionate", "affection", "trust", "gratitude", "admiration", "pity": return .pink
        case "angry", "annoyed", "anger", "frustration", "resentment": return .red
        case "sad", "sadness", "hurt", "disappointment", "melancholy": return .blue
        case "sleepy": return .indigo
        case "thinking", "curious", "interest", "curiosity": return .teal
        case "smug", "pride": return .orange
        case "surprised", "surprise", "confused", "confusion", "embarrassed", "embarrassment", "guilt", "shame", "humiliation": return .purple
        case "bored", "unimpressed", "boredom", "disgust", "contempt": return .gray
        case "worried", "concerned", "fear", "dread": return .blue
        case "determined", "determination": return .orange
        case "awe", "wonder": return .purple
        case "jealousy", "envy": return .green
        case "longing", "nostalgia", "restlessness": return .blue
        case "serenity", "relief": return .teal
        case "playfulness": return .mint
        default: return .secondary
        }
    }

    static func tint(forMeter label: String) -> Color {
        switch label {
        case "Affection": return .pink
        case "Energy": return .yellow
        case "Stress": return .red
        case "Sleepiness": return .indigo
        case "Curiosity": return .teal
        case "Ego": return .orange
        // What she feels about him, beside the vitals (the server's feelings.ts).
        // Each its own colour, or five bars in one accent read as one thing.
        case "Playfulness": return .mint
        case "Jealousy": return .green
        case "Left alone": return .blue
        case "Boredom": return .gray
        case "Hurt": return .purple
        default: return .accentColor
        }
    }
}
