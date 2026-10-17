#!/usr/bin/env python3
"""Musicpy chord-naming worker.

Run with workers/musicpy/.venv/bin/python. Reads one JSON object from stdin:

  {"items": [{"id": "chord-01", "pitches": [50, 57, 60, 65]}]}

pitches are MIDI numbers in voicing order (low to high). Writes one JSON
object to stdout:

  {"items": [{"id": "chord-01", "raw": "Dm7 sort as [1, 3, 4, 2]",
              "root": "D", "type": "m7", "bass": "D", "omit": [], "altered": [],
              "polychord": false}], "version": "7.16"}

Musicpy only names; grouping into events happens in the app.
"""
import contextlib
import json
import sys

NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]


def note_name(pitch):
    return f"{NOTE_NAMES[pitch % 12]}{pitch // 12 - 1}"


def name_one(mp, pitches):
    if not pitches:
        return {"raw": None, "root": None, "type": None, "error": "empty"}
    names = [note_name(p) for p in sorted(pitches)]
    if len(set(p % 12 for p in pitches)) == 1:
        n = NOTE_NAMES[pitches[0] % 12]
        return {"raw": n, "root": n, "type": "note", "bass": n, "omit": [], "altered": [], "polychord": False}
    chord = mp.chord(names)
    raw = mp.alg.detect(chord)
    info = mp.alg.detect(chord, get_chord_type=True)
    poly = info.chord_speciality == "polychord"
    item = {"raw": raw if isinstance(raw, str) else str(raw),
            "root": info.root, "type": info.chord_type,
            "bass": NOTE_NAMES[min(pitches) % 12],
            "omit": list(info.omit or []), "altered": list(info.altered or []),
            "inversion": info.inversion, "polychord": poly,
            "speciality": info.chord_speciality}
    if info.non_chord_bass_note:
        item["nonChordBass"] = str(info.non_chord_bass_note)
    return item


def main():
    request = json.load(sys.stdin)
    with contextlib.redirect_stdout(sys.stderr):
        import musicpy as mp
        results = []
        for it in request.get("items", []):
            try:
                r = name_one(mp, [int(p) for p in it.get("pitches", [])])
            except Exception as e:  # noqa: BLE001
                r = {"raw": None, "root": None, "type": None, "error": str(e)}
            r["id"] = it.get("id")
            results.append(r)
    try:
        from importlib.metadata import version
        ver = version("musicpy")
    except Exception:  # noqa: BLE001
        ver = "unknown"
    sys.stdout.write(json.dumps({"items": results, "version": ver}, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
