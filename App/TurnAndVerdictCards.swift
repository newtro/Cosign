import AppKit
import CosignCore
import CosignVoice
import SwiftUI

// MARK: - User Prompt Bubble

struct UserPromptCardView: View {
    let message: UserPromptMessage

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Text("YOU")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(StudioTheme.brassBright)
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.brassBright)
                }
                Text(message.text)
                    .font(.system(size: 14.5, weight: .regular))
                    .lineSpacing(4)
                    .foregroundStyle(StudioTheme.inkPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#1C2438"), Color(hex: "#151B2B")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(StudioTheme.brass.opacity(0.28), lineWidth: 1)
                    )
            }
        }
    }
}

// MARK: - Round Divider Ribbon

struct RoundBannerView: View {
    let banner: RoundBanner

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.14)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)

            VStack(spacing: 2) {
                Text(banner.title.uppercased())
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .tracking(1.1)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(StudioTheme.brassBright)
                Text(banner.subtitle)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(StudioTheme.inkMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(hex: "#111623"))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            )

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Clarifying Interview Card ("Council Intake")

struct InterviewExchangeCardView: View {
    @ObservedObject var model: AppModel
    let exchange: InterviewExchange

    @State private var draftQuestions: [InterviewQuestion]
    @State private var showModeratorReasoning: Bool = false

    init(model: AppModel, exchange: InterviewExchange) {
        self.model = model
        self.exchange = exchange
        self._draftQuestions = State(initialValue: exchange.questions)
    }

    var body: some View {
        let accent = Color(hex: exchange.moderatorAccentHex)

        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(alignment: .center, spacing: 11) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.20))
                        .frame(width: 36, height: 36)
                    Image(systemName: "questionmark.bubble.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text("\(exchange.moderatorName) · Council Intake")
                            .font(.system(size: 14.5, weight: .bold, design: .serif))
                            .foregroundStyle(StudioTheme.inkPrimary)
                        Text(exchange.isSubmitted ? (exchange.wasSkipped ? "SKIPPED" : "ANSWERED") : "QUICK INTERVIEW")
                            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                            .tracking(0.7)
                            .foregroundStyle(exchange.isSubmitted ? StudioTheme.emerald : accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((exchange.isSubmitted ? StudioTheme.emerald : accent).opacity(0.15)))
                    }
                    Text(ExpressiveTagFormatter.stripTags(exchange.spokenIntro))
                        .font(.system(size: 13.5))
                        .foregroundStyle(StudioTheme.inkSecondary)
                }
                Spacer()
            }

            // Question Cards
            VStack(spacing: 12) {
                ForEach($draftQuestions) { $q in
                    let qAccent = Color(hex: q.askedByAccentHex)
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(qAccent)
                                .frame(width: 7, height: 7)
                            Text("\(q.askedByName) asks")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(qAccent)
                            if !q.whyItMatters.isEmpty {
                                Text("· \(q.whyItMatters)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(StudioTheme.inkMuted)
                                    .lineLimit(1)
                            }
                        }

                        Text(q.question)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StudioTheme.inkPrimary)

                        if exchange.isSubmitted {
                            HStack(spacing: 6) {
                                Image(systemName: q.delegateToPanel ? "sparkles" : "checkmark.circle.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(q.delegateToPanel ? StudioTheme.sky : StudioTheme.emerald)
                                Text(q.delegateToPanel
                                     ? "Delegated — asked the panel to debate and decide this"
                                     : (q.answer.isEmpty ? "Left open to panel" : q.answer))
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                            }
                            .padding(.top, 2)
                        } else {
                            // Quick-pick chips + "Debate this for me"
                            FlowLayout(spacing: 7, lineSpacing: 7) {
                                ForEach(q.quickOptions, id: \.self) { opt in
                                    let chosen = !q.delegateToPanel && q.answer == opt
                                    Button {
                                        q.delegateToPanel = false
                                        q.answer = opt
                                    } label: {
                                        Text(opt)
                                    }
                                    .buttonStyle(StudioPillButtonStyle(tint: qAccent, active: chosen))
                                }

                                Button {
                                    q.delegateToPanel.toggle()
                                    if q.delegateToPanel {
                                        q.answer = ""
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 10))
                                        Text("Not sure — debate this for me")
                                    }
                                }
                                .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.sky, active: q.delegateToPanel))
                            }

                            if !q.delegateToPanel {
                                TextField("Or type / dictate your own answer…", text: $q.answer)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundStyle(StudioTheme.inkPrimary)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(StudioTheme.drawerBg)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                    )
                            }
                        }
                    }
                    .padding(13)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(qAccent.opacity(0.22), lineWidth: 1)
                            )
                    )
                }
            }

            // Actions or Collapsed Reasoning
            HStack(spacing: 10) {
                if !exchange.moderatorReasoning.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            showModeratorReasoning.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "brain")
                                .font(.system(size: 11))
                            Text(showModeratorReasoning ? "Hide Intake Reasoning" : "Why We Asked")
                            Image(systemName: showModeratorReasoning ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: accent, active: showModeratorReasoning))
                }

                Spacer()

                if !exchange.isSubmitted {
                    Button {
                        model.submitInterview(exchangeID: exchange.id, questions: draftQuestions, skipped: true)
                    } label: {
                        Text("Skip — Debate Now")
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.inkSecondary))

                    Button {
                        model.submitInterview(exchangeID: exchange.id, questions: draftQuestions, skipped: false)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Lock Answers & Launch Debate")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                    }
                    .buttonStyle(BrassPrimaryButtonStyle(accent: accent))
                }
            }

            if showModeratorReasoning && !exchange.moderatorReasoning.isEmpty {
                Text(exchange.moderatorReasoning)
                    .font(.system(size: 12.5))
                    .lineSpacing(3.5)
                    .foregroundStyle(StudioTheme.inkSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(StudioTheme.drawerBg)
                    )
            }
        }
        .padding(18)
        .studioCard(
            cornerRadius: 18,
            fill: StudioTheme.cardSurface,
            glowColor: exchange.isSubmitted ? nil : accent,
            glowIntensity: 0.22
        )
    }
}

