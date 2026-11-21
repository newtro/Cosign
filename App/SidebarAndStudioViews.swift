import AppKit
import CosignCore
import CosignVoice
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Left Session & Preset Sidebar

struct CouncilSidebarView: View {
    @ObservedObject var model: AppModel
    @State private var searchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand Header + New Session CTA
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [StudioTheme.brassBright, StudioTheme.brass],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 28, height: 28)
                        Image(systemName: "signature")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(hex: "#090B10"))
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Cosign")
                            .font(.system(size: 16, weight: .bold, design: .serif))
                            .foregroundStyle(StudioTheme.inkPrimary)
                        Text("AI Council Chamber")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                    Spacer()
                }

                Button {
                    model.createNewSession()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("New Council Session")
                        Spacer()
                        Text("⌘N")
                            .font(.system(size: 10.5, design: .monospaced))
                            .opacity(0.65)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrassPrimaryButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            // Search Filter
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(StudioTheme.inkMuted)
                TextField("Filter sessions…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(StudioTheme.inkPrimary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider().overlay(Color.white.opacity(0.06))

            // Session List
            ScrollView {
                LazyVStack(spacing: 4) {
                    let filtered = filteredSessions
                    ForEach(filtered) { session in
                        SidebarSessionRow(
                            session: session,
                            isSelected: model.selectedSessionID == session.id,
                            onSelect: { model.selectSession(session.id) },
                            onDelete: { model.deleteSession(session.id) }
                        )
                    }
                }
                .padding(10)
            }

            Divider().overlay(Color.white.opacity(0.06))

            // Bottom Footer: Persona Studio & Subscription Status Summary
            HStack(spacing: 8) {
                let readyCount = model.providerDiagnostics.filter { $0.provider.isSubscriptionCLI && $0.status == .ready }.count
                Circle()
                    .fill(readyCount >= 2 ? StudioTheme.emerald : StudioTheme.brassBright)
                    .frame(width: 7, height: 7)
                Text("\(readyCount)/3 CLIs Ready")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(StudioTheme.inkMuted)

                Spacer()

                Button {
                    model.openStudio()
                } label: {
                    Image(systemName: "person.crop.rectangle.stack.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(StudioTheme.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Open Persona & Panel Studio")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .background(StudioTheme.sidebarBg)
    }

    private var filteredSessions: [DebateSession] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return model.sessions }
        return model.sessions.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }
}

private struct SidebarSessionRow: View {
    let session: DebateSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 6.5, height: 6.5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? StudioTheme.inkPrimary : StudioTheme.inkSecondary)
                        .lineLimit(1)

                    Text(session.updatedAt, style: .relative)
                        .font(.system(size: 10.5))
                        .foregroundStyle(StudioTheme.inkMuted)
                }

                Spacer(minLength: 4)

                if hovering {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Delete session")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.09) : (hovering ? Color.white.opacity(0.04) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? StudioTheme.brass.opacity(0.32) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }

    private var indicatorColor: Color {
        switch session.stage {
        case .completed: return StudioTheme.emerald
        case .awaitingInterviewAnswers: return StudioTheme.brassBright
        case .scanningIntake, .debating, .synthesizingVerdict: return StudioTheme.sky
        case .error: return StudioTheme.crimson
        default: return StudioTheme.inkMuted.opacity(0.5)
        }
    }
}

// MARK: - Persona & Panel Studio Sheet

