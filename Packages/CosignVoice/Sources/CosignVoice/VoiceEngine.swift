import AVFoundation
import Combine
import CosignCore
import CryptoKit
import Foundation

/// Manages the persistent local MLX Chatterbox Turbo daemon, pre-synthesizes queued turns so
/// transitions between speakers have zero dead air, and publishes live audio meter levels for UI rings.
@MainActor
public final class VoiceEngine: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    @Published public private(set) var daemonState: VoiceDaemonState = .idle
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var isPaused: Bool = false
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
    private var daemonClient: ChatterboxDaemonClient?
    private var audioPlayer: AVAudioPlayer?
    private let fallbackSynth = AVSpeechSynthesizer()
    private var meterTimer: Timer?
    private var playbackLoopTask: Task<Void, Never>?
    private var preSynthTasks: [UUID: Task<URL?, Never>] = [:]
    private var currentTurnContinuation: CheckedContinuation<Void, Never>?

    public init(cacheRoot: URL = SessionStore.defaultRootDirectory()) {
        self.cacheDirectory = cacheRoot.appendingPathComponent("AudioCache", isDirectory: true)
        super.init()
        self.fallbackSynth.delegate = self
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    public func warmUpIfNeeded() {
        guard daemonState == .idle else { return }
        daemonState = .starting("Starting Chatterbox Turbo (Metal)…")
        let client = ChatterboxDaemonClient { [weak self] newState in
            Task { @MainActor in
                self?.daemonState = newState
            }
        }
        self.daemonClient = client
        Task {
            await client.start()
        }
    }

    public func shutdown() {
        stopAll()
        let client = daemonClient
        daemonClient = nil
        Task {
            await client?.stop()
        }
    }

    // MARK: - Queue & Transport Controls

    public func enqueue(_ item: SpeechQueueItem) {
        warmUpIfNeeded()
        queuedItems.append(item)
        startPreSynthesis(for: item)
        ensurePlaybackLoopRunning()
    }

    public func speakImmediately(_ item: SpeechQueueItem) {
        stopCurrentOnly()
        queuedItems.insert(item, at: 0)
        warmUpIfNeeded()
        startPreSynthesis(for: item)
        ensurePlaybackLoopRunning()
    }

    public func togglePlayPause() {
        if let player = audioPlayer {
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
        } else if fallbackSynth.isSpeaking {
            if fallbackSynth.isPaused {
                fallbackSynth.continueSpeaking()
                isPlaying = true
                isPaused = false
            } else {
                fallbackSynth.pauseSpeaking(at: .word)
                isPlaying = false
                isPaused = true
            }
        }
    }

    public func skipCurrent() {
        stopCurrentOnly()
    }

    public func stopAll() {
        queuedItems.removeAll()
        for (_, task) in preSynthTasks {
            task.cancel()
        }
        preSynthTasks.removeAll()
        playbackLoopTask?.cancel()
        playbackLoopTask = nil
        stopCurrentOnly()
    }

    // MARK: - Internal Synthesis & Playback

    private func startPreSynthesis(for item: SpeechQueueItem) {
        guard preSynthTasks[item.id] == nil else { return }
        let cachedURL = cachedAudioURL(for: item)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            preSynthTasks[item.id] = Task { cachedURL }
            return
        }
        let seedPath = resolveReferenceAudioPath(for: item.persona)
        let client = daemonClient
        let exag = item.persona.voiceExaggeration
        let text = item.spokenText
        preSynthTasks[item.id] = Task {
            guard let client else { return nil }
            let ok = await client.synthesize(
                text: text,
                refAudioPath: seedPath,
                exaggeration: exag,
                outputURL: cachedURL
            )
            return ok ? cachedURL : nil
        }
    }

    private func ensurePlaybackLoopRunning() {
        guard playbackLoopTask == nil else { return }
        playbackLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard !self.queuedItems.isEmpty else { break }
                let next = self.queuedItems.removeFirst()
                // Kick off pre-synthesis for the next 2 items in queue while we play this one
                for upcoming in self.queuedItems.prefix(2) {
                    self.startPreSynthesis(for: upcoming)
                }

                self.activeItem = next
                let synthTask = self.preSynthTasks[next.id]
                let wavURL = await synthTask?.value
                self.preSynthTasks.removeValue(forKey: next.id)

                if Task.isCancelled { break }

                if let wavURL, FileManager.default.fileExists(atPath: wavURL.path) {
                    await self.playWAV(url: wavURL)
                } else {
                    await self.playSystemFallback(text: ExpressiveTagFormatter.stripTags(next.spokenText))
                }

                self.activeItem = nil
                self.speakerLevel = 0
                try? await Task.sleep(nanoseconds: 220_000_000) // natural breath between turns
            }
            self.activeItem = nil
            self.isPlaying = false
            self.isPaused = false
            self.speakerLevel = 0
            self.playbackLoopTask = nil
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
            await playSystemFallback(text: activeItem.map { ExpressiveTagFormatter.stripTags($0.spokenText) } ?? "")
        }
    }

    private func playSystemFallback(text: String) async {
        guard !text.isEmpty, !isMuted else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = Float(0.49 * playbackSpeed)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        self.isPlaying = true
        self.isPaused = false
        startSimulatedMetering()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.currentTurnContinuation = cont
            self.fallbackSynth.speak(utterance)
        }
        stopMetering()
        self.isPlaying = false
    }

    private func stopCurrentOnly() {
        stopMetering()
        audioPlayer?.stop()
        audioPlayer = nil
        if fallbackSynth.isSpeaking {
            fallbackSynth.stopSpeaking(at: .immediate)
        }
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
                guard let self, let player = self.audioPlayer, player.isPlaying else { return }
                player.updateMeters()
                let power = player.averagePower(forChannel: 0) // -160 ... 0 dB
                let normalized = max(0, min(1, (power + 45) / 42))
                self.speakerLevel = CGFloat(normalized)
            }
        }
    }

    private func startSimulatedMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.speakerLevel = CGFloat.random(in: 0.25...0.85)
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

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
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
        let keyString = "\(item.persona.voicePresetID)|\(item.persona.customVoicePath ?? "")|\(String(format: "%.2f", item.persona.voiceExaggeration))|\(item.spokenText)"
        let digest = SHA256.hash(data: Data(keyString.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("turn-\(hex).wav")
    }
}

