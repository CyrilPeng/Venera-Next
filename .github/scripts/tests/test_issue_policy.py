import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import issue_policy as policy

LOG = "error Import 2026-11-06 10:11:12.123\nSqliteException(1): failed transaction\n#0 execute (package:sqlite3/db.dart:10)"
ATTACHMENT = "[log.txt](https://github.com/user-attachments/files/123456/log.txt)"
SCREENSHOT = "![error](https://github.com/user-attachments/assets/1234-5678-abcd)"
READER = json.dumps({
    "configuration": {"readerMode": "continuous"}, "durationUs": 45000000,
    "retainedFrameSamples": {"ui": {"count": 10}},
    "retainedStageSamples": {"localRead": {"count": 3}},
})


def body_for(category="data", overrides=None, *, remove=()):
    item = policy.CATEGORIES[category]
    fields = {
        policy.TYPE: item.value, policy.VERSION: "1.18.2+243（手机版）",
        policy.PLATFORM: "Android 手机／平板 / Android phone or tablet",
        policy.DEVICE: "小米 13，Android 16，HyperOS 3",
        policy.STEPS: "1. 打开本地入口\n2. 导入合成文件\n3. 每次提示成功但列表不显示",
        policy.EXPECTED: "成功导入后应在本地全部列表显示",
        policy.ACTUAL: "每次导入后提示成功，但没有新增可见条目",
        item.context: "本地导入 CBZ，单个文件，总目录/漫画A/001.jpg，全部列表无筛选",
        policy.DIAGNOSTIC_SOURCE: policy.PASTED,
        policy.DIAGNOSTICS: READER if item.reader_report else LOG,
        policy.UNAVAILABLE_REASON: "_No response_", policy.ALTERNATIVE: "_No response_",
        policy.CHECKLIST: "\n".join(f"- [X] {option}" for option in policy.AGREEMENTS),
    }
    if item.enhancement:
        fields.update({
            policy.PLATFORM: "所有支持的平台 / All supported platforms",
            policy.FEATURE_AREA: "阅读器 / Reader",
            "需求场景 / Use case": "长条漫画两侧空白较大，希望控制可见宽度",
            "建议方案 / Proposed solution": "提供可调整的裁剪范围，并能恢复默认",
            "验收标准 / Acceptance criteria": "保存后只影响显示，关闭后恢复完整图片",
        })
    fields.update(overrides or {})
    return "\n\n".join(f"### {label}\n\n{value}" for label, value in fields.items() if label not in remove)


def bot_comment(body):
    return {"id": 5, "body": policy.POLICY_MARKER + "\n" + body,
            "user": {"login": "github-actions[bot]", "type": "Bot"}}


