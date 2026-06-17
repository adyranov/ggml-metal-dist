#!/usr/bin/env python3
"""Structural checks for generated media files (stdlib-only).

Usage:
    mediacheck.py png FILE [--width W] [--height H] [--min-bytes N]
    mediacheck.py wav FILE [--min-duration S] [--rate R] [--min-bytes N]

Prints key=value diagnostics to stdout; exits non-zero with a reason on stderr
when a required constraint fails.
"""

from __future__ import annotations

import argparse
import struct
import sys
import wave
import zlib
from array import array
from pathlib import Path

PNG_SIG = b"\x89PNG\r\n\x1a\n"

# Distinct byte values in a real image's (inflated, still-filtered) pixel stream
# run into the hundreds; a flat/degenerate image collapses to a handful.
_MIN_DISTINCT_BYTES = 16

# sampwidth (bytes) -> array typecode for signed PCM peak scanning.
_PCM_TYPECODES = {1: "b", 2: "h", 4: "i"}


def _fail(msg: str) -> None:
    print(msg, file=sys.stderr)
    raise SystemExit(1)


def check_png(
    path: Path,
    width: int | None,
    height: int | None,
    min_bytes: int | None,
) -> dict[str, str]:
    data = path.read_bytes()
    size = len(data)
    if size < 8 or data[:8] != PNG_SIG:
        _fail(f"invalid PNG signature: {path}")
    if min_bytes is not None and size < min_bytes:
        _fail(f"file too small: {size} < {min_bytes}")

    pos = 8
    img_w = img_h = 0
    interlaced = False
    idat = bytearray()
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        ctype = data[pos + 4 : pos + 8]
        pos += 8
        chunk = data[pos : pos + length]
        pos += length + 4  # skip CRC
        if ctype == b"IHDR":
            if length != 13:
                _fail("invalid IHDR chunk")
            img_w, img_h, _, _, comp, filt, interlace = struct.unpack(">IIBBBBB", chunk)
            if comp != 0 or filt != 0:
                _fail("unsupported PNG compression/filter method")
            interlaced = interlace != 0
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break

    if img_w == 0 or img_h == 0:
        _fail("missing IHDR chunk")
    if width is not None and img_w != width:
        _fail(f"width mismatch: {img_w} != {width}")
    if height is not None and img_h != height:
        _fail(f"height mismatch: {img_h} != {height}")

    # Non-degenerate heuristic: decode pixel data is not near-uniform. Cheap and
    # robust without a full defilter; a flat image inflates to <16 distinct bytes
    # (and would already trip --min-bytes, since it compresses tiny).
    variance = "skipped"
    if idat and not interlaced:
        try:
            distinct = len(set(zlib.decompress(bytes(idat))))
        except zlib.error:
            distinct = -1
        if distinct == -1:
            variance = "skipped"
        elif distinct < _MIN_DISTINCT_BYTES:
            _fail(f"degenerate image: only {distinct} distinct byte values")
        else:
            variance = "ok"

    return {
        "bytes": str(size),
        "width": str(img_w),
        "height": str(img_h),
        "variance": variance,
    }


def _pcm_peak(raw: bytes, sampwidth: int) -> int | None:
    """Peak absolute sample amplitude, or None when not decodable as PCM."""
    typecode = _PCM_TYPECODES.get(sampwidth)
    if typecode is None:
        return None
    samples = array(typecode)
    if samples.itemsize != sampwidth:
        return None
    samples.frombytes(raw[: len(raw) - len(raw) % sampwidth])
    return max((abs(int(s)) for s in samples), default=0)


def check_wav(
    path: Path,
    min_duration: float | None,
    rate: int | None,
    min_bytes: int | None,
) -> dict[str, str]:
    size = path.stat().st_size
    if min_bytes is not None and size < min_bytes:
        _fail(f"file too small: {size} < {min_bytes}")

    try:
        with wave.open(str(path), "rb") as wf:
            nch = wf.getnchannels()
            sampwidth = wf.getsampwidth()
            fr = wf.getframerate()
            nframes = wf.getnframes()
            is_pcm = wf.getcomptype() == "NONE"
            raw = wf.readframes(nframes) if is_pcm else b""
    except wave.Error as exc:
        _fail(f"invalid WAV: {exc}")

    duration = nframes / fr if fr > 0 else 0.0
    if min_duration is not None and duration < min_duration:
        _fail(f"duration too short: {duration:.3f}s < {min_duration}s")
    if rate is not None and fr != rate:
        _fail(f"sample rate mismatch: {fr} != {rate}")

    peak = _pcm_peak(raw, sampwidth) if is_pcm else None
    if peak == 0:
        _fail("degenerate audio: silent (peak=0)")

    return {
        "bytes": str(size),
        "channels": str(nch),
        "rate": str(fr),
        "duration": f"{duration:.3f}",
        "peak": str(peak) if peak is not None else "skipped",
    }


def _emit_result(fields: dict[str, str]) -> None:
    print(" ".join(f"{k}={v}" for k, v in fields.items()))


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="mediacheck.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    png = sub.add_parser("png")
    png.add_argument("file", type=Path)
    png.add_argument("--width", type=int)
    png.add_argument("--height", type=int)
    png.add_argument("--min-bytes", type=int)

    wav = sub.add_parser("wav")
    wav.add_argument("file", type=Path)
    wav.add_argument("--min-duration", type=float)
    wav.add_argument("--rate", type=int)
    wav.add_argument("--min-bytes", type=int)

    args = parser.parse_args(argv)
    path: Path = args.file
    if not path.is_file():
        _fail(f"file not found: {path}")

    if args.cmd == "png":
        fields = check_png(path, args.width, args.height, args.min_bytes)
    else:
        fields = check_wav(path, args.min_duration, args.rate, args.min_bytes)
    _emit_result(fields)


if __name__ == "__main__":
    main()
