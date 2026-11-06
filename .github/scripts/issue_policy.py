#!/usr/bin/env python3
"""Validate structured Issue reports without AI or third-party dependencies."""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from issue_github import (
    GitHubIssues, IssueCheckError, ignored_event, load_event, managed_comment, required_env,
)


POLICY_MARKER = "<!-- venera-next:issue-policy:v1 -->"
TYPE = "问题类型 / Issue type"
VERSION = "应用版本 / App version"
PLATFORM = "平台 / Platform"
DEVICE = "设备与系统 / Device and OS"
STEPS = "复现步骤 / Steps to reproduce"
EXPECTED = "预期行为 / Expected behavior"
ACTUAL = "实际行为 / Actual behavior"
CHECKLIST = "提交前确认 / Checklist"
DIAGNOSTIC_SOURCE = "诊断提供方式 / Diagnostic source"
DIAGNOSTICS = "日志或诊断报告 / Logs or diagnostic report"
UNAVAILABLE_REASON = "日志无法取得的原因 / Why diagnostics are unavailable"
ALTERNATIVE = "替代证据 / Alternative evidence"
FEATURE_AREA = "涉及功能 / Feature area"

PASTED = "已粘贴脱敏日志或报告 / Pasted redacted logs or report"
ATTACHED = "已上传日志或报告附件 / Attached logs or report"
UNAVAILABLE = "无法取得（需说明原因并提供替代证据） / Unavailable (explain and provide alternatives)"

AGREEMENTS = (
    "我已搜索现有 Issue，并将独立问题分开提交。 / I searched existing Issues and separated unrelated problems.",
    "我了解本仓库维护应用本体，源站内容、作品可用性和第三方源脚本应联系对应维护者。 / I understand this repository maintains the app; source content and third-party source scripts belong with their maintainers.",
    "我已检查附件与文本，移除账号、Cookie、Token、签名链接及私人内容。 / I reviewed and redacted credentials, signed URLs and private content.",
)


@dataclass(frozen=True)
class Category:
    value: str
    area: str
    context: str
    diagnostics: bool = False
    reader_report: bool = False
    enhancement: bool = False


CATEGORIES = {
    "crash": Category(
        "崩溃、启动失败或无响应 / Crash, startup or freeze", "area: startup",
        "启动或崩溃场景 / Startup or crash context", diagnostics=True,
    ),
    "reader": Category(
        "阅读卡顿、慢加载或内存异常 / Reader performance", "area: reader",
        "阅读环境 / Reading context", diagnostics=True, reader_report=True,
    ),
    "data": Category(
        "本地导入、导出或数据异常 / Import, export or app data", "area: data",
        "数据操作与文件结构 / Data operation and file layout", diagnostics=True,
    ),
    "network": Category(
        "下载、网络或 WebDAV 故障 / Download, network or WebDAV", "area: network",
        "网络操作与错误 / Network operation and error", diagnostics=True,
    ),
    "ui": Category(
        "界面、导航与交互 / UI and interaction", "area: ui",
        "问题位置与操作方式 / Affected screen and input",
    ),
    "extension": Category(
        "扩展运行时 / Extension runtime", "area: extensions",
        "问题位置与操作方式 / Affected screen and input", diagnostics=True,
    ),
    "other": Category(
        "其他应用缺陷 / Other app defect", "area: other",
        "问题位置与操作方式 / Affected screen and input", diagnostics=True,
    ),
    "enhancement": Category(
        "功能建议 / Feature request", "", "需求场景 / Use case", enhancement=True,
    ),
}
FEATURE_AREAS = {
    "阅读器 / Reader": "area: reader",
    "本地漫画、收藏或数据 / Local comics, favorites or data": "area: data",
    "下载、网络或 WebDAV / Download, network or WebDAV": "area: network",
    "界面、导航或交互 / UI, navigation or interaction": "area: ui",
    "扩展运行时 / Extension runtime": "area: extensions",
    "安装、启动或平台支持 / Installation, startup or platform support": "area: startup",
    "其他 / Other": "area: other",
}
PLATFORMS = {
    "Android 手机／平板 / Android phone or tablet", "Android TV", "Windows", "macOS",
    "Linux", "iOS", "HarmonyOS / 鸿蒙", "其他（请说明） / Other (please specify)",
    "所有支持的平台 / All supported platforms",
}
BUG_FIELDS = (VERSION, PLATFORM, DEVICE, STEPS, EXPECTED, ACTUAL)
FEATURE_FIELDS = (PLATFORM, FEATURE_AREA, "需求场景 / Use case", "建议方案 / Proposed solution", "验收标准 / Acceptance criteria")
KNOWN_FIELDS = {
    TYPE, CHECKLIST, DIAGNOSTIC_SOURCE, DIAGNOSTICS, UNAVAILABLE_REASON, ALTERNATIVE,
    *BUG_FIELDS, *FEATURE_FIELDS, *(item.context for item in CATEGORIES.values()),
}
LABELS = {
    "bug": ("d73a4a", "应用缺陷"),
    "enhancement": ("a2eeef", "应用功能建议"),
    "area: startup": ("b60205", "安装、启动、崩溃与无响应"),
    "area: reader": ("1d76db", "阅读器与阅读性能"),
    "area: data": ("5319e7", "本地漫画、收藏、导入导出与应用数据"),
    "area: network": ("0052cc", "下载、网络、网页登录与 WebDAV"),
    "area: ui": ("c5def5", "界面、导航、焦点与交互"),
    "area: extensions": ("bfdadc", "应用的扩展运行时与接口"),
    "area: other": ("ededed", "待进一步归类的应用问题"),
    "needs: information": ("fbca04", "结构化报告缺少必要信息或诊断证据；补齐后自动移除"),
}


