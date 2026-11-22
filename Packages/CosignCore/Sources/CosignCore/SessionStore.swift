import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    /// Returns true when `path` is nil or points to a top-level parent container (`repos`, `Developer`, `$HOME`)
    /// rather than a dedicated project directory—used to prompt the user to select or create a folder before Building.
    public static func isParentReposContainer(_ path: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let parentRoots: Set<String> = [
            "/Volumes/Cache/repos",
            "/Volumes/Data 1/Repos",
            home.appendingPathComponent("repos").standardizedFileURL.path,
            home.appendingPathComponent("Developer").standardizedFileURL.path,
            home.standardizedFileURL.path,
        ]
        return parentRoots.contains(standardized)
    }
}

public struct AppPreferences: Codable, Sendable {
    public var autoSpeakResponses: Bool
    public var playbackSpeed: Double
    public var defaultMaxRebuttalRounds: Int
    public var defaultAllowWebSearch: Bool
    public var defaultMode: CouncilMode?
    public var defaultCLIToolsEnabled: Bool?
    public var defaultCompletenessReviewEnabled: Bool?
    public var defaultCompletenessReviewerID: UUID?
    public var defaultWorkspacePath: String?
    public var recentWorkspacePaths: [String]?
    public var showVocalTagsInText: Bool
    public var activePresetID: UUID?

    public init(
        autoSpeakResponses: Bool = true,
        playbackSpeed: Double = 1.08,
        defaultMaxRebuttalRounds: Int = 2,
        defaultAllowWebSearch: Bool = true,
        defaultMode: CouncilMode? = .debate,
        defaultCLIToolsEnabled: Bool? = true,
        defaultCompletenessReviewEnabled: Bool? = true,
        defaultCompletenessReviewerID: UUID? = DefaultRoster.wardenID,
        defaultWorkspacePath: String? = WorkspaceResolver.defaultWorkspacePath(),
        recentWorkspacePaths: [String]? = nil,
        showVocalTagsInText: Bool = true,
        activePresetID: UUID? = DefaultRoster.coreCouncilPresetID
    ) {
        self.autoSpeakResponses = autoSpeakResponses
        self.playbackSpeed = playbackSpeed
        self.defaultMaxRebuttalRounds = defaultMaxRebuttalRounds
        self.defaultAllowWebSearch = defaultAllowWebSearch
        self.defaultMode = defaultMode
        self.defaultCLIToolsEnabled = defaultCLIToolsEnabled
        self.defaultCompletenessReviewEnabled = defaultCompletenessReviewEnabled
        self.defaultCompletenessReviewerID = defaultCompletenessReviewerID
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
        try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
    }

    private var personasURL: URL { rootDirectory.appendingPathComponent("personas.json") }
    private var presetsURL: URL { rootDirectory.appendingPathComponent("presets.json") }
    private var preferencesURL: URL { rootDirectory.appendingPathComponent("preferences.json") }
    private var sessionsDirectory: URL { rootDirectory.appendingPathComponent("Sessions", isDirectory: true) }
    public var attachmentsDirectory: URL { rootDirectory.appendingPathComponent("Attachments", isDirectory: true) }

    public func loadPersonas() -> [Persona] {
        guard let data = try? Data(contentsOf: personasURL),
              var loaded = try? decoder.decode([Persona].self, from: data),
              !loaded.isEmpty else {
            let defaults = DefaultRoster.personas
            savePersonas(defaults)
            return defaults
        }
        // Merge any newly shipped built-in personas (e.g. Task & Build Crew) without overwriting user customizations
        let existingIDs = Set(loaded.map(\.id))
        var updatedAny = false
        for builtIn in DefaultRoster.personas where !existingIDs.contains(builtIn.id) {
            loaded.append(builtIn)
            updatedAny = true
        }
        // Backfill default taskSpecialties on older built-in personas that were saved before specialties existed
        let defaultsByID = Dictionary(uniqueKeysWithValues: DefaultRoster.personas.map { ($0.id, $0) })
        for idx in loaded.indices where loaded[idx].isBuiltIn && loaded[idx].taskSpecialties == nil && loaded[idx].routingSignal == nil {
            if let def = defaultsByID[loaded[idx].id], (def.taskSpecialties != nil || def.routingSignal != nil) {
                loaded[idx].taskSpecialties = def.taskSpecialties
                loaded[idx].routingSignal = def.routingSignal
                updatedAny = true
            }
        }
        if updatedAny {
            savePersonas(loaded)
        }
        return loaded
    }

