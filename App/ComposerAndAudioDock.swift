import CosignCore
import CosignVoice
import SwiftUI

// MARK: - Empty-State Welcome & Inspiration Deck

struct EmptyCouncilWelcomeView: View {
    @ObservedObject var model: AppModel
    let session: DebateSession
    let onSelectStarter: (String) -> Void

    private let starters: [(icon: String, title: String, subtitle: String, prompt: String)] = [
        (
            "lightbulb.max.fill",
            "Shape a Half-Baked App Idea",
            "Panel interviews you first, then debates scope & MVP",
            "I have a half-baked idea for a tool I want to build, and I want you guys to interview me on the missing pieces and help figure out the sharpest v1."
        ),
        (
            "scale.3d",
            "Stress-Test a Technical Bet",
            "Pragmatist vs. Skeptic vs. Lateral Thinker",
            "We need to choose between building a custom local-first sync engine or leaning on CloudKit for a macOS + iOS app. Debate the real trade-offs."
        ),
        (
            "chart.line.uptrend.xyaxis",
            "Product & Pricing Wedge",
            "Find blind spots before committing",
            "Help me figure out the smartest positioning and pricing model for a niche creator utility without racing to the bottom."
        ),
        (
            "bolt.shield.fill",
            "Red-Team My Plan",
            "Poke holes in assumptions before I start",
            "I'm about to spend two weeks building a new project—interview me about what it is, try to talk me out of the weak parts, and co-sign what survives."
        ),
    ]

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)

            // Emblem & Editorial Welcome
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [StudioTheme.brass.opacity(0.28), .clear],
                                center: .center,
                                startRadius: 6,
                                endRadius: 56
                            )
                        )
                        .frame(width: 110, height: 110)

                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#1A2235"), Color(hex: "#101522")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 68, height: 68)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(StudioTheme.brass.opacity(0.45), lineWidth: 1.2)
                        )
                        .shadow(color: StudioTheme.brass.opacity(0.25), radius: 16, y: 6)

                    Image(systemName: "signature")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [StudioTheme.brassBright, StudioTheme.brass],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Text("Bring Your Idea to the Council")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(StudioTheme.inkPrimary)

                Text("Pitch a rough spark or tough decision. The panel will interview you on what's missing,\ndebate it aloud in compact turns, and deliver a Co-Signed Verdict.")
                    .font(.system(size: 13.5))
                    .lineSpacing(3.5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(StudioTheme.inkSecondary)
                    .frame(maxWidth: 560)
            }

            // 2x2 Starter Cards
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(starters.enumerated()), id: \.offset) { _, item in
                    StarterPromptTile(
                        icon: item.icon,
                        title: item.title,
                        subtitle: item.subtitle
                    ) {
                        onSelectStarter(item.prompt)
                    }
                }
            }
            .frame(maxWidth: 680)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 28)
    }
}

private struct StarterPromptTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StudioTheme.brassBright)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(StudioTheme.brass.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.inkPrimary)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(StudioTheme.inkMuted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hovering ? StudioTheme.cardElevated : StudioTheme.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? StudioTheme.brass.opacity(0.38) : Color.white.opacity(0.07), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Floating Studio Composer & Live Audio Transport Bar

struct StudioComposerDock: View {
    @ObservedObject var model: AppModel
    let session: DebateSession
    @Binding var draftText: String
    @FocusState.Binding var isInputFocused: Bool

    var body: some View {
        let hasPriorVerdict = session.entries.contains {
            if case .verdict = $0 { return true }
            return false
        }

        VStack(spacing: 0) {
            // Upper Ribbon: Live Audio Transport & Chatterbox Turbo Status
            AudioTransportRibbon(model: model)

            Divider().overlay(Color.white.opacity(0.07))

            // Quick @Mention Follow-up Strip once a verdict exists
            if hasPriorVerdict && !session.stage.isBusy {
                let participants = [model.activeModerator(for: session)] + model.activeDebaters(for: session)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Ask directly:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StudioTheme.inkMuted)
                        ForEach(participants) { p in
                            Button {
                                if !draftText.contains("@\(p.name)") {
                                    draftText = draftText.isEmpty ? "@\(p.name) " : "\(draftText) @\(p.name) "
                                }
                                isInputFocused = true
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(Color(hex: p.accentHex))
                                        .frame(width: 6, height: 6)
                                    Text("@\(p.name)")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(StudioTheme.inkSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(Color.white.opacity(0.05)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 9)
                    .padding(.bottom, 2)
                }
            }

            // Main Prompt Input Row
            HStack(alignment: .bottom, spacing: 12) {
                TextField(
                    session.entries.isEmpty
                        ? "Pitch an idea or question for the council… (VoiceSmith ready)"
                        : "Follow up, push back, or @mention a panelist…",
                    text: $draftText,
                    axis: .vertical
                )
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5))
                .foregroundStyle(StudioTheme.inkPrimary)
                .focused($isInputFocused)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.shift) {
                        return .ignored
                    }
                    if !session.stage.isBusy && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let toSend = draftText
                        draftText = ""
                        model.sendPrompt(toSend)
                        return .handled
                    }
                    return .ignored
                }
                .padding(.vertical, 6)

                if session.stage.isBusy {
                    Button {
                        model.stopCurrentRun()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text("Stop")
                                .font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(StudioTheme.crimson))
                    }
                    .buttonStyle(.plain)
                } else {
                    let canSend = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button {
                        let toSend = draftText
                        draftText = ""
                        model.sendPrompt(toSend)
                    } label: {
                        HStack(spacing: 6) {
                            Text(session.entries.isEmpty ? "Convene" : "Send")
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                    .disabled(!canSend)
                    .opacity(canSend ? 1.0 : 0.42)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)

            // Bottom Micro-Controls Bar
            HStack(spacing: 10) {
                // Web Search Toggle
                Button {
                    model.setCurrentSessionWebSearch(!session.allowWebSearch)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "globe")
                            .font(.system(size: 10.5))
                        Text(session.allowWebSearch ? "Web Search On" : "Closed-Book")
                    }
                }
                .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.sky, active: session.allowWebSearch))

                // Rebuttal Depth Menu
                Menu {
                    ForEach([1, 2, 3], id: \.self) { count in
                        Button {
                            model.setCurrentSessionRounds(count)
                        } label: {
                            HStack {
                                Text(count == 1 ? "1 Rebuttal Round (Fast)" : (count == 2 ? "2 Rebuttal Rounds (Balanced)" : "3 Rebuttal Rounds (Deep)"))
                                if session.maxRebuttalRounds == count {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10.5))
                        Text("\(session.maxRebuttalRounds) \(session.maxRebuttalRounds == 1 ? "Rebuttal" : "Rebuttals")")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(StudioTheme.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.045)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                if session.entries.isEmpty && !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.stage.isBusy {
                    Button {
                        let toSend = draftText
                        draftText = ""
                        model.sendPrompt(toSend, skipInterview: true)
                    } label: {
                        Text("Skip Interview & Debate Straight Away →")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("⏎ Convene  ·  ⇧⏎ New line")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.inkMuted.opacity(0.75))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 11)
        }
        .studioCard(cornerRadius: 20, fill: StudioTheme.dockGlass)
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .padding(.top, 6)
    }
}