def _visible(text: str) -> str:
    return re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL).strip()


def sections(body: str) -> tuple[dict[str, str], set[str]]:
    """GitHub's headings delimit fields; headings inside fenced logs do not."""
    result: dict[str, str] = {}
    duplicates: set[str] = set()
    current: str | None = None
    lines: list[str] = []
    fence: str | None = None
    fence_length = 0

    def save() -> None:
        if current is not None:
            if current in result:
                duplicates.add(current)
            else:
                result[current] = _visible("\n".join(lines))

    for line in _visible(body).splitlines():
        fence_match = re.match(r"^ {0,3}(`{3,}|~{3,})", line)
        if fence_match:
            delimiter = fence_match.group(1)
            if fence is None:
                fence, fence_length = delimiter[0], len(delimiter)
            elif delimiter[0] == fence and len(delimiter) >= fence_length:
                fence = None
        heading = re.match(r"^###\s+(.+?)\s*$", line) if fence is None and not fence_match else None
        if heading:
            save()
            label = heading.group(1)
            current = label if label in KNOWN_FIELDS else None
            lines = []
        elif current is not None:
            lines.append(line)
    save()
    return result, duplicates


def has_information(text: str, *, minimum: int = 1) -> bool:
    visible = _visible(text)
    plain = re.sub(r"[\s_*`>#-]+", "", visible).casefold().strip(".。:：")
    return len(plain) >= minimum and plain not in {
        "", "noresponse", "n/a", "na", "none", "null", "nil", "todo", "tbd", "unknown",
        "无", "暂无", "没有", "不知道", "不清楚", "同上", "见上", "稍后提供", "稍后补充",
        "无法取得", "无法获取", "没有日志", "无日志", "见评论", "seecomment", "seebelow",
        "待补充", "待提供", "最新版", "最新版本", "latest", "latestversion", "bug", "问题",
        "nodiagnostics", "nodiagnosticsavailable", "logsunavailable", "nologsavailable", "notavailable",
    }


def has_attachment(text: str, *, diagnostic: bool) -> bool:
    # Check attachment references only. Never download the user's files or follow arbitrary URLs.
    for url in re.findall(r"https://[^\s<>\"\)\]]+", _visible(text)):
        parsed = urlparse(url)
        if parsed.hostname != "github.com" or parsed.username or parsed.password:
            continue
        if re.fullmatch(r"/user-attachments/files/\d+/.+", parsed.path):
            if not diagnostic or parsed.path.casefold().endswith((".txt", ".log", ".json", ".zip", ".gz")):
                return True
        elif not diagnostic and re.fullmatch(r"/user-attachments/assets/[\w-]+", parsed.path):
            return True
    return False


def has_log(text: str) -> bool:
    visible = _visible(text)
    if not has_information(visible, minimum=12):
        return False
    return bool(re.search(
        r"\b20\d{2}-\d{2}-\d{2}[T ]\d{2}:\d{2}"
        r"|\b\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+"
        r"|(?:^|\n)\s*#\d+\s+\S+"
        r"|\b\w*(?:Exception|Error)\b[^\n]*[:(]"
        r"|Traceback \(most recent call last\)"
        r"|FATAL EXCEPTION|Terminating app due to uncaught exception|Faulting application name:"
        r"|(?:^|\n)\s*(?:Unhandled [Ee]xception|\[(?:ERROR|WARN|INFO)\])",
        visible,
    ))


