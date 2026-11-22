import AppKit
import Combine
import CosignCore
import CosignVoice
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var personas: [Persona]
    @Published var presets: [PanelPreset]
    @Published var sessions: [DebateSession]
    @Published var selectedSessionID: UUID?
    @Published var preferences: AppPreferences

    @Published var modelCatalog: [AIProvider: [DiscoveredModel]] = [
        .claude: ModelDiscoveryService.fallbackClaudeModels,
        .codex: ModelDiscoveryService.fallbackCodexModels,
        .agy: ModelDiscoveryService.fallbackAGYModels,
        .openrouter: ModelDiscoveryService.fallbackOpenRouterModels,
    ]
    @Published var providerDiagnostics: [ProviderDiagnostics] = []
    @Published var isRefreshingModels: Bool = false

    @Published var activeThinkerIDs: Set<UUID> = []
    @Published var liveStatusText: String = ""
    @Published var lastErrorBanner: String?

    // UI Sheets & Navigation
    @Published var showingPersonaStudio: Bool = false
    @Published var studioInitialPersonaID: UUID?
    @Published var showingLineupPopover: Bool = false
    @Published var activeHandoffVerdict: CosignVerdict?
    @Published var activeBuildLaunchVerdict: CosignVerdict?
    @Published var pendingAttachmentsBySession: [UUID: [ChatImageAttachment]] = [:]
    @Published var activePreviewAttachment: ChatImageAttachment?

    let store: SessionStore
    let voiceEngine: VoiceEngine
    private let discoveryService: ModelDiscoveryService
    private let orchestrator: DebateOrchestrator
    private var activeRunTask: Task<Void, Never>?
    private var hasAlignedInitialCatalog = false
    private var voiceCancellable: AnyCancellable?

    init(
        store: SessionStore = SessionStore(),
        runner: ModelRunnerProtocol = LiveCLIRunner(),
        testing: Bool = false
    ) {
        self.store = store
        self.voiceEngine = VoiceEngine(cacheRoot: store.rootDirectory)
        self.discoveryService = ModelDiscoveryService()
        self.orchestrator = DebateOrchestrator(runner: runner)

        let loadedPersonas = store.loadPersonas()
        let loadedPresets = store.loadPresets()
        let loadedPrefs = store.loadPreferences()
        let loadedSessions = store.loadSessions()

        self.personas = loadedPersonas
        self.presets = loadedPresets
        self.preferences = loadedPrefs
        self.sessions = loadedSessions

        self.voiceEngine.playbackSpeed = loadedPrefs.playbackSpeed
        self.voiceEngine.isMuted = !loadedPrefs.autoSpeakResponses

        // Forward nested VoiceEngine state updates so SwiftUI views observing AppModel stay lively
        self.voiceCancellable = voiceEngine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        if loadedSessions.isEmpty {
            let initial = Self.makeBlankSession(presets: loadedPresets, personas: loadedPersonas, prefs: loadedPrefs)
            self.sessions = [initial]
            self.selectedSessionID = initial.id
            store.saveSession(initial)
        } else {
            let defaultWS = loadedPrefs.defaultWorkspacePath ?? WorkspaceResolver.defaultWorkspacePath()
            self.sessions = loadedSessions.map { s in
                var copy = s
                if copy.workspacePath == nil {
                    copy.workspacePath = defaultWS
                }
                if copy.cliToolsEnabled == nil {
                    copy.cliToolsEnabled = true
                }
                if copy.completenessReviewEnabled == nil {
                    copy.completenessReviewEnabled = loadedPrefs.defaultCompletenessReviewEnabled ?? true
                }
                if copy.completenessReviewerID == nil {
                    copy.completenessReviewerID = loadedPrefs.defaultCompletenessReviewerID ?? DefaultRoster.wardenID
                }
                if DebateOrchestrator.healSessionIfNeeded(&copy) {
                    store.saveSession(copy)
                }
                return copy
            }
            self.selectedSessionID = self.sessions.first?.id
        }

        if !testing {
            if loadedPrefs.autoSpeakResponses {
                voiceEngine.warmUpIfNeeded()
            }
            Task {
                await refreshModels()
            }
        }
    }

    // MARK: - Computed Helpers

    var currentSession: DebateSession? {
        guard let id = selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == id }
    }

    func persona(for id: UUID) -> Persona? {
        personas.first { $0.id == id }
    }

    func activeModerator(for session: DebateSession) -> Persona {
        if let hit = persona(for: session.moderatorID) { return hit }
        if let anyMod = personas.first(where: { $0.role == .moderator }) { return anyMod }
        return personas[0]
    }

    func activeDebaters(for session: DebateSession) -> [Persona] {
        let resolved = session.debaterIDs.compactMap { persona(for: $0) }
        if !resolved.isEmpty { return resolved }
        return Array(personas.filter { $0.role == .debater }.prefix(3))
    }

    func completenessReviewer(for session: DebateSession) -> Persona {
        let targetID = session.effectiveCompletenessReviewerID
        if let hit = persona(for: targetID) { return hit }
        if let warden = persona(for: DefaultRoster.wardenID) { return warden }
        return activeDebaters(for: session).last ?? activeModerator(for: session)
    }

    func displayLabel(for provider: AIProvider, modelID: String) -> String {
        if let found = modelCatalog[provider]?.first(where: { $0.id == modelID }) {
            return found.displayName
        }
        return modelID
    }

    var allModelLabelsByID: [String: String] {
        var map: [String: String] = [:]
        for (_, list) in modelCatalog {
            for m in list {
                map[m.id] = m.displayName
            }
        }
        return map
    }

    // MARK: - Model Catalog Discovery

    func refreshModels() async {
        isRefreshingModels = true
        let orKey = KeychainHelper.read(account: "openrouter")
        let result = await discoveryService.discoverAll(openRouterKey: orKey)
        self.modelCatalog = result.catalog
        self.providerDiagnostics = result.diagnostics
        self.isRefreshingModels = false

        if !hasAlignedInitialCatalog {
            hasAlignedInitialCatalog = true
            let aligned = DefaultRoster.alignWithDiscoveredModels(personas: personas, catalog: result.catalog)
            if aligned != personas {
                self.personas = aligned
                store.savePersonas(aligned)
            }
        }
    }

    // MARK: - Session Management

    func createNewSession(preset: PanelPreset? = nil, forceMode: CouncilMode? = nil) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        stopCurrentRun()
        let modeToUse = forceMode ?? (preferences.defaultMode ?? .debate)
        let defaultPresetIDForMode = modeToUse == .build
            ? DefaultRoster.taskBuildCrewPresetID
            : DefaultRoster.coreCouncilPresetID
        let chosenPreset = preset
            ?? presets.first(where: { $0.id == (forceMode != nil ? defaultPresetIDForMode : preferences.activePresetID) })
            ?? presets.first
        if let chosenPreset {
            preferences.activePresetID = chosenPreset.id
        }
        if let forceMode {
            preferences.defaultMode = forceMode
        }
        store.savePreferences(preferences)

        var fresh = Self.makeBlankSession(
            presets: chosenPreset.map { [$0] } ?? presets,
            personas: personas,
            prefs: preferences
        )
        fresh.mode = modeToUse
        if modeToUse == .build {
            fresh.cliToolsEnabled = true
        }
        sessions.insert(fresh, at: 0)
        selectedSessionID = fresh.id
        lastErrorBanner = nil
        store.saveSession(fresh)
    }

    func createNewTaskBuildSession() {
        let taskPreset = presets.first(where: { $0.id == DefaultRoster.taskBuildCrewPresetID })
        createNewSession(preset: taskPreset, forceMode: .build)
    }

    func selectSession(_ id: UUID) {
        guard selectedSessionID != id else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        selectedSessionID = id
        lastErrorBanner = nil
    }

    func deleteSession(_ id: UUID) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        if currentSession?.id == id {
            stopCurrentRun()
        }
        sessions.removeAll { $0.id == id }
        store.deleteSession(id: id)
        if sessions.isEmpty {
            createNewSession()
        } else if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }
    }

    func applyPresetToCurrentSession(_ preset: PanelPreset) {
        preferences.activePresetID = preset.id
        let isTaskPreset = (preset.id == DefaultRoster.taskBuildCrewPresetID || preset.id == DefaultRoster.fullStackSquadPresetID)
        store.savePreferences(preferences)
        guard var session = currentSession, !session.stage.isBusy else { return }
        session.moderatorID = preset.moderatorID
        session.debaterIDs = preset.debaterIDs
        if session.entries.isEmpty {
            session.mode = isTaskPreset ? .build : .debate
            if isTaskPreset { session.cliToolsEnabled = true }
        }
        session.updatedAt = Date()
        updateSessionInPlace(session)
    }

    func updateCurrentSessionLineup(moderatorID: UUID, debaterIDs: [UUID]) {
        guard var session = currentSession, !session.stage.isBusy else { return }
        session.moderatorID = moderatorID
        session.debaterIDs = debaterIDs
        session.updatedAt = Date()
        updateSessionInPlace(session)
    }

    func setCurrentSessionWebSearch(_ allowed: Bool) {
        preferences.defaultAllowWebSearch = allowed
        store.savePreferences(preferences)
        guard var session = currentSession else { return }
        session.allowWebSearch = allowed
        updateSessionInPlace(session)
    }

    func setCurrentSessionMode(_ mode: CouncilMode) {
        preferences.defaultMode = mode
        store.savePreferences(preferences)
        guard var session = currentSession, !session.stage.isBusy else { return }
        session.mode = mode
        if mode == .build {
            session.cliToolsEnabled = true
            // On a blank session still seated with the default Debate Council, auto-seat the Task & Build Crew!
            if session.entries.isEmpty,
               session.moderatorID == DefaultRoster.veraID,
               Set(session.debaterIDs) == Set([DefaultRoster.marcusID, DefaultRoster.sableID, DefaultRoster.orionID]),
               let taskPreset = presets.first(where: { $0.id == DefaultRoster.taskBuildCrewPresetID }) {
                session.moderatorID = taskPreset.moderatorID
                session.debaterIDs = taskPreset.debaterIDs
                preferences.activePresetID = taskPreset.id
                store.savePreferences(preferences)
            }
        } else if mode == .debate {
            // If toggling back to Debate on a blank session seated with the Task & Build Crew, auto-seat The Core Council!
            if session.entries.isEmpty,
               session.moderatorID == DefaultRoster.atlasID,
               Set(session.debaterIDs) == Set([DefaultRoster.forgeID, DefaultRoster.emberID, DefaultRoster.rookID]),
               let debatePreset = presets.first(where: { $0.id == DefaultRoster.coreCouncilPresetID }) {
                session.moderatorID = debatePreset.moderatorID
                session.debaterIDs = debatePreset.debaterIDs
                preferences.activePresetID = debatePreset.id
                store.savePreferences(preferences)
            }
        }
        updateSessionInPlace(session)
    }

    func setCurrentSessionCLITools(_ enabled: Bool) {
        preferences.defaultCLIToolsEnabled = enabled
        store.savePreferences(preferences)
        guard var session = currentSession else { return }
        session.cliToolsEnabled = enabled
        updateSessionInPlace(session)
    }

    func setCurrentSessionWorkspace(_ path: String, explicitBuildSelection: Bool = false) {
        preferences.defaultWorkspacePath = path
        var recents = preferences.recentWorkspacePaths ?? []
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        preferences.recentWorkspacePaths = Array(recents.prefix(8))
        store.savePreferences(preferences)

        guard var session = currentSession else { return }
        session.workspacePath = path
        if explicitBuildSelection || !WorkspaceResolver.isParentReposContainer(path) {
            session.hasExplicitBuildFolder = true
        }
        updateSessionInPlace(session)
    }

    @discardableResult
    func chooseWorkspaceFolderWithPanel(forBuild: Bool = false) -> String? {
        let panel = NSOpenPanel()
        panel.title = forBuild ? "Select or Create Project Build Folder" : "Choose Workspace or Repository Folder"
        panel.message = forBuild
            ? "Pick an existing project folder or click 'New Folder' to create a fresh directory for the council to build in."
            : "Choose a local repository or workspace folder for CLI inspection."
        panel.prompt = forBuild ? "Select Build Folder" : "Select Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let current = currentSession?.workspacePath {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        if panel.runModal() == .OK, let url = panel.url {
            setCurrentSessionWorkspace(url.path, explicitBuildSelection: true)
            return url.path
        }
        return nil
    }

    func openFolderInFinder(_ path: String) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    var quickSwitchRepoPaths: [String] {
        var result: [String] = []
        let root = WorkspaceResolver.defaultWorkspacePath()
        result.append(root)
        for recent in (preferences.recentWorkspacePaths ?? []) where !result.contains(recent) {
            result.append(recent)
        }
        if let items = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
                .prefix(10)
                .map(\.path)
            for d in dirs where !result.contains(d) {
                result.append(d)
            }
        }
        return result
    }

    func setCurrentSessionRounds(_ rounds: Int) {
        preferences.defaultMaxRebuttalRounds = rounds
        store.savePreferences(preferences)
        guard var session = currentSession else { return }
        session.maxRebuttalRounds = rounds
        updateSessionInPlace(session)
    }

    func setCurrentSessionCompletenessReview(_ enabled: Bool) {
        preferences.defaultCompletenessReviewEnabled = enabled
        store.savePreferences(preferences)
        guard var session = currentSession else { return }
        session.completenessReviewEnabled = enabled
        if session.completenessReviewerID == nil {
            session.completenessReviewerID = preferences.defaultCompletenessReviewerID ?? DefaultRoster.wardenID
        }
        updateSessionInPlace(session)
    }

    func setCurrentSessionCompletenessReviewer(_ personaID: UUID) {
        preferences.defaultCompletenessReviewerID = personaID
        preferences.defaultCompletenessReviewEnabled = true
        store.savePreferences(preferences)
        guard var session = currentSession else { return }
        session.completenessReviewerID = personaID
        session.completenessReviewEnabled = true
        updateSessionInPlace(session)
    }

    // MARK: - Chat Image Paste, Drag-and-Drop & File Attachment

    var currentPendingAttachments: [ChatImageAttachment] {
        guard let sessionID = currentSession?.id else { return [] }
        return pendingAttachmentsBySession[sessionID] ?? []
    }

    func removePendingAttachment(_ attachmentID: UUID) {
        guard let sessionID = currentSession?.id else { return }
        pendingAttachmentsBySession[sessionID]?.removeAll { $0.id == attachmentID }
    }

    func attachImagesWithOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Attach Image(s) or Screenshots"
        panel.message = "Choose one or more screenshots, mockups, or diagrams for the council to inspect."
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            _ = attachImagesFromURLs(panel.urls)
        }
    }

    @discardableResult
    func attachImagesFromURLs(_ urls: [URL]) -> Int {
        guard let sessionID = currentSession?.id else { return 0 }
        var current = pendingAttachmentsBySession[sessionID] ?? []
        var added = 0
        for url in urls where SessionStore.isSupportedImageURL(url) {
            if current.count >= 8 { break }
            if let imported = try? store.importImageFile(from: url) {
                current.append(imported)
                added += 1
            }
        }
        if added > 0 {
            pendingAttachmentsBySession[sessionID] = current
        }
        return added
    }

    @discardableResult
    func attachImageData(_ data: Data, preferredName: String = "Pasted-Image") -> Bool {
        guard let sessionID = currentSession?.id else { return false }
        var current = pendingAttachmentsBySession[sessionID] ?? []
        guard current.count < 8 else { return false }
        guard let saved = try? store.saveImageData(data, preferredName: preferredName) else { return false }
        current.append(saved)
        pendingAttachmentsBySession[sessionID] = current
        return true
    }

    /// Extracts copied image files (from Finder) or raw clipboard bitmaps/screenshots (`⌘⌃⇧4`, CleanShot, browser Copy Image)
    /// and stages them onto the current session's composer. Returns `true` if at least one image was attached.
    @discardableResult
    func attachImagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        // 1. Check copied image file URLs from Finder first
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let imageURLs = urls.filter { SessionStore.isSupportedImageURL($0) }
            if !imageURLs.isEmpty {
                return attachImagesFromURLs(imageURLs) > 0
            }
        }

        // 2. If the clipboard holds plain text without image bitmap data, let normal text paste run!
        let hasPNG = pasteboard.data(forType: .png) != nil
        let hasTIFF = pasteboard.data(forType: .tiff) != nil
        guard hasPNG || hasTIFF else { return false }

        // Note: Some rich-text apps place BOTH plain string text and an icon/thumbnail TIFF on the pasteboard;
        // if plain non-empty text exists AND there is no raw PNG screenshot data, prefer pasting the text unless NSImage is large.
        let plainText = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !plainText.isEmpty && !hasPNG {
            return false
        }

        let timestamp = Self.pasteTimestampLabel()
        if let pngData = pasteboard.data(forType: .png) {
            return attachImageData(pngData, preferredName: "Screenshot-\(timestamp)")
        }
        if let tiffData = pasteboard.data(forType: .tiff) {
            if let rep = NSBitmapImageRep(data: tiffData),
               let pngData = rep.representation(using: .png, properties: [:]) {
                return attachImageData(pngData, preferredName: "Screenshot-\(timestamp)")
            }
            return attachImageData(tiffData, preferredName: "Screenshot-\(timestamp)")
        }
        return false
    }

    private static func pasteTimestampLabel() -> String {
        let f = DateFormatter()
        f.dateFormat = "HHmmss"
        return f.string(from: Date())
    }

    func togglePersonaSpecialty(personaID: UUID, specialty: String) {
        guard var target = persona(for: personaID) else { return }
        var tags = target.activeSpecialties
        if let existingIdx = tags.firstIndex(where: { $0.caseInsensitiveCompare(specialty) == .orderedSame }) {
            tags.remove(at: existingIdx)
        } else {
            tags.append(specialty)
        }
        target.taskSpecialties = tags.isEmpty ? nil : tags
        upsertPersona(target)
    }

    // MARK: - Running Debates & Interviews

    func sendPrompt(_ text: String, skipInterview: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stagedAttachments = currentPendingAttachments
        guard (!trimmed.isEmpty || !stagedAttachments.isEmpty), var session = currentSession, !session.stage.isBusy else { return }

        // In Build Mode, if no dedicated project folder was picked yet (still pointing at parent repos root),
        // prompt the user right now so they can pick a project directory or click 'New Folder' to create one!
        if session.activeMode == .build
            && session.hasExplicitBuildFolder != true
            && WorkspaceResolver.isParentReposContainer(session.workspacePath) {
            guard chooseWorkspaceFolderWithPanel(forBuild: true) != nil,
                  let refreshed = currentSession else {
                return
            }
            session = refreshed
        }

        pendingAttachmentsBySession[session.id] = nil
        lastErrorBanner = nil
        voiceEngine.stopAll()

        let moderator = activeModerator(for: session)
        let debaters = activeDebaters(for: session)
        let roster = personas
        let labels = allModelLabelsByID
        let orKey = KeychainHelper.read(account: "openrouter")

        activeRunTask?.cancel()
        activeRunTask = Task { [weak self] in
            guard let self else { return }
            do {
                let finalSession = try await self.orchestrator.submitUserMessage(
                    text: trimmed,
                    attachments: stagedAttachments,
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
                    allPersonas: roster,
                    modelLabels: labels,
                    openRouterKey: orKey,
                    skipInterview: skipInterview
                ) { [weak self] event in
                    await self?.handleOrchestratorEvent(event)
                }
                self.updateSessionInPlace(finalSession)
                self.activeThinkerIDs = []
            } catch is CancellationError {
                self.markSessionStopped(session.id)
            } catch let err as ModelRunnerError {
                if case .cancelled = err {
                    self.markSessionStopped(session.id)
                } else {
                    self.recordError(err.localizedDescription, on: session.id)
                }
            } catch {
                self.recordError(error.localizedDescription, on: session.id)
            }
        }
    }

    func submitInterview(exchangeID: UUID, questions: [InterviewQuestion], skipped: Bool) {
        guard let session = currentSession, !session.stage.isBusy else { return }
        lastErrorBanner = nil
        voiceEngine.stopAll()

        let moderator = activeModerator(for: session)
        let debaters = activeDebaters(for: session)
        let roster = personas
        let labels = allModelLabelsByID
        let orKey = KeychainHelper.read(account: "openrouter")

        activeRunTask?.cancel()
        activeRunTask = Task { [weak self] in
            guard let self else { return }
            do {
                let finalSession = try await self.orchestrator.submitInterviewAnswers(
                    exchangeID: exchangeID,
                    updatedQuestions: questions,
                    skipped: skipped,
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
                    allPersonas: roster,
                    modelLabels: labels,
                    openRouterKey: orKey
                ) { [weak self] event in
                    await self?.handleOrchestratorEvent(event)
                }
                self.updateSessionInPlace(finalSession)
                self.activeThinkerIDs = []
            } catch is CancellationError {
                self.markSessionStopped(session.id)
            } catch let err as ModelRunnerError {
                if case .cancelled = err {
                    self.markSessionStopped(session.id)
                } else {
                    self.recordError(err.localizedDescription, on: session.id)
                }
            } catch {
                self.recordError(error.localizedDescription, on: session.id)
            }
        }
    }

    func resumeCurrentSession() {
        guard let session = currentSession, !session.stage.isBusy else { return }
        lastErrorBanner = nil
        voiceEngine.stopAll()

        let moderator = activeModerator(for: session)
        let debaters = activeDebaters(for: session)
        let roster = personas
        let labels = allModelLabelsByID
        let orKey = KeychainHelper.read(account: "openrouter")

        activeRunTask?.cancel()
        activeRunTask = Task { [weak self] in
            guard let self else { return }
            do {
                let finalSession = try await self.orchestrator.resumeInterruptedDebate(
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
                    allPersonas: roster,
                    modelLabels: labels,
                    openRouterKey: orKey
                ) { [weak self] event in
                    await self?.handleOrchestratorEvent(event)
                }
                self.updateSessionInPlace(finalSession)
                self.activeThinkerIDs = []
            } catch is CancellationError {
                self.markSessionStopped(session.id)
            } catch let err as ModelRunnerError {
                if case .cancelled = err {
                    self.markSessionStopped(session.id)
                } else {
                    self.recordError(err.localizedDescription, on: session.id)
                }
            } catch {
                self.recordError(error.localizedDescription, on: session.id)
            }
        }
    }

    func openBuildLaunchSheet(for verdict: CosignVerdict) {
        activeBuildLaunchVerdict = verdict
    }

    func startBuildFromVerdict(_ verdict: CosignVerdict, targetFolder: String, extraNote: String = "") {
        guard currentSession != nil else { return }
        setCurrentSessionWorkspace(targetFolder, explicitBuildSelection: true)
        guard var session = currentSession, !session.stage.isBusy else { return }
        session.mode = .build
        session.cliToolsEnabled = true
        session.workspacePath = targetFolder
        session.hasExplicitBuildFolder = true
        updateSessionInPlace(session)

        lastErrorBanner = nil
        voiceEngine.stopAll()

        let moderator = activeModerator(for: session)
        let debaters = activeDebaters(for: session)
        let roster = personas
        let labels = allModelLabelsByID
        let orKey = KeychainHelper.read(account: "openrouter")

        activeRunTask?.cancel()
        activeRunTask = Task { [weak self] in
            guard let self else { return }
            do {
                let finalSession = try await self.orchestrator.executeVerdictPlan(
                    verdictID: verdict.id,
                    extraInstruction: extraNote,
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
                    allPersonas: roster,
                    modelLabels: labels,
                    openRouterKey: orKey
                ) { [weak self] event in
                    await self?.handleOrchestratorEvent(event)
                }
                self.updateSessionInPlace(finalSession)
                self.activeThinkerIDs = []
            } catch is CancellationError {
                self.markSessionStopped(session.id)
            } catch let err as ModelRunnerError {
                if case .cancelled = err {
                    self.markSessionStopped(session.id)
                } else {
                    self.recordError(err.localizedDescription, on: session.id)
                }
            } catch {
                self.recordError(error.localizedDescription, on: session.id)
            }
        }
    }

    func executeVerdict(_ verdict: CosignVerdict) {
        openBuildLaunchSheet(for: verdict)
    }

    func openHandoffSheet(for verdict: CosignVerdict? = nil) {
        if let verdict {
            activeHandoffVerdict = verdict
            return
        }
        if let current = currentSession {
            for entry in current.entries.reversed() {
                if case .verdict(let v) = entry {
                    activeHandoffVerdict = v
                    return
                }
            }
        }
    }

    func generateTailoredHandoff(baseHandoff: String, customInstruction: String) async throws -> String {
        guard let session = currentSession else { return baseHandoff }
        let moderator = activeModerator(for: session)
        let orKey = KeychainHelper.read(account: "openrouter")
        return try await orchestrator.synthesizeTailoredHandoffPrompt(
            session: session,
            moderator: moderator,
            baseHandoff: baseHandoff,
            customInstruction: customInstruction,
            openRouterKey: orKey
        )
    }

    func stopCurrentRun() {
        activeRunTask?.cancel()
        activeRunTask = nil
        activeThinkerIDs = []
        liveStatusText = ""
        voiceEngine.stopAll()
        if let id = selectedSessionID {
            markSessionStopped(id)
        }
    }

    private func handleOrchestratorEvent(_ event: OrchestratorEvent) async {
        switch event {
        case .sessionUpdated(let updated):
            updateSessionInPlace(updated)
        case .activeThinkersChanged(let ids, let label):
            activeThinkerIDs = ids
            liveStatusText = label
        case .enqueueSpeech(let item):
            if preferences.autoSpeakResponses && !voiceEngine.isMuted {
                voiceEngine.enqueue(item)
            }
        }
    }

    private func updateSessionInPlace(_ updated: DebateSession) {
        if let idx = sessions.firstIndex(where: { $0.id == updated.id }) {
            sessions[idx] = updated
        } else {
            sessions.insert(updated, at: 0)
        }
        store.saveSession(updated)
    }

    private func markSessionStopped(_ sessionID: UUID) {
        activeThinkerIDs = []
        liveStatusText = ""
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if sessions[idx].stage.isBusy {
            sessions[idx].stage = .cancelled
            sessions[idx].updatedAt = Date()
            store.saveSession(sessions[idx])
        }
    }

    private func recordError(_ message: String, on sessionID: UUID) {
        activeThinkerIDs = []
        liveStatusText = ""
        lastErrorBanner = message
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[idx].stage = .error
        sessions[idx].entries.append(.systemNote(UUID(), message))
        sessions[idx].updatedAt = Date()
        store.saveSession(sessions[idx])
    }

    // MARK: - Audio Actions

    func replayTurn(_ turn: DebateTurn) {
        let speaker = persona(for: turn.personaID) ?? Persona(
            id: turn.personaID,
            name: turn.personaName,
            title: turn.personaTitle,
            tagline: "",
            role: .debater,
            provider: turn.provider,
            modelID: turn.modelLabel,
            personality: "",
            debateStyle: "",
            accentHex: turn.accentHex,
            avatarSymbol: turn.avatarSymbol,
            voicePresetID: "vera"
        )
        voiceEngine.isMuted = false
        voiceEngine.speakImmediately(SpeechQueueItem(
            id: turn.id,
            persona: speaker,
            spokenText: turn.spokenTake,
            contextLabel: "Replaying · \(speaker.name)"
        ))
    }

    func replayVerdict(_ verdict: CosignVerdict) {
        let mod = persona(for: verdict.moderatorID) ?? DefaultRoster.personas[0]
        voiceEngine.isMuted = false
        voiceEngine.speakImmediately(SpeechQueueItem(
            id: verdict.id,
            persona: mod,
            spokenText: verdict.spokenVerdict,
            contextLabel: "Verdict · \(mod.name)"
        ))
    }

    func playFullSessionAudio(_ session: DebateSession) {
        voiceEngine.stopAll()
        voiceEngine.isMuted = false
        var batch: [SpeechQueueItem] = []
        for entry in session.entries {
            switch entry {
            case .turn(let t):
                let speaker = persona(for: t.personaID) ?? DefaultRoster.personas[0]
                batch.append(SpeechQueueItem(
                    id: t.id,
                    persona: speaker,
                    spokenText: t.spokenTake,
                    contextLabel: "\(t.roundLabel) · \(speaker.name)"
                ))
            case .verdict(let v):
                let mod = persona(for: v.moderatorID) ?? DefaultRoster.personas[0]
                batch.append(SpeechQueueItem(
                    id: v.id,
                    persona: mod,
                    spokenText: v.spokenVerdict,
                    contextLabel: "Verdict · \(mod.name)"
                ))
            default:
                break
            }
        }
        voiceEngine.enqueueBatch(batch)
    }

    func previewPersonaVoice(_ persona: Persona) {
        let sample = "(laugh) Hi, I'm \(persona.name), \(persona.title). Bring me your sharpest idea or project folder and let's get to work."
        voiceEngine.isMuted = false
        voiceEngine.speakImmediately(SpeechQueueItem(
            id: UUID(),
            persona: persona,
            spokenText: sample,
            contextLabel: "Voice Preview · \(persona.name)"
        ))
    }

    func toggleAutoSpeak() {
        preferences.autoSpeakResponses.toggle()
        voiceEngine.isMuted = !preferences.autoSpeakResponses
        if preferences.autoSpeakResponses {
            voiceEngine.warmUpIfNeeded()
        } else {
            voiceEngine.stopAll()
        }
        store.savePreferences(preferences)
    }

    func setPlaybackSpeed(_ speed: Double) {
        preferences.playbackSpeed = speed
        voiceEngine.playbackSpeed = speed
        store.savePreferences(preferences)
    }

    // MARK: - Persona & Preset Editing

    func openStudio(for personaID: UUID? = nil) {
        studioInitialPersonaID = personaID ?? personas.first?.id
        showingPersonaStudio = true
    }

    func upsertPersona(_ persona: Persona) {
        if let idx = personas.firstIndex(where: { $0.id == persona.id }) {
            personas[idx] = persona
        } else {
            personas.append(persona)
        }
        store.savePersonas(personas)
    }

    func deletePersona(_ id: UUID) {
        // Keep at least 1 moderator and 2 debaters
        guard let target = persona(for: id), !target.isBuiltIn else { return }
        personas.removeAll { $0.id == id }
        store.savePersonas(personas)
        if preferences.defaultCompletenessReviewerID == id {
            preferences.defaultCompletenessReviewerID = DefaultRoster.wardenID
            store.savePreferences(preferences)
        }
        for idx in sessions.indices where sessions[idx].completenessReviewerID == id {
            sessions[idx].completenessReviewerID = DefaultRoster.wardenID
            store.saveSession(sessions[idx])
        }
    }

    func upsertPreset(_ preset: PanelPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
        } else {
            presets.append(preset)
        }
        store.savePresets(presets)
    }

    func deletePreset(_ id: UUID) {
        guard let target = presets.first(where: { $0.id == id }), !target.isBuiltIn else { return }
        presets.removeAll { $0.id == id }
        store.savePresets(presets)
    }

    private static func makeBlankSession(presets: [PanelPreset], personas: [Persona], prefs: AppPreferences) -> DebateSession {
        let preset = presets.first(where: { $0.id == prefs.activePresetID }) ?? presets.first
        let modID = preset?.moderatorID
            ?? personas.first(where: { $0.role == .moderator })?.id
            ?? DefaultRoster.veraID
        let debIDs = preset?.debaterIDs
            ?? Array(personas.filter { $0.role == .debater }.prefix(3).map(\.id))

        return DebateSession(
            moderatorID: modID,
            debaterIDs: debIDs,
            maxRebuttalRounds: prefs.defaultMaxRebuttalRounds,
            allowWebSearch: prefs.defaultAllowWebSearch,
            mode: prefs.defaultMode ?? .debate,
            completenessReviewEnabled: prefs.defaultCompletenessReviewEnabled ?? true,
            completenessReviewerID: prefs.defaultCompletenessReviewerID ?? DefaultRoster.wardenID,
            cliToolsEnabled: prefs.defaultCLIToolsEnabled ?? true,
            workspacePath: prefs.defaultWorkspacePath ?? WorkspaceResolver.defaultWorkspacePath()
        )
    }
}
