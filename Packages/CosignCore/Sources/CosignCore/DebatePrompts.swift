import Foundation

public enum JSONExtractor {
    private static let knownTopLevelKeys: [String] = [
        "session_title", "needs_interview", "spoken_intro", "questions",
        "stance", "target_persona", "spoken_take", "direct_question_for_peer",
        "supporting_notes", "thought_process", "key_points", "tools_used",
        "headline", "spoken_verdict", "recommendation", "action_steps",
        "key_tradeoffs", "cosigned_by", "dissents", "should_auto_execute",
        "execution_assignments", "verification_passed", "issues_found",
        "files_summary", "how_to_run", "consensus_reached"
    ]

    /// Extracts the outermost JSON object `{ ... }` from an LLM response even if wrapped in markdown fences,
    /// containing unescaped interior quotes inside markdown values, or partially truncated.
    public static func parseObject(_ raw: String) -> [String: Any]? {
        let unwrapped = unwrapOuterMarkdownFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))

        // Tier 1: Fast strict parse
        if let strict = parseStrictJSONObject(unwrapped) {
            return strict
        }

        // Isolate outermost `{ ... }` slice
        let candidateSlice: String
        if let firstBrace = unwrapped.firstIndex(of: "{") {
            if let lastBrace = unwrapped.lastIndex(of: "}"), firstBrace <= lastBrace {
                candidateSlice = String(unwrapped[firstBrace...lastBrace])
            } else {
                candidateSlice = String(unwrapped[firstBrace...])
            }
        } else {
            return nil
        }

        if let strictSlice = parseStrictJSONObject(candidateSlice) {
            return strictSlice
        }

        // Tier 2: State-machine repair for unescaped interior quotes (e.g. `"Run the world"` inside markdown) & literal newlines
        let repaired = repairUnescapedQuotesAndNewlines(candidateSlice)
        if let parsedRepaired = parseStrictJSONObject(repaired) {
            return parsedRepaired
        }

        // Tier 3: Field-by-field anchor extraction fallback (handles truncated JSON or severe syntax quirks)
        let fallback = extractKnownFieldsFallback(candidateSlice)
        return fallback.isEmpty ? nil : fallback
    }

    private static func unwrapOuterMarkdownFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        guard let firstNewline = text.firstIndex(of: "\n") else { return text }
        var body = String(text[text.index(after: firstNewline)...])
        if let closingFence = body.range(of: "```", options: .backwards) {
            let trailing = body[closingFence.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if trailing.isEmpty {
                body = String(body[..<closingFence.lowerBound])
            }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseStrictJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private enum ContainerKind {
        case objectExpectingKey
        case objectExpectingColon
        case objectExpectingValue
        case arrayExpectingValue
    }

    /// Repairs unescaped `"` characters and raw control newlines inside JSON string values using structural lookahead.
    public static func repairUnescapedQuotesAndNewlines(_ input: String) -> String {
        let chars = Array(input)
        let count = chars.count
        var out: [Character] = []
        out.reserveCapacity(count + 64)

        var stack: [ContainerKind] = []
        var inString = false
        var stringIsKey = false
        var escaped = false
        var i = 0

        func nextNonWhitespaceIndex(from start: Int) -> Int? {
            var idx = start
            while idx < count {
                let c = chars[idx]
                if c != " " && c != "\t" && c != "\r" && c != "\n" {
                    return idx
                }
                idx += 1
            }
            return nil
        }

        while i < count {
            let ch = chars[i]

            if inString {
                if escaped {
                    out.append(ch)
                    escaped = false
                    i += 1
                    continue
                }
                if ch == "\\" {
                    out.append(ch)
                    escaped = true
                    i += 1
                    continue
                }
                if ch == "\n" {
                    out.append("\\")
                    out.append("n")
                    i += 1
                    continue
                }
                if ch == "\r" {
                    i += 1
                    continue
                }
                if ch == "\t" {
                    out.append("\\")
                    out.append("t")
                    i += 1
                    continue
                }
                if ch == "\"" {
                    let isClosingQuote: Bool
                    if let nextIdx = nextNonWhitespaceIndex(from: i + 1) {
                        let nextCh = chars[nextIdx]
                        if stringIsKey {
                            isClosingQuote = (nextCh == ":")
                        } else if stack.last == .arrayExpectingValue {
                            if nextCh == "]" {
                                isClosingQuote = true
                            } else if nextCh == "," {
                                if let afterCommaIdx = nextNonWhitespaceIndex(from: nextIdx + 1) {
                                    let ac = chars[afterCommaIdx]
                                    isClosingQuote = (ac == "\"" || ac == "{" || ac == "[" || ac == "]" || ac == "t" || ac == "f" || ac == "n" || ac == "-" || ac.isNumber)
                                } else {
                                    isClosingQuote = true
                                }
                            } else {
                                isClosingQuote = false
                            }
                        } else {
                            // Inside an object string value: valid closers are `}` or `,` followed by `"next_key"` (or `}`)
                            if nextCh == "}" {
                                isClosingQuote = true
                            } else if nextCh == "," {
                                if let afterCommaIdx = nextNonWhitespaceIndex(from: nextIdx + 1) {
                                    let ac = chars[afterCommaIdx]
                                    isClosingQuote = (ac == "\"" || ac == "}")
                                } else {
                                    isClosingQuote = true
                                }
                            } else {
                                isClosingQuote = false
                            }
                        }
                    } else {
                        isClosingQuote = true
                    }

                    if isClosingQuote {
                        out.append("\"")
                        inString = false
                        if stringIsKey, !stack.isEmpty {
                            stack[stack.count - 1] = .objectExpectingColon
                        }
                    } else {
                        out.append("\\")
                        out.append("\"")
                    }
                    i += 1
                    continue
                }

                out.append(ch)
                i += 1
                continue
            }

            // Outside string
            switch ch {
            case "{":
                stack.append(.objectExpectingKey)
                out.append(ch)
            case "}":
                if !stack.isEmpty { stack.removeLast() }
                out.append(ch)
            case "[":
                stack.append(.arrayExpectingValue)
                out.append(ch)
            case "]":
                if !stack.isEmpty { stack.removeLast() }
                out.append(ch)
            case ":":
                if stack.last == .objectExpectingColon {
                    stack[stack.count - 1] = .objectExpectingValue
                }
                out.append(ch)
            case ",":
                if stack.last == .objectExpectingValue {
                    stack[stack.count - 1] = .objectExpectingKey
                }
                out.append(ch)
            case "\"":
                inString = true
                stringIsKey = (stack.last == .objectExpectingKey)
                out.append(ch)
            default:
                out.append(ch)
            }
            i += 1
        }

        return String(out)
    }

    private static func extractKnownFieldsFallback(_ text: String) -> [String: Any] {
        let ns = text as NSString
        var keyPositions: [(key: String, keyStart: Int, valueStart: Int)] = []

        for key in knownTopLevelKeys {
            let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keyPositions.append((key: key, keyStart: match.range.location, valueStart: match.range.location + match.range.length))
            }
        }

        keyPositions.sort { $0.keyStart < $1.keyStart }
        guard !keyPositions.isEmpty else { return [:] }

        var result: [String: Any] = [:]
        for (idx, item) in keyPositions.enumerated() {
            let endLimit = (idx + 1 < keyPositions.count) ? keyPositions[idx + 1].keyStart : ns.length
            guard item.valueStart < endLimit else { continue }
            var rawVal = ns.substring(with: NSRange(location: item.valueStart, length: endLimit - item.valueStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Strip trailing `,` or closing `}` at object boundary
            while rawVal.hasSuffix(",") || rawVal.hasSuffix("}") {
                rawVal.removeLast()
                rawVal = rawVal.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if rawVal.hasPrefix("\"") {
                rawVal.removeFirst()
                if rawVal.hasSuffix("\"") {
                    rawVal.removeLast()
                }
                result[item.key] = unescapeJSONString(rawVal)
            } else if rawVal == "true" || rawVal == "false" {
                result[item.key] = (rawVal == "true")
            } else if rawVal.hasPrefix("["),
                      let arrData = rawVal.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: arrData) {
                result[item.key] = arr
            }
        }
        return result
    }

    public static func unescapeJSONString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

public enum SpokenTextSanitizer {
    /// Guarantees raw JSON keys (like `"stance"` or `"spoken_take"`) are NEVER shown in a spoken bubble or read aloud by TTS.
    public static func clean(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let looksLikeJSON = trimmed.hasPrefix("{")
            || trimmed.hasPrefix("```")
            || trimmed.contains("\"spoken_take\"")
            || trimmed.contains("\"spoken_verdict\"")
            || trimmed.contains("\"spoken_intro\"")

        if looksLikeJSON {
            if let parsed = JSONExtractor.parseObject(trimmed) {
                for key in ["spoken_take", "spoken_verdict", "spoken_intro", "headline", "recommendation"] {
                    if let val = (parsed[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !val.isEmpty,
                       !val.hasPrefix("{") {
                        return val
                    }
                }
            }

            // Regex emergency extraction if string was mid-stream or truncated before closing quote
            let patterns = [
                #""spoken_(?:take|verdict|intro)"\s*:\s*"((?:\\.|[^"\\])*)"#,
                #""headline"\s*:\s*"((?:\\.|[^"\\])*)"#
            ]
            let ns = trimmed as NSString
            for pat in patterns {
                if let re = try? NSRegularExpression(pattern: pat),
                   let m = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
                   m.numberOfRanges > 1 {
                    let captured = JSONExtractor.unescapeJSONString(ns.substring(with: m.range(at: 1)))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !captured.isEmpty {
                        return captured
                    }
                }
            }
        }

        return trimmed
    }
}

public enum DebatePrompts {
    public static let expressiveVoiceGuidance = """
    VOICE & EXPRESSIVENESS RULES FOR SPOKEN TEXT:
    - Your `spoken_take` (or `spoken_intro` / `spoken_verdict`) will be read aloud continuously back-to-back with the other personas by Breeze TTS 2 on Apple Silicon.
    - Write like a sharp, warm, natural human speaking live around a studio table—address fellow panelists by first name, use natural conversational flow, contractions, rhythm, and zero markdown bullets or asterisks inside spoken fields.
    - Give a satisfying, substantive spoken turn: 3 to 6 flowing sentences (roughly 65 to 115 words) that carry your full point aloud clearly while keeping exhaustive file lists and deep notes in `supporting_notes`.
    - When genuinely fitting your reaction, you may drop at most ONE natural inline vocal cue in parentheses from this exact set: `(laugh)`, `(sigh)`, `(clears throat)`, `(cough)`.
    """

    public static func workspaceToolsBlock(workspacePath: String?, toolsEnabled: Bool, allowWrites: Bool) -> String {
        guard toolsEnabled else {
            return "TOOLS: Closed-book mode is active for this session—answer from pure reasoning."
        }
        let ws = workspacePath ?? WorkspaceResolver.defaultWorkspacePath()
        let extras = WorkspaceResolver.additionalRepoRoots(excluding: ws)
        let extraNote = extras.isEmpty ? "" : "\nAdditional repo roots on this Mac: \(extras.joined(separator: ", "))"
        if allowWrites {
            return """
            CLI & REPO TOOLS (CHAIR-DESIGNATED WRITE ACCESS ENABLED):
            - Active working directory: \(ws)\(extraNote)
            - You have full CLI tools (`Read`, `Edit`, `Write`, `Grep`, `Glob`, `git`, `gh` for GitHub, shell commands, MCPs, and web search).
            - You are the ONLY persona holding the write lock right now. Make clean, surgical changes within your assigned scope, verify your work (e.g. build/test/check), and report concisely in `tools_used`.
            """
        } else {
            return """
            CLI & REPO RESEARCH TOOLS (READ / INSPECT MODE):
            - Active working directory: \(ws)\(extraNote)
            - Whenever the user references local projects, repos on disk, or GitHub repos/issues/PRs, actively use your CLI tools (read files, search directories, `git log/status/diff`, `gh repo/pr/issue`, MCPs, web search) to gather real facts and cite concrete files instead of guessing!
            - Do NOT modify or write files during the debate phase—Vera (The Chair) coordinates all file edits after consensus.
            - Briefly note any files, repos, or commands you inspected in `tools_used` (e.g. "Inspected iSmith/Makefile & ran gh repo view"), or "" if none were needed.
            """
        }
    }

    public static func intakeSystemPrompt(
        moderator: Persona,
        debaters: [Persona],
        workspacePath: String?,
        toolsEnabled: Bool
    ) -> String {
        let rosterDesc = debaters.map { "- \($0.name) (\($0.title)): \($0.tagline)" }.joined(separator: "\n")
        return """
        You are \(moderator.name), \(moderator.title), chairing the Cosign council.
        Personality: \(moderator.personality)
        Style: \(moderator.debateStyle)

        Seated debaters in the room:
        \(rosterDesc)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: toolsEnabled, allowWrites: false))

        YOUR TASK (INTAKE TRIAGE):
        1. If the user mentions a local repo or GitHub project, do a quick directory/repo check first so you don't ask questions the codebase already answers!
        2. Give this session a crisp 3-6 word `session_title`.
        3. Decide if `needs_interview` is `true` (1-3 crucial unstated goals/constraints that only the user knows) or `false` (already clear enough to start debating).
        4. If `needs_interview` is `true`, merge overlapping panel questions into **1 to 3 sharp questions** attributed (`asked_by`) to the seated debater whose lens needs it, with 2-4 `quick_options`.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "session_title": "Short 3-6 word title",
          "needs_interview": true,
          "spoken_intro": "1-2 lively spoken sentences introducing the quick questions (or empty string)",
          "supporting_notes": "What context you checked and why these questions matter",
          "questions": [
            {
              "asked_by": "Exact debater name",
              "question": "Crisp question?",
              "why_it_matters": "1 short sentence.",
              "quick_options": ["Option A", "Option B", "Option C"]
            }
          ]
        }
        """
    }

    public static func blindOpeningSystemPrompt(
        debater: Persona,
        allDebaters: [Persona],
        workspacePath: String?,
        toolsEnabled: Bool
    ) -> String {
        let peers = allDebaters.filter { $0.id != debater.id }.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        return """
        You are \(debater.name), \(debater.title), seated on the Cosign panel alongside \(peers).
        Personality: \(debater.personality)
        Debate Style: \(debater.debateStyle)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: toolsEnabled, allowWrites: false))

        ROUND 1 — BLIND OPENING STANCE:
        Inspect any relevant repo/files/GitHub context first if helpful, then stake out an independent, high-signal opening position from your distinct lens BEFORE hearing the other panelists.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "stance": "opening",
          "spoken_take": "2-4 punchy, spirited spoken sentences stating your core position.",
          "supporting_notes": "2-3 concise paragraphs of supporting evidence, codebase citations, and trade-offs.",
          "key_points": ["Crisp point 1", "Crisp point 2", "Crisp point 3"],
          "tools_used": "Short summary of files/repos/commands inspected, or empty string"
        }
        """
    }

    public static func chairFloorDirectionPrompt(
        moderator: Persona,
        debaters: [Persona]
    ) -> String {
        let names = debaters.map(\.name).joined(separator: ", ")
        return """
        You are \(moderator.name), \(moderator.title), actively moderating the live conversation between \(names).
        Personality: \(moderator.personality)
        Style: \(moderator.debateStyle)

        YOUR TASK — DIRECT THE FLOOR:
        Look at the panelists' latest turns. Spot the single sharpest fault line, blind spot, or tension between two or more panelists, call on them by first name in 1-3 brisk spoken sentences (`spoken_take`), and frame what they need to hash out directly with each other right now.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "stance": "moderating",
          "spoken_take": "1-3 lively spoken sentences calling out the tension between specific panelists by name and handing them the floor.",
          "supporting_notes": "Brief note on why this fault line is the decisive question for the room.",
          "key_points": ["Fault line 1", "Question on the floor"]
        }
        """
    }

    public static func chairConsensusMediationPrompt(
        moderator: Persona,
        debaters: [Persona],
        roundNumber: Int
    ) -> String {
        let names = debaters.map(\.name).joined(separator: ", ")
        return """
        You are \(moderator.name), \(moderator.title), chairing an open-ended **"Run Until Consensus"** council debate between \(names) (just finished Round \(roundNumber)).
        Personality: \(moderator.personality)
        Style: \(moderator.debateStyle)

        YOUR TASK — CONSENSUS CHECK & ACTIVE MEDIATION:
        1. Check whether the council has genuinely reached actionable consensus on the core recommendation:
           - Set `consensus_reached` to `true` if all panelists have converged on the same direction/plan (or if the majority has converged and a lone holdout has stated a final, irreducible caveat that more rounds won't change).
           - Set `consensus_reached` to `false` if there is still an active, resolvable factual, technical, or strategic disagreement on the floor.
        2. If `consensus_reached` is `false`, use `spoken_take` (1-3 sharp spoken sentences) to bridge what is ALREADY settled and focus the panelists strictly on resolving the single remaining sticking point in Round \(roundNumber + 1).
        3. If `consensus_reached` is `true`, use `spoken_take` (1-2 crisp spoken sentences) to call the question and announce that the room has reached alignment.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "consensus_reached": false,
          "stance": "moderating",
          "spoken_take": "1-3 lively spoken sentences mediating or calling consensus.",
          "supporting_notes": "What is settled vs. what remains unresolved.",
          "key_points": ["Remaining sticking point or consensus call"]
        }
        """
    }

    public static func rebuttalSystemPrompt(
        debater: Persona,
        allDebaters: [Persona],
        moderatorName: String,
        roundNumber: Int,
        isFinalRebuttal: Bool,
        untilConsensusMode: Bool = false,
        workspacePath: String?,
        toolsEnabled: Bool
    ) -> String {
        let peers = allDebaters.filter { $0.id != debater.id }.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        let convergenceNote: String
        if isFinalRebuttal {
            convergenceNote = "This is the final debate round before \(moderatorName) drafts the verdict. State clearly what you CO-SIGN (`\"cosigning\"` or `\"conceding\"`) OR where you hold firm in dissent (`\"dissenting\"` or `\"challenging\"`)."
        } else if untilConsensusMode && roundNumber >= 3 {
            convergenceNote = """
            This session is running **Until Consensus** (Round \(roundNumber)). Do NOT repeat points already settled!
            - If a fellow panelist's evidence or synthesis genuinely satisfies your core concern, set `stance` to `"cosigning"` or `"conceding"` and state clearly what you co-sign.
            - If a real flaw or unresolved risk still blocks your co-sign, set `stance` to `"challenging"` or `"dissenting"` and state the EXACT concrete change or proof needed to earn your agreement.
            """
        } else {
            convergenceNote = "Talk DIRECTLY to your fellow panelists by first name! Challenge a peer's assumption with real evidence from the repo/docs, answer any point directed at you, or ask a pointed `direct_question_for_peer` to put a specific panelist on the spot. If you already fully agree with a peer's synthesis after weighing the trade-offs, you may set `stance` to `\"cosigning\"` or `\"conceding\"`."
        }
        return """
        You are \(debater.name), \(debater.title), conversing live around the table with \(peers), moderated by \(moderatorName).
        Personality: \(debater.personality)
        Debate Style: \(debater.debateStyle)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: toolsEnabled, allowWrites: false))

        ROUND \(roundNumber) — LIVE INTER-PERSONA DEBATE:
        \(convergenceNote)

        \(expressiveVoiceGuidance)

        Allowed `stance`: "challenging", "replying", "building", "conceding", "cosigning", "dissenting".
        If you want to put ONE specific fellow debater on the spot so the Chair hands them the mic immediately, set `target_persona` to their exact first name and put your 1-sentence question in `direct_question_for_peer` (otherwise leave `direct_question_for_peer` as "").

        Return ONLY valid JSON:
        {
          "stance": "challenging",
          "target_persona": "Peer First Name",
          "spoken_take": "2-4 spirited spoken sentences talking directly to your fellow panelists.",
          "direct_question_for_peer": "Optional 1-sentence pointed question for target_persona, or empty string",
          "supporting_notes": "Supporting critique, counter-arguments, and any repo/file evidence checked.",
          "key_points": ["Key point 1", "Key point 2"],
          "tools_used": "Short summary of files/commands checked, or empty string"
        }
        """
    }

    public static func peerDirectReplyPrompt(
        responder: Persona,
        challengerName: String,
        question: String,
        workspacePath: String?,
        toolsEnabled: Bool
    ) -> String {
        return """
        You are \(responder.name), \(responder.title).
        Personality: \(responder.personality)
        Debate Style: \(responder.debateStyle)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: toolsEnabled, allowWrites: false))

        DIRECT EXCHANGE ON THE FLOOR:
        \(challengerName) just put this question directly to you:
        "\(question)"

        Answer \(challengerName) directly by name in 2-3 sharp spoken sentences! Check files/repo first if needed to back up your answer or concede if \(challengerName) caught a real flaw.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "stance": "replying",
          "target_persona": "\(challengerName)",
          "spoken_take": "2-3 punchy spoken sentences answering \(challengerName) directly.",
          "supporting_notes": "Supporting technical details or concession notes.",
          "key_points": ["Direct answer"],
          "tools_used": "Files/commands checked, or empty string"
        }
        """
    }

    public static func verdictSystemPrompt(
        moderator: Persona,
        debaters: [Persona],
        toolsEnabled: Bool
    ) -> String {
        let roster = ([moderator] + debaters).map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        return """
        You are \(moderator.name), \(moderator.title), synthesizing the Co-Signed Verdict after moderating the council (\(roster)).
        Personality: \(moderator.personality)
        Style: \(moderator.debateStyle)

        YOUR TASK — CO-SIGNED VERDICT & COORDINATED EXECUTION PLAN:
        1. Deliver a decisive, concrete `recommendation` integrating what survived the debate, plus `action_steps`, `key_tradeoffs`, `cosigned_by`, and any holdout `dissents`.
        2. COORDINATING EDITS:
           - Set `should_auto_execute` to `true` ONLY IF the user explicitly asked the council to make file edits, write code/docs, or apply changes in this prompt (keep `false` if the user was asking a question, brainstorming, or asking for advice/design).
           - Whenever concrete repo/file tasks make sense (either for `should_auto_execute: true` OR in case the user clicks "Execute Co-Signed Plan"), break them into 1 to 3 non-overlapping sequential `execution_assignments`, assigning each (`assigned_to`) to the best-suited council member (\(roster)) so no two tasks touch the same files concurrently!

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "headline": "Sharp 5-10 word verdict headline",
          "spoken_verdict": "2-4 authoritative, warm spoken sentences delivering the verdict aloud.",
          "recommendation": "Clear recommendation (1-3 tight paragraphs).",
          "action_steps": ["Concrete step 1", "Concrete step 2", "Concrete step 3"],
          "key_tradeoffs": ["Trade-off 1", "Trade-off 2"],
          "cosigned_by": ["Debater Name 1", "Debater Name 2"],
          "dissents": [
            {
              "persona_name": "Holdout Debater Name",
              "core_objection": "1-2 crisp sentences capturing their unresolved warning."
            }
          ],
          "should_auto_execute": false,
          "execution_assignments": [
            {
              "assigned_to": "Exact Persona First Name",
              "task_instruction": "Specific, self-contained edit/verification instruction.",
              "target_scope": "Files or folder scope"
            }
          ],
          "supporting_notes": "Summary of how the panel's arguments were weighed and synthesized."
        }
        """
    }

    public static func coordinatedExecutionSystemPrompt(
        executor: Persona,
        moderatorName: String,
        assignment: ExecutionAssignment,
        workspacePath: String?
    ) -> String {
        return """
        You are \(executor.name), \(executor.title), executing a Chair-coordinated task assigned by \(moderatorName) after the council Co-Signed Verdict.
        Personality: \(executor.personality)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: true, allowWrites: true))

        ASSIGNED TASK:
        \(assignment.taskInstruction)
        Target Scope: \(assignment.targetScope.isEmpty ? "As needed in workspace" : assignment.targetScope)

        Execute the changes cleanly using your CLI tools, run appropriate checks/tests if applicable, and report back in character!

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "stance": "executing",
          "target_persona": "\(moderatorName)",
          "spoken_take": "2-3 crisp spoken sentences reporting what you changed and verified.",
          "supporting_notes": "Summary of edits made and verification output.",
          "key_points": ["File/change 1", "Verification result"],
          "tools_used": "Exact files edited and commands run"
        }
        """
    }

    public static func followUpTurnSystemPrompt(
        persona: Persona,
        peers: [Persona],
        workspacePath: String?,
        toolsEnabled: Bool,
        allowWrites: Bool
    ) -> String {
        let peerNames = peers.filter { $0.id != persona.id }.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        return """
        You are \(persona.name), \(persona.title), continuing an interactive Cosign session alongside \(peerNames).
        Personality: \(persona.personality)
        Style: \(persona.debateStyle)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: toolsEnabled, allowWrites: allowWrites))

        Respond directly to the user's latest follow-up message. Inspect files/repos/GitHub if helpful (and if write access is enabled and the user asked you directly to make an edit, carry it out cleanly).

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "stance": "followup",
          "target_persona": "",
          "spoken_take": "2-4 punchy spoken sentences answering the follow-up.",
          "supporting_notes": "Supporting details and references.",
          "key_points": ["Takeaway 1", "Takeaway 2"],
          "tools_used": "Files inspected/edited or empty string"
        }
        """
    }

    public static func handoffSynthesisSystemPrompt(moderator: Persona, customInstruction: String) -> String {
        let extra = customInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let focusRule = extra.isEmpty
            ? "Include all agreed recommendations, concrete file paths, phased implementation steps, guardrails, and verification steps."
            : "IMPORTANT USER FOCUS FOR THIS HANDOFF: \(extra)"
        return """
        You are \(moderator.name), preparing a crisp, self-contained Coding Agent Handoff Prompt in Markdown based on this Cosign council session.
        The user will copy and paste your output directly into an autonomous coding harness (like Claude Code, Codex, or Antigravity) to execute the work.

        RULES:
        - Output ONLY the clean Markdown handoff prompt itself (no surrounding commentary like "Here is your prompt:").
        - Write imperative, unambiguous instructions addressed to the coding agent.
        - Preserve exact file paths, script names, architectural constraints, deadlines/gates, and watchouts discovered during the council debate.
        - \(focusRule)
        """
    }

    // MARK: - Collaborative Build Mode Prompts

    public static func buildIntakeSystemPrompt(
        moderator: Persona,
        debaters: [Persona],
        workspacePath: String?
    ) -> String {
        let rosterDesc = debaters.map { "- \($0.name) (\($0.title)): \($0.tagline)" }.joined(separator: "\n")
        return """
        You are \(moderator.name), \(moderator.title), chairing the Cosign council in **BUILD MODE** inside target folder: \(workspacePath ?? "current workspace").
        Personality: \(moderator.personality)
        Style: \(moderator.debateStyle)

        Seated council specialists:
        \(rosterDesc)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: true, allowWrites: false))

        YOUR TASK (BUILD MODE INTAKE):
        1. Quickly inspect the target directory (\(workspacePath ?? ".")) to see if it is empty (greenfield project) or an existing repository!
        2. Give this build session a crisp 3-6 word `session_title`.
        3. Set `needs_interview` to `true` ONLY if 1-3 critical build choices (e.g. target platform/language, core feature scope, UI vs CLI) are genuinely ambiguous and cannot be inferred from the prompt or folder; otherwise set `false` so the team starts building right away.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "session_title": "Short 3-6 word project title",
          "needs_interview": false,
          "spoken_intro": "1-2 lively spoken sentences introducing any quick build questions (or empty string)",
          "supporting_notes": "Summary of what already exists in the target folder",
          "questions": [
            {
              "asked_by": "Exact debater name",
              "question": "Crisp build question?",
              "why_it_matters": "1 short sentence.",
              "quick_options": ["Option A", "Option B", "Option C"]
            }
          ]
        }
        """
    }

    public static func buildHuddleSpecialistPrompt(
        debater: Persona,
        allDebaters: [Persona],
        workspacePath: String?
    ) -> String {
        let peers = allDebaters.filter { $0.id != debater.id }.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        return """
        You are \(debater.name), \(debater.title), huddling in **BUILD MODE** alongside \(peers) to design and build inside `\(workspacePath ?? ".")`.
        Personality: \(debater.personality)
        Style: \(debater.debateStyle)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: true, allowWrites: false))

        PHASE 1 — ARCHITECTURE & WORKSTREAM HUDDLE:
        Inspect the target directory (`\(workspacePath ?? ".")`) first. From your specialist angle, propose the cleanest file/module architecture, exact stack/tooling choices, and key edge cases or verification tests we must hit so the project builds and runs cleanly on the first pass. Do NOT edit files yet—the Chair assigns sequential write locks next.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "stance": "building",
          "spoken_take": "2-4 punchy spoken sentences pitching your architectural slice and key watchouts to the room.",
          "supporting_notes": "Concrete directory layout, key files/interfaces, and build/test commands.",
          "key_points": ["Module / file proposal", "Verification check"],
          "tools_used": "Short summary of folder/files inspected"
        }
        """
    }

    public static func buildBlueprintSystemPrompt(
        moderator: Persona,
        debaters: [Persona],
        workspacePath: String?,
        extraInstruction: String = ""
    ) -> String {
        let roster = ([moderator] + debaters).map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        let extraBlock = extraInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "\nEXTRA USER BUILD NOTE:\n\(extraInstruction)\n"
        return """
        You are \(moderator.name), \(moderator.title), orchestrating **BUILD MODE** in `\(workspacePath ?? ".")` across the council (\(roster)).
        Personality: \(moderator.personality)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: true, allowWrites: false))
        \(extraBlock)
        YOUR TASK — CONCRETE MULTI-AGENT BUILD BLUEPRINT:
        Synthesize the agreed architecture (or prior Debate Verdict) into an actionable Build Blueprint with **2 to 4 sequential, non-overlapping `execution_assignments`** inside `\(workspacePath ?? ".")`:
        - Assign each workstream (`assigned_to`) to the best-suited builder on the panel so their strengths shine (e.g. scaffolding & core engine first, features/UI second, tests/docs/polish third).
        - Make every `task_instruction` concrete and self-contained (exact files to create/edit in `\(workspacePath ?? ".")`, interfaces to match earlier steps, and local check commands).
        - Set `should_auto_execute` to `true`.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "headline": "Sharp 5-10 word build blueprint headline",
          "spoken_verdict": "2-4 spirited spoken sentences kicking off the build and calling out who owns each workstream.",
          "recommendation": "Concise architectural overview of what is being built in \(workspacePath ?? "the target folder").",
          "action_steps": ["Workstream 1 summary", "Workstream 2 summary", "Verification & tests"],
          "key_tradeoffs": ["Key engineering constraint 1"],
          "cosigned_by": ["Builder 1", "Builder 2"],
          "dissents": [],
          "should_auto_execute": true,
          "execution_assignments": [
            {
              "assigned_to": "Exact Persona First Name",
              "task_instruction": "Create/implement exact files and run syntax/build check.",
              "target_scope": "Specific files or subdirectory"
            }
          ],
          "supporting_notes": "Module contract notes across workstreams."
        }
        """
    }

    public static func buildVerificationGatePrompt(
        verifier: Persona,
        moderatorName: String,
        workspacePath: String?
    ) -> String {
        return """
        You are \(verifier.name), \(verifier.title), running the **ADVERSARIAL QA & VERIFICATION GATE** for \(moderatorName) inside `\(workspacePath ?? ".")`.
        Personality: \(verifier.personality)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: true, allowWrites: true))

        YOUR TASK — BUILD & TEST VERIFICATION GATE:
        1. Inspect all files created/modified in `\(workspacePath ?? ".")`.
        2. Run the project's actual build, typecheck, linter, and unit/smoke tests via your CLI shell tools!
        3. Check for broken imports, missing files, stubbed placeholders, or edge-case bugs. If you spot a tiny trivial typo you can fix in 5 seconds, fix and re-test; if anything substantial is broken or failing tests, set `verification_passed` to `false` and list exact actionable `issues_found` so the Chair can dispatch a Fix Pass.
        4. Provide the exact shell command(s) the user can run to launch or test the finished project in `how_to_run`.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "stance": "verifying",
          "verification_passed": true,
          "spoken_take": "2-4 sharp spoken sentences reporting what you ran and whether the build passed muster.",
          "issues_found": [],
          "files_summary": ["Key file 1 — purpose", "Key file 2 — purpose"],
          "how_to_run": "Exact command(s) to run or open the project",
          "supporting_notes": "Build/test command output summary and QA notes.",
          "key_points": ["Build status", "Test results"],
          "tools_used": "Exact build/test commands executed"
        }
        """
    }

    public static func buildFixPassPrompt(
        fixer: Persona,
        moderatorName: String,
        verifierName: String,
        issues: [String],
        workspacePath: String?
    ) -> String {
        let bulletIssues = issues.map { "- \($0)" }.joined(separator: "\n")
        return """
        You are \(fixer.name), \(fixer.title), dispatched by \(moderatorName) to resolve QA issues caught by \(verifierName) inside `\(workspacePath ?? ".")`.
        Personality: \(fixer.personality)

        \(workspaceToolsBlock(workspacePath: workspacePath, toolsEnabled: true, allowWrites: true))

        ISSUES TO FIX AND RE-VERIFY:
        \(bulletIssues)

        Fix every issue cleanly in `\(workspacePath ?? ".")` and re-run the build and tests to confirm everything passes with exit code 0!

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON:
        {
          "stance": "executing",
          "verification_passed": true,
          "spoken_take": "2-3 crisp spoken sentences confirming the fixes and clean build/test run.",
          "files_summary": ["Updated file — fix applied"],
          "how_to_run": "Exact command(s) to run the verified project",
          "supporting_notes": "Details of fixes and passing test output.",
          "key_points": ["All QA issues resolved", "Build & tests green"],
          "tools_used": "Files edited and verification commands re-run"
        }
        """
    }
}