def has_reader_report(text: str) -> bool:
    visible = _visible(text)
    # Accept the copied JSON or the documented summary before imageEvents; truncated event
    # detail is unnecessary. A capture duration prevents the unstarted preview being accepted.
    return bool(
        re.search(r'"durationUs"\s*:\s*[1-9]\d*', visible)
        and all(re.search(r'"' + key + r'"\s*:', visible) for key in (
            "configuration", "retainedFrameSamples", "retainedStageSamples",
        ))
    )


def evidence_comments(issue: dict[str, object], comments: list[dict[str, object]]) -> list[str]:
    author = issue.get("user")
    author_login = author.get("login") if isinstance(author, dict) else None
    evidence = []
    for comment in comments:
        user = comment.get("user")
        body = comment.get("body")
        if not isinstance(user, dict) or user.get("type") == "Bot" or not isinstance(body, str):
            continue
        if (
            (author_login is not None and user.get("login") == author_login)
            or comment.get("author_association") in {"OWNER", "MEMBER", "COLLABORATOR"}
        ):
            evidence.append(body)
    return evidence


@dataclass(frozen=True)
class Validation:
    category: str | None
    missing: tuple[str, ...]
    area: str = ""

    @property
    def valid(self) -> bool:
        return not self.missing

    @property
    def labels(self) -> set[str]:
        labels = {"enhancement" if self.category == "enhancement" else "bug"} if self.category else set()
        if self.area:
            labels.add(self.area)
        if not self.valid:
            labels.add("needs: information")
        return labels


def validate(title: str, body: str, *, comments: list[str] | None = None) -> Validation:
    fields, duplicates = sections(body)
    missing = [f"每个字段只保留一次：{label}" for label in sorted(duplicates)]
    title_text = re.sub(r"^(?:\s*\[[^\]]+\])*\s*[:：]?\s*", "", title)
    if not has_information(title_text):
        missing.append("标题：写清触发条件与具体症状，不能只保留模板前缀。")
    category_key = next((key for key, item in CATEGORIES.items() if fields.get(TYPE) == item.value), None)
    if category_key is None:
        missing.append(f"{TYPE}：请使用当前表单选择具体问题类型。")
        return Validation(None, tuple(missing))
    category = CATEGORIES[category_key]
    required = FEATURE_FIELDS if category.enhancement else (*BUG_FIELDS, category.context)
    for label in required:
        if not has_information(fields.get(label, "")):
            missing.append(label)
    if not category.enhancement and has_information(fields.get(VERSION, "")):
        version = fields[VERSION]
        if not re.search(r"\bv?\d+\.\d+\.\d+\b|\b(?:commit|revision)\s*[:：]?\s*[0-9a-f]{7,40}\b", version, re.IGNORECASE):
            missing.append(f"{VERSION}：填写具体版本／构建号；自编译包填写 commit。")
    if has_information(fields.get(PLATFORM, "")):
        platforms = {part.strip() for part in fields[PLATFORM].split(",")}
        if not platforms <= PLATFORMS or (not category.enhancement and "所有支持的平台 / All supported platforms" in platforms):
            missing.append(f"{PLATFORM}：从表单列出的平台中选择，TV 和鸿蒙单独列出。")
    area = category.area
    if category.enhancement:
        area = FEATURE_AREAS.get(fields.get(FEATURE_AREA, ""), "")
        if not area and has_information(fields.get(FEATURE_AREA, "")):
            missing.append(f"{FEATURE_AREA}：请选择涉及的主要功能。")

    checked = {
        match.group(1).strip()
        for match in re.finditer(r"^\s*-\s*\[[xX]\]\s+(.+)$", fields.get(CHECKLIST, ""), re.MULTILINE)
    }
    if not set(AGREEMENTS) <= checked:
        missing.append(f"{CHECKLIST}：完成搜索、维护范围和附件脱敏确认。")

    if category.diagnostics:
        source = fields.get(DIAGNOSTIC_SOURCE, "")
        if source not in {PASTED, ATTACHED, UNAVAILABLE}:
            missing.append(f"{DIAGNOSTIC_SOURCE}：选择粘贴、附件或无法取得。")
        evidence = [fields.get(DIAGNOSTICS, ""), *(comments or [])]
        recognized = any(
            has_attachment(text, diagnostic=True)
            or (has_reader_report(text) if category.reader_report else has_log(text))
            for text in evidence
        )
        if not recognized:
            if source == UNAVAILABLE:
                if not has_information(fields.get(UNAVAILABLE_REASON, ""), minimum=12):
                    missing.append(f"{UNAVAILABLE_REASON}：说明尝试过的入口和不能取得的具体原因。")
                alternative = fields.get(ALTERNATIVE, "")
                alternative_description = re.sub(r"https?://\S+", "", alternative)
                if not (has_attachment(alternative, diagnostic=False) or has_information(alternative_description, minimum=20)):
                    missing.append(f"{ALTERNATIVE}：提供脱敏错误／系统诊断／截图，或带发生时间的具体现场说明。")
            else:
                detail = (
                    "提供实际采集的阅读诊断摘要或报告附件，不能用普通描述代替。"
                    if category.reader_report else "粘贴带时间、错误或调用栈的脱敏日志片段，或上传日志附件。"
                )
                missing.append(f"{DIAGNOSTICS}：{detail}")
    return Validation(category_key, tuple(missing), area)


