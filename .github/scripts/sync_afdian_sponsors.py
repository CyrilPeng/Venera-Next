"""Synchronize the normalized sponsor source from Afdian OpenAPI.

Secrets are read from ``AFDIAN_USER_ID`` and ``AFDIAN_API_TOKEN``. The script
never writes Afdian user IDs, order IDs, avatars, or raw order data to disk.
Only sponsors who supplied a valid public nickname in a successful order
remark are eligible for publication.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = ROOT / ".github" / "data" / "afdian_sync.json"
OUTPUT_PATH = ROOT / ".github" / "data" / "sponsors.json"

AFDIAN_API_ROOT = "https://ifdian.net/api/open"
PUBLIC_TIERS = {30, 80, 200}
ALL_TIERS = {10, 30, 80, 200}
SHANGHAI = ZoneInfo("Asia/Shanghai")


class AfdianApiError(RuntimeError):
    pass


@dataclass(frozen=True)
class SyncConfig:
    grace_days: int
    one_time_minimum: Decimal
    allow_plain_remark: bool
    remark_prefixes: tuple[str, ...]
    plan_tiers: dict[str, int]
    profiles: dict[str, dict[str, object]]


@dataclass(frozen=True)
class SyncResult:
    payload: dict[str, object]
    sponsor_count: int
    order_count: int
    published_count: int
    skipped_without_name: int
    unknown_plan_ids: tuple[str, ...]


def _read_json(path: Path) -> object:
    return json.loads(path.read_bytes().decode("utf-8-sig"))


def _decimal(value: object) -> Decimal | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        return Decimal(str(value))
    except InvalidOperation:
        return None


def _int(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _non_empty_string(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def load_config(path: Path = CONFIG_PATH) -> SyncConfig:
    payload = _read_json(path)
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise ValueError("Afdian sync config schemaVersion must be 1")

    grace_days = payload.get("graceDays", 2)
    if type(grace_days) is not int or not 0 <= grace_days <= 14:
        raise ValueError("graceDays must be an integer between 0 and 14")
    one_time_minimum = _decimal(payload.get("oneTimeMinimum", 30))
    if one_time_minimum is None or one_time_minimum <= 0:
        raise ValueError("oneTimeMinimum must be a positive number")
    allow_plain_remark = payload.get("allowPlainRemark", False)
    if not isinstance(allow_plain_remark, bool):
        raise ValueError("allowPlainRemark must be a boolean")

    raw_prefixes = payload.get("remarkPrefixes", [])
    if not isinstance(raw_prefixes, list) or not all(
        isinstance(prefix, str) and prefix for prefix in raw_prefixes
    ):
        raise ValueError("remarkPrefixes must be a list of non-empty strings")

    raw_plan_tiers = payload.get("planTiers", {})
    if not isinstance(raw_plan_tiers, dict):
        raise ValueError("planTiers must be an object")
    plan_tiers: dict[str, int] = {}
    for plan_id, tier in raw_plan_tiers.items():
        if not isinstance(plan_id, str) or not plan_id:
            raise ValueError("planTiers keys must be non-empty plan IDs")
        if type(tier) is not int or tier not in ALL_TIERS:
            raise ValueError("planTiers values must be 10, 30, 80, or 200")
        plan_tiers[plan_id] = tier

    profiles = payload.get("profiles", {})
    if not isinstance(profiles, dict):
        raise ValueError("profiles must be an object")
    for name, profile in profiles.items():
        if not isinstance(name, str) or not name or not isinstance(profile, dict):
            raise ValueError("profiles must map public names to objects")
        unknown = set(profile) - {"displayName", "hidden", "url", "image", "imageAlt"}
        if unknown:
            raise ValueError(f"profile {name!r} has unknown fields: {sorted(unknown)}")
        if "hidden" in profile and not isinstance(profile["hidden"], bool):
            raise ValueError(f"profile {name!r}.hidden must be a boolean")
        for field in ("displayName", "url", "image", "imageAlt"):
            if field in profile and not _non_empty_string(profile[field]):
                raise ValueError(f"profile {name!r}.{field} must be a non-empty string")

    return SyncConfig(
        grace_days=grace_days,
        one_time_minimum=one_time_minimum,
        allow_plain_remark=allow_plain_remark,
        remark_prefixes=tuple(raw_prefixes),
        plan_tiers=plan_tiers,
        profiles=profiles,
    )


def build_signed_payload(
    user_id: str,
    token: str,
    params: dict[str, object],
    timestamp: int,
) -> dict[str, object]:
    params_json = json.dumps(params, ensure_ascii=False, separators=(",", ":"))
    signature_text = f"{token}params{params_json}ts{timestamp}user_id{user_id}"
    return {
        "user_id": user_id,
        "params": params_json,
        "ts": timestamp,
        "sign": hashlib.md5(signature_text.encode("utf-8")).hexdigest(),
    }


class AfdianClient:
    def __init__(
        self,
        user_id: str,
        token: str,
        *,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.user_id = user_id
        self.token = token
        self.clock = clock
        self.sleep = sleep

    def request(self, endpoint: str, params: dict[str, object]) -> dict[str, object]:
        last_error: BaseException | None = None
        for attempt in range(3):
            payload = build_signed_payload(
                self.user_id,
                self.token,
                params,
                int(self.clock()),
            )
            request = Request(
                f"{AFDIAN_API_ROOT}/{endpoint}",
                data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                headers={
                    "Accept": "application/json",
                    "Content-Type": "application/json; charset=utf-8",
                    "User-Agent": "VeneraNext-Sponsor-Sync/1.0",
                },
                method="POST",
            )
            try:
                with urlopen(request, timeout=30) as response:
                    result = json.loads(response.read().decode("utf-8"))
                if not isinstance(result, dict):
                    raise AfdianApiError("Afdian returned a non-object response")
                if result.get("ec") != 200:
                    if result.get("ec") == 400002 and attempt < 2:
                        self.sleep(2**attempt)
                        continue
                    raise AfdianApiError(
                        f"Afdian {endpoint} failed: ec={result.get('ec')} em={result.get('em')}"
                    )
                data = result.get("data")
                if endpoint == "ping" and not isinstance(data, dict):
                    return {}
                if not isinstance(data, dict):
                    raise AfdianApiError(
                        f"Afdian {endpoint} response has no data object"
                    )
                return data
            except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as error:
                last_error = error
                if attempt < 2:
                    self.sleep(2**attempt)
        raise AfdianApiError(f"Afdian {endpoint} request failed") from last_error

    def ping(self) -> None:
        # Afdian's ping endpoint requires a non-empty JSON object. This is
        # the parameter used by the official signature validation example.
        self.request("ping", {"a": 333})

    def query_all(self, endpoint: str) -> list[dict[str, object]]:
        items: list[dict[str, object]] = []
        page = 1
        while True:
            data = self.request(endpoint, {"page": page, "per_page": 100})
            page_items = data.get("list")
            if not isinstance(page_items, list) or not all(
                isinstance(item, dict) for item in page_items
            ):
                raise AfdianApiError(f"Afdian {endpoint} returned an invalid list")
            items.extend(page_items)
            total_page = _int(data.get("total_page"))
            if total_page is None or total_page < 1:
                total_page = 1
            if page >= total_page:
                return items
            page += 1
            if page > 1000:
                raise AfdianApiError(
                    f"Afdian {endpoint} pagination exceeded 1000 pages"
                )


def extract_display_name(remark: object, config: SyncConfig) -> str | None:
    value = _non_empty_string(remark)
    if value is None:
        return None
    name: str | None = None
    for prefix in config.remark_prefixes:
        if value.startswith(prefix):
            name = value[len(prefix) :].splitlines()[0].strip()
            break
    if (
        name is None
        and config.allow_plain_remark
        and "\n" not in value
        and "\r" not in value
    ):
        name = value
    if not name or len(name) > 40:
        return None
    if any(ord(character) < 32 for character in name):
        return None
    if "http://" in name.lower() or "https://" in name.lower():
        return None
    return name


def _plan_monthly_amount(plan: dict[str, object]) -> Decimal | None:
    amount = _decimal(plan.get("price")) or _decimal(plan.get("show_price"))
    if amount is None or amount <= 0:
        return None
    pay_month = _int(plan.get("pay_month")) or 1
    normalized = amount / pay_month
    if normalized in {Decimal(tier) for tier in ALL_TIERS}:
        return normalized
    if amount in {Decimal(tier) for tier in ALL_TIERS}:
        return amount
    return amount


def _tier_for_plan(
    plan: object,
    config: SyncConfig,
    unknown_plan_ids: set[str],
) -> tuple[int | None, Decimal | None]:
    if not isinstance(plan, dict):
        return None, None
    plan_id = _non_empty_string(plan.get("plan_id"))
    amount = _plan_monthly_amount(plan)
    if plan_id and plan_id in config.plan_tiers:
        return config.plan_tiers[plan_id], amount
    if amount is not None and amount == amount.to_integral_value():
        inferred = int(amount)
        if inferred in ALL_TIERS:
            return inferred, amount
    if plan_id:
        unknown_plan_ids.add(plan_id)
    return None, amount


def _timestamp_date(value: object) -> str | None:
    timestamp = _int(value)
    if timestamp is None or timestamp <= 0:
        return None
    return datetime.fromtimestamp(timestamp, SHANGHAI).date().isoformat()


def _valid_order(order: dict[str, object]) -> bool:
    return _int(order.get("status")) == 2


def _profile_fields(
    original_name: str,
    config: SyncConfig,
    *,
    featured: bool,
) -> tuple[str, dict[str, object]] | None:
    profile = config.profiles.get(original_name, {})
    if profile.get("hidden") is True:
        return None
    display_name = _non_empty_string(profile.get("displayName")) or original_name
    fields: dict[str, object] = {}
    if featured:
        for field in ("url", "image", "imageAlt"):
            value = _non_empty_string(profile.get(field))
            if value:
                fields[field] = value
    return display_name, fields


def build_sponsor_source(
    sponsor_rows: list[dict[str, object]],
    order_rows: list[dict[str, object]],
    config: SyncConfig,
    *,
    now: datetime,
) -> SyncResult:
    if now.tzinfo is None:
        raise ValueError("now must be timezone-aware")
    now = now.astimezone(SHANGHAI)
    orders_by_user: dict[str, list[dict[str, object]]] = {}
    display_names: dict[str, str] = {}
    for order in order_rows:
        if not _valid_order(order):
            continue
        user_id = _non_empty_string(order.get("user_id"))
        if user_id is None:
            continue
        orders_by_user.setdefault(user_id, []).append(order)
        if user_id not in display_names:
            display_name = extract_display_name(order.get("remark"), config)
            if display_name:
                display_names[user_id] = display_name

    records: list[dict[str, object]] = []
    unknown_plan_ids: set[str] = set()
    skipped_without_name = 0
    for sponsor in sponsor_rows:
        user = sponsor.get("user")
        if not isinstance(user, dict):
            continue
        user_id = _non_empty_string(user.get("user_id"))
        if user_id is None:
            continue
        original_name = display_names.get(user_id)
        if original_name is None:
            skipped_without_name += 1
            continue

        user_orders = orders_by_user.get(user_id, [])
        plans = sponsor.get("sponsor_plans")
        if not isinstance(plans, list):
            plans = []
        current_plan = sponsor.get("current_plan")
        current_tier, current_amount = _tier_for_plan(
            current_plan, config, unknown_plan_ids
        )
        current_expire = (
            _int(current_plan.get("expire_time"))
            if isinstance(current_plan, dict)
            else None
        )
        active = (
            current_tier in PUBLIC_TIERS
            and current_expire is not None
            and datetime.fromtimestamp(current_expire, SHANGHAI)
            + timedelta(days=config.grace_days)
            >= now
        )

        recognized_plans: list[tuple[int, Decimal | None, int | None]] = []
        for plan in [*plans, current_plan]:
            tier, amount = _tier_for_plan(plan, config, unknown_plan_ids)
            if tier in PUBLIC_TIERS and isinstance(plan, dict):
                recognized_plans.append((tier, amount, _int(plan.get("expire_time"))))

        one_time_eligible = any(
            not _non_empty_string(order.get("plan_id"))
            and (_int(order.get("product_type")) or 0) == 0
            and (_decimal(order.get("total_amount")) or Decimal(0))
            >= config.one_time_minimum
            for order in user_orders
        )
        if not active and not recognized_plans and not one_time_eligible:
            continue

        started_at = (
            _timestamp_date(sponsor.get("first_pay_time"))
            or _timestamp_date(sponsor.get("create_time"))
            or _timestamp_date(sponsor.get("last_pay_time"))
        )
        if started_at is None:
            continue

        if active:
            tier = current_tier
            assert tier is not None
            profile_result = _profile_fields(
                original_name,
                config,
                featured=tier == 200,
            )
            if profile_result is None:
                continue
            name, profile_fields = profile_result
            amount = current_amount or Decimal(tier)
            monthly_amount = max(tier, int(amount))
            record: dict[str, object] = {
                "name": name,
                "tier": tier,
                "status": "active",
                "kind": "monthly",
                "startedAt": started_at,
                "monthlyAmount": monthly_amount,
                **profile_fields,
            }
        elif recognized_plans:
            tier = max(plan[0] for plan in recognized_plans)
            profile_result = _profile_fields(original_name, config, featured=False)
            if profile_result is None:
                continue
            name, _ = profile_result
            expire_times = [plan[2] for plan in recognized_plans if plan[2]]
            ended_at = (
                _timestamp_date(max(expire_times))
                if expire_times
                else _timestamp_date(sponsor.get("last_pay_time"))
            )
            if ended_at is None:
                continue
            record = {
                "name": name,
                "tier": tier,
                "status": "historical",
                "kind": "monthly",
                "startedAt": started_at,
                "endedAt": ended_at,
                "monthlyAmount": tier,
            }
        else:
            profile_result = _profile_fields(original_name, config, featured=False)
            if profile_result is None:
                continue
            name, _ = profile_result
            record = {
                "name": name,
                "tier": 30,
                "status": "historical",
                "kind": "oneTime",
                "startedAt": started_at,
            }
        records.append(record)

    records.sort(
        key=lambda record: (str(record["startedAt"]), str(record["name"]).casefold())
    )
    payload: dict[str, object] = {"schemaVersion": 1, "sponsors": records}
    return SyncResult(
        payload=payload,
        sponsor_count=len(sponsor_rows),
        order_count=len(order_rows),
        published_count=len(records),
        skipped_without_name=skipped_without_name,
        unknown_plan_ids=tuple(sorted(unknown_plan_ids)),
    )


def _validate_removals(previous: object, current: dict[str, object]) -> None:
    if not isinstance(previous, dict):
        return
    old_records = previous.get("sponsors")
    new_records = current.get("sponsors")
    if not isinstance(old_records, list) or not isinstance(new_records, list):
        return
    old_names = {
        record.get("name")
        for record in old_records
        if isinstance(record, dict) and isinstance(record.get("name"), str)
    }
    new_names = {
        record.get("name")
        for record in new_records
        if isinstance(record, dict) and isinstance(record.get("name"), str)
    }
    missing = sorted(old_names - new_names)
    if missing:
        raise ValueError(
            "sync would remove existing public sponsors; use --allow-removal after review: "
            + ", ".join(missing)
        )


def _write_if_changed(path: Path, payload: dict[str, object]) -> bool:
    content = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    current = path.read_bytes().decode("utf-8-sig").replace("\r\n", "\n")
    if current == content:
        return False
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)
    return True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--allow-removal",
        action="store_true",
        help="allow explicitly reviewed removals from the public sponsor list",
    )
    parser.add_argument(
        "--as-of",
        help="override synchronization time using an ISO-8601 timestamp",
    )
    args = parser.parse_args()

    user_id = os.environ.get("AFDIAN_USER_ID", "").strip()
    token = os.environ.get("AFDIAN_API_TOKEN", "").strip()
    if not user_id or not token:
        raise SystemExit("AFDIAN_USER_ID and AFDIAN_API_TOKEN are required")

    config = load_config()
    now = datetime.fromisoformat(args.as_of) if args.as_of else datetime.now(SHANGHAI)
    if now.tzinfo is None:
        now = now.replace(tzinfo=SHANGHAI)

    client = AfdianClient(user_id, token)
    client.ping()
    sponsor_rows = client.query_all("query-sponsor")
    order_rows = client.query_all("query-order")
    result = build_sponsor_source(sponsor_rows, order_rows, config, now=now)

    previous = _read_json(OUTPUT_PATH)
    if not args.allow_removal:
        _validate_removals(previous, result.payload)
    changed = _write_if_changed(OUTPUT_PATH, result.payload)

    print(f"Afdian sponsors fetched: {result.sponsor_count}")
    print(f"Afdian orders fetched: {result.order_count}")
    print(f"Public sponsors generated: {result.published_count}")
    print(
        f"Sponsors skipped without an explicit public nickname: {result.skipped_without_name}"
    )
    if result.unknown_plan_ids:
        print(
            "Unknown plan IDs (add them to afdian_sync.json if price inference is insufficient): "
            + ", ".join(result.unknown_plan_ids)
        )
    print(
        "Normalized sponsor source updated."
        if changed
        else "Normalized sponsor source unchanged."
    )


if __name__ == "__main__":
    main()
