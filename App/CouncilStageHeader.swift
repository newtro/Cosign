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
                    } else if session.stage == .completed && !session.entries.isEmpty {
                        let voiceBusy = model.voiceEngine.isPlaying || !model.voiceEngine.queuedItems.isEmpty
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StudioTheme.emerald)
                            Text(voiceBusy
                                 ? "All AI steps finished · Voicing remaining audio"
                                 : "Finished · All council steps complete")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(StudioTheme.emerald)
                                .lineLimit(1)
                        }
                    } else {
                        Text("\(session.activeMode.displayName) · \(debaters.count) Specialists + 1 Chair · Subscription CLIs")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                }

                Spacer(minLength: 12)

                // Workspace / Build Folder Selector, Lineup Switcher & Studio Controls
                HStack(spacing: 8) {
                    let wsPath = session.workspacePath ?? WorkspaceResolver.defaultWorkspacePath()
                    let wsName = URL(fileURLWithPath: wsPath).lastPathComponent
                    let needsBuildFolder = session.activeMode == .build
                        && session.hasExplicitBuildFolder != true
                        && WorkspaceResolver.isParentReposContainer(wsPath)
                    let folderTint = needsBuildFolder ? StudioTheme.brassBright : StudioTheme.emerald
                    Menu {
                        Button("Select or Create Project Folder…") {
                            model.chooseWorkspaceFolderWithPanel(forBuild: session.activeMode == .build)
                        }
                        Button("Reveal Current Folder in Finder") {
                            model.openFolderInFinder(wsPath)
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
                            Image(systemName: needsBuildFolder ? "folder.badge.plus" : "folder.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(folderTint)
                            Text(needsBuildFolder ? "Select Build Folder…" : (wsName.isEmpty ? "Workspace" : wsName))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(needsBuildFolder ? StudioTheme.brassBright : StudioTheme.inkSecondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(StudioTheme.inkMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(folderTint.opacity(needsBuildFolder ? 0.12 : 0.045)))
                        .overlay(Capsule().strokeBorder(folderTint.opacity(needsBuildFolder ? 0.45 : 0.28), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Active target folder for CLI inspection & Build Mode: \(wsPath)")

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

            // Seated Council Medallions Strip (Expands fluidly across wide monitors; scrolls cleanly on narrow splits)
            ViewThatFits(in: .horizontal) {
                seatsStrip(moderator: moderator, debaters: debaters, expandToFill: true)

                ScrollView(.horizontal, showsIndicators: false) {
                    seatsStrip(moderator: moderator, debaters: debaters, expandToFill: false)
                }
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
            case .idle: return (session.activeMode == .build ? "Ready to Build" : "Ready", StudioTheme.inkMuted)
            case .scanningIntake: return ("Intake Scan", StudioTheme.brass)
            case .awaitingInterviewAnswers: return ("Awaiting Your Input", StudioTheme.brassBright)
            case .debating: return (session.activeMode == .build ? "Architecture Huddle" : "Live Debate", StudioTheme.sky)
            case .synthesizingVerdict: return (session.activeMode == .build ? "Build Blueprint" : "Drafting Verdict", StudioTheme.brassBright)
            case .executingPlan: return ("Building Code", StudioTheme.emerald)
            case .verifyingBuild: return ("QA & Verification", StudioTheme.sky)
            case .completed: return (session.activeMode == .build ? "Built & Verified" : "Co-Signed", StudioTheme.emerald)
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

    private func seatsStrip(moderator: Persona, debaters: [Persona], expandToFill: Bool) -> some View {
        let showAuditor = session.activeMode == .build && session.isCompletenessReviewOn
        let auditor = showAuditor ? model.completenessReviewer(for: session) : nil
        let isExternalAuditor = auditor != nil
            && auditor?.id != moderator.id
            && !debaters.contains(where: { $0.id == auditor?.id })

        return HStack(spacing: 10) {
            CouncilSeatCard(
                persona: moderator,
                modelLabel: model.displayLabel(for: moderator.provider, modelID: moderator.modelID),
                isModerator: true,
                isAuditor: auditor?.id == moderator.id,
                isThinking: model.activeThinkerIDs.contains(moderator.id),
                isSpeaking: model.voiceEngine.activeItem?.persona.id == moderator.id && model.voiceEngine.isPlaying,
                speakerLevel: model.voiceEngine.speakerLevel,
                latestStance: latestStance(for: moderator.id, in: session),
                expandToFill: expandToFill,
                onToggleSpecialty: { spec in
                    model.togglePersonaSpecialty(personaID: moderator.id, specialty: spec)
                }
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
                    isAuditor: auditor?.id == debater.id,
                    isThinking: model.activeThinkerIDs.contains(debater.id),
                    isSpeaking: model.voiceEngine.activeItem?.persona.id == debater.id && model.voiceEngine.isPlaying,
                    speakerLevel: model.voiceEngine.speakerLevel,
                    latestStance: latestStance(for: debater.id, in: session),
                    expandToFill: expandToFill,
                    onToggleSpecialty: { spec in
                        model.togglePersonaSpecialty(personaID: debater.id, specialty: spec)
                    }
                ) {
                    model.openStudio(for: debater.id)
                }
            }

            if isExternalAuditor, let auditor {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 40)
                    .padding(.horizontal, 2)

                CouncilSeatCard(
                    persona: auditor,
                    modelLabel: model.displayLabel(for: auditor.provider, modelID: auditor.modelID),
                    isModerator: false,
                    isAuditor: true,
                    isThinking: model.activeThinkerIDs.contains(auditor.id),
                    isSpeaking: model.voiceEngine.activeItem?.persona.id == auditor.id && model.voiceEngine.isPlaying,
                    speakerLevel: model.voiceEngine.speakerLevel,
                    latestStance: latestStance(for: auditor.id, in: session),
                    expandToFill: expandToFill,
                    onToggleSpecialty: { spec in
                        model.togglePersonaSpecialty(personaID: auditor.id, specialty: spec)
                    }
                ) {
                    model.openStudio(for: auditor.id)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Individual Seated Persona Medallion

struct CouncilSeatCard: View {
    let persona: Persona
    let modelLabel: String
    let isModerator: Bool
    var isAuditor: Bool = false
    let isThinking: Bool
    let isSpeaking: Bool
    let speakerLevel: CGFloat
    let latestStance: StanceKind?
    var expandToFill: Bool = false
    var onToggleSpecialty: ((String) -> Void)? = nil
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
                        }
                        if isAuditor {
                            Text("AUDITOR")
                                .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                                .tracking(0.6)
                                .foregroundStyle(StudioTheme.emerald)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(StudioTheme.emerald.opacity(0.18)))
                        } else if !isModerator, let stance = latestStance {
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

                        if let topSpec = persona.activeSpecialties.first {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(StudioTheme.inkMuted)
                            Image(systemName: PersonaSpecialty.symbol(for: topSpec))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(accent.opacity(0.92))
                            Text(shortSpecialtyLabel(topSpec))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(accent.opacity(0.92))
                                .lineLimit(1)
                        }
                    }
                }

                if expandToFill {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: expandToFill ? .infinity : nil, alignment: .leading)
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
        .contextMenu {
            if let onToggleSpecialty {
                Section("Choose \(persona.name) For… (Task Routing Signals)") {
                    ForEach(PersonaSpecialty.presets) { spec in
                        let active = persona.activeSpecialties.contains { $0.caseInsensitiveCompare(spec.label) == .orderedSame }
                        Button {
                            onToggleSpecialty(spec.label)
                        } label: {
                            Label(
                                active ? "✓ \(spec.label)" : spec.label,
                                systemImage: spec.symbolName
                            )
                        }
                    }
                }
                Divider()
            }
            Button {
                onTap()
            } label: {
                Label("Customize \(persona.name) in Persona Studio…", systemImage: "slider.horizontal.3")
            }
        }
        .help(seatHelpTooltip)
    }

    private var seatHelpTooltip: String {
        if let routing = persona.routingDescription {
            return "\(persona.name) — \(routing)\nClick to open Persona Studio, or right-click to toggle task specialties."
        }
        return "Click to customize \(persona.name)'s model, routing specialties, personality, or voice (right-click for quick specialty toggles)"
    }

    private func shortSpecialtyLabel(_ raw: String) -> String {
        switch raw {
        case PersonaSpecialty.writingAndCopy: return "Writing"
        case PersonaSpecialty.frontendAndUI: return "UI"
        case PersonaSpecialty.systemsAndBackend: return "Systems"
        case PersonaSpecialty.testsAndQA: return "QA"
        case PersonaSpecialty.creativeAndDesign: return "Creative"
        case PersonaSpecialty.toolingAndScripts: return "Tooling"
        case PersonaSpecialty.visualPolish: return "Visual AAA"
        default: return raw
        }
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