// MARK: - Compact Two-Layer Debate Turn Card

struct DebateTurnCardView: View {
    @ObservedObject var model: AppModel
    let turn: DebateTurn

    @State private var isExpanded: Bool = false

    var body: some View {
        let accent = Color(hex: turn.accentHex)
        let isSpeakingNow = model.voiceEngine.activeItem?.id == turn.id && model.voiceEngine.isPlaying

        HStack(alignment: .top, spacing: 0) {
            // Left Persona Signature Spine
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.30)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3.5)
                .padding(.vertical, 12)
                .padding(.leading, 1)

            VStack(alignment: .leading, spacing: 11) {
                // Top Header Bar
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(0.18))
                            .frame(width: 32, height: 32)
                        Image(systemName: turn.avatarSymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                    }

                    VStack(alignment: .leading, spacing: 1.5) {
                        HStack(spacing: 7) {
                            Text(turn.personaName)
                                .font(.system(size: 14.5, weight: .bold, design: .serif))
                                .foregroundStyle(StudioTheme.inkPrimary)

                            Text(turn.personaTitle)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(StudioTheme.inkMuted)

                            stancePill(accent: accent)
                        }

                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(hex: turn.provider.brandHex))
                                .frame(width: 5.5, height: 5.5)
                            Text("\(turn.provider.shortName) · \(turn.modelLabel)")
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(StudioTheme.inkMuted)
                        }
                    }

                    Spacer()

                    if isSpeakingNow {
                        LiveEqualizerBars(level: model.voiceEngine.speakerLevel, color: accent, barCount: 5, maxHeight: 14)
                            .padding(.trailing, 4)
                    }

                    Button {
                        if isSpeakingNow {
                            model.voiceEngine.togglePlayPause()
                        } else {
                            model.replayTurn(turn)
                        }
                    } label: {
                        Image(systemName: isSpeakingNow ? "pause.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(isSpeakingNow ? accent : StudioTheme.inkSecondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("Speak this turn aloud")
                }

                // LAYER 1: Compact Spoken Take (2-4 punchy sentences + subtle stage cues)
                ExpressiveSpokenTextView(
                    rawText: turn.spokenTake,
                    accent: accent,
                    showCues: model.preferences.showVocalTagsInText
                )

                // Direct Peer Question Banner & CLI Tool Activity Pill
                if (turn.directQuestionForPeer?.isEmpty == false) || (turn.toolsActivitySummary?.isEmpty == false) {
                    FlowLayout(spacing: 8, lineSpacing: 6) {
                        if let tools = turn.toolsActivitySummary, !tools.isEmpty {
                            HStack(spacing: 5) {
                                Image(systemName: turn.stance == .executing ? "hammer.fill" : "terminal.fill")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(StudioTheme.emerald)
                                Text(tools)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(StudioTheme.emerald.opacity(0.10)))
                            .overlay(Capsule().strokeBorder(StudioTheme.emerald.opacity(0.24), lineWidth: 0.8))
                        }

                        if let peerQ = turn.directQuestionForPeer, !peerQ.isEmpty {
                            HStack(spacing: 5) {
                                Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(StudioTheme.brassBright)
                                Text("To \(turn.targetPersonaName ?? "Panel"): \"\(peerQ)\"")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(StudioTheme.brassBright)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(StudioTheme.brass.opacity(0.12)))
                        }
                    }
                }

                // LAYER 2: 1-Click Collapsible Thought Process & Key Takeaways Drawer
                if !turn.thoughtProcess.isEmpty || !turn.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(accent)

                                Text(isExpanded ? "Hide Thought Process" : "Thought Process")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(StudioTheme.inkSecondary)

                                if !turn.keyPoints.isEmpty {
                                    Text("· \(turn.keyPoints.count) key \(turn.keyPoints.count == 1 ? "point" : "points")")
                                        .font(.system(size: 11))
                                        .foregroundStyle(StudioTheme.inkMuted)
                                }

                                if turn.durationMs > 0 {
                                    Text(String(format: "· %.1fs", Double(turn.durationMs) / 1000.0))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(StudioTheme.inkMuted.opacity(0.8))
                                }

                                Spacer()

                                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(StudioTheme.inkMuted)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6.5)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.white.opacity(isExpanded ? 0.06 : 0.03))
                            )
                        }
                        .buttonStyle(.plain)

                        if isExpanded {
                            VStack(alignment: .leading, spacing: 10) {
                                if !turn.keyPoints.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        ForEach(Array(turn.keyPoints.enumerated()), id: \.offset) { _, pt in
                                            HStack(alignment: .top, spacing: 7) {
                                                Image(systemName: "diamond.fill")
                                                    .font(.system(size: 6.5))
                                                    .foregroundStyle(accent)
                                                    .padding(.top, 5)
                                                Text(pt)
                                                    .font(.system(size: 12.5, weight: .medium))
                                                    .foregroundStyle(StudioTheme.inkPrimary.opacity(0.92))
                                                    .textSelection(.enabled)
                                            }
                                        }
                                    }
                                }

                                if !turn.keyPoints.isEmpty && !turn.thoughtProcess.isEmpty {
                                    Divider().overlay(Color.white.opacity(0.06))
                                }

                                if !turn.thoughtProcess.isEmpty {
                                    Text(turn.thoughtProcess)
                                        .font(.system(size: 12.5))
                                        .lineSpacing(4)
                                        .foregroundStyle(StudioTheme.inkSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(StudioTheme.drawerBg)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                                    )
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .studioCard(
            cornerRadius: 16,
            fill: StudioTheme.cardSurface,
            glowColor: isSpeakingNow ? accent : nil,
            glowIntensity: 0.30
        )
    }

    @ViewBuilder
    private func stancePill(accent: Color) -> some View {
        let pillColor: Color = {
            switch turn.stance {
            case .cosigning, .conceding, .executing: return StudioTheme.emerald
            case .dissenting: return StudioTheme.crimson
            case .challenging, .moderating: return StudioTheme.brassBright
            case .replying: return StudioTheme.sky
            default: return accent
            }
        }()

        let text: String = {
            if let target = turn.targetPersonaName, !target.isEmpty,
               turn.stance == .challenging || turn.stance == .replying || turn.stance == .building || turn.stance == .conceding {
                return "\(turn.stance.label) \(target)"
            }
            return turn.stance.label
        }()

        HStack(spacing: 4) {
            Image(systemName: turn.stance.symbolName)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(pillColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(pillColor.opacity(0.14)))
        .overlay(Capsule().strokeBorder(pillColor.opacity(0.28), lineWidth: 0.8))
    }
}

