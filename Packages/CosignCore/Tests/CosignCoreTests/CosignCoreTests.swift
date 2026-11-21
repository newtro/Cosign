import XCTest
@testable import CosignCore

final class FakeModelRunner: ModelRunnerProtocol, @unchecked Sendable {
    var handler: (ModelCallRequest) async throws -> ModelCallResponse

    init(handler: @escaping (ModelCallRequest) async throws -> ModelCallResponse) {
        self.handler = handler
    }

    func call(_ request: ModelCallRequest) async throws -> ModelCallResponse {
        try await handler(request)
    }
}

final class CosignCoreTests: XCTestCase {
    func testAGYModelCatalogParsing() {
        let sample = """
        Fetching available models...
        gemini-4-neon-high\tGemini 4 Neon (High)
        gemini-4-hydrogen-high\tGemini 4 Hydrogen (High)
        gemini-4-carbon-medium\tGemini 4 Carbon (Medium)
        """
        let models = ModelDiscoveryService.parseAGYModelsOutput(sample)
        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models[0].id, "gemini-4-neon-high")
        XCTAssertEqual(models[0].familyGroup, "Gemini 4 Neon")
        XCTAssertEqual(models[1].familyGroup, "Gemini 4 Hydrogen")
        XCTAssertEqual(models[2].familyGroup, "Gemini 4 Carbon")
        XCTAssertTrue(models[0].effortEmbeddedInID)
    }

    func testCodexAndClaudeCatalogParsing() throws {
        let codexJSON = """
        {
          "models": [
            {"slug": "gpt-6.2-sol", "display_name": "GPT-6.2-Sol", "visibility": "list"},
            {"slug": "gpt-reserve", "display_name": "Hidden", "visibility": "hide"}
          ]
        }
        """.data(using: .utf8)!
        let codexModels = ModelDiscoveryService.parseCodexModelsCache(codexJSON)
        XCTAssertEqual(codexModels.count, 1)
        XCTAssertEqual(codexModels.first?.id, "gpt-6.2-sol")

        let claudeJSON = """
        {
          "catalog": {
            "config": {
              "models": [
                {
                  "id": "claude-opus-5-5",
                  "name": "Opus 5.5",
                  "thinking": {
                    "effort_options": [{"id": "low"}, {"id": "high"}, {"id": "max"}]
                  }
                }
              ]
            }
          }
        }
        """.data(using: .utf8)!
        let claudeModels = ModelDiscoveryService.parseClaudeCatalogJSON(claudeJSON)
        XCTAssertEqual(claudeModels.count, 1)
        XCTAssertEqual(claudeModels.first?.displayName, "Claude Opus 5.5")
        XCTAssertEqual(claudeModels.first?.supportedEfforts, [.low, .high, .max])
    }

    func testJSONExtractorHandlesMarkdownFences() {
        let wrapped = """
        Here is my JSON response:
        ```json
        {
          "stance": "challenging",
          "spoken_take": "[chuckle] Hold on Marcus, that assumes zero latency."
        }
        ```
        """
        let obj = JSONExtractor.parseObject(wrapped)
        XCTAssertEqual(obj?["stance"] as? String, "challenging")
        XCTAssertEqual(obj?["spoken_take"] as? String, "[chuckle] Hold on Marcus, that assumes zero latency.")
    }

    func testInterviewThenAutomaticDebateToVerdictFlow() async throws {
        let personas = DefaultRoster.personas
        let moderator = personas.first { $0.role == .moderator }!
        let debaters = Array(personas.filter { $0.role == .debater }.prefix(3))

        let runner = FakeModelRunner { req in
            if req.systemPrompt.contains("INTAKE TRIAGE") {
                XCTAssertEqual(req.toolPhase, .researchAndInspect)
                return ModelCallResponse(rawText: """
                {
                  "session_title": "Local AI Council App",
                  "needs_interview": true,
                  "spoken_intro": "Love the spark here—two quick questions before the panel locks horns.",
                  "thought_process": "Scope and audience are unspecified.",
                  "questions": [
                    {
                      "asked_by": "Marcus",
                      "question": "Is this strictly a personal Mac tool or commercial SaaS?",
                      "why_it_matters": "Changes auth and hosting completely.",
                      "quick_options": ["Personal Mac app", "Commercial SaaS"]
                    }
                  ]
                }
                """, durationMs: 42)
            } else if req.systemPrompt.contains("ROUND 1") {
                XCTAssertEqual(req.toolPhase, .researchAndInspect)
                return ModelCallResponse(rawText: """
                {
                  "stance": "opening",
                  "spoken_take": "Keep it 100% local on macOS and lean into subscription CLIs.",
                  "thought_process": "Deep opening analysis.",
                  "key_points": ["Zero API burn", "Fast iteration"],
                  "tools_used": "Inspected iSmith/Makefile"
                }
                """, durationMs: 55)
            } else if req.systemPrompt.contains("DIRECT THE FLOOR") {
                return ModelCallResponse(rawText: """
                {
                  "stance": "moderating",
                  "spoken_take": "Sable and Marcus, hash out how CLI permissions work without colliding.",
                  "thought_process": "Focusing the room.",
                  "key_points": ["Write safety"]
                }
                """, durationMs: 30)
            } else if req.systemPrompt.contains("DIRECT EXCHANGE ON THE FLOOR") {
                XCTAssertEqual(req.toolPhase, .researchAndInspect)
                return ModelCallResponse(rawText: """
                {
                  "stance": "replying",
                  "target_persona": "Sable",
                  "spoken_take": "Good catch Sable—Vera holds the write lock until we converge.",
                  "thought_process": "Sequential write lock.",
                  "key_points": ["Single writer"]
                }
                """, durationMs: 40)
            } else if req.systemPrompt.contains("LIVE INTER-PERSONA DEBATE") {
                XCTAssertEqual(req.toolPhase, .researchAndInspect)
                if req.systemPrompt.contains("Sable") {
                    return ModelCallResponse(rawText: """
                    {
                      "stance": "challenging",
                      "target_persona": "Marcus",
                      "spoken_take": "[chuckle] Marcus, what stops three parallel CLIs from editing the same file?",
                      "direct_question_for_peer": "How do you prevent parallel write collisions?",
                      "thought_process": "Testing write lock.",
                      "key_points": ["Parallel write hazard"]
                    }
                    """, durationMs: 60)
                }
                return ModelCallResponse(rawText: """
                {
                  "stance": "cosigning",
                  "target_persona": "Marcus",
                  "spoken_take": "Sequential Chair-coordinated writes solve that cleanly.",
                  "thought_process": "Verified.",
                  "key_points": ["Co-sign"]
                }
                """, durationMs: 60)
            } else if req.systemPrompt.contains("ASSIGNED TASK:") {
                // Coordinated execution MUST unlock full read-write access!
                XCTAssertEqual(req.toolPhase, .coordinatedReadWrite)
                return ModelCallResponse(rawText: """
                {
                  "stance": "executing",
                  "target_persona": "Vera",
                  "spoken_take": "Updated README.md and verified all package tests pass.",
                  "thought_process": "Edited README.md cleanly.",
                  "key_points": ["Updated README.md"],
                  "tools_used": "Edited README.md, ran swift test"
                }
                """, durationMs: 85)
            } else {
                return ModelCallResponse(rawText: """
                {
                  "headline": "Build a Native macOS App Over Subscription CLIs",
                  "spoken_verdict": "The council agrees: full CLI research during debate, and Chair-coordinated sequential writes.",
                  "recommendation": "Use SwiftUI + Sparkle + local Chatterbox Turbo.",
                  "action_steps": ["Scaffold XcodeGen", "Coordinate CLI writes"],
                  "key_tradeoffs": ["Mac-only vs zero marginal API cost"],
                  "cosigned_by": ["Marcus", "Sable", "Orion"],
                  "dissents": [],
                  "should_auto_execute": true,
                  "execution_assignments": [
                    {
                      "assigned_to": "Marcus",
                      "task_instruction": "Update README.md with CLI tool modes",
                      "target_scope": "README.md"
                    }
                  ],
                  "thought_process": "All three converged."
                }
                """, durationMs: 70)
            }
        }

        let orchestrator = DebateOrchestrator(runner: runner)
        let speechBox = LockedBox<[SpeechQueueItem]>([])
        let initial = DebateSession(
            moderatorID: moderator.id,
            debaterIDs: debaters.map(\.id),
            maxRebuttalRounds: 2
        )

        // Step 1: Pauses for interview
        let afterIntake = try await orchestrator.submitUserMessage(
            text: "I have a half-baked idea for an AI council app.",
            into: initial,
            moderator: moderator,
            debaters: debaters
        ) { event in
            if case .enqueueSpeech(let item) = event {
                speechBox.withLock { $0.append(item) }
            }
        }

        XCTAssertEqual(afterIntake.stage, .awaitingInterviewAnswers)
        XCTAssertEqual(afterIntake.title, "Local AI Council App")
        XCTAssertEqual(speechBox.withLock { $0.count }, 1)

        guard case .interview(let exchange) = afterIntake.entries.last else {
            XCTFail("Expected interview card")
            return
        }
        var answered = exchange.questions
        answered[0].answer = "Personal Mac app"

        // Step 2: Submit interview answers -> runs Round 1 + Round 2 (converges early!) + Verdict
        let completed = try await orchestrator.submitInterviewAnswers(
            exchangeID: exchange.id,
            updatedQuestions: answered,
            skipped: false,
            into: afterIntake,
            moderator: moderator,
            debaters: debaters
        ) { event in
            if case .enqueueSpeech(let item) = event {
                speechBox.withLock { $0.append(item) }
            }
        }

        XCTAssertEqual(completed.stage, .completed)
        let turns = completed.entries.compactMap { entry -> DebateTurn? in
            if case .turn(let t) = entry { return t }
            return nil
        }
        // Verify Chair floor direction, direct peer reply, and Chair-coordinated execution all occurred!
        XCTAssertTrue(turns.contains(where: { $0.stance == .moderating }))
        XCTAssertTrue(turns.contains(where: { $0.stance == .replying }))
        XCTAssertTrue(turns.contains(where: { $0.stance == .executing }))

        let verdicts = completed.entries.compactMap { entry -> CosignVerdict? in
            if case .verdict(let v) = entry { return v }
            return nil
        }
        XCTAssertEqual(verdicts.first?.wasExecuted, true)
        XCTAssertGreaterThanOrEqual(speechBox.withLock { $0.count }, 10)
    }

    func testResumeInterruptedDebateAndSingleSeatFailureResilience() async throws {
        let personas = DefaultRoster.personas
        let moderator = personas.first { $0.role == .moderator }!
        let debaters = Array(personas.filter { $0.role == .debater }.prefix(3))

        // Simulate one seat failing while the other two succeed
        let runner = FakeModelRunner { req in
            if req.provider == .claude {
                throw ModelRunnerError.processFailed("Simulated provider outage")
            }
            return ModelCallResponse(rawText: """
            {
              "stance": "cosigning",
              "headline": "Resilient Verdict",
              "spoken_verdict": "Here is our verdict.",
              "recommendation": "Ship it.",
              "spoken_take": "Solid plan.",
              "supporting_notes": "Notes here.",
              "key_points": ["Point 1"]
            }
            """, durationMs: 25)
        }

        let orchestrator = DebateOrchestrator(runner: runner)
        var erroredSession = DebateSession(
            title: "Interrupted Session",
            moderatorID: moderator.id,
            debaterIDs: debaters.map(\.id),
            maxRebuttalRounds: 1,
            stage: .error,
            entries: [
                .userPrompt(UserPromptMessage(text: "Test prompt")),
                .roundBanner(RoundBanner(roundNumber: 1, title: "Round 1", subtitle: "")),
                .systemNote(UUID(), "Previous error")
            ]
        )

        erroredSession = try await orchestrator.resumeInterruptedDebate(
            into: erroredSession,
            moderator: moderator,
            debaters: debaters
        ) { _ in }

        XCTAssertEqual(erroredSession.stage, .completed)
        let hasVerdict = erroredSession.entries.contains {
            if case .verdict = $0 { return true }
            return false
        }
        XCTAssertTrue(hasVerdict)
    }

    func testSessionStoreRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cosign-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(rootDirectory: tempDir)
        let personas = store.loadPersonas()
        XCTAssertGreaterThanOrEqual(personas.count, 4)

        var session = DebateSession(
            title: "Test Session",
            moderatorID: DefaultRoster.veraID,
            debaterIDs: [DefaultRoster.marcusID, DefaultRoster.sableID, DefaultRoster.orionID]
        )
        session.entries.append(.userPrompt(UserPromptMessage(text: "Hello panel")))
        store.saveSession(session)

        let reloaded = store.loadSessions()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.title, "Test Session")
    }

    func testHandoffPromptBuilderIncludesContextStepsFollowUpsAndStripsVocalTags() {
        let exchange = InterviewExchange(
            moderatorID: DefaultRoster.veraID,
            moderatorName: "Vera",
            moderatorAccentHex: "#F59E0B",
            spokenIntro: "Quick check.",
            questions: [
                InterviewQuestion(
                    askedByName: "Marcus",
                    question: "Should we trim partner rev-share from the draft?",
                    whyItMatters: "Focuses the pitch.",
                    answer: "Yes, trim rev-share for now"
                )
            ],
            isSubmitted: true,
            wasSkipped: false
        )

        let verdict = CosignVerdict(
            moderatorID: DefaultRoster.veraID,
            moderatorName: "Vera",
            headline: "Sharpen APPLICATION.md Around Playable Core",
            spokenVerdict: "[chuckle] Cut the rev-share layer and ship 10 Steam playtest keys first.",
            recommendation: "Focus APPLICATION.md on the core multiplayer loop and measurable playtest retention.",
            actionSteps: [
                "Rewrite APPLICATION.md executive summary",
                "Invite 10 external Steam playtesters",
                "Archive deferred rev-share notes"
            ],
            keyTradeoffs: ["Narrower pitch scope in exchange for higher fellowship credibility"],
            cosignedNames: ["Marcus", "Orion"],
            dissents: [
                MinorityDissent(
                    personaName: "Sable",
                    accentHex: "#EF4444",
                    coreObjection: "Do not claim retention metrics until external sessions complete."
                )
            ],
            executionAssignments: [
                ExecutionAssignment(
                    assignedPersonaName: "Marcus",
                    taskInstruction: "Remove partner rev-share section and tighten traction milestones.",
                    targetScope: "APPLICATION.md"
                )
            ]
        )

        let followUpTurn = DebateTurn(
            roundNumber: 4,
            roundLabel: "Follow-Up",
            personaID: DefaultRoster.marcusID,
            personaName: "Marcus",
            personaTitle: "The Pragmatist",
            avatarSymbol: "hammer.fill",
            accentHex: "#10B981",
            provider: .codex,
            modelLabel: "GPT-6.2-Sol",
            stance: .replying,
            spokenTake: "[sigh] Keep the budget table under three rows too.",
            thoughtProcess: "Concise table constraint."
        )

        let session = DebateSession(
            title: "Fellowship Pitch",
            moderatorID: DefaultRoster.veraID,
            debaterIDs: [DefaultRoster.marcusID, DefaultRoster.sableID, DefaultRoster.orionID],
            workspacePath: "/Volumes/Cache/repos/LastShard",
            stage: .completed,
            entries: [
                .userPrompt(UserPromptMessage(text: "Review our fellowship application.")),
                .interview(exchange),
                .verdict(verdict),
                .userPrompt(UserPromptMessage(text: "What about the budget table?")),
                .turn(followUpTurn)
            ]
        )

        let prompt = HandoffPromptBuilder.build(
            session: session,
            verdict: verdict,
            selectedStepIndices: [0, 1],
            includeFileAssignments: true,
            includeGuardrails: true,
            extraUserNote: "Preserve existing markdown headings where possible."
        )

        XCTAssertTrue(prompt.contains("`/Volumes/Cache/repos/LastShard`"))
        XCTAssertTrue(prompt.contains("Yes, trim rev-share for now"))
        XCTAssertFalse(prompt.contains("[chuckle]"))
        XCTAssertFalse(prompt.contains("[sigh]"))
        XCTAssertTrue(prompt.contains("1. Rewrite APPLICATION.md executive summary"))
        XCTAssertTrue(prompt.contains("2. Invite 10 external Steam playtesters"))
        XCTAssertFalse(prompt.contains("Archive deferred rev-share notes"))
        XCTAssertTrue(prompt.contains("`APPLICATION.md`"))
        XCTAssertTrue(prompt.contains("Keep the budget table under three rows too."))
        XCTAssertTrue(prompt.contains("**Watchout (Sable):**"))
        XCTAssertTrue(prompt.contains("Preserve existing markdown headings where possible."))
    }

    func testCollaborativeBuildModeAndVerificationFixLoop() async throws {
        let personas = DefaultRoster.personas
        let moderator = personas.first { $0.role == .moderator }!
        let debaters = Array(personas.filter { $0.role == .debater }.prefix(3))
        let tempBuildDir = FileManager.default.temporaryDirectory.appendingPathComponent("cosign-build-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBuildDir) }

        let runner = FakeModelRunner { req in
            XCTAssertEqual(req.workspacePath, tempBuildDir.path)
            if req.systemPrompt.contains("BUILD MODE INTAKE") {
                return ModelCallResponse(rawText: """
                {
                  "session_title": "Markdown CLI Converter",
                  "needs_interview": false,
                  "spoken_intro": "",
                  "supporting_notes": "Greenfield empty folder.",
                  "questions": []
                }
                """, durationMs: 20)
            } else if req.systemPrompt.contains("ARCHITECTURE & WORKSTREAM HUDDLE") {
                XCTAssertEqual(req.toolPhase, .researchAndInspect)
                return ModelCallResponse(rawText: """
                {
                  "stance": "building",
                  "spoken_take": "(laugh) Let's keep it dependency-free Python with pytest tests.",
                  "supporting_notes": "src/md2html.py + tests/test_md2html.py",
                  "key_points": ["Zero deps"],
                  "tools_used": "Checked empty build folder"
                }
                """, durationMs: 30)
            } else if req.systemPrompt.contains("BUILD BLUEPRINT") {
                return ModelCallResponse(rawText: """
                {
                  "headline": "Build Zero-Dep Markdown CLI + Pytest Suite",
                  "spoken_verdict": "Marcus builds the parser and CLI, Orion writes the tests and README, then Sable runs QA.",
                  "recommendation": "Two parallel workstreams followed by QA gate.",
                  "action_steps": ["Implement parser", "Add tests"],
                  "cosigned_by": ["Marcus", "Orion", "Sable"],
                  "should_auto_execute": true,
                  "execution_assignments": [
                    {
                      "assigned_to": "Marcus",
                      "wave": 1,
                      "task_instruction": "Create md2html.py",
                      "target_scope": "md2html.py"
                    },
                    {
                      "assigned_to": "Orion",
                      "wave": 1,
                      "task_instruction": "Create test_md2html.py",
                      "target_scope": "test_md2html.py"
                    }
                  ]
                }
                """, durationMs: 35)
            } else if req.systemPrompt.contains("ASSIGNED TASK") {
                XCTAssertEqual(req.toolPhase, .coordinatedReadWrite)
                return ModelCallResponse(rawText: """
                {
                  "stance": "executing",
                  "spoken_take": "Implemented assigned module cleanly.",
                  "supporting_notes": "Wrote files.",
                  "key_points": ["Created files"],
                  "tools_used": "Wrote module"
                }
                """, durationMs: 40)
            } else if req.systemPrompt.contains("ADVERSARIAL QA & VERIFICATION GATE") {
                XCTAssertEqual(req.toolPhase, .coordinatedReadWrite)
                // Simulate Sable catching 1 bug so the auto-fix pass runs!
                return ModelCallResponse(rawText: """
                {
                  "stance": "verifying",
                  "verification_passed": false,
                  "spoken_take": "(sigh) Caught one bug—fenced code blocks drop blank lines.",
                  "issues_found": ["Preserve blank lines inside fenced code blocks in md2html.py"],
                  "files_summary": ["md2html.py — CLI parser", "test_md2html.py — unit tests"],
                  "how_to_run": "python3 md2html.py README.md",
                  "supporting_notes": "1 failing test.",
                  "key_points": ["1 edge case caught"]
                }
                """, durationMs: 45)
            } else if req.systemPrompt.contains("ISSUES TO FIX AND RE-VERIFY") {
                XCTAssertEqual(req.toolPhase, .coordinatedReadWrite)
                return ModelCallResponse(rawText: """
                {
                  "stance": "executing",
                  "verification_passed": true,
                  "spoken_take": "Fixed fenced code block blank lines and all 8 tests now pass.",
                  "files_summary": ["md2html.py — fixed code block handling"],
                  "how_to_run": "python3 md2html.py input.md",
                  "supporting_notes": "All tests green.",
                  "key_points": ["8/8 tests passing"]
                }
                """, durationMs: 40)
            }
            return ModelCallResponse(rawText: "{}", durationMs: 10)
        }

        let orchestrator = DebateOrchestrator(runner: runner)
        let buildSession = DebateSession(
            moderatorID: moderator.id,
            debaterIDs: debaters.map(\.id),
            mode: .build,
            hasExplicitBuildFolder: true,
            completenessReviewEnabled: false,
            workspacePath: tempBuildDir.path
        )

        let finished = try await orchestrator.submitUserMessage(
            text: "Build a Markdown to HTML CLI converter with tests.",
            into: buildSession,
            moderator: moderator,
            debaters: debaters
        ) { _ in }

        XCTAssertEqual(finished.stage, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempBuildDir.path))

        let turns = finished.entries.compactMap { entry -> DebateTurn? in
            if case .turn(let t) = entry { return t }
            return nil
        }
        // 3 huddle + 2 workstreams + 1 QA gate + 1 fix pass = 7 turns
        XCTAssertEqual(turns.count, 7)
        XCTAssertTrue(turns.contains(where: { $0.stance == .verifying && $0.personaName == "Sable" }))

        let verdict = finished.entries.compactMap { entry -> CosignVerdict? in
            if case .verdict(let v) = entry { return v }
            return nil
        }.first
        XCTAssertEqual(verdict?.wasExecuted, true)
        XCTAssertEqual(verdict?.buildReport?.verificationPassed, true)
        XCTAssertEqual(verdict?.buildReport?.verifierName, "Sable")
        XCTAssertEqual(verdict?.buildReport?.howToRun, "python3 md2html.py input.md")
    }

    func testUnescapedInteriorQuotesRepairAndSessionHealing() {
        // Reproduces Orion's exact failure: unescaped quotes inside markdown backticks in `supporting_notes`
        let malformedRaw = """
        {
          "stance": "building",
          "spoken_take": "Marcus, Sable, treat this Fellowship build like a stage spotlight. (laugh) Match by label instead of hardcoded indices.",
          "supporting_notes": "Keep `"Run the world (DM)"` selected while calling `ApplyServerChoice()`.",
          "key_points": ["Reversible config", "Protocol 62"],
          "tools_used": "Inspected NetBootstrap.cs"
        }
        """

        let parsed = JSONExtractor.parseObject(malformedRaw)
        XCTAssertEqual(parsed?["stance"] as? String, "building")
        XCTAssertEqual(
            parsed?["spoken_take"] as? String,
            "Marcus, Sable, treat this Fellowship build like a stage spotlight. (laugh) Match by label instead of hardcoded indices."
        )
        XCTAssertTrue((parsed?["supporting_notes"] as? String)?.contains("\"Run the world (DM)\"") == true)
        XCTAssertEqual((parsed?["key_points"] as? [String])?.count, 2)

        // Verify retroactive healing on an already-saved broken turn
        let brokenTurn = DebateTurn(
            roundNumber: 1,
            roundLabel: "Build Huddle",
            personaID: DefaultRoster.orionID,
            personaName: "Orion",
            personaTitle: "The Lateral Thinker",
            avatarSymbol: "sparkles",
            accentHex: "#60A5FA",
            provider: .agy,
            modelLabel: "Gemini 4 Neon",
            stance: .building,
            spokenTake: "{\n  \"stance\": \"building\",\n  \"spoken_take\": \"Marcus, Sable, treat this Fellowship build",
            thoughtProcess: malformedRaw
        )
        var session = DebateSession(
            moderatorID: DefaultRoster.veraID,
            debaterIDs: [DefaultRoster.orionID],
            entries: [.turn(brokenTurn)]
        )
        XCTAssertTrue(DebateOrchestrator.healSessionIfNeeded(&session))
        if case .turn(let healed) = session.entries[0] {
            XCTAssertFalse(healed.spokenTake.contains("\"stance\""))
            XCTAssertFalse(healed.spokenTake.hasPrefix("{"))
            XCTAssertTrue(healed.spokenTake.hasPrefix("Marcus, Sable, treat this Fellowship build"))
            XCTAssertEqual(healed.toolsActivitySummary, "Inspected NetBootstrap.cs")
        } else {
            XCTFail("Expected healed turn")
        }
    }

    func testTaskBuildCrewRosterAndUpgradeMerge() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cosign-merge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(rootDirectory: tempDir)
        // Simulate an older v1.0 install that only saved the original 4 personas and 1 preset
        let legacyPersonas = Array(DefaultRoster.personas.prefix(4))
        let legacyPresets = [DefaultRoster.presets[0]]
        store.savePersonas(legacyPersonas)
        store.savePresets(legacyPresets)

        let mergedPersonas = store.loadPersonas()
        let mergedPresets = store.loadPresets()

        XCTAssertTrue(mergedPersonas.contains(where: { $0.id == DefaultRoster.atlasID && $0.name == "Atlas" }))
        XCTAssertTrue(mergedPersonas.contains(where: { $0.id == DefaultRoster.forgeID && $0.name == "Forge" }))
        XCTAssertTrue(mergedPersonas.contains(where: { $0.id == DefaultRoster.emberID && $0.name == "Ember" }))
        XCTAssertTrue(mergedPersonas.contains(where: { $0.id == DefaultRoster.rookID && $0.name == "Rook" }))
        XCTAssertTrue(mergedPersonas.contains(where: { $0.id == DefaultRoster.wardenID && $0.name == "Warden" }))
        XCTAssertTrue(mergedPresets.contains(where: { $0.id == DefaultRoster.taskBuildCrewPresetID && $0.name == "Task & Build Crew" }))
    }

    func testCompletenessReviewerRemediationLoopAndBlockerEscapeHatch() async throws {
        let allPersonas = DefaultRoster.personas
        let moderator = allPersonas.first { $0.id == DefaultRoster.atlasID }!
        let debaters = [
            allPersonas.first { $0.id == DefaultRoster.emberID }!,
            allPersonas.first { $0.id == DefaultRoster.rookID }!,
        ]
        // Warden uses OpenAI (.codex), auditing an AGY Chair + Gemini/Claude build crew!
        let warden = allPersonas.first { $0.id == DefaultRoster.wardenID }!
        let tempBuildDir = FileManager.default.temporaryDirectory.appendingPathComponent("cosign-completeness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBuildDir) }

        let auditCalls = LockedBox<Int>(0)

        let runner = FakeModelRunner { req in
            if req.systemPrompt.contains("BUILD MODE INTAKE") {
                return ModelCallResponse(rawText: """
                {"session_title": "Survive Night One", "needs_interview": false, "questions": []}
                """, durationMs: 10)
            } else if req.systemPrompt.contains("ARCHITECTURE & WORKSTREAM HUDDLE") {
                return ModelCallResponse(rawText: """
                {"stance": "building", "spoken_take": "Let's wire character prefabs and onboarding hints.", "supporting_notes": "Plan"}
                """, durationMs: 10)
            } else if req.systemPrompt.contains("BUILD BLUEPRINT") {
                return ModelCallResponse(rawText: """
                {
                  "headline": "Ship Night One Visuals & Onboarding",
                  "spoken_verdict": "Ember wires prefabs and onboarding, Rook runs QA.",
                  "recommendation": "Wire 4 Synty prefabs into StreetKit and add judge HUD hint.",
                  "action_steps": ["Wire 4 Synty prefabs into StreetKit", "Upload signed build to Steamworks"],
                  "cosigned_by": ["Ember", "Rook"],
                  "should_auto_execute": true,
                  "execution_assignments": [
                    {
                      "assigned_to": "Ember",
                      "wave": 1,
                      "task_instruction": "Stage prefabs and wire StreetKit",
                      "target_scope": "StreetKit.cs"
                    }
                  ]
                }
                """, durationMs: 15)
            } else if req.systemPrompt.contains("ASSIGNED TASK") {
                return ModelCallResponse(rawText: """
                {"stance": "executing", "spoken_take": "Staged prefabs.", "supporting_notes": "Initial pass"}
                """, durationMs: 15)
            } else if req.systemPrompt.contains("ADVERSARIAL QA & VERIFICATION GATE") {
                return ModelCallResponse(rawText: """
                {
                  "stance": "verifying",
                  "verification_passed": true,
                  "spoken_take": "42/42 EditMode tests compile and pass.",
                  "files_summary": ["StreetKit.cs — staged assets"],
                  "how_to_run": "unity -runTests"
                }
                """, durationMs: 15)
            } else if req.systemPrompt.contains("100% SPEC-TO-DISK COMPLETENESS AUDIT") {
                XCTAssertEqual(req.provider, warden.provider)
                XCTAssertEqual(req.toolPhase, .researchAndInspect)
                let passNum = auditCalls.withLock { n -> Int in
                    n += 1
                    return n
                }
                if passNum == 1 {
                    return ModelCallResponse(rawText: """
                    {
                      "stance": "challenging",
                      "is_complete": false,
                      "completeness_percent": 65,
                      "spoken_take": "Tests pass, but StreetKit still leaves the four character visual slots null, and Steamworks upload hasn't been addressed.",
                      "missing_items": [
                        "Assign the 4 Synty character prefabs into StreetKit slots instead of fallback capsules",
                        "Upload build to Steamworks or document credential blocker"
                      ],
                      "accepted_blockers": [],
                      "supporting_notes": "Audited StreetKit.prefab on disk.",
                      "key_points": ["65% complete", "2 missing items"]
                    }
                    """, durationMs: 25)
                } else {
                    // Ensure Pass 2 receives the team's documented blocker reason in userPrompt!
                    XCTAssertTrue(req.userPrompt.contains("TEAM BLOCKER REASON") || req.userPrompt.contains("Steamworks VDF credentials"))
                    return ModelCallResponse(rawText: """
                    {
                      "stance": "cosigning",
                      "is_complete": true,
                      "completeness_percent": 100,
                      "spoken_take": "Verified on disk: all four Synty prefabs are wired into StreetKit with zero capsule fallbacks, and the missing Steamworks credentials blocker is valid.",
                      "missing_items": [],
                      "accepted_blockers": ["Steamworks upload blocked: no SteamCMD credentials configured on local machine"],
                      "files_summary": ["StreetKit.cs — wired 4 Synty prefabs", "NightOneBuild.cs — verified references"],
                      "how_to_run": "open Builds/SurviveNightOne.app",
                      "supporting_notes": "100% of solvable scope verified.",
                      "key_points": ["100% complete", "1 valid external blocker accepted"]
                    }
                    """, durationMs: 25)
                }
            } else if req.systemPrompt.contains("DISPATCH SURGICAL REMEDIATION WORKSTREAMS") {
                return ModelCallResponse(rawText: """
                {
                  "stance": "moderating",
                  "spoken_take": "Warden caught the unassigned prefab slots. Ember, wire all four prefabs into StreetKit and check SteamCMD.",
                  "execution_assignments": [
                    {
                      "assigned_to": "Ember",
                      "task_instruction": "Wire all 4 Synty prefabs into StreetKit and verify SteamCMD availability",
                      "target_scope": "StreetKit.cs"
                    }
                  ]
                }
                """, durationMs: 15)
            } else if req.systemPrompt.contains("COMPLETENESS REMEDIATION WORKSTREAM") {
                return ModelCallResponse(rawText: """
                {
                  "stance": "executing",
                  "spoken_take": "Wired all four Synty prefabs directly into StreetKit and re-ran tests. SteamCMD upload is blocked because no Steamworks VDF credentials exist on this machine.",
                  "files_summary": ["StreetKit.cs — wired all 4 Synty prefabs"],
                  "unresolvable_reasons": ["Steamworks VDF credentials are not present on this local machine"],
                  "how_to_run": "open Builds/SurviveNightOne.app"
                }
                """, durationMs: 20)
            }
            return ModelCallResponse(rawText: "{}", durationMs: 10)
        }

        let orchestrator = DebateOrchestrator(runner: runner)
        let session = DebateSession(
            moderatorID: moderator.id,
            debaterIDs: debaters.map(\.id),
            mode: .build,
            hasExplicitBuildFolder: true,
            completenessReviewEnabled: true,
            completenessReviewerID: warden.id,
            workspacePath: tempBuildDir.path
        )

        let finished = try await orchestrator.submitUserMessage(
            text: "Wire the 4 Synty character prefabs into StreetKit and upload to Steamworks.",
            into: session,
            moderator: moderator,
            debaters: debaters,
            allPersonas: allPersonas
        ) { _ in }

        XCTAssertEqual(finished.stage, .completed)
        XCTAssertEqual(auditCalls.withLock { $0 }, 2)

        let turns = finished.entries.compactMap { entry -> DebateTurn? in
            if case .turn(let t) = entry { return t }
            return nil
        }
        XCTAssertTrue(turns.contains(where: { $0.personaName == "Warden" && $0.stance == .challenging }))
        XCTAssertTrue(turns.contains(where: { $0.personaName == "Warden" && $0.stance == .cosigning }))

        let verdict = finished.entries.compactMap { entry -> CosignVerdict? in
            if case .verdict(let v) = entry { return v }
            return nil
        }.first
        XCTAssertEqual(verdict?.buildReport?.completenessReviewerName, "Warden (OpenAI)")
        XCTAssertEqual(verdict?.buildReport?.completenessPercent, 100)
        XCTAssertEqual(verdict?.buildReport?.completenessIterations, 2)
        XCTAssertEqual(
            verdict?.buildReport?.acceptedBlockers,
            ["Steamworks upload blocked: no SteamCMD credentials configured on local machine"]
        )
        XCTAssertEqual(verdict?.buildReport?.howToRun, "open Builds/SurviveNightOne.app")
    }

    func testRunUntilConsensusChairMediatedConvergence() async throws {
        let personas = DefaultRoster.personas
        let moderator = personas.first { $0.role == .moderator }!
        let debaters = Array(personas.filter { $0.role == .debater }.prefix(3))
        let medCalls = LockedBox<Int>(0)

        let runner = FakeModelRunner { req in
            if req.systemPrompt.contains("INTAKE TRIAGE") {
                return ModelCallResponse(rawText: """
                {"session_title": "Consensus Test", "needs_interview": false, "questions": []}
                """, durationMs: 10)
            } else if req.systemPrompt.contains("ROUND 1") {
                return ModelCallResponse(rawText: """
                {"stance": "opening", "spoken_take": "Initial view.", "supporting_notes": "Notes"}
                """, durationMs: 10)
            } else if req.systemPrompt.contains("DIRECT THE FLOOR") {
                return ModelCallResponse(rawText: """
                {"stance": "moderating", "spoken_take": "Hash it out.", "supporting_notes": "Floor"}
                """, durationMs: 10)
            } else if req.systemPrompt.contains("CONSENSUS CHECK & ACTIVE MEDIATION") {
                let callIndex = medCalls.withLock { count -> Int in
                    count += 1
                    return count
                }
                let reached = (callIndex >= 2)
                return ModelCallResponse(rawText: """
                {
                  "consensus_reached": \(reached),
                  "stance": "moderating",
                  "spoken_take": "\(reached ? "We have consensus across the table." : "Still one sticking point—resolve the latency cap.")",
                  "supporting_notes": "Mediation check \(callIndex)"
                }
                """, durationMs: 10)
            } else if req.systemPrompt.contains("LIVE INTER-PERSONA DEBATE") {
                return ModelCallResponse(rawText: """
                {"stance": "challenging", "spoken_take": "Pushing further.", "supporting_notes": "Debate"}
                """, durationMs: 10)
            } else {
                return ModelCallResponse(rawText: """
                {"headline": "Consensus Reached Verdict", "spoken_verdict": "Agreed.", "recommendation": "Ship."}
                """, durationMs: 10)
            }
        }

        let orchestrator = DebateOrchestrator(runner: runner)
        let session = DebateSession(
            moderatorID: moderator.id,
            debaterIDs: debaters.map(\.id),
            maxRebuttalRounds: RebuttalPolicy.untilConsensusValue
        )
        XCTAssertTrue(session.runsUntilConsensus)
        XCTAssertEqual(RebuttalPolicy.shortLabel(for: session.maxRebuttalRounds), "Until Consensus")

        let finished = try await orchestrator.submitUserMessage(
            text: "Debate until you agree.",
            into: session,
            moderator: moderator,
            debaters: debaters
        ) { _ in }

        XCTAssertEqual(finished.stage, .completed)
        XCTAssertEqual(medCalls.withLock { $0 }, 2)
        // Verify it ran past Round 3 into Round 4 before Chair called consensus!
        let round4BannerExists = finished.entries.contains {
            if case .roundBanner(let b) = $0 { return b.roundNumber == 4 }
            return false
        }
        XCTAssertTrue(round4BannerExists)
    }

    func testParallelWaveExecutionAndScopeCollisionGuard() async throws {
        // 1. Verify scope collision detector separates overlapping paths and groups disjoint paths
        let disjointAndColliding = [
            ExecutionAssignment(assignedPersonaName: "Forge", taskInstruction: "Build server", targetScope: "Server/Engine", wave: 1),
            ExecutionAssignment(assignedPersonaName: "Ember", taskInstruction: "Build UI", targetScope: "Client/UI", wave: 1),
            ExecutionAssignment(assignedPersonaName: "Rook", taskInstruction: "Build tests", targetScope: "Tests/Unit", wave: 1),
            // Accidental duplicate scope inside Wave 1 must automatically shift into a subsequent sub-wave!
            ExecutionAssignment(assignedPersonaName: "Ember", taskInstruction: "Tweak HUD", targetScope: "Client/UI/Hud.cs", wave: 1),
            ExecutionAssignment(assignedPersonaName: "Forge", taskInstruction: "Wire app", targetScope: "Integration/Bootstrap.cs", wave: 2),
        ]
        let partitioned = DebateOrchestrator.partitionIntoParallelWaves(disjointAndColliding)
        XCTAssertEqual(partitioned.count, 3)
        XCTAssertEqual(partitioned[0].items.count, 3) // Server/Engine + Client/UI + Tests/Unit in parallel!
        XCTAssertEqual(partitioned[1].items.count, 1) // Client/UI/Hud.cs safely shifted out of Wave 1
        XCTAssertEqual(partitioned[2].items.count, 1) // Explicit Wave 2 runs last

        // 2. Verify real concurrent execution across 3 personas in Wave 1 before Wave 2 starts
        let allPersonas = DefaultRoster.personas
        let moderator = allPersonas.first { $0.id == DefaultRoster.atlasID }!
        let debaters = [
            allPersonas.first { $0.id == DefaultRoster.forgeID }!,
            allPersonas.first { $0.id == DefaultRoster.emberID }!,
            allPersonas.first { $0.id == DefaultRoster.rookID }!,
        ]
        let tempBuildDir = FileManager.default.temporaryDirectory.appendingPathComponent("cosign-parallel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempBuildDir) }

        struct ConcurrencyTracker {
            var currentInFlight = 0
            var maxInFlight = 0
            var wave1CompletedCount = 0
            var wave2SawCompletedWave1Count = 0
            var maxActiveThinkerBadgeCount = 0
        }
        let tracker = LockedBox(ConcurrencyTracker())

        let runner = FakeModelRunner { req in
            if req.systemPrompt.contains("BUILD MODE INTAKE") {
                return ModelCallResponse(rawText: #"{"session_title":"Parallel Build","needs_interview":false,"questions":[]}"#, durationMs: 5)
            } else if req.systemPrompt.contains("WORKSTREAM HUDDLE") {
                return ModelCallResponse(rawText: #"{"stance":"building","spoken_take":"Modular slices ready.","supporting_notes":"OK"}"#, durationMs: 5)
            } else if req.systemPrompt.contains("BUILD BLUEPRINT") {
                return ModelCallResponse(rawText: """
                {
                  "headline": "Parallel Three-Way Wave Build",
                  "spoken_verdict": "Forge, Ember, and Rook build Wave 1 in parallel, then Forge integrates Wave 2.",
                  "recommendation": "Wave 1 parallel + Wave 2 integration.",
                  "action_steps": ["Wave 1 slices", "Wave 2 wiring"],
                  "cosigned_by": ["Forge", "Ember", "Rook"],
                  "should_auto_execute": true,
                  "execution_assignments": [
                    {"assigned_to": "Forge", "wave": 1, "task_instruction": "Build Server/", "target_scope": "Server/"},
                    {"assigned_to": "Ember", "wave": 1, "task_instruction": "Build Client/", "target_scope": "Client/"},
                    {"assigned_to": "Rook", "wave": 1, "task_instruction": "Build Tests/", "target_scope": "Tests/"},
                    {"assigned_to": "Forge", "wave": 2, "task_instruction": "Wire Integration/", "target_scope": "Integration/"}
                  ]
                }
                """, durationMs: 10)
            } else if req.systemPrompt.contains("ASSIGNED TASK") {
                let isWave1 = req.systemPrompt.contains("(WAVE 1)")
                if isWave1 {
                    XCTAssertTrue(req.systemPrompt.contains("PARALLEL COUNCIL WAVE ACTIVE"))
                    XCTAssertTrue(req.systemPrompt.contains("SUB-AGENTS UNLOCKED"))
                }
                tracker.withLock { st in
                    st.currentInFlight += 1
                    st.maxInFlight = max(st.maxInFlight, st.currentInFlight)
                    if !isWave1 {
                        st.wave2SawCompletedWave1Count = st.wave1CompletedCount
                    }
                }
                try await Task.sleep(nanoseconds: 60_000_000) // 60ms overlap window so all 3 Wave-1 tasks are in flight together
                tracker.withLock { st in
                    st.currentInFlight -= 1
                    if isWave1 {
                        st.wave1CompletedCount += 1
                    }
                }
                return ModelCallResponse(rawText: #"{"stance":"executing","spoken_take":"Slice built with sub-agents.","supporting_notes":"Done"}"#, durationMs: 60)
            } else if req.systemPrompt.contains("ADVERSARIAL QA") {
                return ModelCallResponse(rawText: #"{"stance":"verifying","verification_passed":true,"spoken_take":"All green.","how_to_run":"swift test"}"#, durationMs: 10)
            }
            return ModelCallResponse(rawText: "{}", durationMs: 5)
        }

        let orchestrator = DebateOrchestrator(runner: runner)
        let session = DebateSession(
            moderatorID: moderator.id,
            debaterIDs: debaters.map(\.id),
            mode: .build,
            hasExplicitBuildFolder: true,
            completenessReviewEnabled: false,
            workspacePath: tempBuildDir.path
        )

        let finished = try await orchestrator.submitUserMessage(
            text: "Build Server, Client, and Tests in parallel, then wire Integration.",
            into: session,
            moderator: moderator,
            debaters: debaters,
            allPersonas: allPersonas
        ) { event in
            if case .activeThinkersChanged(let ids, _) = event {
                tracker.withLock { st in
                    st.maxActiveThinkerBadgeCount = max(st.maxActiveThinkerBadgeCount, ids.count)
                }
            }
        }

        XCTAssertEqual(finished.stage, .completed)
        let snapshot = tracker.withLock { $0 }
        XCTAssertEqual(snapshot.maxInFlight, 3, "Expected all 3 Wave-1 personas to execute simultaneously")
        XCTAssertEqual(snapshot.wave2SawCompletedWave1Count, 3, "Expected Wave 2 to start only after all 3 Wave-1 tasks finished")
        XCTAssertGreaterThanOrEqual(snapshot.maxActiveThinkerBadgeCount, 3)
    }
}
