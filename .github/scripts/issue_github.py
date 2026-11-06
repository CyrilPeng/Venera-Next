#!/usr/bin/env python3
"""Small, shared GitHub client for the Issue form and optional AI checks."""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


class IssueCheckError(RuntimeError):
    pass


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise IssueCheckError(f"缺少环境变量 {name}")
    return value


def _request_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    payload: dict[str, object] | None = None,
    timeout: int = 30,
) -> object:
    request_headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "VeneraNext-GitHub-Actions",
        **(headers or {}),
    }
    data = None
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request_headers["Content-Type"] = "application/json"
    request = Request(url, data=data, headers=request_headers, method=method)
    try:
        with urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8")
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise IssueCheckError(f"HTTP {error.code} 请求失败：{detail[:500]}") from error
    except (URLError, TimeoutError) as error:
        raise IssueCheckError(f"网络请求失败：{error}") from error
    if not body:
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise IssueCheckError(f"服务返回了无效 JSON：{error}") from error


def load_event() -> tuple[dict[str, object], dict[str, object]]:
    payload = json.loads(Path(required_env("GITHUB_EVENT_PATH")).read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("issue"), dict):
        raise IssueCheckError("事件负载中没有 Issue")
    issue = payload["issue"]
    number = issue.get("number")
    if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
        raise IssueCheckError("事件负载中没有有效的 Issue 编号")
    return payload, issue


def ignored_event(payload: dict[str, object], issue: dict[str, object]) -> bool:
    sender = payload.get("sender")
    return (
        "pull_request" in issue
        or issue.get("state") == "closed"
        or (isinstance(sender, dict) and sender.get("type") == "Bot")
    )


def managed_comment(comment: dict[str, object], marker: str) -> bool:
    user = comment.get("user")
    body = comment.get("body")
    return (
        isinstance(user, dict)
        and user.get("login") == "github-actions[bot]"
        and user.get("type") == "Bot"
        and isinstance(body, str)
        and body.startswith(marker + "\n")
    )


class GitHubIssues:
    def __init__(self, repository: str, token: str):
        api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
        self.base = f"{api}/repos/{repository}"
        self.headers = {
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    def request(
        self, endpoint: str, *, method: str = "GET", payload: dict[str, object] | None = None
    ) -> object:
        return _request_json(self.base + endpoint, method=method, headers=self.headers, payload=payload)

    def issue(self, number: int) -> dict[str, object]:
        result = self.request(f"/issues/{number}")
        if not isinstance(result, dict) or result.get("number") != number:
            raise IssueCheckError("GitHub 没有返回有效的 Issue")
        return result

    def pages(self, endpoint: str) -> list[dict[str, object]]:
        items = []
        page = 1
        while True:
            result = self.request(f"{endpoint}?per_page=100&page={page}")
            if not isinstance(result, list) or any(not isinstance(item, dict) for item in result):
                raise IssueCheckError("GitHub 没有返回有效的列表")
            items.extend(result)
            if len(result) < 100:
                return items
            page += 1

    def comments(self, number: int) -> list[dict[str, object]]:
        return self.pages(f"/issues/{number}/comments")

    def ensure_labels(self, definitions: dict[str, tuple[str, str]]) -> None:
        existing = {item.get("name") for item in self.pages("/labels")}
        for name, (color, description) in definitions.items():
            if name not in existing:
                try:
                    self.request(
                        "/labels", method="POST",
                        payload={"name": name, "color": color, "description": description},
                    )
                except IssueCheckError as error:
                    # Issue runs are serialized per Issue, but another Issue may create
                    # the same repository label between our list and create requests.
                    if not str(error).startswith("HTTP 422 "):
                        raise
                    existing = {item.get("name") for item in self.pages("/labels")}
                    if name not in existing:
                        raise

    def sync_labels(
        self, number: int, issue: dict[str, object], *, owned: set[str], wanted: set[str]
    ) -> None:
        labels = issue.get("labels", [])
        if not isinstance(labels, list):
            raise IssueCheckError("Issue labels 必须是列表")
        existing = {
            label.get("name") if isinstance(label, dict) else label for label in labels
        }
        additions = wanted - existing
        if additions:
            self.request(f"/issues/{number}/labels", method="POST", payload={"labels": sorted(additions)})
        for name in sorted((existing & owned) - wanted):
            self.request(f"/issues/{number}/labels/{quote(name, safe='')}", method="DELETE")

    def upsert_comment(
        self, number: int, *, marker: str, body: str, comments: list[dict[str, object]]
    ) -> None:
        # A copied marker in a human comment never authorizes editing that comment.
        previous = next((item for item in comments if managed_comment(item, marker)), None)
        if previous is None:
            self.request(f"/issues/{number}/comments", method="POST", payload={"body": body})
        elif previous.get("body") != body:
            comment_id = previous.get("id")
            if not isinstance(comment_id, int) or isinstance(comment_id, bool):
                raise IssueCheckError("检查评论缺少有效编号")
            self.request(f"/issues/comments/{comment_id}", method="PATCH", payload={"body": body})
