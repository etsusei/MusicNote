#!/usr/bin/env python3
"""Export six aligned stems to 192 kbps MP3, with shared gain and staged validation."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

NAMES = ['01_vocals', '02_drums', '03_bass', '04_guitar', '05_piano', '06_other']

def run(args):
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode:
        raise RuntimeError(p.stderr[-4000:])
    return p

def inspect(path, ffmpeg, ffprobe):
    info = json.loads(run([ffprobe, '-v', 'error', '-select_streams', 'a:0',
                          '-show_streams', '-of', 'json', str(path)]).stdout)['streams'][0]
    p = run([ffmpeg, '-hide_banner', '-nostdin', '-i', str(path), '-af',
             'astats=reset=0:measure_perchannel=none:measure_overall=Peak_level+Number_of_samples+Number_of_NaNs+Number_of_Infs',
             '-c:a', 'pcm_f32le', '-f', 'null', '-'])
    def stat(label):
        values = re.findall(re.escape(label) + r':\s*([-+\w.]+)', p.stderr)
        if not values:
            raise RuntimeError(f'Missing {label}: {path}')
        return float(values[-1])
    peak_db = stat('Peak level dB')
    if stat('Number of NaNs') or stat('Number of Infs'):
        raise RuntimeError(f'Nonfinite samples: {path}')
    frames = int(stat('Number of samples'))
    if frames <= 0 or not math.isfinite(peak_db):
        raise RuntimeError(f'Empty or silent stem: {path}')
    return dict(codec=info['codec_name'], sample_rate=int(info['sample_rate']),
                channels=info['channels'], bit_rate=int(info['bit_rate']),
                container_duration_seconds=float(info['duration']), decoded_frames=frames,
                decoded_duration_seconds=frames / int(info['sample_rate']),
                peak_dbfs=peak_db, bytes=path.stat().st_size)

def export(input_dir, output_dir, source=None):
    ffmpeg = shutil.which('ffmpeg') or '/opt/homebrew/bin/ffmpeg'
    ffprobe = shutil.which('ffprobe') or '/opt/homebrew/bin/ffprobe'
    output_dir.mkdir(parents=True, exist_ok=True)
    destinations = [output_dir / (n + '.mp3') for n in NAMES] + [output_dir / 'mp3-export.json']
    for p in destinations:
        if p.exists():
            raise FileExistsError(f'Refusing overwrite: {p}')
    originals = [input_dir / (n + '.wav') for n in NAMES]
    stats = [inspect(p, ffmpeg, ffprobe) for p in originals]
    frames = stats[0]['decoded_frames']
    if any(s['decoded_frames'] != frames or s['sample_rate'] != 44100 or s['channels'] != 2 for s in stats):
        raise RuntimeError('Input stems must be aligned 44.1 kHz stereo')
    peak = max(s['peak_dbfs'] for s in stats)
    # One fixed gain for all stems; leave codec headroom, never boost quiet tracks.
    gain_db = min(0.0, -1.5 - peak)
    with tempfile.TemporaryDirectory(prefix='.mp3-export-', dir=output_dir) as temp:
        stage = Path(temp)
        for attempt in range(3):
            results = []
            for original, name in zip(originals, NAMES):
                dest = stage / (name + '.mp3')
                if dest.exists():
                    dest.unlink()  # Only our private staged encoding from the previous attempt.
                run([ffmpeg, '-v', 'error', '-nostdin', '-n', '-i', str(original),
                     '-map', '0:a:0', '-map_metadata', '-1', '-af', f'volume={gain_db:.9f}dB',
                     '-ar', '44100', '-ac', '2', '-c:a', 'libmp3lame', '-b:a', '192k',
                     '-write_xing', '1', str(dest)])
                result = inspect(dest, ffmpeg, ffprobe)
                if result['codec'] != 'mp3' or result['bit_rate'] != 192000 or result['channels'] != 2 or result['sample_rate'] != 44100:
                    raise RuntimeError(f'Incorrect MP3 format: {name}')
                if result['decoded_frames'] != frames:
                    raise RuntimeError(f'Gapless decoded duration mismatch: {name}')
                if abs(result['container_duration_seconds'] - frames / 44100) > 0.1:
                    raise RuntimeError(f'Unexpected MP3 container duration: {name}')
                result['file'] = str(output_dir / dest.name)
                results.append(result)
            decoded_peak = max(s['peak_dbfs'] for s in results)
            if decoded_peak <= -0.1:
                break
            # Rare codec overshoot: re-encode all six with the same additional attenuation.
            gain_db -= decoded_peak + 0.5
        else:
            raise RuntimeError('Could not establish MP3 playback headroom')
        manifest = dict(format='MP3', bitrate_kbps=192, original_source=source,
                        source_stems=str(input_dir), source_frames=frames,
                        duration_seconds=frames / 44100, shared_gain_db=gain_db,
                        shared_gain_linear=10 ** (gain_db / 20),
                        source_max_peak_dbfs=peak, decoded_mp3_max_peak_dbfs=decoded_peak,
                        trim_applied=False, normalization='shared attenuation only; no limiter or per-track boost',
                        files=results, total_bytes=sum(s['bytes'] for s in results))
        (stage / 'mp3-export.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
        published = []
        try:
            for dest in destinations:
                os.link(stage / dest.name, dest)  # Atomic no-overwrite publication on the same filesystem.
                published.append(dest)
        except Exception:
            for dest in published:
                dest.unlink()
            raise
    print(json.dumps(manifest, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input-dir', type=Path, required=True)
    p.add_argument('--output-dir', type=Path, required=True)
    p.add_argument('--source')
    a = p.parse_args()
    export(a.input_dir.resolve(), a.output_dir.resolve(), a.source)
