import AppKit
import CosignCore
import CosignVoice
import SwiftUI

@main
struct CosignApp: App {
    @NSApplicationDelegateAdaptor(CosignAppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var updater = AppUpdater.shared

    private let isRunningTests: Bool

    init() {
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        self.isRunningTests = testing
        _model = StateObject(wrappedValue: AppModel(testing: testing))
    }

    var body: some Scene {
        WindowGroup("Cosign") {
            if isRunningTests {
                EmptyView()
            } else {
                CosignRootView(model: model)
                    .frame(minWidth: 980, minHeight: 680)
                    .preferredColorScheme(.dark)
                    .onAppear {
                        updater.start(appModel: model)
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 840)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckNow)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Council Session") {
                    model.createNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open Persona Studio…") {
                    model.openStudio()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }

        Settings {
            CosignSettingsView(model: model, updater: updater)
        }
    }
}

final class CosignAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Main Studio Window View

struct CosignRootView: View {
    @ObservedObject var model: AppModel

    @State private var draftPrompt: String = ""
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationSplitView {
            CouncilSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 235, ideal: 260, max: 310)
        } detail: {
            if let session = model.currentSession {
                ZStack {
                    // Deep Atmospheric Studio Canvas + Active Speaker Radial Glow
                    StudioAmbientCanvas(model: model)

                    VStack(spacing: 0) {
                        CouncilStageHeader(model: model, session: session)

                        // Timeline Stream
                        if session.entries.isEmpty {
                            ScrollView {
                                EmptyCouncilWelcomeView(model: model, session: session) { starter in
                                    draftPrompt = starter
                                    isComposerFocused = true
                                }
                            }
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 14) {
                                        ForEach(session.entries) { entry in
                                            timelineEntryView(entry)
                                                .id(entry.id)
                                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        }

                                        if session.stage.isBusy {
                                            LiveThinkingPulseRow(model: model, session: session)
                                                .id("live-pulse-anchor")
                                        } else if session.stage == .completed && !session.entries.isEmpty {
                                            SessionCompletedFinaleCard(model: model, session: session)
                                                .id("session-complete-anchor")
                                        }
                                    }
                                    .padding(.horizontal, 26)
                                    .padding(.top, 20)
                                    .padding(.bottom, 16)
                                    .frame(maxWidth: 920)
                                    .frame(maxWidth: .infinity)
                                }
                                .onChange(of: session.entries.count) { _, _ in
                                    if let lastEntry = session.entries.last {
                                        let isVerdict: Bool = {
                                            if case .verdict = lastEntry { return true }
                                            return false
                                        }()
                                        withAnimation(.easeOut(duration: 0.28)) {
                                            proxy.scrollTo(lastEntry.id, anchor: isVerdict ? .top : .bottom)
                                        }
                                    }
                                }
                                .onChange(of: session.stage) { _, newStage in
                                    if newStage == .completed {
                                        let lastIsVerdict: Bool = {
                                            if let last = session.entries.last, case .verdict = last { return true }
                                            return false
                                        }()
                                        if !lastIsVerdict {
                                            withAnimation(.easeOut(duration: 0.3)) {
                                                proxy.scrollTo("session-complete-anchor", anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Floating Composer & Live Audio Transport Bar
                        StudioComposerDock(
                            model: model,
                            session: session,
                            draftText: $draftPrompt,
                            isInputFocused: $isComposerFocused
                        )
                        .frame(maxWidth: 940)
                    }
                }
            }
        }
        .sheet(isPresented: $model.showingPersonaStudio) {
            PersonaStudioSheet(model: model)
        }
        .sheet(item: $model.activeHandoffVerdict) { verdict in
            if let session = model.currentSession {
                HandoffPromptSheet(model: model, session: session, verdict: verdict)
            }
        }
        .sheet(item: $model.activeBuildLaunchVerdict) { verdict in
            if let session = model.currentSession {
                BuildLaunchSheet(model: model, session: session, verdict: verdict)
            }
        }
    }

    @ViewBuilder
    private func timelineEntryView(_ entry: TimelineEntry) -> some View {
        switch entry {
        case .userPrompt(let msg):
            UserPromptCardView(message: msg)
        case .interview(let exchange):
            InterviewExchangeCardView(model: model, exchange: exchange)
        case .roundBanner(let banner):
            RoundBannerView(banner: banner)
        case .turn(let turn):
            DebateTurnCardView(model: model, turn: turn)
        case .verdict(let verdict):
            CosignVerdictCardView(model: model, verdict: verdict)
        case .systemNote(_, let note):
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(StudioTheme.crimson)
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.inkSecondary)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if let current = model.currentSession,
                   (current.stage == .error || current.stage == .cancelled) {
                    Button {
                        model.resumeCurrentSession()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .bold))
                            Text("Retry & Resume")
                        }
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StudioTheme.crimson.opacity(0.09))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.crimson.opacity(0.28), lineWidth: 1))
            )
        }
    }
}

// MARK: - Ambient Studio Canvas (Subtle Radial Aura Synced to Active Speaker/Thinker)

