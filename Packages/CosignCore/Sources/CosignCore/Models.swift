import Foundation

// MARK: - Providers & Models

public enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude = "claude"
    case codex = "codex"
    case agy = "agy"
    case openrouter = "openrouter"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Anthropic (Claude CLI)"
        case .codex: return "OpenAI (Codex CLI)"
        case .agy: return "Google Gemini (AGY CLI)"
        case .openrouter: return "OpenRouter (API)"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "OpenAI"
        case .agy: return "Gemini"
        case .openrouter: return "OpenRouter"
        }
    }

    public var symbolName: String {
        switch self {
        case .claude: return "sparkles.rectangle.stack.fill"
        case .codex: return "cpu.fill"
        case .agy: return "diamond.fill"
        case .openrouter: return "network"
        }
    }

    public var brandHex: String {
        switch self {
        case .claude: return "#E07A5F"
        case .codex: return "#34D399"
        case .agy: return "#60A5FA"
        case .openrouter: return "#C084FC"
        }
    }

    public var isSubscriptionCLI: Bool {
        self != .openrouter
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "X-High"
        case .max: return "Max"
        }
    }
}

public struct DiscoveredModel: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var provider: AIProvider
    public var familyGroup: String
    public var supportedEfforts: [ReasoningEffort]
    public var effortEmbeddedInID: Bool

    public init(
        id: String,
        displayName: String,
        provider: AIProvider,
        familyGroup: String = "",
        supportedEfforts: [ReasoningEffort] = [.low, .medium, .high],
        effortEmbeddedInID: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.familyGroup = familyGroup
        self.supportedEfforts = supportedEfforts
        self.effortEmbeddedInID = effortEmbeddedInID
    }
}

public enum ProviderHealthStatus: String, Codable, Sendable {
    case ready
    case needsLogin
    case notInstalled
    case missingAPIKey

    public var label: String {
        switch self {
        case .ready: return "Connected"
        case .needsLogin: return "Sign-in Needed"
        case .notInstalled: return "CLI Not Found"
        case .missingAPIKey: return "Optional Key Not Set"
        }
    }
}

public struct ProviderDiagnostics: Identifiable, Sendable {
    public var provider: AIProvider
    public var status: ProviderHealthStatus
    public var binaryPath: String?
    public var detail: String
    public var modelCount: Int

    public var id: String { provider.rawValue }

    public init(
        provider: AIProvider,
        status: ProviderHealthStatus,
        binaryPath: String? = nil,
        detail: String,
        modelCount: Int
    ) {
        self.provider = provider
        self.status = status
        self.binaryPath = binaryPath
        self.detail = detail
        self.modelCount = modelCount
    }
}

// MARK: - Personas & Panel Presets

public enum PersonaRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case moderator
    case debater

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .moderator: return "Moderator / Chair"
        case .debater: return "Debater"
        }
    }
}

public struct Persona: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var title: String
    public var tagline: String
    public var role: PersonaRole
    public var provider: AIProvider
    public var modelID: String
    public var effort: ReasoningEffort
    public var personality: String
    public var debateStyle: String
    public var accentHex: String
    public var avatarSymbol: String
    public var voicePresetID: String
    public var customVoicePath: String?
    public var voiceExaggeration: Double
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        title: String,
        tagline: String,
        role: PersonaRole,
        provider: AIProvider,
        modelID: String,
        effort: ReasoningEffort = .high,
        personality: String,
        debateStyle: String,
        accentHex: String,
        avatarSymbol: String,
        voicePresetID: String,
        customVoicePath: String? = nil,
        voiceExaggeration: Double = 0.45,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.tagline = tagline
        self.role = role
        self.provider = provider
        self.modelID = modelID
        self.effort = effort
        self.personality = personality
        self.debateStyle = debateStyle
        self.accentHex = accentHex
        self.avatarSymbol = avatarSymbol
        self.voicePresetID = voicePresetID
        self.customVoicePath = customVoicePath
        self.voiceExaggeration = voiceExaggeration
        self.isBuiltIn = isBuiltIn
    }

    public var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

public struct PanelPreset: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var subtitle: String
    public var iconSymbol: String
    public var moderatorID: UUID
    public var debaterIDs: [UUID]
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        subtitle: String,
        iconSymbol: String,
        moderatorID: UUID,
        debaterIDs: [UUID],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.iconSymbol = iconSymbol
        self.moderatorID = moderatorID
        self.debaterIDs = debaterIDs
        self.isBuiltIn = isBuiltIn
    }
}

