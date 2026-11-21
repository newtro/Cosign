import Foundation

public struct ModelDiscoveryResult: Sendable {
    public var catalog: [AIProvider: [DiscoveredModel]]
    public var diagnostics: [ProviderDiagnostics]
    public var refreshedAt: Date

    public init(
        catalog: [AIProvider: [DiscoveredModel]],
        diagnostics: [ProviderDiagnostics],
        refreshedAt: Date = Date()
    ) {
        self.catalog = catalog
        self.diagnostics = diagnostics
        self.refreshedAt = refreshedAt
    }
}

public enum BinaryLocator {
    public static func searchPaths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        [
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".local/shims").path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    public static func augmentedPATH(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let prefix = searchPaths(home: home).joined(separator: ":")
        return "\(prefix):\(existing)"
    }

    public static func findBinary(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let fm = FileManager.default
        for dir in searchPaths(home: home) {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) {
                // Resolve symlink/shim target when needed so isolated HOME runs don't break.
                let resolved = candidate.resolvingSymlinksInPath()
                if fm.isExecutableFile(atPath: resolved.path) {
                    return resolved.path
                }
                return candidate.path
            }
        }
        return nil
    }
}

public actor ModelDiscoveryService {
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func discoverAll(openRouterKey: String? = nil) async -> ModelDiscoveryResult {
        async let agyPair = discoverAGY()
        async let codexPair = discoverCodex()
        async let claudePair = discoverClaude()
        async let orPair = discoverOpenRouter(apiKey: openRouterKey)

        let (agyModels, agyDiag) = await agyPair
        let (codexModels, codexDiag) = await codexPair
        let (claudeModels, claudeDiag) = await claudePair
        let (orModels, orDiag) = await orPair

        let catalog: [AIProvider: [DiscoveredModel]] = [
            .agy: agyModels,
            .codex: codexModels,
            .claude: claudeModels,
            .openrouter: orModels,
        ]
        return ModelDiscoveryResult(
            catalog: catalog,
            diagnostics: [claudeDiag, codexDiag, agyDiag, orDiag],
            refreshedAt: Date()
        )
    }

    // MARK: - AGY (Gemini)

    public func discoverAGY() async -> ([DiscoveredModel], ProviderDiagnostics) {
        let binary = BinaryLocator.findBinary("agy", home: home)
        let hasAuth = [
            ".gemini/oauth_creds.json",
            ".gemini/jetski-standalone-oauth-token",
            ".gemini/antigravity-cli/antigravity-oauth-token",
            ".gemini/google_accounts.json"
        ].contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }

        var parsed: [DiscoveredModel] = []
        if let binary {
            if let output = try? await Self.runQuickCommand(executable: binary, arguments: ["models"], home: home, timeoutSeconds: 8) {
                parsed = Self.parseAGYModelsOutput(output)
            }
        }
        let models = parsed.isEmpty ? Self.fallbackAGYModels : parsed
        let status: ProviderHealthStatus = binary == nil ? .notInstalled : (hasAuth ? .ready : .needsLogin)
        let detail: String
        switch status {
        case .ready:
            detail = parsed.isEmpty ? "CLI ready (using built-in model list)" : "Live catalog loaded via `agy models` (\(models.count) models)"
        case .needsLogin:
            detail = "Run `agy` in Terminal once to sign in with Google"
        case .notInstalled:
            detail = "`agy` CLI not found in PATH"
        case .missingAPIKey:
            detail = ""
        }
        return (models, ProviderDiagnostics(provider: .agy, status: status, binaryPath: binary, detail: detail, modelCount: models.count))
    }

    public static func parseAGYModelsOutput(_ output: String) -> [DiscoveredModel] {
        var results: [DiscoveredModel] = []
        var seen = Set<String>()
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.contains("\t") else { continue }
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            let label = parts[1].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)

            let group = inferAGYGroup(id: id, label: label)
            let embedded = id.hasSuffix("-low") || id.hasSuffix("-medium") || id.hasSuffix("-high") || id.hasSuffix("-xhigh")
            results.append(DiscoveredModel(
                id: id,
                displayName: label,
                provider: .agy,
                familyGroup: group,
                supportedEfforts: [.low, .medium, .high, .xhigh],
                effortEmbeddedInID: embedded
            ))
        }
        return results
    }

    private static func inferAGYGroup(id: String, label: String) -> String {
        if id.contains("neon") { return "Gemini 4 Neon" }
        if id.contains("hydrogen") { return "Gemini 4 Hydrogen" }
        if id.contains("carbon") { return "Gemini 4 Carbon" }
        if id.contains("argon") { return "Gemini 4 Argon" }
        if id.contains("flash") { return "Gemini Flash" }
        if id.contains("orchestrator") { return "Orchestrator" }
        if id.contains("claude") { return "Claude (via AGY)" }
        return label
    }

    public static var fallbackAGYModels: [DiscoveredModel] {
        [
            DiscoveredModel(id: "gemini-4-neon-high", displayName: "Gemini 4 Neon (High)", provider: .agy, familyGroup: "Gemini 4 Neon", supportedEfforts: [.low, .medium, .high, .xhigh], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-4-neon-xhigh", displayName: "Gemini 4 Neon (XHigh)", provider: .agy, familyGroup: "Gemini 4 Neon", supportedEfforts: [.low, .medium, .high, .xhigh], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-4-neon-medium", displayName: "Gemini 4 Neon (Medium)", provider: .agy, familyGroup: "Gemini 4 Neon", supportedEfforts: [.low, .medium, .high, .xhigh], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-4-hydrogen-high", displayName: "Gemini 4 Hydrogen (High)", provider: .agy, familyGroup: "Gemini 4 Hydrogen", supportedEfforts: [.low, .medium, .high, .xhigh], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-4-hydrogen-xhigh", displayName: "Gemini 4 Hydrogen (XHigh)", provider: .agy, familyGroup: "Gemini 4 Hydrogen", supportedEfforts: [.low, .medium, .high, .xhigh], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-4-hydrogen-medium", displayName: "Gemini 4 Hydrogen (Medium)", provider: .agy, familyGroup: "Gemini 4 Hydrogen", supportedEfforts: [.low, .medium, .high, .xhigh], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-4-carbon-high", displayName: "Gemini 4 Carbon (High)", provider: .agy, familyGroup: "Gemini 4 Carbon", supportedEfforts: [.low, .medium, .high], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-4-carbon-medium", displayName: "Gemini 4 Carbon (Medium)", provider: .agy, familyGroup: "Gemini 4 Carbon", supportedEfforts: [.low, .medium, .high], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-4-argon-high", displayName: "Gemini 4 Argon (High)", provider: .agy, familyGroup: "Gemini 4 Argon", supportedEfforts: [.low, .medium, .high], effortEmbeddedInID: true),
            DiscoveredModel(id: "gemini-3.8-flash-high", displayName: "Gemini 3.8 Flash (High)", provider: .agy, familyGroup: "Gemini Flash", supportedEfforts: [.low, .medium, .high], effortEmbeddedInID: true),
        ]
    }

    // MARK: - Codex (OpenAI)

    public func discoverCodex() async -> ([DiscoveredModel], ProviderDiagnostics) {
        let binary = BinaryLocator.findBinary("codex", home: home)
        let authPath = home.appendingPathComponent(".codex/auth.json")
        let hasAuth = FileManager.default.fileExists(atPath: authPath.path)
        let cacheURL = home.appendingPathComponent(".codex/models_cache.json")

        var parsed: [DiscoveredModel] = []
        if let data = try? Data(contentsOf: cacheURL) {
            parsed = Self.parseCodexModelsCache(data)
        }
        let models = parsed.isEmpty ? Self.fallbackCodexModels : parsed
        let status: ProviderHealthStatus = binary == nil ? .notInstalled : (hasAuth ? .ready : .needsLogin)
        let detail: String
        switch status {
        case .ready:
            detail = parsed.isEmpty ? "CLI signed in (using fallback models)" : "Live catalog loaded from Codex (\(models.count) models)"
        case .needsLogin:
            detail = "Run `codex login` in Terminal to sign in with OpenAI"
        case .notInstalled:
            detail = "`codex` CLI not found in PATH"
        case .missingAPIKey:
            detail = ""
        }
        return (models, ProviderDiagnostics(provider: .codex, status: status, binaryPath: binary, detail: detail, modelCount: models.count))
    }

    public static func parseCodexModelsCache(_ data: Data) -> [DiscoveredModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["models"] as? [[String: Any]] else {
            return []
        }
        var results: [DiscoveredModel] = []
        var seen = Set<String>()
        for entry in list {
            guard let slug = entry["slug"] as? String, !slug.isEmpty, !seen.contains(slug) else { continue }
            let visibility = (entry["visibility"] as? String) ?? "list"
            if visibility == "hide" { continue }
            seen.insert(slug)
            let display = (entry["display_name"] as? String) ?? slug
            var efforts: [ReasoningEffort] = [.low, .medium, .high, .xhigh]
            if let levels = entry["supported_reasoning_levels"] as? [[String: Any]] {
                let mapped = levels.compactMap { dict -> ReasoningEffort? in
                    guard let raw = dict["effort"] as? String else { return nil }
                    return ReasoningEffort(rawValue: raw)
                }
                if !mapped.isEmpty { efforts = mapped }
            }
            results.append(DiscoveredModel(
                id: slug,
                displayName: display,
                provider: .codex,
                familyGroup: "OpenAI",
                supportedEfforts: efforts,
                effortEmbeddedInID: false
            ))
        }
        return results
    }

    public static var fallbackCodexModels: [DiscoveredModel] {
        [
            DiscoveredModel(id: "gpt-6.2-sol", displayName: "GPT-6.2-Sol", provider: .codex, familyGroup: "OpenAI", supportedEfforts: [.low, .medium, .high, .xhigh]),
            DiscoveredModel(id: "gpt-6.2-astra", displayName: "GPT-6.2-Astra", provider: .codex, familyGroup: "OpenAI", supportedEfforts: [.low, .medium, .high, .xhigh]),
            DiscoveredModel(id: "gpt-6.1-terra", displayName: "GPT-6.1 Terra", provider: .codex, familyGroup: "OpenAI", supportedEfforts: [.low, .medium, .high, .xhigh]),
            DiscoveredModel(id: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", provider: .codex, familyGroup: "OpenAI", supportedEfforts: [.low, .medium, .high, .xhigh]),
            DiscoveredModel(id: "gpt-6-sol", displayName: "GPT-6-Sol", provider: .codex, familyGroup: "OpenAI", supportedEfforts: [.low, .medium, .high]),
        ]
    }

    // MARK: - Claude (Anthropic)

    public func discoverClaude() async -> ([DiscoveredModel], ProviderDiagnostics) {
        let binary = BinaryLocator.findBinary("claude", home: home)
        let claudeDir = home.appendingPathComponent(".claude")
        let hasAuth = FileManager.default.fileExists(atPath: claudeDir.path)

        var parsed: [DiscoveredModel] = []
        let catalogDir = claudeDir.appendingPathComponent("cache/model-catalog")
        if let urls = try? FileManager.default.contentsOfDirectory(
            at: catalogDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let candidates = urls
                .filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains("failed") && $0.lastPathComponent != "published-floor.json" }
                .sorted { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return da > db
                }
            for url in candidates {
                if let data = try? Data(contentsOf: url) {
                    let items = Self.parseClaudeCatalogJSON(data)
                    if !items.isEmpty {
                        parsed = items
                        break
                    }
                }
            }
        }

        let models = parsed.isEmpty ? Self.fallbackClaudeModels : parsed
        let status: ProviderHealthStatus = binary == nil ? .notInstalled : (hasAuth ? .ready : .needsLogin)
        let detail: String
        switch status {
        case .ready:
            detail = parsed.isEmpty ? "CLI ready (using built-in Claude models)" : "Live catalog loaded from Claude (\(models.count) models)"
        case .needsLogin:
            detail = "Run `claude` in Terminal once to sign in with Anthropic"
        case .notInstalled:
            detail = "`claude` CLI not found in PATH"
        case .missingAPIKey:
            detail = ""
        }
        return (models, ProviderDiagnostics(provider: .claude, status: status, binaryPath: binary, detail: detail, modelCount: models.count))
    }

    public static func parseClaudeCatalogJSON(_ data: Data) -> [DiscoveredModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = root["catalog"] as? [String: Any],
              let config = catalog["config"] as? [String: Any],
              let list = config["models"] as? [[String: Any]] else {
            return []
        }
        var results: [DiscoveredModel] = []
        var seen = Set<String>()
        for item in list {
            guard let id = item["id"] as? String, !id.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            let rawName = (item["name"] as? String) ?? id
            let display = rawName.hasPrefix("Claude") ? rawName : "Claude \(rawName)"
            var efforts: [ReasoningEffort] = [.low, .medium, .high]
            if let thinking = item["thinking"] as? [String: Any],
               let options = thinking["effort_options"] as? [[String: Any]] {
                let mapped = options.compactMap { opt -> ReasoningEffort? in
                    guard let raw = opt["id"] as? String else { return nil }
                    return ReasoningEffort(rawValue: raw)
                }
                if !mapped.isEmpty { efforts = mapped }
            }
            results.append(DiscoveredModel(
                id: id,
                displayName: display,
                provider: .claude,
                familyGroup: "Anthropic",
                supportedEfforts: efforts,
                effortEmbeddedInID: false
            ))
        }
        return results
    }

    public static var fallbackClaudeModels: [DiscoveredModel] {
        [
            DiscoveredModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", provider: .claude, familyGroup: "Anthropic", supportedEfforts: [.low, .medium, .high, .xhigh, .max]),
            DiscoveredModel(id: "claude-fable-5-2", displayName: "Claude Fable 5.2", provider: .claude, familyGroup: "Anthropic", supportedEfforts: [.low, .medium, .high, .xhigh, .max]),
            DiscoveredModel(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", provider: .claude, familyGroup: "Anthropic", supportedEfforts: [.low, .medium, .high, .xhigh, .max]),
            DiscoveredModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", provider: .claude, familyGroup: "Anthropic", supportedEfforts: [.low, .medium, .high]),
        ]
    }

    // MARK: - OpenRouter (Optional)

    public func discoverOpenRouter(apiKey: String?) async -> ([DiscoveredModel], ProviderDiagnostics) {
        let trimmed = (apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let defaults = Self.fallbackOpenRouterModels
            return (
                defaults,
                ProviderDiagnostics(
                    provider: .openrouter,
                    status: .missingAPIKey,
                    binaryPath: nil,
                    detail: "Optional — add an OpenRouter key in Settings to unlock non-subscription models",
                    modelCount: defaults.count
                )
            )
        }
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
            return (Self.fallbackOpenRouterModels, ProviderDiagnostics(provider: .openrouter, status: .ready, detail: "Key saved", modelCount: Self.fallbackOpenRouterModels.count))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        var parsed: [DiscoveredModel] = []
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, http.statusCode == 200,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = root["data"] as? [[String: Any]] {
            for item in list.prefix(80) {
                guard let id = item["id"] as? String, !id.isEmpty else { continue }
                let name = (item["name"] as? String) ?? id
                parsed.append(DiscoveredModel(
                    id: id,
                    displayName: name,
                    provider: .openrouter,
                    familyGroup: String(id.split(separator: "/").first ?? "OpenRouter"),
                    supportedEfforts: [.low, .medium, .high]
                ))
            }
        }
        let models = parsed.isEmpty ? Self.fallbackOpenRouterModels : parsed
        return (
            models,
            ProviderDiagnostics(
                provider: .openrouter,
                status: .ready,
                binaryPath: nil,
                detail: "Connected via Keychain API key (\(models.count) models)",
                modelCount: models.count
            )
        )
    }

    public static var fallbackOpenRouterModels: [DiscoveredModel] {
        [
            DiscoveredModel(id: "moonshotai/kimi-k3.1-pro", displayName: "Kimi K3.1 Pro", provider: .openrouter, familyGroup: "moonshotai"),
            DiscoveredModel(id: "qwen/qwen3.8-max-prime", displayName: "Qwen 3.8 Max Prime", provider: .openrouter, familyGroup: "qwen"),
            DiscoveredModel(id: "deepseek/deepseek-v4-pro", displayName: "DeepSeek V4 Pro", provider: .openrouter, familyGroup: "deepseek"),
            DiscoveredModel(id: "z-ai/glm-5.3", displayName: "GLM 5.3", provider: .openrouter, familyGroup: "z-ai"),
        ]
    }

    // MARK: - Helper Subprocess

    private static func runQuickCommand(executable: String, arguments: [String], home: URL, timeoutSeconds: Double) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = BinaryLocator.augmentedPATH(home: home)
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            proc.standardInput = FileHandle.nullDevice

            let finishedBox = LockedBox(false)

            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler {
                let shouldKill = finishedBox.withLock { !$0 }
                if shouldKill, proc.isRunning {
                    proc.terminate()
                }
            }
            timer.resume()

            proc.terminationHandler = { p in
                timer.cancel()
                let alreadyDone = finishedBox.withLock { done -> Bool in
                    if done { return true }
                    done = true
                    return false
                }
                guard !alreadyDone else { return }

                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errText = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: NSError(domain: "ModelDiscovery", code: Int(p.terminationStatus), userInfo: [
                        NSLocalizedDescriptionKey: errText
                    ]))
                }
            }

            do {
                try proc.run()
            } catch {
                timer.cancel()
                finishedBox.withLock { $0 = true }
                continuation.resume(throwing: error)
            }
        }
    }
}
