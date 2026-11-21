import Foundation

public struct ModelCallRequest: Sendable {
    public var provider: AIProvider
    public var modelID: String
    public var effort: ReasoningEffort
    public var systemPrompt: String
    public var userPrompt: String
    public var allowWebSearch: Bool
    public var toolPhase: ToolExecutionPhase
    public var workspacePath: String?
    public var openRouterAPIKey: String?

    public init(
        provider: AIProvider,
        modelID: String,
        effort: ReasoningEffort,
        systemPrompt: String,
        userPrompt: String,
        allowWebSearch: Bool = true,
        toolPhase: ToolExecutionPhase = .researchAndInspect,
        workspacePath: String? = nil,
        openRouterAPIKey: String? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.effort = effort
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.allowWebSearch = allowWebSearch
        self.toolPhase = toolPhase
        self.workspacePath = workspacePath
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

/// Runs headless calls through subscription CLIs (`claude`, `codex`, `agy`) and optional OpenRouter.
/// Supports three tool modes:
/// - `.closedBook`: isolated no-tool reasoning
/// - `.researchAndInspect`: full CLI read/inspection tools (local repos, `git`, `gh`, MCP, web) with file edits blocked
/// - `.coordinatedReadWrite`: full read + write + shell execution (used one persona at a time under Chair coordination)
public final class LiveCLIRunner: ModelRunnerProtocol, @unchecked Sendable {
    private let realHome: URL
    private let maxRetries: Int

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

    private func resolveWorkingDirectory(for req: ModelCallRequest) -> (url: URL, cleanupAfter: Bool) {
        if req.toolPhase == .closedBook {
            if let tmp = try? makeTempDir(prefix: "cosign-closed-") {
                return (tmp, true)
            }
        }
        if let ws = req.workspacePath, !ws.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: ws, isDirectory: &isDir), isDir.boolValue {
                return (URL(fileURLWithPath: ws), false)
            }
        }
        let fallback = WorkspaceResolver.defaultWorkspacePath(home: realHome)
        return (URL(fileURLWithPath: fallback), false)
    }

    // MARK: - Claude Subscription CLI