// MARK: - Debate Timeline & Turns

public enum ToolExecutionPhase: String, Codable, Sendable {
    /// Pure fast reasoning with zero filesystem, shell, or web tools.
    case closedBook
    /// Full CLI research & inspection tools (Read, Glob, Grep, git, gh, MCP read, web search) — file writes blocked so parallel debaters never collide.
    case researchAndInspect
    /// Full read + write + execute CLI access — unlocked sequentially for ONE persona at a time under Chair coordination.
    case coordinatedReadWrite
}

public enum StanceKind: String, Codable, CaseIterable, Sendable {
    case intake
    case opening
    case challenging
    case replying
    case building
    case conceding
    case moderating
    case synthesizing
    case cosigning
    case dissenting
    case executing
    case followup

    public var label: String {
        switch self {
        case .intake: return "Clarifying"
        case .opening: return "Opening Stance"
        case .challenging: return "Challenging"
        case .replying: return "Answering"
        case .building: return "Building On"
        case .conceding: return "Conceding Point"
        case .moderating: return "Directing Floor"
        case .synthesizing: return "Synthesizing"
        case .cosigning: return "Co-Signing"
        case .dissenting: return "Holding Dissent"
        case .executing: return "Coordinated Edit"
        case .followup: return "Follow-Up"
        }
    }

    public var symbolName: String {
        switch self {
        case .intake: return "questionmark.bubble.fill"
        case .opening: return "sparkle"
        case .challenging: return "bolt.fill"
        case .replying: return "arrowshape.turn.up.left.fill"
        case .building: return "plus.circle.fill"
        case .conceding: return "arrow.uturn.right.circle.fill"
        case .moderating: return "person.wave.2.fill"
        case .synthesizing: return "wand.and.stars"
        case .cosigning: return "checkmark.seal.fill"
        case .dissenting: return "exclamationmark.triangle.fill"
        case .executing: return "hammer.circle.fill"
        case .followup: return "bubble.left.and.bubble.right.fill"
        }
    }
}

public struct InterviewQuestion: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var askedByPersonaID: UUID?
    public var askedByName: String
    public var askedByAccentHex: String
    public var question: String
    public var whyItMatters: String
    public var quickOptions: [String]
    public var answer: String
    public var delegateToPanel: Bool

    public init(
        id: UUID = UUID(),
        askedByPersonaID: UUID? = nil,
        askedByName: String,
        askedByAccentHex: String = "#F59E0B",
        question: String,
        whyItMatters: String,
        quickOptions: [String] = [],
        answer: String = "",
        delegateToPanel: Bool = false
    ) {
        self.id = id
        self.askedByPersonaID = askedByPersonaID
        self.askedByName = askedByName
        self.askedByAccentHex = askedByAccentHex
        self.question = question
        self.whyItMatters = whyItMatters
        self.quickOptions = quickOptions
        self.answer = answer
        self.delegateToPanel = delegateToPanel
    }
}

public struct InterviewExchange: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var moderatorID: UUID
    public var moderatorName: String
    public var moderatorAccentHex: String
    public var spokenIntro: String
    public var moderatorReasoning: String
    public var questions: [InterviewQuestion]
    public var isSubmitted: Bool
    public var wasSkipped: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        moderatorID: UUID,
        moderatorName: String,
        moderatorAccentHex: String,
        spokenIntro: String,
        moderatorReasoning: String = "",
        questions: [InterviewQuestion],
        isSubmitted: Bool = false,
        wasSkipped: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.moderatorID = moderatorID
        self.moderatorName = moderatorName
        self.moderatorAccentHex = moderatorAccentHex
        self.spokenIntro = spokenIntro
        self.moderatorReasoning = moderatorReasoning
        self.questions = questions
        self.isSubmitted = isSubmitted
        self.wasSkipped = wasSkipped
        self.createdAt = createdAt
    }
}

