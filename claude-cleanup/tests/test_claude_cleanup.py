from __future__ import annotations

import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from io import StringIO
from unittest import mock


SCRIPT = pathlib.Path(__file__).parents[1] / "scripts" / "claude_cleanup.py"
SPEC = importlib.util.spec_from_file_location("claude_cleanup", SCRIPT)
assert SPEC and SPEC.loader
claude_cleanup = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = claude_cleanup
SPEC.loader.exec_module(claude_cleanup)


class ClaudeCleanupTests(unittest.TestCase):
    def make_home(self) -> tuple[tempfile.TemporaryDirectory[str], object]:
        temp = tempfile.TemporaryDirectory()
        home = pathlib.Path(temp.name)
        paths = claude_cleanup.Paths(home)
        paths.claude_dir.mkdir()
        paths.trash.mkdir()
        return temp, paths

    def test_full_backup_contains_protected_data_and_claude_json(self) -> None:
        temp, paths = self.make_home()
        self.addCleanup(temp.cleanup)
        expected = {
            "projects/session.jsonl": "session",
            "skills/example/SKILL.md": "skill",
            "plugins/plugin.json": "plugin",
            "hooks/guard.sh": "hook",
            "settings.json": '{"env": {}}',
        }
        for relative, content in expected.items():
            target = paths.claude_dir / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        paths.claude_json.write_text('{"userID":"old"}', encoding="utf-8")

        backup = claude_cleanup.create_full_backup(paths)

        for relative, content in expected.items():
            copied = backup / "dot-claude" / relative
            self.assertEqual(copied.read_text(encoding="utf-8"), content)
        self.assertEqual(
            (backup / "claude.json").read_text(encoding="utf-8"),
            '{"userID":"old"}',
        )
        manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
        self.assertTrue(manifest["claudeJsonCopied"])
        self.assertGreaterEqual(manifest["items"], len(expected))

    def test_deletion_gate_rejects_every_protected_branch_and_parent(self) -> None:
        temp, paths = self.make_home()
        self.addCleanup(temp.cleanup)
        for name in claude_cleanup.PROTECTED_CLAUDE_NAMES:
            with self.subTest(name=name):
                with self.assertRaises(RuntimeError):
                    claude_cleanup.assert_deletion_allowed(paths.claude_dir / name, paths)
        with self.assertRaises(RuntimeError):
            claude_cleanup.assert_deletion_allowed(paths.claude_dir, paths)

    def test_allowlisted_cache_moves_without_touching_protected_paths(self) -> None:
        temp, paths = self.make_home()
        self.addCleanup(temp.cleanup)
        cache = paths.claude_dir / "cache"
        cache.mkdir()
        (cache / "entry").write_text("cache", encoding="utf-8")
        project = paths.claude_dir / "projects" / "session.jsonl"
        project.parent.mkdir()
        project.write_text("session", encoding="utf-8")
        run_dir = paths.trash / "run"

        destination = claude_cleanup.move_to_trash(cache, paths, run_dir)

        self.assertFalse(cache.exists())
        self.assertEqual((destination / "entry").read_text(encoding="utf-8"), "cache")
        self.assertEqual(project.read_text(encoding="utf-8"), "session")

    def test_simple_prompt_enable_preserves_telemetry_and_other_settings(self) -> None:
        settings = {
            "env": {
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                "DISABLE_TELEMETRY": "0",
                "TOKEN": "secret",
            },
            "hooks": {"PreToolUse": ["keep"]},
            "enabledPlugins": {"example": True},
        }
        before = claude_cleanup.telemetry_snapshot(settings)

        updated = claude_cleanup.update_simple_prompt(settings, "enable")

        self.assertEqual(updated["env"]["CLAUDE_CODE_SIMPLE"], "1")
        self.assertEqual(claude_cleanup.telemetry_snapshot(updated), before)
        self.assertEqual(updated["env"]["TOKEN"], "secret")
        self.assertEqual(updated["hooks"], settings["hooks"])
        self.assertEqual(updated["enabledPlugins"], settings["enabledPlugins"])

    def test_simple_prompt_disable_does_not_turn_telemetry_on_or_off(self) -> None:
        settings = {
            "env": {
                "CLAUDE_CODE_SIMPLE": "1",
                "DISABLE_ERROR_REPORTING": "1",
            }
        }
        updated = claude_cleanup.update_simple_prompt(settings, "disable")
        self.assertNotIn("CLAUDE_CODE_SIMPLE", updated["env"])
        self.assertEqual(updated["env"]["DISABLE_ERROR_REPORTING"], "1")
        self.assertNotIn("DISABLE_TELEMETRY", updated["env"])

    def test_identity_rotation_preserves_unrelated_fields(self) -> None:
        original = {
            "userID": "a" * 64,
            "oauthAccount": {"emailAddress": "private@example.com"},
            "cachedGrowthBookFeatures": {"feature": True},
            "projects": {"keep": True},
            "customSetting": "keep",
        }

        updated, old_ids, new_ids = claude_cleanup.rotate_identity(original)

        self.assertEqual(old_ids["userID"], "a" * 64)
        self.assertIsNone(old_ids["machineID"])
        self.assertRegex(new_ids["userID"], r"^[0-9a-f]{64}$")
        self.assertRegex(new_ids["machineID"], r"^[0-9a-f]{64}$")
        self.assertNotEqual(new_ids["userID"], old_ids["userID"])
        self.assertEqual(updated["userID"], new_ids["userID"])
        self.assertEqual(updated["machineID"], new_ids["machineID"])
        self.assertNotIn("oauthAccount", updated)
        self.assertNotIn("cachedGrowthBookFeatures", updated)
        self.assertEqual(updated["projects"], {"keep": True})
        self.assertEqual(updated["customSetting"], "keep")
        self.assertEqual(original["oauthAccount"]["emailAddress"], "private@example.com")

    def test_no_noninteractive_confirmation_flag_exists(self) -> None:
        with redirect_stderr(StringIO()), self.assertRaises(SystemExit):
            claude_cleanup.parse_args(["--yes"])

    def test_final_confirmation_cancels_before_any_write(self) -> None:
        temp, paths = self.make_home()
        self.addCleanup(temp.cleanup)
        claude_cleanup.atomic_write_json(paths.settings, {"env": {}})
        answers = iter(["n", "n", "0", "n", "0", "n", "NOT CONFIRMED"])
        with (
            mock.patch.object(pathlib.Path, "home", return_value=paths.home),
            mock.patch.object(claude_cleanup, "list_desktop_processes", return_value=[]),
            mock.patch.object(claude_cleanup, "list_cli_processes", return_value=[]),
            mock.patch("builtins.input", side_effect=lambda _prompt="": next(answers)),
            mock.patch.object(sys.stdin, "isatty", return_value=True),
        ):
            result = claude_cleanup.main([])
        self.assertEqual(result, 1)
        self.assertFalse(paths.backup_root.exists())
        self.assertEqual(claude_cleanup.read_json(paths.settings), {"env": {}})

    def test_isolated_full_run_preserves_protected_data_and_telemetry(self) -> None:
        temp, paths = self.make_home()
        self.addCleanup(temp.cleanup)
        protected_files = {
            "projects/session.jsonl": "session",
            "skills/demo/SKILL.md": "skill",
            "plugins/demo.json": "plugin",
            "hooks/guard.sh": "hook",
        }
        for relative, content in protected_files.items():
            target = paths.claude_dir / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        settings = {
            "env": {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"},
            "hooks": {"PreToolUse": ["keep"]},
        }
        claude_cleanup.atomic_write_json(paths.settings, settings)
        claude_cleanup.atomic_write_json(
            paths.claude_json,
            {
                "userID": "a" * 64,
                "machineID": "b" * 64,
                "oauthAccount": {"emailAddress": "private"},
                "keep": True,
            },
        )
        internal_backups = paths.claude_dir / "backups"
        internal_backups.mkdir()
        claude_cleanup.atomic_write_json(
            internal_backups / ".claude.json.backup.1",
            {
                "userID": "a" * 64,
                "machineID": "b" * 64,
                "oauthAccount": {"emailAddress": "private"},
                "backupKeep": True,
            },
        )
        cache = paths.claude_dir / "cache"
        cache.mkdir()
        (cache / "entry").write_text("cache", encoding="utf-8")
        desktop = paths.home / "Library/Application Support/Claude"
        desktop.mkdir(parents=True)
        (desktop / "Cookies").write_text("desktop", encoding="utf-8")
        plan = claude_cleanup.Plan(
            rotate_identity=True,
            delete_keychain=False,
            desktop_data=True,
            desktop_app=False,
            clear_cli_caches=True,
            simple_prompt="enable",
            set_taipei_timezone=False,
        )

        with mock.patch.object(claude_cleanup, "require_process_decision", return_value=None):
            claude_cleanup.apply_plan(paths, settings, plan)

        backups = list(paths.backup_root.glob("claude-cleanup-*"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "dot-claude/projects/session.jsonl").exists())
        for relative, content in protected_files.items():
            self.assertEqual((paths.claude_dir / relative).read_text(encoding="utf-8"), content)
        self.assertFalse(cache.exists())
        self.assertFalse(desktop.exists())
        final_settings = claude_cleanup.read_json(paths.settings)
        self.assertEqual(final_settings["env"]["CLAUDE_CODE_SIMPLE"], "1")
        self.assertEqual(
            final_settings["env"]["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"], "1"
        )
        self.assertEqual(final_settings["hooks"], settings["hooks"])
        final_identity = claude_cleanup.read_json(paths.claude_json)
        self.assertRegex(final_identity["userID"], r"^[0-9a-f]{64}$")
        self.assertRegex(final_identity["machineID"], r"^[0-9a-f]{64}$")
        self.assertNotEqual(final_identity["userID"], "a" * 64)
        self.assertNotEqual(final_identity["machineID"], "b" * 64)
        self.assertNotIn("oauthAccount", final_identity)
        self.assertTrue(final_identity["keep"])
        final_internal_backup = claude_cleanup.read_json(
            internal_backups / ".claude.json.backup.1"
        )
        self.assertEqual(final_internal_backup["userID"], final_identity["userID"])
        self.assertEqual(final_internal_backup["machineID"], final_identity["machineID"])
        self.assertNotIn("oauthAccount", final_internal_backup)
        self.assertTrue(final_internal_backup["backupKeep"])


if __name__ == "__main__":
    unittest.main()
