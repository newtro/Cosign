import AppKit
import CosignCore
import CosignVoice
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Empty-State Welcome & Inspiration Deck

struct EmptyCouncilWelcomeView: View {
    @ObservedObject var model: AppModel
    let session: DebateSession
    let onSelectStarter: (String) -> Void

    private let debateStarters: [(icon: String, title: String, subtitle: String, prompt: String)] = [
        (
            "lightbulb.max.fill",
            "Clarify an Early App Idea",
            "Panel interviews you first, then debates scope & MVP",
            "I have an early idea for a tool I want to build, and I want you guys to interview me on the missing details and help define the first version."
        ),
        (
            "scale.3d",
            "Evaluate a Technical Choice",
            "Pragmatist vs. Skeptic vs. Lateral Thinker",
            "We need to choose between building a custom local-first sync engine or using CloudKit for a macOS + iOS app. Debate the real trade-offs."
        ),
        (
            "chart.line.uptrend.xyaxis",
            "Product & Pricing Strategy",
            "Identify overlooked risks before committing",
            "Help me figure out the clearest positioning and pricing model for a niche creator utility without competing on low price alone."
        ),
        (
            "bolt.shield.fill",
            "Critique My Plan",
            "Test assumptions before I start",
            "I'm about to spend two weeks building a new project—interview me about what it is, point out the weak parts, and co-sign the parts worth keeping."
        ),
    ]

    private let buildStarters: [(icon: String, title: String, subtitle: String, prompt: String)] = [
        (
            "hammer.fill",
            "Build a New App from Scratch",
            "Huddle → Blueprint → Multi-Agent Build → QA Gate",
            "Build a clean, self-contained project in this folder with tests and a README—ask me any quick clarifying questions first, then build and verify it end-to-end."
        ),
        (
            "terminal.fill",
            "Scaffold a Fast CLI Tool",
            "Design, implement, and run unit tests",
            "Build a fast command-line utility in this directory with clean subcommands, automated unit tests, and zero unnecessary dependencies."
        ),
        (
            "sparkles.rectangle.stack.fill",
            "Implement a Feature in Existing Repo",
            "Inspect repo, split workstreams, verify tests",
            "Inspect this repository, propose the clearest implementation plan, divide the workstreams across the council, and verify all existing and new tests pass."
        ),
        (
            "checkmark.shield.fill",
            "Audit, Fix & Test Repo",
            "Find real bugs, fix them, and prove with tests",
            "Audit this codebase for bugs or missing test coverage, implement targeted fixes sequentially, and verify the full build and test suite pass."
        ),
    ]

