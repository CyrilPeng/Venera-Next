import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_delivery as delivery


class ReleaseDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.context = {"schema": 1, "source_commit": "a" * 40, "run_id": "77", "version": "1.2.3-rc.1", "build": 42}
        self.environ = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF_TYPE": "branch",
                        "GITHUB_REF": "refs/heads/test/release", "GITHUB_REPOSITORY": delivery.REPOSITORY}
        self.paths = {name: self.root / name for name in ("linux~rc.deb", "app.ipa")}
        for name, path in self.paths.items():
            path.write_bytes(("Original compiler bytes " + name).encode())
        self.records = delivery.assets.file_records(self.paths.values())
        self.manifest = self.root / delivery.PROOF
        self.manifest.write_text("Source-bound compiler manifest")
        self.receipt = self.root / "receipt.json"
        self.remote = {"id": 99, "tag_name": "rehearsal-77-1", "target_commitish": "a" * 40,
                       "draft": True, "prerelease": True, "assets": [], "html_url": "https://example.invalid/release"}
        self.patches = [
            patch.object(delivery, "validate_inputs", return_value=(self.context, self.paths, self.records)),
            patch.object(delivery, "find_release", return_value=None),
            patch.object(delivery, "read_release", side_effect=lambda identifier: copy.deepcopy(self.remote)),
            patch.object(delivery, "gh", side_effect=lambda *args: json.dumps(self.remote)),
            patch.object(delivery, "upload_asset", side_effect=self.upload),
            patch.object(delivery, "download_files", return_value=2),
        ]
        self.mocks = [item.start() for item in self.patches]
        for item in self.patches:
            self.addCleanup(item.stop)

    def upload(self, identifier, path):
        self.assertEqual(identifier, 99)
        record = self.records[path.name]
        item = {"id": 100 + len(self.remote["assets"]), "name": path.name.replace("~", "."), "state": "uploaded",
                "size": record["bytes"], "digest": "sha256:" + record["sha256"]}
        self.remote["assets"].append(item)
        return item

    def test_interrupted_draft_recovers_the_same_original_assets_and_cleanup_is_repeatable(self):
        status = delivery.rehearse(self.root, self.root, self.manifest, self.receipt, self.environ, interrupt=True)
        self.assertEqual(status, delivery.INTERRUPTED)
        first = copy.deepcopy(self.remote["assets"][0])
        self.assertEqual(first["name"], "linux.rc.deb")
        self.assertEqual(delivery.rehearse(self.root, self.root, self.manifest, self.receipt, self.environ, resume=True), 0)
        self.assertEqual(self.remote["assets"][0], first)
        self.assertTrue(json.loads(self.receipt.read_text())["recovery_verified"])
        self.mocks[3].reset_mock()
        delivery.cleanup_rehearsal(self.receipt, self.environ)
        delivery.cleanup_rehearsal(self.receipt, self.environ)
        self.mocks[3].assert_called_once_with("api", "--method", "DELETE", f"repos/{delivery.REPOSITORY}/releases/99")

    def test_tag_dispatch_foreign_sources_and_public_releases_cannot_be_used_or_deleted(self):
        with self.assertRaisesRegex(ValueError, "branch dispatch"):
            delivery.rehearse(self.root, self.root, self.manifest, self.receipt,
                              self.environ | {"GITHUB_REF_TYPE": "tag"})
        self.mocks[3].assert_not_called()
        delivery.rehearse(self.root, self.root, self.manifest, self.receipt, self.environ, interrupt=True)
        for change in ({"draft": False}, {"target_commitish": "b" * 40}, {"tag_name": "v1.2.3"}):
            original = copy.deepcopy(self.remote)
            self.remote.update(change)
            self.mocks[3].reset_mock()
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, "Rehearsal draft"):
                delivery.cleanup_rehearsal(self.receipt, self.environ)
            self.mocks[3].assert_not_called()
            self.remote = original

    def test_download_stream_rejects_bytes_that_disagree_with_uploaded_digest(self):
        self.upload(99, self.paths["app.ipa"])
        records = {"app.ipa": self.records["app.ipa"]}
        self.patches[-1].stop()
        for corrupted in (False, True):
            def run(command, **kwargs):
                kwargs["stdout"].write(b"Corrupt download" if corrupted else self.paths["app.ipa"].read_bytes())
                return subprocess.CompletedProcess(command, 0)
            with self.subTest(corrupted=corrupted), patch.object(delivery.subprocess, "run", side_effect=run):
                if corrupted:
                    with self.assertRaisesRegex(ValueError, "Downloaded bytes differ"):
                        delivery.download_files(self.remote, records)
                else:
                    self.assertEqual(delivery.download_files(self.remote, records), 1)

    def test_already_published_release_is_verified_without_publishing_again(self):
        self.remote.update(tag_name="v1.2.3-rc.1", body="Original notes")
        for path in self.paths.values():
            self.upload(99, path)
        expected = {"schema": 3, "tagged": True, "preview": False, "source_mode": "release_commit",
                    "distribution": "independent_beta", "release_commit": "a" * 40,
                    "tag": self.remote["tag_name"], "version": self.context["version"]}
        notes = self.root / "notes.md"
        notes.write_text("Original notes")
        def publish(*args):
            self.assertIn("--latest=false", args)
            self.remote["draft"] = False
            return ""
        with patch.object(delivery, "production_inputs", return_value=(self.context, self.paths, self.records, expected, {})), \
                patch.object(delivery, "find_release", side_effect=lambda tag: copy.deepcopy(self.remote)), \
                patch.object(delivery.harmony, "check_runtime", return_value=True), \
                patch.object(delivery, "check_report"), patch.object(delivery, "gh", side_effect=publish) as github:
            for _ in range(2):
                delivery.production(self.root, self.root, self.root, self.manifest, notes, self.receipt, {},
                                    publish=True, security={})
            github.assert_called_once()
        self.assertEqual(json.loads(self.receipt.read_text())["state"], "published_verified")


if __name__ == "__main__":
    unittest.main()
