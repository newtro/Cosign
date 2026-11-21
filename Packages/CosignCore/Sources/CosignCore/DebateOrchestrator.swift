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

/// Drives the automatic "Intake Interview → Parallel Blind Openings → Cross-Examination → Co-Signed Verdict" flow.
public final class DebateOrchestrator: Sendable {
    private let runner: ModelRunnerProtocol

    public init(runner: ModelRunnerProtocol) {
        self.runner = runner
    }

    /// Starts a brand-new user prompt on the session.
    /// - If this is the initial prompt and key context is missing, pauses at `awaitingInterviewAnswers`.
    /// - Otherwise runs straight through the debate rounds to a Co-Signed Verdict.
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

        // If user explicitly @mentioned a single persona in a follow-up, let that persona answer directly + optional quick reactions
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

        // Step 1: Intake Triage & Clarifying Interview (on initial idea or major new direction unless skipped)
        if !skipInterview && !hadPriorVerdict {
            session.stage = .scanningIntake
            await onEvent(.sessionUpdated(session))
            await onEvent(.activeThinkersChanged([moderator.id], statusLabel: "\(moderator.name) is reviewing your pitch with the panel…"))

            let intakePrompt = buildTranscriptContext(for: session, moderator: moderator, debaters: debaters)
            let resp = try await runner.call(ModelCallRequest(
                provider: moderator.provider,
                modelID: moderator.modelID,
                effort: moderator.effort,
                systemPrompt: DebatePrompts.intakeSystemPrompt(moderator: moderator, debaters: debaters),
                userPrompt: intakePrompt,
                allowWebSearch: session.allowWebSearch,
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

        // Step 2: Run the full automatic debate -> verdict pipeline
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

    /// Resumes an `awaitingInterviewAnswers` session once the user submits or skips the interview card.
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

    // MARK: - Core Multi-Round Debate Engine

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

        // Auto-title fallback if still untitled
        if session.title == "New Council Session",
           let firstPrompt = session.entries.compactMap({ entry -> String? in
               if case .userPrompt(let m) = entry { return m.text }
               return nil
           }).first {
            session.title = Self.quickHeuristicTitle(from: firstPrompt)
        }

        // --- ROUND 1: Parallel Blind Openings ---
        let r1Title = isFollowUpRound ? "Follow-Up Positions" : "Round 1 · Blind Opening Takes"
        let r1Sub = isFollowUpRound
            ? "Independent takes on your follow-up"
            : "Each panelist answers independently in parallel — zero anchoring"
        session.entries.append(.roundBanner(RoundBanner(roundNumber: 1, title: r1Title, subtitle: r1Sub)))
        await onEvent(.sessionUpdated(session))

        let baseContext = buildTranscriptContext(for: session, moderator: moderator, debaters: debaters)
        let thinkerIDs = Set(debaters.map(\.id))
        await onEvent(.activeThinkersChanged(thinkerIDs, statusLabel: "Round 1: Panelists forming independent positions in parallel…"))

        let blindTurns = try await runParallelBlindOpeningRound(
            debaters: debaters,
            transcriptContext: baseContext,
            allowWebSearch: session.allowWebSearch,
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

        // --- ROUNDS 2..N: Cross-Examination & Rebuttals ---
        let rebuttalCount = isFollowUpRound ? min(1, session.maxRebuttalRounds) : max(1, session.maxRebuttalRounds)
        for rebuttalIdx in 1...rebuttalCount {
            try Task.checkCancellation()
            let roundNum = rebuttalIdx + 1
            let isFinal = (rebuttalIdx == rebuttalCount)
            let bannerTitle = isFinal && rebuttalCount > 1
                ? "Round \(roundNum) · Final Cross-Examination & Co-Sign Check"
                : "Round \(roundNum) · Cross-Examination & Rebuttals"
            let bannerSub = isFinal
                ? "Panelists settle final stances, concessions, or holdout dissents"
                : "Challenging assumptions, poking holes, and sharpening the best ideas"

            session.entries.append(.roundBanner(RoundBanner(roundNumber: roundNum, title: bannerTitle, subtitle: bannerSub)))
            await onEvent(.sessionUpdated(session))

            var roundTurns: [DebateTurn] = []
            // Rotate speaking order each round so the same debater never speaks first every time
            let orderedDebaters = rotate(debaters, by: rebuttalIdx)
            for debater in orderedDebaters {
                try Task.checkCancellation()
                await onEvent(.activeThinkersChanged([debater.id], statusLabel: "Round \(roundNum): \(debater.name) is responding…"))

                let liveBoard = buildTranscriptContext(for: session, moderator: moderator, debaters: debaters)
                let resp = try await runner.call(ModelCallRequest(
                    provider: debater.provider,
                    modelID: debater.modelID,
                    effort: debater.effort,
                    systemPrompt: DebatePrompts.rebuttalSystemPrompt(
                        debater: debater,
                        allDebaters: debaters,
                        roundNumber: roundNum,
                        isFinalRebuttal: isFinal
                    ),
                    userPrompt: liveBoard,
                    allowWebSearch: session.allowWebSearch,
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
            }

            // Early convergence stop: if every debater already co-signed or conceded, don't burn another round talking in circles
            let allConverged = !roundTurns.isEmpty && roundTurns.allSatisfy {
                $0.stance == .cosigning || $0.stance == .conceding
            }
            if allConverged && !isFinal {
                break
            }
        }

        // --- STEP 3: Moderator Co-Signed Verdict + Minority Dissent ---
        try Task.checkCancellation()
        session.stage = .synthesizingVerdict
        await onEvent(.activeThinkersChanged([moderator.id], statusLabel: "\(moderator.name) is drafting the Co-Signed Verdict…"))
        await onEvent(.sessionUpdated(session))

        let fullTranscript = buildTranscriptContext(for: session, moderator: moderator, debaters: debaters)
        let verdictResp = try await runner.call(ModelCallRequest(
            provider: moderator.provider,
            modelID: moderator.modelID,
            effort: moderator.effort,
            systemPrompt: DebatePrompts.verdictSystemPrompt(moderator: moderator, debaters: debaters),
            userPrompt: fullTranscript,
            allowWebSearch: session.allowWebSearch,
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

        return session
    }

    private func runParallelBlindOpeningRound(
        debaters: [Persona],
        transcriptContext: String,
        allowWebSearch: Bool,
        modelLabels: [String: String],
        openRouterKey: String?
    ) async throws -> [DebateTurn] {
        try await withThrowingTaskGroup(of: (Int, DebateTurn).self) { group in
            for (index, debater) in debaters.enumerated() {
                let modelLabel = modelLabels[debater.modelID] ?? debater.modelID
                group.addTask { [runner] in
                    let resp = try await runner.call(ModelCallRequest(
                        provider: debater.provider,
                        modelID: debater.modelID,
                        effort: debater.effort,
                        systemPrompt: DebatePrompts.blindOpeningSystemPrompt(debater: debater, allDebaters: debaters),
                        userPrompt: transcriptContext,
                        allowWebSearch: allowWebSearch,
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

        let context = buildTranscriptContext(for: session, moderator: moderator, debaters: debaters)
        let resp = try await runner.call(ModelCallRequest(
            provider: target.provider,
            modelID: target.modelID,
            effort: target.effort,
            systemPrompt: DebatePrompts.followUpTurnSystemPrompt(persona: target, peers: [moderator] + debaters),
            userPrompt: context,
            allowWebSearch: session.allowWebSearch,
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
                    durationMs: durationMs
                )
            }
        }

        // Graceful prose fallback if a model ignored JSON formatting
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
                moderatorThoughtProcess: thought
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

    private func buildTranscriptContext(for session: DebateSession, moderator: Persona, debaters: [Persona]) -> String {
        var sections: [String] = []
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
                if !t.keyPoints.isEmpty {
                    block += "\nKey Points: " + t.keyPoints.joined(separator: " | ")
                }
                sections.append(block)
            case .verdict(let v):
                sections.append("PRIOR CO-SIGNED VERDICT (\(v.headline)):\n\(v.recommendation)")
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
