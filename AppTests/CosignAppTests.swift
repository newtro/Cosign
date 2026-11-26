import SwiftUI
import XCTest
@testable import Cosign
import CosignCore

@MainActor
final class CosignAppTests: XCTestCase {
    func testAppModelInitializesDefaultCouncilAndCreatesSession() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cosign-apptest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(rootDirectory: tempDir)
        let appModel = AppModel(store: store, testing: true)

        XCTAssertEqual(appModel.sessions.count, 1)
        let session = try XCTUnwrap(appModel.currentSession)
        XCTAssertEqual(appModel.activeDebaters(for: session).count, 3)
        XCTAssertEqual(appModel.activeModerator(for: session).role, .moderator)

        // Custom persona creation persists cleanly
        let custom = Persona(
            name: "Dr. Nova",
            title: "The Physicist",
            tagline: "First principles",
            role: .debater,
            provider: .agy,
            modelID: "gemini-4-neon-high",
            personality: "Rigorous",
            debateStyle: "Crisp",
            accentHex: "#60A5FA",
            avatarSymbol: "sparkles",
            voicePresetID: "orion"
        )
        appModel.upsertPersona(custom)
        XCTAssertTrue(appModel.personas.contains(where: { $0.name == "Dr. Nova" }))

        // Populate session 1 with entries, create a 4-debater Build session 2, and verify switching back & forth in NSHostingView never deadlocks!
        var populated = appModel.sessions[0]
        populated.stage = .completed
        populated.entries = [
            .userPrompt(UserPromptMessage(text: "First session prompt")),
            .verdict(CosignVerdict(
                moderatorID: DefaultRoster.veraID,
                moderatorName: "Vera",
                headline: "Ship It",
                spokenVerdict: "Ship it cleanly.",
                recommendation: "Done."
            ))
        ]
        appModel.sessions[0] = populated

        appModel.createNewTaskBuildSession()
        if let buildSession = appModel.currentSession {
            appModel.updateCurrentSessionLineup(
                moderatorID: buildSession.moderatorID,
                debaterIDs: buildSession.debaterIDs + [custom.id]
            )
        }

        let hosting = NSHostingView(rootView: CosignRootView(model: appModel).environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        // Switch from 4-debater empty Build session -> populated Debate session -> back
        appModel.selectSession(populated.id)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(appModel.selectedSessionID, populated.id)

        appModel.selectSession(appModel.sessions[0].id)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(appModel.selectedSessionID, appModel.sessions[0].id)
    }

    func testSendPromptWhileBusyQueuesLiveSteeringForActiveLeader() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cosign-steer-apptest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SessionStore(rootDirectory: tempDir)
        let appModel = AppModel(store: store, testing: true)

        var runningSession = try XCTUnwrap(appModel.currentSession)
        runningSession.stage = .debating
        runningSession.entries = [
            .userPrompt(UserPromptMessage(text: "Evaluate our multiplayer server tick rate."))
        ]
        appModel.sessions[0] = runningSession

        let leader = appModel.activeModerator(for: runningSession)
        XCTAssertEqual(leader.name, "Vera")

        // Sending a prompt while the session is busy routes directly to live steering for the active leader (Vera)
        appModel.sendPrompt("Focus on 30 Hz mobile battery usage before deciding.")

        let queued = appModel.pendingSteeringMessages(for: runningSession.id)
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(queued.first?.isSteering, true)
        XCTAssertEqual(queued.first?.steeredToPersonaName, "Vera")
        XCTAssertEqual(queued.first?.text, "Focus on 30 Hz mobile battery usage before deciding.")

        // Render the live busy UI with queued steering card + composer Steer button to verify zero layout/hosting issues
        let hosting = NSHostingView(rootView: CosignRootView(model: appModel).environment(\.colorScheme, .dark))
        hosting.frame = NSRect(x: 0, y: 0, width: 1280, height: 860)
        hosting.layoutSubtreeIfNeeded()

