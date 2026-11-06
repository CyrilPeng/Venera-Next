import io
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from check_issue import (
    IssueCheckError,
    _chat_completions_url,
    _decode_json_response,
    _normalize_decision,
)
import check_issue


class IssueCheckTest(unittest.TestCase):
    def test_chat_completions_url_accepts_common_base_urls(self):
        self.assertEqual(
            _chat_completions_url("https://api.openai.com"),
            "https://api.openai.com/v1/chat/completions",
        )
        self.assertEqual(
            _chat_completions_url("https://example.com/v1/"),
            "https://example.com/v1/chat/completions",
        )
        self.assertEqual(
            _chat_completions_url("https://example.com/chat/completions"),
            "https://example.com/chat/completions",
        )

    def test_decode_json_response_accepts_markdown_fence(self):
        self.assertEqual(
            _decode_json_response(
                '```json\n{"should_close": false, "comment": "保留"}\n```'
            ),
            {"should_close": False, "comment": "保留"},
        )

    def test_normalize_decision_requires_comment_before_closing(self):
        with self.assertRaises(IssueCheckError):
            _normalize_decision({"should_close": True, "comment": ""})

    def test_normalize_decision_uses_non_empty_comment(self):
        self.assertEqual(
            _normalize_decision(
                {
                    "should_close": False,
                    "should_comment": False,
                    "comment": "问题摘要",
                }
            ),
            (False, True, "问题摘要"),
        )

    def test_normalize_decision_requires_comment_when_requested(self):
        with self.assertRaises(IssueCheckError):
            _normalize_decision({"should_comment": True, "comment": ""})


class AiIssueEventTest(unittest.TestCase):
    def run_event(self, *, valid=True, latest=None, state="open", comments=None, latest_comments=None, decision=(False, True, "辅助摘要")):
        issue = {"number": 42, "title": "合成测试报告", "body": "current body", "state": state,
                 "user": {"login": "reporter"}}
        payload = {"action": "edited", "issue": issue, "sender": {"type": "User"}}
        client = Mock()
        client.issue.side_effect = [issue, latest or issue]
        client.comments.side_effect = [comments or [], latest_comments if latest_comments is not None else (comments or [])]
        with (
            patch.object(check_issue, "load_event", return_value=(payload, issue)),
            patch.object(check_issue, "GitHubIssues", return_value=client),
            patch.object(check_issue, "validate", return_value=Mock(valid=valid)),
            patch.object(check_issue, "classify_issue", return_value=decision) as classify,
            patch.dict(os.environ, {
                "GITHUB_REPOSITORY": "owner/repo", "GITHUB_TOKEN": "test-token",
                **({"API_URL": "https://example.test", "API_KEY": "test-key"} if valid else {}),
            }, clear=True),
            patch("sys.stdout", new=io.StringIO()),
        ):
            self.assertEqual(check_issue.main(), 0)
        return client, classify

    def test_incomplete_reports_skip_ai_without_api_secrets(self):
        client, classify = self.run_event(valid=False)
        classify.assert_not_called()
        client.upsert_comment.assert_not_called()

    def test_ai_suggestions_do_not_close_issues_or_change_labels(self):
        client, _ = self.run_event(decision=(True, True, "建议维护者检查范围"))
        client.sync_labels.assert_not_called()
        client.request.assert_not_called()
        content = client.upsert_comment.call_args.kwargs["body"]
        self.assertTrue(content.startswith(check_issue.AI_MARKER + "\n"))
        self.assertIn("请维护者复核", content)

    def test_reports_changed_during_model_call_discard_stale_advice(self):
        client, classify = self.run_event(latest={"number": 42, "state": "open", "title": "changed", "body": "new body"})
        classify.assert_called_once()
        client.upsert_comment.assert_not_called()

    def test_closed_reports_do_not_call_the_model(self):
        client, classify = self.run_event(state="closed")
        classify.assert_not_called()
        client.upsert_comment.assert_not_called()

    def test_new_no_comment_decision_clears_previous_ai_recommendation(self):
        previous = {"id": 9, "body": check_issue.AI_MARKER + "\nold advice",
                    "user": {"type": "Bot", "login": "github-actions[bot]"}}
        client, _ = self.run_event(comments=[previous], decision=(False, False, ""))
        self.assertIn("未提出额外建议", client.upsert_comment.call_args.kwargs["body"])

    def test_ai_receives_reporter_supplements_instead_of_requesting_them_again(self):
        supplement = {"body": "已补交的脱敏诊断片段", "user": {"login": "reporter", "type": "User"}}
        _, classify = self.run_event(comments=[supplement])
        self.assertIn("已补交的脱敏诊断片段", classify.call_args.args[0])

    def test_supplements_changed_during_model_call_discard_stale_advice(self):
        supplement = {"body": "新的脱敏诊断片段", "user": {"login": "reporter", "type": "User"}}
        client, classify = self.run_event(latest_comments=[supplement])
        classify.assert_called_once()
        client.upsert_comment.assert_not_called()


if __name__ == "__main__":
    unittest.main()
