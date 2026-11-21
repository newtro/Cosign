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
}
