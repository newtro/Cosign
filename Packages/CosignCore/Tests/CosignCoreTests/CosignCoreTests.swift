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
                return ModelCallResponse(rawText: """
                {
                  "stance": "opening",
                  "spoken_take": "Keep it 100% local on macOS and lean into subscription CLIs.",
                  "thought_process": "Deep opening analysis.",
                  "key_points": ["Zero API burn", "Fast iteration"]
                }
                """, durationMs: 55)
            } else if req.systemPrompt.contains("CROSS-EXAMINATION") {
                return ModelCallResponse(rawText: """
                {
                  "stance": "cosigning",
                  "target_persona": "Marcus",
                  "spoken_take": "[chuckle] Fair point—as long as CLI processes run in isolated temp homes, I'm in.",
                  "thought_process": "Verified token isolation.",
                  "key_points": ["Sandbox HOME", "Co-sign"]
                }
                """, durationMs: 60)
            } else {
                return ModelCallResponse(rawText: """
                {
                  "headline": "Build a Native macOS App Over Isolated Subscription CLIs",
                  "spoken_verdict": "The council is unanimous: ship a native SwiftUI Mac app backed by isolated subscription CLIs.",
                  "recommendation": "Use SwiftUI + Sparkle + local Chatterbox Turbo.",
                  "action_steps": ["Scaffold XcodeGen", "Isolate CLI homes"],
                  "key_tradeoffs": ["Mac-only vs zero marginal API cost"],
                  "cosigned_by": ["Marcus", "Sable", "Orion"],
                  "dissents": [],
                  "thought_process": "All three converged in Round 2."
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
        // 3 blind openings + 3 round-2 rebuttals (early stop because all cosigned!) = 6 turns
        XCTAssertEqual(turns.count, 6)
        guard case .verdict(let verdict) = completed.entries.last else {
            XCTFail("Expected final verdict")
            return
        }
        XCTAssertEqual(verdict.cosignedNames.count, 3)
        // 1 interview + 6 turns + 1 verdict = 8 spoken items
        XCTAssertEqual(speechBox.withLock { $0.count }, 8)
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
