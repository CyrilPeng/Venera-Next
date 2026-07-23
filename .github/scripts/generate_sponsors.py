"""Generate public sponsor data and repository acknowledgements.

The normalized source is synchronized from Afdian OpenAPI into
``.github/data/sponsors.json``. Public sponsors use the following fields:

- name: public display name
- tier: earned display tier (30, 80, or 200)
- status: active or historical
- kind: monthly or oneTime
- startedAt: first sponsorship date (YYYY-MM-DD)
- endedAt: required for historical monthly sponsors
- monthlyAmount: required for monthly sponsors; used to order featured sponsors
- url/image/imageAlt: optional promotion for active tier-200 sponsors only

The CNY 10 monthly tier is intentionally absent because it does not include
public acknowledgement. One-time sponsors that should be acknowledged use the
30 tier and are placed in the historical section.
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = ROOT / ".github" / "data" / "sponsors.json"
JSON_OUTPUT_PATH = ROOT / "sponsors.json"
MARKDOWN_OUTPUT_PATH = ROOT / "SPONSORS.md"
README_PATH = ROOT / "README.md"
README_EN_PATH = ROOT / "README.en.md"

README_START = "<!-- featured-sponsors:start -->"
README_END = "<!-- featured-sponsors:end -->"

VALID_TIERS = {30, 80, 200}
VALID_STATUSES = {"active", "historical"}
VALID_KINDS = {"monthly", "oneTime"}
ALLOWED_FIELDS = {
    "name",
    "tier",
    "status",
    "kind",
    "startedAt",
    "endedAt",
    "monthlyAmount",
    "url",
    "image",
    "imageAlt",
}


@dataclass(frozen=True)
class Sponsor:
    name: str
    tier: int
    status: str
    kind: str
    started_at: date
    ended_at: date | None
    monthly_amount: int | None
    url: str | None
    image: str | None
    image_alt: str | None
    source_index: int


@dataclass(frozen=True)
class SponsorSections:
    featured: tuple[Sponsor, ...]
    current: tuple[Sponsor, ...]
    historical: tuple[Sponsor, ...]

    @property
    def all(self) -> tuple[Sponsor, ...]:
        return self.featured + self.current + self.historical


def _read_text(path: Path) -> str:
    return path.read_bytes().decode("utf-8-sig").replace("\r\n", "\n")


def _required_string(raw: dict, field: str, index: int) -> str:
    value = raw.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"sponsors[{index}].{field} must be a non-empty string")
    return value.strip()


def _optional_string(raw: dict, field: str, index: int) -> str | None:
    value = raw.get(field)
    if value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"sponsors[{index}].{field} must be null or a non-empty string")
    return value.strip()


def _parse_date(value: str | None, field: str, index: int) -> date | None:
    if value is None:
        return None
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise ValueError(
            f"sponsors[{index}].{field} must use YYYY-MM-DD format"
        ) from error


def _validate_https_url(value: str | None, field: str, index: int) -> None:
    if value is None:
        return
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ValueError(f"sponsors[{index}].{field} must be an HTTPS URL")


def _validate_image(value: str | None, index: int) -> None:
    if value is None:
        return
    if value.startswith("assets/") and ".." not in Path(value).parts:
        return
    _validate_https_url(value, "image", index)


def parse_source(payload: object) -> list[Sponsor]:
    if not isinstance(payload, dict):
        raise ValueError("sponsor source must be a JSON object")
    if payload.get("schemaVersion") != 1:
        raise ValueError("sponsor source schemaVersion must be 1")
    raw_sponsors = payload.get("sponsors")
    if not isinstance(raw_sponsors, list):
        raise ValueError("sponsor source sponsors must be a list")

    sponsors: list[Sponsor] = []
    seen_names: set[str] = set()
    for index, raw in enumerate(raw_sponsors):
        if not isinstance(raw, dict):
            raise ValueError(f"sponsors[{index}] must be an object")
        unknown_fields = set(raw) - ALLOWED_FIELDS
        if unknown_fields:
            unknown = ", ".join(sorted(unknown_fields))
            raise ValueError(f"sponsors[{index}] has unknown fields: {unknown}")

        name = _required_string(raw, "name", index)
        if "\n" in name or "\r" in name:
            raise ValueError(f"sponsors[{index}].name must be a single line")
        normalized_name = name.casefold()
        if normalized_name in seen_names:
            raise ValueError(f"duplicate sponsor name: {name}")
        seen_names.add(normalized_name)

        tier = raw.get("tier")
        if type(tier) is not int or tier not in VALID_TIERS:
            raise ValueError(f"sponsors[{index}].tier must be one of 30, 80, or 200")
        status = _required_string(raw, "status", index)
        if status not in VALID_STATUSES:
            raise ValueError(f"sponsors[{index}].status must be active or historical")
        kind = _required_string(raw, "kind", index)
        if kind not in VALID_KINDS:
            raise ValueError(f"sponsors[{index}].kind must be monthly or oneTime")

        started_at = _parse_date(
            _required_string(raw, "startedAt", index), "startedAt", index
        )
        ended_at = _parse_date(_optional_string(raw, "endedAt", index), "endedAt", index)
        monthly_amount = raw.get("monthlyAmount")
        url = _optional_string(raw, "url", index)
        image = _optional_string(raw, "image", index)
        image_alt = _optional_string(raw, "imageAlt", index)

        if kind == "monthly":
            if type(monthly_amount) is not int or monthly_amount < tier:
                raise ValueError(
                    f"sponsors[{index}].monthlyAmount must be an integer no lower than tier"
                )
            if status == "active" and ended_at is not None:
                raise ValueError(f"sponsors[{index}] is active and cannot have endedAt")
            if status == "historical" and ended_at is None:
                raise ValueError(
                    f"sponsors[{index}] is historical monthly and requires endedAt"
                )
        else:
            if status != "historical":
                raise ValueError(f"sponsors[{index}] oneTime sponsors must be historical")
            if tier != 30:
                raise ValueError(f"sponsors[{index}] oneTime sponsors use tier 30")
            if monthly_amount is not None or ended_at is not None:
                raise ValueError(
                    f"sponsors[{index}] oneTime sponsors cannot have monthlyAmount or endedAt"
                )

        if ended_at is not None and started_at is not None and ended_at < started_at:
            raise ValueError(f"sponsors[{index}].endedAt cannot precede startedAt")

        is_featured = kind == "monthly" and status == "active" and tier == 200
        if not is_featured and any((url, image, image_alt)):
            raise ValueError(
                f"sponsors[{index}] promotion fields are reserved for active tier-200 sponsors"
            )
        if image_alt is not None and image is None:
            raise ValueError(f"sponsors[{index}].imageAlt requires image")
        _validate_https_url(url, "url", index)
        _validate_image(image, index)

        sponsors.append(
            Sponsor(
                name=name,
                tier=tier,
                status=status,
                kind=kind,
                started_at=started_at,
                ended_at=ended_at,
                monthly_amount=monthly_amount,
                url=url,
                image=image,
                image_alt=image_alt,
                source_index=index,
            )
        )
    return sponsors


def load_source(path: Path = SOURCE_PATH) -> list[Sponsor]:
    return parse_source(json.loads(_read_text(path)))


def build_sections(sponsors: list[Sponsor]) -> SponsorSections:
    featured = [
        sponsor
        for sponsor in sponsors
        if sponsor.status == "active" and sponsor.tier == 200
    ]
    current = [
        sponsor
        for sponsor in sponsors
        if sponsor.status == "active" and sponsor.tier in {30, 80}
    ]
    historical = [
        sponsor for sponsor in sponsors if sponsor.status == "historical"
    ]

    featured.sort(
        key=lambda sponsor: (
            -(sponsor.monthly_amount or 0),
            sponsor.started_at,
            sponsor.source_index,
        )
    )
    current.sort(key=lambda sponsor: (sponsor.started_at, sponsor.source_index))
    historical.sort(key=lambda sponsor: (sponsor.started_at, sponsor.source_index))
    return SponsorSections(tuple(featured), tuple(current), tuple(historical))


def _public_sponsor(sponsor: Sponsor) -> dict[str, object]:
    return {
        "name": sponsor.name,
        "tier": sponsor.tier,
        "kind": sponsor.kind,
    }


def render_public_json(sections: SponsorSections) -> str:
    payload = {
        "schemaVersion": 2,
        # Keep the flat list for clients released before the sectioned schema.
        "sponsors": [_public_sponsor(sponsor) for sponsor in sections.all],
        "sections": {
            "featured": [
                _public_sponsor(sponsor) for sponsor in sections.featured
            ],
            "current": [_public_sponsor(sponsor) for sponsor in sections.current],
            "historical": [
                _public_sponsor(sponsor) for sponsor in sections.historical
            ],
        },
    }
    return json.dumps(payload, ensure_ascii=False, indent=2) + "\n"


def _escape_markdown(value: str) -> str:
    escaped = value.replace("\\", "\\\\")
    for character in "*_[]<>`":
        escaped = escaped.replace(character, f"\\{character}")
    return escaped


def _markdown_sponsor(sponsor: Sponsor) -> str:
    name = _escape_markdown(sponsor.name)
    if sponsor.url:
        name = f"[{name}]({sponsor.url})"
    if sponsor.tier >= 80:
        name = f"**{name}**"
    if sponsor.tier == 200:
        name = f"👑 {name}"
    detail = "一次性赞助" if sponsor.kind == "oneTime" else f"¥{sponsor.tier} 档"
    return f"- {name}（{detail}）"


def _markdown_section(sponsors: tuple[Sponsor, ...]) -> str:
    if not sponsors:
        return "*暂无*"
    return "\n".join(_markdown_sponsor(sponsor) for sponsor in sponsors)


def render_sponsors_markdown(sections: SponsorSections) -> str:
    return f"""# 赞助者名单

