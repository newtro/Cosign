import AppKit
import Combine
import CosignCore
import CosignVoice
import SwiftUI

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

    func createNewSession(preset: PanelPreset? = nil) {
        stopCurrentRun()
        let chosenPreset = preset
            ?? presets.first(where: { $0.id == preferences.activePresetID })
            ?? presets.first
        if let chosenPreset {
            preferences.activePresetID = chosenPreset.id
            store.savePreferences(preferences)
        }
        let fresh = Self.makeBlankSession(
            presets: chosenPreset.map { [$0] } ?? presets,
            personas: personas,
            prefs: preferences
        )
        sessions.insert(fresh, at: 0)
        selectedSessionID = fresh.id
        lastErrorBanner = nil
        store.saveSession(fresh)
    }

    func selectSession(_ id: UUID) {
        guard selectedSessionID != id else { return }
        selectedSessionID = id
        lastErrorBanner = nil
    }

    func deleteSession(_ id: UUID) {
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
        store.savePreferences(preferences)
        guard var session = currentSession, !session.stage.isBusy else { return }
        session.moderatorID = preset.moderatorID
        session.debaterIDs = preset.debaterIDs
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

    func setCurrentSessionCLITools(_ enabled: Bool) {
        preferences.defaultCLIToolsEnabled = enabled
        store.savePreferences(preferences)
        guard var session = currentSession else { return }
        session.cliToolsEnabled = enabled
        updateSessionInPlace(session)
    }

    func setCurrentSessionWorkspace(_ path: String) {
        preferences.defaultWorkspacePath = path
        var recents = preferences.recentWorkspacePaths ?? []
        recents.removeAll { $0 == path }
        recents.insert(path, at: 0)
        preferences.recentWorkspacePaths = Array(recents.prefix(8))
        store.savePreferences(preferences)

        guard var session = currentSession else { return }
        session.workspacePath = path
        updateSessionInPlace(session)
    }

    func chooseWorkspaceFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Workspace or Repository Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if let current = currentSession?.workspacePath {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        if panel.runModal() == .OK, let url = panel.url {
            setCurrentSessionWorkspace(url.path)
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

    // MARK: - Running Debates & Interviews

    func sendPrompt(_ text: String, skipInterview: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = currentSession, !session.stage.isBusy else { return }

        lastErrorBanner = nil
        voiceEngine.stopAll()

        let moderator = activeModerator(for: session)
        let debaters = activeDebaters(for: session)
        let labels = allModelLabelsByID
        let orKey = KeychainHelper.read(account: "openrouter")

        activeRunTask?.cancel()
        activeRunTask = Task { [weak self] in
            guard let self else { return }
            do {
                let finalSession = try await self.orchestrator.submitUserMessage(
                    text: trimmed,
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
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
        guard let session = currentSession, !session.stage.isBusy else { return }
        lastErrorBanner = nil
        voiceEngine.stopAll()

        let moderator = activeModerator(for: session)
        let debaters = activeDebaters(for: session)
        let labels = allModelLabelsByID
        let orKey = KeychainHelper.read(account: "openrouter")

        activeRunTask?.cancel()
        activeRunTask = Task { [weak self] in
            guard let self else { return }
            do {
                let finalSession = try await self.orchestrator.executeVerdictPlan(
                    verdictID: verdict.id,
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
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
        let sample = "[chuckle] Hi, I'm \(persona.name), \(persona.title). Bring me your sharpest half-baked idea and let's put it to the test."
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
            cliToolsEnabled: prefs.defaultCLIToolsEnabled ?? true,
            workspacePath: prefs.defaultWorkspacePath ?? WorkspaceResolver.defaultWorkspacePath()
        )
    }
}
