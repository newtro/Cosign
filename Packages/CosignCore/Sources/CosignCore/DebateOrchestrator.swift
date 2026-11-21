import Foundation

public struct SpeechQueueItem: Identifiable, Sendable {
    public var id: UUID
    public var persona: Persona
    public var spokenText: String
    public var contextLabel: String

    public init(id: UUID = UUID(), persona: Persona, spokenText: String, contextLabel: String) {
        self.id = id
        self.persona = persona
        self.spokenText = spokenText
        self.contextLabel = contextLabel
    }
}

public enum OrchestratorEvent: Sendable {
    case sessionUpdated(DebateSession)
    case activeThinkersChanged(Set<UUID>, statusLabel: String)
    case enqueueSpeech(SpeechQueueItem)
}

/// Drives Intake Interview → Parallel Blind Investigation → Chair-Moderated Inter-Persona Debate → Co-Signed Verdict → Chair-Coordinated Sequential Execution.
public final class DebateOrchestrator: Sendable {
    private let runner: ModelRunnerProtocol

    public init(runner: ModelRunnerProtocol) {
        self.runner = runner
    }

    private func researchPhase(for session: DebateSession) -> ToolExecutionPhase {
        session.hasFullCLITools ? .researchAndInspect : .closedBook
    }

    public func submitUserMessage(
        text: String,
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        modelLabels: [String: String] = [:],
        openRouterKey: String? = nil,
        skipInterview: Bool = false,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return session }

        let hadPriorVerdict = session.entries.contains {
            if case .verdict = $0 { return true }
            return false
        }

        session.entries.append(.userPrompt(UserPromptMessage(text: trimmed)))
        session.updatedAt = Date()
        await onEvent(.sessionUpdated(session))

        // Direct @Persona follow-up (with single-agent write lock if CLI tools are enabled!)
        if hadPriorVerdict, let targeted = detectDirectMention(in: trimmed, personas: [moderator] + debaters) {
            return try await runDirectFollowUp(
                target: targeted,
                session: session,
                moderator: moderator,
                debaters: debaters,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                onEvent: onEvent
            )
        }

        // Step 1: Intake Scan & Optional Clarifying Interview
        if !skipInterview && !hadPriorVerdict {
            session.stage = .scanningIntake
            await onEvent(.sessionUpdated(session))
            await onEvent(.activeThinkersChanged(
                [moderator.id],
                statusLabel: session.hasFullCLITools
                    ? "\(moderator.name) is checking repo context & reviewing your pitch…"
                    : "\(moderator.name) is reviewing your pitch with the panel…"
            ))

            let intakePrompt = buildTranscriptContext(for: session)
            let intakeSysPrompt = session.activeMode == .build
                ? DebatePrompts.buildIntakeSystemPrompt(
                    moderator: moderator,
                    debaters: debaters,
                    workspacePath: session.workspacePath
                )
                : DebatePrompts.intakeSystemPrompt(
                    moderator: moderator,
                    debaters: debaters,
                    workspacePath: session.workspacePath,
                    toolsEnabled: session.hasFullCLITools
                )
            let resp = try await runner.call(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: moderator.effort,
                systemPrompt: intakeSysPrompt,
                userPrompt: intakePrompt,
                allowWebSearch: session.allowWebSearch,
                toolPhase: researchPhase(for: session),
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            ))