// MARK: - Expressive Spoken Text Renderer (Styles [chuckle] / [sigh] cleanly)

struct ExpressiveSpokenTextView: View {
    let rawText: String
    let accent: Color
    let showCues: Bool

    var body: some View {
        if !showCues {
            Text(ExpressiveTagFormatter.stripTags(rawText))
                .font(.system(size: 15, weight: .regular))
                .lineSpacing(5)
                .foregroundStyle(StudioTheme.inkPrimary)
                .textSelection(.enabled)
        } else {
            let segments = ExpressiveTagFormatter.parseSegments(rawText)
            segments.reduce(Text("")) { partial, seg in
                switch seg {
                case .words(let str):
                    return partial + Text(str)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(StudioTheme.inkPrimary)
                case .cue(let cueLabel):
                    return partial + Text(" (\(cueLabel)) ")
                        .font(.system(size: 13, weight: .medium, design: .serif))
                        .italic()
                        .foregroundColor(accent.opacity(0.88))
                }
            }
            .lineSpacing(5)
            .textSelection(.enabled)
        }
    }
}

// MARK: - The Co-Signed Verdict Charter Card

struct CosignVerdictCardView: View {
    @ObservedObject var model: AppModel
    let verdict: CosignVerdict

    @State private var copied: Bool = false
    @State private var showFullBrief: Bool = false
    @State private var showDissents: Bool = false
    @State private var showChairTrace: Bool = false