def render_comment(result: Validation) -> str:
    guide = "https://github.com/CyrilPeng/Venera-Next/blob/main/doc/user/issue_reporting.zh.md"
    english = "https://github.com/CyrilPeng/Venera-Next/blob/main/doc/user/issue_reporting.en.md"
    lines = [POLICY_MARKER]
    if result.valid:
        lines += [
            "**提交格式检查通过 / Submission format check passed**",
            "", "所需字段及诊断引用已补齐，已移除 `needs: information`。附件内容和根因仍由维护者核实。",
            "Required fields and diagnostic references are present. A maintainer still needs to inspect the evidence.",
        ]
    else:
        lines += [
            "**需要补充信息 / More information needed**", "",
            "请编辑 Issue 正文补齐以下项目；日志或报告也可由报告者在评论中补充。不要另开重复 Issue。",
            "Please edit the Issue to complete these fields; the reporter may also add logs or reports in a comment.", "",
            *(f"- {item}" for item in result.missing), "",
            "暂标记为 `needs: information`，补齐后自动复查并更新本条提示。不会自动关闭 Issue。",
        ]
    lines += ["", f"[分类与诊断采集说明]({guide}) · [English guide]({english})"]
    return "\n".join(lines) + "\n"


def write_output(valid: bool) -> None:
    output = os.environ.get("GITHUB_OUTPUT", "")
    if output:
        with Path(output).open("a", encoding="utf-8") as stream:
            stream.write(f"valid={str(valid).lower()}\n")


def main() -> int:
    payload, event_issue = load_event()
    if ignored_event(payload, event_issue):
        write_output(False)
        print("跳过 PR、已关闭 Issue 或机器人事件。")
        return 0
    client = GitHubIssues(required_env("GITHUB_REPOSITORY"), required_env("GITHUB_TOKEN"))
    number = event_issue["number"]
    # Event snapshots can be stale after an edit; always inspect the current body and comments.
    issue = client.issue(number)
    if issue.get("state") != "open" or "pull_request" in issue:
        write_output(False)
        return 0
    comments = client.comments(number)
    body = issue.get("body") if isinstance(issue.get("body"), str) else ""
    title = issue.get("title") if isinstance(issue.get("title"), str) else ""
    fields, _ = sections(body)
    previously_checked = any(managed_comment(comment, POLICY_MARKER) for comment in comments)
    if TYPE not in fields and payload.get("action") != "opened" and not previously_checked:
        write_output(False)
        print(f"Issue #{number}: 旧格式报告保留原跟进流程。")
        return 0
    result = validate(title, body, comments=evidence_comments(issue, comments))
    client.ensure_labels(LABELS)
    latest = client.issue(number)
    if latest.get("state") != "open" or latest.get("title") != title or (latest.get("body") or "") != body:
        write_output(False)
        print(f"Issue #{number}: 校验期间报告已变化，等待后续事件复查。")
        return 0
    client.sync_labels(number, latest, owned=set(LABELS), wanted=result.labels)
    client.upsert_comment(number, marker=POLICY_MARKER, body=render_comment(result), comments=comments)
    write_output(result.valid)
    print(f"Issue #{number}: category={result.category}, valid={result.valid}, missing={len(result.missing)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IssueCheckError, OSError, json.JSONDecodeError) as error:
        print(f"::error::{error}", file=sys.stderr)
        raise SystemExit(1)