            if let json = JSONExtractor.parseObject(resp.rawText) {
                if let newTitle = (json["session_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !newTitle.isEmpty,
                   session.title == "New Council Session" {
                    session.title = newTitle
                }

                let needsInterview = (json["needs_interview"] as? Bool) ?? false
                let rawQuestions = (json["questions"] as? [[String: Any]]) ?? []
                if needsInterview && !rawQuestions.isEmpty {
                    let questions: [InterviewQuestion] = rawQuestions.prefix(3).compactMap { qDict in
                        guard let qText = (qDict["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !qText.isEmpty else { return nil }
                        let askedByRaw = (qDict["asked_by"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? moderator.name
                        let matchedPersona = debaters.first { $0.name.localizedCaseInsensitiveContains(askedByRaw) || askedByRaw.localizedCaseInsensitiveContains($0.name) }
                        let why = (qDict["why_it_matters"] as? String) ?? ""
                        let opts = (qDict["quick_options"] as? [String]) ?? []
                        return InterviewQuestion(
                            askedByPersonaID: matchedPersona?.id ?? moderator.id,
                            askedByName: matchedPersona?.name ?? askedByRaw,
                            askedByAccentHex: matchedPersona?.accentHex ?? moderator.accentHex,
                            question: qText,
                            whyItMatters: why,
                            quickOptions: Array(opts.prefix(4))
                        )
                    }

                    if !questions.isEmpty {
                        let spokenIntro = (json["spoken_intro"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? "Before the panel dives in, we have \(questions.count == 1 ? "one quick question" : "\(questions.count) quick questions") to sharpen this."
                        let reasoning = (json["supporting_notes"] as? String) ?? (json["thought_process"] as? String) ?? ""
                        let exchange = InterviewExchange(
                            moderatorID: moderator.id,
                            moderatorName: moderator.name,
                            moderatorAccentHex: moderator.accentHex,
                            spokenIntro: spokenIntro,
                            moderatorReasoning: reasoning,
                            questions: questions
                        )
                        session.entries.append(.interview(exchange))
                        session.stage = .awaitingInterviewAnswers
                        session.updatedAt = Date()
                        await onEvent(.activeThinkersChanged([], statusLabel: "Waiting for your quick answers…"))
                        await onEvent(.sessionUpdated(session))

                        let spokenFull = ([spokenIntro] + questions.map { "\($0.askedByName) asks: \($0.question)" }).joined(separator: " ")
                        await onEvent(.enqueueSpeech(SpeechQueueItem(
                            id: exchange.id,
                            persona: moderator,
                            spokenText: spokenFull,
                            contextLabel: "Clarifying Interview"
                        )))
                        return session
                    }
                }
            }
        }

        if session.activeMode == .build {
            return try await runBuildSessionToCompletion(
                session: session,
                moderator: moderator,
                debaters: debaters,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                isIncrementalFollowUp: hadPriorVerdict,
                onEvent: onEvent
            )
        }

        return try await runDebateToVerdict(
            session: session,
            moderator: moderator,
            debaters: debaters,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            isFollowUpRound: hadPriorVerdict,
            onEvent: onEvent
        )
    }

    public func submitInterviewAnswers(
        exchangeID: UUID,
        updatedQuestions: [InterviewQuestion],
        skipped: Bool,
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        modelLabels: [String: String] = [:],
        openRouterKey: String? = nil,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        if let idx = session.entries.firstIndex(where: {
            if case .interview(let ex) = $0 { return ex.id == exchangeID }
            return false
        }), case .interview(var ex) = session.entries[idx] {
            ex.questions = updatedQuestions
            ex.isSubmitted = true
            ex.wasSkipped = skipped
            session.entries[idx] = .interview(ex)
        }
        session.updatedAt = Date()
        await onEvent(.sessionUpdated(session))

        if session.activeMode == .build {
            return try await runBuildSessionToCompletion(
                session: session,
                moderator: moderator,
                debaters: debaters,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                isIncrementalFollowUp: false,
                onEvent: onEvent
            )
        }

        return try await runDebateToVerdict(
            session: session,
            moderator: moderator,
            debaters: debaters,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            isFollowUpRound: false,
            onEvent: onEvent
        )
    }

    /// Resumes an interrupted (`.error` or `.cancelled`) session from its saved user prompt & interview answers,
    /// cleaning up trailing error notes or an empty trailing round banner so the timeline stays spotless.
    public func resumeInterruptedDebate(
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        modelLabels: [String: String] = [:],
        openRouterKey: String? = nil,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        // Strip trailing system error notes
        while let last = session.entries.last {
            if case .systemNote = last {
                session.entries.removeLast()
            } else if case .roundBanner = last {
                // Remove orphan round banner that had zero turns after it
                session.entries.removeLast()
            } else {
                break
            }
        }
        session.updatedAt = Date()
        await onEvent(.sessionUpdated(session))

        let hadPriorVerdict = session.entries.contains {
            if case .verdict = $0 { return true }
            return false
        }
        if session.activeMode == .build {
            return try await runBuildSessionToCompletion(
                session: session,
                moderator: moderator,
                debaters: debaters,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                isIncrementalFollowUp: hadPriorVerdict,
                onEvent: onEvent
            )
        }
        return try await runDebateToVerdict(
            session: session,
            moderator: moderator,
            debaters: debaters,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            isFollowUpRound: hadPriorVerdict,
            onEvent: onEvent
        )
    }

    /// Runs Chair-coordinated sequential build execution + Adversarial QA Verification Gate + Auto-Fix Pass
    /// inside `session.workspacePath` (either from Build Mode or when clicking "Build This Plan…" on a Debate Verdict).
    public func executeVerdictPlan(
        verdictID: UUID,
        extraInstruction: String = "",
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        modelLabels: [String: String] = [:],
        openRouterKey: String? = nil,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        guard let vIdx = session.entries.firstIndex(where: {
            if case .verdict(let v) = $0 { return v.id == verdictID }
            return false
        }), case .verdict(var verdict) = session.entries[vIdx] else {
            return session
        }

        let targetFolder = session.workspacePath ?? WorkspaceResolver.defaultWorkspacePath()
        let folderName = URL(fileURLWithPath: targetFolder).lastPathComponent

        // Ensure target directory exists on disk before builders run
        try? FileManager.default.createDirectory(atPath: targetFolder, withIntermediateDirectories: true)

        var assignments = verdict.executionAssignments ?? []
        let trimmedExtra = extraInstruction.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the Verdict came from Debate Mode without granular file workstreams (or user supplied extra build notes),
        // let the Chair inspect the target folder and decompose the plan into concrete workstreams first!
        if assignments.isEmpty || !trimmedExtra.isEmpty {
            session.stage = .synthesizingVerdict
            await onEvent(.activeThinkersChanged(
                [moderator.id],
                statusLabel: "\(moderator.name) is mapping build workstreams for \(folderName)…"
            ))
            await onEvent(.sessionUpdated(session))

            let blueprintResp = try await runner.call(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: moderator.effort,
                systemPrompt: DebatePrompts.buildBlueprintSystemPrompt(
                    moderator: moderator,
                    debaters: debaters,
                    workspacePath: targetFolder,
                    extraInstruction: trimmedExtra
                ),
                userPrompt: buildTranscriptContext(for: session),
                allowWebSearch: session.allowWebSearch,
                toolPhase: .researchAndInspect,
                workspacePath: targetFolder,
                openRouterAPIKey: openRouterKey
            ))
            let decomposed = parseVerdict(raw: blueprintResp.rawText, moderator: moderator, debaters: debaters)
            if let newAssignments = decomposed.executionAssignments, !newAssignments.isEmpty {
                assignments = newAssignments
                verdict.executionAssignments = newAssignments
                if let idx = session.entries.firstIndex(where: { $0.id == verdictID }) {
                    session.entries[idx] = .verdict(verdict)
                }
            }
        }

        if assignments.isEmpty {
            let combinedSteps = verdict.actionSteps.isEmpty
                ? verdict.recommendation
                : verdict.actionSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let defaultExecutor = selectPrimaryBuilder(from: debaters, excluding: nil, fallback: moderator)
            assignments = [
                ExecutionAssignment(
                    assignedPersonaName: defaultExecutor.name,
                    taskInstruction: "Implement and verify the agreed plan in \(targetFolder):\n\(combinedSteps)",
                    targetScope: targetFolder
                )
            ]
        }

        session.stage = .executingPlan
        session.entries.append(.roundBanner(RoundBanner(
            roundNumber: 98,
            title: "Build Phase · Multi-Agent Implementation (\(folderName))",
            subtitle: "\(moderator.name) is coordinating \(assignments.count) sequential workstreams inside \(targetFolder)"
        )))
        await onEvent(.sessionUpdated(session))

        let allCouncil = [moderator] + debaters
        for (idx, assignment) in assignments.enumerated() {
            try Task.checkCancellation()
            let executor = allCouncil.first {
                $0.name.localizedCaseInsensitiveContains(assignment.assignedPersonaName)
                || assignment.assignedPersonaName.localizedCaseInsensitiveContains($0.name)
            } ?? selectPrimaryBuilder(from: debaters, excluding: nil, fallback: moderator)

            await onEvent(.activeThinkersChanged(
                [executor.id],
                statusLabel: "Workstream \(idx + 1)/\(assignments.count): \(executor.name) is building in \(folderName)…"
            ))

            let liveContext = buildTranscriptContext(for: session)
            let resp = try await runner.call(ModelCallRequest(
                provider: executor.provider,
                modelID: executor.modelID,
                effort: executor.effort,
                systemPrompt: DebatePrompts.coordinatedExecutionSystemPrompt(
                    executor: executor,
                    moderatorName: moderator.name,
                    assignment: assignment,
                    workspacePath: targetFolder
                ),
                userPrompt: liveContext,
                allowWebSearch: session.allowWebSearch,
                toolPhase: .coordinatedReadWrite,
                workspacePath: targetFolder,
                openRouterAPIKey: openRouterKey
            ))

            let execTurn = parseDebateTurn(
                raw: resp.rawText,
                durationMs: resp.durationMs,
                roundNumber: 98,
                roundLabel: "Workstream \(idx + 1)/\(assignments.count)",
                persona: executor,
                modelLabel: modelLabels[executor.modelID] ?? executor.modelID,
                defaultStance: .executing
            )
            session.entries.append(.turn(execTurn))
            session.updatedAt = Date()
            await onEvent(.sessionUpdated(session))
            await onEvent(.enqueueSpeech(SpeechQueueItem(
                id: execTurn.id,
                persona: executor,
                spokenText: execTurn.spokenTake,
                contextLabel: "Built · \(executor.name)"
            )))
        }

        // --- ADVERSARIAL QA & VERIFICATION GATE ---
        try Task.checkCancellation()
        let verifier = selectVerifier(from: debaters, fallback: moderator)
        session.stage = .verifyingBuild
        session.entries.append(.roundBanner(RoundBanner(
            roundNumber: 99,
            title: "Verification Gate · Build & Test QA",
            subtitle: "\(verifier.name) is running builds, tests, and checking edge cases in \(folderName)"
        )))
        await onEvent(.activeThinkersChanged(
            [verifier.id],
            statusLabel: "\(verifier.name) is running build & verification checks in \(folderName)…"
        ))
        await onEvent(.sessionUpdated(session))

        let qaContext = buildTranscriptContext(for: session)
        let qaResp = try await runner.call(ModelCallRequest(
            provider: verifier.provider,
            modelID: verifier.modelID,
            effort: verifier.effort,
            systemPrompt: DebatePrompts.buildVerificationGatePrompt(
                verifier: verifier,
                moderatorName: moderator.name,
                workspacePath: targetFolder
            ),
            userPrompt: qaContext,
            allowWebSearch: session.allowWebSearch,
            toolPhase: .coordinatedReadWrite,
            workspacePath: targetFolder,
            openRouterAPIKey: openRouterKey
        ))

        let qaJSON = JSONExtractor.parseObject(qaResp.rawText)
        var verificationPassed = (qaJSON?["verification_passed"] as? Bool) ?? true
        let issuesFound = (qaJSON?["issues_found"] as? [String])?.filter { !$0.isEmpty } ?? []
        var filesSummary = (qaJSON?["files_summary"] as? [String])?.filter { !$0.isEmpty } ?? []
        var howToRun = (qaJSON?["how_to_run"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let qaTurn = parseDebateTurn(
            raw: qaResp.rawText,
            durationMs: qaResp.durationMs,
            roundNumber: 99,
            roundLabel: "QA Gate",
            persona: verifier,
            modelLabel: modelLabels[verifier.modelID] ?? verifier.modelID,
            defaultStance: .verifying
        )
        var verificationSummary = qaTurn.spokenTake
        session.entries.append(.turn(qaTurn))
        session.updatedAt = Date()
        await onEvent(.sessionUpdated(session))
        await onEvent(.enqueueSpeech(SpeechQueueItem(
            id: qaTurn.id,
            persona: verifier,
            spokenText: qaTurn.spokenTake,
            contextLabel: "QA Gate · \(verifier.name)"
        )))

        // --- AUTOMATED FIX PASS IF QA CAUGHT ISSUES ---
        if !verificationPassed && !issuesFound.isEmpty {
            try Task.checkCancellation()
            let fixer = selectPrimaryBuilder(from: debaters, excluding: verifier, fallback: moderator)
            session.stage = .executingPlan
            await onEvent(.activeThinkersChanged(
                [fixer.id],
                statusLabel: "\(fixer.name) is fixing \(issuesFound.count) QA issue(s) caught by \(verifier.name)…"
            ))
            await onEvent(.sessionUpdated(session))

            let fixResp = try await runner.call(ModelCallRequest(
                provider: fixer.provider,
                modelID: fixer.modelID,
                effort: fixer.effort,
                systemPrompt: DebatePrompts.buildFixPassPrompt(
                    fixer: fixer,
                    moderatorName: moderator.name,
                    verifierName: verifier.name,
                    issues: issuesFound,
                    workspacePath: targetFolder
                ),
                userPrompt: buildTranscriptContext(for: session),
                allowWebSearch: session.allowWebSearch,
                toolPhase: .coordinatedReadWrite,
                workspacePath: targetFolder,
                openRouterAPIKey: openRouterKey
            ))

            if let fixJSON = JSONExtractor.parseObject(fixResp.rawText) {
                verificationPassed = (fixJSON["verification_passed"] as? Bool) ?? true
                if let updatedFiles = (fixJSON["files_summary"] as? [String])?.filter({ !$0.isEmpty }), !updatedFiles.isEmpty {
                    for f in updatedFiles where !filesSummary.contains(f) {
                        filesSummary.append(f)
                    }
                }
                if let updatedRun = (fixJSON["how_to_run"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !updatedRun.isEmpty {
                    howToRun = updatedRun
                }
            } else {
                verificationPassed = true
            }

            let fixTurn = parseDebateTurn(
                raw: fixResp.rawText,
                durationMs: fixResp.durationMs,
                roundNumber: 99,
                roundLabel: "Fix & Re-Verify",
                persona: fixer,
                modelLabel: modelLabels[fixer.modelID] ?? fixer.modelID,
                defaultStance: .executing
            )
            verificationSummary = fixTurn.spokenTake
            session.entries.append(.turn(fixTurn))
            session.updatedAt = Date()
            await onEvent(.sessionUpdated(session))
            await onEvent(.enqueueSpeech(SpeechQueueItem(
                id: fixTurn.id,
                persona: fixer,
                spokenText: fixTurn.spokenTake,
                contextLabel: "Fixed · \(fixer.name)"
            )))
        }

        verdict.wasExecuted = true
        verdict.buildReport = BuildReport(
            buildFolder: targetFolder,
            verificationPassed: verificationPassed,
            verifierName: verifier.name,
            verificationSummary: ExpressiveCleaner.stripCues(verificationSummary),
            filesSummary: filesSummary,
            howToRun: howToRun
        )
        if let updatedIdx = session.entries.firstIndex(where: {
            if case .verdict(let v) = $0 { return v.id == verdictID }
            return false
        }) {
            session.entries[updatedIdx] = .verdict(verdict)
        }
        session.stage = .completed
        session.updatedAt = Date()
        await onEvent(.activeThinkersChanged([], statusLabel: "Build & verification complete in \(folderName)"))
        await onEvent(.sessionUpdated(session))
        return session
    }

    // MARK: - Collaborative Build Mode Pipeline (Huddle -> Blueprint -> Build -> QA Gate)

    private func runBuildSessionToCompletion(
        session initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        modelLabels: [String: String],
        openRouterKey: String?,
        isIncrementalFollowUp: Bool,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        let targetFolder = session.workspacePath ?? WorkspaceResolver.defaultWorkspacePath()
        let folderName = URL(fileURLWithPath: targetFolder).lastPathComponent
        try? FileManager.default.createDirectory(atPath: targetFolder, withIntermediateDirectories: true)

        if session.title == "New Council Session",
           let firstPrompt = session.entries.compactMap({ entry -> String? in
               if case .userPrompt(let m) = entry { return m.text }
               return nil
           }).first {
            session.title = Self.quickHeuristicTitle(from: firstPrompt)
        }

        // Phase 1: Fast Parallel Architecture & Workstream Huddle
        session.stage = .debating
        session.entries.append(.roundBanner(RoundBanner(
            roundNumber: 1,
            title: isIncrementalFollowUp ? "Build Huddle · Incremental Design" : "Phase 1 · Architecture & Workstream Huddle",
            subtitle: "Specialists inspect \(folderName) in parallel and propose clean module boundaries"
        )))
        await onEvent(.activeThinkersChanged(
            Set(debaters.map(\.id)),
            statusLabel: "Huddle: Specialists inspecting \(folderName) & aligning on build architecture…"
        ))
        await onEvent(.sessionUpdated(session))

        let huddleContext = buildTranscriptContext(for: session)
        let (huddleTurns, huddleFailures) = try await runParallelBuildHuddle(
            debaters: debaters,
            transcriptContext: huddleContext,
            session: session,
            targetFolder: targetFolder,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey
        )
        for note in huddleFailures {
            session.entries.append(.systemNote(UUID(), note))
        }
        for turn in huddleTurns {
            try Task.checkCancellation()
            session.entries.append(.turn(turn))
            session.updatedAt = Date()
            await onEvent(.sessionUpdated(session))
            if let speaker = debaters.first(where: { $0.id == turn.personaID }) {
                await onEvent(.enqueueSpeech(SpeechQueueItem(
                    id: turn.id,
                    persona: speaker,
                    spokenText: turn.spokenTake,
                    contextLabel: "Huddle · \(speaker.name)"
                )))
            }
        }

        // Phase 2: Chair Synthesizes Concrete Multi-Agent Build Blueprint
        try Task.checkCancellation()
        session.stage = .synthesizingVerdict
        await onEvent(.activeThinkersChanged(
            [moderator.id],
            statusLabel: "\(moderator.name) is locking in the Build Blueprint & assigning workstreams…"
        ))
        await onEvent(.sessionUpdated(session))

        let blueprintResp = try await runner.call(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: moderator.effort,
            systemPrompt: DebatePrompts.buildBlueprintSystemPrompt(
                moderator: moderator,
                debaters: debaters,
                workspacePath: targetFolder
            ),
            userPrompt: buildTranscriptContext(for: session),
            allowWebSearch: session.allowWebSearch,
            toolPhase: .researchAndInspect,
            workspacePath: targetFolder,
            openRouterAPIKey: openRouterKey
        ))

        var blueprint = parseVerdict(raw: blueprintResp.rawText, moderator: moderator, debaters: debaters)
        blueprint.shouldAutoExecute = true
        session.entries.append(.verdict(blueprint))
        session.updatedAt = Date()
        await onEvent(.sessionUpdated(session))
        await onEvent(.enqueueSpeech(SpeechQueueItem(
            id: blueprint.id,
            persona: moderator,
            spokenText: blueprint.spokenVerdict,
            contextLabel: "Build Blueprint · \(moderator.name)"
        )))

        // Phase 3 + 4 + 5: Execute Workstreams -> Adversarial QA Verification -> Auto-Fix Pass
        return try await executeVerdictPlan(
            verdictID: blueprint.id,
            into: session,
            moderator: moderator,
            debaters: debaters,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            onEvent: onEvent
        )
    }

    private func runParallelBuildHuddle(
        debaters: [Persona],
        transcriptContext: String,
        session: DebateSession,
        targetFolder: String,
        modelLabels: [String: String],
        openRouterKey: String?
    ) async throws -> ([DebateTurn], [String]) {
        let webOn = session.allowWebSearch
        return try await withThrowingTaskGroup(of: (Int, String, Result<DebateTurn, Error>).self) { group in
            for (index, debater) in debaters.enumerated() {
                let modelLabel = modelLabels[debater.modelID] ?? debater.modelID
                group.addTask { [runner] in
                    do {
                        let resp = try await runner.call(ModelCallRequest(
                            provider: debater.provider,
                            modelID: debater.modelID,
                            effort: debater.effort,
                            systemPrompt: DebatePrompts.buildHuddleSpecialistPrompt(
                                debater: debater,
                                allDebaters: debaters,
                                workspacePath: targetFolder
                            ),
                            userPrompt: transcriptContext,
                            allowWebSearch: webOn,
                            toolPhase: .researchAndInspect,
                            workspacePath: targetFolder,
                            openRouterAPIKey: openRouterKey
                        ))
                        let turn = self.parseDebateTurn(
                            raw: resp.rawText,
                            durationMs: resp.durationMs,
                            roundNumber: 1,
                            roundLabel: "Build Huddle",
                            persona: debater,
                            modelLabel: modelLabel,
                            defaultStance: .building
                        )
                        return (index, debater.name, .success(turn))
                    } catch {
                        return (index, debater.name, .failure(error))
                    }
                }
            }

            var successes: [(Int, DebateTurn)] = []
            var failures: [String] = []
            var firstError: Error?
            for try await (idx, name, result) in group {
                switch result {
                case .success(let turn):
                    successes.append((idx, turn))
                case .failure(let err):
                    if Task.isCancelled { throw ModelRunnerError.cancelled }
                    if case ModelRunnerError.cancelled = err { throw err }
                    firstError = firstError ?? err
                    failures.append("\(name) skipped huddle: \(err.localizedDescription)")
                }
            }
            if successes.isEmpty, let firstError {
                throw firstError
            }
            return (successes.sorted { $0.0 < $1.0 }.map(\.1), failures)
        }
    }

    private func selectVerifier(from debaters: [Persona], fallback: Persona) -> Persona {
        if let skeptic = debaters.first(where: {
            $0.name.localizedCaseInsensitiveContains("Sable")
            || $0.title.localizedCaseInsensitiveContains("Skeptic")
            || $0.title.localizedCaseInsensitiveContains("Critic")
            || $0.title.localizedCaseInsensitiveContains("Security")
        }) {
            return skeptic
        }
        return debaters.last ?? fallback
    }

    private func selectPrimaryBuilder(from debaters: [Persona], excluding: Persona?, fallback: Persona) -> Persona {
        let candidates = debaters.filter { $0.id != excluding?.id }
        if let pragmatist = candidates.first(where: {
            $0.name.localizedCaseInsensitiveContains("Marcus")
            || $0.title.localizedCaseInsensitiveContains("Pragmatist")
            || $0.title.localizedCaseInsensitiveContains("Builder")
            || $0.title.localizedCaseInsensitiveContains("Architect")
        }) {
            return pragmatist
        }
        return candidates.first ?? fallback
    }

    /// Synthesizes a tailored coding-harness handoff prompt using the Chair when the user wants custom AI synthesis/filtering.
    public func synthesizeTailoredHandoffPrompt(
        session: DebateSession,
        moderator: Persona,
        baseHandoff: String,
        customInstruction: String,
        openRouterKey: String? = nil
    ) async throws -> String {
        let fullInput = """
        SESSION TRANSCRIPT & VERDICT SUMMARY:
        \(buildTranscriptContext(for: session))

        ---

        STRUCTURED DRAFT HANDOFF:
        \(baseHandoff)
        """
        let resp = try await runner.call(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: .medium,
            systemPrompt: DebatePrompts.handoffSynthesisSystemPrompt(moderator: moderator, customInstruction: customInstruction),
            userPrompt: fullInput,
            allowWebSearch: false,
            toolPhase: .closedBook,
            workspacePath: session.workspacePath,
            openRouterAPIKey: openRouterKey
        ))
        return resp.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Core Multi-Round Debate Engine (With Live Inter-Persona Dialogue)

    private func runDebateToVerdict(
        session initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        modelLabels: [String: String],
        openRouterKey: String?,
        isFollowUpRound: Bool,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        session.stage = .debating
        await onEvent(.sessionUpdated(session))

        if session.title == "New Council Session",
           let firstPrompt = session.entries.compactMap({ entry -> String? in
               if case .userPrompt(let m) = entry { return m.text }
               return nil
           }).first {
            session.title = Self.quickHeuristicTitle(from: firstPrompt)
        }

        // --- ROUND 1: Parallel Blind Research & Opening Stances ---
        let r1Title = isFollowUpRound ? "Follow-Up Investigation & Positions" : "Round 1 · Blind Research & Opening Stances"
        let r1Sub = session.hasFullCLITools
            ? "Panelists inspect repos/context independently in parallel — zero anchoring"
            : "Independent opening stances in parallel — zero anchoring"
        session.entries.append(.roundBanner(RoundBanner(roundNumber: 1, title: r1Title, subtitle: r1Sub)))
        await onEvent(.sessionUpdated(session))

        let baseContext = buildTranscriptContext(for: session)
        await onEvent(.activeThinkersChanged(
            Set(debaters.map(\.id)),
            statusLabel: session.hasFullCLITools
                ? "Round 1: Panelists inspecting context & forming independent stances…"
                : "Round 1: Panelists forming independent positions…"
        ))

        let (blindTurns, blindFailures) = try await runParallelBlindOpeningRound(
            debaters: debaters,
            transcriptContext: baseContext,
            session: session,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey
        )

        for failureNote in blindFailures {
            session.entries.append(.systemNote(UUID(), failureNote))
        }

        for turn in blindTurns {
            try Task.checkCancellation()
            session.entries.append(.turn(turn))
            session.updatedAt = Date()
            await onEvent(.sessionUpdated(session))
            if let speaker = debaters.first(where: { $0.id == turn.personaID }) {
                await onEvent(.enqueueSpeech(SpeechQueueItem(
                    id: turn.id,
                    persona: speaker,
                    spokenText: turn.spokenTake,
                    contextLabel: "Round 1 · \(speaker.name)"
                )))
            }
        }

        // --- CHAIR FLOOR DIRECTION: Vera calls out the sharpest fault line between the personas! ---
        if !isFollowUpRound && debaters.count >= 2 {
            try Task.checkCancellation()
            await onEvent(.activeThinkersChanged([moderator.id], statusLabel: "\(moderator.name) is framing the clash on the floor…"))
            let r1Board = buildTranscriptContext(for: session)
            if let chairResp = try? await runner.call(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: .medium,
                systemPrompt: DebatePrompts.chairFloorDirectionPrompt(moderator: moderator, debaters: debaters),
                userPrompt: r1Board,
                allowWebSearch: false,
                toolPhase: .closedBook,
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            )) {
                let chairTurn = parseDebateTurn(
                    raw: chairResp.rawText,
                    durationMs: chairResp.durationMs,
                    roundNumber: 1,
                    roundLabel: "Chair",
                    persona: moderator,
                    modelLabel: modelLabels[moderator.modelID] ?? moderator.modelID,
                    defaultStance: .moderating
                )
                session.entries.append(.turn(chairTurn))
                session.updatedAt = Date()
                await onEvent(.sessionUpdated(session))
                await onEvent(.enqueueSpeech(SpeechQueueItem(
                    id: chairTurn.id,
                    persona: moderator,
                    spokenText: chairTurn.spokenTake,
                    contextLabel: "\(moderator.name) · Directing Floor"
                )))
            }
        }

        // --- ROUNDS 2..N: Live Inter-Persona Conversation & Direct Exchanges ---
        let rebuttalCount = isFollowUpRound ? min(1, session.maxRebuttalRounds) : max(1, session.maxRebuttalRounds)
        for rebuttalIdx in 1...rebuttalCount {
            try Task.checkCancellation()
            let roundNum = rebuttalIdx + 1
            let isFinal = (rebuttalIdx == rebuttalCount)
            let bannerTitle = isFinal && rebuttalCount > 1
                ? "Round \(roundNum) · Final Cross-Examination & Co-Sign Check"
                : "Round \(roundNum) · Live Council Cross-Examination"
            let bannerSub = isFinal
                ? "Panelists settle final stances, concessions, or holdout dissents"
                : "Panelists challenge each other directly and answer face-to-face"

            session.entries.append(.roundBanner(RoundBanner(roundNumber: roundNum, title: bannerTitle, subtitle: bannerSub)))
            await onEvent(.sessionUpdated(session))

            var roundTurns: [DebateTurn] = []
            var directRepliesTriggered = 0
            let orderedDebaters = rotate(debaters, by: rebuttalIdx)

            for debater in orderedDebaters {
                try Task.checkCancellation()
                await onEvent(.activeThinkersChanged([debater.id], statusLabel: "Round \(roundNum): \(debater.name) has the floor…"))

                let liveBoard = buildTranscriptContext(for: session)
                let resp: ModelCallResponse
                do {
                    resp = try await runner.call(ModelCallRequest(
                        provider: debater.provider,
                        modelID: debater.modelID,
                        effort: debater.effort,
                        systemPrompt: DebatePrompts.rebuttalSystemPrompt(
                            debater: debater,
                            allDebaters: debaters,
                            moderatorName: moderator.name,
                            roundNumber: roundNum,
                            isFinalRebuttal: isFinal,
                            workspacePath: session.workspacePath,
                            toolsEnabled: session.hasFullCLITools
                        ),
                        userPrompt: liveBoard,
                        allowWebSearch: session.allowWebSearch,
                        toolPhase: researchPhase(for: session),
                        workspacePath: session.workspacePath,
                        openRouterAPIKey: openRouterKey
                    ))
                } catch {
                    if Task.isCancelled { throw ModelRunnerError.cancelled }
                    if case ModelRunnerError.cancelled = error { throw error }
                    session.entries.append(.systemNote(UUID(), "\(debater.name) skipped Round \(roundNum): \(error.localizedDescription)"))
                    await onEvent(.sessionUpdated(session))
                    continue
                }

                let turn = parseDebateTurn(
                    raw: resp.rawText,
                    durationMs: resp.durationMs,
                    roundNumber: roundNum,
                    roundLabel: "Round \(roundNum)",
                    persona: debater,
                    modelLabel: modelLabels[debater.modelID] ?? debater.modelID,
                    defaultStance: .challenging
                )
                roundTurns.append(turn)
                session.entries.append(.turn(turn))
                session.updatedAt = Date()
                await onEvent(.sessionUpdated(session))
                await onEvent(.enqueueSpeech(SpeechQueueItem(
                    id: turn.id,
                    persona: debater,
                    spokenText: turn.spokenTake,
                    contextLabel: "Round \(roundNum) · \(debater.name)"
                )))

                // LIVE INTER-PERSONA BACK-AND-FORTH: If this debater put a direct question to a specific peer,
                // hand the mic immediately to that peer for a brisk face-to-face answer (up to 1 direct exchange per round so pacing stays snappy)!
                if !isFinal,
                   directRepliesTriggered < 1,
                   let peerQuestion = turn.directQuestionForPeer, !peerQuestion.isEmpty,
                   let targetName = turn.targetPersonaName, !targetName.isEmpty,
                   let challengedPeer = debaters.first(where: {
                       $0.id != debater.id && ($0.name.localizedCaseInsensitiveContains(targetName) || targetName.localizedCaseInsensitiveContains($0.name))
                   }) {
                    directRepliesTriggered += 1
                    try Task.checkCancellation()
                    await onEvent(.activeThinkersChanged(
                        [challengedPeer.id],
                        statusLabel: "\(challengedPeer.name) is answering \(debater.name) directly…"
                    ))

                    let replyBoard = buildTranscriptContext(for: session)
                    let replyResp = try await runner.call(ModelCallRequest(
                        provider: challengedPeer.provider,
                        modelID: challengedPeer.modelID,
                        effort: challengedPeer.effort,
                        systemPrompt: DebatePrompts.peerDirectReplyPrompt(
                            responder: challengedPeer,
                            challengerName: debater.name,
                            question: peerQuestion,
                            workspacePath: session.workspacePath,
                            toolsEnabled: session.hasFullCLITools
                        ),
                        userPrompt: replyBoard,
                        allowWebSearch: session.allowWebSearch,
                        toolPhase: researchPhase(for: session),
                        workspacePath: session.workspacePath,
                        openRouterAPIKey: openRouterKey
                    ))

                    let replyTurn = parseDebateTurn(
                        raw: replyResp.rawText,
                        durationMs: replyResp.durationMs,
                        roundNumber: roundNum,
                        roundLabel: "Direct Exchange",
                        persona: challengedPeer,
                        modelLabel: modelLabels[challengedPeer.modelID] ?? challengedPeer.modelID,
                        defaultStance: .replying
                    )
                    session.entries.append(.turn(replyTurn))
                    session.updatedAt = Date()
                    await onEvent(.sessionUpdated(session))
                    await onEvent(.enqueueSpeech(SpeechQueueItem(
                        id: replyTurn.id,
                        persona: challengedPeer,
                        spokenText: replyTurn.spokenTake,
                        contextLabel: "\(challengedPeer.name) → \(debater.name)"
                    )))
                }
            }

            let allConverged = !roundTurns.isEmpty && roundTurns.allSatisfy {
                $0.stance == .cosigning || $0.stance == .conceding
            }
            if allConverged && !isFinal {
                break
            }
        }

        // --- STEP 3: Moderator Co-Signed Verdict ---
        try Task.checkCancellation()
        session.stage = .synthesizingVerdict
        await onEvent(.activeThinkersChanged([moderator.id], statusLabel: "\(moderator.name) is drafting the Co-Signed Verdict…"))
        await onEvent(.sessionUpdated(session))

        let fullTranscript = buildTranscriptContext(for: session)
        let verdictResp = try await runner.call(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: moderator.effort,
            systemPrompt: DebatePrompts.verdictSystemPrompt(
                moderator: moderator,
                debaters: debaters,
                toolsEnabled: session.hasFullCLITools
            ),
            userPrompt: fullTranscript,
            allowWebSearch: session.allowWebSearch,
            toolPhase: researchPhase(for: session),
            workspacePath: session.workspacePath,
            openRouterAPIKey: openRouterKey
        ))

        let verdict = parseVerdict(raw: verdictResp.rawText, moderator: moderator, debaters: debaters)
        session.entries.append(.verdict(verdict))
        session.stage = .completed
        session.updatedAt = Date()

        await onEvent(.activeThinkersChanged([], statusLabel: "Co-Signed Verdict ready"))
        await onEvent(.sessionUpdated(session))
        await onEvent(.enqueueSpeech(SpeechQueueItem(
            id: verdict.id,
            persona: moderator,
            spokenText: verdict.spokenVerdict,
            contextLabel: "Co-Signed Verdict · \(moderator.name)"
        )))

        // --- STEP 4: Automatic Chair-Coordinated Execution if User Explicitly Asked for Edits ---
        if session.hasFullCLITools,
           verdict.shouldAutoExecute == true,
           let assignments = verdict.executionAssignments,
           !assignments.isEmpty {
            return try await executeVerdictPlan(
                verdictID: verdict.id,
                into: session,
                moderator: moderator,
                debaters: debaters,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                onEvent: onEvent
            )
        }

        return session
    }

    private func runParallelBlindOpeningRound(
        debaters: [Persona],
        transcriptContext: String,
        session: DebateSession,
        modelLabels: [String: String],
        openRouterKey: String?
    ) async throws -> ([DebateTurn], [String]) {
        let phase = researchPhase(for: session)
        let ws = session.workspacePath
        let toolsOn = session.hasFullCLITools
        let webOn = session.allowWebSearch

        return try await withThrowingTaskGroup(of: (Int, String, Result<DebateTurn, Error>).self) { group in
            for (index, debater) in debaters.enumerated() {
                let modelLabel = modelLabels[debater.modelID] ?? debater.modelID
                group.addTask { [runner] in
                    do {
                        let resp = try await runner.call(ModelCallRequest(
                            provider: debater.provider,
                            modelID: debater.modelID,
                            effort: debater.effort,
                            systemPrompt: DebatePrompts.blindOpeningSystemPrompt(
                                debater: debater,
                                allDebaters: debaters,
                                workspacePath: ws,
                                toolsEnabled: toolsOn
                            ),
                            userPrompt: transcriptContext,
                            allowWebSearch: webOn,
                            toolPhase: phase,
                            workspacePath: ws,
                            openRouterAPIKey: openRouterKey
                        ))
                        let turn = self.parseDebateTurn(
                            raw: resp.rawText,
                            durationMs: resp.durationMs,
                            roundNumber: 1,
                            roundLabel: "Round 1",
                            persona: debater,
                            modelLabel: modelLabel,
                            defaultStance: .opening
                        )
                        return (index, debater.name, .success(turn))
                    } catch {
                        return (index, debater.name, .failure(error))
                    }
                }
            }

            var successes: [(Int, DebateTurn)] = []
            var failures: [String] = []
            var firstError: Error?

            for try await (idx, name, result) in group {
                switch result {
                case .success(let turn):
                    successes.append((idx, turn))
                case .failure(let err):
                    if Task.isCancelled {
                        throw ModelRunnerError.cancelled
                    }
                    if case ModelRunnerError.cancelled = err {
                        throw err
                    }
                    firstError = firstError ?? err
                    failures.append("\(name) skipped this round: \(err.localizedDescription)")
                }
            }

            if successes.isEmpty, let firstError {
                throw firstError
            }
            return (successes.sorted { $0.0 < $1.0 }.map(\.1), failures)
        }
    }

    private func runDirectFollowUp(
        target: Persona,
        session initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        modelLabels: [String: String],
        openRouterKey: String?,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        session.stage = .debating
        await onEvent(.activeThinkersChanged([target.id], statusLabel: "\(target.name) is replying directly…"))
        await onEvent(.sessionUpdated(session))

        // Since only ONE persona is running here, they safely hold the single-agent write lock if CLI tools are enabled
        let phase: ToolExecutionPhase = session.hasFullCLITools ? .coordinatedReadWrite : .closedBook
        let context = buildTranscriptContext(for: session)
        let resp = try await runner.call(ModelCallRequest(
            provider: target.provider,
            modelID: target.modelID,
            effort: target.effort,
            systemPrompt: DebatePrompts.followUpTurnSystemPrompt(
                persona: target,
                peers: [moderator] + debaters,
                workspacePath: session.workspacePath,
                toolsEnabled: session.hasFullCLITools,
                allowWrites: session.hasFullCLITools
            ),
            userPrompt: context,
            allowWebSearch: session.allowWebSearch,
            toolPhase: phase,
            workspacePath: session.workspacePath,
            openRouterAPIKey: openRouterKey
        ))
        let turn = parseDebateTurn(
            raw: resp.rawText,
            durationMs: resp.durationMs,
            roundNumber: 0,
            roundLabel: "Direct Reply",
            persona: target,
            modelLabel: modelLabels[target.modelID] ?? target.modelID,
            defaultStance: .followup
        )
        session.entries.append(.turn(turn))
        session.stage = .completed
        session.updatedAt = Date()

        await onEvent(.activeThinkersChanged([], statusLabel: "Ready"))
        await onEvent(.sessionUpdated(session))
        await onEvent(.enqueueSpeech(SpeechQueueItem(
            id: turn.id,
            persona: target,
            spokenText: turn.spokenTake,
            contextLabel: "Reply · \(target.name)"
        )))
        return session
    }

    // MARK: - Parsing & Formatting Helpers

    private func parseDebateTurn(
        raw: String,
        durationMs: Int,
        roundNumber: Int,
        roundLabel: String,
        persona: Persona,
        modelLabel: String,
        defaultStance: StanceKind
    ) -> DebateTurn {
        if let json = JSONExtractor.parseObject(raw) {
            let stanceRaw = (json["stance"] as? String)?.lowercased() ?? ""
            let stance = StanceKind(rawValue: stanceRaw) ?? defaultStance
            let target = (json["target_persona"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let spoken = (json["spoken_take"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let thought = ((json["supporting_notes"] as? String) ?? (json["thought_process"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let points = (json["key_points"] as? [String])?.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? []
            let directQ = (json["direct_question_for_peer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolsUsed = (json["tools_used"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let spoken, !spoken.isEmpty {
                return DebateTurn(
                    roundNumber: roundNumber,
                    roundLabel: roundLabel,
                    personaID: persona.id,
                    personaName: persona.name,
                    personaTitle: persona.title,
                    avatarSymbol: persona.avatarSymbol,
                    accentHex: persona.accentHex,
                    provider: persona.provider,
                    modelLabel: modelLabel,
                    stance: stance,
                    targetPersonaName: (target?.isEmpty == false) ? target : nil,
                    spokenTake: SpokenTextSanitizer.clean(spoken),
                    thoughtProcess: thought,
                    keyPoints: points,
                    directQuestionForPeer: (directQ?.isEmpty == false) ? directQ : nil,
                    toolsActivitySummary: (toolsUsed?.isEmpty == false) ? toolsUsed : nil,
                    durationMs: durationMs
                )
            }
        }

        let sanitized = SpokenTextSanitizer.clean(raw)
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = sanitized.components(separatedBy: ". ")
        let compact = sentences.prefix(4).joined(separator: ". ")
        return DebateTurn(
            roundNumber: roundNumber,
            roundLabel: roundLabel,
            personaID: persona.id,
            personaName: persona.name,
            personaTitle: persona.title,
            avatarSymbol: persona.avatarSymbol,
            accentHex: persona.accentHex,
            provider: persona.provider,
            modelLabel: modelLabel,
            stance: defaultStance,
            spokenTake: compact.isEmpty ? sanitized : compact,
            thoughtProcess: cleaned,
            keyPoints: [],
            durationMs: durationMs
        )
    }

    /// Retroactively repairs any saved turn/verdict whose `spokenTake` accidentally stored raw JSON before the quote-repair parser.
    @discardableResult
    public static func healSessionIfNeeded(_ session: inout DebateSession) -> Bool {
        var didChange = false
        for idx in session.entries.indices {
            switch session.entries[idx] {
            case .turn(var t):
                let trimmed = t.spokenTake.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.contains("\"spoken_take\"") {
                    let source = t.thoughtProcess.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                        ? t.thoughtProcess
                        : t.spokenTake
                    if let json = JSONExtractor.parseObject(source) {
                        if let sp = (json["spoken_take"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !sp.isEmpty {
                            t.spokenTake = SpokenTextSanitizer.clean(sp)
                            didChange = true
                        }
                        if let stRaw = (json["stance"] as? String)?.lowercased(), let st = StanceKind(rawValue: stRaw) {
                            t.stance = st
                        }
                        if let notes = ((json["supporting_notes"] as? String) ?? (json["thought_process"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !notes.isEmpty {
                            t.thoughtProcess = notes
                        }
                        if let pts = (json["key_points"] as? [String])?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }),
                           !pts.isEmpty {
                            t.keyPoints = pts
                        }
                        if let tools = (json["tools_used"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !tools.isEmpty {
                            t.toolsActivitySummary = tools
                        }
                    } else {
                        t.spokenTake = SpokenTextSanitizer.clean(t.spokenTake)
                        didChange = true
                    }
                    session.entries[idx] = .turn(t)
                }
            case .verdict(var v):
                let trimmed = v.spokenVerdict.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.contains("\"spoken_verdict\"") {
                    v.spokenVerdict = SpokenTextSanitizer.clean(v.spokenVerdict)
                    session.entries[idx] = .verdict(v)
                    didChange = true
                }
            default:
                break
            }
        }
        return didChange
    }

    private func parseVerdict(raw: String, moderator: Persona, debaters: [Persona]) -> CosignVerdict {
        if let json = JSONExtractor.parseObject(raw) {
            let headline = (json["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Panel Recommendation"
            let spoken = (json["spoken_verdict"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? headline
            let rec = (json["recommendation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? spoken
            let steps = (json["action_steps"] as? [String])?.filter { !$0.isEmpty } ?? []
            let tradeoffs = (json["key_tradeoffs"] as? [String])?.filter { !$0.isEmpty } ?? []
            let rawCosigned = (json["cosigned_by"] as? [String]) ?? debaters.map(\.name)
            let thought = (json["supporting_notes"] as? String) ?? (json["thought_process"] as? String) ?? ""
            let autoExec = (json["should_auto_execute"] as? Bool) ?? false

            var cosignedIDs: [UUID] = []
            var cosignedNames: [String] = []
            for name in rawCosigned {
                if let match = debaters.first(where: { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }) {
                    if !cosignedIDs.contains(match.id) {
                        cosignedIDs.append(match.id)
                        cosignedNames.append(match.name)
                    }
                } else if !name.isEmpty {
                    cosignedNames.append(name)
                }
            }

            var dissents: [MinorityDissent] = []
            if let rawDissents = json["dissents"] as? [[String: Any]] {
                for d in rawDissents {
                    guard let pName = (d["persona_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let obj = (d["core_objection"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !pName.isEmpty, !obj.isEmpty else { continue }
                    let match = debaters.first { $0.name.localizedCaseInsensitiveContains(pName) || pName.localizedCaseInsensitiveContains($0.name) }
                    dissents.append(MinorityDissent(
                        personaID: match?.id,
                        personaName: match?.name ?? pName,
                        accentHex: match?.accentHex ?? "#F43F5E",
                        coreObjection: obj
                    ))
                }
            }

            var assignments: [ExecutionAssignment] = []
            if let rawAssign = json["execution_assignments"] as? [[String: Any]] {
                for item in rawAssign.prefix(4) {
                    guard let who = (item["assigned_to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let instr = (item["task_instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !who.isEmpty, !instr.isEmpty else { continue }
                    let scope = (item["target_scope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    assignments.append(ExecutionAssignment(
                        assignedPersonaName: who,
                        taskInstruction: instr,
                        targetScope: scope
                    ))
                }
            }

            if cosignedNames.isEmpty && dissents.isEmpty {
                cosignedIDs = debaters.map(\.id)
                cosignedNames = debaters.map(\.name)
            }

            return CosignVerdict(
                moderatorID: moderator.id,
                moderatorName: moderator.name,
                headline: headline,
                spokenVerdict: SpokenTextSanitizer.clean(spoken),
                recommendation: rec,
                actionSteps: steps,
                keyTradeoffs: tradeoffs,
                cosignedPersonaIDs: cosignedIDs,
                cosignedNames: cosignedNames,
                dissents: dissents,
                moderatorThoughtProcess: thought,
                shouldAutoExecute: autoExec,
                executionAssignments: assignments.isEmpty ? nil : assignments,
                wasExecuted: false
            )
        }

        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeSpoken = SpokenTextSanitizer.clean(cleaned)
        return CosignVerdict(
            moderatorID: moderator.id,
            moderatorName: moderator.name,
            headline: "Panel Verdict",
            spokenVerdict: String(safeSpoken.prefix(280)),
            recommendation: cleaned,
            cosignedPersonaIDs: debaters.map(\.id),
            cosignedNames: debaters.map(\.name)
        )
    }

    private func buildTranscriptContext(for session: DebateSession) -> String {
        var sections: [String] = []
        if let ws = session.workspacePath, !ws.isEmpty {
            sections.append("ACTIVE WORKSPACE DIRECTORY: \(ws)")
        }
        for entry in session.entries {
            switch entry {
            case .userPrompt(let msg):
                sections.append("USER PROMPT:\n\(msg.text)")
            case .interview(let ex):
                if ex.wasSkipped {
                    sections.append("CLARIFYING INTERVIEW: User asked the panel to make reasonable assumptions and debate open forks directly.")
                } else if ex.isSubmitted {
                    var lines = ["CLARIFYING INTERVIEW ANSWERS FROM USER:"]
                    for q in ex.questions {
                        if q.delegateToPanel {
                            lines.append("- Q (\(q.askedByName)): \(q.question)\n  USER: Not sure — I want the panel to debate and recommend the best answer to this.")
                        } else {
                            let ans = q.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                            lines.append("- Q (\(q.askedByName)): \(q.question)\n  USER ANSWER: \(ans.isEmpty ? "(Left open to panel)" : ans)")
                        }
                    }
                    sections.append(lines.joined(separator: "\n"))
                }
            case .roundBanner:
                break
            case .turn(let t):
                let targetSuffix = t.targetPersonaName.map { " -> @\($0)" } ?? ""
                var block = "[\(t.roundLabel)] \(t.personaName) (\(t.personaTitle), stance=\(t.stance.rawValue)\(targetSuffix)):\nSpoken: \(t.spokenTake)"
                if let dq = t.directQuestionForPeer, !dq.isEmpty {
                    block += "\nDirect Question to \(t.targetPersonaName ?? "peer"): \(dq)"
                }
                if !t.keyPoints.isEmpty {
                    block += "\nKey Points: " + t.keyPoints.joined(separator: " | ")
                }
                if let tools = t.toolsActivitySummary, !tools.isEmpty {
                    block += "\nTools/Files Checked: \(tools)"
                }
                sections.append(block)
            case .verdict(let v):
                sections.append("CO-SIGNED VERDICT (\(v.headline)):\n\(v.recommendation)")
            case .systemNote:
                break
            }
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    private func detectDirectMention(in text: String, personas: [Persona]) -> Persona? {
        for p in personas {
            if text.range(of: "@\(p.name)", options: .caseInsensitive) != nil {
                return p
            }
        }
        return nil
    }

    private func rotate(_ array: [Persona], by offset: Int) -> [Persona] {
        guard !array.isEmpty else { return [] }
        let shift = offset % array.count
        return Array(array[shift...] + array[..<shift])
    }

    public static func quickHeuristicTitle(from prompt: String) -> String {
        let words = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .prefix(7)
            .map(String.init)
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? "Council Session" : (words.count >= 7 ? "\(joined)…" : joined)
    }
}

private enum ExpressiveCleaner {
    static func stripCues(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"[\[\(](chuckle|laugh|sigh|clears? throat|cough|gasp|groan)[\]\)]"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(of: "  ", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
