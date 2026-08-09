from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "claude_cleanup.py"
SPEC = importlib.util.spec_from_file_location("claude_cleanup", SCRIPT)
assert SPEC and SPEC.loader
cleanup = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = cleanup
SPEC.loader.exec_module(cleanup)


class CleanupTests(unittest.TestCase):
    def home(self) -> pathlib.Path:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        home = pathlib.Path(temp.name)
        (home / ".claude").mkdir()
        (home / ".Trash").mkdir()
        return home

    def seed_protected(self, home: pathlib.Path) -> dict[str, str]:
        files = {
            "projects/session.jsonl": "session",
            "skills/demo/SKILL.md": "skill",
            "plugins/demo.json": "plugin",
            "hooks/guard.sh": "hook",
        }
        for relative, content in files.items():
            target = home / ".claude" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        return files

    def test_backup_contains_all_claude_data_and_identity(self):
        home = self.home()
        files = self.seed_protected(home)
        (home / ".claude.json").write_text('{"userID":"old"}', encoding="utf-8")
        backup = cleanup.create_backup(home)
        for relative, content in files.items():
            self.assertEqual((backup / "dot-claude" / relative).read_text(), content)
        self.assertEqual((backup / "claude.json").read_text(), '{"userID":"old"}')
        manifest = json.loads((backup / "manifest.json").read_text())
        self.assertGreaterEqual(manifest["files"], len(files))
        self.assertTrue(manifest["claudeJsonCopied"])

    def test_deletion_gate_rejects_protected_and_unknown_paths(self):
        home = self.home()
        claude, batch = home / ".claude", home / ".Trash/run"
        for name in cleanup.PROTECTED:
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                cleanup.move_to_trash(claude / name, {claude / name}, claude, batch)
        with self.assertRaises(RuntimeError):
            cleanup.move_to_trash(home / "Documents", set(), claude, batch)

    def test_safe_cache_moves_without_touching_project(self):
        home = self.home()
        project = home / ".claude/projects/session.jsonl"
        project.parent.mkdir()
        project.write_text("keep")
        cache = home / ".claude/cache"
        cache.mkdir()
        (cache / "entry").write_text("cache")
        destination = cleanup.move_to_trash(cache, {cache}, home / ".claude", home / ".Trash/run")
        self.assertFalse(cache.exists())
        self.assertEqual((destination / "entry").read_text(), "cache")
        self.assertEqual(project.read_text(), "keep")

    def test_identity_rotation_syncs_internal_backups(self):
        home = self.home()
        cleanup.write_json(home / ".claude.json", {"userID": "old", "machineID": "old", "oauthAccount": {}, "keep": 1})
        internal = home / ".claude/backups/.claude.json.backup.1"
        internal.parent.mkdir()
        cleanup.write_json(internal, {"userID": "old", "machineID": "old", "oauthAccount": {}, "keepBackup": 1})
        self.assertEqual(cleanup.rotate_identity(home), 1)
        main, backup = cleanup.read_json(home / ".claude.json"), cleanup.read_json(internal)
        self.assertEqual((main["userID"], main["machineID"]), (backup["userID"], backup["machineID"]))
        self.assertNotIn("oauthAccount", main)
        self.assertNotIn("oauthAccount", backup)
        self.assertEqual((main["keep"], backup["keepBackup"]), (1, 1))

    def test_simple_mode_preserves_telemetry_and_other_settings(self):
        home = self.home()
        path = home / ".claude/settings.json"
        original = {"env": {"DISABLE_TELEMETRY": "1", "TOKEN": "secret"}, "hooks": {"x": ["keep"]}}
        cleanup.write_json(path, original)
        cleanup.update_simple(home, 1)
        updated = cleanup.read_json(path)
        self.assertEqual(updated["env"]["CLAUDE_CODE_SIMPLE"], "1")
        self.assertEqual(cleanup.telemetry(updated), cleanup.telemetry(original))
        self.assertEqual(updated["hooks"], original["hooks"])

    def run_main(self, home: pathlib.Path, answers: list[str], processes: list[str] | None = None) -> tuple[int, list[str]]:
        prompts, iterator = [], iter(answers)

        def answer(prompt=""):
            prompts.append(prompt)
            return next(iterator)

        with (
            mock.patch.object(pathlib.Path, "home", return_value=home),
            mock.patch.object(cleanup, "running_under_claude", return_value=False),
            mock.patch.object(cleanup, "claude_processes", return_value=processes or []),
            mock.patch.object(cleanup, "current_timezone", return_value="Asia/Taipei"),
            mock.patch.object(sys.stdin, "isatty", return_value=True),
            mock.patch("builtins.input", side_effect=answer),
        ):
            return cleanup.main([]), prompts

    def test_safe_cleanup_is_not_a_question_and_cancel_writes_nothing(self):
        home = self.home()
        (home / ".claude/cache").mkdir()
        result, prompts = self.run_main(home, ["n", "n", "0", "0", "NO"])
        self.assertEqual(result, 1)
        self.assertFalse((home / "ClaudeBackups").exists())
        self.assertTrue((home / ".claude/cache").exists())
        self.assertEqual(len(prompts), 5)
        self.assertFalse(any("自动清理" in prompt or "可再生缓存" in prompt for prompt in prompts))

    def test_running_claude_skips_safe_cleanup_without_exit_prompt(self):
        home = self.home()
        cache = home / ".claude/cache"
        cache.mkdir()
        result, prompts = self.run_main(home, ["n", "n", "0", "0", "CONFIRM"], ["123 claude"])
        self.assertEqual(result, 0)
        self.assertTrue(cache.exists())
        self.assertFalse(any("退出后按 Enter" in prompt for prompt in prompts))

    def test_claude_agent_allows_audit_only(self):
        home = self.home()
        with (
            mock.patch.object(pathlib.Path, "home", return_value=home),
            mock.patch.object(cleanup, "running_under_claude", return_value=True),
            mock.patch.object(cleanup, "current_timezone", return_value="Asia/Taipei"),
            mock.patch.object(cleanup, "claude_processes", return_value=[]),
        ):
            self.assertEqual(cleanup.main([]), 2)
            self.assertEqual(cleanup.main(["--audit"]), 0)

    def test_isolated_full_run_preserves_protected_data_and_telemetry(self):
        home = self.home()
        protected = self.seed_protected(home)
        settings = {"env": {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}, "hooks": {"x": ["keep"]}}
        cleanup.write_json(home / ".claude/settings.json", settings)
        cleanup.write_json(home / ".claude.json", {"userID": "old", "machineID": "old", "oauthAccount": {}, "keep": True})
        internal = home / ".claude/backups/.claude.json.backup.1"
        internal.parent.mkdir()
        cleanup.write_json(internal, {"userID": "old", "machineID": "old", "backupKeep": True})
        cache = home / ".claude/cache"
        cache.mkdir()
        (cache / "entry").write_text("cache")
        result, _ = self.run_main(home, ["y", "n", "0", "1", "CONFIRM"])
        self.assertEqual(result, 0)
        backups = list((home / "ClaudeBackups").glob("claude-cleanup-*"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "dot-claude/projects/session.jsonl").exists())
        self.assertFalse(cache.exists())
        for relative, content in protected.items():
            self.assertEqual((home / ".claude" / relative).read_text(), content)
        final = cleanup.read_json(home / ".claude/settings.json")
        self.assertEqual(cleanup.telemetry(final), cleanup.telemetry(settings))
        self.assertEqual(final["hooks"], settings["hooks"])
        identity, saved = cleanup.read_json(home / ".claude.json"), cleanup.read_json(internal)
        self.assertEqual(identity["userID"], saved["userID"])
        self.assertTrue(identity["keep"] and saved["backupKeep"])


if __name__ == "__main__":
    unittest.main()