// MARK: - Background Actor Managing Python MLX Daemon

actor ChatterboxDaemonClient {
    private let onStateChange: @Sendable (VoiceDaemonState) -> Void
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var pending: [String: CheckedContinuation<Bool, Never>] = [:]
    private var isReady: Bool = false
    private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    private var failedPermanently: Bool = false

    init(onStateChange: @escaping @Sendable (VoiceDaemonState) -> Void) {
        self.onStateChange = onStateChange
    }

    func start() async {
        guard process == nil, !failedPermanently else { return }

        guard let scriptURL = Bundle.module.url(forResource: "voice_daemon", withExtension: "py") else {
            failedPermanently = true
            onStateChange(.fallbackSystemVoice("Voice daemon script missing; using macOS voice"))
            resumeReadyWaiters(false)
            return
        }

        let uvBinary = BinaryLocator.findBinary("uv")
        guard let uvBinary else {
            failedPermanently = true
            onStateChange(.fallbackSystemVoice("Install `uv` to enable Chatterbox Turbo MLX; using macOS voice"))
            resumeReadyWaiters(false)
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uvBinary)
        proc.arguments = [
            "run",
            "--python", "3.12",
            "--with", "mlx-audio",
            "--with", "soundfile",
            "--with", "tiktoken",
            "--with", "librosa",
            "python",
            scriptURL.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = BinaryLocator.augmentedPATH()
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.process = proc
        self.stdinHandle = inPipe.fileHandleForWriting

        let lineBuffer = LockedBox(Data())

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
            Task {
                await self?.handleDaemonTerminated()
            }
        }

        do {
            try proc.run()
        } catch {
            failedPermanently = true
            onStateChange(.fallbackSystemVoice("Voice daemon launch failed; using macOS voice"))
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
    }

    func synthesize(text: String, refAudioPath: String?, exaggeration: Double, outputURL: URL) async -> Bool {
        if failedPermanently { return false }
        if !isReady {
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
            "exaggeration": exaggeration,
            "out_path": outputURL.path
        ]
        if let refAudioPath {
            payload["ref_audio"] = refAudioPath
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
        if failedPermanently { return false }
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
                failedPermanently = true
                onStateChange(.fallbackSystemVoice("Chatterbox unavailable; using macOS voice"))
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
        if !failedPermanently {
            onStateChange(.fallbackSystemVoice("Voice engine restarted on next turn"))
        }
    }
}
