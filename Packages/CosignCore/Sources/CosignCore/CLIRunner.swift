import Foundation

public struct ModelCallRequest: Sendable {
    public var provider: AIProvider
    public var modelID: String
    public var effort: ReasoningEffort
    public var systemPrompt: String
    public var userPrompt: String
    public var imagePaths: [String]
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
        imagePaths: [String] = [],
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
        self.imagePaths = imagePaths
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
/// - `.researchAndInspect`: full CLI read/inspection tools + read-only sub-agents (`git`, `gh`, MCP, web) with file edits blocked
/// - `.coordinatedReadWrite`: full read + write + shell + native sub-agents (supports parallel disjoint-scope waves)
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
        do {
            return try await callClaudeOnce(req, modelOverride: nil)
        } catch let ModelRunnerError.processFailed(msg) where Self.isClaudeFalsePositiveModelBlock(msg, modelID: req.modelID) {
            // Anthropic's Opus 5.5 occasionally false-positives on `[reasoning_extraction]` with safe prompts
            // and recommends switching models. Automatically fall back to `claude-sonnet-5-5` so the seat never stalls!
            return try await callClaudeOnce(req, modelOverride: "claude-sonnet-5-5")
        }
    }

    private static func isClaudeFalsePositiveModelBlock(_ message: String, modelID: String) -> Bool {
        guard modelID != "claude-sonnet-5-5" else { return false }
        let lower = message.lowercased()
        return lower.contains("reasoning_extraction")
            || lower.contains("can't respond to this message with")
            || lower.contains("change your model")
    }

    private func callClaudeOnce(_ req: ModelCallRequest, modelOverride: String?) async throws -> String {
        guard let binary = BinaryLocator.findBinary("claude", home: realHome) else {
            throw ModelRunnerError.binaryNotFound(.claude)
        }

        let effectiveModel = modelOverride ?? req.modelID
        // When falling back due to reasoning_extraction, also use medium/high effort rather than xhigh/max
        let effectiveEffort = (modelOverride != nil && (req.effort == .max || req.effort == .xhigh)) ? "high" : req.effort.rawValue

        let (cwd, shouldClean) = resolveWorkingDirectory(for: req)
        defer { if shouldClean { try? FileManager.default.removeItem(at: cwd) } }

        let validImages = Self.existingImagePaths(from: req.imagePaths)
        let imageDirs = Self.uniqueParentDirectories(for: validImages)

        var args: [String] = [
            "-p",
            "--model", effectiveModel,
            "--effort", effectiveEffort,
            "--output-format", "json",
            "--disable-slash-commands",
            "--no-session-persistence",
        ]

        switch req.toolPhase {
        case .closedBook:
            if validImages.isEmpty {
                let tools = req.allowWebSearch ? "WebSearch,WebFetch" : ""
                args += [
                    "--system-prompt", req.systemPrompt,
                    "--tools", tools,
                    "--safe-mode",
                    "--setting-sources", "",
                    "--strict-mcp-config",
                ]
                if req.allowWebSearch {
                    args += ["--allowedTools", tools]
                }
            } else {
                // Allow Read on attached image directories so Claude visually inspects user-attached screenshots even in closed-book turns!
                let tools = req.allowWebSearch ? "Read,WebSearch,WebFetch" : "Read"
                args += [
                    "--system-prompt", req.systemPrompt,
                    "--tools", tools,
                    "--allowedTools", tools,
                    "--dangerously-skip-permissions",
                    "--setting-sources", "",
                    "--strict-mcp-config",
                ]
                for dir in imageDirs {
                    args += ["--add-dir", dir]
                }
            }
        case .researchAndInspect:
            // Use --append-system-prompt so Claude Code preserves its native built-in Agent/sub-agent & parallel tool orchestration!
            args += [
                "--append-system-prompt", req.systemPrompt,
                "--tools", "default",
                "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit",
                "--dangerously-skip-permissions",
            ]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
            for dir in imageDirs {
                args += ["--add-dir", dir]
            }
        case .coordinatedReadWrite:
            // Preserve Claude Code's built-in Agent/sub-agent harness so each builder can spawn sub-agents freely!
            args += [
                "--append-system-prompt", req.systemPrompt,
                "--tools", "default",
                "--dangerously-skip-permissions",
            ]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
            for dir in imageDirs {
                args += ["--add-dir", dir]
            }
        }

        let claudeStdin: String
        if validImages.isEmpty {
            claudeStdin = req.userPrompt
        } else {
            let list = validImages.map { "- \($0)" }.joined(separator: "\n")
            claudeStdin = """
            IMPORTANT — USER ATTACHED IMAGE(S):
            Call your `Read` tool on these attached image path(s) FIRST so you visually inspect them before answering:
            \(list)

            \(req.userPrompt)
            """
        }

        let out: String
        do {
            out = try await runSubprocess(
                executable: binary,
                arguments: args,
                cwd: cwd,
                stdinText: claudeStdin,
                label: "claude/\(effectiveModel)"
            )
        } catch let ModelRunnerError.processFailed(rawErr) {
            // Claude CLI writes structured JSON to stdout even when exiting with status 1; extract clean `result` message if present.
            if let brace = rawErr.firstIndex(of: "{"),
               let data = String(rawErr[brace...]).data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cleanMsg = json["result"] as? String {
                throw ModelRunnerError.processFailed("Claude (\(effectiveModel)): \(cleanMsg)")
            }
            throw ModelRunnerError.processFailed(rawErr)
        }

        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            throw ModelRunnerError.emptyResponse("claude/\(effectiveModel)")
        }
        if (json["is_error"] as? Bool) == true {
            let msg = (json["result"] as? String) ?? "Unknown Claude CLI error"
            throw ModelRunnerError.processFailed("Claude (\(effectiveModel)): \(msg)")
        }
        guard let result = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else {
            throw ModelRunnerError.emptyResponse("claude/\(effectiveModel)")
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
            fullPrompt += "\n\nTOOL & SUB-AGENT ACCESS: You have full read/research access to local repos (working directory: \(cwd.path)), `git`, `gh` (GitHub CLI), MCP servers, web search, and parallel read-only sub-agents. STRICT RULE FOR THIS TURN: Do NOT edit, write, create, or delete any files—only inspect, read, and research."
        case .coordinatedReadWrite:
            fullPrompt += "\n\nTOOL & SUB-AGENT ACCESS: You have full read + write + shell access in \(cwd.path) AND full freedom to spawn your own sub-agents and parallel tool calls to split up your assigned scope rapidly. Stay strictly within your assigned file/directory scope so concurrent council teammates are never disrupted."
        }

        let validImages = Self.existingImagePaths(from: req.imagePaths)
        let imageDirs = Self.uniqueParentDirectories(for: validImages)

        let effortValue = req.effort == .max ? "xhigh" : req.effort.rawValue
        var args: [String] = []
        if req.toolPhase != .closedBook {
            args += ["--enable", "multi_agent_v2"]
        }
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
        for imgPath in validImages {
            args += ["-i", imgPath]
        }

        switch req.toolPhase {
        case .closedBook:
            args += ["--ignore-user-config", "--ignore-rules", "-s", "read-only"]
        case .researchAndInspect, .coordinatedReadWrite:
            args += ["--dangerously-bypass-approvals-and-sandbox"]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
            for dir in imageDirs {
                args += ["--add-dir", dir]
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

        let validImages = Self.existingImagePaths(from: req.imagePaths)
        let imageDirs = Self.uniqueParentDirectories(for: validImages)

        var fullPrompt = "\(req.systemPrompt)\n\n---\n\n\(req.userPrompt)"
        if !validImages.isEmpty {
            let list = validImages.map { "- \($0)" }.joined(separator: "\n")
            fullPrompt += "\n\nIMPORTANT — USER ATTACHED IMAGE(S): Call `read_file` on these attached image path(s) FIRST so you visually inspect them before answering:\n\(list)"
        }
        switch req.toolPhase {
        case .closedBook:
            if !req.allowWebSearch && validImages.isEmpty {
                fullPrompt += "\n\nDo not use any tools, files, or web search for this reply."
            }
        case .researchAndInspect:
            fullPrompt += "\n\nTOOL & SUB-AGENT ACCESS: You have full read/inspection access to local repos (working directory: \(cwd.path)), `git`, `gh` (GitHub CLI), web search, and read-only `research` sub-agents (`invoke_subagent`). Do NOT edit or modify files during this turn."
        case .coordinatedReadWrite:
            fullPrompt += "\n\nTOOL & SUB-AGENT ACCESS: You have full read + write + command access in \(cwd.path) AND full freedom to spawn sub-agents (`invoke_subagent` / `define_subagent`) and parallel tool calls to parallelize sub-tasks within your assigned scope."
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
            if validImages.isEmpty {
                args += ["--mode", "plan"]
            } else {
                args += ["--dangerously-skip-permissions", "--mode", "plan"]
                for dir in imageDirs {
                    args += ["--add-dir", dir]
                }
            }
        case .researchAndInspect:
            args += ["--dangerously-skip-permissions", "--mode", "plan"]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
            for dir in imageDirs {
                args += ["--add-dir", dir]
            }
        case .coordinatedReadWrite:
            args += ["--dangerously-skip-permissions", "--mode", "auto"]
            for extra in WorkspaceResolver.additionalRepoRoots(excluding: cwd.path, home: realHome) {
                args += ["--add-dir", extra]
            }
            for dir in imageDirs {
                args += ["--add-dir", dir]
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
        let validImages = Self.existingImagePaths(from: req.imagePaths)
        let userContent: Any
        if validImages.isEmpty {
            userContent = req.userPrompt
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": req.userPrompt]]
            for path in validImages {
                if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                    let ext = URL(fileURLWithPath: path).pathExtension
                    let mime = SessionStore.mimeType(forExtension: ext)
                    let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": dataURL]
                    ])
                }
            }
            userContent = parts
        }

        let model = req.modelID + (req.allowWebSearch ? ":online" : "")
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": req.systemPrompt],
                ["role": "user", "content": userContent],
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

    private static func existingImagePaths(from rawPaths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in rawPaths where !path.isEmpty && !seen.contains(path) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                seen.insert(path)
                result.append(path)
            }
        }
        return result
    }

    private static func uniqueParentDirectories(for filePaths: [String]) -> [String] {
        Array(Set(filePaths.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path })).sorted()
    }

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
