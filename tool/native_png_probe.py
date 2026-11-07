"""Host-only native PNG A/B/A probe; not a mobile frame or energy benchmark.

Compare two already-built Release libraries using the same RGBA buffer, native
encoding, owned output copy and release. No shared Pub sources are modified.
"""

import argparse
from array import array
import ctypes
import gc
import hashlib
import json
import platform
from pathlib import Path
import statistics
import sys
import time


def memory():
    if sys.platform == "win32":
        class Counters(ctypes.Structure):
            _fields_ = [("cb", ctypes.c_ulong), ("faults", ctypes.c_ulong),
                        *[(name, ctypes.c_size_t) for name in (
                            "peak", "rss", "peak_paged", "paged", "peak_nonpaged",
                            "nonpaged", "pagefile", "peak_pagefile", "private")]]
        counters = Counters(cb=ctypes.sizeof(Counters))
        kernel = ctypes.WinDLL("kernel32")
        kernel.GetCurrentProcess.restype = ctypes.c_void_p
        query = ctypes.WinDLL("psapi").GetProcessMemoryInfo
        query.argtypes = [ctypes.c_void_p, ctypes.POINTER(Counters), ctypes.c_ulong]
        if not query(kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
            raise ctypes.WinError()
        return {"rss_bytes": counters.rss, "process_peak_rss_bytes": counters.peak}
    import resource
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform != "darwin":
        peak *= 1024
    rss = None
    if sys.platform == "linux":
        for line in Path("/proc/self/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                rss = int(line.split()[1]) * 1024
    return {"rss_bytes": rss, "process_peak_rss_bytes": peak}


def encoder(path, candidate, width, height):
    library = ctypes.CDLL(str(path))
    if candidate:
        encode = library.venera_png_encode
        encode.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32,
                           ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t)]
        release = library.venera_native_free
    else:
        encode = library.lodepng_encode32
        encode.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_size_t),
                           ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32]
        release = library.freePtr
    encode.restype = ctypes.c_uint32
    release.argtypes = [ctypes.c_void_p]
    release.restype = None

    def run(buffer):
        output = ctypes.c_void_p()
        length = ctypes.c_size_t()
        try:
            if candidate:
                code = encode(buffer, width * height * 4, width, height,
                              ctypes.byref(output), ctypes.byref(length))
            else:
                code = encode(ctypes.byref(output), ctypes.byref(length), buffer, width, height)
            if code or not output.value or not length.value:
                raise RuntimeError(f"PNG encoder returned status {code} / length {length.value}")
            return ctypes.string_at(output.value, length.value)
        finally:
            if output.value:
                release(output)
    return run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--old-library", type=Path, required=True)
    parser.add_argument("--new-library", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--width", type=int, default=1600)
    parser.add_argument("--height", type=int, default=2400)
    parser.add_argument("--runs", type=int, default=5)
    args = parser.parse_args()
    if min(args.width, args.height, args.runs) < 1:
        parser.error("Positive dimensions and runs are required")
    old = encoder(args.old_library.resolve(), False, args.width, args.height)
    new = encoder(args.new_library.resolve(), True, args.width, args.height)
    results = []
    for kind in ("monochrome", "color"):
        pixels = array("I", (
            (0xff202020 if x % 97 < 3 or y % 113 < 3 else 0xfff8f8f8)
            if kind == "monochrome" else
            0xff000000 | ((x * 3 + y * 5) & 255) | (((x * 11 + y * 7) & 255) << 8)
            | (((x * 17 + y * 13) & 255) << 16)
            for y in range(args.height) for x in range(args.width)))
        if sys.byteorder != "little":
            pixels.byteswap()
        buffer = ctypes.create_string_buffer(pixels.tobytes(), len(pixels) * 4)
        del pixels
        reference = old(buffer)
        if new(buffer) != reference:
            raise RuntimeError("The candidate changed the encoded PNG bytes")
        del reference
        for phase, encode in (("A1_old", old), ("B_new", new), ("A2_old", old)):
            encode(buffer)
            gc.collect()
            samples = []
            for _ in range(args.runs):
                started = time.perf_counter_ns()
                encoded = encode(buffer)
                samples.append((time.perf_counter_ns() - started) / 1_000_000)
            record = {"kind": kind, "phase": phase, "ms": samples,
                      "median_ms": statistics.median(samples), "png_bytes": len(encoded), **memory()}
            results.append(record)
            print(json.dumps(record), flush=True)
        del buffer, encoded
    report = {"probe": "native_png", "scope": "native encode, owned copy and free; host process RSS",
              "platform": platform.platform(), "machine": platform.machine(),
              "width": args.width, "height": args.height, "runs": args.runs,
              "libraries": {name: {"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
                            for name, path in (("baseline", args.old_library), ("candidate", args.new_library))},
              "results": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
