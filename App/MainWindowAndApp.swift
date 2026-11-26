import AppKit
import CosignCore
import CosignVoice
import SwiftUI

private extension Notification.Name {
    static let cosignScrollToBottom = Notification.Name("Cosign.ScrollToBottom")
}

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
                    .frame(minWidth: 760, minHeight: 540)
                    .background(WindowGeometryPersistenceView())
                    .preferredColorScheme(.dark)
                    .onAppear {
                        updater.start(appModel: model)
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 880)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckNow)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Council Debate") {
                    model.createNewSession(forceMode: .debate)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("New Task / Build Crew Session") {
                    model.createNewTaskBuildSession()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("Open Persona Studio…") {
                    model.openStudio()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("Attach Image(s)…") {
                    model.attachImagesWithOpenPanel()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Scroll to Bottom") {
                    NotificationCenter.default.post(name: .cosignScrollToBottom, object: nil)
                }
                .keyboardShortcut("j", modifiers: [.command])
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
    @State private var scrollToBottomTrigger: Int = 0
    @State private var isScrolledNearBottom: Bool = true
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        NavigationSplitView {
            CouncilSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            if let session = model.currentSession {
                GeometryReader { detailGeo in
                    let horizontalMargin: CGFloat = detailGeo.size.width < 760 ? 14 : (detailGeo.size.width < 1260 ? 24 : 36)

                    ZStack {
                        // Deep Atmospheric Studio Canvas + Active Speaker Radial Glow
                        StudioAmbientCanvas(model: model)

                        VStack(spacing: 0) {
                            CouncilStageHeader(model: model, session: session)

                            // Timeline Stream
                            if session.entries.isEmpty && !session.stage.isBusy {
                                ScrollView {
                                    EmptyCouncilWelcomeView(model: model, session: session) { starter in
                                        draftPrompt = starter
                                        isComposerFocused = true
                                    }
                                }
                                .id("empty-\(session.id.uuidString)")
                            } else {
                                ScrollViewReader { proxy in
                                    ZStack(alignment: .bottomTrailing) {
                                        ScrollView {
                                            LazyVStack(alignment: .leading, spacing: 14) {
                                                ForEach(session.entries) { entry in
                                                    timelineEntryView(entry)
                                                        .id(entry.id)
                                                }

                                                ForEach(model.pendingSteeringMessages(for: session.id)) { pendingMsg in
                                                    UserPromptCardView(model: model, message: pendingMsg, isQueuedLiveSteering: true)
                                                        .id(pendingMsg.id)
                                                }

                                                if session.stage.isBusy {
                                                    LiveThinkingPulseRow(model: model, session: session)
                                                        .id("live-pulse-anchor")
                                                } else if session.stage == .completed && !session.entries.isEmpty {
                                                    SessionCompletedFinaleCard(model: model, session: session)
                                                        .id("session-complete-anchor")
                                                }

                                                // Lightweight AppKit NSScrollView observer (zero PreferenceKey / zero AttributeGraph cycle!)
                                                ScrollNearBottomProbe(isNearBottom: $isScrolledNearBottom)
                                                    .frame(height: 1)
                                                    .id("timeline-bottom-sentinel")
                                            }
                                            .padding(.horizontal, horizontalMargin)
                                            .padding(.top, 18)
                                            .padding(.bottom, 14)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .onChange(of: session.entries.count) { _, _ in
                                            guard isScrolledNearBottom else { return }
                                            if let lastEntry = session.entries.last {
                                                let isVerdict: Bool = {
                                                    if case .verdict = lastEntry { return true }
                                                    return false
                                                }()
                                                withAnimation(.easeOut(duration: 0.26)) {
                                                    if isVerdict {
                                                        proxy.scrollTo(lastEntry.id, anchor: .top)
                                                    } else {
                                                        proxy.scrollTo("timeline-bottom-sentinel", anchor: .bottom)
                                                    }
                                                }
                                            }
                                        }
                                        .onChange(of: model.pendingSteeringMessages(for: session.id).count) { _, newCount in
                                            guard newCount > 0 && isScrolledNearBottom else { return }
                                            withAnimation(.easeOut(duration: 0.24)) {
                                                proxy.scrollTo("timeline-bottom-sentinel", anchor: .bottom)
                                            }
                                        }
                                        .onChange(of: session.stage) { _, newStage in
                                            if newStage == .completed && isScrolledNearBottom {
                                                let lastIsVerdict: Bool = {
                                                    if let last = session.entries.last, case .verdict = last { return true }
                                                    return false
                                                }()
                                                if !lastIsVerdict {
                                                    withAnimation(.easeOut(duration: 0.3)) {
                                                        proxy.scrollTo("timeline-bottom-sentinel", anchor: .bottom)
                                                    }
                                                }
                                            }
                                        }
                                        .onChange(of: scrollToBottomTrigger) { _, _ in
                                            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                                                proxy.scrollTo("timeline-bottom-sentinel", anchor: .bottom)
                                            }
                                        }

                                        // Floating "Scroll to Bottom" Action Pill whenever user scrolls up
                                        if !isScrolledNearBottom {
                                            Button {
                                                scrollToBottomTrigger += 1
                                            } label: {
                                                HStack(spacing: 7) {
                                                    if session.stage.isBusy {
                                                        Circle()
                                                            .fill(StudioTheme.brassBright)
                                                            .frame(width: 7, height: 7)
                                                    }
                                                    Image(systemName: "arrow.down")
                                                        .font(.system(size: 11.5, weight: .bold))
                                                    Text(session.stage.isBusy ? "Jump to Live Turn" : "Scroll to Bottom")
                                                        .font(.system(size: 12, weight: .semibold))
                                                }
                                                .foregroundStyle(StudioTheme.inkPrimary)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(
                                                    Capsule(style: .continuous)
                                                        .fill(StudioTheme.cardElevated.opacity(0.96))
                                                        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                                                )
                                                .overlay(
                                                    Capsule(style: .continuous)
                                                        .strokeBorder(
                                                            (session.stage.isBusy ? StudioTheme.brassBright : StudioTheme.emerald).opacity(0.55),
                                                            lineWidth: 1.1
                                                        )
                                                )
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.trailing, horizontalMargin + 6)
                                            .padding(.bottom, 12)
                                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                                        }
                                    }
                                }
                                .id("stream-\(session.id.uuidString)")
                            }

                            // Floating Composer & Live Audio Transport Bar (Fluid width matching timeline)
                            StudioComposerDock(
                                model: model,
                                session: session,
                                draftText: $draftPrompt,
                                isInputFocused: $isComposerFocused,
                                onScrollToBottom: {
                                    scrollToBottomTrigger += 1
                                }
                            )
                            .padding(.horizontal, horizontalMargin)
                        }
                    }
                }
            }
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            isScrolledNearBottom = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cosignScrollToBottom)) { _ in
            scrollToBottomTrigger += 1
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
        .sheet(item: $model.activePreviewAttachment) { attachment in
            ImageAttachmentLightboxSheet(attachment: attachment)
        }
    }

    @ViewBuilder
    private func timelineEntryView(_ entry: TimelineEntry) -> some View {
        switch entry {
        case .userPrompt(let msg):
            UserPromptCardView(model: model, message: msg)
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

                if let reviewerName = report.completenessReviewerName {
                    let pct = report.completenessPercent ?? 100
                    let passes = report.completenessIterations ?? 1
                    HStack(spacing: 7) {
                        Image(systemName: pct >= 100 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(pct >= 100 ? StudioTheme.emerald : StudioTheme.brassBright)
                        Text("\(pct)% COMPLETENESS AUDITED & SIGNED OFF BY \(reviewerName.uppercased()) (\(passes) PASS\(passes == 1 ? "" : "ES"))")
                            .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(pct >= 100 ? StudioTheme.emerald : StudioTheme.brassBright)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5.5)
                    .background(Capsule().fill((pct >= 100 ? StudioTheme.emerald : StudioTheme.brassBright).opacity(0.13)))
                }

                if let blockers = report.acceptedBlockers, !blockers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VERIFIED EXTERNAL BLOCKERS")
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(StudioTheme.brassBright)
                        ForEach(blockers, id: \.self) { blocker in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(StudioTheme.brassBright)
                                    .padding(.top, 2.5)
                                Text(blocker)
                                    .font(.system(size: 12))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(StudioTheme.brass.opacity(0.08)))
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

// MARK: - Multi-Monitor Window Frame & Screen Persistence Across Restarts

private struct WindowGeometryPersistenceView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowGeometryObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowGeometryObserverView: NSView {
    private static let frameDefaultsKey = "Cosign.MainWindowFrameV2"
    private static let fullScreenDefaultsKey = "Cosign.MainWindowFullScreenV2"

    private weak var observedWindow: NSWindow?
    private var tokens: [NSObjectProtocol] = []
    private var isRestoring = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let win = window, win !== observedWindow else { return }
        tearDownObservers()
        observedWindow = win

        restoreSavedGeometry(on: win)
        installObservers(for: win)
    }

    private func restoreSavedGeometry(on win: NSWindow) {
        isRestoring = true
        win.setFrameAutosaveName("CosignStudioMainWindow")

        if let rawFrame = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) {
            let candidate = NSRectFromString(rawFrame)
            if candidate.width >= 700 && candidate.height >= 480 {
                let targetFrame = validatedFrameAcrossMonitors(candidate)
                win.setFrame(targetFrame, display: true, animate: false)
                // Apply once more on next runloop tick so SwiftUI's initial `defaultSize` pass never overrides monitor placement!
                DispatchQueue.main.async { [weak self, weak win] in
                    if let win {
                        win.setFrame(targetFrame, display: true, animate: false)
                        if UserDefaults.standard.bool(forKey: Self.fullScreenDefaultsKey),
                           !win.styleMask.contains(.fullScreen) {
                            win.toggleFullScreen(nil)
                        }
                    }
                    self?.isRestoring = false
                }
                return
            }
        }
        isRestoring = false
    }

    private func validatedFrameAcrossMonitors(_ rect: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return rect }

        // Check if at least a 120x80 region of the saved frame is visible on ANY connected monitor
        for screen in screens {
            let intersection = rect.intersection(screen.visibleFrame)
            if intersection.width >= 120 && intersection.height >= 80 {
                return rect
            }
        }

        // External monitor was unplugged — fit cleanly onto primary screen's visible area
        let fallback = (NSScreen.main ?? screens[0]).visibleFrame
        let w = min(rect.width, fallback.width)
        let h = min(rect.height, fallback.height)
        let x = fallback.minX + (fallback.width - w) * 0.5
        let y = fallback.minY + (fallback.height - h) * 0.5
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func installObservers(for win: NSWindow) {
        let nc = NotificationCenter.default
        let saveHandler: (Notification) -> Void = { [weak self, weak win] _ in
            guard let self, let win, !self.isRestoring else { return }
            let isFS = win.styleMask.contains(.fullScreen)
            UserDefaults.standard.set(isFS, forKey: Self.fullScreenDefaultsKey)
            if !isFS {
                let rect = win.frame
                if rect.width >= 700 && rect.height >= 480 {
                    UserDefaults.standard.set(NSStringFromRect(rect), forKey: Self.frameDefaultsKey)
                }
            }
        }

        tokens.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: win, queue: .main, using: saveHandler))
        tokens.append(nc.addObserver(forName: NSWindow.didResizeNotification, object: win, queue: .main, using: saveHandler))
        tokens.append(nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: win, queue: .main, using: saveHandler))
        tokens.append(nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: win, queue: .main, using: saveHandler))
        tokens.append(nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: win, queue: .main, using: saveHandler))
        tokens.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: saveHandler))
    }

    private func tearDownObservers() {
        for t in tokens {
            NotificationCenter.default.removeObserver(t)
        }
        tokens.removeAll()
    }

    deinit {
        for t in tokens {
            NotificationCenter.default.removeObserver(t)
        }
    }
}

