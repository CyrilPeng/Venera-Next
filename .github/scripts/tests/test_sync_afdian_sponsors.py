import json
import sys
import unittest
from datetime import datetime
from decimal import Decimal
from pathlib import Path
from unittest.mock import patch

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

import generate_sponsors  # noqa: E402
import sync_afdian_sponsors as afdian  # noqa: E402


def _timestamp(value: str) -> int:
    return int(
        datetime.fromisoformat(value).replace(tzinfo=afdian.SHANGHAI).timestamp()
    )


def _config(**overrides) -> afdian.SyncConfig:
    values = {
        "grace_days": 2,
        "one_time_minimum": Decimal("30"),
        "allow_plain_remark": True,
        "remark_prefixes": ("公开昵称：", "公开昵称:"),
        "plan_tiers": {"p10": 10, "p30": 30, "p80": 80, "p200": 200},
        "profiles": {},
    }
    values.update(overrides)
    return afdian.SyncConfig(**values)


def _plan(plan_id: str, price: int, expire: str) -> dict:
    return {
        "plan_id": plan_id,
        "name": f"Tier {price}",
        "price": f"{price}.00",
        "pay_month": 1,
        "expire_time": _timestamp(expire),
    }


def _sponsor(
    user_id: str,
    *,
    started: str,
    current_plan: dict | None = None,
    plans: list[dict] | None = None,
) -> dict:
    return {
        "user": {"user_id": user_id, "name": f"Afdian {user_id}"},
        "first_pay_time": _timestamp(started),
        "last_pay_time": _timestamp(started),
        "current_plan": current_plan or {"name": ""},
        "sponsor_plans": plans or [],
    }


def _order(
    user_id: str,
    remark: str,
    *,
    plan_id: str = "",
    amount: str = "30.00",
    status: int = 2,
) -> dict:
    return {
        "user_id": user_id,
        "plan_id": plan_id,
        "total_amount": amount,
        "product_type": 0,
        "status": status,
        "remark": remark,
    }


