import copy
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_assets as assets


def tar_bytes(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as archive:
        for name, data in files.items():
            member = tarfile.TarInfo(name)
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
    return output.getvalue()


def deb_bytes(files, control):
    output = bytearray(b"!<arch>\n")
    for name, data in {"debian-binary": b"2.0\n", "control.tar.gz": tar_bytes({"control": control}),
                       "data.tar.gz": tar_bytes(files)}.items():
        output.extend(f"{name + '/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode())
        output.extend(data)
        if len(data) % 2:
            output.extend(b"\n")
    return bytes(output)


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sources = {
            "release.json": b'{"version":"1.2.3","build":42}',
            "pubspec.yaml": b"name: fixture\nversion: 1.2.3+42\n# fonts:\n",
            "CHANGELOG.md": b"# Changes\n\n## v1.2.3\n\nRelease.\n",
            assets.NOTICE_SOURCE: b"Reviewed native library notice\n",
            "patch/font.dart": ('"""' + assets.FONT_PATCH + '"""').encode(),
        }
        for name, value in self.sources.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(value)
        self.git("init", "-q")
        self.git("add", ".")
        self.git("commit", "-qm", "test(release): 固定包核验来源夹具")
        self.context = assets.source_context(self.root, {"GITHUB_RUN_ID": "77"})

    def git(self, *arguments):
        return subprocess.check_output(["git", "-C", str(self.root), "-c", "user.name=Fixture",
                                        "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
                                        *arguments], stderr=subprocess.PIPE, timeout=30).decode().strip()

    def payload(self, *, font=False):
        pubspec = self.sources["pubspec.yaml"]
        if font:
            pubspec = pubspec.replace(b"# fonts:", assets.FONT_PATCH.encode())
        files = {"pubspec.yaml": pubspec, "CHANGELOG.md": self.sources["CHANGELOG.md"],
                 assets.NOTICE: self.sources[assets.NOTICE_SOURCE]}
        if font:
            files[assets.FONT_ASSET] = b"\0\1\0\0reviewed font fixture"
            files["FontManifest.json"] = json.dumps([
                {"family": "HarmonyOS Sans", "fonts": [{"asset": assets.FONT_ASSET}]}]).encode()
        return files

    def test_source_is_canonical_and_manifest_covers_stable_and_native_rc_names(self):
        (self.root / "pubspec.yaml").write_bytes(b"Dirty working tree is not the package oracle")
        self.assertEqual(assets.source_context(self.root, {"GITHUB_RUN_ID": "77"}), self.context)
        with self.assertRaisesRegex(ValueError, "exact commit"):
            assets.source_context(self.root, {"GITHUB_SHA": "0" * 40})
        for version in ("1.2.3", "1.2.3-rc.1"):
            expected = assets.expected_files(self.context | {"version": version})
            self.assertEqual(sum(map(len, expected.values())), 21)
            self.assertIn(f"venera-next-{version.replace('-', '_')}-42-x86_64.pkg.tar.zst", expected["linux_x64"])
            self.assertIn(f"venera-next_{version.replace('-', '~')}_arm64.deb", expected["linux_arm64"])

    def test_font_transform_and_encoded_asset_are_exact_and_missing_or_wrong_content_fails(self):
        original = self.payload(font=True)
        assets.check_payload(original.__getitem__, set(original), "", self.root, self.context, font=True)
        windows_text = original | {assets.NOTICE: original[assets.NOTICE].replace(b"\n", b"\r\n")}
        assets.check_payload(windows_text.__getitem__, set(windows_text), "", self.root, self.context, font=True)
        for name in ("pubspec.yaml", "CHANGELOG.md", assets.NOTICE, assets.FONT_ASSET, "FontManifest.json"):
            with self.subTest(name=name):
                changed = original | {name: b"Invalid contents"}
                with self.assertRaises((ValueError, KeyError)):
                    assets.check_payload(changed.__getitem__, set(changed), "", self.root, self.context, font=True)
        missing = original.copy()
        del missing[assets.FONT_ASSET]
        with self.assertRaisesRegex(ValueError, "font asset"):
            assets.check_payload(missing.__getitem__, set(missing), "", self.root, self.context, font=True)

    def test_real_deb_container_checks_upgrade_directory_and_both_architectures(self):
        for architecture, machine in (("amd64", 62), ("arm64", 183)):
            header = bytearray(64)
            header[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", header, 18, machine)
            payload = self.payload(font=architecture == "arm64")
            control = f"Package: venera-next\nVersion: 1.2.3\nArchitecture: {architecture}\n".encode()
            for prefix in ("usr/local/lib/venera-next/", "opt/wrong-install-directory/"):
                with self.subTest(architecture=architecture, prefix=prefix):
                    files = {prefix + "venera-next": bytes(header),
                             **{prefix + "data/flutter_assets/" + name: data for name, data in payload.items()}}
                    package = self.root / "fixture.deb"
                    package.write_bytes(deb_bytes(files, control))
                    if prefix.startswith("usr/"):
                        assets.check_deb(package, architecture, self.root, self.context)
                        with self.assertRaisesRegex(ValueError, "architecture"):
                            assets.check_deb(package, "arm64" if architecture == "amd64" else "amd64", self.root, self.context)
                    else:
                        with self.assertRaises(KeyError):
                            assets.check_deb(package, architecture, self.root, self.context)

    def test_complete_aggregate_rejects_missing_extra_changed_and_foreign_receipts(self):
        output, receipts = self.root / "output", self.root / "receipts"
        output.mkdir()
        receipts.mkdir()
        expected = assets.expected_files(self.context)
        for platform, names in expected.items():
            for name in names:
                (output / name).write_bytes(("Compiler output " + name).encode())
            assets.write_receipt(receipts / f"{platform}.json", self.context | {
                "platform": platform, "contents_verified": True,
                "files": assets.file_records([output / name for name in names])})
        receipt = assets.aggregate(output, receipts, self.context)
        self.assertEqual(len(receipt["files"]), 21)
        path = output / next(iter(expected["windows"]))
        original = path.read_bytes()
        path.write_bytes(b"Changed after native package verification")
        with self.assertRaisesRegex(ValueError, "compiler receipt"):
            assets.aggregate(output, receipts, self.context)
        path.write_bytes(original)
        path.unlink()
        with self.assertRaisesRegex(ValueError, "Missing or unexpected"):
            assets.aggregate(output, receipts, self.context)
        path.write_bytes(original)
        (output / "unexpected.hap").write_bytes(b"Independent beta")
        with self.assertRaisesRegex(ValueError, "Missing or unexpected"):
            assets.aggregate(output, receipts, self.context)
        (output / "unexpected.hap").unlink()
        foreign = json.loads((receipts / "windows.json").read_text()) | {"source_commit": "0" * 40}
        assets.write_receipt(receipts / "windows.json", foreign)
        with self.assertRaisesRegex(ValueError, "Wrong compiler source"):
            assets.aggregate(output, receipts, self.context)

    def test_partial_upload_never_accepts_replaced_or_ambiguous_packages(self):
        files = {"linux~rc.deb": {"bytes": 7, "sha256": "a" * 64}, "app.ipa": {"bytes": 8, "sha256": "b" * 64}}
        remote = {"assets": [{"name": "linux.rc.deb", "state": "uploaded", "size": 7, "digest": "sha256:" + "a" * 64}]}
        self.assertEqual(assets.check_remote_files(remote, files, partial=True), {"app.ipa"})
        for field, value in (("size", 1), ("digest", "sha256:" + "0" * 64), ("state", "starter")):
            changed = copy.deepcopy(remote)
            changed["assets"][0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "original build"):
                assets.check_remote_files(changed, files, partial=True)
        with self.assertRaisesRegex(ValueError, "collide"):
            assets.github_file_records(files | {"linux.rc.deb": files["linux~rc.deb"]})
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            assets.safe_names(["../outside.txt"])


if __name__ == "__main__":
    unittest.main()
