#!/usr/bin/env python3
"""Essentia worker: tempo/key detection on the unseparated selection, and an
optional beat-synchronous chord cross-check on a stem.

Run with workers/essentia/.venv/bin/python. Prints exactly one JSON object on
stdout; logs go to stderr.

  detect AUDIO            -> {"rawBpm", "ticks", "confidence", "estimates", "key", "scale", "strength", ...}
  chords AUDIO --ticks .. -> {"chords": [{"startSec", "endSec", "label", "strength"}]}
"""
import argparse
import json
import sys


def out(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def load_mono(path):
    import essentia.standard as es
    # MonoLoader downmixes and resamples into memory; the source file is untouched.
    return es.MonoLoader(filename=path, sampleRate=44100)()


def detect(path):
    import essentia.standard as es
    audio = load_mono(path)
    seconds = len(audio) / 44100.0
    result = {"durationSec": seconds, "sampleRate": 44100}
    try:
        bpm, ticks, confidence, estimates, _intervals = es.RhythmExtractor2013(method="multifeature")(audio)
        result.update(rawBpm=float(bpm), ticks=[float(t) for t in ticks],
                      confidence=float(confidence),
                      estimates=[float(e) for e in estimates[:16]],
                      rhythmMethod="multifeature", bpmRange=[40, 208])
    except Exception as e:  # noqa: BLE001
        result.update(rawBpm=None, ticks=[], confidence=None, rhythmError=str(e))
    try:
        key, scale, strength = es.KeyExtractor(sampleRate=44100)(audio)
        result.update(key=key, scale=scale, strength=float(strength))
    except Exception as e:  # noqa: BLE001
        result.update(key=None, scale=None, strength=None, keyError=str(e))
    import essentia
    result["version"] = essentia.__version__
    return result


def chords(path, ticks):
    import numpy as np
    import essentia.standard as es
    audio = load_mono(path)
    frame, hop = 4096, 2048
    window = es.Windowing(type="blackmanharris62")
    spectrum = es.Spectrum()
    peaks = es.SpectralPeaks(orderBy="magnitude", magnitudeThreshold=1e-5,
                             minFrequency=40, maxFrequency=5000, maxPeaks=60)
    hpcp = es.HPCP(size=36, referenceFrequency=440, harmonics=8,
                   bandPreset=True, minFrequency=40, maxFrequency=5000,
                   weightType="cosine", nonLinear=False, windowSize=1.0)
    frames = []
    for f in es.FrameGenerator(audio, frameSize=frame, hopSize=hop, startFromZero=True):
        freqs, mags = peaks(spectrum(window(f)))
        frames.append(hpcp(freqs, mags))
    if not frames or len(ticks) < 2:
        return {"chords": []}
    labels, strengths = es.ChordsDetectionBeats(hopSize=hop, sampleRate=44100)(
        np.array(frames, dtype=np.float32), np.array(ticks, dtype=np.float32))
    items = []
    for i, (label, s) in enumerate(zip(labels, strengths)):
        if i + 1 >= len(ticks):
            break
        items.append({"startSec": float(ticks[i]), "endSec": float(ticks[i + 1]),
                      "label": label, "strength": float(s)})
    return {"chords": items}


def chroma(path, start, end):
    """Average 12-bin pitch-class energy (HPCP) of [start, end) seconds: local audio evidence."""
    import numpy as np
    import essentia.standard as es
    audio = es.MonoLoader(filename=path, sampleRate=44100)()
    seg = audio[int(start * 44100):int(end * 44100)]
    if len(seg) < 4096:
        return {"error": {"code": "INVALID_RANGE", "message": "片段太短"}}
    window = es.Windowing(type="blackmanharris62")
    spectrum = es.Spectrum()
    peaks = es.SpectralPeaks(orderBy="magnitude", magnitudeThreshold=1e-5, minFrequency=40, maxFrequency=5000, maxPeaks=60)
    hpcp = es.HPCP(size=12, referenceFrequency=440, harmonics=8, bandPreset=True, minFrequency=40, maxFrequency=5000,
                   weightType="cosine", nonLinear=False, windowSize=1.0)
    acc = np.zeros(12)
    n = 0
    for f in es.FrameGenerator(seg, frameSize=4096, hopSize=2048, startFromZero=True):
        fr, mg = peaks(spectrum(window(f)))
        acc += hpcp(fr, mg)
        n += 1
    acc = acc / max(1, n)
    if acc.max() > 0:
        acc = acc / acc.max()
    # Essentia HPCP index 0 is A; rotate so index 0 is C.
    names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    by_c = [float(acc[(i + 3) % 12]) for i in range(12)]
    return {"chroma": {names[i]: round(by_c[i], 3) for i in range(12)}, "frames": n}


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("detect")
    d.add_argument("audio")
    c = sub.add_parser("chords")
    c.add_argument("audio")
    c.add_argument("--ticks", required=True, help="JSON array of beat times in seconds")
    h = sub.add_parser("chroma")
    h.add_argument("audio")
    h.add_argument("--start", type=float, required=True)
    h.add_argument("--end", type=float, required=True)
    a = p.parse_args()
    try:
        if a.cmd == "detect":
            out(detect(a.audio))
        elif a.cmd == "chroma":
            out(chroma(a.audio, a.start, a.end))
        else:
            out(chords(a.audio, json.loads(a.ticks)))
    except Exception as e:  # noqa: BLE001
        out({"error": {"code": "DETECTION_FAILED", "message": str(e)}})
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