    private func callClaude(_ req: ModelCallRequest) async throws -> String {
        guard let binary = BinaryLocator.findBinary("claude", home: realHome) else {
            throw ModelRunnerError.binaryNotFound(.claude)
        }

        let (cwd, shouldClean) = resolveWorkingDirectory(for: req)
        defer { if shouldClean { try? FileManager.default.removeItem(at: cwd) } }

        var args: [String] = [
            "-p",
            "--model", req.modelID,
            "--effort", req.effort.rawValue,
            "--output-format", "json",
            "--system-prompt", req.systemPrompt,
            "--disable-slash-commands",
            "--no-session-persistence",
        ]

        switch req.toolPhase {
        case .closedBook:
            let tools = req.allowWebSearch ? "WebSearch,WebFetch" : ""
            args += ["--tools", tools, "--safe-mode", "--setting-sources", "", "--strict-mcp-config"]
            if req.allowWebSearch {
                args += ["--allowedTools", tools]
            }
        case .researchAndInspect:
            args += [
                "--tools", "default",
                "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit",
                "--dangerously-skip-permissions",
            ]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
        case .coordinatedReadWrite:
            args += [
                "--tools", "default",
                "--dangerously-skip-permissions",
            ]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
        }

        let out = try await runSubprocess(
            executable: binary,
            arguments: args,
            cwd: cwd,
            stdinText: req.userPrompt,
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

        let (cwd, shouldClean) = resolveWorkingDirectory(for: req)
        defer { if shouldClean { try? FileManager.default.removeItem(at: cwd) } }

        let tempOutDir = try makeTempDir(prefix: "cosign-codex-out-")
        defer { try? FileManager.default.removeItem(at: tempOutDir) }
        let lastFile = tempOutDir.appendingPathComponent("last.txt")

        var fullPrompt = "\(req.systemPrompt)\n\n---\n\n\(req.userPrompt)"
        switch req.toolPhase {
        case .closedBook:
            if !req.allowWebSearch {
                fullPrompt += "\n\nDo not use any tools, files, or web search for this reply."
            }
        case .researchAndInspect:
            fullPrompt += "\n\nTOOL ACCESS: You have full read/research access to local repos (working directory: \(cwd.path)), `git`, `gh` (GitHub CLI), MCP servers, and web search. STRICT RULE FOR THIS DEBATE TURN: Do NOT edit, write, create, or delete any files—only inspect, read, and research."
        case .coordinatedReadWrite:
            fullPrompt += "\n\nTOOL ACCESS: You are the Chair-designated executor for this turn with full read + write + shell access in \(cwd.path)."
        }

        let effortValue = req.effort == .max ? "xhigh" : req.effort.rawValue
        var args: [String] = []
        if req.allowWebSearch || req.toolPhase != .closedBook {
            args.append("--search")
        }
        args += [
            "exec",
            "-m", req.modelID,
            "-c", "model_reasoning_effort=\"\(effortValue)\"",
            "--skip-git-repo-check",
            "--ephemeral",
            "-C", cwd.path,
            "-o", lastFile.path,
        ]

        switch req.toolPhase {
        case .closedBook:
            args += ["--ignore-user-config", "--ignore-rules", "-s", "read-only"]
        case .researchAndInspect, .coordinatedReadWrite:
            args += ["--dangerously-bypass-approvals-and-sandbox"]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
        }
        args.append("-")

        _ = try await runSubprocess(
            executable: binary,
            arguments: args,
            cwd: cwd,
            stdinText: fullPrompt,
            label: "codex/\(req.modelID)"
        )
        let text = (try? String(contentsOf: lastFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw ModelRunnerError.emptyResponse("codex/\(req.modelID)")
        }
        return text
    }

    // MARK: - AGY (Gemini Ultra Subscription CLI)

    private func callAGY(_ req: ModelCallRequest) async throws -> String {
        guard let binary = BinaryLocator.findBinary("agy", home: realHome) else {
            throw ModelRunnerError.binaryNotFound(.agy)
        }

        let (cwd, shouldClean) = resolveWorkingDirectory(for: req)
        defer { if shouldClean { try? FileManager.default.removeItem(at: cwd) } }

        var fullPrompt = "\(req.systemPrompt)\n\n---\n\n\(req.userPrompt)"
        switch req.toolPhase {
        case .closedBook:
            if !req.allowWebSearch {
                fullPrompt += "\n\nDo not use any tools, files, or web search for this reply."
            }
        case .researchAndInspect:
            fullPrompt += "\n\nTOOL ACCESS: You have full read/inspection access to local repos (working directory: \(cwd.path)), `git`, `gh` (GitHub CLI), and web search. Do NOT edit or modify files during this debate turn."
        case .coordinatedReadWrite:
            fullPrompt += "\n\nTOOL ACCESS: You are the Chair-designated executor for this turn with full read + write + command access in \(cwd.path)."
        }

        var args = [
            "-p", fullPrompt,
            "--model", req.modelID,
            "--effort", req.effort.rawValue,
            "--output-format", "json",
            "--disable-slash-commands",
        ]

        switch req.toolPhase {
        case .closedBook:
            args += ["--mode", "plan"]
        case .researchAndInspect:
            args += ["--dangerously-skip-permissions", "--mode", "plan"]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
        case .coordinatedReadWrite:
            args += ["--dangerously-skip-permissions", "--mode", "auto"]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
        }

        let out = try await runSubprocess(
            executable: binary,
            arguments: args,
            cwd: cwd,
            stdinText: nil,
            label: "agy/\(req.modelID)"
        )

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

    // MARK: - Clean Environment & Subprocess Execution

    private func makeTempDir(prefix: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanEnvironment() -> [String: String] {
        // Strip host AI-session nesting vars while keeping real HOME, Keychain, SSH, and `gh` GitHub auth intact!
        let blockedPrefixes = ["CLAUDE", "ANTHROPIC", "CODEX_", "OPENAI_"]
        var env: [String: String] = [:]
        for (k, v) in ProcessInfo.processInfo.environment {
            if blockedPrefixes.contains(where: { k.hasPrefix($0) }) { continue }
            env[k] = v
        }
        env["HOME"] = realHome.path
        env["PATH"] = BinaryLocator.augmentedPATH(home: realHome)
        return env
    }

    private func runSubprocess(
        executable: String,
        arguments: [String],
        cwd: URL,
        stdinText: String?,
        label: String
    ) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = cwd
        proc.environment = cleanEnvironment()

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