class PolicyValidationTests(unittest.TestCase):
    def test_each_diagnostic_category_requires_evidence(self):
        for category in ("crash", "reader", "data", "network", "extension", "other"):
            with self.subTest(category=category):
                result = policy.validate("实际失败症状", body_for(category, {policy.DIAGNOSTICS: "_No response_"}))
                self.assertFalse(result.valid)
                self.assertTrue(any(item.startswith(policy.DIAGNOSTICS) for item in result.missing))
                self.assertIn("needs: information", result.labels)

    def test_ui_and_features_do_not_require_logs(self):
        for category in ("ui", "enhancement"):
            with self.subTest(category=category):
                self.assertTrue(policy.validate("明确的使用问题或建议", body_for(category, remove=(policy.DIAGNOSTIC_SOURCE, policy.DIAGNOSTICS))).valid)

    def test_features_require_observable_acceptance(self):
        result = policy.validate("希望增加裁剪", body_for("enhancement", {"验收标准 / Acceptance criteria": "_No response_"}))
        self.assertFalse(result.valid)
        self.assertIn("验收标准 / Acceptance criteria", result.missing)

    def test_complete_reports_have_primary_area_and_type(self):
        for category, item in policy.CATEGORIES.items():
            with self.subTest(category=category):
                result = policy.validate("操作后出现明确症状", body_for(category))
                self.assertTrue(result.valid, result.missing)
                self.assertIn("enhancement" if item.enhancement else "bug", result.labels)
                self.assertIn("area: reader" if item.enhancement else item.area, result.labels)

    def test_placeholder_title_version_and_fields_are_rejected(self):
        result = policy.validate("[Bug]: ", body_for("data", {
            policy.VERSION: "最新版", policy.STEPS: "_No response_", policy.DEVICE: "N/A",
        }))
        self.assertFalse(result.valid)
        self.assertTrue(any(item.startswith("标题") for item in result.missing))
        for field in (policy.VERSION, policy.STEPS, policy.DEVICE):
            self.assertIn(field, result.missing)

    def test_version_numbers_and_custom_commits_are_supported(self):
        for version in ("v1.18.2", "1.18.2-rc.6+242", "commit 4337ed6bb318c22", "1.18.2+243 (TV)"):
            with self.subTest(version=version):
                self.assertTrue(policy.validate("明确症状", body_for("data", {policy.VERSION: version})).valid)
        self.assertFalse(policy.validate("明确症状", body_for("data", {policy.VERSION: "stable release"})).valid)

    def test_multiple_actual_platforms_are_accepted(self):
        self.assertTrue(policy.validate("跨平台症状", body_for("data", {policy.PLATFORM: "Android TV, Windows"})).valid)
        self.assertFalse(policy.validate("跨平台症状", body_for("data", {policy.PLATFORM: "所有支持的平台 / All supported platforms"})).valid)

    def test_unchecked_and_fake_checklists_are_rejected(self):
        for checklist in ("- [X] done", "\n".join(f"- [ ] {item}" for item in policy.AGREEMENTS)):
            with self.subTest(checklist=checklist):
                result = policy.validate("明确问题", body_for("data", {policy.CHECKLIST: checklist}))
                self.assertTrue(any(item.startswith(policy.CHECKLIST) for item in result.missing))

    def test_duplicate_fields_are_not_silently_overwritten(self):
        result = policy.validate("明确问题", body_for() + f"\n\n### {policy.VERSION}\n\n1.18.1")
        self.assertFalse(result.valid)
        self.assertIn(f"每个字段只保留一次：{policy.VERSION}", result.missing)

    def test_fenced_headings_and_html_comments_do_not_create_fields(self):
        body = body_for("data", {policy.DIAGNOSTICS: "````text\n" + LOG + f"\n### {policy.VERSION}\n\n0.0.0\n```\n````"})
        body += f"\n<!--\n### {policy.VERSION}\n\n0.0.0\n-->"
        self.assertTrue(policy.validate("明确问题", body).valid)

    def test_reader_accepts_summary_without_event_details(self):
        summary = READER[:-1] + ',\n"imageEvents": [\n...'
        self.assertTrue(policy.validate("首次停顿", body_for("reader", {policy.DIAGNOSTICS: summary})).valid)

    def test_reader_rejects_regular_logs_and_unstarted_capture(self):
        for text in (LOG, READER.replace("45000000", "0"), "已开始诊断，稍后发报告"):
            with self.subTest(text=text):
                self.assertFalse(policy.validate("首次停顿", body_for("reader", {policy.DIAGNOSTICS: text})).valid)

    def test_attachments_are_allowed_but_screenshots_do_not_replace_logs(self):
        for category in ("crash", "reader", "data", "network"):
            with self.subTest(category=category):
                self.assertTrue(policy.validate("明确问题", body_for(category, {
                    policy.DIAGNOSTIC_SOURCE: policy.ATTACHED, policy.DIAGNOSTICS: ATTACHMENT,
                })).valid)
                self.assertFalse(policy.validate("明确问题", body_for(category, {policy.DIAGNOSTICS: SCREENSHOT})).valid)

    def test_failed_upload_and_untrusted_urls_are_not_attachments(self):
        for evidence in (
            f'<!-- Failed to upload "{ATTACHMENT}" -->',
            "[log](https://github.com.evil.test/user-attachments/files/123/log.txt)",
            "[log](https://github.com/user-attachments/files/123/photo.jpg)",
            "[log](https://example.test/log.txt)",
        ):
            with self.subTest(evidence=evidence):
                self.assertFalse(policy.has_attachment(evidence, diagnostic=True))

    def test_unavailable_requires_reason_and_alternative(self):
        result = policy.validate("启动退出", body_for("crash", {
            policy.DIAGNOSTIC_SOURCE: policy.UNAVAILABLE, policy.DIAGNOSTICS: "无法取得",
            policy.UNAVAILABLE_REASON: "没有日志", policy.ALTERNATIVE: "稍后补充",
        }))
        self.assertFalse(result.valid)
        for field in (policy.UNAVAILABLE_REASON, policy.ALTERNATIVE):
            self.assertTrue(any(item.startswith(field) for item in result.missing))

    def test_unavailable_accepts_screenshot_or_detailed_circumstances(self):
        for alternative in (SCREENSHOT, "2026-11-06 10:00，点击图标后进程立即退出，每次发生，未出现窗口"):
            with self.subTest(alternative=alternative):
                result = policy.validate("启动退出", body_for("crash", {
                    policy.DIAGNOSTIC_SOURCE: policy.UNAVAILABLE, policy.DIAGNOSTICS: "无法取得",
                    policy.UNAVAILABLE_REASON: "点图标立即退出，无法进入设置，常见目录尚未生成启动日志",
                    policy.ALTERNATIVE: alternative,
                }))
                self.assertTrue(result.valid, result.missing)

    def test_later_evidence_can_complete_the_report(self):
        body = body_for("reader", {policy.DIAGNOSTICS: "稍后补充"})
        self.assertFalse(policy.validate("阅读卡顿", body).valid)
        self.assertTrue(policy.validate("阅读卡顿", body, comments=[READER]).valid)
        self.assertFalse(policy.validate("阅读卡顿", body, comments=[LOG]).valid)

    def test_native_platform_crash_logs_are_supported(self):
        for log in (
            "11-06 10:12:13.456 1234 1234 E AndroidRuntime: FATAL EXCEPTION: main",
            "Terminating app due to uncaught exception 'NSInvalidArgumentException'",
            "Faulting application name: VeneraNext.exe, version: 1.18.2",
            "SqliteException(1): while executing, transaction failed",
            "Exception: Could not open the selected archive",
            "Error: HTTP 401",
        ):
            with self.subTest(log=log):
                self.assertTrue(policy.has_log(log))

    def test_only_reporter_and_maintainer_comments_count(self):
        issue = {"user": {"login": "reporter"}}
        comments = [
            {"body": ATTACHMENT, "user": {"login": "reporter", "type": "User"}, "author_association": "NONE"},
            {"body": LOG, "user": {"login": "maintainer", "type": "User"}, "author_association": "COLLABORATOR"},
            {"body": READER, "user": {"login": "bystander", "type": "User"}, "author_association": "NONE"},
            {"body": READER, "user": {"login": "github-actions[bot]", "type": "Bot"}, "author_association": "MEMBER"},
        ]
        self.assertEqual(policy.evidence_comments(issue, comments), [ATTACHMENT, LOG])

    def test_notice_is_stable_and_does_not_quote_user_content(self):
        result = policy.validate("明确问题", body_for("data", {policy.DIAGNOSTICS: "private-token-value"}))
        first = policy.render_comment(result)
        self.assertEqual(first, policy.render_comment(result))
        self.assertTrue(first.startswith(policy.POLICY_MARKER + "\n"))
        self.assertNotIn("private-token-value", first)


