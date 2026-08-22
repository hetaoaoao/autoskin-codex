#!/usr/bin/env python3
"""Snapshot-first installer for AutoSkin Codex schema-v2 themes."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

from theme_core import ThemeError, build_theme, load_json, normalize_theme_dir, write_json


def state_root() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "AutoSkinCodex"
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "AutoSkinCodex"
    return Path.home() / ".local" / "share" / "autoskin-codex"


def default_runtime_root() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "CodexAutoSkin" / "runtime"
    if os.name == "nt":
        return Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "CodexAutoSkin" / "runtime"
    return Path.home() / ".local" / "share" / "codex-autoskin" / "runtime"


def default_private_root(runtime_root: Path) -> Path:
    if runtime_root.name == "runtime":
        return runtime_root.parent / "themes-private"
    return runtime_root / "themes-private"


def find_node(runtime_root: Path) -> Path:
    install_state = runtime_root.parent / "install-state.json"
    if install_state.is_file():
        node_value = load_json(install_state).get("nodePath")
        if isinstance(node_value, str) and Path(node_value).is_file():
            return Path(node_value)
    candidate = shutil.which("node")
    if candidate:
        return Path(candidate)
    if sys.platform == "darwin":
        bundled = Path("/Applications/ChatGPT.app/Contents/Resources/app.asar.unpacked/node_modules")
        if bundled.is_dir():
            raise ThemeError(
                "the Codex app is present, but this runtime did not record its Node executable; "
                "repair the safe runtime before applying a theme"
            )
    raise ThemeError("Node.js executable was not found in install-state.json or PATH")


def doctor(runtime_root: Path) -> dict[str, Any]:
    scripts = runtime_root / "scripts"
    required = [
        scripts / "injector.mjs",
        scripts / "set-theme.mjs",
        scripts / "autoskin-macos.sh" if sys.platform == "darwin" else scripts / "install-dream-skin.ps1",
        runtime_root / "assets" / "renderer-inject.js",
        runtime_root / "styles" / "dream" / "style.css",
    ]
    missing = [str(path) for path in required if not path.is_file()]
    return {
        "runtimeRoot": str(runtime_root),
        "privateThemes": str(default_private_root(runtime_root)),
        "runtimeReady": not missing,
        "missing": missing,
    }


def toml_quote(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def remove_toml_sections(text: str, section_names: list[str]) -> str:
    lines = text.splitlines(keepends=True)
    output: list[str] = []
    skipping = False
    targets = {name.strip() for name in section_names}
    for line in lines:
        match = re.match(r"^\s*\[([^\]]+)\]\s*$", line)
        if match:
            skipping = match.group(1).strip() in targets
        if not skipping:
            output.append(line)
    return "".join(output)


def update_desktop_scalar(text: str, key: str, value: str) -> str:
    lines = text.splitlines(keepends=True)
    desktop_start = None
    desktop_end = len(lines)
    for index, line in enumerate(lines):
        match = re.match(r"^\s*\[([^\]]+)\]\s*$", line)
        if not match:
            continue
        name = match.group(1).strip()
        if name == "desktop":
            desktop_start = index
            continue
        if desktop_start is not None:
            desktop_end = index
            break
    if desktop_start is None:
        if text and not text.endswith("\n"):
            text += "\n"
        return text + f"\n[desktop]\n{key} = {value}\n"
    pattern = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for index in range(desktop_start + 1, desktop_end):
        if pattern.match(lines[index]):
            newline = "\n" if lines[index].endswith("\n") else ""
            lines[index] = f"{key} = {value}{newline}"
            return "".join(lines)
    lines.insert(desktop_end, f"{key} = {value}\n")
    return "".join(lines)


def remove_desktop_scalars(text: str, keys: set[str]) -> str:
    """Remove selected direct keys from [desktop] without touching nested tables."""
    lines = text.splitlines(keepends=True)
    output: list[str] = []
    in_desktop = False
    patterns = [re.compile(rf"^\s*{re.escape(key)}\s*=") for key in keys]
    for line in lines:
        section = re.match(r"^\s*\[([^\]]+)\]\s*$", line)
        if section:
            in_desktop = section.group(1).strip() == "desktop"
        if in_desktop and any(pattern.match(line) for pattern in patterns):
            continue
        output.append(line)
    return "".join(output)


def native_theme_block(native: dict[str, Any]) -> str:
    mode = native["appearance"].capitalize()
    key = f"desktop.appearance{mode}ChromeTheme"
    code_font = "Cascadia Mono" if os.name == "nt" else "SFMono-Regular"
    ui_font = "Segoe UI" if os.name == "nt" else "SF Pro Text"
    return (
        f"\n[{key}]\n"
        f"accent = {toml_quote(native['accent'])}\n"
        f"contrast = {native['contrast']}\n"
        f"ink = {toml_quote(native['ink'])}\n"
        f"opaqueWindows = {'true' if native['opaqueWindows'] else 'false'}\n"
        f"surface = {toml_quote(native['surface'])}\n"
        f"\n[{key}.fonts]\n"
        f'code = {toml_quote(code_font)}\n'
        f'ui = {toml_quote(ui_font)}\n'
        f"\n[{key}.semanticColors]\n"
        f"diffAdded = {toml_quote('#00A240')}\n"
        f"diffRemoved = {toml_quote('#E02E2A')}\n"
        f"skill = {toml_quote(native['accent'])}\n"
    )


def render_native_config(source: str, native: dict[str, Any]) -> str:
    mode = native["appearance"].capitalize()
    table = f"desktop.appearance{mode}ChromeTheme"
    names = [
        table,
        f"{table}.fonts",
        f"{table}.semanticColors",
    ]
    result = remove_toml_sections(source, names)
    result = remove_desktop_scalars(result, {f"appearance{mode}ChromeTheme"})
    appearance = native["appearance"]
    result = update_desktop_scalar(result, "appearanceTheme", toml_quote(appearance))
    code_key = f"appearance{appearance.capitalize()}CodeThemeId"
    result = update_desktop_scalar(result, code_key, '"codex"')
    marker = "\n[desktop.open-in-target-preferences]"
    block = native_theme_block(native)
    if marker in result:
        result = result.replace(marker, block + marker, 1)
    else:
        result = result.rstrip() + "\n" + block
    return result


def atomic_install(build_dir: Path, destination: Path, snapshot: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage = destination.parent / f".{destination.name}.autoskin-next-{os.getpid()}"
    if stage.exists():
        shutil.rmtree(stage)
    shutil.copytree(build_dir, stage)
    previous = snapshot / "previous-theme"
    if destination.exists():
        shutil.copytree(destination, previous)
        shutil.rmtree(destination)
    stage.rename(destination)


def restore_install(destination: Path, snapshot: Path, config_path: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)
    previous = snapshot / "previous-theme"
    if previous.is_dir():
        shutil.copytree(previous, destination)
    config_backup = snapshot / "config.toml"
    if config_backup.is_file():
        shutil.copy2(config_backup, config_path)


def run_runtime(
    runtime_root: Path,
    theme_id: str,
    layout: str,
    port: int,
) -> dict[str, Any]:
    node = find_node(runtime_root)
    injector = runtime_root / "scripts" / "injector.mjs"
    switcher = runtime_root / "scripts" / "set-theme.mjs"
    reload_result = subprocess.run(
        [str(node), str(injector), "--once", "--reload", "--port", str(port)],
        check=True,
        capture_output=True,
        text=True,
    )
    switch_result = subprocess.run(
        [str(node), str(switcher), theme_id, layout, "--port", str(port)],
        check=True,
        capture_output=True,
        text=True,
    )
    verify_result = subprocess.run(
        [str(node), str(injector), "--verify", "--port", str(port)],
        check=True,
        capture_output=True,
        text=True,
    )
    return {
        "node": str(node),
        "reload": reload_result.stdout.strip(),
        "switch": switch_result.stdout.strip(),
        "verify": verify_result.stdout.strip(),
    }


def command_install(args: argparse.Namespace) -> int:
    theme_dir = normalize_theme_dir(args.theme)
    build_dir, build_report = build_theme(theme_dir)
    source_theme = load_json(build_dir / "source-theme.json")
    theme_id = source_theme["id"]
    runtime_root = Path(args.runtime_root).expanduser().resolve()
    health = doctor(runtime_root)
    if not health["runtimeReady"]:
        raise ThemeError(
            "safe runtime is incomplete; install or repair the bundled autoskin-codex runtime first:\n"
            + "\n".join(health["missing"])
        )
    private_root = default_private_root(runtime_root)
    destination = private_root / theme_id
    config_path = Path(args.config).expanduser().resolve()
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    snapshot = state_root() / "snapshots" / f"{timestamp}-{theme_id}"
    plan = {
        "theme": theme_id,
        "source": str(theme_dir),
        "build": str(build_dir),
        "destination": str(destination),
        "snapshot": str(snapshot),
        "config": str(config_path),
        "applyNativeTheme": not args.skip_native_theme,
        "applyLive": args.apply,
        "layout": args.layout,
        "port": args.port,
        "warnings": build_report["warnings"],
    }
    if args.dry_run:
        print(json.dumps({"ok": True, "dryRun": True, "doctor": health, "plan": plan}, ensure_ascii=False, indent=2))
        return 0

    snapshot.mkdir(parents=True, exist_ok=False)
    write_json(snapshot / "install-plan.json", plan)
    if config_path.is_file():
        shutil.copy2(config_path, snapshot / "config.toml")
    try:
        atomic_install(build_dir, destination, snapshot)
        if not args.skip_native_theme:
            if not config_path.is_file():
                raise ThemeError(f"Codex config does not exist: {config_path}")
            updated = render_native_config(
                config_path.read_text(encoding="utf-8"),
                source_theme["nativeTheme"],
            )
            next_config = config_path.with_name(config_path.name + ".autoskin-next")
            next_config.write_text(updated, encoding="utf-8")
            os.replace(next_config, config_path)
        runtime_result = None
        if args.apply:
            runtime_result = run_runtime(runtime_root, theme_id, args.layout, args.port)
        result = {
            "ok": True,
            "installed": str(destination),
            "snapshot": str(snapshot),
            "runtime": runtime_result,
            "restartRequiredForNativeChrome": not args.skip_native_theme,
        }
        write_json(snapshot / "install-result.json", result)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception:
        restore_install(destination, snapshot, config_path)
        raise


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    root.add_argument("theme", help="schema-v2 theme directory or theme.json")
    root.add_argument("--runtime-root", default=str(default_runtime_root()))
    root.add_argument("--config", default=str(Path.home() / ".codex" / "config.toml"))
    root.add_argument("--layout", choices=("fullscreen", "banner"), default="fullscreen")
    root.add_argument("--port", type=int, default=9335)
    root.add_argument("--apply", action="store_true", help="reload and switch the running safe runtime")
    root.add_argument("--skip-native-theme", action="store_true")
    root.add_argument("--dry-run", action="store_true")
    return root


def main() -> int:
    args = parser().parse_args()
    try:
        if not 1024 <= args.port <= 65535:
            raise ThemeError("--port must be from 1024 to 65535")
        return command_install(args)
    except ThemeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or str(exc)).strip()
        print(f"error: runtime command failed; install rolled back: {detail}", file=sys.stderr)
        return exc.returncode or 1


if __name__ == "__main__":
    raise SystemExit(main())
