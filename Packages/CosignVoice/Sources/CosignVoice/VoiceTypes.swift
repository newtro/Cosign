import Foundation

public struct VoicePreset: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var subtitle: String
    public var accentNote: String
    public var seedFilename: String

    public init(id: String, name: String, subtitle: String, accentNote: String, seedFilename: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.accentNote = accentNote
        self.seedFilename = seedFilename
    }

    public static let all: [VoicePreset] = [
        VoicePreset(id: "vera", name: "Vera — Studio Anchor", subtitle: "Warm, poised editorial host", accentNote: "US · Warm Contralto", seedFilename: "vera.wav"),
        VoicePreset(id: "marcus", name: "Marcus — Grounded Builder", subtitle: "Direct, steady baritone", accentNote: "US · Deep Baritone", seedFilename: "marcus.wav"),
        VoicePreset(id: "sable", name: "Sable — Wry Contrarian", subtitle: "Sharp, expressive red-teamer", accentNote: "UK · Crisp Alto", seedFilename: "sable.wav"),
        VoicePreset(id: "orion", name: "Orion — Bright Visionary", subtitle: "Energetic, curious storyteller", accentNote: "US · Spirited Tenor", seedFilename: "orion.wav"),
        VoicePreset(id: "lyra", name: "Lyra — Warm Designer", subtitle: "Clear, empathetic craft voice", accentNote: "US · Clear Mezzo", seedFilename: "lyra.wav"),
        VoicePreset(id: "kael", name: "Kael — Calm Strategist", subtitle: "Measured, analytical cadence", accentNote: "UK · Smooth Baritone", seedFilename: "kael.wav"),
        VoicePreset(id: "ember", name: "Ember — Bold Challenger", subtitle: "Velvety, spirited edge", accentNote: "US · Expressive", seedFilename: "ember.wav"),
        VoicePreset(id: "sage", name: "Sage — Senior Counsel", subtitle: "Unhurried, resonant advisor", accentNote: "US · Resonant", seedFilename: "sage.wav"),
    ]
}

public enum VocalSegment: Equatable, Hashable, Sendable {
    case words(String)
    case cue(String)
}

public enum ExpressiveTagFormatter {
    private static let tagPattern = try! NSRegularExpression(
        pattern: #"\[(chuckle|laugh|sigh|clear throat|cough|gasp|groan)\]"#,
        options: [.caseInsensitive]
    )

    /// Splits a raw spoken line (e.g. `"[chuckle] Hold on Marcus, that won't scale."`) into text & subtle stage cues for UI display.
    public static func parseSegments(_ raw: String) -> [VocalSegment] {
        let ns = raw as NSString
        let matches = tagPattern.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else {
            return [.words(raw)]
        }
        var segments: [VocalSegment] = []
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                let textPart = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                if !textPart.isEmpty {
                    segments.append(.words(textPart))
                }
            }
            let cueWord = ns.substring(with: m.range(at: 1)).lowercased()
            segments.append(.cue(humanCueLabel(cueWord)))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let tail = ns.substring(from: cursor)
            if !tail.isEmpty {
                segments.append(.words(tail))
            }
        }
        return segments
    }

    /// Strips bracketed vocal tags when falling back to plain system speech so fallback voices never read "[chuckle]" literally.
    public static func stripTags(_ raw: String) -> String {
        let ns = raw as NSString
        let stripped = tagPattern.stringByReplacingMatches(
            in: raw,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        return stripped
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func humanCueLabel(_ tag: String) -> String {
        switch tag {
        case "chuckle": return "chuckles"
        case "laugh": return "laughs"
        case "sigh": return "sighs"
        case "clear throat": return "clears throat"
        case "cough": return "coughs"
        case "gasp": return "gasps"
        case "groan": return "groans"
        default: return tag
        }
    }
}

public enum VoiceDaemonState: Equatable, Sendable {
    case idle
    case starting(String)
    case ready
    case fallbackSystemVoice(String)
}