public struct DebateTurn: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var roundNumber: Int
    public var roundLabel: String
    public var personaID: UUID
    public var personaName: String
    public var personaTitle: String
    public var avatarSymbol: String
    public var accentHex: String
    public var provider: AIProvider
    public var modelLabel: String
    public var stance: StanceKind
    public var targetPersonaName: String?
    /// Raw spoken line including inline expressive vocal tags (`[chuckle]`, `[sigh]`, etc.) for Chatterbox Turbo.
    public var spokenTake: String
    /// Full reasoning trace & deeper analysis (hidden inside 1-click expandable drawer).
    public var thoughtProcess: String
    /// Crisp bullet takeaways inside the drawer.
    public var keyPoints: [String]
    /// Direct question or challenge posed to another seated persona so the Chair can hand them the mic.
    public var directQuestionForPeer: String?
    /// Short summary of CLI tools/files/repos inspected or modified during this turn.
    public var toolsActivitySummary: String?
    public var durationMs: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        roundNumber: Int,
        roundLabel: String,
        personaID: UUID,
        personaName: String,
        personaTitle: String,
        avatarSymbol: String,
        accentHex: String,
        provider: AIProvider,
        modelLabel: String,
        stance: StanceKind,
        targetPersonaName: String? = nil,
        spokenTake: String,
        thoughtProcess: String,
        keyPoints: [String] = [],
        directQuestionForPeer: String? = nil,
        toolsActivitySummary: String? = nil,
        durationMs: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.roundNumber = roundNumber
        self.roundLabel = roundLabel
        self.personaID = personaID
        self.personaName = personaName
        self.personaTitle = personaTitle
        self.avatarSymbol = avatarSymbol
        self.accentHex = accentHex
        self.provider = provider
        self.modelLabel = modelLabel
        self.stance = stance
        self.targetPersonaName = targetPersonaName
        self.spokenTake = spokenTake
        self.thoughtProcess = thoughtProcess
        self.keyPoints = keyPoints
        self.directQuestionForPeer = directQuestionForPeer
        self.toolsActivitySummary = toolsActivitySummary
        self.durationMs = durationMs
        self.createdAt = createdAt
    }
}

public struct MinorityDissent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var personaID: UUID?
    public var personaName: String
    public var accentHex: String
    public var coreObjection: String

    public init(
        id: UUID = UUID(),
        personaID: UUID? = nil,
        personaName: String,
        accentHex: String,
        coreObjection: String
    ) {
        self.id = id
        self.personaID = personaID
        self.personaName = personaName
        self.accentHex = accentHex
        self.coreObjection = coreObjection
    }
}

public struct ExecutionAssignment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var assignedPersonaName: String
    public var taskInstruction: String
    public var targetScope: String

    public init(
        id: UUID = UUID(),
        assignedPersonaName: String,
        taskInstruction: String,
        targetScope: String = ""
    ) {
        self.id = id
        self.assignedPersonaName = assignedPersonaName
        self.taskInstruction = taskInstruction
        self.targetScope = targetScope
    }
}

