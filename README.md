# Cosign

**Cosign** is a native macOS AI council chamber that seats **3 customizable Debaters + 1 Moderator** across your existing frontier AI subscriptions (`claude`, `codex`, and `agy` / Gemini, plus optional OpenRouter).

Instead of dumping walls of homogeneous text from a single model, Cosign interviews you on missing details when an idea is half-baked, runs blind parallel opening stances across distinct model families, cross-examines assumptions in spirited multi-round debates, speaks every turn aloud locally on Apple Silicon using **Chatterbox Turbo** (`mlx-audio`), and delivers a decisive **Co-Signed Verdict** alongside any **Minority Dissent**.

## Highlights

- **Subscription-Backed Frontier Diversity:** Runs `claude`, `codex`, and `agy` inside isolated temporary `HOME` sandboxes so your personal skills, memories, and host sessions never pollute persona prompts—while automatically syncing refreshed OAuth tokens.
- **Live Provider Model Discovery:** Automatically surfaces the latest models available on each subscription (`agy models`, Codex model cache, Claude model catalog, and optional OpenRouter) right inside the **Persona Studio**.
- **Smart Intake Interview → Automatic Debate → Co-Sign:** Deduplicates missing context into 1–3 high-impact questions (with 1-click option chips, freeform/dictated replies, or *"Not sure — debate this for me"*), then flows automatically through Blind Openings, Cross-Examination, and Verdict.
- **Compact Two-Layer Cards:** Every turn displays a crisp 2–4 sentence spoken take in the main stream, with a 1-click expandable **Thought Process** drawer underneath so full reasoning is always transparent without clutter.
- **100% Local Expressive Voices:** Powered by **Chatterbox Turbo** on Apple Silicon Metal (`mlx-audio`) with inline vocal reactions (`[chuckle]`, `[sigh]`, `[laugh]`, `[clear throat]`) and zero cloud TTS fees.
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
