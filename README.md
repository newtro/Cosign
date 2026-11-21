# Cosign

**Cosign** is a native macOS AI council chamber that seats **3 customizable Debaters + 1 Moderator** across your existing frontier AI subscriptions (`claude`, `codex`, and `agy` / Gemini, plus optional OpenRouter).

Instead of dumping walls of homogeneous text from a single model, Cosign interviews you on missing details when an idea is half-baked, runs blind parallel opening stances across distinct model families, cross-examines assumptions in spirited multi-round debates, speaks every turn aloud locally on Apple Silicon using **Breeze TTS 2** (`mlx-audio`), and either delivers a decisive **Co-Signed Verdict** or collaboratively builds & verifies real projects in **Build Mode**.

## Highlights

- **Debate Mode + Collaborative Build Mode:** Toggle between **Debate** and **Build** right in the composer—or click **Build This Plan…** on any finished Debate Verdict to select or create a local folder, assign sequential multi-agent workstreams, run an adversarial QA & test verification gate, and auto-fix any issues.
- **Full Subscription CLI & Repo/GitHub Tools:** Personas run `claude`, `codex`, and `agy` against your active workspace folder (with automatic multi-root repo discovery, `git`, `gh` for GitHub, MCP servers, and web search).
- **Chair-Directed Live Dialogue & Coordinated Edits:** Panelists challenge and question each other directly on the floor moderated by **Vera (The Chair)**. During debates, file-edit tools are locked out so parallel agents never collide; during Build Mode, **Vera coordinates sequential single-writer execution** followed by **Sable's QA & verification gate**.
- **Live Provider Model Discovery:** Automatically surfaces the latest models available on each subscription (`agy models`, Codex model cache, Claude model catalog, and optional OpenRouter) right inside the **Persona Studio**.
- **Smart Intake Interview → Automatic Debate → Co-Sign:** Deduplicates missing context into 1–3 high-impact questions (with 1-click option chips, freeform/dictated replies, or *"Not sure — debate this for me"*), then flows automatically through Blind Openings, Cross-Examination, and Verdict.
- **Compact Two-Layer Cards & Coding-Harness Handoff:** Every turn displays a crisp spoken take with a 1-click expandable **Thought Process** drawer, plus a **Handoff Prompt** generator ready to copy into Claude Code, Codex, or Antigravity.
- **100% Local Studio Human Voices (Breeze TTS 2):** Powered by **Breeze TTS 2** (`mlx-community/Breeze-TTS-2-mlx-8bit` via `mlx-audio`) on Apple Silicon Metal with locked reference-voice consistency, natural inline vocal cues (`(laugh)`, `(sigh)`, `(clears throat)`, `(cough)`), and zero cloud TTS fees.
- **Signed & Auto-Updating:** Built with XcodeGen, Developer ID notarization, and Sparkle 2 automatic updates.

## Build & Run

```sh
make icons      # Generate macOS app icons (Release + Dev)
make test       # Run CosignCore, CosignVoice, and app-hosted tests
make run        # Build and launch "Cosign Dev" (isolated from /Applications/Cosign.app)
make install    # Build Release and install /Applications/Cosign.app
```

## Releasing Updates

```sh
Tools/release.sh 1.0.0
```
