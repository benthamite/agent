"""Routing and data-encoding checks for the status publisher."""
import base64
import json
from pathlib import Path
import re
import runpy
from types import SimpleNamespace
import unittest

helper = runpy.run_path(str(Path(__file__).resolve().parents[1] / "bin" / "agent-status"))


class StatusPublisherTests(unittest.TestCase):
    def test_codex_identity_and_whitespace(self):
        request = helper["request_payload"]("Testing\n fix", None,
                    {"CODEX_BUFFER_NAME": "*codex*", "CODEX_THREAD_ID": "thread-1"})
        self.assertEqual(request["text"], "Testing fix")
        self.assertEqual(request["session_id"], "thread-1")

    def test_reject_missing_or_ambiguous_routing(self):
        for env in ({}, {"CODEX_BUFFER_NAME": "a", "CLAUDE_BUFFER_NAME": "b", "AGENT_SESSION_UUID": "uuid-1"}):
            with self.assertRaises(ValueError):
                helper["request_payload"]("Testing", None, env)

    def test_explicit_backend_and_clear(self):
        request = helper["request_payload"]("", "claude-code",
                    {"CODEX_BUFFER_NAME": "a", "CLAUDE_BUFFER_NAME": "b", "AGENT_SESSION_UUID": "uuid-1"})
        self.assertEqual(request["buffer"], "b")
        self.assertEqual(request["text"], "")
        self.assertIsNone(request["session_id"])

    def test_missing_publisher_identity(self):
        with self.assertRaises(ValueError):
            helper["request_payload"]("Testing", None, {"CLAUDE_BUFFER_NAME": "b"})

    def test_length_limit(self):
        with self.assertRaises(ValueError):
            helper["request_payload"]("x" * 161, None, {"CODEX_BUFFER_NAME": "a", "CODEX_THREAD_ID": "thread-1"})

    def test_text_is_encoded_not_executable(self):
        text = '\" ) (error \"injected\") ; `$(touch bogus)` — тест'
        request = helper["request_payload"](text, None, {"CODEX_BUFFER_NAME": "a", "CODEX_THREAD_ID": "thread-1"})
        expr = helper["expression"](request)
        encoded = re.search(r'base64-decode-string "([A-Za-z0-9+/=]+)"', expr)[1]
        self.assertEqual(json.loads(base64.b64decode(encoded)), request)
        self.assertNotIn("injected", expr)


    def test_retries_refused_connections_then_succeeds(self):
        refused = SimpleNamespace(returncode=1, stdout="", stderr="emacsclient: can't connect to /tmp/server: Connection refused")
        answers = [refused, refused, SimpleNamespace(returncode=0, stdout="t\n", stderr="")]
        delays = []
        helper["publish"](["emacsclient"], run=lambda *a, **k: answers.pop(0), sleep=delays.append)
        self.assertEqual(delays, [0.5, 1])

    def test_gives_up_after_repeated_refusals(self):
        refused = SimpleNamespace(returncode=1, stdout="", stderr='emacsclient: error accessing socket "/tmp/server"')
        delays = []
        with self.assertRaises(ValueError):
            helper["publish"](["emacsclient"], run=lambda *a, **k: refused, sleep=delays.append)
        self.assertEqual(delays, [0.5, 1, 2, 4])

    def test_rejection_is_not_retried(self):
        rejected = SimpleNamespace(returncode=1, stdout="", stderr="*ERROR*: No live agent session named x")
        delays = []
        with self.assertRaises(ValueError):
            helper["publish"](["emacsclient"], run=lambda *a, **k: rejected, sleep=delays.append)
        self.assertEqual(delays, [])


if __name__ == "__main__":
    unittest.main()
