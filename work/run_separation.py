#!/usr/bin/env python3
"""Selected audio + explicit confirmation -> full-song six-stem MP3 export."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('audio', type=Path, help='User-selected audio file')
    p.add_argument('--confirm', action='store_true', help='Confirm the selected file and start processing')
    p.add_argument('--output-dir', type=Path, default=Path(__file__).resolve().parent.parent / 'output')
    p.add_argument('--short', action='store_true', help=argparse.SUPPRESS)  # Explicit development verification only.
    a = p.parse_args()
    if not a.audio.is_file():
        p.error('Selected audio file does not exist')
    if not a.confirm:
        p.error('No processing started. Confirm the selected audio by adding --confirm.')
    work = Path(__file__).resolve().parent
    binary = work / 'separate'
    source = work / 'separate.swift'
    if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
        with tempfile.TemporaryDirectory(prefix='musicnote-build-') as cache:
            subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', cache, str(source), '-o', str(binary)], check=True)
    command = [str(binary), '--input', str(a.audio.resolve()), '--confirm', '--output-dir', str(a.output_dir.resolve())]
    if a.short:
        command.append('--short')
    return subprocess.call(command)

if __name__ == '__main__':
    sys.exit(main())
