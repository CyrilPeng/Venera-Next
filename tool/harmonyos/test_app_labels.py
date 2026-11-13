import json
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

from app_labels import APP_LABEL, audit_hap_labels, compiled_label_values, configure_app_labels


LABEL_IDS = (0x01000000, 0x01000003)


def label_index(*, translated=APP_LABEL):
    groups = ((LABEL_IDS[0], {0: APP_LABEL}),
              (LABEL_IDS[1], {0: APP_LABEL, 1: translated, 2: translated}))
    table_length = 12 + sum(12 + 8 * len(values) for _, values in groups)
    header = bytearray(140)
    header[:10] = b"RestoolV2 "
    table = bytearray(struct.pack("<4sII", b"DATA", table_length, len(groups)))
    strings = bytearray()
    for resource, values in groups:
        table.extend(struct.pack("<III", resource, 12 + 8 * len(values), len(values)))
        for qualifier, value in values.items():
            offset = 140 + table_length + len(strings)
            table.extend(struct.pack("<II", qualifier, offset))
            encoded = value.encode("utf-8")
            strings.extend(struct.pack("<H", len(encoded)) + encoded)
    struct.pack_into("<III", header, 128, 140 + table_length + len(strings), 3, 140)
    return bytes(header + table + strings)


def label_module():
    return {"app": {"label": "$string:app_name", "labelId": LABEL_IDS[0]},
            "module": {"mainElement": "EntryAbility", "abilities": [
                {"name": "EntryAbility", "label": "$string:EntryAbility_label", "labelId": LABEL_IDS[1]}]}}


class LauncherLabelTests(unittest.TestCase):
    def test_every_language_label_is_updated_without_touching_other_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            for prefix in ("ohos/AppScope/resources", "ohos/entry/src/main/resources"):
                for locale in ("base", "en_US", "zh_CN", "zh_TW"):
                    path = project / prefix / locale / "element/string.json"
                    path.parent.mkdir(parents=True)
                    path.write_text(json.dumps({"string": [
                        {"name": "app_name", "value": "venera_next"},
                        {"name": "EntryAbility_label", "value": "venera_next"},
                        {"name": "EntryAbility_desc", "value": "unchanged"}]}), encoding="utf-8")
            configure_app_labels(project)
            for path in project.rglob("string.json"):
                values = {item["name"]: item["value"] for item in json.loads(path.read_text(encoding="utf-8"))["string"]}
                self.assertEqual(values, {"app_name": APP_LABEL, "EntryAbility_label": APP_LABEL,
                                          "EntryAbility_desc": "unchanged"})

    def test_compiled_base_and_language_overrides_are_checked(self):
        for translation in (APP_LABEL, "venera_next", "VeneraNext (HarmonyOS Beta)"):
            with self.subTest(translation=translation), tempfile.TemporaryDirectory() as temporary:
                file = Path(temporary) / "fixture.hap"
                with zipfile.ZipFile(file, "w") as archive:
                    archive.writestr("module.json", json.dumps(label_module()))
                    archive.writestr("resources.index", label_index(translated=translation))
                with zipfile.ZipFile(file) as archive:
                    if translation == APP_LABEL:
                        self.assertEqual(audit_hap_labels(archive), APP_LABEL)
                    else:
                        with self.assertRaisesRegex(ValueError, "across languages"):
                            audit_hap_labels(archive)

    def test_index_bounds_and_missing_resources_fail_before_publication(self):
        index = label_index()
        for invalid in (b"", index[:139], index[:-1], index[:148] + b"\xff" * 4 + index[152:]):
            with self.subTest(length=len(invalid)), self.assertRaises(ValueError):
                compiled_label_values(invalid, set(LABEL_IDS))
        with self.assertRaisesRegex(ValueError, "Missing"):
            compiled_label_values(index, {0x01000077})


if __name__ == "__main__":
    unittest.main()
