import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "etc/skills/live-session-status/scripts/session_tail.py"


def load_module():
    spec = importlib.util.spec_from_file_location("session_tail", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


session_tail = load_module()


class ToolHomeTests(unittest.TestCase):
    def test_homes_follow_the_tools_variables(self):
        with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": "/tmp/claude-home",
                                          "CODEX_HOME": "/tmp/codex-home"}):
            self.assertEqual(session_tail.claude_projects(), Path("/tmp/claude-home/projects"))
            self.assertEqual(session_tail.codex_sessions(), Path("/tmp/codex-home/sessions"))

    def test_homes_default_to_the_tools_defaults(self):
        environment = {k: v for k, v in os.environ.items()
                       if k not in ("CLAUDE_CONFIG_DIR", "CODEX_HOME")}
        with mock.patch.dict(os.environ, environment, clear=True):
            self.assertEqual(session_tail.claude_projects(), Path.home() / ".claude/projects")
            self.assertEqual(session_tail.codex_sessions(), Path.home() / ".codex/sessions")


class LatestTests(unittest.TestCase):
    def test_claude_transcript_found_under_config_dir(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as project:
            slug = session_tail.claude_slug(project)
            transcript = Path(home) / "projects" / slug / "s1.jsonl"
            transcript.parent.mkdir(parents=True)
            transcript.write_text("{}\n")
            with mock.patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": home}):
                self.assertEqual(session_tail.latest(project, False, None), transcript)

    def test_codex_rollout_found_under_codex_home(self):
        with tempfile.TemporaryDirectory() as home, tempfile.TemporaryDirectory() as project:
            rollout = Path(home) / "sessions/2026/10/14/rollout-1-s1.jsonl"
            rollout.parent.mkdir(parents=True)
            meta = {"type": "session_meta",
                    "payload": {"cwd": str(Path(project).resolve())}}
            rollout.write_text(json.dumps(meta) + "\n")
            with mock.patch.dict(os.environ, {"CODEX_HOME": home}):
                self.assertEqual(session_tail.latest(project, True, None), rollout)


if __name__ == "__main__":
    unittest.main()