    var body: some View {
        let isSpeakingNow = model.voiceEngine.activeItem?.id == verdict.id && model.voiceEngine.isPlaying

        VStack(alignment: .leading, spacing: 16) {
            // Top Emblem & Actions
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [StudioTheme.brassBright, StudioTheme.brass],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 34, height: 34)
                            .shadow(color: StudioTheme.brass.opacity(0.45), radius: 8)
                        Image(systemName: "signature")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(hex: "#090B10"))
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("CO-SIGNED COUNCIL ANSWER")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(StudioTheme.brassBright)
                        Text("Synthesized by \(verdict.moderatorName)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                }

                Spacer()

                if verdict.wasExecuted == true {
                    Button {
                        model.openBuildLaunchSheet(for: verdict)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 10.5))
                            Text("Built & Verified")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: true))
                    .disabled(model.currentSession?.stage.isBusy == true)
                    .help("Project built and verified — click to run another build pass or target a different folder")
                } else {
                    Button {
                        model.openBuildLaunchSheet(for: verdict)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 10.5))
                            Text("Build This Plan…")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.brassBright, active: true))
                    .disabled(model.currentSession?.stage.isBusy == true)
                    .help("Select a local folder and have the council build, test, and verify this plan together")
                }

                Button {
                    model.openHandoffSheet(for: verdict)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 10.5))
                        Text("Handoff Prompt")
                    }
                }
                .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: true))
                .help("Build and copy a coding-harness handoff prompt with all recommendations while keeping this conversation live")

                Button {
                    model.replayVerdict(verdict)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isSpeakingNow ? "waveform" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                        Text("Speak")
                    }
                }
                .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.brassBright, active: isSpeakingNow))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(verdict.markdownFormatted, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        copied = false
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copied ? "Copied" : "Copy Markdown")
                    }
                }
                .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: copied))
            }

            // Editorial Headline
            Text(verdict.headline)
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(StudioTheme.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Front-and-Center Bottom-Line Answer (Compact & Unmistakable!)
            VStack(alignment: .leading, spacing: 6) {
                Text("THE BOTTOM LINE")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(StudioTheme.emerald)

                ExpressiveSpokenTextView(
                    rawText: verdict.spokenVerdict,
                    accent: StudioTheme.brassBright,
                    showCues: model.preferences.showVocalTagsInText
                )
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(StudioTheme.emerald.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(StudioTheme.emerald.opacity(0.26), lineWidth: 1)
                    )
            )

            // Built & Verified Summary Box (when Build Mode / Build This Plan completed)
            if let report = verdict.buildReport {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: report.verificationPassed ? "checkmark.shield.fill" : "wrench.and.screwdriver.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(StudioTheme.emerald)
                        Text(report.verificationPassed ? "BUILT & QA VERIFIED BY \(report.verifierName.uppercased())" : "BUILD COMPLETED · REVIEW NOTES")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(StudioTheme.emerald)
                        Spacer()
                        Button {
                            model.openFolderInFinder(report.buildFolder)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 10))
                                Text("Open in Finder")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: true))
                    }

                    Text(report.buildFolder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(StudioTheme.inkSecondary)
                        .textSelection(.enabled)

                    if !report.verificationSummary.isEmpty {
                        Text(report.verificationSummary)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(StudioTheme.inkPrimary)
                            .textSelection(.enabled)
                    }

                    if !report.filesSummary.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(report.filesSummary.prefix(6), id: \.self) { fileLine in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "doc.badge.gearshape.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(StudioTheme.brassBright)
                                        .padding(.top, 3)
                                    Text(fileLine)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(StudioTheme.inkSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }

                    if !report.howToRun.isEmpty {
                        HStack(spacing: 8) {
                            Text("RUN:")
                                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                .foregroundStyle(StudioTheme.brassBright)
                            Text(report.howToRun)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(StudioTheme.inkPrimary)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(report.howToRun, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copy run command")
                        }
                        .padding(9)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.28)))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(StudioTheme.sky.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(StudioTheme.sky.opacity(0.28), lineWidth: 1)
                        )
                )
            }

            // Compact Action Plan
            if !verdict.actionSteps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("RECOMMENDED NEXT STEPS")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(StudioTheme.brassBright)

                    ForEach(Array(verdict.actionSteps.enumerated()), id: \.offset) { idx, step in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(StudioTheme.brassBright)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(StudioTheme.brass.opacity(0.16)))
                            Text(step)
                                .font(.system(size: 13, weight: .medium))
                                .lineSpacing(2.5)
                                .foregroundStyle(StudioTheme.inkPrimary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                )
            }

            // Co-Signatory Seals Row
            if !verdict.cosignedNames.isEmpty {
                HStack(spacing: 8) {
                    Text("CO-SIGNED BY:")
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(StudioTheme.emerald)

                    FlowLayout(spacing: 7, lineSpacing: 7) {
                        ForEach(verdict.cosignedNames, id: \.self) { signer in
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(StudioTheme.emerald)
                                Text(signer)
                                    .font(.system(size: 12, weight: .bold, design: .serif))
                                    .foregroundStyle(StudioTheme.inkPrimary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(StudioTheme.emerald.opacity(0.11))
                                    .overlay(Capsule().strokeBorder(StudioTheme.emerald.opacity(0.32), lineWidth: 1))
                            )
                        }
                    }
                }
            }

            // Progressive-Disclosure Drawers (Full Written Brief, Minority Dissent, & Synthesis Notes)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if !verdict.recommendation.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                showFullBrief.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 10.5))
                                Text(showFullBrief ? "Hide Full Brief" : "Full Written Brief & Trade-offs")
                                Image(systemName: showFullBrief ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.brassBright, active: showFullBrief))
                    }

                    if !verdict.dissents.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                showDissents.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10.5))
                                Text("\(verdict.dissents.count) Minority Caveat (\(verdict.dissents.map(\.personaName).joined(separator: ", ")))")
                                Image(systemName: showDissents ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.crimson, active: showDissents))
                    }

                    if !verdict.moderatorThoughtProcess.isEmpty {
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                showChairTrace.toggle()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "scale.3d")
                                    .font(.system(size: 10.5))
                                Text("Synthesis Notes")
                                Image(systemName: showChairTrace ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.sky, active: showChairTrace))
                    }
                }

                if showFullBrief {
                    VStack(alignment: .leading, spacing: 12) {
                        Group {
                            if let md = try? AttributedString(markdown: verdict.recommendation, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                                Text(md)
                            } else {
                                Text(verdict.recommendation)
                            }
                        }
                        .font(.system(size: 13.5))
                        .lineSpacing(4.5)
                        .foregroundStyle(StudioTheme.inkPrimary.opacity(0.93))
                        .textSelection(.enabled)

                        if !verdict.keyTradeoffs.isEmpty {
                            Divider().overlay(Color.white.opacity(0.07))
                            Text("KEY TRADE-OFFS")
                                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                                .tracking(0.8)
                                .foregroundStyle(StudioTheme.inkMuted)
                            ForEach(Array(verdict.keyTradeoffs.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 7) {
                                    Image(systemName: "arrow.left.and.right")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(StudioTheme.inkMuted)
                                        .padding(.top, 4)
                                    Text(item)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(StudioTheme.inkSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioTheme.drawerBg))
                }

                if showDissents {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(verdict.dissents) { dissent in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(dissent.personaName)'s Caveat / Dissent")
                                    .font(.system(size: 12.5, weight: .bold, design: .serif))
                                    .foregroundStyle(Color(hex: dissent.accentHex))
                                Text(dissent.coreObjection)
                                    .font(.system(size: 12.5))
                                    .lineSpacing(3.5)
                                    .foregroundStyle(StudioTheme.inkPrimary.opacity(0.9))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(StudioTheme.crimson.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioTheme.crimson.opacity(0.28), lineWidth: 1))
                    )
                }

                if showChairTrace {
                    Text(verdict.moderatorThoughtProcess)
                        .font(.system(size: 12.5))
                        .lineSpacing(4)
                        .foregroundStyle(StudioTheme.inkSecondary)
                        .textSelection(.enabled)
                        .padding(13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StudioTheme.drawerBg))
                }
            }
        }
        .padding(22)
        .studioCard(
            cornerRadius: 20,
            fill: Color(hex: "#141926"),
            glowColor: StudioTheme.brass,
            glowIntensity: isSpeakingNow ? 0.36 : 0.18
        )
    }
}