// MARK: - Zero-Cycle AppKit ScrollView Near-Bottom Probe

private struct ScrollNearBottomProbe: NSViewRepresentable {
    @Binding var isNearBottom: Bool

    func makeNSView(context: Context) -> ScrollProbeNSView {
        let view = ScrollProbeNSView()
        view.onNearBottomChanged = { near in
            DispatchQueue.main.async {
                if self.isNearBottom != near {
                    self.isNearBottom = near
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: ScrollProbeNSView, context: Context) {}
}

private final class ScrollProbeNSView: NSView {
    var onNearBottomChanged: ((Bool) -> Void)?
    private weak var observedClipView: NSClipView?
    private var tokens: [NSObjectProtocol] = []
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachIfNeeded()
    }

    private func attachIfNeeded() {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        guard clip !== observedClipView else { return }
        tearDown()
        observedClipView = clip
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true

        let nc = NotificationCenter.default
        let handler: (Notification) -> Void = { [weak self] _ in
            self?.evaluatePosition()
        }
        tokens.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main, using: handler))
        tokens.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main, using: handler))
        if let doc = scrollView.documentView {
            doc.postsFrameChangedNotifications = true
            tokens.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main, using: handler))
        }
        evaluatePosition()
    }

    private func evaluatePosition() {
        guard let scrollView = enclosingScrollView,
              let doc = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let docHeight = doc.bounds.height
        let clipHeight = clip.bounds.height

        let near: Bool
        if docHeight <= clipHeight + 72 {
            near = true
        } else if doc.isFlipped {
            near = clip.bounds.maxY >= (docHeight - 72)
        } else {
            near = clip.bounds.minY <= 72
        }

        if lastReported != near {
            lastReported = near
            onNearBottomChanged?(near)
        }
    }

    private func tearDown() {
        for t in tokens {
            NotificationCenter.default.removeObserver(t)
        }
        tokens.removeAll()
    }

    deinit {
        for t in tokens {
            NotificationCenter.default.removeObserver(t)
        }
    }
}
