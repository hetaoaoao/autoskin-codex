#!/usr/bin/env python3
"""Regression tests for schema-v2 validation and deterministic packaging."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
try:
    import tomllib
except ModuleNotFoundError:  # Python 3.9-3.10 remain supported by the theme tools.
    tomllib = None
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

from theme_core import EXAMPLE_ROOT, build_theme, validate_theme  # noqa: E402
from install_theme import render_native_config  # noqa: E402


class ThemeValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="autoskin-theme-test-")
        self.theme = Path(self.temp.name) / "chiikawa-summer"
        shutil.copytree(EXAMPLE_ROOT, self.theme, ignore=shutil.ignore_patterns(".build"))

    def tearDown(self) -> None:
        self.temp.cleanup()

    def read_manifest(self) -> dict[str, object]:
        return json.loads((self.theme / "theme.json").read_text(encoding="utf-8"))

    def write_manifest(self, manifest: dict[str, object]) -> None:
        (self.theme / "theme.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def test_bundled_example_is_valid(self) -> None:
        _, result = validate_theme(self.theme)
        self.assertTrue(result.ok, result.errors)

    def test_required_background_cannot_be_null(self) -> None:
        manifest = self.read_manifest()
        manifest["assets"]["background"] = None  # type: ignore[index]
        self.write_manifest(manifest)
        _, result = validate_theme(self.theme)
        self.assertIn("assets.background must be a relative asset path", result.errors)

    def test_unknown_top_level_field_is_rejected(self) -> None:
        manifest = self.read_manifest()
        manifest["surprise"] = True
        self.write_manifest(manifest)
        _, result = validate_theme(self.theme)
        self.assertIn("$.surprise is not a supported field", result.errors)

    def test_remote_url_in_custom_css_is_rejected(self) -> None:
        custom = self.theme / "custom.css"
        custom.write_text(
            ".dream-theme-chiikawa-summer .card { background: url(https://example.com/a.png); }\n",
            encoding="utf-8",
        )
        manifest = self.read_manifest()
        manifest["advanced"]["customCss"] = "custom.css"  # type: ignore[index]
        self.write_manifest(manifest)
        _, result = validate_theme(self.theme)
        self.assertTrue(
            any("remote CSS asset URL" in error for error in result.errors),
            result.errors,
        )

    def test_package_is_reproducible(self) -> None:
        first = Path(self.temp.name) / "first.zip"
        second = Path(self.temp.name) / "second.zip"
        command = [sys.executable, str(SCRIPTS / "theme_tool.py"), "package", str(self.theme)]
        subprocess.run(command + ["--output", str(first)], check=True, capture_output=True)
        subprocess.run(command + ["--output", str(second)], check=True, capture_output=True)
        self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_runtime_manifest_consumes_preview_content_and_decorations(self) -> None:
        manifest = self.read_manifest()
        build_dir, _ = build_theme(self.theme)
        runtime = json.loads((build_dir / "theme.json").read_text(encoding="utf-8"))
        self.assertEqual(runtime["content"]["heroTitle"], manifest["content"]["heroTitle"])
        self.assertEqual(
            runtime["content"]["cardTitles"],
            [card["title"] for card in manifest["content"]["cards"]],
        )
        self.assertEqual(len(runtime["decorations"]), len(manifest["decorations"]))

    def test_conversation_art_keeps_readable_contrast(self) -> None:
        build_dir, _ = build_theme(self.theme)
        runtime = json.loads((build_dir / "theme.json").read_text(encoding="utf-8"))
        self.assertEqual(runtime["tokens"]["--dream-chat-art-opacity"], "0.320")
        self.assertEqual(runtime["tokens"]["--dream-chat-wash"], "rgba(248, 254, 255, 0.460)")

    def test_hero_title_preserves_native_project_button(self) -> None:
        manifest = self.read_manifest()
        manifest["content"]["heroTitle"] = "A title without a project slot"  # type: ignore[index]
        self.write_manifest(manifest)
        _, result = validate_theme(self.theme)
        self.assertTrue(any("{{project}} exactly once" in error for error in result.errors), result.errors)

    def test_native_theme_replaces_inline_chrome_theme_without_duplicate_key(self) -> None:
        if tomllib is None:
            self.skipTest("stdlib tomllib is available on Python 3.11+")
        source = """[desktop]
appearanceTheme = "dark"
appearanceLightChromeTheme = { accent = "#123456", surface = "#FFFFFF" }
appearanceDarkChromeTheme = { accent = "#654321", surface = "#000000" }

[desktop.open-in-target-preferences]
global = "cursor"
"""
        native = {
            "appearance": "light",
            "accent": "#16ABC4",
            "surface": "#F8FDFE",
            "ink": "#184F5F",
            "contrast": 64,
            "opaqueWindows": True,
        }
        rendered = render_native_config(source, native)
        parsed = tomllib.loads(rendered)
        self.assertEqual(parsed["desktop"]["appearanceLightChromeTheme"]["accent"], "#16ABC4")
        self.assertEqual(parsed["desktop"]["appearanceDarkChromeTheme"]["accent"], "#654321")
        self.assertEqual(render_native_config(rendered, native), rendered)


if __name__ == "__main__":
    unittest.main()