// MARK: - Coding Harness Handoff Prompt Sheet

struct HandoffPromptSheet: View {
    @ObservedObject var model: AppModel
    let session: DebateSession
    let verdict: CosignVerdict
    @Environment(\.dismiss) private var dismiss

    @State private var selectedSteps: Set<Int> = []
    @State private var includeFileAssignments: Bool = true
    @State private var includeGuardrails: Bool = true
    @State private var steeringNote: String = ""
    @State private var promptText: String = ""
    @State private var isTailoringWithAI: Bool = false
    @State private var copiedToast: Bool = false
    @State private var tailorError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StudioTheme.emerald.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StudioTheme.emerald)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Coding Harness Handoff Prompt")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(StudioTheme.inkPrimary)
                    Text("Ready to paste into Claude Code, Codex, or Antigravity — your council session stays open for follow-ups.")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.inkSecondary)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(StudioPillButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(StudioTheme.sidebarBg)

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 0) {
                // Left Controls: Scope & Optional AI Tailoring
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !verdict.actionSteps.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("INCLUDED STEPS")
                                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                                        .tracking(0.9)
                                        .foregroundStyle(StudioTheme.brassBright)
                                    Spacer()
                                    Button(selectedSteps.count == verdict.actionSteps.count ? "None" : "All") {
                                        if selectedSteps.count == verdict.actionSteps.count {
                                            selectedSteps.removeAll()
                                        } else {
                                            selectedSteps = Set(verdict.actionSteps.indices)
                                        }
                                        rebuildStructuredPrompt()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StudioTheme.sky)
                                }

                                ForEach(Array(verdict.actionSteps.enumerated()), id: \.offset) { idx, step in
                                    let on = selectedSteps.contains(idx)
                                    Button {
                                        if on { selectedSteps.remove(idx) } else { selectedSteps.insert(idx) }
                                        rebuildStructuredPrompt()
                                    } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: on ? "checkmark.square.fill" : "square")
                                                .foregroundStyle(on ? StudioTheme.emerald : StudioTheme.inkMuted)
                                                .padding(.top, 1)
                                            Text("\(idx + 1). \(step)")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(on ? StudioTheme.inkPrimary : StudioTheme.inkMuted)
                                                .lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(7)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(on ? 0.05 : 0.02)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Divider().overlay(Color.white.opacity(0.07))

                        VStack(alignment: .leading, spacing: 9) {
                            Text("SECTIONS")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .tracking(0.9)
                                .foregroundStyle(StudioTheme.brassBright)

                            Toggle("Include file-level workstreams", isOn: $includeFileAssignments)
                                .font(.system(size: 12))
                                .onChange(of: includeFileAssignments) { _, _ in rebuildStructuredPrompt() }

                            Toggle("Include trade-offs & dissent guardrails", isOn: $includeGuardrails)
                                .font(.system(size: 12))
                                .onChange(of: includeGuardrails) { _, _ in rebuildStructuredPrompt() }
                        }

                        Divider().overlay(Color.white.opacity(0.07))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("OPTIONAL FOCUS / EXTRA NOTE")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .tracking(0.9)
                                .foregroundStyle(StudioTheme.brassBright)

                            TextField("e.g. Focus only on Phase 1 C# UI changes…", text: $steeringNote, axis: .vertical)
                                .lineLimit(2...4)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(StudioTheme.inkPrimary)
                                .padding(9)
                                .background(RoundedRectangle(cornerRadius: 8).fill(StudioTheme.drawerBg))
                                .onChange(of: steeringNote) { _, _ in rebuildStructuredPrompt() }

                            Button {
                                runAITailor()
                            } label: {
                                HStack(spacing: 6) {
                                    if isTailoringWithAI {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 11))
                                    }
                                    Text(isTailoringWithAI ? "Synthesizing with \(verdict.moderatorName)…" : "Tailor Prompt with \(verdict.moderatorName)")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.sky, active: true))
                            .disabled(isTailoringWithAI)

                            if let tailorError {
                                Text(tailorError)
                                    .font(.system(size: 11))
                                    .foregroundStyle(StudioTheme.crimson)
                            }
                        }
                    }
                    .padding(16)
                }
                .frame(width: 315)
                .background(StudioTheme.sidebarBg.opacity(0.75))

                Divider().overlay(Color.white.opacity(0.08))

                // Right Editable Markdown Preview
                VStack(alignment: .leading, spacing: 0) {
                    TextEditor(text: $promptText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(3.5)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(StudioTheme.inkPrimary)
                        .padding(16)
                        .background(StudioTheme.drawerBg)

                    Divider().overlay(Color.white.opacity(0.08))

                    HStack {
                        Button("Reset to Full Structured Handoff") {
                            rebuildStructuredPrompt()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(StudioTheme.inkMuted)

                        Spacer()

                        if copiedToast {
                            Label("Copied to Clipboard!", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(StudioTheme.emerald)
                                .padding(.trailing, 6)
                        }

                        Button {
                            copyToClipboard()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 11.5))
                                Text("Copy Handoff Prompt")
                            }
                        }
                        .buttonStyle(BrassPrimaryButtonStyle())
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 13)
                    .background(StudioTheme.sidebarBg)
                }
            }
        }
        .frame(width: 940, height: 660)
        .background(StudioTheme.canvasTop)
        .preferredColorScheme(.dark)
        .onAppear {
            selectedSteps = Set(verdict.actionSteps.indices)
            rebuildStructuredPrompt()
        }
    }

    private func rebuildStructuredPrompt() {
        promptText = HandoffPromptBuilder.build(
            session: session,
            verdict: verdict,
            selectedStepIndices: selectedSteps,
            includeFileAssignments: includeFileAssignments,
            includeGuardrails: includeGuardrails,
            extraUserNote: steeringNote
        )
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(promptText, forType: .string)
        copiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            copiedToast = false
        }
    }

    private func runAITailor() {
        isTailoringWithAI = true
        tailorError = nil
        let currentDraft = promptText
        let note = steeringNote
        Task {
            do {
                let refined = try await model.generateTailoredHandoff(baseHandoff: currentDraft, customInstruction: note)
                if !refined.isEmpty {
                    promptText = refined
                }
            } catch {
                tailorError = error.localizedDescription
            }
            isTailoringWithAI = false
        }
    }
}

