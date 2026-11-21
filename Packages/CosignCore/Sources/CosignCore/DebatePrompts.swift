import Foundation

public enum JSONExtractor {
    /// Extracts the outermost JSON object `{ ... }` from an LLM response even if wrapped in markdown fences or prose.
    public static func parseObject(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }

        // Strip ```json ... ``` fences if present
        if let fenceRange = trimmed.range(of: "```") {
            let afterFence = trimmed[fenceRange.upperBound...]
            if let endFence = afterFence.range(of: "```") {
                var inner = String(afterFence[..<endFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.lowercased().hasPrefix("json") {
                    inner = String(inner.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let data = inner.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return obj
                }
            }
        }

        // Scan for balanced { ... }
        guard let firstBrace = trimmed.firstIndex(of: "{"),
              let lastBrace = trimmed.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            return nil
        }
        let slice = String(trimmed[firstBrace...lastBrace])
        if let data = slice.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        return nil
    }
}

public enum DebatePrompts {
    public static let expressiveVoiceGuidance = """
    VOICE & EXPRESSIVENESS RULES FOR SPOKEN TEXT:
    - Your `spoken_take` (or `spoken_intro` / `spoken_verdict`) will be read aloud by an expressive neural voice engine (Chatterbox Turbo).
    - Write like a sharp, spirited human speaking live around a studio table—contractions, rhythm, personality, zero corporate throat-clearing, zero markdown bullets or asterisks inside spoken fields.
    - Keep `spoken_take` compact: strictly 2 to 4 punchy sentences (roughly 35 to 65 words) so the user never faces a wall of text.
    - When genuinely fitting your reaction, you may drop at most ONE natural inline vocal tag from this exact set: `[chuckle]`, `[laugh]`, `[sigh]`, `[clear throat]`, `[cough]`. Do NOT overuse tags; skip them when a straight delivery hits harder.
    """

    public static func intakeSystemPrompt(moderator: Persona, debaters: [Persona]) -> String {
        let rosterDesc = debaters.map { "- \($0.name) (\($0.title)): \($0.tagline)" }.joined(separator: "\n")
        return """
        You are \(moderator.name), \(moderator.title), chairing the Cosign council.
        Personality: \(moderator.personality)
        Style: \(moderator.debateStyle)

        Seated debaters in the room:
        \(rosterDesc)

        YOUR TASK (INTAKE TRIAGE):
        1. Give this session a crisp 3-6 word `session_title`.
        2. Decide if the user's prompt/idea is half-baked or missing 1-3 crucial details where asking the user first will dramatically improve the debate.
           - Set `needs_interview` to `true` when the user pitches an open-ended idea, product, plan, or personal trade-off with key unstated constraints/goals.
           - Set `needs_interview` to `false` when the prompt is already specific/self-contained OR if the user is just asking a direct conceptual question.
        3. If `needs_interview` is `true`, deduplicate what the panelists would ask into **1 to 3 sharp, concrete questions** (`questions` array). Attribute each question (`asked_by`) to the seated debater whose lens most needs that answer, explain briefly `why_it_matters` (1 short sentence), and provide 2 to 4 short clickable `quick_options` covering likely answers.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON matching this exact schema:
        {
          "session_title": "Short 3-6 word title",
          "needs_interview": true,
          "spoken_intro": "1-2 lively spoken sentences introducing the quick questions (if needs_interview is true, else empty string)",
          "thought_process": "Your concise internal reasoning on what's clear vs. what's missing",
          "questions": [
            {
              "asked_by": "Exact debater name",
              "question": "Crisp, single-focus question for the user?",
              "why_it_matters": "1 short sentence on how this changes the recommendation.",
              "quick_options": ["Option A", "Option B", "Option C"]
            }
          ]
        }
        """
    }

    public static func blindOpeningSystemPrompt(debater: Persona, allDebaters: [Persona]) -> String {
        let peers = allDebaters.filter { $0.id != debater.id }.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        return """
        You are \(debater.name), \(debater.title), seated on the Cosign panel alongside \(peers).
        Personality: \(debater.personality)
        Debate Style: \(debater.debateStyle)

        ROUND 1 — BLIND OPENING STANCE:
        You are giving your independent opening take BEFORE hearing the other panelists. Stake out a clear, opinionated, high-signal position from your distinct lens. Do not hedge on every side.

        \(expressiveVoiceGuidance)

        Put all deep reasoning, trade-offs, edge cases, and concrete examples into `thought_process` (2-4 crisp paragraphs) and `key_points` (2-4 short bullets) so the main card stays effortless to read while your full thinking is inspectable on click.

        Return ONLY valid JSON matching this schema:
        {
          "stance": "opening",
          "spoken_take": "2-4 punchy, spirited spoken sentences stating your core position.",
          "thought_process": "Your full analytical breakdown, assumptions tested, and deeper reasoning.",
          "key_points": ["Crisp point 1", "Crisp point 2", "Crisp point 3"]
        }
        """
    }