感谢每一位支持 VeneraNext 持续维护的赞助者 ❤️

名单分为置顶赞助、当前赞助者和历史赞助者。停止赞助不会导致昵称被自动移除，但赞助者可以随时申请修改昵称或取消展示。

如果本项目对你的日常阅读有帮助，欢迎通过[爱发电](https://ifdian.net/a/cyril)支持作者。

<!-- 此文件根据爱发电 API 同步结果自动生成，请勿直接编辑名单。 -->

---

## 置顶赞助

{_markdown_section(sections.featured)}

## 当前赞助者

{_markdown_section(sections.current)}

## 历史赞助者

{_markdown_section(sections.historical)}

---

## 赞助档位

- **¥10/月 · 纯爱心赞助**：用于单纯支持项目，不包含公开展示权益。
- **¥30/月 · 加入鸣谢**：昵称将永久加入应用内“关于 -> 赞助者名单”页面和 GitHub 赞助者列表。
- **¥80/月 · 殿堂发电**：包含上一档权益，昵称加粗展示；符合项目方向的 Bug 反馈或功能建议会优先查看和回复，但不保证采纳或实现。
- **¥200/月 · 置顶赞助**：包含上一档权益，赞助期间在名单中置顶并添加 👑 标识；经沟通确认内容合规后，可以在 README 顶部展示 Logo 或横幅。
- **一次性赞助**：单次赞助达到 ¥30 且赞助者同意展示时，进入历史赞助区域，不获得持续置顶或宣传权益。

## 展示与排序规则

- 当前有效的 ¥200/月赞助进入置顶区域，按实际月赞助金额从高到低排序，同金额按开始赞助时间排序。
- 当前有效的 ¥30/月和 ¥80/月赞助进入当前赞助区域，按开始赞助时间排序。
- 已停止的公开赞助和符合条件的一次性赞助进入历史赞助区域，按首次赞助时间排序。
- ¥80 档在当前和历史区域中保留加粗样式，¥200 档在历史区域中保留 👑 标识；停止 ¥200 档赞助后会撤下 README 宣传内容。
- “永久保留”表示停止赞助后不会自动移除；赞助者仍可随时申请修改昵称或取消公开展示。
- 赞助后请在订单备注中填写“公开昵称：你的昵称”；直接填写纯昵称也会兼容识别。昵称需符合社区规范，作者保留调整权。

## 宣传与维护边界

- README 宣传位仅面向当前有效的 ¥200/月赞助，并会明确标注为置顶赞助，不代表项目官方合作或背书。
- Logo、横幅和链接均需人工审核，不接受漫画源、内容分发、侵权内容、博彩、成人内容或其他与项目维护边界冲突的推广。
- Issue 优先关注权益不适用于漫画源、源站内容及其他超出本仓库维护范围的问题。
"""


def _featured_html(sponsor: Sponsor) -> str:
    name = html.escape(sponsor.name)
    url = html.escape(sponsor.url, quote=True) if sponsor.url else None
    if sponsor.image:
        image = html.escape(sponsor.image, quote=True)
        image_alt = html.escape(sponsor.image_alt or sponsor.name, quote=True)
        content = f'<img src="{image}" alt="{image_alt}" height="64" />'
    else:
        content = f"<strong>👑 {name}</strong>"
    if url:
        return f'<a href="{url}">{content}</a>'
    return content


def render_readme_featured(
    sections: SponsorSections,
    label: str = "置顶赞助",
) -> str:
    if not sections.featured:
        return ""
    sponsors = "\n  &nbsp;&nbsp;\n  ".join(
        _featured_html(sponsor) for sponsor in sections.featured
    )
    return f"""<div align="center">
  <sub>{html.escape(label)}</sub><br><br>
  {sponsors}
</div>"""


def replace_marked_block(content: str, replacement: str) -> str:
    start = content.find(README_START)
    end = content.find(README_END)
    if start == -1 or end == -1 or end < start:
        raise ValueError("README featured sponsor markers are missing or invalid")
    end += len(README_END)
    block = README_START
    if replacement:
        block += f"\n{replacement.rstrip()}\n"
    else:
        block += "\n"
    block += README_END
    return content[:start] + block + content[end:]


def generated_outputs() -> dict[Path, str]:
    sections = build_sections(load_source())
    readme = replace_marked_block(
        _read_text(README_PATH), render_readme_featured(sections)
    )
    readme_en = replace_marked_block(
        _read_text(README_EN_PATH),
        render_readme_featured(sections, "Featured sponsors"),
    )
    return {
        JSON_OUTPUT_PATH: render_public_json(sections),
        MARKDOWN_OUTPUT_PATH: render_sponsors_markdown(sections),
        README_PATH: readme,
        README_EN_PATH: readme_en,
    }


def _check_outputs(outputs: dict[Path, str]) -> bool:
    changed = [path for path, content in outputs.items() if _read_text(path) != content]
    if not changed:
        print("Sponsor outputs are up to date.")
        return True
    for path in changed:
        print(f"Outdated generated sponsor file: {path.relative_to(ROOT)}", file=sys.stderr)
    return False


def _write_outputs(outputs: dict[Path, str]) -> None:
    changed = 0
    for path, content in outputs.items():
        if _read_text(path) == content:
            continue
        path.write_text(content, encoding="utf-8")
        changed += 1
        print(f"Generated {path.relative_to(ROOT)}")
    if changed == 0:
        print("Sponsor outputs are already up to date.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail when generated sponsor files are out of date",
    )
    args = parser.parse_args()
    outputs = generated_outputs()
    if args.check:
        raise SystemExit(0 if _check_outputs(outputs) else 1)
    _write_outputs(outputs)


if __name__ == "__main__":
    main()