    var body: some View {
        let isBuild = session.activeMode == .build
        let activeStarters = isBuild ? buildStarters : debateStarters
        let wsPath = session.workspacePath ?? WorkspaceResolver.defaultWorkspacePath()
        let needsFolder = isBuild && session.hasExplicitBuildFolder != true && WorkspaceResolver.isParentReposContainer(wsPath)

        VStack(spacing: 24) {
            Spacer(minLength: 20)

            // Emblem & Editorial Welcome
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [(isBuild ? StudioTheme.emerald : StudioTheme.brass).opacity(0.28), .clear],
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
                                .strokeBorder((isBuild ? StudioTheme.emerald : StudioTheme.brass).opacity(0.45), lineWidth: 1.2)
                        )
                        .shadow(color: (isBuild ? StudioTheme.emerald : StudioTheme.brass).opacity(0.25), radius: 16, y: 6)

                    Image(systemName: isBuild ? "hammer.fill" : "signature")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: isBuild ? [StudioTheme.emerald, StudioTheme.sky] : [StudioTheme.brassBright, StudioTheme.brass],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Text(isBuild ? "Build Together with the Council" : "Bring Your Idea to the Council")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(StudioTheme.inkPrimary)

                Text(isBuild
                     ? "Pick or create a local folder. The council aligns on architecture, executes parallel workstreams\nwith sub-agents, runs QA tests, and loops with your Completeness Reviewer to 100%."
                     : "Share an early idea or difficult decision. The panel will interview you on what's missing,\ndebate it aloud in compact turns, and deliver a Co-Signed Verdict.")
                    .font(.system(size: 13.5))
                    .lineSpacing(3.5)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(StudioTheme.inkSecondary)
                    .frame(maxWidth: 580)

                if isBuild {
                    Button {
                        model.chooseWorkspaceFolderWithPanel(forBuild: true)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: needsFolder ? "folder.badge.plus" : "folder.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text(needsFolder ? "Select or Create Target Build Folder…" : "Build Folder: \(wsPath)")
                                .font(.system(size: 12.5, weight: .semibold, design: needsFolder ? .default : .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: needsFolder ? StudioTheme.brassBright : StudioTheme.emerald, active: true))
                    .frame(maxWidth: 540)
                }
            }

            // 2x2 Starter Cards
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(activeStarters.enumerated()), id: \.offset) { _, item in
                    StarterPromptTile(
                        icon: item.icon,
                        title: item.title,
                        subtitle: item.subtitle
                    ) {
                        onSelectStarter(item.prompt)
                    }
                }
            }
            .frame(maxWidth: 960)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
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
    var onScrollToBottom: (() -> Void)? = nil

    @State private var isDropTargeted: Bool = false
    @State private var pasteMonitor: Any?

    var body: some View {
        let pendingAttachments = model.currentPendingAttachments
        let moderator = model.activeModerator(for: session)
        let participants = [moderator] + model.activeDebaters(for: session)
        let hasPriorVerdict = session.entries.contains {
            if case .verdict = $0 { return true }
            return false
        }

        VStack(spacing: 0) {
            // Upper Ribbon: Live Audio Transport & Chatterbox Turbo Status
            AudioTransportRibbon(model: model)

            Divider().overlay(Color.white.opacity(0.07))

            // Live Steering Strip while a debate or build run is active
            if session.stage.isBusy {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Live Steering · Sent to \(moderator.name) (\(moderator.title)) as soon as the current turn finishes")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(StudioTheme.emerald)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(StudioTheme.emerald.opacity(0.13)))
                        .overlay(Capsule().strokeBorder(StudioTheme.emerald.opacity(0.32), lineWidth: 0.8))

                        ForEach(model.activeDebaters(for: session)) { p in
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
            } else if hasPriorVerdict {
                // Quick @Mention Follow-up Strip once a verdict exists
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

                        Divider()
                            .frame(height: 14)
                            .padding(.horizontal, 4)

                        Button {
                            model.openHandoffSheet()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "terminal.fill")
                                    .font(.system(size: 9.5))
                                Text("Handoff Prompt")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(StudioTheme.emerald)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(Capsule().fill(StudioTheme.emerald.opacity(0.13)))
                            .overlay(Capsule().strokeBorder(StudioTheme.emerald.opacity(0.30), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                        .help("Generate & copy a coding-harness handoff prompt with all recommendations from this conversation")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 9)
                    .padding(.bottom, 2)
                }
            }

            // Staged Image Attachments Strip (when screenshots/images are pasted, dropped, or picked)
            if !pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(pendingAttachments) { att in
                            StagedImageThumbnailTile(
                                attachment: att,
                                onPreview: { model.activePreviewAttachment = att },
                                onRemove: { model.removePendingAttachment(att.id) }
                            )
                        }

                        if pendingAttachments.count < 8 {
                            Button {
                                model.attachImagesWithOpenPanel()
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("Add")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(StudioTheme.inkSecondary)
                                .frame(width: 58, height: 58)
                                .background(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .fill(Color.white.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.11), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Attach another image")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                }
            }

            // Main Prompt Input Row (Static NSTextField placeholder + SwiftUI overlay avoids AppKit IMKInputSession re-entrant RunLoop lockup!)
            let placeholderText = !pendingAttachments.isEmpty
                ? (session.stage.isBusy
                    ? "Add steering instructions for \(moderator.name) with the attached image\(pendingAttachments.count == 1 ? "" : "s"), or press Return…"
                    : "Add instructions for the attached image\(pendingAttachments.count == 1 ? "" : "s"), or press Return to send…")
                : (session.stage.isBusy
                    ? "Steer \(moderator.name) — add instructions or constraints while the council is working (⏎)…"
                    : (session.entries.isEmpty
                        ? (session.activeMode == .build
                            ? "Describe what to build, or paste/drop a screenshot (⌘V)…"
                            : "Pitch an idea or paste/drop an image for the council (⌘V)…")
                        : (session.activeMode == .build
                            ? "Ask for the next feature, fix, paste a screenshot (⌘V), or @mention…"
                            : "Follow up, push back, paste an image (⌘V), or @mention…")))

            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    model.attachImagesWithOpenPanel()
                } label: {
                    Image(systemName: pendingAttachments.isEmpty ? "photo.badge.plus" : "photo.stack.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(pendingAttachments.isEmpty ? StudioTheme.inkSecondary : StudioTheme.emerald)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(pendingAttachments.isEmpty ? Color.white.opacity(0.05) : StudioTheme.emerald.opacity(0.16))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(pendingAttachments.isEmpty ? Color.white.opacity(0.09) : StudioTheme.emerald.opacity(0.40), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Attach image(s) or screenshots (or paste directly with ⌘V / drag & drop)")

                ZStack(alignment: .topLeading) {
                    if draftText.isEmpty {
                        Text(placeholderText)
                            .font(.system(size: 14.5))
                            .foregroundStyle(StudioTheme.inkMuted.opacity(0.75))
                            .lineLimit(1)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }

                    TextField("", text: $draftText, axis: .vertical)
                        .lineLimit(1...6)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5))
                        .foregroundStyle(StudioTheme.inkPrimary)
                        .focused($isInputFocused)
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            if press.modifiers.contains(.shift) {
                                return .ignored
                            }
                            let hasContent = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.currentPendingAttachments.isEmpty
                            if hasContent {
                                let toSend = draftText
                                draftText = ""
                                model.sendPrompt(toSend)
                                return .handled
                            }
                            return .ignored
                        }
                        .padding(.vertical, 6)
                }

                let canSend = !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty
                if session.stage.isBusy {
                    HStack(spacing: 8) {
                        Button {
                            let toSend = draftText
                            draftText = ""
                            model.sendPrompt(toSend)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.triangle.turn.up.right.circle.fill")
                                    .font(.system(size: 11.5, weight: .bold))
                                Text("Steer \(moderator.name)")
                                    .font(.system(size: 12.5, weight: .semibold))
                            }
                            .foregroundStyle(Color(hex: "#071410"))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(StudioTheme.emerald)
                                    .shadow(color: StudioTheme.emerald.opacity(0.30), radius: 8, y: 3)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .opacity(canSend ? 1.0 : 0.38)
                        .help("Send this steering note to \(moderator.name) to read as soon as the current turn finishes")

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
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(StudioTheme.crimson))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Button {
                        let toSend = draftText
                        draftText = ""
                        model.sendPrompt(toSend)
                    } label: {
                        HStack(spacing: 6) {
                            if session.activeMode == .build && session.entries.isEmpty {
                                Image(systemName: "hammer.fill")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Build")
                            } else {
                                Text(session.entries.isEmpty ? "Convene" : "Send")
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 11, weight: .bold))
                            }
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

            // Bottom Micro-Controls Bar: Debate | Build Toggle + Folder / Tool Controls
            HStack(spacing: 9) {
                // Segmented Mode Toggle: Debate | Build
                HStack(spacing: 2) {
                    ForEach(CouncilMode.allCases) { modeOption in
                        let selected = session.activeMode == modeOption
                        let tint = modeOption == .build ? StudioTheme.emerald : StudioTheme.brassBright
                        Button {
                            model.setCurrentSessionMode(modeOption)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: modeOption.symbolName)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(modeOption.shortLabel)
                                    .font(.system(size: 11.5, weight: .semibold))
                            }
                            .foregroundStyle(selected ? StudioTheme.inkPrimary : StudioTheme.inkMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(
                                Capsule()
                                    .fill(selected ? tint.opacity(0.24) : .clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(session.stage.isBusy)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
                .help("Switch between Council Debate Mode and Multi-Agent Build Mode")

                if session.activeMode == .build {
                    let wsPath = session.workspacePath ?? WorkspaceResolver.defaultWorkspacePath()
                    let wsName = URL(fileURLWithPath: wsPath).lastPathComponent
                    let needsFolder = session.hasExplicitBuildFolder != true && WorkspaceResolver.isParentReposContainer(wsPath)
                    Button {
                        model.chooseWorkspaceFolderWithPanel(forBuild: true)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: needsFolder ? "folder.badge.plus" : "folder.fill")
                                .font(.system(size: 10.5))
                            Text(needsFolder ? "Select Build Folder…" : wsName)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: needsFolder ? StudioTheme.brassBright : StudioTheme.emerald, active: true))
                    .help("Choose an existing project directory or create a new folder for the council to build in (\(wsPath))")
                } else {
                    // Full CLI Tools + Chair Edits Toggle
                    Button {
                        model.setCurrentSessionCLITools(!session.hasFullCLITools)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: session.hasFullCLITools ? "hammer.fill" : "lock.fill")
                                .font(.system(size: 10.5))
                            Text(session.hasFullCLITools ? "Full CLI + Chair Edits" : "Closed-Book")
                        }
                    }
                    .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.emerald, active: session.hasFullCLITools))
                    .help("When enabled, all personas can inspect local repos & GitHub via CLI tools, and The Chair coordinates sequential file edits")
                }

                // Web Search Toggle
                Button {
                    model.setCurrentSessionWebSearch(!session.allowWebSearch)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "globe")
                            .font(.system(size: 10.5))
                        Text(session.allowWebSearch ? "Web On" : "Web Off")
                    }
                }
                .buttonStyle(StudioPillButtonStyle(tint: StudioTheme.sky, active: session.allowWebSearch))

                if session.activeMode == .build {
                    // Per-Session Completeness Reviewer Toggle & Persona Selector
                    let reviewOn = session.isCompletenessReviewOn
                    let reviewer = model.completenessReviewer(for: session)
                    let reviewerAccent = Color(hex: reviewer.accentHex)

                    Menu {
                        Button {
                            model.setCurrentSessionCompletenessReview(true)
                        } label: {
                            HStack {
                                Text("Completeness Review Loop: ON (Audit to 100%)")
                                if reviewOn {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Button {
                            model.setCurrentSessionCompletenessReview(false)
                        } label: {
                            HStack {
                                Text("Completeness Review Loop: OFF")
                                if !reviewOn {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Divider()

                        Section("Reviewer Persona (Any Model Provider)") {
                            ForEach(model.personas) { candidate in
                                let modelName = model.displayLabel(for: candidate.provider, modelID: candidate.modelID)
                                Button {
                                    model.setCurrentSessionCompletenessReviewer(candidate.id)
                                } label: {
                                    HStack {
                                        Text("\(candidate.name) — \(candidate.title)  (\(candidate.provider.shortName) · \(modelName))")
                                        if reviewOn && reviewer.id == candidate.id {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            model.openStudio(for: reviewer.id)
                        } label: {
                            Label("Customize \(reviewer.name) / Create Reviewer Persona…", systemImage: "slider.horizontal.3")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: reviewOn ? reviewer.avatarSymbol : "checkmark.shield")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(reviewOn ? reviewerAccent : StudioTheme.inkMuted)
                            Text(reviewOn
                                 ? "Reviewer: \(reviewer.name) · \(reviewer.provider.shortName)"
                                 : "Reviewer Off")
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(StudioTheme.inkMuted)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(reviewOn ? StudioTheme.inkPrimary : StudioTheme.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(reviewOn ? reviewerAccent.opacity(0.15) : Color.white.opacity(0.045)))
                        .overlay(Capsule().strokeBorder(reviewOn ? reviewerAccent.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(session.stage.isBusy)
                    .help(reviewOn
                          ? "Completeness Review ON: \(reviewer.name) (\(reviewer.provider.displayName)) will audit 100% of requirements at the end of the build and loop missed items back to the team until complete."
                          : "Completeness Review OFF for this chat session. Click to enable and pick a reviewer persona.")
                }

                if session.activeMode == .debate {
                    // Rebuttal Depth Menu (1, 2, 3, 5, 8, or Run Until Consensus)
                    let consensusMode = session.runsUntilConsensus
                    Menu {
                        ForEach([1, 2, 3, 5, 8], id: \.self) { count in
                            Button {
                                model.setCurrentSessionRounds(count)
                            } label: {
                                HStack {
                                    Text(RebuttalPolicy.menuLabel(for: count))
                                    if session.maxRebuttalRounds == count {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            model.setCurrentSessionRounds(RebuttalPolicy.untilConsensusValue)
                        } label: {
                            HStack {
                                Text(RebuttalPolicy.menuLabel(for: RebuttalPolicy.untilConsensusValue))
                                if consensusMode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: consensusMode ? "infinity" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text(RebuttalPolicy.shortLabel(for: session.maxRebuttalRounds))
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(consensusMode ? StudioTheme.brassBright : StudioTheme.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(consensusMode ? StudioTheme.brass.opacity(0.15) : Color.white.opacity(0.045)))
                        .overlay(Capsule().strokeBorder(consensusMode ? StudioTheme.brass.opacity(0.42) : Color.white.opacity(0.08), lineWidth: 1))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose a fixed number of rebuttal rounds or keep debating until the council reaches consensus")
                }

                Spacer()

                if !session.entries.isEmpty, let onScrollToBottom {
                    Button(action: onScrollToBottom) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 10, weight: .bold))
                            Text("Bottom")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(StudioTheme.inkSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(Capsule().fill(Color.white.opacity(0.055)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Scroll straight to the bottom of the session (⌘J)")
                }

                if session.entries.isEmpty && (!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty) && !session.stage.isBusy {
                    Button {
                        let toSend = draftText
                        draftText = ""
                        model.sendPrompt(toSend, skipInterview: true)
                    } label: {
                        Text(session.activeMode == .build ? "Skip Questions & Build Straight Away →" : "Skip Interview & Debate Straight Away →")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(StudioTheme.inkMuted)
                    }
                    .buttonStyle(.plain)
                } else if session.stage.isBusy {
                    Text("⌘V Image  ·  ⏎ Steer \(moderator.name)  ·  ⇧⏎ New line")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.emerald.opacity(0.85))
                } else {
                    Text(session.activeMode == .build ? "⌘V Image  ·  ⏎ Build  ·  ⇧⏎ New line" : "⌘V Image  ·  ⏎ Convene  ·  ⇧⏎ New line")
                        .font(.system(size: 11))
                        .foregroundStyle(StudioTheme.inkMuted.opacity(0.75))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 11)
        }
        .frame(maxWidth: .infinity)
        .studioCard(
            cornerRadius: 20,
            fill: StudioTheme.dockGlass,
            glowColor: isDropTargeted ? StudioTheme.emerald : nil,
            glowIntensity: isDropTargeted ? 0.45 : 0.22
        )
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(StudioTheme.emerald, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .overlay(
                        HStack(spacing: 7) {
                            Image(systemName: "photo.badge.plus")
                            Text("Drop image(s) to attach")
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(StudioTheme.emerald)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.82)))
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .onAppear {
            installPasteMonitorIfNeeded()
        }
        .onDisappear {
            if let pasteMonitor {
                NSEvent.removeMonitor(pasteMonitor)
                self.pasteMonitor = nil
            }
        }
        .padding(.bottom, 14)
        .padding(.top, 6)
    }

    private func installPasteMonitorIfNeeded() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            // Don't hijack ⌘V inside modal sheets (Persona Studio, Settings, Handoff, etc.)
            guard !model.showingPersonaStudio,
                  model.activeHandoffVerdict == nil,
                  model.activeBuildLaunchVerdict == nil,
                  model.activePreviewAttachment == nil,
                  NSApp.keyWindow?.attachedSheet == nil else {
                return event
            }
            if model.currentSession != nil,
               model.attachImagesFromPasteboard(.general) {
                return nil
            }
            return event
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let resolvedURL: URL? = {
                        if let data = item as? Data {
                            return URL(dataRepresentation: data, relativeTo: nil)
                        }
                        if let url = item as? URL {
                            return url
                        }
                        return nil
                    }()
                    if let url = resolvedURL {
                        Task { @MainActor in
                            _ = model.attachImagesFromURLs([url])
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data {
                        Task { @MainActor in
                            _ = model.attachImageData(data, preferredName: "Dropped-Image")
                        }
                    }
                }
            }
        }
        return handled
    }
}

private struct StagedImageThumbnailTile: View {
    let attachment: ChatImageAttachment
    let onPreview: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onPreview) {
                Group {
                    if let nsImg = NSImage(contentsOfFile: attachment.filePath) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color.white.opacity(0.06)
                            Image(systemName: "photo")
                                .foregroundStyle(StudioTheme.inkMuted)
                        }
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(StudioTheme.emerald.opacity(0.42), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help("\(attachment.displayName) — click to preview")

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.82))
            }
            .buttonStyle(.plain)
            .offset(x: 5, y: -5)
            .help("Remove image")
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
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
                    } else {
                        ProgressView().controlSize(.mini).tint(activeAccent)
                    }
                    Text(voice.isPlaying ? active.contextLabel : "Voicing \(active.contextLabel)…")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(StudioTheme.inkPrimary)
                        .lineLimit(1)
                    if !voice.queuedItems.isEmpty {
                        Text(voice.isSynthesizingNext ? "· buffering +\(voice.queuedItems.count)" : "· +\(voice.queuedItems.count) ready")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(voice.isSynthesizingNext ? StudioTheme.brassBright : StudioTheme.emerald)
                    }
                } else if voice.isSynthesizingNext || !voice.queuedItems.isEmpty {
                    ProgressView().controlSize(.mini).tint(StudioTheme.brassBright)
                    Text("Queuing & synthesizing voices (\(voice.queuedItems.count) turns)…")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(StudioTheme.brassBright)
                        .lineLimit(1)
                } else {
                    Text(statusDescription(voice.daemonState))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(StudioTheme.inkMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Play Entire Session Button when idle on a session with turns
            if voice.activeItem == nil && voice.queuedItems.isEmpty,
               let current = model.currentSession,
               current.entries.contains(where: {
                   if case .turn = $0 { return true }
                   if case .verdict = $0 { return true }
                   return false
               }) {
                Button {
                    model.playFullSessionAudio(current)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("Play Full Debate")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(StudioTheme.brassBright)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(StudioTheme.brass.opacity(0.14)))
                    .overlay(Capsule().strokeBorder(StudioTheme.brass.opacity(0.32), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("Voice every turn and the verdict continuously from start to finish")
            }

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
        case .ready: return "Breeze TTS 2 Studio Voice · Ready on Metal"
        case .starting(let msg): return msg
        case .idle: return "Breeze TTS 2 · Standby"
        case .fallbackSystemVoice(let msg): return msg
        }
    }
}
