"""Cross-build the existing core libraries; this is NOT a device acceptance test."""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import struct
import subprocess
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CONFIG = json.loads(Path(__file__).with_name("toolchain.json").read_text())
TARGET = CONFIG["rust"]["target"]
OUTPUT = ROOT / "build/harmonyos/native/arm64-v8a"

SQLITE_DEFINES = (
    "SQLITE_ENABLE_DBSTAT_VTAB", "SQLITE_ENABLE_FTS5", "SQLITE_ENABLE_RTREE",
    "SQLITE_ENABLE_MATH_FUNCTIONS", "SQLITE_DQS=0", "SQLITE_DEFAULT_MEMSTATUS=0",
    "SQLITE_TEMP_STORE=2", "SQLITE_MAX_EXPR_DEPTH=0", "SQLITE_STRICT_SUBTYPE=1",
    "SQLITE_OMIT_AUTHORIZATION", "SQLITE_OMIT_DECLTYPE", "SQLITE_OMIT_DEPRECATED",
    "SQLITE_OMIT_PROGRESS_CALLBACK", "SQLITE_OMIT_SHARED_CACHE",
    "SQLITE_OMIT_TCL_VARIABLE", "SQLITE_OMIT_TRACE", "SQLITE_USE_ALLOCA",
    "SQLITE_ENABLE_SESSION", "SQLITE_ENABLE_PREUPDATE_HOOK", "SQLITE_UNTESTABLE",
    "SQLITE_HAVE_ISNAN", "SQLITE_HAVE_LOCALTIME_R", "SQLITE_HAVE_MALLOC_USABLE_SIZE",
    "SQLITE_HAVE_STRCHRNUL",
)


def digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def run(args, *, env=None, capture=False):
    print("RUN", " ".join(map(str, args)), flush=True)
    return subprocess.run(
        list(map(str, args)), cwd=ROOT, env=env, check=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        encoding="utf-8", errors="replace",
    ).stdout


def require_within(path, parent):
    path, parent = Path(path).resolve(), Path(parent).resolve()
    if path == parent or not path.is_relative_to(parent):
        raise ValueError(f"Output must be strictly inside {parent}")
    return path


def validate_elf(data):
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise ValueError("Expected a 64-bit little-endian ELF library")
    if struct.unpack_from("<HH", data, 16) != (3, 183):
        raise ValueError("Expected an AArch64 shared object")


def source_fingerprint():
    source = ROOT / "packages/rhttp/rust"
    files = [source / "Cargo.toml", source / "Cargo.lock"]
    files.extend(sorted((source / "src").rglob("*.rs")))
    result = hashlib.sha256()
    for path in files:
        result.update(path.relative_to(source).as_posix().encode() + b"\0")
        result.update(path.read_bytes())
    return result.hexdigest()


def build_fingerprint():
    return digest(__file__) + ":" + digest(Path(__file__).with_name("toolchain.json"))


def check_qjs_source(source):
    head = run(["git", "-C", source, "rev-parse", "HEAD"], capture=True).strip()
    if head != CONFIG["quickjs"]["revision"]:
        raise ValueError("QuickJS source must match the application's pinned fork")
    run(["git", "-C", source, "diff", "--exit-code", "HEAD", "--", "cxx", "lib"])
    return head


def build_qjs(native, source, output):
    check_qjs_source(source)
    cxx = source / "cxx"
    qjs = cxx / "quickjs-ng"
    version = (qjs / "VERSION").read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9.+-]+", version):
        raise ValueError("Invalid QuickJS version macro")
    objects = output.parent / "qjs-objects"
    objects.mkdir(exist_ok=True)
    common = ["--target=aarch64-linux-ohos", f"--sysroot={native / 'sysroot'}",
              "-D__MUSL__", "-D_GNU_SOURCE", "-fPIC", "-O2"]
    compiled = []
    for name in ("cutils.c", "libregexp.c", "libunicode.c", "quickjs.c", "libbf.c"):
        obj = objects / (name + ".o")
        run([native / "llvm/bin/clang", *common, "-std=gnu11",
             f'-DCONFIG_VERSION="{version}"', "-DDUMP_LEAKS",
             "-c", qjs / name, "-o", obj])
        compiled.append(obj)
    run([native / "llvm/bin/clang++", *common, "-std=c++17", "-shared",
         "-Wl,--no-undefined", "-Wl,-soname,libqjs.so", cxx / "ffi.cpp",
         *compiled, "-pthread", "-lm", "-o", output / "libqjs.so"])


def build_sqlite(native, source, output):
    if digest(source) != CONFIG["sqlite"]["amalgamationSha256"]:
        raise ValueError("SQLite source differs from the pinned amalgamation")
    run([native / "llvm/bin/clang", "--target=aarch64-linux-ohos",
         f"--sysroot={native / 'sysroot'}", "-D__MUSL__", "-D_GNU_SOURCE",
         "-fPIC", "-O2", "-shared", "-Wl,--no-undefined",
         "-Wl,-soname,libsqlite3.so", *[f"-D{name}" for name in SQLITE_DEFINES],
         source, "-lm", "-ldl", "-pthread", "-o", output / "libsqlite3.so"])


def target_cflags(native):
    return shlex.join(["--target=aarch64-linux-ohos",
                       f"--sysroot={native.as_posix()}/sysroot", "-D__MUSL__"])


