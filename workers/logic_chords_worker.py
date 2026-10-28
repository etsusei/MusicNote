#!/usr/bin/env python3
"""Logic Pro Chord ID worker: audio + beat grid -> native chord candidates.

Productised from work/logic-chord-probe/run_probe.py. Reads Logic's private framework
read-only (version pinned by SHA-256); never launches Logic or writes its data. The bridge
is compiled once into --cache-dir, next to a symlink to Logic's resource bundle.

  logic_chords_worker.py --audio PATH --offset S --duration S --grid-json FILE --cache-dir DIR

grid JSON: {"beats": [seconds...], "downbeats": [seconds...]} relative to the clip start.
stdout: one JSON object
  {"status": "ok", "events": [{"label": "Fm(7)", "startSec": 0.0067, "endSec": 1.82}], ...}
  {"error": {"code": "...", "message": "..."}}
An empty grid makes Logic return nothing; that is reported as an error, never as "no chords".
"""
import argparse
import hashlib
import json
import math
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
LOGIC = pathlib.Path("/Applications/Logic Pro.app")
FRAMEWORKS = LOGIC / "Contents/Frameworks"
ML_BINARY = FRAMEWORKS / "MAMachineLearning.framework/MAMachineLearning"
RESOURCES = LOGIC / "Contents/Resources/MAMachineLearningResources.bundle"
# MAMachineLearning builds checked against stored results (same API; 12.4 changed ~1% of labels,
# e.g. Gb(maj7) -> Gb, Gm/Bb -> Gm). A new build is refused until it is checked again.
VERIFIED_SHA256 = {
    "20581918005b925b0ee2ce26e20f936848f841a8853050ab364f8cfd9c4db195": "12.3.1",
    "930cd55d602fd4750bb572d611598e6646601213fa265fda31c6aa836d3c1f10": "12.4",
}


def out(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def fail(code, message):
    out({"error": {"code": code, "message": message}})
    return 1


def helper(cache_dir: pathlib.Path, digest: str) -> pathlib.Path:
    d = cache_dir / digest[:16]
    exe = d / "harmony_bridge"
    if exe.exists():
        return exe
    d.mkdir(parents=True, exist_ok=True)
    link = d / "MAMachineLearningResources.bundle"
    if not link.exists():
        link.symlink_to(RESOURCES)
    tmp = d / "harmony_bridge.tmp"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                    "-Wl,-rpath," + str(FRAMEWORKS), str(HERE / "logic" / "harmony_bridge.m"), "-o", str(tmp)],
                   check=True, capture_output=True)
    tmp.rename(exe)
    return exe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", required=True, type=pathlib.Path)
    ap.add_argument("--offset", type=float, default=0.0)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--grid-json", required=True, type=pathlib.Path)
    ap.add_argument("--cache-dir", required=True, type=pathlib.Path)
    ap.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg")
    a = ap.parse_args()
    if not ML_BINARY.exists():
        return fail("MODEL_UNAVAILABLE", "没有找到 Logic Pro 的 Chord ID 框架")
    info = plistlib.loads((LOGIC / "Contents/Info.plist").read_bytes())
    digest = hashlib.sha256(ML_BINARY.read_bytes()).hexdigest()
    if digest not in VERIFIED_SHA256:
        return fail("MODEL_UNAVAILABLE", f"Logic {info.get('CFBundleShortVersionString')} 的 Chord ID 框架与已验证版本不同，需要重新验证后才能使用")
    grid = json.loads(a.grid_json.read_text())
    if not grid.get("beats") or not grid.get("downbeats"):
        return fail("INVALID_ARGUMENTS", "拍点为空：Logic 会返回空结果，不能当作没有和弦")
    try:
        exe = helper(a.cache_dir, digest)
    except subprocess.CalledProcessError as e:
        return fail("MODEL_UNAVAILABLE", "编译 Logic 桥接失败：" + (e.stderr or b"").decode()[-300:])
    with tempfile.TemporaryDirectory(prefix="musicnote-logic-") as td:
        clip = pathlib.Path(td) / "clip.wav"
        r = subprocess.run([a.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-ss", str(a.offset),
                            "-i", str(a.audio), "-t", str(a.duration), "-ar", "22050", "-ac", "1", "-c:a", "pcm_f32le", str(clip)],
                           capture_output=True, text=True)
        if r.returncode:
            return fail("SOURCE_MISSING", "裁剪音频失败：" + r.stderr[-300:])
        started = time.monotonic()
        run = subprocess.run([str(exe), str(clip), str(a.grid_json)], capture_output=True, text=True, timeout=200)
        elapsed = time.monotonic() - started
    if run.returncode:
        return fail("ANALYSIS_FAILED", f"Logic 分析器退出码 {run.returncode}：{run.stderr[-300:]}")
    raw = json.loads(run.stdout)
    chords = [r for r in raw if r.get("type") == 0]
    if not chords:
        return fail("ANALYSIS_FAILED", "Logic 没有返回和弦事件")
    events = []
    for i, r in enumerate(chords):
        s = float(r["position"])
        e = float(chords[i + 1]["position"]) if i + 1 < len(chords) else a.duration
        if not (math.isfinite(s) and 0 <= s < a.duration):
            continue
        events.append({"label": r["label"], "startSec": s, "endSec": min(e, a.duration)})
    out({"status": "ok", "events": events, "logicVersion": info.get("CFBundleShortVersionString"),
         "logicBuild": info.get("CFBundleVersion"), "frameworkSha256": digest, "seconds": round(elapsed, 3),
         "endTimesDerived": True})
    return 0


if __name__ == "__main__":
    sys.exit(main())
