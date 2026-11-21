#!/usr/bin/env python3
"""Persistent Apple Silicon MLX Breeze TTS 2 worker for Cosign.

Reads JSON-line commands from stdin and emits JSON-line events on stdout.
Uses Breeze Voice Design to synthesize clean studio human reference anchors once per persona,
caches the encoded Qwen3-TTS reference codec tokens in Metal memory, and runs fast single-pass
Zero-Shot Voice Cloning on every turn so each persona keeps a natural, consistent human voice.
"""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
import time
import traceback

# Disable tqdm / HuggingFace progress bars so stderr/stdout pipes never saturate or block.
os.environ["TQDM_DISABLE"] = "1"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.environ["TRANSFORMERS_VERBOSITY"] = "error"

MODEL_REPO = os.environ.get("COSIGN_TTS_MODEL", "mlx-community/Breeze-TTS-2-mlx-8bit")
REFS_DIR = pathlib.Path(
    os.environ.get(
        "COSIGN_BREEZE_REFS_DIR",
        str(pathlib.Path.home() / "Library" / "Application Support" / "Cosign" / "BreezeRefs"),
    )
)

_PROTO_OUT = sys.stdout
_DEVNULL = open(os.devnull, "w")
sys.stdout = _DEVNULL

# Distinct, natural human studio voice anchors designed for Breeze TTS 2.
BREEZE_PRESETS: dict[str, dict] = {
    "vera": {
        "seed": 101,
        "instruct": "A warm, poised American woman in her thirties with a rich contralto studio host voice, natural breath, and calm conversational pacing.",
        "ref_text": "Welcome back to the studio. Let's look closely at the architecture and make a clear decision together.",
    },
    "marcus": {
        "seed": 202,
        "instruct": "A grounded, confident American man in his late thirties with a warm deep baritone voice, steady conversational rhythm, and clear studio presence.",
        "ref_text": "Keep the foundation simple first. Once the core loop compiles and passes tests, we can layer on everything else.",
    },
    "sable": {
        "seed": 303,
        "instruct": "A sharp, articulate British woman in her early thirties with a crisp alto voice, subtle dry wit, and expressive natural inflection.",
        "ref_text": "Hold on a second. Before everyone celebrates that design, let's check what happens when two processes hit disk at once.",
    },
    "orion": {
        "seed": 404,
        "instruct": "An engaging, thoughtful American man in his late twenties with a bright, warm tenor voice, curious energy, and natural storytelling flow.",
        "ref_text": "What if we flip the problem completely on its head and let the interface guide the workflow effortlessly?",
    },
    "lyra": {
        "seed": 505,
        "instruct": "A warm, empathetic American woman in her thirties with a clear mezzo voice, relaxed studio intimacy, and smooth natural cadence.",
        "ref_text": "When someone opens this screen for the first time, the hierarchy should feel calm, obvious, and inviting.",
    },
    "kael": {
        "seed": 606,
        "instruct": "A measured, composed British man in his forties with a smooth resonant baritone voice and unhurried analytical delivery.",
        "ref_text": "Look at the incentives over six months. That single constraint tells us where to draw the boundary.",
    },
    "ember": {
        "seed": 707,
        "instruct": "A spirited, confident American woman in her late twenties with a velvety expressive voice and lively conversational warmth.",
        "ref_text": "Don't water down the best part of the pitch. Lean right into what makes this project unmistakable.",
    },
    "sage": {
        "seed": 808,
        "instruct": "A seasoned, calm American man in his fifties with a deep warm resonant voice, relaxed pacing, and trustworthy counsel.",
        "ref_text": "I have seen teams build both versions of this system, and the simpler boundary wins every single time.",
    },
}

_BRACKET_TAG_RE = re.compile(r"[\[\(](chuckle|laugh|sigh|clears? throat|cough|gasp|groan)[\]\)]", re.IGNORECASE)
_SPOKEN_FIELD_RE = re.compile(r'"spoken_(?:take|verdict|intro)"\s*:\s*"((?:\\.|[^"\\])*)"', re.DOTALL)


