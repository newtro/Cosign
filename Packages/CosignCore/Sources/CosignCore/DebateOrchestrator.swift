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

    public static func activeImagePaths(in session: DebateSession) -> [String] {
        var paths: [String] = []
        for entry in session.entries {
            if case .userPrompt(let msg) = entry {
                for att in msg.imageAttachments where !att.filePath.isEmpty && !paths.contains(att.filePath) {
                    paths.append(att.filePath)
                }
            }
        }
        return Array(paths.suffix(8))
    }

    private func callModel(_ request: ModelCallRequest, in session: DebateSession) async throws -> ModelCallResponse {
        var req = request
        if req.imagePaths.isEmpty {
            req.imagePaths = Self.activeImagePaths(in: session)
        }
        return try await runner.call(req)
    }

    public func submitUserMessage(
        text: String,
        attachments: [ChatImageAttachment] = [],
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        allPersonas: [Persona] = [],
        modelLabels: [String: String] = [:],
        openRouterKey: String? = nil,
        skipInterview: Bool = false,
        steeringInbox: SteeringInbox? = nil,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        let trimmedRaw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRaw.isEmpty || !attachments.isEmpty else { return session }
        let trimmed = trimmedRaw.isEmpty
            ? (session.activeMode == .build
                ? "Inspect the attached reference image(s) and implement/fix accordingly."
                : "Inspect the attached image(s) and share your assessment.")
            : trimmedRaw

        let hadPriorVerdict = session.entries.contains {
            if case .verdict = $0 { return true }
            return false
        }

        session.entries.append(.userPrompt(UserPromptMessage(text: trimmed, attachments: attachments)))
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
                steeringInbox: steeringInbox,
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
            var resp = try await callModel(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: moderator.effort,
                systemPrompt: intakeSysPrompt,
                userPrompt: buildTranscriptContext(for: session),
                allowWebSearch: session.allowWebSearch,
                toolPhase: researchPhase(for: session),
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            ), in: session)

            // If user submitted live steering while intake was scanning, drain immediately so the Chair incorporates it right away
            let intakeSteered = await drainSteeringMessages(steeringInbox, into: &session, onEvent: onEvent)
            if !intakeSteered.isEmpty {
                await onEvent(.activeThinkersChanged(
                    [moderator.id],
                    statusLabel: "\(moderator.name) is incorporating your live steering into intake…"
                ))
                resp = try await callModel(ModelCallRequest(
                    provider: moderator.provider,
                    modelID: moderator.modelID,
                    effort: moderator.effort,
                    systemPrompt: intakeSysPrompt,
                    userPrompt: buildTranscriptContext(for: session),
                    allowWebSearch: session.allowWebSearch,
                    toolPhase: researchPhase(for: session),
                    workspacePath: session.workspacePath,
                    openRouterAPIKey: openRouterKey
                ), in: session)
            }

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
                        // Fallback spoken intro template: literal language only (no metaphors, similes, or idioms)
                        let spokenIntro = (json["spoken_intro"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? "Before the panel starts, we have \(questions.count == 1 ? "one quick question" : "\(questions.count) quick questions") to clarify the missing details."
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
                allPersonas: allPersonas,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                isIncrementalFollowUp: hadPriorVerdict,
                steeringInbox: steeringInbox,
                onEvent: onEvent
            )
        }

        return try await runDebateToVerdict(
            session: session,
            moderator: moderator,
            debaters: debaters,
            allPersonas: allPersonas,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            isFollowUpRound: hadPriorVerdict,
            steeringInbox: steeringInbox,
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
        allPersonas: [Persona] = [],
        modelLabels: [String: String] = [:],
        openRouterKey: String? = nil,
        steeringInbox: SteeringInbox? = nil,
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
                allPersonas: allPersonas,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                isIncrementalFollowUp: false,
                steeringInbox: steeringInbox,
                onEvent: onEvent
            )
        }

        return try await runDebateToVerdict(
            session: session,
            moderator: moderator,
            debaters: debaters,
            allPersonas: allPersonas,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            isFollowUpRound: false,
            steeringInbox: steeringInbox,
            onEvent: onEvent
        )
    }

    /// Resumes an interrupted (`.error` or `.cancelled`) session from its saved user prompt & interview answers,
    /// cleaning up trailing error notes or an empty trailing round banner so the timeline stays spotless.
    public func resumeInterruptedDebate(
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        allPersonas: [Persona] = [],
        modelLabels: [String: String] = [:],
        openRouterKey: String? = nil,
        steeringInbox: SteeringInbox? = nil,
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
                allPersonas: allPersonas,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                isIncrementalFollowUp: hadPriorVerdict,
                steeringInbox: steeringInbox,
                onEvent: onEvent
            )
        }
        return try await runDebateToVerdict(
            session: session,
            moderator: moderator,
            debaters: debaters,
            allPersonas: allPersonas,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            isFollowUpRound: hadPriorVerdict,
            steeringInbox: steeringInbox,
            onEvent: onEvent
        )
    }

    /// Runs Chair-coordinated sequential build execution + Adversarial QA Verification Gate + Auto-Fix Pass
    /// + Optional Independent Completeness Reviewer & Remediation Loop inside `session.workspacePath`.
    public func executeVerdictPlan(
        verdictID: UUID,
        extraInstruction: String = "",
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        allPersonas: [Persona] = [],
        modelLabels: [String: String] = [:],
        openRouterKey: String? = nil,
        steeringInbox: SteeringInbox? = nil,
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
            _ = await drainSteeringMessages(steeringInbox, into: &session, onEvent: onEvent)
            session.stage = .synthesizingVerdict
            await onEvent(.activeThinkersChanged(
                [moderator.id],
                statusLabel: "\(moderator.name) is mapping build workstreams for \(folderName)…"
            ))
            await onEvent(.sessionUpdated(session))

            let blueprintResp = try await callModel(ModelCallRequest(
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
            ), in: session)
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
            let defaultExecutor = selectPrimaryBuilder(from: debaters, excluding: nil, fallback: moderator, forTask: combinedSteps)
            assignments = [
                ExecutionAssignment(
                    assignedPersonaName: defaultExecutor.name,
                    taskInstruction: "Implement and verify the agreed plan in \(targetFolder):\n\(combinedSteps)",
                    targetScope: targetFolder
                )
            ]
        }

        let initialWaves = Self.partitionIntoParallelWaves(assignments, workspaceRoot: targetFolder)
        let hasParallelWave = initialWaves.contains { $0.items.count > 1 }
        session.stage = .executingPlan
        session.entries.append(.roundBanner(RoundBanner(
            roundNumber: 98,
            title: hasParallelWave
                ? "Build Phase · Parallel Multi-Agent Waves (\(folderName))"
                : "Build Phase · Multi-Agent Implementation (\(folderName))",
            subtitle: "\(moderator.name) dispatched \(assignments.count) workstream\(assignments.count == 1 ? "" : "s") across \(initialWaves.count) wave\(initialWaves.count == 1 ? "" : "s") (sub-agents unlocked)"
        )))
        await onEvent(.sessionUpdated(session))

        let allCouncil = [moderator] + debaters
        var initialFilesSummary: [String] = []
        var initialHowToRun: String = ""
        session = try await runExecutionWaves(
            waves: initialWaves,
            into: session,
            moderator: moderator,
            allCouncil: allCouncil,
            debaters: debaters,
            excludingBuilder: nil,
            reviewerNameForRemediation: nil,
            remediationPassIndex: nil,
            targetFolder: targetFolder,
            folderName: folderName,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            steeringInbox: steeringInbox,
            filesSummary: &initialFilesSummary,
            howToRun: &initialHowToRun,
            onEvent: onEvent
        )

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
        let qaResp = try await callModel(ModelCallRequest(
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
        ), in: session)

        let qaJSON = JSONExtractor.parseObject(qaResp.rawText)
        var verificationPassed = (qaJSON?["verification_passed"] as? Bool) ?? true
        let issuesFound = (qaJSON?["issues_found"] as? [String])?.filter { !$0.isEmpty } ?? []
        var filesSummary = initialFilesSummary
        for f in ((qaJSON?["files_summary"] as? [String])?.filter { !$0.isEmpty } ?? []) where !filesSummary.contains(f) {
            filesSummary.append(f)
        }
        let qaRun = (qaJSON?["how_to_run"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var howToRun = qaRun.isEmpty ? initialHowToRun : qaRun

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

        // If user sent live steering during QA Gate, let Chair dispatch any steered workstreams immediately
        if let steeringInbox, steeringInbox.hasPending {
            let (steeredSession, didSteer, postQAWaves) = try await applyBuildSteeringIfNeeded(
                steeringInbox: steeringInbox,
                into: session,
                moderator: moderator,
                debaters: debaters,
                remainingAssignments: [],
                roundNumber: 99,
                targetFolder: targetFolder,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                onEvent: onEvent
            )
            session = steeredSession
            if didSteer && !postQAWaves.isEmpty {
                session = try await runExecutionWaves(
                    waves: postQAWaves,
                    into: session,
                    moderator: moderator,
                    allCouncil: allCouncil,
                    debaters: debaters,
                    excludingBuilder: nil,
                    reviewerNameForRemediation: nil,
                    remediationPassIndex: nil,
                    targetFolder: targetFolder,
                    folderName: folderName,
                    modelLabels: modelLabels,
                    openRouterKey: openRouterKey,
                    steeringInbox: steeringInbox,
                    filesSummary: &filesSummary,
                    howToRun: &howToRun,
                    onEvent: onEvent
                )
            }
        }

        // --- AUTOMATED FIX PASS IF QA CAUGHT ISSUES ---
        if !verificationPassed && !issuesFound.isEmpty {
            try Task.checkCancellation()
            _ = await drainSteeringMessages(steeringInbox, into: &session, onEvent: onEvent)
            let fixer = selectPrimaryBuilder(
                from: debaters,
                excluding: verifier,
                fallback: moderator,
                forTask: issuesFound.joined(separator: " ")
            )
            session.stage = .executingPlan
            await onEvent(.activeThinkersChanged(
                [fixer.id],
                statusLabel: "\(fixer.name) is fixing \(issuesFound.count) QA issue(s) caught by \(verifier.name)…"
            ))
            await onEvent(.sessionUpdated(session))

            let fixResp = try await callModel(ModelCallRequest(
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
            ), in: session)

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

            if let steeringInbox, steeringInbox.hasPending {
                let (steeredSession, didSteer, postFixWaves) = try await applyBuildSteeringIfNeeded(
                    steeringInbox: steeringInbox,
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
                    remainingAssignments: [],
                    roundNumber: 99,
                    targetFolder: targetFolder,
                    modelLabels: modelLabels,
                    openRouterKey: openRouterKey,
                    onEvent: onEvent
                )
                session = steeredSession
                if didSteer && !postFixWaves.isEmpty {
                    session = try await runExecutionWaves(
                        waves: postFixWaves,
                        into: session,
                        moderator: moderator,
                        allCouncil: allCouncil,
                        debaters: debaters,
                        excludingBuilder: nil,
                        reviewerNameForRemediation: nil,
                        remediationPassIndex: nil,
                        targetFolder: targetFolder,
                        folderName: folderName,
                        modelLabels: modelLabels,
                        openRouterKey: openRouterKey,
                        steeringInbox: steeringInbox,
                        filesSummary: &filesSummary,
                        howToRun: &howToRun,
                        onEvent: onEvent
                    )
                }
            }
        }

        // --- INDEPENDENT COMPLETENESS REVIEWER & REMEDIATION LOOP (Until 100% Complete or Valid Blocker) ---
        var finalCompletenessReviewerName: String?
        var finalCompletenessPercent: Int?
        var finalCompletenessPasses: Int?
        var finalAcceptedBlockers: [String]?

        if session.isCompletenessReviewOn {
            let reviewer = resolveCompletenessReviewer(
                for: session,
                moderator: moderator,
                debaters: debaters,
                allPersonas: allPersonas
            )
            finalCompletenessReviewerName = "\(reviewer.name) (\(reviewer.provider.shortName))"
            let maxCompletenessPasses = 6

            for passIndex in 1...maxCompletenessPasses {
                try Task.checkCancellation()
                finalCompletenessPasses = passIndex
                session.stage = .verifyingBuild
                session.entries.append(.roundBanner(RoundBanner(
                    roundNumber: 100 + passIndex,
                    title: "Completeness Audit · Pass \(passIndex) (\(reviewer.name) · \(reviewer.provider.shortName))",
                    subtitle: "Auditing 100% spec & blueprint delivery on disk in \(folderName)"
                )))
                await onEvent(.activeThinkersChanged(
                    [reviewer.id],
                    statusLabel: "Completeness Audit (Pass \(passIndex)): \(reviewer.name) (\(reviewer.provider.shortName)) is verifying 100% delivery…"
                ))
                await onEvent(.sessionUpdated(session))

                let auditResp = try await callModel(ModelCallRequest(
                    provider: reviewer.provider,
                    modelID: reviewer.modelID,
                    effort: reviewer.effort,
                    systemPrompt: DebatePrompts.completenessAuditSystemPrompt(
                        reviewer: reviewer,
                        moderatorName: moderator.name,
                        teamNames: debaters.map(\.name),
                        iteration: passIndex,
                        workspacePath: targetFolder
                    ),
                    userPrompt: buildTranscriptContext(for: session),
                    allowWebSearch: session.allowWebSearch,
                    toolPhase: .researchAndInspect,
                    workspacePath: targetFolder,
                    openRouterAPIKey: openRouterKey
                ), in: session)

                let auditJSON = JSONExtractor.parseObject(auditResp.rawText)
                let missingItems = (auditJSON?["missing_items"] as? [String])?
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty } ?? []
                let acceptedBlockers = (auditJSON?["accepted_blockers"] as? [String])?
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty } ?? []
                let explicitComplete = (auditJSON?["is_complete"] as? Bool)
                let isComplete = explicitComplete ?? false
                let pct = (auditJSON?["completeness_percent"] as? Int) ?? (isComplete ? 100 : 75)

                if let auditedFiles = (auditJSON?["files_summary"] as? [String])?.filter({ !$0.isEmpty }) {
                    for f in auditedFiles where !filesSummary.contains(f) {
                        filesSummary.append(f)
                    }
                }
                if let auditedRun = (auditJSON?["how_to_run"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !auditedRun.isEmpty {
                    howToRun = auditedRun
                }

                let auditLabel = (isComplete && missingItems.isEmpty)
                    ? "Completeness · 100% Signed Off"
                    : "Completeness · \(pct)% (\(missingItems.count) Gap\(missingItems.count == 1 ? "" : "s"))"

                let auditTurn = parseDebateTurn(
                    raw: auditResp.rawText,
                    durationMs: auditResp.durationMs,
                    roundNumber: 100 + passIndex,
                    roundLabel: auditLabel,
                    persona: reviewer,
                    modelLabel: modelLabels[reviewer.modelID] ?? reviewer.modelID,
                    defaultStance: .verifying
                )
                session.entries.append(.turn(auditTurn))
                session.updatedAt = Date()
                await onEvent(.sessionUpdated(session))
                await onEvent(.enqueueSpeech(SpeechQueueItem(
                    id: auditTurn.id,
                    persona: reviewer,
                    spokenText: auditTurn.spokenTake,
                    contextLabel: "Completeness · \(reviewer.name)"
                )))

                finalCompletenessPercent = (isComplete && missingItems.isEmpty) ? max(pct, 100) : pct
                if !acceptedBlockers.isEmpty {
                    finalAcceptedBlockers = acceptedBlockers
                }

                // If user sent live steering while Completeness Audit was running, address it before signing off!
                if let steeringInbox, steeringInbox.hasPending {
                    if isComplete && missingItems.isEmpty {
                        let (steeredSession, didSteer, postAuditWaves) = try await applyBuildSteeringIfNeeded(
                            steeringInbox: steeringInbox,
                            into: session,
                            moderator: moderator,
                            debaters: debaters,
                            remainingAssignments: [],
                            roundNumber: 100 + passIndex,
                            targetFolder: targetFolder,
                            modelLabels: modelLabels,
                            openRouterKey: openRouterKey,
                            onEvent: onEvent
                        )
                        session = steeredSession
                        if didSteer && !postAuditWaves.isEmpty {
                            session = try await runExecutionWaves(
                                waves: postAuditWaves,
                                into: session,
                                moderator: moderator,
                                allCouncil: allCouncil,
                                debaters: debaters,
                                excludingBuilder: reviewer,
                                reviewerNameForRemediation: nil,
                                remediationPassIndex: passIndex,
                                targetFolder: targetFolder,
                                folderName: folderName,
                                modelLabels: modelLabels,
                                openRouterKey: openRouterKey,
                                steeringInbox: steeringInbox,
                                filesSummary: &filesSummary,
                                howToRun: &howToRun,
                                onEvent: onEvent
                            )
                            if passIndex < maxCompletenessPasses {
                                continue
                            }
                        }
                    } else {
                        _ = await drainSteeringMessages(steeringInbox, into: &session, onEvent: onEvent)
                    }
                }

                // Exit cleanly if 100% complete (or all remaining gaps are accepted legitimate blockers)!
                if isComplete && missingItems.isEmpty {
                    verificationPassed = true
                    verificationSummary = auditTurn.spokenTake
                    break
                }

                if passIndex == maxCompletenessPasses {
                    verificationPassed = false
                    verificationSummary = auditTurn.spokenTake
                    break
                }

                // --- FIRE MISSED ITEMS BACK TO CHAIR & TEAM FOR REMEDIATION ---
                try Task.checkCancellation()
                session.stage = .synthesizingVerdict
                session.entries.append(.roundBanner(RoundBanner(
                    roundNumber: 110 + passIndex,
                    title: "Remediation Pass \(passIndex) · Closing \(missingItems.count) Completeness Gap\(missingItems.count == 1 ? "" : "s")",
                    subtitle: "\(moderator.name) & the team are resolving everything \(reviewer.name) flagged"
                )))
                await onEvent(.activeThinkersChanged(
                    [moderator.id],
                    statusLabel: "Remediation \(passIndex): \(moderator.name) is assigning \(missingItems.count) missed item(s) back to the team…"
                ))
                await onEvent(.sessionUpdated(session))

                let remPlanResp = try await callModel(ModelCallRequest(
                    provider: moderator.provider,
                    modelID: moderator.modelID,
                    effort: moderator.effort,
                    systemPrompt: DebatePrompts.completenessRemediationPlanPrompt(
                        moderator: moderator,
                        debaters: debaters,
                        reviewerName: reviewer.name,
                        missingItems: missingItems,
                        iteration: passIndex,
                        workspacePath: targetFolder
                    ),
                    userPrompt: buildTranscriptContext(for: session),
                    allowWebSearch: session.allowWebSearch,
                    toolPhase: .researchAndInspect,
                    workspacePath: targetFolder,
                    openRouterAPIKey: openRouterKey
                ), in: session)

                let remPlanTurn = parseDebateTurn(
                    raw: remPlanResp.rawText,
                    durationMs: remPlanResp.durationMs,
                    roundNumber: 110 + passIndex,
                    roundLabel: "Remediation Dispatch \(passIndex)",
                    persona: moderator,
                    modelLabel: modelLabels[moderator.modelID] ?? moderator.modelID,
                    defaultStance: .moderating
                )
                session.entries.append(.turn(remPlanTurn))
                session.updatedAt = Date()
                await onEvent(.sessionUpdated(session))
                await onEvent(.enqueueSpeech(SpeechQueueItem(
                    id: remPlanTurn.id,
                    persona: moderator,
                    spokenText: remPlanTurn.spokenTake,
                    contextLabel: "Dispatch · \(moderator.name)"
                )))

                var remAssignments: [ExecutionAssignment] = []
                if let remPlanJSON = JSONExtractor.parseObject(remPlanResp.rawText),
                   let rawAssign = remPlanJSON["execution_assignments"] as? [[String: Any]] {
                    for item in rawAssign.prefix(8) {
                        guard let who = (item["assigned_to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              let instr = (item["task_instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !who.isEmpty, !instr.isEmpty else { continue }
                        let scope = (item["target_scope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let wave = Self.parseWave(item["wave"])
                        remAssignments.append(ExecutionAssignment(
                            assignedPersonaName: who,
                            taskInstruction: instr,
                            targetScope: scope,
                            wave: wave
                        ))
                    }
                }
                if remAssignments.isEmpty {
                    let joinedMissing = missingItems.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                    let defaultBuilder = selectPrimaryBuilder(from: debaters, excluding: reviewer, fallback: moderator, forTask: joinedMissing)
                    remAssignments = [
                        ExecutionAssignment(
                            assignedPersonaName: defaultBuilder.name,
                            taskInstruction: "Resolve all completeness gaps flagged by \(reviewer.name):\n\(joinedMissing)",
                            targetScope: targetFolder,
                            wave: 1
                        )
                    ]
                }

                let remWaves = Self.partitionIntoParallelWaves(remAssignments, workspaceRoot: targetFolder)
                session.stage = .executingPlan
                await onEvent(.sessionUpdated(session))

                session = try await runExecutionWaves(
                    waves: remWaves,
                    into: session,
                    moderator: moderator,
                    allCouncil: allCouncil,
                    debaters: debaters,
                    excludingBuilder: reviewer,
                    reviewerNameForRemediation: reviewer.name,
                    remediationPassIndex: passIndex,
                    targetFolder: targetFolder,
                    folderName: folderName,
                    modelLabels: modelLabels,
                    openRouterKey: openRouterKey,
                    steeringInbox: steeringInbox,
                    filesSummary: &filesSummary,
                    howToRun: &howToRun,
                    onEvent: onEvent
                )
            }
        }

        verdict.wasExecuted = true
        verdict.buildReport = BuildReport(
            buildFolder: targetFolder,
            verificationPassed: verificationPassed,
            verifierName: verifier.name,
            verificationSummary: ExpressiveCleaner.stripCues(verificationSummary),
            filesSummary: filesSummary,
            howToRun: howToRun,
            completenessReviewerName: finalCompletenessReviewerName,
            completenessPercent: finalCompletenessPercent,
            completenessIterations: finalCompletenessPasses,
            acceptedBlockers: finalAcceptedBlockers
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

    // MARK: - Collaborative Build Mode Pipeline (Huddle -> Blueprint -> Build -> QA Gate -> Completeness Loop)

    private func runBuildSessionToCompletion(
        session initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        allPersonas: [Persona],
        modelLabels: [String: String],
        openRouterKey: String?,
        isIncrementalFollowUp: Bool,
        steeringInbox: SteeringInbox?,
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

        // Drain any steering queued right before Huddle starts
        _ = await drainSteeringMessages(steeringInbox, into: &session, onEvent: onEvent)

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

        // Drain any live steering sent during Phase 1 Huddle so the Chair incorporates it directly into the Blueprint!
        let huddleSteered = await drainSteeringMessages(steeringInbox, into: &session, onEvent: onEvent)
        let blueprintExtraInstruction = huddleSteered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        // Phase 2: Chair Synthesizes Concrete Multi-Agent Build Blueprint
        try Task.checkCancellation()
        session.stage = .synthesizingVerdict
        await onEvent(.activeThinkersChanged(
            [moderator.id],
            statusLabel: huddleSteered.isEmpty
                ? "\(moderator.name) is locking in the Build Blueprint & assigning workstreams…"
                : "\(moderator.name) is applying your live steering & locking in the Build Blueprint…"
        ))
        await onEvent(.sessionUpdated(session))

        let blueprintResp = try await callModel(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: moderator.effort,
            systemPrompt: DebatePrompts.buildBlueprintSystemPrompt(
                moderator: moderator,
                debaters: debaters,
                workspacePath: targetFolder,
                extraInstruction: blueprintExtraInstruction
            ),
            userPrompt: buildTranscriptContext(for: session),
            allowWebSearch: session.allowWebSearch,
            toolPhase: .researchAndInspect,
            workspacePath: targetFolder,
            openRouterAPIKey: openRouterKey
        ), in: session)

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

        // Phase 3 + 4 + 5: Execute Workstreams -> Adversarial QA Verification -> Completeness Audit Loop
        return try await executeVerdictPlan(
            verdictID: blueprint.id,
            into: session,
            moderator: moderator,
            debaters: debaters,
            allPersonas: allPersonas,
            modelLabels: modelLabels,
            openRouterKey: openRouterKey,
            steeringInbox: steeringInbox,
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
        let attachedImages = Self.activeImagePaths(in: session)
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
                            imagePaths: attachedImages,
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
        if let verifier = debaters.first(where: {
            $0.name.localizedCaseInsensitiveContains("Rook")
            || $0.name.localizedCaseInsensitiveContains("Sable")
            || $0.title.localizedCaseInsensitiveContains("QA")
            || $0.title.localizedCaseInsensitiveContains("Verification")
            || $0.title.localizedCaseInsensitiveContains("Skeptic")
            || $0.title.localizedCaseInsensitiveContains("Critic")
            || $0.title.localizedCaseInsensitiveContains("Security")
        }) {
            return verifier
        }
        return debaters.last ?? fallback
    }

    public func selectPrimaryBuilder(
        from debaters: [Persona],
        excluding: Persona?,
        fallback: Persona,
        forTask taskText: String = ""
    ) -> Persona {
        let candidates = debaters.filter { $0.id != excluding?.id }
        // 1. Honor explicit user/roster task specialties & routing signals first!
        if !taskText.isEmpty {
            let scored = candidates.map { ($0, $0.domainAffinityScore(for: taskText)) }
            if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 {
                return best.0
            }
        }
        // 2. Otherwise default to the primary systems/pragmatist builder
        if let builder = candidates.first(where: {
            $0.name.localizedCaseInsensitiveContains("Forge")
            || $0.name.localizedCaseInsensitiveContains("Marcus")
            || $0.title.localizedCaseInsensitiveContains("Systems")
            || $0.title.localizedCaseInsensitiveContains("Pragmatist")
            || $0.title.localizedCaseInsensitiveContains("Builder")
            || $0.title.localizedCaseInsensitiveContains("Engineer")
            || $0.title.localizedCaseInsensitiveContains("Architect")
        }) {
            return builder
        }
        return candidates.first ?? fallback
    }

    private func resolveCompletenessReviewer(
        for session: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        allPersonas: [Persona]
    ) -> Persona {
        let targetID = session.effectiveCompletenessReviewerID
        let pool = allPersonas + [moderator] + debaters + DefaultRoster.personas
        if let hit = pool.first(where: { $0.id == targetID }) {
            return hit
        }
        return DefaultRoster.personas.first(where: { $0.id == DefaultRoster.wardenID })
            ?? selectVerifier(from: debaters, fallback: moderator)
    }

    // MARK: - Parallel Wave Partitioning & Concurrent Workstream Execution

    public struct ExecutionWave: Sendable {
        public let waveNumber: Int
        public let items: [ExecutionAssignment]
    }

    /// Groups `ExecutionAssignment`s into safe parallel execution waves.
    /// Tasks in the same wave with non-overlapping `targetScope` paths execute concurrently via `ThrowingTaskGroup`,
    /// while any accidental file/directory scope collision automatically shifts into the next sub-wave so two writers never clobber the same file.
    public static func partitionIntoParallelWaves(
        _ assignments: [ExecutionAssignment],
        workspaceRoot: String? = nil
    ) -> [ExecutionWave] {
        guard !assignments.isEmpty else { return [] }

        let hasExplicitWaves = assignments.contains { $0.wave != nil }
        let groupedInput: [[ExecutionAssignment]]
        if hasExplicitWaves {
            let distinctWaves = Array(Set(assignments.map(\.effectiveWave))).sorted()
            groupedInput = distinctWaves.map { w in
                assignments.filter { $0.effectiveWave == w }
            }
        } else {
            groupedInput = [assignments]
        }

        var result: [ExecutionWave] = []
        var nextWaveIndex = 1
        for group in groupedInput {
            var buckets: [[ExecutionAssignment]] = []
            for candidate in group {
                if let bucketIdx = buckets.firstIndex(where: { existingBucket in
                    !existingBucket.contains { existing in
                        scopesPotentiallyCollide(existing.targetScope, candidate.targetScope, workspaceRoot: workspaceRoot)
                    }
                }) {
                    buckets[bucketIdx].append(candidate)
                } else {
                    buckets.append([candidate])
                }
            }
            for bucket in buckets {
                result.append(ExecutionWave(waveNumber: nextWaveIndex, items: bucket))
                nextWaveIndex += 1
            }
        }
        return result
    }

    public static func scopesPotentiallyCollide(_ a: String, _ b: String, workspaceRoot: String? = nil) -> Bool {
        let tokensA = normalizedScopeTokens(a, workspaceRoot: workspaceRoot)
        let tokensB = normalizedScopeTokens(b, workspaceRoot: workspaceRoot)
        // Empty or wildcard scope touches potentially anything in the workspace, so run it safely in its own wave
        guard !tokensA.isEmpty, !tokensB.isEmpty else { return true }
        for ta in tokensA {
            if ta == "*" { return true }
            for tb in tokensB {
                if tb == "*" { return true }
                if ta == tb { return true }
                if ta.hasPrefix(tb + "/") || tb.hasPrefix(ta + "/") { return true }
            }
        }
        return false
    }

    private static func normalizedScopeTokens(_ raw: String, workspaceRoot: String?) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let lowerRoot = (workspaceRoot ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let parts = trimmed
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var tokens: [String] = []
        for part in parts {
            var norm = part.lowercased()
            while norm.hasPrefix("./") {
                norm = String(norm.dropFirst(2))
            }
            norm = norm.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if norm.isEmpty || norm == "." || norm == "*" || norm == "workspace" || norm.contains("as needed") || norm == lowerRoot {
                return ["*"]
            }
            if !lowerRoot.isEmpty, norm.hasPrefix(lowerRoot + "/") {
                norm = String(norm.dropFirst(lowerRoot.count + 1))
            }
            if norm.contains("*") {
                let prefix = norm.components(separatedBy: "*").first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
                if prefix.isEmpty { return ["*"] }
                tokens.append(prefix)
            } else {
                tokens.append(norm)
            }
        }
        return tokens
    }

    private static func parseWave(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return max(1, i) }
        if let n = raw as? NSNumber { return max(1, n.intValue) }
        if let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), let i = Int(s) {
            return max(1, i)
        }
        return nil
    }

    private struct WaveTaskOutcome: Sendable {
        let orderIndex: Int
        let executor: Persona
        let result: Result<(turn: DebateTurn, files: [String], runCmd: String), Error>
    }

    private func runExecutionWaves(
        waves: [ExecutionWave],
        into initialSession: DebateSession,
        moderator: Persona,
        allCouncil: [Persona],
        debaters: [Persona],
        excludingBuilder: Persona?,
        reviewerNameForRemediation: String?,
        remediationPassIndex: Int?,
        targetFolder: String,
        folderName: String,
        modelLabels: [String: String],
        openRouterKey: String?,
        steeringInbox: SteeringInbox?,
        filesSummary: inout [String],
        howToRun: inout String,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        let webOn = session.allowWebSearch
        var pendingWaves = waves
        var completedWavesCount = 0

        while true {
            try Task.checkCancellation()

            // Check live steering before starting the next wave AND right after the final wave finishes!
            if let steeringInbox, steeringInbox.hasPending {
                let remainingItems = pendingWaves.flatMap(\.items)
                let steerRoundNum = remediationPassIndex.map { 110 + $0 } ?? 98
                let (steeredSession, didSteer, updatedWaves) = try await applyBuildSteeringIfNeeded(
                    steeringInbox: steeringInbox,
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
                    remainingAssignments: remainingItems,
                    roundNumber: steerRoundNum,
                    targetFolder: targetFolder,
                    modelLabels: modelLabels,
                    openRouterKey: openRouterKey,
                    onEvent: onEvent
                )
                session = steeredSession
                if didSteer {
                    pendingWaves = updatedWaves
                }
            }

            guard !pendingWaves.isEmpty else { break }

            let nextWave = pendingWaves.removeFirst()
            completedWavesCount += 1
            let currentWaveNumber = completedWavesCount
            let totalWaves = completedWavesCount + pendingWaves.count

            let resolved: [(index: Int, assignment: ExecutionAssignment, executor: Persona)] = nextWave.items.enumerated().map { idx, item in
                var resolvedItem = item
                resolvedItem.wave = currentWaveNumber
                let exec = allCouncil.first {
                    $0.name.localizedCaseInsensitiveContains(item.assignedPersonaName)
                    || item.assignedPersonaName.localizedCaseInsensitiveContains($0.name)
                } ?? selectPrimaryBuilder(
                    from: debaters,
                    excluding: excludingBuilder,
                    fallback: moderator,
                    forTask: "\(item.taskInstruction) \(item.targetScope)"
                )
                return (idx, resolvedItem, exec)
            }

            let isParallel = resolved.count > 1
            let activeNames = resolved.map(\.executor.name).joined(separator: ", ")
            let prefixLabel = remediationPassIndex.map { "Remediation \($0) · Wave \(currentWaveNumber)/\(totalWaves)" }
                ?? "Wave \(currentWaveNumber)/\(totalWaves)"
            let initialStatus = isParallel
                ? "\(prefixLabel) (Parallel): \(activeNames) building simultaneously in \(folderName)…"
                : "\(prefixLabel): \(resolved[0].executor.name) building in \(folderName)…"

            var remainingByIndex: [Int: Persona] = Dictionary(uniqueKeysWithValues: resolved.map { ($0.index, $0.executor) })
            await onEvent(.activeThinkersChanged(Set(remainingByIndex.values.map(\.id)), statusLabel: initialStatus))

            let waveContext = buildTranscriptContext(for: session)
            let waveImages = Self.activeImagePaths(in: session)
            let roundNum = remediationPassIndex.map { 110 + $0 } ?? 98

            var waveSuccessCount = 0
            var firstWaveError: Error?

            try await withThrowingTaskGroup(of: WaveTaskOutcome.self) { group in
                for entry in resolved {
                    let peers = resolved
                        .filter { $0.index != entry.index }
                        .map { "\($0.executor.name) (scope: \($0.assignment.targetScope.isEmpty ? "assigned slice" : $0.assignment.targetScope))" }
                    let modelLabel = modelLabels[entry.executor.modelID] ?? entry.executor.modelID
                    let roundTag: String = {
                        if let remPass = remediationPassIndex {
                            return isParallel
                                ? "Remediation \(remPass) · Wave \(currentWaveNumber) (Parallel)"
                                : "Remediation \(remPass) · Wave \(currentWaveNumber)"
                        }
                        return isParallel
                            ? "Wave \(currentWaveNumber)/\(totalWaves) · Parallel"
                            : "Wave \(currentWaveNumber)/\(totalWaves)"
                    }()

                    group.addTask { [runner] in
                        do {
                            let sysPrompt: String
                            if let revName = reviewerNameForRemediation {
                                sysPrompt = DebatePrompts.completenessRemediationExecutionPrompt(
                                    executor: entry.executor,
                                    moderatorName: moderator.name,
                                    reviewerName: revName,
                                    assignment: entry.assignment,
                                    concurrentPeers: peers,
                                    workspacePath: targetFolder
                                )
                            } else {
                                sysPrompt = DebatePrompts.coordinatedExecutionSystemPrompt(
                                    executor: entry.executor,
                                    moderatorName: moderator.name,
                                    assignment: entry.assignment,
                                    concurrentPeers: peers,
                                    workspacePath: targetFolder
                                )
                            }

                            let resp = try await runner.call(ModelCallRequest(
                                provider: entry.executor.provider,
                                modelID: entry.executor.modelID,
                                effort: entry.executor.effort,
                                systemPrompt: sysPrompt,
                                userPrompt: waveContext,
                                imagePaths: waveImages,
                                allowWebSearch: webOn,
                                toolPhase: .coordinatedReadWrite,
                                workspacePath: targetFolder,
                                openRouterAPIKey: openRouterKey
                            ))

                            var turn = self.parseDebateTurn(
                                raw: resp.rawText,
                                durationMs: resp.durationMs,
                                roundNumber: roundNum,
                                roundLabel: roundTag,
                                persona: entry.executor,
                                modelLabel: modelLabel,
                                defaultStance: .executing
                            )

                            var extractedFiles: [String] = []
                            var extractedRun = ""
                            if let parsed = JSONExtractor.parseObject(resp.rawText) {
                                extractedFiles = (parsed["files_summary"] as? [String])?.filter { !$0.isEmpty } ?? []
                                extractedRun = (parsed["how_to_run"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                if let blockers = (parsed["unresolvable_reasons"] as? [String])?
                                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                                    .filter({ !$0.isEmpty }) {
                                    for b in blockers {
                                        turn.keyPoints.append("TEAM BLOCKER REASON: \(b)")
                                    }
                                }
                            }
                            return WaveTaskOutcome(
                                orderIndex: entry.index,
                                executor: entry.executor,
                                result: .success((turn, extractedFiles, extractedRun))
                            )
                        } catch {
                            return WaveTaskOutcome(
                                orderIndex: entry.index,
                                executor: entry.executor,
                                result: .failure(error)
                            )
                        }
                    }
                }

                // Stream each builder's turn & voice cue live onto the timeline the moment that builder finishes!
                for try await outcome in group {
                    remainingByIndex.removeValue(forKey: outcome.orderIndex)
                    switch outcome.result {
                    case .success(let payload):
                        waveSuccessCount += 1
                        for f in payload.files where !filesSummary.contains(f) {
                            filesSummary.append(f)
                        }
                        if !payload.runCmd.isEmpty {
                            howToRun = payload.runCmd
                        }
                        session.entries.append(.turn(payload.turn))
                        session.updatedAt = Date()
                        await onEvent(.sessionUpdated(session))
                        await onEvent(.enqueueSpeech(SpeechQueueItem(
                            id: payload.turn.id,
                            persona: outcome.executor,
                            spokenText: payload.turn.spokenTake,
                            contextLabel: (remediationPassIndex != nil ? "Remediated" : "Built") + " · \(outcome.executor.name)"
                        )))
                    case .failure(let err):
                        if Task.isCancelled { throw ModelRunnerError.cancelled }
                        if case ModelRunnerError.cancelled = err { throw err }
                        firstWaveError = firstWaveError ?? err
                        session.entries.append(.systemNote(
                            UUID(),
                            "\(outcome.executor.name) encountered an error in Wave \(currentWaveNumber): \(err.localizedDescription)"
                        ))
                        session.updatedAt = Date()
                        await onEvent(.sessionUpdated(session))
                    }

                    if !remainingByIndex.isEmpty {
                        let stillWorking = remainingByIndex.values.map(\.name).joined(separator: ", ")
                        await onEvent(.activeThinkersChanged(
                            Set(remainingByIndex.values.map(\.id)),
                            statusLabel: "\(prefixLabel): Waiting on \(stillWorking) in \(folderName)…"
                        ))
                    }
                }
            }

            if waveSuccessCount == 0, let firstWaveError {
                throw firstWaveError
            }
        }

        return session
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
        let resp = try await callModel(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: .medium,
            systemPrompt: DebatePrompts.handoffSynthesisSystemPrompt(moderator: moderator, customInstruction: customInstruction),
            userPrompt: fullInput,
            allowWebSearch: false,
            toolPhase: .closedBook,
            workspacePath: session.workspacePath,
            openRouterAPIKey: openRouterKey
        ), in: session)
        return resp.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Core Multi-Round Debate Engine (With Live Inter-Persona Dialogue)

    private func runDebateToVerdict(
        session initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        allPersonas: [Persona],
        modelLabels: [String: String],
        openRouterKey: String?,
        isFollowUpRound: Bool,
        steeringInbox: SteeringInbox?,
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

        // Check for any live steering queued right before Round 1 starts
        if let steeringInbox, steeringInbox.hasPending {
            let (steered, _, _) = try await applyDebateSteeringIfNeeded(
                steeringInbox: steeringInbox,
                into: session,
                moderator: moderator,
                debaters: debaters,
                roundNumber: 1,
                isNearEndOfDebate: false,
                allowImmediatePeerReply: false,
                nextScheduledDebaterID: nil,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                onEvent: onEvent
            )
            session = steered
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

        // --- CHAIR FLOOR DIRECTION (or immediate Live Steering if user steered during Round 1!) ---
        if let steeringInbox, steeringInbox.hasPending {
            let (steered, _, _) = try await applyDebateSteeringIfNeeded(
                steeringInbox: steeringInbox,
                into: session,
                moderator: moderator,
                debaters: debaters,
                roundNumber: 1,
                isNearEndOfDebate: false,
                allowImmediatePeerReply: true,
                nextScheduledDebaterID: rotate(debaters, by: 1).first?.id,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                onEvent: onEvent
            )
            session = steered
        } else if !isFollowUpRound && debaters.count >= 2 {
            try Task.checkCancellation()
            await onEvent(.activeThinkersChanged([moderator.id], statusLabel: "\(moderator.name) is framing the clash on the floor…"))
            let r1Board = buildTranscriptContext(for: session)
            if let chairResp = try? await callModel(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: .medium,
                systemPrompt: DebatePrompts.chairFloorDirectionPrompt(moderator: moderator, debaters: debaters),
                userPrompt: r1Board,
                allowWebSearch: false,
                toolPhase: .closedBook,
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            ), in: session) {
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

        // --- ROUNDS 2..N: Live Inter-Persona Conversation & Direct Exchanges (Fixed Count OR Until Consensus) ---
        let untilConsensus = !isFollowUpRound && session.runsUntilConsensus
        let initialRebuttalCount: Int = {
            if isFollowUpRound { return 1 }
            if untilConsensus { return RebuttalPolicy.safetyMaxRounds }
            return max(1, session.maxRebuttalRounds)
        }()
        let hardMaxRounds = RebuttalPolicy.safetyMaxRounds + 4
        var targetRebuttalCount = initialRebuttalCount
        var rebuttalIdx = 1

        while rebuttalIdx <= targetRebuttalCount {
            try Task.checkCancellation()
            let roundNum = rebuttalIdx + 1
            var isFinal = (rebuttalIdx == targetRebuttalCount)
            let bannerTitle: String = {
                if untilConsensus {
                    if isFinal {
                        return "Round \(roundNum) · Final Consensus & Co-Sign Call"
                    }
                    return rebuttalIdx == 1
                        ? "Round \(roundNum) · Cross-Examination (Running Until Consensus)"
                        : "Round \(roundNum) · Convergence & Sticking-Point Resolution"
                }
                return (isFinal && targetRebuttalCount > 1)
                    ? "Round \(roundNum) · Final Cross-Examination & Co-Sign Check"
                    : "Round \(roundNum) · Live Council Cross-Examination"
            }()
            let bannerSub: String = {
                if untilConsensus && !isFinal {
                    return "Debating until panelists align or \(moderator.name) calls consensus"
                }
                return isFinal
                    ? "Panelists settle final stances, concessions, or holdout dissents"
                    : "Panelists challenge each other directly and answer face-to-face"
            }()

            session.entries.append(.roundBanner(RoundBanner(roundNumber: roundNum, title: bannerTitle, subtitle: bannerSub)))
            await onEvent(.sessionUpdated(session))

            var roundTurns: [DebateTurn] = []
            var directRepliesTriggered = 0
            var roundHadSteering = false
            let orderedDebaters = rotate(debaters, by: rebuttalIdx)

            for (debaterIdx, debater) in orderedDebaters.enumerated() {
                try Task.checkCancellation()
                let nextDebaterID = (debaterIdx + 1 < orderedDebaters.count) ? orderedDebaters[debaterIdx + 1].id : nil

                // Check for live steering right before this debater takes the floor
                if let steeringInbox, steeringInbox.hasPending {
                    let (steered, didSteer, wantsExtra) = try await applyDebateSteeringIfNeeded(
                        steeringInbox: steeringInbox,
                        into: session,
                        moderator: moderator,
                        debaters: debaters,
                        roundNumber: roundNum,
                        isNearEndOfDebate: isFinal && (debaterIdx == orderedDebaters.count - 1),
                        allowImmediatePeerReply: true,
                        nextScheduledDebaterID: debater.id,
                        modelLabels: modelLabels,
                        openRouterKey: openRouterKey,
                        onEvent: onEvent
                    )
                    session = steered
                    if didSteer {
                        roundHadSteering = true
                        if wantsExtra && isFinal && targetRebuttalCount < hardMaxRounds {
                            targetRebuttalCount += 1
                            isFinal = false
                        }
                    }
                }

                let modeHint = untilConsensus ? " (Until Consensus)" : ""
                await onEvent(.activeThinkersChanged([debater.id], statusLabel: "Round \(roundNum)\(modeHint): \(debater.name) has the floor…"))

                let liveBoard = buildTranscriptContext(for: session)
                let resp: ModelCallResponse
                do {
                    resp = try await callModel(ModelCallRequest(
                        provider: debater.provider,
                        modelID: debater.modelID,
                        effort: debater.effort,
                        systemPrompt: DebatePrompts.rebuttalSystemPrompt(
                            debater: debater,
                            allDebaters: debaters,
                            moderatorName: moderator.name,
                            roundNumber: roundNum,
                            isFinalRebuttal: isFinal,
                            untilConsensusMode: untilConsensus,
                            workspacePath: session.workspacePath,
                            toolsEnabled: session.hasFullCLITools
                        ),
                        userPrompt: liveBoard,
                        allowWebSearch: session.allowWebSearch,
                        toolPhase: researchPhase(for: session),
                        workspacePath: session.workspacePath,
                        openRouterAPIKey: openRouterKey
                    ), in: session)
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

                // AS SOON AS THIS TURN FINISHES: check if the user sent live steering!
                // If steering arrived, pass it immediately to the Chair before any pre-steering peer exchange runs.
                var steeredRightAfterTurn = false
                if let steeringInbox, steeringInbox.hasPending {
                    let (steered, didSteer, wantsExtra) = try await applyDebateSteeringIfNeeded(
                        steeringInbox: steeringInbox,
                        into: session,
                        moderator: moderator,
                        debaters: debaters,
                        roundNumber: roundNum,
                        isNearEndOfDebate: isFinal && (debaterIdx == orderedDebaters.count - 1),
                        allowImmediatePeerReply: true,
                        nextScheduledDebaterID: nextDebaterID,
                        modelLabels: modelLabels,
                        openRouterKey: openRouterKey,
                        onEvent: onEvent
                    )
                    session = steered
                    if didSteer {
                        steeredRightAfterTurn = true
                        roundHadSteering = true
                        if wantsExtra && isFinal && targetRebuttalCount < hardMaxRounds {
                            targetRebuttalCount += 1
                            isFinal = false
                        }
                    }
                }

                // LIVE INTER-PERSONA BACK-AND-FORTH: If this debater put a direct question to a specific peer
                // (and the user did not just redirect the floor with live steering), hand the floor immediately to that peer!
                if !steeredRightAfterTurn,
                   !isFinal,
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
                    let replyResp = try await callModel(ModelCallRequest(
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
                    ), in: session)

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

                    // Check again immediately after Direct Exchange finishes
                    if let steeringInbox, steeringInbox.hasPending {
                        let (steered, didSteer, wantsExtra) = try await applyDebateSteeringIfNeeded(
                            steeringInbox: steeringInbox,
                            into: session,
                            moderator: moderator,
                            debaters: debaters,
                            roundNumber: roundNum,
                            isNearEndOfDebate: isFinal && (debaterIdx == orderedDebaters.count - 1),
                            allowImmediatePeerReply: true,
                            nextScheduledDebaterID: nextDebaterID,
                            modelLabels: modelLabels,
                            openRouterKey: openRouterKey,
                            onEvent: onEvent
                        )
                        session = steered
                        if didSteer {
                            roundHadSteering = true
                            if wantsExtra && isFinal && targetRebuttalCount < hardMaxRounds {
                                targetRebuttalCount += 1
                                isFinal = false
                            }
                        }
                    }
                }
            }

            let allConverged = !roundHadSteering && !roundTurns.isEmpty && roundTurns.allSatisfy {
                $0.stance == .cosigning || $0.stance == .conceding
            }
            if allConverged && !isFinal {
                break
            }

            // In "Until Consensus" mode (from Round 3 onward), let the Chair actively mediate and check whether consensus is reached!
            if untilConsensus && !isFinal && rebuttalIdx >= 2 && debaters.count >= 2 {
                try Task.checkCancellation()
                if let steeringInbox, steeringInbox.hasPending {
                    let (steered, _, _) = try await applyDebateSteeringIfNeeded(
                        steeringInbox: steeringInbox,
                        into: session,
                        moderator: moderator,
                        debaters: debaters,
                        roundNumber: roundNum,
                        isNearEndOfDebate: false,
                        allowImmediatePeerReply: true,
                        nextScheduledDebaterID: nil,
                        modelLabels: modelLabels,
                        openRouterKey: openRouterKey,
                        onEvent: onEvent
                    )
                    session = steered
                } else {
                    await onEvent(.activeThinkersChanged(
                        [moderator.id],
                        statusLabel: "\(moderator.name) is checking consensus & mediating Round \(roundNum)…"
                    ))
                    let board = buildTranscriptContext(for: session)
                    if let medResp = try? await callModel(ModelCallRequest(
                        provider: moderator.provider,
                        modelID: moderator.modelID,
                        effort: .medium,
                        systemPrompt: DebatePrompts.chairConsensusMediationPrompt(
                            moderator: moderator,
                            debaters: debaters,
                            roundNumber: roundNum
                        ),
                        userPrompt: board,
                        allowWebSearch: false,
                        toolPhase: .closedBook,
                        workspacePath: session.workspacePath,
                        openRouterAPIKey: openRouterKey
                    ), in: session) {
                        let medJSON = JSONExtractor.parseObject(medResp.rawText)
                        let consensusReached = (medJSON?["consensus_reached"] as? Bool) ?? false
                        let medTurn = parseDebateTurn(
                            raw: medResp.rawText,
                            durationMs: medResp.durationMs,
                            roundNumber: roundNum,
                            roundLabel: consensusReached ? "Chair · Consensus Reached" : "Chair · Mediating",
                            persona: moderator,
                            modelLabel: modelLabels[moderator.modelID] ?? moderator.modelID,
                            defaultStance: .moderating
                        )
                        session.entries.append(.turn(medTurn))
                        session.updatedAt = Date()
                        await onEvent(.sessionUpdated(session))
                        await onEvent(.enqueueSpeech(SpeechQueueItem(
                            id: medTurn.id,
                            persona: moderator,
                            spokenText: medTurn.spokenTake,
                            contextLabel: consensusReached ? "\(moderator.name) · Consensus" : "\(moderator.name) · Mediating"
                        )))
                        if consensusReached && (steeringInbox?.hasPending != true) {
                            break
                        }
                    }
                }
            }

            rebuttalIdx += 1
        }

        // Check for any steering right before Verdict synthesis
        if let steeringInbox, steeringInbox.hasPending {
            let (steered, _, wantsExtra) = try await applyDebateSteeringIfNeeded(
                steeringInbox: steeringInbox,
                into: session,
                moderator: moderator,
                debaters: debaters,
                roundNumber: targetRebuttalCount + 1,
                isNearEndOfDebate: true,
                allowImmediatePeerReply: true,
                nextScheduledDebaterID: nil,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                onEvent: onEvent
            )
            session = steered
            if wantsExtra {
                session = try await runSingleSteeredRebuttalPass(
                    into: session,
                    roundNumber: targetRebuttalCount + 2,
                    moderator: moderator,
                    debaters: debaters,
                    modelLabels: modelLabels,
                    openRouterKey: openRouterKey,
                    steeringInbox: steeringInbox,
                    onEvent: onEvent
                )
            }
        }

        // --- STEP 3: Moderator Co-Signed Verdict ---
        try Task.checkCancellation()
        session.stage = .synthesizingVerdict
        await onEvent(.activeThinkersChanged([moderator.id], statusLabel: "\(moderator.name) is drafting the Co-Signed Verdict…"))
        await onEvent(.sessionUpdated(session))

        var verdictResp = try await callModel(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: moderator.effort,
            systemPrompt: DebatePrompts.verdictSystemPrompt(
                moderator: moderator,
                debaters: debaters,
                toolsEnabled: session.hasFullCLITools
            ),
            userPrompt: buildTranscriptContext(for: session),
            allowWebSearch: session.allowWebSearch,
            toolPhase: researchPhase(for: session),
            workspacePath: session.workspacePath,
            openRouterAPIKey: openRouterKey
        ), in: session)

        // If the user sent live steering while the Verdict was mid-generation, incorporate it before finalizing!
        if let steeringInbox, steeringInbox.hasPending {
            let (steered, _, wantsExtra) = try await applyDebateSteeringIfNeeded(
                steeringInbox: steeringInbox,
                into: session,
                moderator: moderator,
                debaters: debaters,
                roundNumber: targetRebuttalCount + 2,
                isNearEndOfDebate: true,
                allowImmediatePeerReply: true,
                nextScheduledDebaterID: nil,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                onEvent: onEvent
            )
            session = steered
            if wantsExtra {
                session = try await runSingleSteeredRebuttalPass(
                    into: session,
                    roundNumber: targetRebuttalCount + 3,
                    moderator: moderator,
                    debaters: debaters,
                    modelLabels: modelLabels,
                    openRouterKey: openRouterKey,
                    steeringInbox: steeringInbox,
                    onEvent: onEvent
                )
            }
            session.stage = .synthesizingVerdict
            await onEvent(.activeThinkersChanged([moderator.id], statusLabel: "\(moderator.name) is updating the Co-Signed Verdict with your steering…"))
            await onEvent(.sessionUpdated(session))
            verdictResp = try await callModel(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: moderator.effort,
                systemPrompt: DebatePrompts.verdictSystemPrompt(
                    moderator: moderator,
                    debaters: debaters,
                    toolsEnabled: session.hasFullCLITools
                ),
                userPrompt: buildTranscriptContext(for: session),
                allowWebSearch: session.allowWebSearch,
                toolPhase: researchPhase(for: session),
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            ), in: session)
        }

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
                allPersonas: allPersonas,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                steeringInbox: steeringInbox,
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
        let attachedImages = Self.activeImagePaths(in: session)

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
                            imagePaths: attachedImages,
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
        steeringInbox: SteeringInbox?,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        session.stage = .debating
        await onEvent(.activeThinkersChanged([target.id], statusLabel: "\(target.name) is replying directly…"))
        await onEvent(.sessionUpdated(session))

        // Since only ONE persona is running here, they safely hold the single-agent write lock if CLI tools are enabled
        let phase: ToolExecutionPhase = session.hasFullCLITools ? .coordinatedReadWrite : .closedBook
        let context = buildTranscriptContext(for: session)
        let resp = try await callModel(ModelCallRequest(
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
        ), in: session)
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
        session.updatedAt = Date()
        await onEvent(.sessionUpdated(session))
        await onEvent(.enqueueSpeech(SpeechQueueItem(
            id: turn.id,
            persona: target,
            spokenText: turn.spokenTake,
            contextLabel: "Reply · \(target.name)"
        )))

        // If user sent live steering while the direct reply was running, let the Chair address it immediately!
        if let steeringInbox, steeringInbox.hasPending {
            let (steered, _, _) = try await applyDebateSteeringIfNeeded(
                steeringInbox: steeringInbox,
                into: session,
                moderator: moderator,
                debaters: debaters,
                roundNumber: 0,
                isNearEndOfDebate: false,
                allowImmediatePeerReply: true,
                nextScheduledDebaterID: nil,
                modelLabels: modelLabels,
                openRouterKey: openRouterKey,
                onEvent: onEvent
            )
            session = steered
        }

        session.stage = .completed
        session.updatedAt = Date()
        await onEvent(.activeThinkersChanged([], statusLabel: "Ready"))
        await onEvent(.sessionUpdated(session))
        return session
    }

    // MARK: - Live User Steering Helpers (Chair-Directed Immediate Uptake)

    private func drainSteeringMessages(
        _ steeringInbox: SteeringInbox?,
        into session: inout DebateSession,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async -> [UserPromptMessage] {
        guard let steeringInbox else { return [] }
        let drained = steeringInbox.drainAll()
        guard !drained.isEmpty else { return [] }
        for var msg in drained {
            if msg.isSteering == nil {
                msg.isSteering = true
            }
            session.entries.append(.userPrompt(msg))
        }
        session.updatedAt = Date()
        await onEvent(.sessionUpdated(session))
        return drained
    }

    private static func formatSteeringTexts(_ messages: [UserPromptMessage]) -> [String] {
        messages.compactMap { msg -> String? in
            var text = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.imageAttachments.isEmpty {
                let paths = msg.imageAttachments.map { "\($0.displayName): \($0.filePath)" }.joined(separator: ", ")
                text = text.isEmpty ? "[Attached image(s): \(paths)]" : "\(text) [Attached image(s): \(paths)]"
            }
            return text.isEmpty ? nil : text
        }
    }

    private func applyDebateSteeringIfNeeded(
        steeringInbox: SteeringInbox?,
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        roundNumber: Int,
        isNearEndOfDebate: Bool,
        allowImmediatePeerReply: Bool,
        nextScheduledDebaterID: UUID?,
        modelLabels: [String: String],
        openRouterKey: String?,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> (session: DebateSession, handledSteering: Bool, needsExtraRound: Bool) {
        var session = initialSession
        let drained = await drainSteeringMessages(steeringInbox, into: &session, onEvent: onEvent)
        let steeringTexts = Self.formatSteeringTexts(drained)
        guard !steeringTexts.isEmpty else {
            return (session, false, false)
        }

        try Task.checkCancellation()
        session.stage = .debating
        await onEvent(.activeThinkersChanged(
            [moderator.id],
            statusLabel: "\(moderator.name) is reading your live steering & directing the panel…"
        ))
        await onEvent(.sessionUpdated(session))

        let steerResp = try await callModel(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: moderator.effort,
            systemPrompt: DebatePrompts.chairLiveSteeringPrompt(
                moderator: moderator,
                debaters: debaters,
                steeringTexts: steeringTexts,
                isNearEndOfDebate: isNearEndOfDebate
            ),
            userPrompt: buildTranscriptContext(for: session),
            allowWebSearch: session.allowWebSearch,
            toolPhase: researchPhase(for: session),
            workspacePath: session.workspacePath,
            openRouterAPIKey: openRouterKey
        ), in: session)

        let parsed = JSONExtractor.parseObject(steerResp.rawText)
        let needsExtra = (parsed?["needs_extra_round"] as? Bool) ?? false

        let chairTurn = parseDebateTurn(
            raw: steerResp.rawText,
            durationMs: steerResp.durationMs,
            roundNumber: roundNumber,
            roundLabel: "Live Steering",
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
            contextLabel: "Live Steering · \(moderator.name)"
        )))

        // If the Chair routed a direct question to a specific panelist who is NOT already scheduled next, let them answer right now!
        if allowImmediatePeerReply,
           let peerQ = chairTurn.directQuestionForPeer, !peerQ.isEmpty,
           let targetName = chairTurn.targetPersonaName, !targetName.isEmpty,
           let targetPeer = debaters.first(where: {
               $0.id != moderator.id && ($0.name.localizedCaseInsensitiveContains(targetName) || targetName.localizedCaseInsensitiveContains($0.name))
           }),
           targetPeer.id != nextScheduledDebaterID {
            try Task.checkCancellation()
            await onEvent(.activeThinkersChanged(
                [targetPeer.id],
                statusLabel: "\(targetPeer.name) is answering \(moderator.name)'s steered question…"
            ))
            let replyResp = try await callModel(ModelCallRequest(
                provider: targetPeer.provider,
                modelID: targetPeer.modelID,
                effort: targetPeer.effort,
                systemPrompt: DebatePrompts.peerDirectReplyPrompt(
                    responder: targetPeer,
                    challengerName: moderator.name,
                    question: peerQ,
                    workspacePath: session.workspacePath,
                    toolsEnabled: session.hasFullCLITools
                ),
                userPrompt: buildTranscriptContext(for: session),
                allowWebSearch: session.allowWebSearch,
                toolPhase: researchPhase(for: session),
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            ), in: session)
            let replyTurn = parseDebateTurn(
                raw: replyResp.rawText,
                durationMs: replyResp.durationMs,
                roundNumber: roundNumber,
                roundLabel: "Steered Reply",
                persona: targetPeer,
                modelLabel: modelLabels[targetPeer.modelID] ?? targetPeer.modelID,
                defaultStance: .replying
            )
            session.entries.append(.turn(replyTurn))
            session.updatedAt = Date()
            await onEvent(.sessionUpdated(session))
            await onEvent(.enqueueSpeech(SpeechQueueItem(
                id: replyTurn.id,
                persona: targetPeer,
                spokenText: replyTurn.spokenTake,
                contextLabel: "\(targetPeer.name) → \(moderator.name)"
            )))
        }

        return (session, true, needsExtra)
    }

    private func runSingleSteeredRebuttalPass(
        into initialSession: DebateSession,
        roundNumber: Int,
        moderator: Persona,
        debaters: [Persona],
        modelLabels: [String: String],
        openRouterKey: String?,
        steeringInbox: SteeringInbox?,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> DebateSession {
        var session = initialSession
        session.stage = .debating
        session.entries.append(.roundBanner(RoundBanner(
            roundNumber: roundNumber,
            title: "Round \(roundNumber) · Steered Council Response",
            subtitle: "Panelists respond to \(moderator.name)'s updated steering direction before the verdict"
        )))
        await onEvent(.sessionUpdated(session))

        for debater in debaters {
            try Task.checkCancellation()
            await onEvent(.activeThinkersChanged([debater.id], statusLabel: "Round \(roundNumber): \(debater.name) is addressing your steering…"))
            let resp = try await callModel(ModelCallRequest(
                provider: debater.provider,
                modelID: debater.modelID,
                effort: debater.effort,
                systemPrompt: DebatePrompts.rebuttalSystemPrompt(
                    debater: debater,
                    allDebaters: debaters,
                    moderatorName: moderator.name,
                    roundNumber: roundNumber,
                    isFinalRebuttal: true,
                    untilConsensusMode: false,
                    workspacePath: session.workspacePath,
                    toolsEnabled: session.hasFullCLITools
                ),
                userPrompt: buildTranscriptContext(for: session),
                allowWebSearch: session.allowWebSearch,
                toolPhase: researchPhase(for: session),
                workspacePath: session.workspacePath,
                openRouterAPIKey: openRouterKey
            ), in: session)
            let turn = parseDebateTurn(
                raw: resp.rawText,
                durationMs: resp.durationMs,
                roundNumber: roundNumber,
                roundLabel: "Round \(roundNumber)",
                persona: debater,
                modelLabel: modelLabels[debater.modelID] ?? debater.modelID,
                defaultStance: .cosigning
            )
            session.entries.append(.turn(turn))
            session.updatedAt = Date()
            await onEvent(.sessionUpdated(session))
            await onEvent(.enqueueSpeech(SpeechQueueItem(
                id: turn.id,
                persona: debater,
                spokenText: turn.spokenTake,
                contextLabel: "Round \(roundNumber) · \(debater.name)"
            )))

            if let steeringInbox, steeringInbox.hasPending {
                let (steered, _, _) = try await applyDebateSteeringIfNeeded(
                    steeringInbox: steeringInbox,
                    into: session,
                    moderator: moderator,
                    debaters: debaters,
                    roundNumber: roundNumber,
                    isNearEndOfDebate: false,
                    allowImmediatePeerReply: false,
                    nextScheduledDebaterID: nil,
                    modelLabels: modelLabels,
                    openRouterKey: openRouterKey,
                    onEvent: onEvent
                )
                session = steered
            }
        }
        return session
    }

    private func applyBuildSteeringIfNeeded(
        steeringInbox: SteeringInbox?,
        into initialSession: DebateSession,
        moderator: Persona,
        debaters: [Persona],
        remainingAssignments: [ExecutionAssignment],
        roundNumber: Int,
        targetFolder: String,
        modelLabels: [String: String],
        openRouterKey: String?,
        onEvent: @escaping @Sendable (OrchestratorEvent) async -> Void
    ) async throws -> (session: DebateSession, didSteer: Bool, updatedWaves: [ExecutionWave]) {
        var session = initialSession
        let drained = await drainSteeringMessages(steeringInbox, into: &session, onEvent: onEvent)
        let steeringTexts = Self.formatSteeringTexts(drained)
        guard !steeringTexts.isEmpty else {
            return (session, false, Self.partitionIntoParallelWaves(remainingAssignments, workspaceRoot: targetFolder))
        }

        try Task.checkCancellation()
        session.stage = .synthesizingVerdict
        await onEvent(.activeThinkersChanged(
            [moderator.id],
            statusLabel: "\(moderator.name) is reading your live steering & updating build workstreams…"
        ))
        await onEvent(.sessionUpdated(session))

        let steerResp = try await callModel(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: moderator.effort,
            systemPrompt: DebatePrompts.buildLiveSteeringPrompt(
                moderator: moderator,
                debaters: debaters,
                steeringTexts: steeringTexts,
                remainingAssignments: remainingAssignments,
                workspacePath: targetFolder
            ),
            userPrompt: buildTranscriptContext(for: session),
            allowWebSearch: session.allowWebSearch,
            toolPhase: .researchAndInspect,
            workspacePath: targetFolder,
            openRouterAPIKey: openRouterKey
        ), in: session)

        let steerTurn = parseDebateTurn(
            raw: steerResp.rawText,
            durationMs: steerResp.durationMs,
            roundNumber: roundNumber,
            roundLabel: "Live Steering",
            persona: moderator,
            modelLabel: modelLabels[moderator.modelID] ?? moderator.modelID,
            defaultStance: .moderating
        )
        session.entries.append(.turn(steerTurn))
        session.updatedAt = Date()
        await onEvent(.sessionUpdated(session))
        await onEvent(.enqueueSpeech(SpeechQueueItem(
            id: steerTurn.id,
            persona: moderator,
            spokenText: steerTurn.spokenTake,
            contextLabel: "Live Steering · \(moderator.name)"
        )))

        var updatedAssignments: [ExecutionAssignment] = []
        var parsedHasExplicitArray = false
        if let json = JSONExtractor.parseObject(steerResp.rawText),
           let rawAssign = json["execution_assignments"] as? [[String: Any]] {
            parsedHasExplicitArray = true
            for item in rawAssign.prefix(8) {
                guard let who = (item["assigned_to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let instr = (item["task_instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !who.isEmpty, !instr.isEmpty else { continue }
                let scope = (item["target_scope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let wave = Self.parseWave(item["wave"])
                updatedAssignments.append(ExecutionAssignment(
                    assignedPersonaName: who,
                    taskInstruction: instr,
                    targetScope: scope,
                    wave: wave
                ))
            }
        }

        if !parsedHasExplicitArray {
            updatedAssignments = remainingAssignments
            let combinedSteering = steeringTexts.joined(separator: "\n")
            let fallbackBuilder = selectPrimaryBuilder(from: debaters, excluding: nil, fallback: moderator, forTask: combinedSteering)
            let nextWaveNum = (remainingAssignments.map(\.effectiveWave).max() ?? 0) + 1
            updatedAssignments.append(ExecutionAssignment(
                assignedPersonaName: fallbackBuilder.name,
                taskInstruction: "Implement the user's live steering instruction in \(targetFolder):\n\(combinedSteering)",
                targetScope: targetFolder,
                wave: nextWaveNum
            ))
        }

        let newWaves = Self.partitionIntoParallelWaves(updatedAssignments, workspaceRoot: targetFolder)
        session.stage = .executingPlan
        await onEvent(.sessionUpdated(session))
        return (session, true, newWaves)
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
                for item in rawAssign.prefix(8) {
                    guard let who = (item["assigned_to"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          let instr = (item["task_instruction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !who.isEmpty, !instr.isEmpty else { continue }
                    let scope = (item["target_scope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let wave = Self.parseWave(item["wave"])
                    assignments.append(ExecutionAssignment(
                        assignedPersonaName: who,
                        taskInstruction: instr,
                        targetScope: scope,
                        wave: wave
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
                let header: String
                if msg.isSteering == true {
                    let recipient = (msg.steeredToPersonaName?.isEmpty == false) ? " -> DIRECTED TO \(msg.steeredToPersonaName!.uppercased())" : ""
                    header = "USER LIVE STEERING COMMENT (HIGHEST PRIORITY — APPLY IMMEDIATELY\(recipient)):"
                } else {
                    header = "USER PROMPT:"
                }
                var uBlock = "\(header)\n\(msg.text)"
                if !msg.imageAttachments.isEmpty {
                    uBlock += "\nATTACHED USER IMAGE(S):\n" + msg.imageAttachments.map {
                        "- [\($0.displayName)] \($0.filePath)"
                    }.joined(separator: "\n")
                }
                sections.append(uBlock)
            case .interview(let ex):
                if ex.wasSkipped {
                    sections.append("CLARIFYING INTERVIEW: User asked the panel to make reasonable assumptions and debate open questions directly.")
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
                var vBlock = "CO-SIGNED VERDICT (\(v.headline)):\n\(v.recommendation)"
                if !v.actionSteps.isEmpty {
                    vBlock += "\nAction Steps:\n" + v.actionSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
                }
                if let assignments = v.executionAssignments, !assignments.isEmpty {
                    vBlock += "\nExecution Workstreams:\n" + assignments.enumerated().map { idx, a in
                        let wavePrefix = a.wave.map { "[Wave \($0)] " } ?? ""
                        let scope = a.targetScope.isEmpty ? "" : " [Scope: \(a.targetScope)]"
                        return "\(idx + 1). \(wavePrefix)\(a.assignedPersonaName): \(a.taskInstruction)\(scope)"
                    }.joined(separator: "\n")
                }
                sections.append(vBlock)
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
