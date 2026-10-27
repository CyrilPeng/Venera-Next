"""Install a checksum-pinned, publicly mirrored SDK on a disposable Linux runner."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


def file_digest(path):
    with Path(path).open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def verify_archive(path, asset):
    if not asset["sha256"]:
        raise ValueError("Unpinned SDK archive: record the observed digest before extracting or executing it")
    if path.stat().st_size != asset["bytes"] or file_digest(path) != asset["sha256"]:
        raise ValueError(f"SDK archive size/checksum mismatch: {asset['name']}")


def archive_records(config):
    return [{key: asset[key] for key in ("name", "bytes", "sha256")}
            for asset in config["harmonyCiSdk"]["archives"]]


def prepare_archive(downloads, baseline):
    for asset in baseline["archives"]:
        verify_archive(downloads / asset["name"], asset)
    if "joinedArchive" not in baseline:
        return downloads / baseline["archives"][0]["name"]
    joined = downloads / baseline["joinedArchive"]
    if joined.name in {asset["name"] for asset in baseline["archives"]}:
        raise ValueError("Joined archive must not overwrite a source part")
    with joined.open("xb") as output:
        for asset in baseline["archives"]:
            with (downloads / asset["name"]).open("rb") as source:
                shutil.copyfileobj(source, output, length=1024 * 1024)
    for asset in baseline["archives"]:
        (downloads / asset["name"]).unlink()
    return joined


def check_native_sdk(metadata, profile, config, receipt=None):
    if profile not in ("public", "harmony-ci"):
        raise ValueError("Unknown native SDK profile")
    baseline = config["nativeSdk" if profile == "public" else "harmonyCiSdk"]
    if str(metadata.get("apiVersion")) != str(baseline["api"]):
        raise ValueError("Native SDK API does not match the selected baseline")
    version = metadata.get("version")
    if not isinstance(version, str) or not version:
        raise ValueError("Missing native SDK component version")
    expected_version = baseline.get("version" if profile == "public" else "nativeVersion")
    if expected_version is not None and version != expected_version:
        raise ValueError("Native SDK component version does not match the pinned baseline")
    if profile == "harmony-ci":
        if any(not re.fullmatch(r"[a-f0-9]{64}", asset.get("sha256") or "")
               for asset in baseline["archives"]):
            raise ValueError("An unpinned CI SDK cannot be used for native builds")
        if not receipt or receipt.get("status") != "verified":
            raise ValueError("The CI SDK requires a successful archive verification receipt")
        if receipt.get("archives") != archive_records(config):
            raise ValueError("CI SDK receipt does not match the pinned archive digests")
        observed = receipt.get("native", {})
        if (observed.get("version") != version or
                str(observed.get("apiVersion")) != str(baseline["api"])):
            raise ValueError("CI SDK receipt and native component metadata differ")


def check_report_sdk(report, config):
    profile = report.get("sdk_profile")
    check_native_sdk({"version": report.get("sdk_version"),
                      "apiVersion": report.get("sdk_api")},
                     profile, config, report.get("sdk_receipt"))


def install(destination, downloads, report_path, config):
    destination.mkdir(parents=True, exist_ok=False)
    downloads.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report = {"status": "installing", "source": config["harmonyCiSdk"]["source"],
              "checksum_source": config["harmonyCiSdk"]["checksumSource"],
              "archives": archive_records(config)}
    try:
        for asset in config["harmonyCiSdk"]["archives"]:
            archive = downloads / asset["name"]
            subprocess.run(["curl", "--fail", "--location", "--retry", "4",
                            "--retry-all-errors", "--silent", "--show-error",
                            "--output", str(archive), asset["url"]], check=True)
            observed = {"name": archive.name, "bytes": archive.stat().st_size,
                        "sha256": file_digest(archive)}
            report.setdefault("observed_archives", []).append(observed)
            print("Observed archive: " + json.dumps(observed), flush=True)
            verify_archive(archive, asset)
            print(f"Verified {asset['name']}: {asset['sha256']}", flush=True)
        archive = prepare_archive(downloads, config["harmonyCiSdk"])
        report["assembled_archive"] = {"name": archive.name, "bytes": archive.stat().st_size,
                                       "sha256": file_digest(archive)}
        subprocess.run(["7z", "x", str(archive),
                        f"-o{destination}", "-y", "-bsp0"], check=True)
        root = destination / "command-line-tools"
        native = root / "sdk/default/openharmony/native"
        metadata = json.loads((native / "oh-uni-package.json").read_text(encoding="utf-8-sig"))
        report["native"] = metadata
        report["sdk_directories"] = sorted(path.name for path in (root / "sdk/default").iterdir())
        report["sdk_package"] = (root / "sdk/default/sdk-pkg.json").read_text(encoding="utf-8-sig")
        print(json.dumps(report, indent=2), flush=True)
        # The genuine CLI uses sdk-pkg.json; an hmscore directory is not required.
        for path in (root / "sdk/default/sdk-pkg.json",
                     root / "sdk/default/openharmony/ets/oh-uni-package.json",
                     root / "sdk/default/openharmony/toolchains/hdc",
                     native / "llvm/bin/clang", root / "tool/node/bin/node"):
            if not path.exists():
                raise ValueError(f"Missing genuine command-line SDK component: {path.name}")
        report.update(status="verified", native=metadata)
        check_native_sdk(metadata, "harmony-ci", config, report)
        paths = [root / name for name in ("bin", "ohpm/bin", "hvigor/bin",
                                         "tool/node/bin", "sdk/default/openharmony/toolchains")]
        if not any((path / "ohpm").is_file() for path in paths):
            raise ValueError("SDK does not contain an ohpm launcher")
        if not any((path / "hvigorw").is_file() for path in paths):
            raise ValueError("SDK does not contain a hvigorw launcher")
        with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as env:
            env.write(f"DEVECO_SDK_HOME={root / 'sdk'}\nHOS_SDK_HOME={root / 'sdk'}\n"
                      f"NODE_HOME={root / 'tool/node'}\nHARMONY_NATIVE_SDK={native}\n")
        with Path(os.environ["GITHUB_PATH"]).open("a", encoding="utf-8") as env_path:
            env_path.writelines(f"{path}\n" for path in paths if path.is_dir())
        for asset in config["harmonyCiSdk"]["archives"]:
            (downloads / asset["name"]).unlink(missing_ok=True)
        archive.unlink(missing_ok=True)
    except Exception as error:
        report.update(status="failed", error_type=type(error).__name__)
        raise
    finally:
        report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--downloads", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(Path(__file__).with_name("toolchain.json").read_text())
    install(args.destination.resolve(), args.downloads.resolve(), args.report.resolve(), config)


if __name__ == "__main__":
    main()
