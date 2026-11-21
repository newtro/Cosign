import Foundation

public enum WorkspaceResolver {
    public static func defaultWorkspacePath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let fm = FileManager.default
        let candidates = [
            "/Volumes/Cache/repos",
            home.appendingPathComponent("repos").path,
            home.appendingPathComponent("Developer").path,
            home.path,
        ]
        for path in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return path
            }
        }
        return home.path
    }

    public static func additionalRepoRoots(excluding primary: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let fm = FileManager.default
        let candidates = [
            "/Volumes/Cache/repos",
            "/Volumes/Data 1/Repos",
            home.appendingPathComponent("repos").path,
        ]
        return candidates.filter { path in
            guard path != primary else { return false }
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }
}

public struct AppPreferences: Codable, Sendable {
    public var autoSpeakResponses: Bool
    public var playbackSpeed: Double
    public var defaultMaxRebuttalRounds: Int
    public var defaultAllowWebSearch: Bool
    public var defaultCLIToolsEnabled: Bool?
    public var defaultWorkspacePath: String?
    public var recentWorkspacePaths: [String]?
    public var showVocalTagsInText: Bool
    public var activePresetID: UUID?

    public init(
        autoSpeakResponses: Bool = true,
        playbackSpeed: Double = 1.08,
        defaultMaxRebuttalRounds: Int = 2,
        defaultAllowWebSearch: Bool = true,
        defaultCLIToolsEnabled: Bool? = true,
        defaultWorkspacePath: String? = WorkspaceResolver.defaultWorkspacePath(),
        recentWorkspacePaths: [String]? = nil,
        showVocalTagsInText: Bool = true,
        activePresetID: UUID? = DefaultRoster.coreCouncilPresetID
    ) {
        self.autoSpeakResponses = autoSpeakResponses
        self.playbackSpeed = playbackSpeed
        self.defaultMaxRebuttalRounds = defaultMaxRebuttalRounds
        self.defaultAllowWebSearch = defaultAllowWebSearch
        self.defaultCLIToolsEnabled = defaultCLIToolsEnabled
        self.defaultWorkspacePath = defaultWorkspacePath
        self.recentWorkspacePaths = recentWorkspacePaths
        self.showVocalTagsInText = showVocalTagsInText
        self.activePresetID = activePresetID
    }
}

public final class SessionStore: @unchecked Sendable {
    public let rootDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public static func defaultRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.scottsmith.cosign"
        let folderName = bundleID.hasSuffix(".debug") ? "Cosign Dev" : "Cosign"
        return appSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    public init(rootDirectory: URL = SessionStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
    }

    private var personasURL: URL { rootDirectory.appendingPathComponent("personas.json") }
    private var presetsURL: URL { rootDirectory.appendingPathComponent("presets.json") }
    private var preferencesURL: URL { rootDirectory.appendingPathComponent("preferences.json") }
    private var sessionsDirectory: URL { rootDirectory.appendingPathComponent("Sessions", isDirectory: true) }

    public func loadPersonas() -> [Persona] {
        guard let data = try? Data(contentsOf: personasURL),
              let loaded = try? decoder.decode([Persona].self, from: data),
              !loaded.isEmpty else {
            let defaults = DefaultRoster.personas
            savePersonas(defaults)
            return defaults
        }
        return loaded
    }

    public func savePersonas(_ personas: [Persona]) {
        guard let data = try? encoder.encode(personas) else { return }
        try? data.write(to: personasURL, options: .atomic)
    }

    public func loadPresets() -> [PanelPreset] {
        guard let data = try? Data(contentsOf: presetsURL),
              let loaded = try? decoder.decode([PanelPreset].self, from: data),
              !loaded.isEmpty else {
            let defaults = DefaultRoster.presets
            savePresets(defaults)
            return defaults
        }
        return loaded
    }

    public func savePresets(_ presets: [PanelPreset]) {
        guard let data = try? encoder.encode(presets) else { return }
        try? data.write(to: presetsURL, options: .atomic)
    }

    public func loadPreferences() -> AppPreferences {
        guard let data = try? Data(contentsOf: preferencesURL),
              let prefs = try? decoder.decode(AppPreferences.self, from: data) else {
            let defaults = AppPreferences()
            savePreferences(defaults)
            return defaults
        }
        return prefs
    }

    public func savePreferences(_ prefs: AppPreferences) {
        guard let data = try? encoder.encode(prefs) else { return }
        try? data.write(to: preferencesURL, options: .atomic)
    }

    public func loadSessions() -> [DebateSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> DebateSession? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(DebateSession.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func saveSession(_ session: DebateSession) {
        let url = sessionsDirectory.appendingPathComponent("\(session.id.uuidString).json")
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func deleteSession(id: UUID) {
        let url = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }
}