public struct CosignVerdict: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var moderatorID: UUID
    public var moderatorName: String
    public var headline: String
    public var spokenVerdict: String
    public var recommendation: String
    public var actionSteps: [String]
    public var keyTradeoffs: [String]
    public var cosignedPersonaIDs: [UUID]
    public var cosignedNames: [String]
    public var dissents: [MinorityDissent]
    public var moderatorThoughtProcess: String
    public var shouldAutoExecute: Bool?
    public var executionAssignments: [ExecutionAssignment]?
    public var wasExecuted: Bool?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        moderatorID: UUID,
        moderatorName: String,
        headline: String,
        spokenVerdict: String,
        recommendation: String,
        actionSteps: [String] = [],
        keyTradeoffs: [String] = [],
        cosignedPersonaIDs: [UUID] = [],
        cosignedNames: [String] = [],
        dissents: [MinorityDissent] = [],
        moderatorThoughtProcess: String = "",
        shouldAutoExecute: Bool? = false,
        executionAssignments: [ExecutionAssignment]? = nil,
        wasExecuted: Bool? = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.moderatorID = moderatorID
        self.moderatorName = moderatorName
        self.headline = headline
        self.spokenVerdict = spokenVerdict
        self.recommendation = recommendation
        self.actionSteps = actionSteps
        self.keyTradeoffs = keyTradeoffs
        self.cosignedPersonaIDs = cosignedPersonaIDs
        self.cosignedNames = cosignedNames
        self.dissents = dissents
        self.moderatorThoughtProcess = moderatorThoughtProcess
        self.shouldAutoExecute = shouldAutoExecute
        self.executionAssignments = executionAssignments
        self.wasExecuted = wasExecuted
        self.createdAt = createdAt
    }

    public var markdownFormatted: String {
        var lines: [String] = [
            "# Co-Signed Verdict: \(headline)",
            "",
            recommendation,
            ""
        ]
        if !actionSteps.isEmpty {
            lines.append("## Recommended Next Steps")
            for (idx, step) in actionSteps.enumerated() {
                lines.append("\(idx + 1). \(step)")
            }
            lines.append("")
        }
        if !keyTradeoffs.isEmpty {
            lines.append("## Key Trade-offs")
            for item in keyTradeoffs {
                lines.append("- \(item)")
            }
            lines.append("")
        }
        if !cosignedNames.isEmpty {
            lines.append("**Co-Signed By:** \(cosignedNames.joined(separator: ", "))")
        }
        if !dissents.isEmpty {
            lines.append("")
            lines.append("## Minority Dissent")
            for d in dissents {
                lines.append("- **\(d.personaName):** \(d.coreObjection)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum HandoffPromptBuilder {
    /// Builds a clean, self-contained implementation handoff prompt ready to paste into any coding harness
    /// (Claude Code, Codex, Antigravity, Cursor, etc.), incorporating workspace context, user constraints,
    /// the Co-Signed Verdict, file-scoped assignments, guardrails, and any post-verdict follow-up refinements.
    public static func build(
        session: DebateSession,
        verdict: CosignVerdict,
        selectedStepIndices: Set<Int>? = nil,
        includeFileAssignments: Bool = true,
        includeGuardrails: Bool = true,
        extraUserNote: String = ""
    ) -> String {
        var out: [String] = []

        out.append("# Implementation Handoff: \(verdict.headline)")
        out.append("")
        if let ws = session.workspacePath, !ws.isEmpty {
            out.append("**Workspace / Repo Context:** `\(ws)`")
            out.append("")
        }

        // Original Goal & Clarified Constraints
        let userPrompts = session.entries.compactMap { entry -> String? in
            if case .userPrompt(let m) = entry { return m.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            return nil
        }
        if let initialGoal = userPrompts.first, !initialGoal.isEmpty {
            out.append("## Goal & Context")
            out.append(initialGoal)
            out.append("")
        }

        let answeredQuestions = session.entries.compactMap { entry -> [InterviewQuestion]? in
            if case .interview(let ex) = entry, ex.isSubmitted, !ex.wasSkipped {
                return ex.questions
            }
            return nil
        }.flatMap { $0 }

        if !answeredQuestions.isEmpty {
            out.append("### Clarified Constraints")
            for q in answeredQuestions {
                if !q.delegateToPanel {
                    let ans = q.answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ans.isEmpty {
                        out.append("- **\(q.question)** → \(ans)")
                    }
                }
            }
            out.append("")
        }

        // Core Co-Signed Direction
        out.append("## Agreed Architecture & Strategy")
        let cleanBottomLine = verdict.spokenVerdict
            .replacingOccurrences(of: #"\[(chuckle|laugh|sigh|clear throat|cough|gasp|groan)\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanBottomLine.isEmpty {
            out.append("> **Bottom Line:** \(cleanBottomLine)")
            out.append("")
        }
        if !verdict.recommendation.isEmpty {
            out.append(verdict.recommendation)
            out.append("")
        }

        // Scoped Action Steps
        if !verdict.actionSteps.isEmpty {
            let indices = selectedStepIndices ?? Set(verdict.actionSteps.indices)
            let chosenSteps = verdict.actionSteps.enumerated().filter { indices.contains($0.offset) }
            if !chosenSteps.isEmpty {
                out.append("## Actionable Implementation Steps")
                for (displayIdx, pair) in chosenSteps.enumerated() {
                    out.append("\(displayIdx + 1). \(pair.element)")
                }
                out.append("")
            }
        }

        // Concrete File-Level Specifications (if Chair produced scoped assignments)
        if includeFileAssignments, let assignments = verdict.executionAssignments, !assignments.isEmpty {
            out.append("## Detailed File & Module Breakdown")
            for (idx, item) in assignments.enumerated() {
                out.append("### Workstream \(idx + 1)")
                if !item.targetScope.isEmpty {
                    out.append("- **Target Files / Scope:** `\(item.targetScope)`")
                }
                out.append("- **Instructions:** \(item.taskInstruction)")
                out.append("")
            }
        }

        // Post-Verdict Follow-Up Refinements (if user continued chatting after the verdict)
        if let verdictIndex = session.entries.firstIndex(where: { $0.id == verdict.id }),
           verdictIndex + 1 < session.entries.count {
            let trailingEntries = session.entries[(verdictIndex + 1)...]
            var followUps: [String] = []
            for entry in trailingEntries {
                switch entry {
                case .userPrompt(let msg):
                    followUps.append("- **User Follow-Up:** \(msg.text)")
                case .turn(let t):
                    let clean = t.spokenTake
                        .replacingOccurrences(of: #"\[(chuckle|laugh|sigh|clear throat|cough|gasp|groan)\]"#, with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    followUps.append("- **\(t.personaName) (\(t.personaTitle)):** \(clean)")
                default:
                    break
                }
            }
            if !followUps.isEmpty {
                out.append("## Follow-Up Refinements from Discussion")
                out.append(contentsOf: followUps)
                out.append("")
            }
        }

        // Guardrails, Trade-offs & Minority Caveats
        if includeGuardrails && (!verdict.keyTradeoffs.isEmpty || !verdict.dissents.isEmpty) {
            out.append("## Guardrails & Trade-Offs to Respect")
            for tradeoff in verdict.keyTradeoffs {
                out.append("- \(tradeoff)")
            }
            for dissent in verdict.dissents {
                out.append("- **Watchout (\(dissent.personaName)):** \(dissent.coreObjection)")
            }
            out.append("")
        }

        let trimmedExtra = extraUserNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExtra.isEmpty {
            out.append("## Additional Instructions")
            out.append(trimmedExtra)
            out.append("")
        }

        out.append("## Execution Expectations")
        out.append("- Inspect the referenced files and current git state before making edits.")
        out.append("- Implement the scoped steps cleanly, keeping changes surgical and aligned with the guardrails above.")
        out.append("- Run the project's build and relevant tests to verify everything passes before wrapping up.")

        return out.joined(separator: "\n")
    }
}

public struct UserPromptMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

public struct RoundBanner: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var roundNumber: Int
    public var title: String
    public var subtitle: String

    public init(id: UUID = UUID(), roundNumber: Int, title: String, subtitle: String) {
        self.id = id
        self.roundNumber = roundNumber
        self.title = title
        self.subtitle = subtitle
    }
}

public enum TimelineEntry: Identifiable, Codable, Hashable, Sendable {
    case userPrompt(UserPromptMessage)
    case interview(InterviewExchange)
    case roundBanner(RoundBanner)
    case turn(DebateTurn)
    case verdict(CosignVerdict)
    case systemNote(UUID, String)

    public var id: UUID {
        switch self {
        case .userPrompt(let msg): return msg.id
        case .interview(let ex): return ex.id
        case .roundBanner(let b): return b.id
        case .turn(let t): return t.id
        case .verdict(let v): return v.id
        case .systemNote(let id, _): return id
        }
    }
}

public enum SessionStage: String, Codable, Sendable {
    case idle
    case scanningIntake
    case awaitingInterviewAnswers
    case debating
    case synthesizingVerdict
    case executingPlan
    case completed
    case cancelled
    case error

    public var isBusy: Bool {
        switch self {
        case .scanningIntake, .debating, .synthesizingVerdict, .executingPlan:
            return true
        default:
            return false
        }
    }
}

public struct DebateSession: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var moderatorID: UUID
    public var debaterIDs: [UUID]
    public var maxRebuttalRounds: Int
    public var allowWebSearch: Bool
    /// When true (default), personas have full CLI tools (repo/disk read, git, gh, MCP, web) and Chair-coordinated writes.
    public var cliToolsEnabled: Bool?
    /// Active working directory for CLI tools (e.g. a specific repo or repos parent folder).
    public var workspacePath: String?
    public var stage: SessionStage
    public var entries: [TimelineEntry]

    public var hasFullCLITools: Bool {
        cliToolsEnabled ?? true
    }

    public init(
        id: UUID = UUID(),
        title: String = "New Council Session",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        moderatorID: UUID,
        debaterIDs: [UUID],
        maxRebuttalRounds: Int = 2,
        allowWebSearch: Bool = true,
        cliToolsEnabled: Bool? = true,
        workspacePath: String? = nil,
        stage: SessionStage = .idle,
        entries: [TimelineEntry] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.moderatorID = moderatorID
        self.debaterIDs = debaterIDs
        self.maxRebuttalRounds = maxRebuttalRounds
        self.allowWebSearch = allowWebSearch
        self.cliToolsEnabled = cliToolsEnabled
        self.workspacePath = workspacePath
        self.stage = stage
        self.entries = entries
    }
}
