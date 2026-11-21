import Foundation

public struct ModelCallRequest: Sendable {
    public var provider: AIProvider
    public var modelID: String
    public var effort: ReasoningEffort
    public var systemPrompt: String
    public var userPrompt: String
    public var allowWebSearch: Bool
    public var openRouterAPIKey: String?

    public init(
        provider: AIProvider,
        modelID: String,
        effort: ReasoningEffort,
        systemPrompt: String,
        userPrompt: String,
        allowWebSearch: Bool = false,
        openRouterAPIKey: String? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.effort = effort
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.allowWebSearch = allowWebSearch
        self.openRouterAPIKey = openRouterAPIKey
    }
}

public struct ModelCallResponse: Sendable {
    public var rawText: String
    public var durationMs: Int

    public init(rawText: String, durationMs: Int) {
        self.rawText = rawText
        self.durationMs = durationMs
    }
}

public enum ModelRunnerError: LocalizedError, Sendable {
    case binaryNotFound(AIProvider)
    case missingAPIKey(AIProvider)
    case processFailed(String)
    case emptyResponse(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let provider):
            return "\(provider.displayName) CLI was not found on this Mac."
        case .missingAPIKey(let provider):
            return "\(provider.displayName) requires an API key in Settings."
        case .processFailed(let msg):
            return msg
        case .emptyResponse(let who):
            return "\(who) returned an empty response."
        case .cancelled:
            return "Cancelled."
        }
    }
}

public protocol ModelRunnerProtocol: Sendable {
    func call(_ request: ModelCallRequest) async throws -> ModelCallResponse
}

/// Runs isolated, context-free calls through subscription CLIs (`claude`, `codex`, `agy`) and optional OpenRouter.
/// Never leaks user skills, memories, MCP tools, or host session variables into persona prompts.
public final class LiveCLIRunner: ModelRunnerProtocol, @unchecked Sendable {
    private let realHome: URL
    private let maxRetries: Int

    private static let authFiles: [AIProvider: [String]] = [
        .codex: [
            ".codex/auth.json"
        ],
        .agy: [
            ".gemini/google_accounts.json",
            ".gemini/installation_id",
            ".gemini/oauth_creds.json",
            ".gemini/settings.json",
            ".gemini/jetski-standalone-oauth-token",
            ".gemini/antigravity-cli/antigravity-oauth-token",
            ".gemini/antigravity-cli/installation_id",
            ".gemini/antigravity-cli/settings.json",
        ]
    ]

    public init(
        realHome: URL = FileManager.default.homeDirectoryForCurrentUser,
        maxRetries: Int = 1
    ) {
        self.realHome = realHome
        self.maxRetries = maxRetries
    }

    public func call(_ request: ModelCallRequest) async throws -> ModelCallResponse {
        var lastError: Error?
        for _ in 0...maxRetries {
            try Task.checkCancellation()
            do {
                let started = ContinuousClock.now
                let text: String
                switch request.provider {
                case .claude:
                    text = try await callClaude(request)
                case .codex:
                    text = try await callCodex(request)
                case .agy:
                    text = try await callAGY(request)
                case .openrouter:
                    text = try await callOpenRouter(request)
                }
                let elapsed = started.duration(to: ContinuousClock.now)
                let ms = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                return ModelCallResponse(rawText: text, durationMs: max(1, ms))
            } catch is CancellationError {
                throw ModelRunnerError.cancelled
            } catch let err as ModelRunnerError {
                if case .cancelled = err { throw err }
                if case .binaryNotFound = err { throw err }
                if case .missingAPIKey = err { throw err }
                lastError = err
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ModelRunnerError.processFailed("Model call failed.")
    }

    // MARK: - Claude Subscription CLI

    private func callClaude(_ req: ModelCallRequest) async throws -> String {
        guard let binary = BinaryLocator.findBinary("claude", home: realHome) else {
            throw ModelRunnerError.binaryNotFound(.claude)
        }
        let tools = req.allowWebSearch ? "WebSearch,WebFetch" : ""
        var args = [
            "-p",
            "--model", req.modelID,
            "--effort", req.effort.rawValue,
            "--output-format", "json",
            "--system-prompt", req.systemPrompt,
            "--tools", tools,
            "--safe-mode",
            "--setting-sources", "",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--no-session-persistence",
        ]
        if req.allowWebSearch {
            args += ["--allowedTools", tools]
        }

        let tempCwd = try makeTempDir(prefix: "cosign-claude-")
        defer { try? FileManager.default.removeItem(at: tempCwd) }

        let out = try await runSubprocess(
            executable: binary,
            arguments: args,
            cwd: tempCwd,
            stdinText: req.userPrompt,
            isolatedHome: nil,
            label: "claude/\(req.modelID)"
        )

        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            throw ModelRunnerError.emptyResponse("claude/\(req.modelID)")
        }
        if (json["is_error"] as? Bool) == true {
            let msg = (json["result"] as? String) ?? "Unknown Claude CLI error"
            throw ModelRunnerError.processFailed("Claude (\(req.modelID)): \(msg)")
        }
        guard let result = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            throw ModelRunnerError.emptyResponse("claude/\(req.modelID)")
        }
        return result
    }

