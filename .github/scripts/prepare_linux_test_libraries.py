"""Build the locked plugins' FFI libraries for Linux Flutter unit tests."""

import ctypes
import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ("flutter_qjs", "zip_flutter", "flutter_7zip", "lodepng_flutter")


def package_paths(config: Path) -> dict[str, Path]:
    config = config.resolve()
    packages = json.loads(config.read_text(encoding="utf-8"))["packages"]
    paths = {}
    for package in packages:
        name = package["name"]
        if name not in PACKAGES:
            continue
        uri = urlsplit(urljoin(config.as_uri(), package["rootUri"]))
        if uri.scheme != "file" or uri.netloc:
            raise ValueError(f"{name}: expected a local package root")
        path = Path(url2pathname(uri.path)).resolve()
        source = "cxx/quickjs.cmake" if name == "flutter_qjs" else "src/CMakeLists.txt"
        if not (path / source).is_file():
            raise ValueError(f"{name}: native sources missing at {path}")
        paths[name] = path
    missing = set(PACKAGES) - paths.keys()
    if missing:
        raise ValueError(f"Run flutter pub get first; missing packages: {sorted(missing)}")
    return paths


def main() -> None:
    if sys.platform != "linux":
        raise RuntimeError("Linux test libraries must be built on Linux")
    ctypes.CDLL("libsqlite3.so")  # sqlite3's Dart FFI needs the unversioned dev symlink.
    paths = package_paths(ROOT / ".dart_tool/package_config.json")
    build = ROOT / "build/test-native"
    rhttp = build / "lib/librhttp.so"
    ctypes.CDLL(str(rhttp))  # Built and tested by the rhttp-native CI job.
    print(f"Ready: {rhttp}", flush=True)
    subprocess.run(
        [
            "cmake", "-S", str(Path(__file__).with_name("native_test_libraries")),
            "-B", str(build), "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
            *[f"-D{name.upper()}_ROOT={path}" for name, path in paths.items()],
        ],
        check=True,
    )
    subprocess.run(
        ["cmake", "--build", str(build), "--parallel", str(os.cpu_count() or 2)],
        check=True,
    )
    for name in PACKAGES:
        library = "flutter_qjs_plugin" if name == "flutter_qjs" else name
        path = build / "lib" / f"lib{library}.so"
        ctypes.CDLL(str(path))  # Fail here on unresolved symbols, before tests hang.
        print(f"Ready: {path}", flush=True)


if __name__ == "__main__":
    main()
