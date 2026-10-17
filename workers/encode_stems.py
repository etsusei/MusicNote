#!/usr/bin/env python3
"""Encode six separated WAV stems to 192 kbps MP3 with one shared gain.

Adapted from work/export_mp3.py for the app: product stem names, silent stems
are reported instead of rejected, and the manifest is printed as one JSON line.

  encode_stems.py --input-dir STAGE/wav --output-dir STAGE/mp3

Input: vocals.wav drums.wav bass.wav guitar.wav piano.wav other.wav (44.1 kHz
stereo float). Output: same names as .mp3 plus a JSON manifest on stdout.
Runs with the system python3; needs ffmpeg/ffprobe.
"""
import argparse
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

STEMS = ["vocals", "drums", "bass", "guitar", "piano", "other"]
SILENT_DB = -90.0
WEAK_DB = -40.0
MP3_FRAME = 1152


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{Path(cmd[0]).name} failed: {r.stderr.strip()[-400:]}")
    return r


def inspect(path, ffmpeg, ffprobe):
    info = json.loads(run([ffprobe, "-v", "error", "-select_streams", "a:0", "-show_entries",
                           "stream=codec_name,sample_rate,channels,bit_rate,duration",
                           "-of", "json", str(path)]).stdout)["streams"][0]
    stats = run([ffmpeg, "-v", "info", "-nostdin", "-i", str(path), "-map", "0:a:0",
                 "-af", "astats=measure_perchannel=none:measure_overall=Peak_level+Number_of_samples+Number_of_NaNs+Number_of_Infs",
                 "-f", "null", "-"]).stderr

    def stat(label):
        values = [line.rsplit(":", 1)[1].strip() for line in stats.splitlines() if label in line]
        if not values:
            raise RuntimeError(f"Missing {label}: {path}")
        v = values[-1]
        return float("-inf") if v in ("-inf", "-") else float(v)

    if stat("Number of NaNs") or stat("Number of Infs"):
        raise RuntimeError(f"Nonfinite samples: {path}")
    frames = int(stat("Number of samples"))
    if frames <= 0:
        raise RuntimeError(f"Empty stem: {path}")
    peak = stat("Peak level dB")
    return dict(codec=info.get("codec_name"), sampleRate=int(info["sample_rate"]),
                channels=int(info["channels"]), bitRate=int(info.get("bit_rate") or 0),
                containerDurationSec=float(info.get("duration") or 0), decodedFrames=frames,
                peakDbfs=peak if math.isfinite(peak) else None, bytes=path.stat().st_size)


def level(peak):
    if peak is None or peak < SILENT_DB:
        return "silent"
    if peak < WEAK_DB:
        return "weak"
    return "normal"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--input-dir", type=Path, required=True)
    p.add_argument("--output-dir", type=Path, required=True)
    p.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")
    p.add_argument("--ffprobe", default=shutil.which("ffprobe") or "/opt/homebrew/bin/ffprobe")
    a = p.parse_args()
    ffmpeg, ffprobe = a.ffmpeg, a.ffprobe
    a.output_dir.mkdir(parents=True, exist_ok=True)
    originals = [a.input_dir / f"{s}.wav" for s in STEMS]
    stats = [inspect(o, ffmpeg, ffprobe) for o in originals]
    frames = stats[0]["decodedFrames"]
    if any(s["decodedFrames"] != frames or s["sampleRate"] != 44100 or s["channels"] != 2 for s in stats):
        raise RuntimeError("Input stems must be aligned 44.1 kHz stereo")
    peaks = [s["peakDbfs"] for s in stats if s["peakDbfs"] is not None]
    peak = max(peaks) if peaks else -120.0
    # One fixed gain for all stems keeps their balance; never boost quiet stems.
    gain_db = min(0.0, -1.5 - peak)
    for attempt in range(3):
        results = []
        for original, name in zip(originals, STEMS):
            dest = a.output_dir / f"{name}.mp3"
            if dest.exists():
                dest.unlink()  # Our own staged output from the previous attempt.
            run([ffmpeg, "-v", "error", "-nostdin", "-n", "-i", str(original), "-map", "0:a:0",
                 "-map_metadata", "-1", "-af", f"volume={gain_db:.9f}dB", "-ar", "44100", "-ac", "2",
                 "-c:a", "libmp3lame", "-b:a", "192k", "-write_xing", "1", str(dest)])
            r = inspect(dest, ffmpeg, ffprobe)
            if r["codec"] != "mp3" or r["bitRate"] != 192000 or r["channels"] != 2 or r["sampleRate"] != 44100:
                raise RuntimeError(f"Incorrect MP3 format: {name}")
            # The start is gapless-trimmed exactly; ffmpeg's LAME tag can leave a few padding
            # samples at the end. Accept less than one MP3 frame of trailing padding: it is not
            # new audio (valid length stays `frames`) and no music is cut. Shorter is an error.
            extra = r["decodedFrames"] - frames
            if extra < 0 or extra >= MP3_FRAME:
                raise RuntimeError(f"Gapless decoded length mismatch: {name} {r['decodedFrames']} != {frames}")
            r.update(stem=name, file=dest.name, level=level(r["peakDbfs"]), trailingPaddingFrames=extra)
            results.append(r)
        decoded = [r["peakDbfs"] for r in results if r["peakDbfs"] is not None]
        decoded_peak = max(decoded) if decoded else -120.0
        if decoded_peak <= -0.1:
            break
        gain_db -= decoded_peak + 0.5  # Rare codec overshoot: attenuate all six together.
    else:
        raise RuntimeError("Could not establish MP3 playback headroom")
    manifest = dict(format="mp3", bitrateKbps=192, frames=frames, durationSec=frames / 44100,
                    sharedGainDb=gain_db, sourcePeakDbfs=peak, decodedPeakDbfs=decoded_peak,
                    encoder=run([ffmpeg, "-version"]).stdout.splitlines()[0], stems=results)
    sys.stdout.write(json.dumps(manifest, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        sys.stdout.write(json.dumps({"error": {"code": "ENCODE_FAILED", "message": str(e)}}) + "\n")
        sys.exit(1)