def build_rust(native, output):
    env = os.environ.copy()
    # Keep host build-script flags separate from the OHOS target flags.
    env.pop("RUSTFLAGS", None)
    env["CARGO_ENCODED_RUSTFLAGS"] = "\x1f".join([
        "--cfg", "reqwest_unstable", "-C", "link-arg=--target=aarch64-linux-ohos",
        "-C", f"link-arg=--sysroot={native / 'sysroot'}",
        "-C", "link-arg=-Wl,--no-undefined",
    ])
    suffix = ".exe" if os.name == "nt" else ""
    tools = native / "llvm/bin"
    env[f"CARGO_TARGET_{TARGET.upper().replace('-', '_')}_LINKER"] = str(tools / ("clang" + suffix))
    env["CC_aarch64_unknown_linux_ohos"] = str(tools / ("clang" + suffix))
    env["CXX_aarch64_unknown_linux_ohos"] = str(tools / ("clang++" + suffix))
    env["AR_aarch64_unknown_linux_ohos"] = str(tools / ("llvm-ar" + suffix))
    # cc-rs otherwise passes embedded quotes literally to clang on Windows.
    env["CC_SHELL_ESCAPED_FLAGS"] = "1"
    flags = target_cflags(native)
    env["CFLAGS_aarch64_unknown_linux_ohos"] = flags
    env["CXXFLAGS_aarch64_unknown_linux_ohos"] = flags
    target_dir = ROOT / "build/harmonyos/cargo"
    env["CARGO_TARGET_DIR"] = str(target_dir)
    run(["cargo", "build", "--locked", "--release", "--lib", "--jobs", "2",
         "--target", TARGET, "--manifest-path", "packages/rhttp/rust/Cargo.toml"], env=env)
    shutil.copy2(target_dir / TARGET / "release/librhttp.so", output / "librhttp.so")


def inspect_library(native, path):
    validate_elf(path.read_bytes())
    suffix = ".exe" if os.name == "nt" else ""
    info = run([native / f"llvm/bin/llvm-readelf{suffix}", "--dynamic", path], capture=True)
    needed = re.findall(r"\(NEEDED\).*?\[(.*?)\]", info)
    if any(name in needed for name in ("liblog.so", "libandroid.so")):
        raise ValueError(f"Unexpected Android linkage in {path.name}")
    unexpected = set(needed) - {"libc.so", "libc++_shared.so"}
    if unexpected:
        raise ValueError(f"Review unbundled dependencies in {path.name}: {unexpected}")
    symbols = run([native / f"llvm/bin/llvm-nm{suffix}", "-D", "--defined-only", path], capture=True)
    required = {
        "librhttp.so": ("frb_get_rust_content_hash", "frb_init_frb_dart_api_dl",
                        "frb_pde_ffi_dispatcher_primary", "frb_pde_ffi_dispatcher_sync"),
        "libqjs.so": ("jsNewRuntime", "jsEval", "jsFreeRuntime"),
        "libsqlite3.so": ("sqlite3_open_v2", "sqlite3_close_v2", "sqlite3session_create"),
    }.get(path.name, ())
    exported = {line.split()[-1] for line in symbols.splitlines() if line.strip()}
    if not set(required).issubset(exported):
        raise ValueError(f"Missing FFI exports in {path.name}")
    return {"name": path.name, "bytes": path.stat().st_size,
            "sha256": digest(path), "needed": needed, "checked_exports": required}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-native", type=Path, required=True)
    parser.add_argument("--qjs-source", type=Path, required=True)
    parser.add_argument("--sqlite-source", type=Path, required=True)
    parser.add_argument("--component", choices=("all", "qjs", "sqlite", "rust"), default="all")
    args = parser.parse_args()
    native = args.sdk_native.resolve()
    sdk = json.loads((native / "oh-uni-package.json").read_text(encoding="utf-8-sig"))
    if sdk["version"] != CONFIG["nativeSdk"]["version"]:
        raise ValueError("Unexpected native SDK; update the pinned baseline deliberately")
    output = require_within(OUTPUT, ROOT / "build/harmonyos")
    output.mkdir(parents=True, exist_ok=True)
    report_path = output.parent / "native-build.json"
    report = {"status": "building", "component": args.component,
              "target": TARGET, "sdk_version": sdk["version"],
              "runtime_verified": False, "hap_built": False}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    builders = {"qjs": lambda: build_qjs(native, args.qjs_source.resolve(), output),
                "sqlite": lambda: build_sqlite(native, args.sqlite_source.resolve(), output),
                "rust": lambda: build_rust(native, output)}
    try:
        for component in builders:
            if args.component in ("all", component):
                builders[component]()
        if args.component == "all":
            runtime = native / "llvm/lib/aarch64-linux-ohos/libc++_shared.so"
            if not runtime.is_file():
                runtime = native / "sysroot/usr/lib/aarch64-linux-ohos/libc++_shared.so"
            shutil.copy2(runtime, output / "libc++_shared.so")
            report["libraries"] = [inspect_library(native, output / name) for name in (
                "librhttp.so", "libqjs.so", "libsqlite3.so", "libc++_shared.so")]
            report["rhttp_source_sha256"] = source_fingerprint()
            report["build_fingerprint"] = build_fingerprint()
            report["quickjs_revision"] = CONFIG["quickjs"]["revision"]
            report["sqlite_source_sha256"] = CONFIG["sqlite"]["amalgamationSha256"]
            report["status"] = "cross_compile_pass"
        else:
            report["status"] = "partial_compile_pass"
        report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
    except Exception as error:
        report["status"] = "failed"
        report["error_type"] = type(error).__name__
        raise
    finally:
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
