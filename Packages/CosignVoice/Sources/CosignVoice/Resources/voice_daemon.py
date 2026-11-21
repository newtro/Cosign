#!/usr/bin/env python3
"""Persistent Apple Silicon MLX Chatterbox Turbo TTS worker for Cosign.

Reads JSON-line commands from stdin and emits JSON-line events on stdout.
All generation runs 100% locally on Metal GPU with zero cloud API calls.
"""

from __future__ import annotations

import json
import os
import pathlib
import sys
import time
import traceback

# Disable tqdm / HuggingFace progress bars so stderr/stdout pipes never saturate or block.
os.environ["TQDM_DISABLE"] = "1"
os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
os.environ["TRANSFORMERS_VERBOSITY"] = "error"

MODEL_REPO = os.environ.get("COSIGN_TTS_MODEL", "mlx-community/chatterbox-turbo-fp16")
_PROTO_OUT = sys.stdout
_DEVNULL = open(os.devnull, "w")
sys.stdout = _DEVNULL


def emit(payload: dict) -> None:
    _PROTO_OUT.write(json.dumps(payload, ensure_ascii=False) + "\n")
    _PROTO_OUT.flush()


def trim_dead_air(audio, sample_rate: int):
    """Trims leading and trailing dead silence so speaker-to-speaker transitions have minimal pause."""
    import numpy as np

    if audio.size == 0:
        return audio
    abs_audio = np.abs(audio)
    active = np.where(abs_audio > 0.009)[0]
    if active.size == 0:
        return audio
    pad = int(sample_rate * 0.045)  # keep a natural 45ms breath at edges
    start = max(0, int(active[0]) - pad)
    end = min(len(audio), int(active[-1]) + pad)
    return audio[start:end]


def main() -> None:
    emit({
        "event": "status",
        "state": "starting",
        "message": "Loading Chatterbox Turbo on Apple Silicon Metal…"
    })

    try:
        import numpy as np
        import soundfile as sf
        from mlx_audio.tts.utils import load_model

        t0 = time.monotonic()
        model = load_model(MODEL_REPO)
        dt = time.monotonic() - t0
        emit({
            "event": "status",
            "state": "ready",
            "message": f"Chatterbox Turbo ready ({dt:.1f}s)"
        })
    except Exception as exc:
        emit({
            "event": "status",
            "state": "error",
            "message": f"Chatterbox load failed: {exc}",
            "trace": traceback.format_exc()[-600:]
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
        if cmd != "synthesize":
            continue

        req_id = req.get("id", "")
        text = (req.get("text") or "").strip()
        ref_audio = req.get("ref_audio")
        exaggeration = float(req.get("exaggeration", 0.45))
        out_path = req.get("out_path")

        if not text or not out_path:
            emit({"event": "done", "id": req_id, "ok": False, "error": "Missing text or out_path"})
            continue

        try:
            t_start = time.monotonic()
            spirit = max(0.0, min(1.0, exaggeration))
            temp = 0.58 + (0.38 * spirit)
            kwargs = {
                "text": text,
                "temperature": round(temp, 2),
                "max_tokens": 1200,
            }
            if ref_audio and pathlib.Path(ref_audio).exists():
                kwargs["ref_audio"] = str(ref_audio)

            chunks = []
            sample_rate = 24000
            for res in model.generate(**kwargs):
                arr = np.asarray(res.audio, dtype=np.float32).squeeze()
                if arr.ndim == 0:
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
                "trace": traceback.format_exc()[-500:]
            })


if __name__ == "__main__":
    main()