private struct StudioAmbientCanvas: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let activeColor: Color = {
            if let speaking = model.voiceEngine.activeItem, model.voiceEngine.isPlaying {
                return Color(hex: speaking.persona.accentHex)
            }
            if let thinkerID = model.activeThinkerIDs.first,
               let p = model.persona(for: thinkerID) {
                return Color(hex: p.accentHex)
            }
            return StudioTheme.brass
        }()

        ZStack {
            LinearGradient(
                colors: [StudioTheme.canvasTop, StudioTheme.canvasBottom],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [activeColor.opacity(0.085), .clear],
                center: .top,
                startRadius: 20,
                endRadius: 520
            )
            .animation(.easeInOut(duration: 0.7), value: activeColor.description)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Subtle Live Thinking Row in Stream

private struct LiveThinkingPulseRow: View {
    @ObservedObject var model: AppModel
    let session: DebateSession

    var body: some View {
        let thinkers = model.activeThinkerIDs.compactMap { model.persona(for: $0) }

        HStack(spacing: 10) {
            HStack(spacing: -6) {
                ForEach(thinkers) { p in
                    Circle()
                        .fill(Color(hex: p.accentHex).opacity(0.28))
                        .frame(width: 24, height: 24)
                        .overlay(
                            Image(systemName: p.avatarSymbol)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(hex: p.accentHex))
                        )
                        .overlay(Circle().strokeBorder(StudioTheme.canvasTop, lineWidth: 1.5))
                }
            }

            Text(model.liveStatusText.isEmpty ? "Council deliberating…" : model.liveStatusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StudioTheme.inkSecondary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.035))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        )
    }
}

// MARK: - Unmistakable Bottom-of-Stream Completion Finale Card

private struct SessionCompletedFinaleCard: View {
    @ObservedObject var model: AppModel
    let session: DebateSession

    @State private var copiedRunCmd = false

    private var latestVerdict: CosignVerdict? {
        for entry in session.entries.reversed() {
            if case .verdict(let v) = entry { return v }
        }
        return nil
    }

    private var lastEntryIsVerdict: Bool {
        if let last = session.entries.last, case .verdict = last { return true }
        return false
    }

    var body: some View {
        let voiceActive = model.voiceEngine.isPlaying || !model.voiceEngine.queuedItems.isEmpty
        let remainingAudioCount = model.voiceEngine.queuedItems.count + (model.voiceEngine.isPlaying ? 1 : 0)

        if let verdict = latestVerdict, let report = verdict.buildReport, !lastEntryIsVerdict {
            // Full Build & QA Finale Card right at the bottom of the timeline!
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(StudioTheme.emerald.opacity(0.22))
                            .frame(width: 34, height: 34)
                        Image(systemName: report.verificationPassed ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(StudioTheme.emerald)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.verificationPassed
                             ? "BUILD FINISHED & QA VERIFIED BY \(report.verifierName.uppercased())"
                             : "BUILD FINISHED · SEE QA NOTES")
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(StudioTheme.emerald)

                        Text(voiceActive
                             ? "All AI workstreams complete · Still voicing \(remainingAudioCount) turn\(remainingAudioCount == 1 ? "" : "s") aloud"
                             : "All AI workstreams, tests, and voice playback are 100% done")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(voiceActive ? StudioTheme.brassBright : StudioTheme.inkSecondary)
                    }

                    Spacer()

                    Button {
                        model.openFolderInFinder(report.buildFolder)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10.5))
                            Text("Open in Finder")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: true))

                    Button {
                        model.openHandoffSheet(for: verdict)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10.5))
                            Text("Handoff Prompt")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.sky, active: true))
                }

                if !report.verificationSummary.isEmpty {
                    Text(report.verificationSummary)
                        .font(.system(size: 13.5))
                        .lineSpacing(3.5)
                        .foregroundStyle(StudioTheme.inkPrimary)
                        .textSelection(.enabled)
                }

                if !report.filesSummary.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("KEY FILES TOUCHED (\(URL(fileURLWithPath: report.buildFolder).lastPathComponent))")
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(StudioTheme.brassBright)

                        ForEach(report.filesSummary.prefix(8), id: \.self) { fileLine in
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(StudioTheme.emerald)
                                    .padding(.top, 3)
                                Text(fileLine)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035)))
                }

                if !report.howToRun.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("HOW TO RUN / TEST")
                                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(StudioTheme.brassBright)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report.howToRun, forType: .string)
                                copiedRunCmd = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    copiedRunCmd = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: copiedRunCmd ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 10))
                                    Text(copiedRunCmd ? "Copied" : "Copy Commands")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(StudioTheme.emerald)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(report.howToRun)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(StudioTheme.inkPrimary)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.32)))
                }
            }
            .padding(18)
            .studioCard(
                cornerRadius: 18,
                fill: Color(hex: "#101A19"),
                glowColor: StudioTheme.emerald,
                glowIntensity: 0.28
            )
        } else {
            // Compact Clear Completion Strip for Debate Mode / Follow-ups
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(StudioTheme.emerald)

                Text(voiceActive
                     ? "Council finished deliberating · Still speaking (\(remainingAudioCount) turn\(remainingAudioCount == 1 ? "" : "s") queued)"
                     : "Session Finished · All agents done — ask a follow-up below anytime")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.emerald)

                Spacer()

                if let verdict = latestVerdict, !lastEntryIsVerdict {
                    Button {
                        model.openBuildLaunchSheet(for: verdict)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 10))
                            Text("Build This Plan…")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.brassBright, active: true))

                    Button {
                        model.openHandoffSheet(for: verdict)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 10))
                            Text("Handoff Prompt")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: true))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(StudioTheme.emerald.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(StudioTheme.emerald.opacity(0.34), lineWidth: 1)
                    )
            )
        }
    }
}