def normalize_breeze_cues(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("{") or '"spoken_take"' in stripped or '"spoken_verdict"' in stripped:
        m = _SPOKEN_FIELD_RE.search(stripped)
        if m:
            stripped = m.group(1).replace('\\"', '"').replace("\\n", " ").strip()

    def _repl(match: re.Match) -> str:
        raw = match.group(1).lower()
        if raw in ("chuckle", "laugh"):
            return "(laugh)"
        if raw in ("clear throat", "clears throat"):
            return "(clears throat)"
        if raw == "cough":
            return "(cough)"
        return "(sigh)"

    cleaned = _BRACKET_TAG_RE.sub(_repl, stripped)
    return re.sub(r"  +", " ", cleaned).strip()


def emit(payload: dict) -> None:
    _PROTO_OUT.write(json.dumps(payload, ensure_ascii=False) + "\n")
    _PROTO_OUT.flush()


def trim_dead_air(audio, sample_rate: int):
    """Trims leading and trailing dead silence so speaker-to-speaker transitions have minimal pause."""
    import numpy as np

    if audio.size == 0:
        return audio
    abs_audio = np.abs(audio)
    active = np.where(abs_audio > 0.008)[0]
    if active.size == 0:
        return audio
    pad = int(sample_rate * 0.045)  # keep a natural 45ms breath at edges
    start = max(0, int(active[0]) - pad)
    end = min(len(audio), int(active[-1]) + pad)
    return audio[start:end]


def ensure_preset_ref_wav(model, preset_id: str, refs_dir: pathlib.Path) -> tuple[str, str]:
    """Returns `(ref_wav_path, ref_text)` for `preset_id`, generating it once via Breeze Voice Design if needed."""
    import numpy as np
    import soundfile as sf

    preset_key = preset_id if preset_id in BREEZE_PRESETS else "vera"
    spec = BREEZE_PRESETS[preset_key]
    refs_dir.mkdir(parents=True, exist_ok=True)
    wav_path = refs_dir / f"{preset_key}-breeze2-v1.wav"

    if wav_path.exists() and wav_path.stat().st_size > 2048:
        return str(wav_path), spec["ref_text"]

    chunks = []
    sample_rate = getattr(model, "sample_rate", 24000)
    for res in model.generate(
        text=spec["ref_text"],
        instruct=spec["instruct"],
        cfg_scale=4.0,
        temperature=0.78,
        top_k=50,
        max_tokens=500,
        seed=int(spec["seed"]),
    ):
        arr = np.asarray(res.audio, dtype=np.float32).squeeze()
        if arr.ndim > 0 and arr.size > 0:
            chunks.append(arr)
        if getattr(res, "sample_rate", None):
            sample_rate = int(res.sample_rate)

    if not chunks:
        raise RuntimeError(f"Failed to synthesize Breeze reference voice for {preset_key}")

    audio = trim_dead_air(np.concatenate(chunks), sample_rate)
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak > 0.01:
        audio = audio * (0.90 / max(peak, 0.90))
    sf.write(str(wav_path), audio, sample_rate, subtype="PCM_16")
    return str(wav_path), spec["ref_text"]


def main() -> None:
    emit({
        "event": "status",
        "state": "starting",
        "message": "Loading Breeze TTS 2 on Apple Silicon Metal…",
    })

    try:
        import mlx.core as mx
        import numpy as np
        import soundfile as sf
        from mlx_audio.tts.utils import load_model

        t0 = time.monotonic()
        model = load_model(MODEL_REPO)

        # Cache encoded reference audio tensors on Metal GPU so repeated turns never re-encode the reference clip!
        if hasattr(model, "_encode_reference"):
            orig_encode = model._encode_reference
            ref_tensor_cache: dict[str, object] = {}

            def cached_encode(ref_audio):
                key = str(ref_audio)
                if key not in ref_tensor_cache:
                    encoded = orig_encode(ref_audio)
                    mx.eval(encoded)
                    ref_tensor_cache[key] = encoded
                return ref_tensor_cache[key]

            model._encode_reference = cached_encode

        dt = time.monotonic() - t0
        emit({
            "event": "status",
            "state": "ready",
            "message": f"Breeze TTS 2 ready ({dt:.1f}s)",
        })
    except Exception as exc:
        emit({
            "event": "status",
            "state": "error",
            "message": f"Breeze TTS 2 load failed: {exc}",
            "trace": traceback.format_exc()[-600:],
        })
        sys.exit(1)

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue

        cmd = req.get("cmd")
        if cmd == "ping":
            emit({"event": "pong", "id": req.get("id", "")})
            continue
        if cmd == "quit":
            break
        if cmd == "warm_presets":
            preset_ids = req.get("preset_ids") or list(BREEZE_PRESETS.keys())
            warmed = []
            for pid in preset_ids:
                try:
                    wav_p, _ = ensure_preset_ref_wav(model, pid, REFS_DIR)
                    if hasattr(model, "_encode_reference"):
                        _ = model._encode_reference(wav_p)
                    warmed.append(pid)
                except Exception:
                    pass
            emit({"event": "warmed", "id": req.get("id", ""), "presets": warmed})
            continue
        if cmd != "synthesize":
            continue

        req_id = req.get("id", "")
        raw_text = (req.get("text") or "").strip()
        text = normalize_breeze_cues(raw_text)
        preset_id = (req.get("preset_id") or "vera").strip().lower()
        custom_voice = req.get("custom_voice")
        exaggeration = float(req.get("exaggeration", 0.45))
        out_path = req.get("out_path")

        if not text or not out_path:
            emit({"event": "done", "id": req_id, "ok": False, "error": "Missing text or out_path"})
            continue

        try:
            t_start = time.monotonic()
            spirit = max(0.0, min(1.0, exaggeration))
            # Keep temperature in Breeze TTS 2's natural conversational sweet spot (0.76..0.88)
            temp = round(0.76 + (0.12 * spirit), 2)

            kwargs: dict = {
                "text": text,
                "temperature": temp,
                "top_p": 0.95,
                "top_k": 50,
                "repetition_penalty": 1.06,
                "max_tokens": 1150,
            }

            if custom_voice and pathlib.Path(custom_voice).exists():
                custom_path = pathlib.Path(custom_voice)
                sidecar_txt = custom_path.with_suffix(".txt")
                if sidecar_txt.exists():
                    ref_txt = sidecar_txt.read_text(encoding="utf-8").strip()
                    if ref_txt:
                        kwargs["ref_audio"] = str(custom_path)
                        kwargs["ref_text"] = ref_txt
                if "ref_audio" not in kwargs:
                    # Fallback to preset anchor if custom clip has no transcript sidecar
                    ref_wav, ref_txt = ensure_preset_ref_wav(model, preset_id, REFS_DIR)
                    kwargs["ref_audio"] = ref_wav
                    kwargs["ref_text"] = ref_txt
            else:
                ref_wav, ref_txt = ensure_preset_ref_wav(model, preset_id, REFS_DIR)
                kwargs["ref_audio"] = ref_wav
                kwargs["ref_text"] = ref_txt

            chunks = []
            sample_rate = getattr(model, "sample_rate", 24000)
            for res in model.generate(**kwargs):
                arr = np.asarray(res.audio, dtype=np.float32).squeeze()
                if arr.ndim == 0 or arr.size == 0:
                    continue
                chunks.append(arr)
                if getattr(res, "sample_rate", None):
                    sample_rate = int(res.sample_rate)

            if not chunks:
                emit({"event": "done", "id": req_id, "ok": False, "error": "Model produced empty audio"})
                continue

            audio = trim_dead_air(np.concatenate(chunks), sample_rate)
            peak = float(np.max(np.abs(audio))) if audio.size else 0.0
            if peak > 0.01:
                audio = audio * (0.92 / max(peak, 0.92))

            out_file = pathlib.Path(out_path)
            out_file.parent.mkdir(parents=True, exist_ok=True)
            sf.write(str(out_file), audio, sample_rate, subtype="PCM_16")
            dur = float(len(audio)) / float(sample_rate)
            emit({
                "event": "done",
                "id": req_id,
                "ok": True,
                "out_path": str(out_file),
                "duration_sec": round(dur, 2),
                "synth_sec": round(time.monotonic() - t_start, 2),
            })
        except Exception as exc:
            emit({
                "event": "done",
                "id": req_id,
                "ok": False,
                "error": str(exc),
                "trace": traceback.format_exc()[-500:],
            })


if __name__ == "__main__":
    main()
