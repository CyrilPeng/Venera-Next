"""Prepare and check every qualifier of the native launcher label."""

import json
import struct


APP_LABEL = "VeneraNext"
LABEL_RESOURCES = {"app_name", "EntryAbility_label"}


def configure_app_labels(project):
    roots = (project / "ohos/AppScope/resources",
             project / "ohos/entry/src/main/resources")
    for root in roots:
        for strings in root.glob("*/element/string.json"):
            data = json.loads(strings.read_text(encoding="utf-8"))
            for item in data["string"]:
                if item["name"] in LABEL_RESOURCES:
                    item["value"] = APP_LABEL
            strings.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for root, name in zip(roots, ("app_name", "EntryAbility_label")):
        data = json.loads((root / "base/element/string.json").read_text(encoding="utf-8"))
        if [item["value"] for item in data["string"] if item["name"] == name] != [APP_LABEL]:
            raise ValueError("Missing native launcher label resource: " + name)


def compiled_label_values(data, resource_ids):
    # The pinned RestoolV2 index uses a 140-byte header and a DATA table of
    # resource IDs, qualifier IDs and absolute offsets to UTF-8 strings.
    # See OpenHarmony global_resource_management's ResIndexHeader/ResInfo.
    def unpack(pattern, offset):
        length = struct.calcsize(pattern)
        if offset < 0 or offset + length > len(data):
            raise ValueError("Truncated native label resource index")
        return struct.unpack_from(pattern, data, offset)

    if len(data) < 140 or not data.startswith(b"RestoolV2 "):
        raise ValueError("Unsupported native label resource index")
    length, key_count, offset = unpack("<III", 128)
    if length != len(data) or not 0 < key_count <= 4096 or offset < 140:
        raise ValueError("Invalid native label resource header")
    tag, length, count = unpack("<4sII", offset)
    if tag != b"DATA" or length < 12 or offset + length > len(data) or count > length // 12:
        raise ValueError("Invalid native label resource table")
    end = offset + length
    offset += 12
    result = {}
    for _ in range(count):
        resource, size, values = unpack("<III", offset)
        if size != 12 + values * 8 or offset + size > end or not 0 < values <= key_count:
            raise ValueError("Invalid native label qualifier table")
        if resource in resource_ids:
            if resource in result:
                raise ValueError("Duplicate native label resource")
            labels = {}
            for index in range(values):
                qualifier, value_offset = unpack("<II", offset + 12 + index * 8)
                if qualifier in labels or value_offset < end:
                    raise ValueError("Invalid native label value offset")
                string_length, = unpack("<H", value_offset)
                start = value_offset + 2
                if not string_length or start + string_length > len(data):
                    raise ValueError("Truncated native launcher label")
                value = data[start:start + string_length]
                if b"\0" in value:
                    raise ValueError("Invalid native launcher label")
                labels[qualifier] = value.decode("utf-8")
            if 0 not in labels:
                raise ValueError("Missing base native launcher label")
            result[resource] = labels
        offset += size
    if offset != end or set(result) != set(resource_ids):
        raise ValueError("Missing native launcher label values")
    return result


def audit_hap_labels(archive):
    module = json.loads(archive.read("module.json"))
    app = module["app"]
    abilities = module["module"].get("abilities", [])
    launcher = [ability for ability in abilities
                if ability.get("name") == module["module"].get("mainElement")]
    if len(launcher) != 1:
        raise ValueError("Missing unique native launcher ability")
    if app.get("label") != "$string:app_name" or launcher[0].get("label") != "$string:EntryAbility_label":
        raise ValueError("Unexpected native launcher label reference")
    ids = {app.get("labelId"), launcher[0].get("labelId")}
    if len(ids) != 2 or any(type(value) is not int or value <= 0 for value in ids):
        raise ValueError("Missing native launcher label IDs")
    labels = compiled_label_values(archive.read("resources.index"), ids)
    if any(value != APP_LABEL for qualifiers in labels.values() for value in qualifiers.values()):
        raise ValueError("Native launcher label differs across languages")
    return APP_LABEL