struct PersonaStudioSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPersonaID: UUID?
    @State private var draft: Persona = DefaultRoster.personas[0]
    @State private var customModelOverride: String = ""
    @State private var showingVoiceFileImporter: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            // Left Roster Column
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Personas")
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundStyle(StudioTheme.inkPrimary)
                    Spacer()
                    Button {
                        createNewPersona()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("New")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.brassBright, active: true))
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)

                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(model.personas) { p in
                            let selected = draft.id == p.id
                            Button {
                                selectPersona(p)
                            } label: {
                                HStack(spacing: 10) {
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: p.accentHex).opacity(0.22))
                                            .frame(width: 30, height: 30)
                                        Image(systemName: p.avatarSymbol)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(Color(hex: p.accentHex))
                                    }
                                    VStack(alignment: .leading, spacing: 1.5) {
                                        HStack(spacing: 5) {
                                            Text(p.name)
                                                .font(.system(size: 13, weight: .bold, design: .serif))
                                                .foregroundStyle(StudioTheme.inkPrimary)
                                            if p.role == .moderator {
                                                Text("CHAIR")
                                                    .font(.system(size: 8, weight: .heavy))
                                                    .foregroundStyle(StudioTheme.brassBright)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Capsule().fill(StudioTheme.brass.opacity(0.18)))
                                            }
                                        }
                                        Text("\(p.provider.shortName) · \(model.displayLabel(for: p.provider, modelID: p.modelID))")
                                            .font(.system(size: 10.5, design: .monospaced))
                                            .foregroundStyle(StudioTheme.inkMuted)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(9)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(selected ? Color.white.opacity(0.09) : .clear)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(selected ? Color(hex: p.accentHex).opacity(0.55) : .clear, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                }

                Divider().overlay(Color.white.opacity(0.08))

                Button {
                    Task { await model.refreshModels() }
                } label: {
                    HStack(spacing: 6) {
                        if model.isRefreshingModels {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text("Refresh Live Provider Models")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(StudioTheme.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
            .frame(width: 265)
            .background(StudioTheme.sidebarBg)

            Divider().overlay(Color.white.opacity(0.08))

            // Right Persona Editor
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Live Identity Banner
                        let accent = Color(hex: draft.accentHex)
                        HStack(alignment: .top, spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(accent.opacity(0.24))
                                    .frame(width: 52, height: 52)
                                Image(systemName: draft.avatarSymbol)
                                    .font(.system(size: 21, weight: .semibold))
                                    .foregroundStyle(accent)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    TextField("Name", text: $draft.name)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 20, weight: .bold, design: .serif))
                                        .foregroundStyle(StudioTheme.inkPrimary)
                                        .frame(minWidth: 110, maxWidth: 160)

                                    Text("·")
                                        .foregroundStyle(StudioTheme.inkMuted)

                                    TextField("Title (e.g. The Skeptic)", text: $draft.title)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(accent)

                                    Spacer(minLength: 8)

                                    HStack(spacing: 4) {
                                        ForEach(PersonaRole.allCases) { r in
                                            Button {
                                                draft.role = r
                                            } label: {
                                                Text(r == .moderator ? "Chair" : "Debater")
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                    .foregroundStyle(draft.role == r ? StudioTheme.inkPrimary : StudioTheme.inkMuted)
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .background(
                                                        Capsule().fill(draft.role == r ? accent.opacity(0.26) : .clear)
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(3)
                                    .background(Capsule().fill(StudioTheme.drawerBg))
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                                }

                                TextField("One-line tagline…", text: $draft.tagline)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                            }
                        }
                        .padding(16)
                        .studioCard(cornerRadius: 15, fill: StudioTheme.cardSurface, glowColor: accent, glowIntensity: 0.16)

                        // Swatches & Symbols
                        HStack(alignment: .top, spacing: 22) {
                            VStack(alignment: .leading, spacing: 7) {
                                studioLabel("ACCENT SIGNATURE")
                                HStack(spacing: 7) {
                                    ForEach(StudioTheme.personaSwatches, id: \.self) { hex in
                                        Button {
                                            draft.accentHex = hex
                                        } label: {
                                            Circle()
                                                .fill(Color(hex: hex))
                                                .frame(width: 20, height: 20)
                                                .overlay(
                                                    Circle()
                                                        .strokeBorder(.white, lineWidth: draft.accentHex == hex ? 2 : 0)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 7) {
                                studioLabel("EMBLEM")
                                FlowLayout(spacing: 6, lineSpacing: 6) {
                                    ForEach(StudioTheme.personaSymbols, id: \.self) { sym in
                                        Button {
                                            draft.avatarSymbol = sym
                                        } label: {
                                            Image(systemName: sym)
                                                .font(.system(size: 12))
                                                .foregroundStyle(draft.avatarSymbol == sym ? accent : StudioTheme.inkSecondary)
                                                .frame(width: 26, height: 26)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 7)
                                                        .fill(draft.avatarSymbol == sym ? accent.opacity(0.2) : Color.white.opacity(0.05))
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // Provider + Live Discovered Model + Effort
                        VStack(alignment: .leading, spacing: 12) {
                            studioLabel("SUBSCRIPTION PROVIDER & LIVE MODEL")

                            HStack(spacing: 12) {
                                Picker("Provider", selection: $draft.provider) {
                                    ForEach(AIProvider.allCases) { prov in
                                        Text(prov.displayName).tag(prov)
                                    }
                                }
                                .onChange(of: draft.provider) { _, newProv in
                                    if let first = model.modelCatalog[newProv]?.first {
                                        draft.modelID = first.id
                                    }
                                }

                                let availableModels = model.modelCatalog[draft.provider] ?? []
                                Picker("Model", selection: $draft.modelID) {
                                    ForEach(availableModels) { m in
                                        Text(m.displayName).tag(m.id)
                                    }
                                    if !availableModels.contains(where: { $0.id == draft.modelID }) {
                                        Text(draft.modelID).tag(draft.modelID)
                                    }
                                }
                            }

                            HStack(spacing: 10) {
                                Text("Effort")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                                    .fixedSize()

                                HStack(spacing: 3) {
                                    ForEach(ReasoningEffort.allCases) { eff in
                                        Button {
                                            draft.effort = eff
                                        } label: {
                                            Text(eff.displayName)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(draft.effort == eff ? StudioTheme.inkPrimary : StudioTheme.inkMuted)
                                                .padding(.horizontal, 9)
                                                .padding(.vertical, 4.5)
                                                .background(
                                                    Capsule().fill(draft.effort == eff ? accent.opacity(0.26) : .clear)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(3)
                                .background(Capsule().fill(StudioTheme.drawerBg))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))

                                Spacer(minLength: 8)

                                TextField("Custom model slug…", text: $draft.modelID)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .frame(width: 185)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(StudioTheme.drawerBg))
                            }
                        }
                        .padding(15)
                        .studioCard(cornerRadius: 14, fill: StudioTheme.cardSurface)

                        // Expressive Local Voice Studio (Breeze TTS 2)
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                studioLabel("BREEZE TTS 2 STUDIO VOICE")
                                Spacer()
                                Button {
                                    model.previewPersonaVoice(draft)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 10))
                                        Text("Preview Voice")
                                    }
                                }
                                .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: true))
                            }

                            HStack(spacing: 14) {
                                Picker("Voice Archetype", selection: $draft.voicePresetID) {
                                    ForEach(VoicePreset.all) { vp in
                                        Text("\(vp.name) (\(vp.accentNote))").tag(vp.id)
                                    }
                                }

                                Button {
                                    showingVoiceFileImporter = true
                                } label: {
                                    Text(draft.customVoicePath == nil ? "Custom .wav Seed…" : "Change Custom .wav")
                                }
                                .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.sky, active: draft.customVoicePath != nil))

                                if draft.customVoicePath != nil {
                                    Button("Clear") {
                                        draft.customVoicePath = nil
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(StudioTheme.crimson)
                                }
                            }

                            HStack(spacing: 12) {
                                Text("Vocal Spirit:")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(StudioTheme.inkSecondary)
                                Text("Measured")
                                    .font(.system(size: 11))
                                    .foregroundStyle(StudioTheme.inkMuted)
                                Slider(value: $draft.voiceExaggeration, in: 0.1...0.95)
                                    .tint(accent)
                                Text("Spirited")
                                    .font(.system(size: 11))
                                    .foregroundStyle(StudioTheme.inkMuted)
                            }
                        }
                        .padding(15)
                        .studioCard(cornerRadius: 14, fill: StudioTheme.cardSurface)

                        // Personality & Debate Style
                        VStack(alignment: .leading, spacing: 10) {
                            studioLabel("PERSONALITY & WORLDVIEW")
                            TextEditor(text: $draft.personality)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(StudioTheme.inkPrimary)
                                .padding(10)
                                .frame(height: 82)
                                .background(RoundedRectangle(cornerRadius: 10).fill(StudioTheme.drawerBg))

                            studioLabel("DEBATE STYLE & RHETORIC")
                            TextEditor(text: $draft.debateStyle)
                                .font(.system(size: 13))
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(StudioTheme.inkPrimary)
                                .padding(10)
                                .frame(height: 70)
                                .background(RoundedRectangle(cornerRadius: 10).fill(StudioTheme.drawerBg))
                        }
                        .padding(15)
                        .studioCard(cornerRadius: 14, fill: StudioTheme.cardSurface)
                    }
                    .padding(22)
                }

                Divider().overlay(Color.white.opacity(0.08))

                // Bottom Sheet Actions
                HStack {
                    if !draft.isBuiltIn {
                        Button(role: .destructive) {
                            model.deletePersona(draft.id)
                            if let first = model.personas.first {
                                selectPersona(first)
                            }
                        } label: {
                            Label("Delete Persona", systemImage: "trash")
                                .foregroundStyle(StudioTheme.crimson)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            duplicateCurrentPersona()
                        } label: {
                            Label("Duplicate as Custom Persona", systemImage: "plus.square.on.square")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(StudioTheme.inkSecondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(StudioPillButtonStyle())

                    Button("Save Persona") {
                        model.upsertPersona(draft)
                    }
                    .buttonStyle(BrassPrimaryButtonStyle(accent: Color(hex: draft.accentHex)))
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(StudioTheme.sidebarBg)
            }
        }
        .frame(width: 920, height: 690)
        .background(StudioTheme.canvasTop)
        .preferredColorScheme(.dark)
        .onAppear {
            let startID = model.studioInitialPersonaID ?? model.personas.first?.id
            if let startID, let found = model.persona(for: startID) {
                selectPersona(found)
            }
        }
        .fileImporter(
            isPresented: $showingVoiceFileImporter,
            allowedContentTypes: [.wav, .audio],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                draft.customVoicePath = url.path
            }
        }
    }

    private func selectPersona(_ p: Persona) {
        selectedPersonaID = p.id
        draft = p
    }

    private func createNewPersona() {
        let fresh = Persona(
            name: "New Panelist",
            title: "The Specialist",
            tagline: "Custom council voice with a sharp perspective.",
            role: .debater,
            provider: .claude,
            modelID: model.modelCatalog[.claude]?.first?.id ?? "claude-opus-5-5",
            effort: .high,
            personality: "Describe how this persona thinks, what they prioritize, and what they push back against.",
            debateStyle: "Direct, incisive, conversational.",
            accentHex: "#2DD4BF",
            avatarSymbol: "compass.drawing",
            voicePresetID: "ember",
            voiceExaggeration: 0.48,
            isBuiltIn: false
        )
        model.upsertPersona(fresh)
        selectPersona(fresh)
    }

    private func duplicateCurrentPersona() {
        var copy = draft
        copy.id = UUID()
        copy.name = "\(draft.name) Copy"
        copy.isBuiltIn = false
        model.upsertPersona(copy)
        selectPersona(copy)
    }

    private func studioLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.9)
            .foregroundStyle(StudioTheme.brassBright)
    }
}