        // Stopping a run flushes any unconsumed steering note into session.entries so the user's input is never lost
        appModel.stopCurrentRun()
        XCTAssertTrue(appModel.pendingSteeringMessages(for: runningSession.id).isEmpty)
        let committedPrompts = appModel.currentSession?.entries.compactMap { entry -> UserPromptMessage? in
            if case .userPrompt(let msg) = entry, msg.isSteering == true { return msg }
            return nil
        } ?? []
        XCTAssertEqual(committedPrompts.count, 1)
        XCTAssertEqual(committedPrompts.first?.steeredToPersonaName, "Vera")
    }

    func testOptionalVisualUISnapshots() throws {
        guard let outDirPath = ProcessInfo.processInfo.environment["COSIGN_SNAPSHOT_DIR"], !outDirPath.isEmpty else {
            return
        }
        let outDir = URL(fileURLWithPath: outDirPath)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cosign-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = SessionStore(rootDirectory: tempDir)
        let appModel = AppModel(store: store, testing: true)

        // 1. Welcome state snapshot
        saveSnapshot(
            CosignRootView(model: appModel)
                .frame(width: 1240, height: 820)
                .environment(\.colorScheme, .dark),
            to: outDir.appendingPathComponent("ui_welcome_chamber.png")
        )

        // 2. Populated debate + verdict snapshot
        var rich = appModel.currentSession!
        rich.title = "Subscription AI Council Architecture"
        rich.stage = .completed
        rich.entries = [
            .userPrompt(UserPromptMessage(text: "I want a native Mac council app over my Claude, OpenAI, and Gemini Ultra subscriptions with spirited local voices.")),
            .roundBanner(RoundBanner(roundNumber: 2, title: "Round 2 · Cross-Examination & Rebuttals", subtitle: "Challenging assumptions and sharpening the design")),
            .turn(DebateTurn(
                roundNumber: 2,
                roundLabel: "Round 2",
                personaID: DefaultRoster.sableID,
                personaName: "Sable",
                personaTitle: "The Skeptic",
                avatarSymbol: "flame.fill",
                accentHex: "#F43F5E",
                provider: .claude,
                modelLabel: "Claude Opus 5.5",
                stance: .challenging,
                targetPersonaName: "Marcus",
                spokenTake: "[chuckle] Hold on Marcus—if you run those CLIs against the user's real home directory, every personal skill and memory file will affect the personas. Isolate HOME or don't bother.",
                thoughtProcess: "Shared CLI contexts cause unintended bias across turns.",
                keyPoints: ["Sandbox HOME per call", "Sync refreshed OAuth tokens back"],
                durationMs: 3820
            )),
            .verdict(CosignVerdict(
                moderatorID: DefaultRoster.veraID,
                moderatorName: "Vera",
                headline: "Ship a Native SwiftUI App Over Isolated Subscription CLIs + MLX Chatterbox",
                spokenVerdict: "We have a clear verdict: pair a compact two-layer SwiftUI studio interface with isolated subscription CLIs and local Chatterbox Turbo voices.",
                recommendation: "Run `claude`, `codex`, and `agy` inside temporary home directories so personas stay isolated while using flat-rate subscription quota, and synthesize spoken turns locally on Metal with Chatterbox Turbo.",
                actionSteps: [
                    "Run parallel blind opening stances before cross-examination to prevent groupthink",
                    "Keep turn cards to 2–4 spoken sentences with 1-click expandable thought drawers"
                ],
                keyTradeoffs: ["macOS Apple Silicon focus vs. zero cloud API or TTS token cost"],
                cosignedPersonaIDs: [DefaultRoster.marcusID, DefaultRoster.orionID],
                cosignedNames: ["Marcus", "Orion"],
                dissents: [
                    MinorityDissent(
                        personaID: DefaultRoster.sableID,
                        personaName: "Sable",
                        accentHex: "#F43F5E",
                        coreObjection: "Watch for CLI flag changes across auto-updates—keep fallback parsers so a CLI output format change never breaks a live session."
                    )
                ],
                moderatorThoughtProcess: "All three debaters converged on isolated CLI sandboxes; preserved Sable's CLI-version resilience warning."
            ))
        ]
        appModel.sessions[0] = rich

        saveSnapshot(
            CosignRootView(model: appModel)
                .environment(\.colorScheme, .dark),
            to: outDir.appendingPathComponent("ui_live_debate_verdict.png"),
            size: NSSize(width: 1240, height: 960)
        )

        saveSnapshot(
            PersonaStudioSheet(model: appModel)
                .environment(\.colorScheme, .dark),
            to: outDir.appendingPathComponent("ui_persona_studio.png"),
            size: NSSize(width: 920, height: 690)
        )
    }

    private func saveSnapshot<V: View>(_ view: V, to url: URL, size: NSSize = NSSize(width: 1240, height: 860)) {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        hosting.layoutSubtreeIfNeeded()

        guard let contentView = window.contentView,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            return
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