// MARK: - Build This Plan Launch Sheet (Select or Create Local Target Folder)

struct BuildLaunchSheet: View {
    @ObservedObject var model: AppModel
    let session: DebateSession
    let verdict: CosignVerdict
    @Environment(\.dismiss) private var dismiss

    @State private var targetFolder: String = ""
    @State private var extraNote: String = ""

    private var isGenericParentRoot: Bool {
        WorkspaceResolver.isParentReposContainer(targetFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(StudioTheme.brass.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StudioTheme.brassBright)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Build This Plan with the Council")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(StudioTheme.inkPrimary)
                    Text("Chair-coordinated sequential workstreams → Adversarial QA & Test Verification → Auto-Fix")
                        .font(.system(size: 12))
                        .foregroundStyle(StudioTheme.inkSecondary)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(StudioPillButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(StudioTheme.sidebarBg)

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PLAN TO BUILD")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(StudioTheme.brassBright)
                    Text(verdict.headline)
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(StudioTheme.inkPrimary)
                }

                // Target Local Folder Picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("TARGET LOCAL PROJECT FOLDER")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(StudioTheme.emerald)

                    HStack(spacing: 10) {
                        Image(systemName: isGenericParentRoot ? "folder.badge.questionmark" : "folder.fill")
                            .foregroundStyle(isGenericParentRoot ? StudioTheme.brassBright : StudioTheme.emerald)
                        Text(targetFolder.isEmpty ? "No folder selected" : targetFolder)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(StudioTheme.inkPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Select or Create Folder…") {
                            if let chosen = model.chooseWorkspaceFolderWithPanel(forBuild: true) {
                                targetFolder = chosen
                            }
                        }
                        .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: true))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(StudioTheme.drawerBg))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(isGenericParentRoot ? StudioTheme.brassBright.opacity(0.5) : StudioTheme.emerald.opacity(0.32), lineWidth: 1)
                    )

                    if isGenericParentRoot {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 11))
                            Text("This points to your top-level repos directory. Click 'Select or Create Folder…' (and 'New Folder' if starting fresh) to target a dedicated project directory.")
                                .font(.system(size: 11.5))
                        }
                        .foregroundStyle(StudioTheme.brassBright)
                    }
                }

                // Optional Extra Build Note
                VStack(alignment: .leading, spacing: 6) {
                    Text("OPTIONAL BUILD SCOPE / EXTRA INSTRUCTIONS")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(StudioTheme.inkMuted)

                    TextField("e.g. Build Phase 1 MVP first, or use Swift 6 + SwiftUI…", text: $extraNote, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(StudioTheme.inkPrimary)
                        .padding(11)
                        .background(RoundedRectangle(cornerRadius: 10).fill(StudioTheme.drawerBg))
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer()
                    Button {
                        var chosen = targetFolder
                        if isGenericParentRoot {
                            guard let picked = model.chooseWorkspaceFolderWithPanel(forBuild: true) else {
                                return
                            }
                            chosen = picked
                        }
                        let note = extraNote
                        dismiss()
                        model.startBuildFromVerdict(verdict, targetFolder: chosen, extraNote: note)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "hammer.fill")
                                .font(.system(size: 11.5))
                            Text(isGenericParentRoot ? "Choose Folder & Start Building →" : "Start Multi-Agent Build →")
                        }
                    }
                    .buttonStyle(BrassPrimaryButtonStyle())
                }
            }
            .padding(22)
        }
        .frame(width: 640, height: 420)
        .background(StudioTheme.canvasTop)
        .preferredColorScheme(.dark)
        .onAppear {
            targetFolder = session.workspacePath ?? WorkspaceResolver.defaultWorkspacePath()
        }
    }
}
