"""Build the locked plugins' FFI libraries for Linux Flutter unit tests."""

import argparse
import ctypes
import hashlib
import shutil
import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urljoin, urlsplit
from urllib.request import url2pathname


ROOT = Path(__file__).resolve().parents[2]
PACKAGES = ("flutter_qjs", "zip_flutter", "venera_native")


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



LIBRARIES = ('librhttp.so', 'libsqlite3.so', 'libflutter_qjs_plugin.so',
             'libzip_flutter.so', 'libvenera_native.so')


def library_hashes(directory: Path) -> dict[str, str]:
    result = {}
    for name in LIBRARIES:
        path = directory / name
        if not path.is_file():
            raise ValueError(f'Required test library is missing: {path}')
        result[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def load_libraries(directory: Path) -> None:
    for name in LIBRARIES:
        path = directory / name
        ctypes.CDLL(str(path))
        print(f'Ready: {path}', flush=True)


def publish_bundle(directory: Path) -> dict:
    data = {'schema_version': 1, 'libraries': library_hashes(directory)}
    load_libraries(directory)
    (directory / 'libraries.json').write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')
    return data


def verify_bundle(directory: Path) -> None:
    data = json.loads((directory / 'libraries.json').read_text(encoding='utf-8'))
    if data.get('schema_version') != 1 or data.get('libraries') != library_hashes(directory):
        raise ValueError('Test library bundle manifest or hashes do not match')
    load_libraries(directory)


def main() -> None:
    if sys.platform != "linux":
        raise RuntimeError("Linux test libraries must be built on Linux")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true", help="Validate the downloaded bundle without rebuilding")
    args = parser.parse_args()
    if args.verify_only:
        verify_bundle(ROOT / "build/test-native/lib")
        return
    ctypes.CDLL("libsqlite3.so")  # sqlite3's Dart FFI needs the unversioned dev symlink.
    paths = package_paths(ROOT / ".dart_tool/package_config.json")
    build = ROOT / "build/test-native"
    rhttp = build / "lib/librhttp.so"
    ctypes.CDLL(str(rhttp))  # Built and tested by the rhttp-native CI job.
    print(f"Ready: {rhttp}", flush=True)
    # Ship the resolved unversioned library to each fresh shard runner.
    sqlite_dir = subprocess.run(["pkg-config", "--variable=libdir", "sqlite3"], check=True,
                                capture_output=True, text=True).stdout.strip()
    sqlite = (Path(sqlite_dir) / "libsqlite3.so").resolve(strict=True)
    shutil.copy2(sqlite, build / "lib/libsqlite3.so")
    subprocess.run(
        [
            "cmake", "-S", str(Path(__file__).with_name("native_test_libraries")),
            "-B", str(build), "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
            "-DVENERA_NATIVE_BUILD_TESTS=ON",
            *[f"-D{name.upper()}_ROOT={path}" for name, path in paths.items()],
        ],
        check=True,
    )
    subprocess.run(
        ["cmake", "--build", str(build), "--parallel", str(os.cpu_count() or 2)],
        check=True,
    )
    subprocess.run(["ctest", "--test-dir", str(build), "--output-on-failure"], check=True)
    publish_bundle(build / "lib")


if __name__ == "__main__":
    main()
