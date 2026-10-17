#!/usr/bin/env python3
"""MuScriptor transcription worker.

Run with MuScriptor's own venv python. Protocol: one JSON object per line on
stdout; every log line (including the library's own prints) goes to stderr.

  {"event": "progress", "completed": 1, "total": 3}
  {"event": "note", "index": 0, "pitch": 60, "startUs": 120000, "endUs": 480000, "instrument": "acoustic_piano"}
  {"event": "done", "notes": 42, "model": "medium", "seconds": 1.9}
  {"event": "error", "code": "TRANSCRIPTION_FAILED", "message": "..."}

MuScriptor does not recover velocity; the app assigns a default.
"""
import argparse
import contextlib
import json
import os
import sys
import time

# Keep a private handle on the real stdout before anything can print to it.
_protocol = os.fdopen(os.dup(sys.stdout.fileno()), "w", buffering=1)


def emit(obj):
    _protocol.write(json.dumps(obj, ensure_ascii=False) + "\n")
    _protocol.flush()


STEM_INSTRUMENTS = {
    "piano": ["acoustic_piano", "electric_piano"],
    "guitar": ["acoustic_guitar", "clean_electric_guitar", "distorted_electric_guitar"],
    "bass": ["acoustic_bass", "electric_bass"],
    "vocals": ["voice"],
    "drums": ["drums"],
    "other": None,
}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("audio")
    p.add_argument("--stem", required=True, choices=sorted(STEM_INSTRUMENTS))
    p.add_argument("--model", default="medium")
    p.add_argument("--device", default="mps")
    a = p.parse_args()

    started = time.time()
    with contextlib.redirect_stdout(sys.stderr):
        try:
            from muscriptor import TranscriptionModel
            from muscriptor.events import NoteEndEvent, NoteStartEvent, ProgressEvent
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "code": "MODEL_UNAVAILABLE", "message": f"import failed: {e}"})
            return 2
        try:
            model = TranscriptionModel.load_model(a.model, device=a.device)
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "code": "MODEL_UNAVAILABLE", "message": str(e)})
            return 2
        count = 0
        try:
            for ev in model.transcribe(a.audio, instruments=STEM_INSTRUMENTS[a.stem]):
                if isinstance(ev, ProgressEvent):
                    emit({"event": "progress", "completed": ev.completed, "total": ev.total})
                elif isinstance(ev, NoteEndEvent):
                    s = ev.start_event
                    start_us = int(round(s.start_time * 1_000_000))
                    end_us = max(start_us + 1000, int(round(ev.end_time * 1_000_000)))
                    emit({"event": "note", "index": s.index, "pitch": s.pitch,
                          "startUs": start_us, "endUs": end_us, "instrument": s.instrument})
                    count += 1
                elif isinstance(ev, NoteStartEvent):
                    pass  # Emitted on the matching end so every note line is complete.
        except Exception as e:  # noqa: BLE001
            emit({"event": "error", "code": "TRANSCRIPTION_FAILED", "message": str(e)})
            return 1
    emit({"event": "done", "notes": count, "model": a.model,
          "seconds": round(time.time() - started, 3)})
    return 0


if __name__ == "__main__":
    sys.exit(main())
