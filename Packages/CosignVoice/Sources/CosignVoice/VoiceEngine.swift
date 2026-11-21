import AVFoundation
import Combine
import CosignCore
import CryptoKit
import Foundation

/// Two-stage pipelined TTS engine:
/// 1. `synthesisWorkerTask` holds queued items until Chatterbox Turbo is ready and continuously
///    pre-synthesizes upcoming turns on Metal GPU *while* the current speaker is talking.
/// 2. `playbackWorkerTask` plays synthesized `.wav` clips back-to-back in strict FIFO order with
///    minimal dead air (~70ms breath) between personas.
@MainActor
public final class VoiceEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published public private(set) var daemonState: VoiceDaemonState = .idle
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isPaused: Bool = false
    @Published public private(set) var isSynthesizingNext: Bool = false
    @Published public var isMuted: Bool = false {
        didSet {
            audioPlayer?.volume = isMuted ? 0 : 1
        }
    }
    @Published public var playbackSpeed: Double = 1.08 {
        didSet {
            audioPlayer?.rate = Float(playbackSpeed)
        }
    }
    @Published public private(set) var activeItem: SpeechQueueItem?
    @Published public private(set) var queuedItems: [SpeechQueueItem] = []
    /// Normalized 0.0 ... 1.0 live vocal energy for pulsing speaker halos & dock equalizer bars.
    @Published public private(set) var speakerLevel: CGFloat = 0

    private let cacheDirectory: URL
    private let breezeRefsDirectory: URL
    private lazy var daemonClient: ChatterboxDaemonClient = ChatterboxDaemonClient(refsDirectory: breezeRefsDirectory) { [weak self] newState in
        Task { @MainActor in
            self?.daemonState = newState
        }
    }

    private var pendingSynthQueue: [SpeechQueueItem] = []
    private var readyToPlayQueue: [(item: SpeechQueueItem, wavURL: URL?)] = []
    private var synthesisWorkerTask: Task<Void, Never>?
    private var playbackWorkerTask: Task<Void, Never>?

    private var audioPlayer: AVAudioPlayer?
    private var meterTimer: Timer?
    private var currentTurnContinuation: CheckedContinuation<Void, Never>?

    public init(cacheRoot: URL = SessionStore.defaultRootDirectory()) {
        self.cacheDirectory = cacheRoot.appendingPathComponent("AudioCache", isDirectory: true)
        self.breezeRefsDirectory = cacheRoot.appendingPathComponent("BreezeRefs", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: breezeRefsDirectory, withIntermediateDirectories: true)
    }

    public func warmUpIfNeeded() {
        if case .idle = daemonState {
            daemonState = .starting("Starting Breeze TTS 2 (Metal)…")
        }
        let client = daemonClient
        Task {
            await client.start()
        }
    }

    public func shutdown() {
        stopAll()
        let client = daemonClient
        Task {
            await client.stop()
        }
    }

    // MARK: - Queue & Transport Controls

    /// Appends a turn to the continuous TTS pipeline. Holds until Chatterbox can synthesize it,
    /// and pre-synthesizes ahead in the background while earlier turns are speaking.
    public func enqueue(_ item: SpeechQueueItem) {
        let trimmed = item.spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        warmUpIfNeeded()
        pendingSynthQueue.append(item)
        syncPublishedQueueCount()
        ensureSynthesisWorkerRunning()
        ensurePlaybackWorkerRunning()
    }

    public func enqueueBatch(_ items: [SpeechQueueItem]) {
        guard !items.isEmpty else { return }
        warmUpIfNeeded()
        for item in items where !item.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingSynthQueue.append(item)
        }
        syncPublishedQueueCount()
        ensureSynthesisWorkerRunning()
        ensurePlaybackWorkerRunning()
    }

    public func speakImmediately(_ item: SpeechQueueItem) {
        stopAll()
        enqueue(item)
    }

    public func togglePlayPause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            isPaused = true
        } else {
            player.enableRate = true
            player.rate = Float(playbackSpeed)
            player.play()
            isPlaying = true
            isPaused = false
        }
    }

    public func skipCurrent() {
        stopCurrentOnly()
    }

    public func stopAll() {
        pendingSynthQueue.removeAll()
        readyToPlayQueue.removeAll()
        queuedItems.removeAll()
        isSynthesizingNext = false

        synthesisWorkerTask?.cancel()
        synthesisWorkerTask = nil
        playbackWorkerTask?.cancel()
        playbackWorkerTask = nil
        stopCurrentOnly()
    }

    private func syncPublishedQueueCount() {
        queuedItems = readyToPlayQueue.map(\.item) + pendingSynthQueue
    }

    // MARK: - Stage 1: Background Ahead-of-Time Synthesis Worker

    private func ensureSynthesisWorkerRunning() {
        guard synthesisWorkerTask == nil else { return }
        synthesisWorkerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard !self.pendingSynthQueue.isEmpty else { break }
                let item = self.pendingSynthQueue.removeFirst()
                self.isSynthesizingNext = true

                let wavURL = await self.synthesizeOrFetchCached(for: item)
                if Task.isCancelled { break }

                self.readyToPlayQueue.append((item: item, wavURL: wavURL))
                self.isSynthesizingNext = !self.pendingSynthQueue.isEmpty
                self.syncPublishedQueueCount()
                self.ensurePlaybackWorkerRunning()
            }
            self.isSynthesizingNext = false
            self.synthesisWorkerTask = nil
        }
    }

    private func synthesizeOrFetchCached(for item: SpeechQueueItem) async -> URL? {
        let cachedURL = cachedAudioURL(for: item)
        if FileManager.default.fileExists(atPath: cachedURL.path),
           ((try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.size] as? Int) ?? 0) > 1024 {
            return cachedURL
        }
        let normalizedText = ExpressiveTagFormatter.normalizeForBreeze(item.spokenText)
        let customPath = (item.persona.customVoicePath?.isEmpty == false) ? item.persona.customVoicePath : nil
        let client = daemonClient
        let ok = await client.synthesize(
            text: normalizedText,
            presetID: item.persona.voicePresetID,
            customVoicePath: customPath,
            exaggeration: item.persona.voiceExaggeration,
            outputURL: cachedURL
        )
        if ok, FileManager.default.fileExists(atPath: cachedURL.path) {
            return cachedURL
        }
        return nil
    }

    // MARK: - Stage 2: Continuous Gapless Audio Playback Worker

    private func ensurePlaybackWorkerRunning() {
        guard playbackWorkerTask == nil else { return }
        playbackWorkerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if self.readyToPlayQueue.isEmpty {
                    // If synthesis is still working on upcoming queued turns, hold and wait seamlessly!
                    if !self.pendingSynthQueue.isEmpty || self.isSynthesizingNext || self.synthesisWorkerTask != nil {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        continue
                    } else {
                        break
                    }
                }

                let nextPair = self.readyToPlayQueue.removeFirst()
                self.syncPublishedQueueCount()
                self.activeItem = nextPair.item

                if let wavURL = nextPair.wavURL, FileManager.default.fileExists(atPath: wavURL.path) {
                    await self.playWAV(url: wavURL)
                }

                if Task.isCancelled { break }
                self.activeItem = nil
                self.speakerLevel = 0
                // Minimal 70ms breath between speakers so voices flow continuously like a live roundtable
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
            self.activeItem = nil
            self.isPlaying = false
            self.isPaused = false
            self.speakerLevel = 0
            self.playbackWorkerTask = nil
        }
    }

    private func playWAV(url: URL) async {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.enableRate = true
            player.rate = Float(playbackSpeed)
            player.volume = isMuted ? 0 : 1
            player.isMeteringEnabled = true
            player.prepareToPlay()
            self.audioPlayer = player
            self.isPlaying = true
            self.isPaused = false
            startMetering()

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                self.currentTurnContinuation = cont
                if !player.play() {
                    self.currentTurnContinuation = nil
                    cont.resume()
                }
            }
            stopMetering()
            self.audioPlayer = nil
            self.isPlaying = false
        } catch {
            stopMetering()
            self.audioPlayer = nil
            self.isPlaying = false
        }
    }

    private func stopCurrentOnly() {
        stopMetering()
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        isPaused = false
        speakerLevel = 0
        if let cont = currentTurnContinuation {
            currentTurnContinuation = nil
            cont.resume()
        }
    }

    // MARK: - Metering & Delegates

    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.audioPlayer else { return }
                if player.isPlaying {
                    player.updateMeters()
                    let power = player.averagePower(forChannel: 0)
                    let normalized = max(0, min(1, (power + 45) / 42))
                    self.speakerLevel = CGFloat(normalized)
                } else if !self.isPaused {
                    // Safety net in case AVAudioPlayer finishes without firing delegate
                    if let cont = self.currentTurnContinuation {
                        self.currentTurnContinuation = nil
                        cont.resume()
                    }
                }
            }
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if let cont = self.currentTurnContinuation {
                self.currentTurnContinuation = nil
                cont.resume()
            }
        }
    }

    // MARK: - Paths & Seeds

    public func resolveReferenceAudioPath(for persona: Persona) -> String? {
        if let custom = persona.customVoicePath, !custom.isEmpty, FileManager.default.fileExists(atPath: custom) {
            return custom
        }
        let preset = VoicePreset.all.first { $0.id == persona.voicePresetID } ?? VoicePreset.all[0]
        let baseName = (preset.seedFilename as NSString).deletingPathExtension
        if let url = Bundle.module.url(forResource: baseName, withExtension: "wav", subdirectory: "VoiceSeeds") {
            return url.path
        }
        if let url = Bundle.module.url(forResource: baseName, withExtension: "wav") {
            return url.path
        }
        return nil
    }

    private func cachedAudioURL(for item: SpeechQueueItem) -> URL {
        let normalized = ExpressiveTagFormatter.normalizeForBreeze(item.spokenText)
        let keyString = "breeze2-v1|\(item.persona.voicePresetID)|\(item.persona.customVoicePath ?? "")|\(String(format: "%.2f", item.persona.voiceExaggeration))|\(normalized)"
        let digest = SHA256.hash(data: Data(keyString.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("breeze-\(hex).wav")
    }
}

// MARK: - Background Actor Managing Python MLX Breeze TTS 2 Daemon (Zero Pipe Deadlock + Auto-Recovery)

actor ChatterboxDaemonClient {
    private let refsDirectory: URL
    private let onStateChange: @Sendable (VoiceDaemonState) -> Void
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [String: CheckedContinuation<Bool, Never>] = [:]
    private var isReady: Bool = false
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var missingRuntimePermanently: Bool = false

    init(refsDirectory: URL, onStateChange: @escaping @Sendable (VoiceDaemonState) -> Void) {
        self.refsDirectory = refsDirectory
        self.onStateChange = onStateChange
    }

    func start() async {
        if let process, process.isRunning { return }
        guard !missingRuntimePermanently else { return }

        guard let scriptURL = Bundle.module.url(forResource: "voice_daemon", withExtension: "py") else {
            missingRuntimePermanently = true
            onStateChange(.fallbackSystemVoice("Voice daemon script missing"))
            resumeReadyWaiters(false)
            return
        }

        guard let uvBinary = BinaryLocator.findBinary("uv") else {
            missingRuntimePermanently = true
            onStateChange(.fallbackSystemVoice("Install `uv` to enable Breeze TTS 2 MLX"))
            resumeReadyWaiters(false)
            return
        }

        onStateChange(.starting("Warming up Breeze TTS 2 (Metal)…"))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uvBinary)
        proc.arguments = [
            "run",
            "--python", "3.12",
            "--with", "mlx-audio>=0.6.0",
            "--with", "soundfile",
            "--with", "numpy",
            "python",
            scriptURL.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.augmentedPATH()
        env["PYTHONUNBUFFERED"] = "1"
        env["TQDM_DISABLE"] = "1"
        env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        env["COSIGN_BREEZE_REFS_DIR"] = refsDirectory.path
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting
        self.isReady = false

        let lineBuffer = LockedBox(Data())

        // CRITICAL: Drain stderr continuously so Python/MLX/transformers can NEVER block on a full 64KB stderr pipe!
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            let lines: [String] = lineBuffer.withLock { buf in
                buf.append(chunk)
                var extracted: [String] = []
                while let nlIndex = buf.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buf.subdata(in: 0..<nlIndex)
                    buf.removeSubrange(0...nlIndex)
                    if let str = String(data: lineData, encoding: .utf8) {
                        extracted.append(str)
                    }
                }
                return extracted
            }
            for line in lines {
                Task {
                    await self?.handleDaemonLine(line)
                }
            }
        }

        proc.terminationHandler = { [weak self] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            Task {
                await self?.handleDaemonTerminated()
            }
        }

        do {
            try proc.run()
        } catch {
            process = nil
            stdinHandle = nil
            onStateChange(.fallbackSystemVoice("Voice daemon launch error"))
            resumeReadyWaiters(false)
        }
    }

    func stop() {
        if let stdinHandle, let quitData = "{\"cmd\":\"quit\"}\n".data(using: .utf8) {
            try? stdinHandle.write(contentsOf: quitData)
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        isReady = false
    }

    func synthesize(text: String, presetID: String, customVoicePath: String?, exaggeration: Double, outputURL: URL) async -> Bool {
        if missingRuntimePermanently { return false }
        for attempt in 0..<2 {
            if await synthesizeSingleAttempt(text: text, presetID: presetID, customVoicePath: customVoicePath, exaggeration: exaggeration, outputURL: outputURL) {
                return true
            }
            if attempt == 0 {
                // Restart daemon cleanly on transient failure and retry once
                stop()
            }
        }
        return false
    }

    private func synthesizeSingleAttempt(text: String, presetID: String, customVoicePath: String?, exaggeration: Double, outputURL: URL) async -> Bool {
        if !isReady || process?.isRunning != true {
            await start()
            let becameReady = await waitForReady()
            guard becameReady else { return false }
        }
        guard let stdinHandle else { return false }

        let reqID = UUID().uuidString
        var payload: [String: Any] = [
            "id": reqID,
            "cmd": "synthesize",
            "text": text,
            "preset_id": presetID,
            "exaggeration": exaggeration,
            "out_path": outputURL.path
        ]
        if let customVoicePath {
            payload["custom_voice"] = customVoicePath
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              var lineData = String(data: jsonData, encoding: .utf8)?.data(using: .utf8) else {
            return false
        }
        lineData.append(UInt8(ascii: "\n"))

        return await withCheckedContinuation { cont in
            pending[reqID] = cont
            do {
                try stdinHandle.write(contentsOf: lineData)
            } catch {
                pending.removeValue(forKey: reqID)
                cont.resume(returning: false)
            }
        }
    }

    private func waitForReady() async -> Bool {
        if isReady { return true }
        if missingRuntimePermanently { return false }
        return await withCheckedContinuation { cont in
            readyWaiters.append(cont)
        }
    }

    private func resumeReadyWaiters(_ value: Bool) {
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for w in waiters {
            w.resume(returning: value)
        }
    }

    private func handleDaemonLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = json["event"] as? String else {
            return
        }
        if event == "status" {
            let state = (json["state"] as? String) ?? ""
            let msg = (json["message"] as? String) ?? ""
            if state == "ready" {
                isReady = true
                onStateChange(.ready)
                resumeReadyWaiters(true)
            } else if state == "starting" {
                onStateChange(.starting(msg))
            } else if state == "error" {
                onStateChange(.fallbackSystemVoice("Breeze TTS 2 reload needed"))
                resumeReadyWaiters(false)
            }
        } else if event == "done" {
            let id = (json["id"] as? String) ?? ""
            let ok = (json["ok"] as? Bool) ?? false
            if let cont = pending.removeValue(forKey: id) {
                cont.resume(returning: ok)
            }
        }
    }

    private func handleDaemonTerminated() {
        isReady = false
        process = nil
        stdinHandle = nil
        resumeReadyWaiters(false)
        let allPending = pending
        pending.removeAll()
        for (_, cont) in allPending {
            cont.resume(returning: false)
        }
    }
}
