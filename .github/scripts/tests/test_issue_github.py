import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from issue_github import GitHubIssues, IssueCheckError

MARKER = "<!-- venera-next:issue-policy:v1 -->"
BODY = MARKER + "\nnew result\n"


def bot_comment(body):
    return {"id": 50, "body": body, "user": {"login": "github-actions[bot]", "type": "Bot"}}


class GitHubIssueTests(unittest.TestCase):
    def setUp(self):
        self.client = GitHubIssues("owner/repo", "test-token")

    def test_first_check_creates_one_comment(self):
        with patch.object(self.client, "request") as request:
            self.client.upsert_comment(10, marker=MARKER, body=BODY, comments=[])
        request.assert_called_once_with("/issues/10/comments", method="POST", payload={"body": BODY})

    def test_recheck_updates_previous_comment(self):
        with patch.object(self.client, "request") as request:
            self.client.upsert_comment(10, marker=MARKER, body=BODY, comments=[bot_comment(MARKER + "\nold result")])
        request.assert_called_once_with("/issues/comments/50", method="PATCH", payload={"body": BODY})

    def test_unchanged_result_does_not_notify_again(self):
        with patch.object(self.client, "request") as request:
            self.client.upsert_comment(10, marker=MARKER, body=BODY, comments=[bot_comment(BODY)])
        request.assert_not_called()

    def test_copied_marker_in_human_comment_is_never_edited(self):
        human = {"id": 9, "body": MARKER + "\nold result", "user": {"login": "reporter", "type": "User"}}
        with patch.object(self.client, "request") as request:
            self.client.upsert_comment(10, marker=MARKER, body=BODY, comments=[human])
        self.assertEqual(request.call_args.args[0], "/issues/10/comments")
        self.assertEqual(request.call_args.kwargs["method"], "POST")

    def test_label_updates_preserve_human_status_and_unowned_labels(self):
        issue = {"labels": [{"name": name} for name in (
            "bug", "area: data", "needs: information", "status: investigating", "review: low", "help wanted",
        )]}
        with patch.object(self.client, "request") as request:
            self.client.sync_labels(10, issue, owned={"bug", "enhancement", "area: data", "area: reader", "needs: information"}, wanted={"bug", "area: reader"})
        self.assertEqual(request.call_count, 3)
        self.assertEqual(request.call_args_list[0].kwargs["payload"], {"labels": ["area: reader"]})
        deleted = {call.args[0] for call in request.call_args_list[1:]}
        self.assertEqual(deleted, {"/issues/10/labels/area%3A%20data", "/issues/10/labels/needs%3A%20information"})

    def test_existing_label_colors_and_descriptions_are_not_changed(self):
        with (
            patch.object(self.client, "pages", return_value=[{"name": "bug", "color": "ffffff"}]),
            patch.object(self.client, "request") as request,
        ):
            self.client.ensure_labels({"bug": ("d73a4a", "应用缺陷"), "area: reader": ("1d76db", "阅读器")})
        request.assert_called_once_with("/labels", method="POST", payload={"name": "area: reader", "color": "1d76db", "description": "阅读器"})

    def test_comment_pagination_does_not_miss_late_evidence(self):
        first_page = [{"id": index} for index in range(100)]
        last_page = [{"id": 101, "body": "later diagnostic evidence"}]
        with patch.object(self.client, "request", side_effect=[first_page, last_page]) as request:
            comments = self.client.comments(10)
        self.assertEqual(len(comments), 101)
        self.assertEqual(comments[-1]["body"], "later diagnostic evidence")
        self.assertEqual(request.call_args_list[1].args[0], "/issues/10/comments?per_page=100&page=2")

    def test_concurrent_label_creation_is_rechecked_without_overwriting(self):
        with (
            patch.object(self.client, "pages", side_effect=[[], [{"name": "area: reader"}]]),
            patch.object(self.client, "request", side_effect=IssueCheckError("HTTP 422 请求失败：already_exists")) as request,
        ):
            self.client.ensure_labels({"area: reader": ("1d76db", "阅读器")})
        request.assert_called_once()

    def test_invalid_list_response_fails_before_mutation(self):
        with patch.object(self.client, "request", return_value={"message": "invalid"}):
            with self.assertRaises(IssueCheckError):
                self.client.comments(10)


if __name__ == "__main__":
    unittest.main()