// MARK: - Live Audio Transport & Chatterbox Turbo Status Ribbon

private struct AudioTransportRibbon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let voice = model.voiceEngine
        let activeAccent = voice.activeItem.map { Color(hex: $0.persona.accentHex) } ?? StudioTheme.brassBright

        HStack(spacing: 12) {
            // Engine Status Dot + Label
            HStack(spacing: 6) {
                Circle()
                    .fill(statusDotColor(voice.daemonState))
                    .frame(width: 7, height: 7)

                if let active = voice.activeItem {
                    if voice.isPlaying {
                        LiveEqualizerBars(level: voice.speakerLevel, color: activeAccent, barCount: 5, maxHeight: 13)
                    }
                    Text(active.contextLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.inkPrimary)
                        .lineLimit(1)
                    if !voice.queuedItems.isEmpty {
                        Text("+\(voice.queuedItems.count) queued")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                } else {
                    Text(statusDescription(voice.daemonState))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.inkMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Playback Transport Controls
            if voice.activeItem != nil || !voice.queuedItems.isEmpty {
                Button {
                    voice.togglePlayPause()
                } label: {
                    Image(systemName: voice.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(StudioTheme.inkPrimary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(voice.isPlaying ? "Pause speech" : "Resume speech")

                Button {
                    voice.skipCurrent()
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(StudioTheme.inkSecondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Skip to next speaker")
            }

            // Speed Picker
            Menu {
                ForEach([0.95, 1.0, 1.08, 1.2, 1.35], id: \.self) { rate in
                    Button {
                        model.setPlaybackSpeed(rate)
                    } label: {
                        HStack {
                            Text(String(format: "%.2gx Speed", rate))
                            if abs(model.preferences.playbackSpeed - rate) < 0.02 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(String(format: "%.2gx", model.preferences.playbackSpeed))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(StudioTheme.inkSecondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            // Auto-Speak / Mute Toggle
            Button {
                model.toggleAutoSpeak()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.preferences.autoSpeakResponses ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 10.5))
                    Text(model.preferences.autoSpeakResponses ? "Voice On" : "Muted")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(model.preferences.autoSpeakResponses ? StudioTheme.emerald : StudioTheme.inkMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func statusDotColor(_ state: VoiceDaemonState) -> Color {
        switch state {
        case .ready: return StudioTheme.emerald
        case .starting: return StudioTheme.brassBright
        case .idle: return StudioTheme.inkMuted
        case .fallbackSystemVoice: return StudioTheme.sky
        }
    }

    private func statusDescription(_ state: VoiceDaemonState) -> String {
        switch state {
        case .ready: return "Chatterbox Turbo Expressive Voice · Ready on Metal"
        case .starting(let msg): return msg
        case .idle: return "Chatterbox Turbo · Standby"
        case .fallbackSystemVoice(let msg): return msg
        }
    }
}
