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
            let resp = try await runner.call(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: moderator.effort,
                systemPrompt: DebatePrompts.intakeSystemPrompt(
                    moderator: moderator,
                    debaters: debaters,
                    workspacePath: session.workspacePath,
                    toolsEnabled: session.hasFullCLITools
                ),
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
                        let reasoning = (json["thought_process"] as? String) ?? ""
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

    /// Runs Chair-coordinated sequential write execution for a Co-Signed Verdict (either automatically or when the user clicks "Execute Plan").
    public func executeVerdictPlan(
        verdictID: UUID,
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

        session.stage = .executingPlan
        session.entries.append(.roundBanner(RoundBanner(
            roundNumber: 99,
            title: "Chair-Coordinated Execution",
            subtitle: "\(moderator.name) is coordinating sequential edits — one persona holds the write lock at a time"
        )))
        await onEvent(.sessionUpdated(session))

        // Build assignments from verdict (or synthesize 1 clean assignment from actionSteps if none were pre-populated)
        var assignments = verdict.executionAssignments ?? []
        if assignments.isEmpty {
            let combinedSteps = verdict.actionSteps.isEmpty
                ? verdict.recommendation
                : verdict.actionSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            let defaultExecutor = debaters.first ?? moderator
            assignments = [
                ExecutionAssignment(
                    assignedPersonaName: defaultExecutor.name,
                    taskInstruction: "Implement and verify the Co-Signed Verdict:\n\(combinedSteps)",
                    targetScope: session.workspacePath ?? ""
                )
            ]
        }

        let allCouncil = [moderator] + debaters
        for (idx, assignment) in assignments.enumerated() {
            try Task.checkCancellation()
            let executor = allCouncil.first {
                $0.name.localizedCaseInsensitiveContains(assignment.assignedPersonaName)
                || assignment.assignedPersonaName.localizedCaseInsensitiveContains($0.name)
            } ?? moderator

            await onEvent(.activeThinkersChanged(
                [executor.id],
                statusLabel: "Step \(idx + 1)/\(assignments.count): \(executor.name) is executing edits (\(moderator.name) coordinating)…"
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
                    workspacePath: session.workspacePath
                ),
                userPrompt: liveContext,
                allowWebSearch: session.allowWebSearch,
                toolPhase: .coordinatedReadWrite,
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            ))

            let execTurn = parseDebateTurn(
                raw: resp.rawText,
                durationMs: resp.durationMs,
                roundNumber: 99,
                roundLabel: "Execution \(idx + 1)/\(assignments.count)",
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
                contextLabel: "Executed · \(executor.name)"
            )))
        }

        verdict.wasExecuted = true
        if let updatedIdx = session.entries.firstIndex(where: {
            if case .verdict(let v) = $0 { return v.id == verdictID }
            return false
        }) {
            session.entries[updatedIdx] = .verdict(verdict)
        }
        session.stage = .completed
        session.updatedAt = Date()
        await onEvent(.activeThinkersChanged([], statusLabel: "Coordinated edits complete"))
        await onEvent(.sessionUpdated(session))
        return session
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

        let blindTurns = try await runParallelBlindOpeningRound(
            debaters: debaters,
            transcriptContext: baseContext,
            session: session,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey
        )

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
            let chairResp = try await runner.call(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: .medium,
                systemPrompt: DebatePrompts.chairFloorDirectionPrompt(moderator: moderator, debaters: debaters),
                userPrompt: r1Board,
                allowWebSearch: false,
                toolPhase: .closedBook,
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            ))
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
                let resp = try await runner.call(ModelCallRequest(
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
    ) async throws -> [DebateTurn] {
        let phase = researchPhase(for: session)
        let ws = session.workspacePath
        let toolsOn = session.hasFullCLITools
        let webOn = session.allowWebSearch

        return try await withThrowingTaskGroup(of: (Int, DebateTurn).self) { group in
            for (index, debater) in debaters.enumerated() {
                let modelLabel = modelLabels[debater.modelID] ?? debater.modelID
                group.addTask { [runner] in
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
                    return (index, turn)
                }
            }
            var indexed: [(Int, DebateTurn)] = []
            for try await pair in group {
                indexed.append(pair)
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
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
            let thought = (json["thought_process"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                    spokenTake: spoken,
                    thoughtProcess: thought,
                    keyPoints: points,
                    directQuestionForPeer: (directQ?.isEmpty == false) ? directQ : nil,
                    toolsActivitySummary: (toolsUsed?.isEmpty == false) ? toolsUsed : nil,
                    durationMs: durationMs
                )
            }
        }

        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = cleaned.components(separatedBy: ". ")
        let compact = sentences.prefix(3).joined(separator: ". ")
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
            spokenTake: compact.isEmpty ? cleaned : compact,
            thoughtProcess: cleaned,
            keyPoints: [],
            durationMs: durationMs
        )
    }

    private func parseVerdict(raw: String, moderator: Persona, debaters: [Persona]) -> CosignVerdict {
        if let json = JSONExtractor.parseObject(raw) {
            let headline = (json["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Panel Recommendation"
            let spoken = (json["spoken_verdict"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? headline
            let rec = (json["recommendation"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? spoken
            let steps = (json["action_steps"] as? [String])?.filter { !$0.isEmpty } ?? []
            let tradeoffs = (json["key_tradeoffs"] as? [String])?.filter { !$0.isEmpty } ?? []
            let rawCosigned = (json["cosigned_by"] as? [String]) ?? debaters.map(\.name)
            let thought = (json["thought_process"] as? String) ?? ""
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
                spokenVerdict: spoken,
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
        return CosignVerdict(
            moderatorID: moderator.id,
            moderatorName: moderator.name,
            headline: "Panel Verdict",
            spokenVerdict: String(cleaned.prefix(280)),
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
