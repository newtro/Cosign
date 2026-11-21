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
            case .cosigning, .conceding: return StudioTheme.emerald
            case .dissenting: return StudioTheme.crimson
            case .challenging: return StudioTheme.brassBright
            default: return accent
            }
        }()

        let text: String = {
            if let target = turn.targetPersonaName, !target.isEmpty,
               turn.stance == .challenging || turn.stance == .building || turn.stance == .conceding {
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
    @State private var showChairTrace: Bool = false

    var body: some View {
        let isSpeakingNow = model.voiceEngine.activeItem?.id == verdict.id && model.voiceEngine.isPlaying

        VStack(alignment: .leading, spacing: 18) {
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
                        Text("CO-SIGNED COUNCIL VERDICT")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(1.1)
                            .foregroundStyle(StudioTheme.brassBright)
                        Text("Synthesized by \(verdict.moderatorName)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                }

                Spacer()

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
                .font(.system(size: 21, weight: .bold, design: .serif))
                .foregroundStyle(StudioTheme.inkPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Main Recommendation Body (renders inline Markdown like **bold** & `code`)
            Group {
                if let md = try? AttributedString(markdown: verdict.recommendation, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    Text(md)
                } else {
                    Text(verdict.recommendation)
                }
            }
            .font(.system(size: 14.5))
            .lineSpacing(5)
            .foregroundStyle(StudioTheme.inkPrimary.opacity(0.94))
            .textSelection(.enabled)

            // Concrete Action Plan
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
                                .font(.system(size: 13.5, weight: .medium))
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

            // Key Trade-offs
            if !verdict.keyTradeoffs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("KEY TRADE-OFFS")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(StudioTheme.inkMuted)

                    ForEach(Array(verdict.keyTradeoffs.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 10))
                                .foregroundStyle(StudioTheme.inkMuted)
                                .padding(.top, 4)
                            Text(item)
                                .font(.system(size: 12.5))
                                .foregroundStyle(StudioTheme.inkSecondary)
                        }
                    }
                }
            }

            // Co-Signatory Seals
            if !verdict.cosignedNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CO-SIGNED BY")
                        .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .tracking(0.9)
                        .foregroundStyle(StudioTheme.emerald)

                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(verdict.cosignedNames, id: \.self) { signer in
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(StudioTheme.emerald)
                                Text(signer)
                                    .font(.system(size: 12.5, weight: .bold, design: .serif))
                                    .foregroundStyle(StudioTheme.inkPrimary)
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(StudioTheme.emerald.opacity(0.11))
                                    .overlay(Capsule().strokeBorder(StudioTheme.emerald.opacity(0.32), lineWidth: 1))
                            )
                        }
                    }
                }
            }

            // Minority Dissent Report (if any debater refused to fold!)
            if !verdict.dissents.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(StudioTheme.crimson)
                        Text("MINORITY DISSENT")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .tracking(0.9)
                            .foregroundStyle(StudioTheme.crimson)
                    }

                    ForEach(verdict.dissents) { dissent in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(dissent.personaName)
                                .font(.system(size: 12.5, weight: .bold, design: .serif))
                                .foregroundStyle(Color(hex: dissent.accentHex))
                            Text(dissent.coreObjection)
                                .font(.system(size: 13))
                                .foregroundStyle(StudioTheme.inkPrimary.opacity(0.9))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(StudioTheme.crimson.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(StudioTheme.crimson.opacity(0.30), lineWidth: 1)
                        )
                )
            }

            // Chair's Synthesis Trace Drawer
            if !verdict.moderatorThoughtProcess.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                            showChairTrace.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "scale.3d")
                                .font(.system(size: 11))
                                .foregroundStyle(StudioTheme.brassBright)
                            Text(showChairTrace ? "Hide Synthesis Reasoning" : "Inspect How \(verdict.moderatorName) Weighed the Debate")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(StudioTheme.inkSecondary)
                            Spacer()
                            Image(systemName: showChairTrace ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(StudioTheme.inkMuted)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.04)))
                    }
                    .buttonStyle(.plain)

                    if showChairTrace {
                        Text(verdict.moderatorThoughtProcess)
                            .font(.system(size: 12.5))
                            .lineSpacing(4)
                            .foregroundStyle(StudioTheme.inkSecondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StudioTheme.drawerBg))
                    }
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
