import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIR))

from check_issue import (
    IssueCheckError,
    _chat_completions_url,
    _decode_json_response,
    _normalize_decision,
)


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


if __name__ == "__main__":
    unittest.main()