    // MARK: - Codex Subscription CLI

    private func callCodex(_ req: ModelCallRequest) async throws -> String {
        guard let binary = BinaryLocator.findBinary("codex", home: realHome) else {
            throw ModelRunnerError.binaryNotFound(.codex)
        }
        var fullPrompt = "\(req.systemPrompt)\n\n---\n\n\(req.userPrompt)"
        if !req.allowWebSearch {
            fullPrompt += "\n\nDo not use any tools, files, or web search for this reply."
        }
        // Codex maps max -> xhigh if needed
        let effortValue = req.effort == .max ? "xhigh" : req.effort.rawValue

        return try await withIsolatedHome(for: .codex) { home in
            let workDir = home.appendingPathComponent("work")
            let lastFile = home.appendingPathComponent("last.txt")
            var args: [String] = []
            if req.allowWebSearch {
                args.append("--search")
            }
            args += [
                "exec",
                "-m", req.modelID,
                "-c", "model_reasoning_effort=\"\(effortValue)\"",
                "--ignore-user-config",
                "--ignore-rules",
                "--skip-git-repo-check",
                "--ephemeral",
                "-s", "read-only",
                "-C", workDir.path,
                "-o", lastFile.path,
                "-",
            ]
            _ = try await self.runSubprocess(
                executable: binary,
                arguments: args,
                cwd: workDir,
                stdinText: fullPrompt,
                isolatedHome: home,
                label: "codex/\(req.modelID)"
            )
            let text = (try? String(contentsOf: lastFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw ModelRunnerError.emptyResponse("codex/\(req.modelID)")
            }
            return text
        }
    }

    // MARK: - AGY (Gemini Ultra Subscription CLI)

    private func callAGY(_ req: ModelCallRequest) async throws -> String {
        guard let binary = BinaryLocator.findBinary("agy", home: realHome) else {
            throw ModelRunnerError.binaryNotFound(.agy)
        }
        var fullPrompt = "\(req.systemPrompt)\n\n---\n\n\(req.userPrompt)"
        if !req.allowWebSearch {
            fullPrompt += "\n\nDo not use any tools, files, or web search for this reply."
        }
        let args = [
            "-p", fullPrompt,
            "--model", req.modelID,
            "--effort", req.effort.rawValue,
            "--output-format", "json",
            "--disable-slash-commands",
        ]
        let out = try await withIsolatedHome(for: .agy) { home in
            try await self.runSubprocess(
                executable: binary,
                arguments: args,
                cwd: home.appendingPathComponent("work"),
                stdinText: nil,
                isolatedHome: home,
                label: "agy/\(req.modelID)"
            )
        }
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            throw ModelRunnerError.emptyResponse("agy/\(req.modelID)")
        }
        if let status = json["status"] as? String, status != "SUCCESS" {
            throw ModelRunnerError.processFailed("Gemini (\(req.modelID)) status \(status)")
        }
        guard let response = (json["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !response.isEmpty else {
            throw ModelRunnerError.emptyResponse("agy/\(req.modelID)")
        }
        return response
    }

    // MARK: - Optional OpenRouter

    private func callOpenRouter(_ req: ModelCallRequest) async throws -> String {
        let key = (req.openRouterAPIKey ?? KeychainHelper.read(account: "openrouter") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ModelRunnerError.missingAPIKey(.openrouter)
        }
        let model = req.modelID + (req.allowWebSearch ? ":online" : "")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": req.systemPrompt],
                ["role": "user", "content": req.userPrompt],
            ],
            "reasoning": ["effort": req.effort == .max || req.effort == .xhigh ? "high" : req.effort.rawValue]
        ]
        var urlReq = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        urlReq.httpMethod = "POST"
        urlReq.timeoutInterval = 300
        urlReq.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: urlReq)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw ModelRunnerError.processFailed("OpenRouter HTTP \(http.statusCode): \(String(errBody.prefix(300)))")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = (msg["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw ModelRunnerError.emptyResponse("openrouter/\(model)")
        }
        return content
    }

    // MARK: - Isolated Home & Subprocess Execution

    private func makeTempDir(prefix: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func withIsolatedHome<T>(for provider: AIProvider, body: @escaping (URL) async throws -> T) async throws -> T {
        let fm = FileManager.default
        let tempHome = try makeTempDir(prefix: "cosign-\(provider.rawValue)-")
        let files = Self.authFiles[provider] ?? []

        for rel in files {
            let src = realHome.appendingPathComponent(rel)
            if fm.fileExists(atPath: src.path) {
                let dst = tempHome.appendingPathComponent(rel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: src, to: dst)
            }
        }
        let workDir = tempHome.appendingPathComponent("work")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        defer {
            // Sync refreshed OAuth tokens back to real HOME if rewritten during the call
            for rel in files {
                let newFile = tempHome.appendingPathComponent(rel)
                let realFile = realHome.appendingPathComponent(rel)
                if fm.fileExists(atPath: newFile.path), fm.fileExists(atPath: realFile.path),
                   let newAttrs = try? fm.attributesOfItem(atPath: newFile.path),
                   let realAttrs = try? fm.attributesOfItem(atPath: realFile.path),
                   let newDate = newAttrs[.modificationDate] as? Date,
                   let realDate = realAttrs[.modificationDate] as? Date,
                   newDate > realDate,
                   let newData = try? Data(contentsOf: newFile),
                   let realData = try? Data(contentsOf: realFile),
                   newData != realData {
                    try? newData.write(to: realFile, options: .atomic)
                }
            }
            try? fm.removeItem(at: tempHome)
        }

        return try await body(tempHome)
    }

    private func cleanEnvironment(isolatedHome: URL?) -> [String: String] {
        let blockedPrefixes = ["CLAUDE", "ANTHROPIC", "CODEX_", "OPENAI_"]
        var env: [String: String] = [:]
        for (k, v) in ProcessInfo.processInfo.environment {
            if blockedPrefixes.contains(where: { k.hasPrefix($0) }) { continue }
            env[k] = v
        }
        env["PATH"] = BinaryLocator.augmentedPATH(home: realHome)
        if let isolatedHome {
            env["HOME"] = isolatedHome.path
            env.removeValue(forKey: "XDG_CONFIG_HOME")
            env.removeValue(forKey: "XDG_DATA_HOME")
        }
        return env
    }

    private func runSubprocess(
        executable: String,
        arguments: [String],
        cwd: URL,
        stdinText: String?,
        isolatedHome: URL?,
        label: String
    ) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = cwd
        proc.environment = cleanEnvironment(isolatedHome: isolatedHome)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let inPipe: Pipe?
        if stdinText != nil {
            let p = Pipe()
            proc.standardInput = p
            inPipe = p
        } else {
            proc.standardInput = FileHandle.nullDevice
            inPipe = nil
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Collect stdout/stderr asynchronously so large outputs never block pipe buffers
                let buffers = LockedBox((out: Data(), err: Data()))

                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        buffers.withLock { $0.out.append(chunk) }
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if !chunk.isEmpty {
                        buffers.withLock { $0.err.append(chunk) }
                    }
                }

                proc.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil

                    let remOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let remErr = errPipe.fileHandleForReading.readDataToEndOfFile()

                    let (finalOut, finalErr) = buffers.withLock { state -> (String, String) in
                        state.out.append(remOut)
                        state.err.append(remErr)
                        return (
                            String(data: state.out, encoding: .utf8) ?? "",
                            String(data: state.err, encoding: .utf8) ?? ""
                        )
                    }

                    if p.terminationReason == .uncaughtSignal || p.terminationStatus == 130 || p.terminationStatus == 15 || p.terminationStatus == 9 {
                        continuation.resume(throwing: ModelRunnerError.cancelled)
                        return
                    }
                    if p.terminationStatus != 0 {
                        let tail = String((finalErr.isEmpty ? finalOut : finalErr).suffix(600))
                        continuation.resume(throwing: ModelRunnerError.processFailed("\(label) exited \(p.terminationStatus): \(tail)"))
                        return
                    }
                    continuation.resume(returning: finalOut)
                }

                do {
                    try proc.run()
                    if let stdinText, let inPipe {
                        DispatchQueue.global(qos: .userInitiated).async {
                            if let data = stdinText.data(using: .utf8) {
                                try? inPipe.fileHandleForWriting.write(contentsOf: data)
                            }
                            try? inPipe.fileHandleForWriting.close()
                        }
                    }
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if proc.isRunning {
                proc.terminate()
            }
        }
    }
}
