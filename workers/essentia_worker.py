#!/usr/bin/env python3
"""Essentia worker: tempo/key detection on the unseparated selection, and an
optional beat-synchronous chord cross-check on a stem.

Run with workers/essentia/.venv/bin/python. Prints exactly one JSON object on
stdout; logs go to stderr.

  detect AUDIO            -> {"rawBpm", "ticks", "confidence", "estimates", "key", "scale", "strength", ...}
  chords AUDIO --ticks .. -> {"chords": [{"startSec", "endSec", "label", "strength"}]}
  bars AUDIO              -> {"bpm", "ticks", "beatsPerBar", "downbeatPhase", "phaseScores", ...} (whole song)
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


def bars(path):
    """Beats and bar lines for the whole song, so a selection can snap to bar lines.

    Essentia has no downbeat tracker. In most songs the harmony changes and the bass is
    struck on the first beat of a bar, so for each meter (4, 3) and phase we score how much
    beat-synchronous chroma change and bass onset energy falls on the candidate downbeats.
    """
    import numpy as np
    import essentia.standard as es
    audio = load_mono(path)
    sr = 44100.0
    bpm, ticks, confidence, estimates, _ = es.RhythmExtractor2013(method="multifeature")(audio)
    ticks = [float(t) for t in ticks]
    result = {"bpm": float(bpm), "ticks": ticks, "confidence": float(confidence), "durationSec": len(audio) / sr}
    if len(ticks) < 12:
        result.update(beatsPerBar=4, downbeatPhase=0, phaseScores={}, note="too few beats")
        return result
    frame, hop = 4096, 2048
    window = es.Windowing(type="blackmanharris62")
    spectrum = es.Spectrum()
    peaks = es.SpectralPeaks(orderBy="magnitude", magnitudeThreshold=1e-5, minFrequency=40, maxFrequency=5000, maxPeaks=60)
    hpcp = es.HPCP(size=12, referenceFrequency=440, harmonics=8, bandPreset=True, minFrequency=40, maxFrequency=5000,
                   weightType="cosine", nonLinear=False, windowSize=1.0)
    lo_bin = int(30 * frame / sr)
    hi_bin = int(160 * frame / sr)
    chroma, bass = [], []
    for f in es.FrameGenerator(audio, frameSize=frame, hopSize=hop, startFromZero=True):
        sp = spectrum(window(f))
        fr, mg = peaks(sp)
        chroma.append(hpcp(fr, mg))
        bass.append(float(np.sum(sp[lo_bin:hi_bin] ** 2)))
    chroma = np.array(chroma)
    bass = np.array(bass)
    times = np.arange(len(bass)) * hop / sr
    n = len(ticks)
    sync = np.zeros((n, 12))
    onset = np.zeros(n)
    for i, t in enumerate(ticks):
        end = ticks[i + 1] if i + 1 < n else t + 60.0 / max(bpm, 1)
        m = (times >= t) & (times < end)
        if m.any():
            sync[i] = chroma[m].mean(axis=0)
        head = (times >= t - 0.03) & (times < t + 0.12)
        before = (times >= t - 0.25) & (times < t - 0.03)
        if head.any():
            onset[i] = max(0.0, np.log1p(bass[head].max()) - (np.log1p(bass[before].mean()) if before.any() else 0.0))
    norms = np.linalg.norm(sync, axis=1) + 1e-9
    novelty = np.zeros(n)
    for i in range(1, n):
        novelty[i] = 1.0 - float(np.dot(sync[i], sync[i - 1]) / (norms[i] * norms[i - 1]))
    def z(x):
        sd = x.std()
        return (x - x.mean()) / sd if sd > 0 else x * 0
    feat = z(novelty) + 0.6 * z(onset)
    scores = {}
    for meter in (4, 3):
        for p in range(meter):
            scores["%d/%d" % (meter, p)] = float(feat[p::meter].mean())
    # Half-time reading (a 4/4 bar spans 8 detected beats): which of the two 4-beat phases is beat 1.
    for p in range(8):
        scores["8/%d" % p] = float(feat[p::8].mean())
    best4 = max(range(4), key=lambda p: scores["4/%d" % p])
    best3 = max(range(3), key=lambda p: scores["3/%d" % p])
    # 4/4 unless 3/4 is clearly stronger: most material here is 4/4, and 3/4 fits half the 4/4 patterns too.
    if scores["3/%d" % best3] > scores["4/%d" % best4] + 0.25:
        meter, phase = 3, best3
    else:
        meter, phase = 4, best4
    ranked = sorted([scores["%d/%d" % (meter, p)] for p in range(meter)], reverse=True)
    half = max(range(8), key=lambda p: scores["8/%d" % p]) if meter == 4 else None
    result.update(halfTimePhase=half)
    result.update(beatsPerBar=meter, downbeatPhase=phase, phaseScores=scores,
                  downbeatMargin=float(ranked[0] - ranked[1]) if len(ranked) > 1 else 0.0)
    return result


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
    b = sub.add_parser("bars")
    b.add_argument("audio")
    a = p.parse_args()
    try:
        if a.cmd == "detect":
            out(detect(a.audio))
        elif a.cmd == "bars":
            out(bars(a.audio))
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
