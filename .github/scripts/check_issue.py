#!/usr/bin/env python3
"""Classify a newly opened issue through an OpenAI-compatible API."""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse, urlunparse
from urllib.request import Request, urlopen


DEFAULT_PROMPT = (
    "你是仓库 Issue 检查器。本项目是漫画阅读器，支持用户通过配置文件阅读"
    "本地或网络漫画。若要阅读网络漫画源，用户必须自行添加配置文件。用户不应"
    "在本项目仓库反馈任何与漫画源配置文件有关的问题，因为漫画源配置由其他"
    "仓库或用户自行维护。你会收到一个 Issue 内容，需要判断是否建议维护者关闭该 "
    "Issue。如果建议关闭，请同时给出解释原因的评论。如果不建议关闭，请给出该 Issue "
    "的摘要评论。请只返回 JSON 对象，包含以下键：should_close、should_comment、"
    "comment。should_close 仅代表给维护者的建议，工作流不会自动关闭 Issue。"
)


class IssueCheckError(RuntimeError):
    pass


def _required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise IssueCheckError(f"缺少环境变量 {name}")
    return value


def _chat_completions_url(api_url: str) -> str:
    parsed = urlparse(api_url.rstrip("/"))
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise IssueCheckError(f"API_URL 不是有效的 HTTP(S) 地址：{api_url}")

    path = parsed.path.rstrip("/")
    if path.endswith("/chat/completions"):
        target_path = path
    elif path.endswith("/v1"):
        target_path = f"{path}/chat/completions"
    else:
        target_path = f"{path}/v1/chat/completions"
    return urlunparse(parsed._replace(path=target_path, params="", query="", fragment=""))


def _decode_json_response(content: str) -> dict[str, object]:
    text = content.strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if len(lines) < 3 or lines[-1].strip() != "```":
            raise IssueCheckError("模型返回了不完整的 Markdown JSON 代码块")
        text = "\n".join(lines[1:-1]).strip()

    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise IssueCheckError(f"模型没有返回有效 JSON：{error}") from error
    if not isinstance(value, dict):
        raise IssueCheckError("模型返回值必须是 JSON 对象")
    return value


def _normalize_decision(value: dict[str, object]) -> tuple[bool, bool, str]:
    should_close = value.get("should_close") is True
    comment_value = value.get("comment", "")
    comment = comment_value.strip() if isinstance(comment_value, str) else ""
    should_comment = value.get("should_comment") is True or bool(comment)
    if should_comment and not comment:
        raise IssueCheckError("模型要求发表评论，但没有提供评论内容")
    if should_close and not comment:
        raise IssueCheckError("模型要求关闭 Issue，但没有提供解释评论")
    if len(comment) > 10000:
        raise IssueCheckError("模型生成的评论超过 10000 字符")
    return should_close, should_comment, comment


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


def classify_issue(
    content: str,
    *,
    api_url: str,
    api_key: str,
    model: str,
    prompt: str,
    attempts: int = 3,
) -> tuple[bool, bool, str]:
    endpoint = _chat_completions_url(api_url)
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": prompt},
            {"role": "user", "content": content},
        ],
    }
    headers = {"Authorization": f"Bearer {api_key}"}

    last_error: Exception | None = None
    for attempt in range(attempts):
        try:
            response = _request_json(
                endpoint,
                method="POST",
                headers=headers,
                payload=payload,
                timeout=60,
            )
            if not isinstance(response, dict):
                raise IssueCheckError("模型 API 返回值必须是 JSON 对象")
            choices = response.get("choices")
            if not isinstance(choices, list) or not choices:
                raise IssueCheckError("模型 API 没有返回 choices")
            choice = choices[0]
            if not isinstance(choice, dict):
                raise IssueCheckError("模型 API 返回了无效 choice")
            message = choice.get("message")
            if not isinstance(message, dict) or not isinstance(message.get("content"), str):
                raise IssueCheckError("模型 API 没有返回消息内容")
            return _normalize_decision(_decode_json_response(message["content"]))
        except IssueCheckError as error:
            last_error = error
            if attempt + 1 < attempts:
                time.sleep(2**attempt)

    raise IssueCheckError(f"模型请求重试后仍失败：{last_error}")


def _github_request(
    repository: str,
    issue_number: int,
    token: str,
    endpoint: str,
    payload: dict[str, object],
) -> None:
    _request_json(
        f"https://api.github.com/repos/{repository}/issues/{issue_number}{endpoint}",
        method="POST" if endpoint == "/comments" else "PATCH",
        headers={
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
        payload=payload,
    )


def main() -> int:
    event_path = Path(_required_env("GITHUB_EVENT_PATH"))
    repository = _required_env("GITHUB_REPOSITORY")
    github_token = _required_env("GITHUB_TOKEN")
    api_url = _required_env("API_URL")
    api_key = _required_env("API_KEY")
    model = os.environ.get("ISSUE_CHECK_MODEL", "gpt-4o").strip() or "gpt-4o"
    prompt = os.environ.get("ISSUE_CHECK_PROMPT", DEFAULT_PROMPT).strip() or DEFAULT_PROMPT

    payload = json.loads(event_path.read_text(encoding="utf-8"))
    issue = payload.get("issue")
    if not isinstance(issue, dict):
        raise IssueCheckError("事件负载中没有 Issue")
    issue_number = issue.get("number")
    if not isinstance(issue_number, int):
        raise IssueCheckError("事件负载中没有有效的 Issue 编号")
    title = issue.get("title") if isinstance(issue.get("title"), str) else ""
    body = issue.get("body") if isinstance(issue.get("body"), str) else ""

    should_close, should_comment, comment = classify_issue(
        f"{title}\n{body}",
        api_url=api_url,
        api_key=api_key,
        model=model,
        prompt=prompt,
    )
    if should_close:
        review_notice = "> 自动检查建议关闭此 Issue，请维护者复核。"
        comment = f"{review_notice}\n\n{comment}"

    if should_comment:
        _github_request(repository, issue_number, github_token, "/comments", {"body": comment})

    print(
        f"Issue #{issue_number}: comment={should_comment}, "
        f"recommended_close={should_close}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IssueCheckError, OSError, json.JSONDecodeError) as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
