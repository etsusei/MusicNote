#!/usr/bin/env python3
"""MT3 transcription worker (second, independent transcription next to MuScriptor).

Run with workers/mt3/.venv/bin/python: a thin venv layered over the user's MT3 environment
(read-only .pth) that adds the jax-mps Metal backend, so MT3 runs on the Apple GPU. It reuses
InferenceModel from the user's existing MT3 script without modifying it.

  mt3_worker.py AUDIO --mt3-dir DIR [--offset S --duration S] [--programs 0-5] [--model mt3]

stdout: JSON lines (everything else goes to stderr)
  {"event": "progress", "stage": "load", ...}
  {"event": "note", "pitch": 60, "startUs": 0, "endUs": 400000, "velocity": 100, "program": 0, "instrument": "acoustic_piano"}
  {"event": "done", "notes": N, "kept": K, "dropped": {"program 32": 12}, "seconds": 12.3}
  {"event": "error", "code": "...", "message": "..."}

Times are relative to `offset`. Program filter keeps General MIDI programs in the given
range (default 0–5: acoustic and electric pianos); drums are always dropped.
"""
import argparse
import contextlib
import json
import os
import sys
import time

_protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)


def emit(obj):
    _protocol.write(json.dumps(obj, ensure_ascii=False) + "\n")
    _protocol.flush()


def program_name(p):
    if 0 <= p <= 3:
        return "acoustic_piano"
    if 4 <= p <= 5:
        return "electric_piano"
    return f"program_{p}"


def parse_range(s):
    lo, _, hi = s.partition("-")
    return int(lo), int(hi or lo)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("--mt3-dir", required=True)
    ap.add_argument("--offset", type=float, default=0.0)
    ap.add_argument("--duration", type=float, default=None)
    ap.add_argument("--programs", default="0-5")
    ap.add_argument("--model", default="mt3", choices=["mt3", "ismir2021"])
    ap.add_argument("--device", default="mps", choices=["mps", "cpu"], help="mps = Apple GPU via jax-mps")
    a = ap.parse_args()
    lo, hi = parse_range(a.programs)
    started = time.time()
    with contextlib.redirect_stdout(sys.stderr):
        try:
            sys.path.insert(0, a.mt3_dir)
            os.environ["JAX_PLATFORMS"] = a.device  # before jax is imported
            os.environ.setdefault("JAX_MPS_ASYNC_DISPATCH", "1")
            if a.device == "mps":
                # jax-mps turns the shardy partitioner off when its backend initialises, which is after
                # T5X has recorded the setting; switch it off first so both agree.
                import jax
                jax.config.update("jax_use_shardy_partitioner", False)
            import librosa
            import transcribe as mt3script
            if a.device == "mps":
                # T5X can't derive a device mesh for the "mps" platform; MT3 inference uses one device.
                import jax
                import numpy as np
                import t5x.partitioning as tp
                tp.default_mesh = lambda *args, **kw: jax.sharding.Mesh(np.array(jax.devices()[:1]).reshape(1, 1), ("data", "model"))
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "code": "MODEL_UNAVAILABLE", "message": f"MT3 import failed: {e}"})
            return 2
        emit({"event": "progress", "stage": "load"})
        try:
            audio, _ = librosa.load(a.audio, sr=mt3script.SAMPLE_RATE, mono=True, offset=a.offset, duration=a.duration)
            ckpt = os.path.join(a.mt3_dir, "checkpoints", a.model)
            model = mt3script.InferenceModel(ckpt, a.model)
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "code": "MODEL_UNAVAILABLE", "message": str(e)})
            return 2
        emit({"event": "progress", "stage": "transcribe", "seconds": round(len(audio) / mt3script.SAMPLE_RATE, 3)})
        try:
            ns = model(audio)
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "code": "TRANSCRIPTION_FAILED", "message": str(e)})
            return 1
    kept = 0
    dropped = {}
    for n in sorted(ns.notes, key=lambda n: (n.start_time, n.pitch)):
        prog = int(n.program)
        if n.is_drum or not (lo <= prog <= hi):
            k = "drums" if n.is_drum else f"program {prog}"
            dropped[k] = dropped.get(k, 0) + 1
            continue
        s = int(round(n.start_time * 1e6))
        e = max(s + 1000, int(round(n.end_time * 1e6)))
        emit({"event": "note", "pitch": int(n.pitch), "startUs": s, "endUs": e, "velocity": int(n.velocity or 100),
              "program": prog, "instrument": program_name(prog)})
        kept += 1
    emit({"event": "done", "notes": len(ns.notes), "kept": kept, "dropped": dropped,
          "model": a.model, "device": a.device, "seconds": round(time.time() - started, 3)})
    return 0


if __name__ == "__main__":
    sys.exit(main())