class PolicyEventTests(unittest.TestCase):
    def run_event(self, body=None, *, action="opened", comments=None, previous=None,
                  sender_type="User", state="open", pull_request=False, latest=None):
        issue = {
            "number": 999, "title": "合成报告用于检查规则", "body": body if body is not None else body_for(),
            "state": state, "user": {"login": "reporter"}, "labels": [{"name": "status: investigating"}],
        }
        if pull_request:
            issue["pull_request"] = {"url": "https://example.test/pr"}
        payload = {"action": action, "issue": previous or issue, "sender": {"type": sender_type}}
        client = Mock()
        client.issue.side_effect = [issue, latest or issue]
        client.comments.return_value = comments or []
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output.txt"
            with (
                patch.object(policy, "load_event", return_value=(payload, previous or issue)),
                patch.object(policy, "GitHubIssues", return_value=client) as constructor,
                patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo", "GITHUB_TOKEN": "test-token", "GITHUB_OUTPUT": str(output)}, clear=True),
                patch("sys.stdout", new=io.StringIO()),
            ):
                self.assertEqual(policy.main(), 0)
                outputs = output.read_text(encoding="utf-8")
        return client, constructor, outputs

    def test_validation_runs_without_ai_secrets(self):
        client, _, outputs = self.run_event()
        self.assertEqual(outputs, "valid=true\n")
        client.ensure_labels.assert_called_once()
        self.assertEqual(client.sync_labels.call_args.kwargs["wanted"], {"bug", "area: data"})

    def test_opened_unstructured_reports_need_the_current_form(self):
        client, _, outputs = self.run_event("It broke")
        self.assertEqual(outputs, "valid=false\n")
        self.assertIn("needs: information", client.sync_labels.call_args.kwargs["wanted"])

    def test_event_snapshot_is_replaced_by_current_issue(self):
        previous = {"number": 999, "state": "open", "body": "It broke"}
        client, _, outputs = self.run_event(action="edited", previous=previous)
        self.assertEqual(outputs, "valid=true\n")
        client.upsert_comment.assert_called_once()

    def test_historical_reports_are_not_retroactively_enforced(self):
        for action in ("edited", "reopened", "created", "deleted"):
            with self.subTest(action=action):
                client, _, outputs = self.run_event("### Bug type\n\nReader\n\n### logs\n\n_No response_", action=action)
                self.assertEqual(outputs, "valid=false\n")
                client.ensure_labels.assert_not_called()
                client.upsert_comment.assert_not_called()

    def test_removing_category_from_a_checked_report_is_detected(self):
        client, _, outputs = self.run_event(body_for(remove=(policy.TYPE,)), action="edited", comments=[bot_comment("previous check")])
        self.assertEqual(outputs, "valid=false\n")
        self.assertIn("needs: information", client.sync_labels.call_args.kwargs["wanted"])

    def test_closed_pr_and_bot_events_skip_credentials_and_mutations(self):
        for arguments in ({"state": "closed"}, {"pull_request": True}, {"sender_type": "Bot"}):
            with self.subTest(arguments=arguments):
                client, constructor, outputs = self.run_event(**arguments)
                constructor.assert_not_called()
                client.upsert_comment.assert_not_called()
                self.assertEqual(outputs, "valid=false\n")

    def test_issue_closed_during_event_processing_is_not_prompted(self):
        event = {"number": 999, "state": "open"}
        client, _, outputs = self.run_event(state="closed", previous=event)
        self.assertEqual(outputs, "valid=false\n")
        client.upsert_comment.assert_not_called()

    def test_report_edited_during_check_does_not_receive_stale_notice(self):
        latest = {"number": 999, "state": "open", "title": "changed", "body": body_for()}
        client, _, outputs = self.run_event(latest=latest)
        self.assertEqual(outputs, "valid=false\n")
        client.sync_labels.assert_not_called()
        client.upsert_comment.assert_not_called()

    def test_reporter_comment_completes_required_diagnostics(self):
        comment = {"body": ATTACHMENT, "user": {"login": "reporter", "type": "User"}, "author_association": "NONE"}
        client, _, outputs = self.run_event(body_for("data", {policy.DIAGNOSTICS: "稍后补充"}), action="created", comments=[comment])
        self.assertEqual(outputs, "valid=true\n")
        self.assertNotIn("needs: information", client.sync_labels.call_args.kwargs["wanted"])

    def test_deleted_evidence_restores_missing_information_status(self):
        client, _, outputs = self.run_event(body_for("data", {policy.DIAGNOSTICS: "稍后补充"}), action="deleted", comments=[bot_comment("previously accepted")])
        self.assertEqual(outputs, "valid=false\n")
        self.assertIn("needs: information", client.sync_labels.call_args.kwargs["wanted"])


if __name__ == "__main__":
    unittest.main()