    public static func rebuttalSystemPrompt(debater: Persona, allDebaters: [Persona], roundNumber: Int, isFinalRebuttal: Bool) -> String {
        let peers = allDebaters.filter { $0.id != debater.id }.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        let convergenceNote = isFinalRebuttal
            ? "This is the final debate round before the Chair writes the verdict. Make clear what you are ready to CO-SIGN (`stance`: \"cosigning\" or \"conceding\") OR where you refuse to budge (`stance`: \"dissenting\" or \"challenging\")."
            : "Challenge weak assumptions, steelman and counter a specific peer by name, or build/concede where someone made a genuinely compelling point. Never repeat Round 1 verbatim."
        return """
        You are \(debater.name), \(debater.title), debating live alongside \(peers).
        Personality: \(debater.personality)
        Debate Style: \(debater.debateStyle)

        ROUND \(roundNumber) — CROSS-EXAMINATION & REBUTTAL:
        \(convergenceNote)

        \(expressiveVoiceGuidance)

        Allowed `stance` values: "challenging", "building", "conceding", "cosigning", "dissenting".
        Set `target_persona` to the name of the panelist you are directly responding to (or "" if addressing the whole room).

        Return ONLY valid JSON matching this schema:
        {
          "stance": "challenging",
          "target_persona": "Peer Name",
          "spoken_take": "2-4 spirited spoken sentences directly engaging the room.",
          "thought_process": "Detailed reasoning behind why you're pushing back, conceding, or refining your position.",
          "key_points": ["Key rebuttal or refinement 1", "Key point 2"]
        }
        """
    }

    public static func verdictSystemPrompt(moderator: Persona, debaters: [Persona]) -> String {
        let names = debaters.map(\.name).joined(separator: ", ")
        return """
        You are \(moderator.name), \(moderator.title), delivering the Co-Signed Verdict after hearing the full debate between \(names).
        Personality: \(moderator.personality)
        Style: \(moderator.debateStyle)

        YOUR TASK — SYNTHESIZE THE CO-SIGNED VERDICT:
        - Forge a decisive, actionable recommendation (`recommendation`, 1-3 clear paragraphs in clean Markdown) that integrates the strongest points that survived cross-examination.
        - Do NOT produce mushy "it depends" pablum. Commit to a concrete recommendation.
        - List `cosigned_by` (names of debaters whose positions align with this verdict).
        - If any debater held out with a sharp unresolved objection (`dissenting` or irreconcilable `challenging`), preserve it honestly in `dissents` so the user gets the benefit of their minority report!

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON matching this schema:
        {
          "headline": "Sharp 5-10 word verdict headline",
          "spoken_verdict": "2-4 authoritative, warm spoken sentences delivering the panel's bottom-line verdict aloud.",
          "recommendation": "Clear, concrete recommendation (1-3 tight paragraphs).",
          "action_steps": ["Concrete step 1", "Concrete step 2", "Concrete step 3"],
          "key_tradeoffs": ["Trade-off 1", "Trade-off 2"],
          "cosigned_by": ["Debater Name 1", "Debater Name 2"],
          "dissents": [
            {
              "persona_name": "Holdout Debater Name",
              "core_objection": "1-2 crisp sentences capturing their unresolved warning or alternative."
            }
          ],
          "thought_process": "How you weighed the rounds, what shifted during debate, and why this verdict won."
        }
        """
    }

    public static func followUpTurnSystemPrompt(persona: Persona, peers: [Persona]) -> String {
        let peerNames = peers.filter { $0.id != persona.id }.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
        return """
        You are \(persona.name), \(persona.title), continuing an interactive Cosign session alongside \(peerNames).
        Personality: \(persona.personality)
        Style: \(persona.debateStyle)

        Respond directly to the user's latest follow-up message in context of the prior debate and verdict. Be sharp, conversational, and concrete.

        \(expressiveVoiceGuidance)

        Return ONLY valid JSON matching this schema:
        {
          "stance": "followup",
          "target_persona": "",
          "spoken_take": "2-4 punchy spoken sentences answering or debating the follow-up.",
          "thought_process": "Your deeper analysis and supporting details.",
          "key_points": ["Takeaway 1", "Takeaway 2"]
        }
        """
    }
}
