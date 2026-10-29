"""Cross-compile the reader's real PNG, ZIP and 7Z FFI libraries for OHOS."""

import argparse
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from native_build import CONFIG, digest, inspect_library, require_within, run
from prepare_full_app import DEPS, EXTRA_LIBRARIES, verify_dependencies
from prepare_probe import BASE, verify_native_report
from ci_sdk import check_native_sdk


EXPORTS = {
    "liblodepng_flutter.so": ("lodepng_encode32", "lodepng_decode32", "freePtr"),
    "libzip_flutter.so": ("zip_open", "zip_close", "zip_entry_open", "zip_entry_fwrite", "zip_entry_read", "zip_extract"),
    "libflutter_7zip.so": ("openArchive", "closeArchive", "getArchiveFileCount", "getArchiveFile", "readArchiveFile", "extractArchiveToFile", "freeReadData"),
}


def compile_libraries(native, output):
    suffix = ".exe" if os.name == "nt" else ""
    clang = native / f"llvm/bin/clang{suffix}"
    cxx = native / f"llvm/bin/clang++{suffix}"
    flags = ["--target=aarch64-linux-ohos", f"--sysroot={native / 'sysroot'}",
             "-D__MUSL__", "-D_GNU_SOURCE", "-DDART_SHARED_LIB", "-fPIC", "-O2"]
    link = ["-shared", "-Wl,--no-undefined"]
    run([clang, *flags, *link, "-Wl,-soname,liblodepng_flutter.so",
         DEPS / "lodepng_flutter/src/lodepng.c", "-o", output / "liblodepng_flutter.so"])
    run([cxx, *flags, "-std=c++17", *link, "-Wl,-soname,libzip_flutter.so",
         DEPS / "zip_flutter/src/zip.cc", "-o", output / "libzip_flutter.so"])
    source = DEPS / "flutter_7zip/src"
    c_source = source / "7zip/C"
    objects = require_within(output.parent / "7zip-objects", BASE)
    objects.mkdir(parents=True, exist_ok=True)
    names = ("7zAlloc", "7zArcIn", "7zBuf", "7zBuf2", "7zCrc", "7zCrcOpt", "7zDec",
             "7zFile", "7zStream", "Bcj2", "Bra", "Bra86", "Delta", "LzmaDec", "Lzma2Dec", "CpuArch")
    compiled = []
    for name in names:
        obj = objects / f"{name}.o"
        run([clang, *flags, "-std=gnu11", "-I", c_source, "-c", c_source / f"{name}.c", "-o", obj])
        compiled.append(obj)
    run([cxx, *flags, "-std=c++20", "-I", c_source, *link,
         "-Wl,-soname,libflutter_7zip.so", source / "flutter_7zip.cpp", *compiled,
         "-o", output / "libflutter_7zip.so"])


def inspect_reader_library(native, path):
    record = inspect_library(native, path)
    suffix = ".exe" if os.name == "nt" else ""
    symbols = run([native / f"llvm/bin/llvm-nm{suffix}", "-D", "--defined-only", path], capture=True)
    defined = {line.split()[-1] for line in symbols.splitlines() if line.strip()}
    if not set(EXPORTS[path.name]).issubset(defined):
        raise ValueError(f"Missing reader FFI exports: {path.name}")
    record["checked_exports"] = list(EXPORTS[path.name])
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-native", type=Path, required=True)
    parser.add_argument("--core-native-dir", type=Path, default=BASE / "native")
    parser.add_argument("--output", type=Path, default=BASE / "full-native")
    args = parser.parse_args()
    native = args.sdk_native.resolve()
    core = verify_native_report(args.core_native_dir / "native-build.json", args.core_native_dir / "arm64-v8a")
    sdk = json.loads((native / "oh-uni-package.json").read_text(encoding="utf-8-sig"))
    check_native_sdk(sdk, core["sdk_profile"], CONFIG, core.get("sdk_receipt"))
    if sdk["version"] != core["sdk_version"] or int(sdk["apiVersion"]) != core["sdk_api"]:
        raise ValueError("Reader libraries must match the core Native SDK")
    output = require_within(args.output.resolve(), BASE)
    libraries = output / "arm64-v8a"
    libraries.mkdir(parents=True, exist_ok=True)
    report = {"status": "building", "sdk_profile": core["sdk_profile"], "sdk_version": core["sdk_version"],
              "sdk_api": core["sdk_api"], "runtime_verified": False, "dependencies": verify_dependencies(),
              "build_script_sha256": digest(Path(__file__))}
    try:
        compile_libraries(native, libraries)
        report["libraries"] = [inspect_reader_library(native, libraries / name) for name in EXTRA_LIBRARIES]
        report["status"] = "cross_compile_pass"
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
        (output / "extra-native-build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("Audited real reader FFI libraries; device runtime remains unverified.")


if __name__ == "__main__":
    main()