class AfdianSponsorSyncTest(unittest.TestCase):
    def test_signature_matches_official_example(self) -> None:
        payload = afdian.build_signed_payload(
            "abc",
            "123",
            {"a": 333},
            1624339905,
        )

        self.assertEqual(payload["params"], '{"a":333}')
        self.assertEqual(payload["sign"], "a4acc28b81598b7e5d84ebdc3e91710c")

    def test_ping_uses_non_empty_json_params(self) -> None:
        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self) -> bytes:
                return b'{"ec":200,"data":{}}'

        captured = []

        def fake_urlopen(request, timeout):
            captured.append((request, timeout))
            return FakeResponse()

        client = afdian.AfdianClient(
            "abc",
            "123",
            clock=lambda: 1624339905,
        )
        with patch.object(afdian, "urlopen", fake_urlopen):
            client.ping()

        self.assertEqual(len(captured), 1)
        payload = json.loads(captured[0][0].data.decode("utf-8"))
        self.assertEqual(payload["params"], '{"a":333}')

    def test_remark_requires_an_explicit_safe_public_name(self) -> None:
        strict = _config(allow_plain_remark=False)
        self.assertEqual(
            afdian.extract_display_name("公开昵称：Venera Friend", strict),
            "Venera Friend",
        )
        self.assertIsNone(afdian.extract_display_name("普通留言", strict))
        self.assertIsNone(
            afdian.extract_display_name("公开昵称：https://example.com", strict)
        )

        permissive = _config(allow_plain_remark=True)
        self.assertEqual(
            afdian.extract_display_name("直接填写的昵称", permissive),
            "直接填写的昵称",
        )
        self.assertIsNone(afdian.extract_display_name("第一行\n第二行", permissive))

    def test_sync_classifies_active_historical_and_one_time_sponsors(self) -> None:
        active_plan = _plan("p200", 200, "2026-08-01T00:00:00")
        recently_expired = _plan("p80", 80, "2026-07-21T00:00:00")
        historical_plan = _plan("p80", 80, "2026-06-01T00:00:00")
        sponsor_rows = [
            _sponsor(
                "active",
                started="2025-01-01T00:00:00",
                current_plan=active_plan,
                plans=[active_plan],
            ),
            _sponsor(
                "grace",
                started="2025-02-01T00:00:00",
                current_plan=recently_expired,
                plans=[recently_expired],
            ),
            _sponsor(
                "historical",
                started="2025-03-01T00:00:00",
                plans=[historical_plan],
            ),
            _sponsor("one-time", started="2025-04-01T00:00:00"),
            _sponsor(
                "private",
                started="2025-05-01T00:00:00",
                current_plan=_plan("p30", 30, "2026-08-01T00:00:00"),
            ),
        ]
        order_rows = [
            _order("active", "Studio", plan_id="p200", amount="200.00"),
            _order("grace", "公开昵称：Grace", plan_id="p80", amount="80.00"),
            _order(
                "historical",
                "公开昵称：Past",
                plan_id="p80",
                amount="80.00",
            ),
            _order("one-time", "One Time", amount="50.00"),
            _order("private", "", plan_id="p30", amount="30.00"),
        ]
        config = _config(
            profiles={
                "Studio": {
                    "url": "https://example.com",
                    "image": "https://example.com/logo.png",
                }
            }
        )

        result = afdian.build_sponsor_source(
            sponsor_rows,
            order_rows,
            config,
            now=datetime(2026, 7, 22, 12, tzinfo=afdian.SHANGHAI),
        )

        records = {record["name"]: record for record in result.payload["sponsors"]}
        self.assertEqual(set(records), {"Studio", "Grace", "Past", "One Time"})
        self.assertEqual(records["Studio"]["status"], "active")
        self.assertEqual(records["Studio"]["tier"], 200)
        self.assertEqual(records["Studio"]["url"], "https://example.com")
        self.assertEqual(records["Grace"]["status"], "active")
        self.assertEqual(records["Past"]["status"], "historical")
        self.assertEqual(records["Past"]["endedAt"], "2026-06-01")
        self.assertEqual(records["One Time"]["kind"], "oneTime")
        self.assertEqual(result.skipped_without_name, 1)
        generate_sponsors.parse_source(result.payload)

    def test_price_fallback_recognizes_tiers_without_plan_mapping(self) -> None:
        plan = _plan("unknown-plan", 30, "2026-08-01T00:00:00")
        result = afdian.build_sponsor_source(
            [
                _sponsor(
                    "fallback",
                    started="2025-01-01T00:00:00",
                    current_plan=plan,
                )
            ],
            [_order("fallback", "Fallback", plan_id="unknown-plan")],
            _config(plan_tiers={}),
            now=datetime(2026, 7, 22, tzinfo=afdian.SHANGHAI),
        )

        self.assertEqual(result.payload["sponsors"][0]["tier"], 30)
        self.assertEqual(result.unknown_plan_ids, ())

    def test_multi_month_plan_uses_monthly_equivalent(self) -> None:
        plan = _plan("quarterly", 90, "2026-10-01T00:00:00")
        plan["pay_month"] = 3
        result = afdian.build_sponsor_source(
            [
                _sponsor(
                    "quarterly",
                    started="2025-01-01T00:00:00",
                    current_plan=plan,
                )
            ],
            [_order("quarterly", "Quarterly", plan_id="quarterly", amount="90")],
            _config(plan_tiers={}),
            now=datetime(2026, 7, 22, tzinfo=afdian.SHANGHAI),
        )

        self.assertEqual(result.payload["sponsors"][0]["tier"], 30)
        self.assertEqual(result.payload["sponsors"][0]["monthlyAmount"], 30)

    def test_existing_public_names_cannot_disappear_silently(self) -> None:
        previous = {
            "schemaVersion": 1,
            "sponsors": [{"name": "Existing"}],
        }
        current = {"schemaVersion": 1, "sponsors": []}

        with self.assertRaisesRegex(ValueError, "Existing"):
            afdian._validate_removals(previous, current)


if __name__ == "__main__":
    unittest.main()
