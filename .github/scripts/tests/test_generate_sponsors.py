import json
import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import generate_sponsors as sponsors  # noqa: E402


def _monthly(
    name: str,
    tier: int,
    started_at: str,
    *,
    status: str = "active",
    monthly_amount: int | None = None,
) -> dict:
    item = {
        "name": name,
        "tier": tier,
        "status": status,
        "kind": "monthly",
        "startedAt": started_at,
        "monthlyAmount": monthly_amount or tier,
    }
    if status == "historical":
        item["endedAt"] = "2026-06-01"
    return item


class GenerateSponsorsTest(unittest.TestCase):
    def test_sections_follow_business_order(self) -> None:
        payload = {
            "schemaVersion": 1,
            "sponsors": [
                _monthly("Earlier featured", 200, "2025-01-01"),
                _monthly(
                    "Higher featured",
                    200,
                    "2026-01-01",
                    monthly_amount=300,
                ),
                _monthly("Later current", 80, "2026-02-01"),
                _monthly("Earlier current", 30, "2025-02-01"),
                _monthly(
                    "Historical monthly",
                    80,
                    "2024-01-01",
                    status="historical",
                ),
                {
                    "name": "One-time supporter",
                    "tier": 30,
                    "status": "historical",
                    "kind": "oneTime",
                    "startedAt": "2023-01-01",
                },
            ],
        }

        sections = sponsors.build_sections(sponsors.parse_source(payload))

        self.assertEqual(
            [item.name for item in sections.featured],
            ["Higher featured", "Earlier featured"],
        )
        self.assertEqual(
            [item.name for item in sections.current],
            ["Earlier current", "Later current"],
        )
        self.assertEqual(
            [item.name for item in sections.historical],
            ["One-time supporter", "Historical monthly"],
        )

        public = json.loads(sponsors.render_public_json(sections))
        self.assertEqual(public["schemaVersion"], 2)
        self.assertEqual(public["sections"]["featured"][0]["name"], "Higher featured")
        self.assertEqual(len(public["sponsors"]), 6)

    def test_source_rejects_non_public_and_inconsistent_entries(self) -> None:
        invalid_payloads = [
            {
                "schemaVersion": 1,
                "sponsors": [_monthly("Private tier", 10, "2026-01-01")],
            },
            {
                "schemaVersion": 1,
                "sponsors": [
                    {
                        "name": "Active one-time",
                        "tier": 30,
                        "status": "active",
                        "kind": "oneTime",
                        "startedAt": "2026-01-01",
                    }
                ],
            },
            {
                "schemaVersion": 1,
                "sponsors": [
                    {
                        **_monthly("Non-featured promotion", 80, "2026-01-01"),
                        "url": "https://example.com",
                    }
                ],
            },
        ]

        for payload in invalid_payloads:
            with self.subTest(payload=payload):
                with self.assertRaises(ValueError):
                    sponsors.parse_source(payload)

    def test_markdown_and_readme_rendering_are_deterministic(self) -> None:
        payload = {
            "schemaVersion": 1,
            "sponsors": [
                {
                    **_monthly("Featured Studio", 200, "2026-01-01"),
                    "url": "https://example.com",
                    "image": "https://example.com/logo.png",
                    "imageAlt": "Featured Studio",
                },
                _monthly(
                    "Past Supporter",
                    80,
                    "2025-01-01",
                    status="historical",
                ),
            ],
        }
        sections = sponsors.build_sections(sponsors.parse_source(payload))

        markdown = sponsors.render_sponsors_markdown(sections)
        self.assertIn("## 置顶赞助", markdown)
        self.assertIn("## 当前赞助者", markdown)
        self.assertIn("## 历史赞助者", markdown)
        self.assertIn("👑 **[Featured Studio]", markdown)
        self.assertIn("**Past Supporter**", markdown)

        readme = (
            "before\n"
            f"{sponsors.README_START}\n"
            "old content\n"
            f"{sponsors.README_END}\n"
            "after\n"
        )
        featured = sponsors.render_readme_featured(sections)
        featured_en = sponsors.render_readme_featured(sections, "Featured sponsors")
        first = sponsors.replace_marked_block(readme, featured)
        second = sponsors.replace_marked_block(first, featured)
        self.assertEqual(first, second)
        self.assertEqual(first.count("Featured Studio"), 1)
        self.assertIn("<sub>置顶赞助</sub>", featured)
        self.assertIn("<sub>Featured sponsors</sub>", featured_en)


if __name__ == "__main__":
    unittest.main()
