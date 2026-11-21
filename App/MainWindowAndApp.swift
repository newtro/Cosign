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
                                        }
                                    }
                                    .padding(.horizontal, 26)
                                    .padding(.top, 20)
                                    .padding(.bottom, 16)
                                    .frame(maxWidth: 920)
                                    .frame(maxWidth: .infinity)
                                }
                                .onChange(of: session.entries.count) { _, _ in
                                    if let lastID = session.entries.last?.id {
                                        withAnimation(.easeOut(duration: 0.28)) {
                                            proxy.scrollTo(lastID, anchor: .bottom)
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
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(StudioTheme.crimson)
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.inkSecondary)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(StudioTheme.crimson.opacity(0.09))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(StudioTheme.crimson.opacity(0.28), lineWidth: 1))
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
