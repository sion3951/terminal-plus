#!/usr/bin/env python3
"""Render packaging/macos/terminal-plus.svg into the app bundle's .icns.

Usage: python3 scripts/make-macos-icon.py [output.icns]
Requires rsvg-convert (librsvg). The output is committed, so release builds
need no SVG renderer; rerun this only after changing the SVG.
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "packaging/macos/terminal-plus.svg"
# PNG-backed ICNS element types and their pixel sizes (including @2x slots).
TYPES = [
    (b"icp4", 16), (b"icp5", 32), (b"icp6", 64), (b"ic07", 128),
    (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024),
    (b"ic11", 32), (b"ic12", 64), (b"ic13", 256), (b"ic14", 512),
]


def render(size, directory):
    path = Path(directory) / f"{size}.png"
    if not path.exists():
        subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), "-o", str(path), str(SOURCE)], check=True)
    return path.read_bytes()


def main():
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "packaging/macos/Terminal+.icns"
    with tempfile.TemporaryDirectory() as directory:
        chunks = b"".join(kind + struct.pack(">I", 8 + len(data)) + data
                          for kind, size in TYPES for data in [render(size, directory)])
    output.write_bytes(b"icns" + struct.pack(">I", 8 + len(chunks)) + chunks)
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