// MARK: - Settings View (⌘,)

struct CosignSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: AppUpdater

    @State private var openRouterInput: String = ""
    @State private var savedKeyNotice: Bool = false

    var body: some View {
        TabView {
            providersTab
                .tabItem {
                    Label("Subscriptions & Models", systemImage: "cpu.fill")
                }

            voiceAndDisplayTab
                .tabItem {
                    Label("Voice & Debate", systemImage: "waveform")
                }

            updatesTab
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                }
        }
        .frame(width: 600, height: 440)
        .padding(16)
        .preferredColorScheme(.dark)
        .onAppear {
            openRouterInput = KeychainHelper.read(account: "openrouter") ?? ""
        }
    }

    private var providersTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subscription CLI Connections")
                        .font(.headline)
                    Text("Cosign runs each persona inside an isolated temporary HOME so your personal skills and memories never leak.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshModels() }
                } label: {
                    Label("Refresh Models", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingModels)
            }

            VStack(spacing: 8) {
                ForEach(model.providerDiagnostics) { diag in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(diag.status == .ready ? StudioTheme.emerald : (diag.status == .missingAPIKey ? .gray : StudioTheme.brassBright))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(diag.provider.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(diag.status.label)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(diag.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(diag.modelCount) models")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Optional OpenRouter API Key (Stored in macOS Keychain)")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    SecureField("sk-or-v1-…", text: $openRouterInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Save to Keychain") {
                        let trimmed = openRouterInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            KeychainHelper.delete(account: "openrouter")
                        } else {
                            try? KeychainHelper.save(key: trimmed, account: "openrouter")
                        }
                        savedKeyNotice = true
                        Task { await model.refreshModels() }
                    }
                    if savedKeyNotice {
                        Text("Saved")
                            .font(.caption)
                            .foregroundStyle(StudioTheme.emerald)
                    }
                }
            }
            Spacer()
        }
        .padding(12)
    }

    private var voiceAndDisplayTab: some View {
        Form {
            Toggle("Automatically speak panel responses aloud (Breeze TTS 2 MLX)", isOn: Binding(
                get: { model.preferences.autoSpeakResponses },
                set: { _ in model.toggleAutoSpeak() }
            ))

            Toggle("Display subtle vocal stage cues (e.g. laughs, sighs) in turn cards", isOn: Binding(
                get: { model.preferences.showVocalTagsInText },
                set: { newVal in
                    model.preferences.showVocalTagsInText = newVal
                    model.store.savePreferences(model.preferences)
                }
            ))

            Picker("Default Session Mode", selection: Binding(
                get: { model.preferences.defaultMode ?? .debate },
                set: { model.setCurrentSessionMode($0) }
            )) {
                ForEach(CouncilMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }

            Picker("Default Rebuttal Rounds", selection: Binding(
                get: { model.preferences.defaultMaxRebuttalRounds },
                set: { model.setCurrentSessionRounds($0) }
            )) {
                Text("1 Rebuttal Round (Fast)").tag(1)
                Text("2 Rebuttal Rounds (Balanced)").tag(2)
                Text("3 Rebuttal Rounds (Deep)").tag(3)
            }

            Toggle("Allow Web Search by default", isOn: Binding(
                get: { model.preferences.defaultAllowWebSearch },
                set: { model.setCurrentSessionWebSearch($0) }
            ))
        }
        .padding(16)
    }

    private var updatesTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Automatic Updates (Sparkle)")
                .font(.headline)
            Text(updater.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.setAutomaticChecks($0) }
                ))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloads },
                    set: { updater.setAutomaticDownloads($0) }
                ))
                Button("Check for Updates Now…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckNow)
            }
            Spacer()
        }
        .padding(16)
    }
}
