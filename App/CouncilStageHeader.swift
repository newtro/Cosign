import CosignCore
import CosignVoice
import SwiftUI

struct CouncilStageHeader: View {
    @ObservedObject var model: AppModel
    let session: DebateSession

    var body: some View {
        let moderator = model.activeModerator(for: session)
        let debaters = model.activeDebaters(for: session)

        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                // Session Title & Stage Pill
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(session.title)
                            .font(.system(size: 18, weight: .bold, design: .serif))
                            .foregroundStyle(StudioTheme.inkPrimary)
                            .lineLimit(1)

                        stageBadge(for: session.stage)
                    }

                    if !model.liveStatusText.isEmpty && session.stage.isBusy {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(StudioTheme.brassBright)
                            Text(model.liveStatusText)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(StudioTheme.brassBright)
                                .lineLimit(1)
                        }
                        .transition(.opacity)
                    } else {
                        Text("\(debaters.count) Debaters + 1 Chair · Subscription CLIs")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                }

                Spacer(minLength: 12)

                // Workspace Selector, Lineup Switcher & Studio Controls
                HStack(spacing: 8) {
                    let wsPath = session.workspacePath ?? WorkspaceResolver.defaultWorkspacePath()
                    let wsName = URL(fileURLWithPath: wsPath).lastPathComponent
                    Menu {
                        Button("Choose Folder or Repo…") {
                            model.chooseWorkspaceFolderWithPanel()
                        }
                        Divider()
                        ForEach(model.quickSwitchRepoPaths, id: \.self) { candidate in
                            Button {
                                model.setCurrentSessionWorkspace(candidate)
                            } label: {
                                HStack {
                                    Text(candidate)
                                    if candidate == wsPath {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(StudioTheme.emerald)
                            Text(wsName.isEmpty ? "Workspace" : wsName)
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(StudioTheme.inkSecondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(StudioTheme.inkMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.045)))
                        .overlay(Capsule().strokeBorder(StudioTheme.emerald.opacity(0.28), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Active workspace folder for CLI repo/file tools: \(wsPath)")

                    Button {
                        model.showingLineupPopover.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.3.sequence.fill")
                                .font(.system(size: 11))
                            Text("Lineup")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.brass, active: model.showingLineupPopover))
                    .disabled(session.stage.isBusy)
                    .popover(isPresented: $model.showingLineupPopover, arrowEdge: .bottom) {
                        LineupQuickPopover(model: model, session: session)
                    }

                    Button {
                        model.openStudio()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 11))
                            Text("Persona Studio")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.sky))
                }
            }

            // Seated Council Medallions Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    CouncilSeatCard(
                        persona: moderator,
                        modelLabel: model.displayLabel(for: moderator.provider, modelID: moderator.modelID),
                        isModerator: true,
                        isThinking: model.activeThinkerIDs.contains(moderator.id),
                        isSpeaking: model.voiceEngine.activeItem?.persona.id == moderator.id && model.voiceEngine.isPlaying,
                        speakerLevel: model.voiceEngine.speakerLevel,
                        latestStance: latestStance(for: moderator.id, in: session)
                    ) {
                        model.openStudio(for: moderator.id)
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1, height: 40)
                        .padding(.horizontal, 2)

                    ForEach(debaters) { debater in
                        CouncilSeatCard(
                            persona: debater,
                            modelLabel: model.displayLabel(for: debater.provider, modelID: debater.modelID),
                            isModerator: false,
                            isThinking: model.activeThinkerIDs.contains(debater.id),
                            isSpeaking: model.voiceEngine.activeItem?.persona.id == debater.id && model.voiceEngine.isPlaying,
                            speakerLevel: model.voiceEngine.speakerLevel,
                            latestStance: latestStance(for: debater.id, in: session)
                        ) {
                            model.openStudio(for: debater.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
        .background(
            ZStack {
                Color(hex: "#0C1019").opacity(0.94)
                LinearGradient(
                    colors: [StudioTheme.brass.opacity(0.05), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.09), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func stageBadge(for stage: SessionStage) -> some View {
        let (label, color): (String, Color) = {
            switch stage {
            case .idle: return ("Ready", StudioTheme.inkMuted)
            case .scanningIntake: return ("Intake Scan", StudioTheme.brass)
            case .awaitingInterviewAnswers: return ("Awaiting Your Input", StudioTheme.brassBright)
            case .debating: return ("Live Debate", StudioTheme.sky)
            case .synthesizingVerdict: return ("Drafting Verdict", StudioTheme.brassBright)
            case .executingPlan: return ("Coordinating Edits", StudioTheme.emerald)
            case .completed: return ("Co-Signed", StudioTheme.emerald)
            case .cancelled: return ("Paused", StudioTheme.inkMuted)
            case .error: return ("Attention Needed", StudioTheme.crimson)
            }
        }()

        Text(label.uppercased())
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .tracking(0.7)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().strokeBorder(color.opacity(0.32), lineWidth: 0.8))
    }

    private func latestStance(for personaID: UUID, in session: DebateSession) -> StanceKind? {
        for entry in session.entries.reversed() {
            if case .verdict(let v) = entry {
                if v.moderatorID == personaID { return .synthesizing }
                if v.dissents.contains(where: { $0.personaID == personaID }) { return .dissenting }
                if v.cosignedPersonaIDs.contains(personaID) { return .cosigning }
            }
            if case .turn(let t) = entry, t.personaID == personaID {
                return t.stance
            }
        }
        return nil
    }
}

// MARK: - Individual Seated Persona Medallion

struct CouncilSeatCard: View {
    let persona: Persona
    let modelLabel: String
    let isModerator: Bool
    let isThinking: Bool
    let isSpeaking: Bool
    let speakerLevel: CGFloat
    let latestStance: StanceKind?
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        let accent = Color(hex: persona.accentHex)

        Button(action: onTap) {
            HStack(spacing: 10) {
                // Luminous Avatar Medallion
                ZStack {
                    if isSpeaking {
                        Circle()
                            .fill(accent.opacity(0.24))
                            .frame(width: 38 + speakerLevel * 10, height: 38 + speakerLevel * 10)
                            .blur(radius: 4)
                    }

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.32), accent.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 36, height: 36)
                        .overlay(
                            Circle()
                                .strokeBorder(accent.opacity(isSpeaking ? 0.95 : 0.45), lineWidth: isSpeaking ? 1.8 : 1.1)
                        )

                    Image(systemName: persona.avatarSymbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)

                    if isThinking {
                        OrbitingThinkingRing(color: accent, size: 41)
                    }
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2.5) {
                    HStack(spacing: 5) {
                        Text(persona.name)
                            .font(.system(size: 13, weight: .bold, design: .serif))
                            .foregroundStyle(StudioTheme.inkPrimary)

                        if isModerator {
                            Text("CHAIR")
                                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                .tracking(0.6)
                                .foregroundStyle(StudioTheme.brassBright)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(StudioTheme.brass.opacity(0.18)))
                        } else if let stance = latestStance {
                            Image(systemName: stance.symbolName)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(stanceColor(stance, fallback: accent))
                        }

                        if isSpeaking {
                            LiveEqualizerBars(level: speakerLevel, color: accent, barCount: 4, maxHeight: 12)
                                .padding(.leading, 2)
                        }
                    }

                    Text(persona.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(StudioTheme.inkSecondary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: persona.provider.brandHex))
                            .frame(width: 5.5, height: 5.5)
                        Text("\(persona.provider.shortName) · \(shortModelName(modelLabel))")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(StudioTheme.inkMuted)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(isSpeaking ? accent.opacity(0.11) : (hovering ? StudioTheme.cardElevated : StudioTheme.cardSurface.opacity(0.85)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        isSpeaking ? accent.opacity(0.55) : (hovering ? Color.white.opacity(0.16) : Color.white.opacity(0.07)),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to customize \(persona.name)'s model, personality, or voice")
    }

    private func shortModelName(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "Claude ", with: "")
            .replacingOccurrences(of: "Gemini ", with: "")
    }

    private func stanceColor(_ stance: StanceKind, fallback: Color) -> Color {
        switch stance {
        case .cosigning, .conceding: return StudioTheme.emerald
        case .dissenting: return StudioTheme.crimson
        case .challenging: return StudioTheme.brassBright
        default: return fallback
        }
    }
}

// MARK: - Quick Lineup Switcher Popover

struct LineupQuickPopover: View {
    @ObservedObject var model: AppModel
    let session: DebateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Council Presets")
                .font(.system(size: 13, weight: .bold, design: .serif))
                .foregroundStyle(StudioTheme.inkPrimary)

            ForEach(model.presets) { preset in
                let isSelected = session.moderatorID == preset.moderatorID && session.debaterIDs == preset.debaterIDs
                Button {
                    model.applyPresetToCurrentSession(preset)
                    model.showingLineupPopover = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: preset.iconSymbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? StudioTheme.brassBright : StudioTheme.inkSecondary)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(StudioTheme.inkPrimary)
                            Text(preset.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(StudioTheme.inkMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(StudioTheme.emerald)
                        }
                    }
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? StudioTheme.brass.opacity(0.12) : Color.white.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(Color.white.opacity(0.08))

            Text("Toggle Seated Debaters")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(StudioTheme.inkSecondary)

            let allDebaters = model.personas.filter { $0.role == .debater }
            ForEach(allDebaters) { debater in
                let seated = session.debaterIDs.contains(debater.id)
                Button {
                    var next = session.debaterIDs
                    if seated {
                        if next.count > 2 {
                            next.removeAll { $0 == debater.id }
                        }
                    } else {
                        next.append(debater.id)
                    }
                    model.updateCurrentSessionLineup(moderatorID: session.moderatorID, debaterIDs: next)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: seated ? "checkmark.square.fill" : "square")
                            .foregroundStyle(seated ? Color(hex: debater.accentHex) : StudioTheme.inkMuted)
                        Text(debater.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StudioTheme.inkPrimary)
                        Text("· \(debater.title)")
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.inkMuted)
                        Spacer()
                        Text(debater.provider.shortName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(hex: debater.provider.brandHex))
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(StudioTheme.cardSurface)
    }
}