    public func savePersonas(_ personas: [Persona]) {
        guard let data = try? encoder.encode(personas) else { return }
        try? data.write(to: personasURL, options: .atomic)
    }

    public func loadPresets() -> [PanelPreset] {
        guard let data = try? Data(contentsOf: presetsURL),
              var loaded = try? decoder.decode([PanelPreset].self, from: data),
              !loaded.isEmpty else {
            let defaults = DefaultRoster.presets
            savePresets(defaults)
            return defaults
        }
        // Merge any newly shipped built-in panel presets (e.g. Task & Build Crew) right after Core Council
        let existingIDs = Set(loaded.map(\.id))
        var addedAny = false
        for builtIn in DefaultRoster.presets where !existingIDs.contains(builtIn.id) {
            if builtIn.id == DefaultRoster.taskBuildCrewPresetID, loaded.count >= 1 {
                loaded.insert(builtIn, at: 1)
            } else {
                loaded.append(builtIn)
            }
            addedAny = true
        }
        if addedAny {
            savePresets(loaded)
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

    // MARK: - Persistent Chat Image Attachment Storage

    public static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "tif", "bmp"
    ]

    public static func isSupportedImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if supportedImageExtensions.contains(ext) { return true }
        if let uti = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           uti.conforms(to: .image) {
            return true
        }
        return false
    }

    /// Imports an external image file into `Attachments/`, normalizing TIFF/HEIC/BMP or oversized bitmaps into crisp PNG
    /// so every CLI (`claude`, `codex -i`, `agy`) and OpenRouter vision endpoint can read it reliably.
    public func importImageFile(from sourceURL: URL, preferredName: String? = nil) throws -> ChatImageAttachment {
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let rawName = preferredName ?? sourceURL.deletingPathExtension().lastPathComponent
        let cleanBase = Self.sanitizeFilename(rawName.isEmpty ? "Image" : rawName)
        let ext = sourceURL.pathExtension.lowercased()
        let directWebExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]
        let fileSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        let id = UUID()
        let shortID = String(id.uuidString.prefix(8))

        if directWebExtensions.contains(ext), fileSize > 0, fileSize <= 10_000_000 {
            let destExt = ext == "jpeg" ? "jpg" : ext
            let destURL = attachmentsDirectory.appendingPathComponent("\(shortID)-\(cleanBase).\(destExt)")
            if FileManager.default.fileExists(atPath: destURL.path) {
                try? FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            let dims = Self.readPixelDimensions(at: destURL)
            return ChatImageAttachment(
                id: id,
                filePath: destURL.path,
                displayName: "\(cleanBase).\(destExt)",
                mimeType: Self.mimeType(forExtension: destExt),
                widthPx: dims?.width,
                heightPx: dims?.height
            )
        }

        let rawData = try Data(contentsOf: sourceURL)
        return try saveImageData(rawData, preferredName: cleanBase, existingID: id)
    }

    /// Saves raw clipboard or dropped image data (PNG, TIFF, JPEG, HEIC, etc.) into `Attachments/` as a normalized PNG.
    public func saveImageData(
        _ data: Data,
        preferredName: String = "Pasted-Image",
        existingID: UUID = UUID()
    ) throws -> ChatImageAttachment {
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        let cleanBase = Self.sanitizeFilename(preferredName.isEmpty ? "Pasted-Image" : preferredName)
        let shortID = String(existingID.uuidString.prefix(8))
        let destURL = attachmentsDirectory.appendingPathComponent("\(shortID)-\(cleanBase).png")

        if let normalized = Self.transcodeToNormalizedPNG(data: data, maxDimension: 3072) {
            try normalized.pngData.write(to: destURL, options: .atomic)
            return ChatImageAttachment(
                id: existingID,
                filePath: destURL.path,
                displayName: "\(cleanBase).png",
                mimeType: "image/png",
                widthPx: normalized.width,
                heightPx: normalized.height
            )
        }

        // Fallback if raw bytes are already valid image data
        try data.write(to: destURL, options: .atomic)
        let dims = Self.readPixelDimensions(at: destURL)
        return ChatImageAttachment(
            id: existingID,
            filePath: destURL.path,
            displayName: "\(cleanBase).png",
            mimeType: "image/png",
            widthPx: dims?.width,
            heightPx: dims?.height
        )
    }

    private static func readPixelDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }

    private static func transcodeToNormalizedPNG(data: Data, maxDimension: Int) -> (pngData: Data, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return nil
        }
        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (outData as Data, cgImage.width, cgImage.height)
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(cleaned)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "Image" : String(collapsed.prefix(40))
    }

    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }
}
