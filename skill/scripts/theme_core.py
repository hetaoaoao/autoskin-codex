#!/usr/bin/env python3
"""Deterministic schema-v2 helpers for AutoSkin Codex."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import shutil
import struct
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

SKILL_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_PATH = SKILL_ROOT / "assets" / "theme-template" / "theme.json"
PREVIEWER_ROOT = SKILL_ROOT / "assets" / "previewer"
EXAMPLE_ROOT = SKILL_ROOT / "examples" / "chiikawa-summer"
ID_RE = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
ASSET_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp"}
ASSET_MIME = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
}
FORBIDDEN_TEXT = (
    (re.compile(r"data\s*:\s*image", re.I), "embedded data image"),
    (re.compile(r";\s*base64\s*,", re.I), "Base64 payload"),
    (re.compile(r"url\s*\(\s*['\"]?\s*javascript:", re.I), "javascript URL"),
    (re.compile(r"url\s*\(\s*['\"]?\s*https?://", re.I), "remote CSS asset URL"),
    (re.compile(r"<\s*script\b", re.I), "script markup"),
    (re.compile(r"expression\s*\(", re.I), "CSS expression"),
)
REQUIRED_META = ("name", "shortName", "edition", "signature")
VIEW_NAMES = ("fullscreen", "banner", "chat")


class ThemeError(RuntimeError):
    pass


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors

    def require_ok(self) -> None:
        if not self.ok:
            raise ThemeError("\n".join(self.errors))


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ThemeError(f"missing file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ThemeError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ThemeError(f"JSON root must be an object: {path}")
    return value


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )


def normalize_theme_dir(path: str | Path) -> Path:
    theme_dir = Path(path).expanduser().resolve()
    if theme_dir.is_file() and theme_dir.name == "theme.json":
        theme_dir = theme_dir.parent
    return theme_dir


def iter_strings(value: Any, key_path: str = "$") -> Iterable[tuple[str, str]]:
    if isinstance(value, str):
        yield key_path, value
    elif isinstance(value, dict):
        for key, child in value.items():
            yield from iter_strings(child, f"{key_path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from iter_strings(child, f"{key_path}[{index}]")


def is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def validate_color(value: Any, key: str, result: ValidationResult) -> None:
    if not isinstance(value, str) or not HEX_RE.fullmatch(value):
        result.errors.append(f"{key} must be a six-digit hex color")


def validate_unit_interval(value: Any, key: str, result: ValidationResult) -> None:
    if not is_number(value) or not 0 <= float(value) <= 1:
        result.errors.append(f"{key} must be a number from 0 to 1")


def resolve_asset(
    theme_dir: Path,
    value: Any,
    key: str,
    result: ValidationResult,
    *,
    allow_null: bool = True,
) -> Path | None:
    if value is None:
        if not allow_null:
            result.errors.append(f"{key} must be a relative asset path")
        return None
    if not isinstance(value, str) or not value:
        result.errors.append(f"{key} must be null or a relative asset path")
        return None
    normalized = value.replace("\\", "/")
    if normalized.startswith("/") or not normalized.startswith("assets/") or ".." in Path(normalized).parts:
        result.errors.append(f"{key} must stay under assets/: {value}")
        return None
    if Path(normalized).suffix.lower() not in ASSET_EXTENSIONS:
        result.errors.append(f"{key} must reference png/jpg/jpeg/webp: {value}")
        return None
    candidate = (theme_dir / normalized).resolve()
    assets_root = (theme_dir / "assets").resolve()
    try:
        candidate.relative_to(assets_root)
    except ValueError:
        result.errors.append(f"{key} escapes assets/: {value}")
        return None
    if not candidate.is_file():
        result.errors.append(f"{key} file does not exist: {value}")
        return None
    return candidate


def image_info(path: Path) -> tuple[int, int, bool | None]:
    data = path.read_bytes()
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 26:
        width, height = struct.unpack(">II", data[16:24])
        color_type = data[25]
        return width, height, color_type in (4, 6)
    if data[:2] == b"\xff\xd8":
        index = 2
        while index + 9 < len(data):
            if data[index] != 0xFF:
                index += 1
                continue
            marker = data[index + 1]
            index += 2
            if marker in (0xD8, 0xD9):
                continue
            if index + 2 > len(data):
                break
            length = struct.unpack(">H", data[index:index + 2])[0]
            if marker in {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}:
                height, width = struct.unpack(">HH", data[index + 3:index + 7])
                return width, height, False
            index += max(length, 2)
    return 0, 0, None


def validate_custom_css(theme_dir: Path, theme_id: str, relative: Any, result: ValidationResult) -> None:
    if relative is None:
        return
    if not isinstance(relative, str) or not relative:
        result.errors.append("advanced.customCss must be null or a relative CSS path")
        return
    css_path = (theme_dir / relative).resolve()
    try:
        css_path.relative_to(theme_dir)
    except ValueError:
        result.errors.append("advanced.customCss escapes the theme directory")
        return
    if css_path.suffix.lower() != ".css" or not css_path.is_file():
        result.errors.append(f"advanced.customCss file is missing or not CSS: {relative}")
        return
    css = css_path.read_text(encoding="utf-8")
    for pattern, label in FORBIDDEN_TEXT:
        if pattern.search(css):
            result.errors.append(f"advanced.customCss contains prohibited {label}")
    stripped = re.sub(r"/\*[\s\S]*?\*/", "", css)
    scope = f".dream-theme-{theme_id}"
    for selector_text in re.findall(r"([^{}]+)\{", stripped):
        selector_text = selector_text.strip()
        if selector_text.startswith("@"):
            if not re.match(r"^@(media|supports)\b", selector_text):
                result.errors.append(f"unsupported CSS at-rule: {selector_text[:60]}")
            continue
        for selector in selector_text.split(","):
            selector = selector.strip()
            first = re.split(r"[\s>+~]", selector, maxsplit=1)[0]
            if not (first.startswith("html.") or first.startswith(":root.")) or scope not in first:
                result.errors.append(f"custom CSS selector is not scoped to {scope}: {selector[:80]}")


def require_string(
    mapping: dict[str, Any],
    key: str,
    prefix: str,
    result: ValidationResult,
) -> None:
    if not isinstance(mapping.get(key), str) or not mapping[key].strip():
        result.errors.append(f"{prefix}.{key} must be a non-empty string")


def validate_component_color(
    mapping: dict[str, Any],
    key: str,
    prefix: str,
    result: ValidationResult,
    *,
    allow_transparent: bool = False,
) -> None:
    value = mapping.get(key)
    if allow_transparent and value == "transparent":
        return
    validate_color(value, f"{prefix}.{key}", result)


def validate_keys(
    mapping: dict[str, Any],
    allowed: set[str],
    prefix: str,
    result: ValidationResult,
) -> None:
    for key in sorted(set(mapping) - allowed):
        result.errors.append(f"{prefix}.{key} is not a supported field")


def validate_theme(theme_dir: Path) -> tuple[dict[str, Any], ValidationResult]:
    theme_dir = Path(theme_dir).expanduser().resolve()
    result = ValidationResult()
    manifest_path = theme_dir / "theme.json"
    try:
        theme = load_json(manifest_path)
    except ThemeError as exc:
        result.errors.append(str(exc))
        return {}, result

    validate_keys(
        theme,
        {
            "schemaVersion",
            "id",
            "meta",
            "nativeTheme",
            "assets",
            "views",
            "components",
            "content",
            "decorations",
            "advanced",
        },
        "$",
        result,
    )
    if theme.get("schemaVersion") != 2:
        result.errors.append("schemaVersion must be 2")
    theme_id = theme.get("id")
    if not isinstance(theme_id, str) or not ID_RE.fullmatch(theme_id):
        result.errors.append("id must be kebab-case")
        theme_id = "invalid"
    elif theme_dir.name != theme_id:
        result.warnings.append(f"theme folder is '{theme_dir.name}', but id is '{theme_id}'")

    meta = theme.get("meta")
    if not isinstance(meta, dict):
        result.errors.append("meta must be an object")
    else:
        validate_keys(meta, {"name", "shortName", "edition", "signature", "author"}, "meta", result)
        for key in REQUIRED_META:
            if not isinstance(meta.get(key), str) or not meta[key].strip():
                result.errors.append(f"meta.{key} must be a non-empty string")

    native = theme.get("nativeTheme")
    if not isinstance(native, dict):
        result.errors.append("nativeTheme must be an object")
    else:
        validate_keys(
            native,
            {
                "appearance",
                "accent",
                "surface",
                "ink",
                "contrast",
                "opaqueWindows",
            },
            "nativeTheme",
            result,
        )
        if native.get("appearance") not in {"light", "dark"}:
            result.errors.append("nativeTheme.appearance must be light or dark")
        for key in ("accent", "surface", "ink"):
            validate_color(native.get(key), f"nativeTheme.{key}", result)
        contrast = native.get("contrast")
        if not is_number(contrast) or not 0 <= float(contrast) <= 100:
            result.errors.append("nativeTheme.contrast must be a number from 0 to 100")
        if not isinstance(native.get("opaqueWindows"), bool):
            result.errors.append("nativeTheme.opaqueWindows must be true or false")

    assets = theme.get("assets")
    resolved_assets: dict[str, Path] = {}
    if not isinstance(assets, dict):
        result.errors.append("assets must be an object")
    else:
        validate_keys(assets, {"background", "chatBackground", "brandIcon", "cardIcons"}, "assets", result)
        for key in ("background", "chatBackground", "brandIcon"):
            path = resolve_asset(
                theme_dir,
                assets.get(key),
                f"assets.{key}",
                result,
                allow_null=key != "background",
            )
            if path:
                resolved_assets[key] = path
        card_icons = assets.get("cardIcons")
        if not isinstance(card_icons, list) or len(card_icons) != 4:
            result.errors.append("assets.cardIcons must contain exactly four entries")
        else:
            for index, value in enumerate(card_icons):
                path = resolve_asset(theme_dir, value, f"assets.cardIcons[{index}]", result)
                if path:
                    resolved_assets[f"cardIcons[{index}]"] = path

    background = resolved_assets.get("background")
    if background:
        width, height, _ = image_info(background)
        if width and (width < 1600 or height < 900):
            result.warnings.append(
                f"background is {width}x{height}; 1600x900 or larger is recommended"
            )
        elif not width:
            result.warnings.append(f"could not read image dimensions for {background.name}")

    for key, path in resolved_assets.items():
        if key.startswith("cardIcons") or key == "brandIcon":
            width, height, alpha = image_info(path)
            if width and max(width, height) > 1200:
                result.warnings.append(f"{key} is unusually large: {width}x{height}")
            if alpha is False and path.suffix.lower() == ".png":
                result.warnings.append(f"{key} PNG has no alpha channel")

    views = theme.get("views")
    if not isinstance(views, dict):
        result.errors.append("views must be an object")
    else:
        for name in VIEW_NAMES:
            view = views.get(name)
            prefix = f"views.{name}"
            if not isinstance(view, dict):
                result.errors.append(f"{prefix} must be an object")
                continue
            if view.get("fit") not in {"cover", "contain"}:
                result.errors.append(f"{prefix}.fit must be cover or contain")
            scale = view.get("scale")
            if not is_number(scale) or not 0.5 <= float(scale) <= 4:
                result.errors.append(f"{prefix}.scale must be from 0.5 to 4")
            point = view.get("focalPoint")
            if not isinstance(point, list) or len(point) != 2:
                result.errors.append(f"{prefix}.focalPoint must contain two normalized numbers")
            else:
                for index, value in enumerate(point):
                    validate_unit_interval(value, f"{prefix}.focalPoint[{index}]", result)
            validate_unit_interval(view.get("opacity"), f"{prefix}.opacity", result)
            overlay = view.get("overlay")
            if not isinstance(overlay, dict):
                result.errors.append(f"{prefix}.overlay must be an object")
            else:
                if overlay.get("kind") not in {"solid", "linear", "radial"}:
                    result.errors.append(f"{prefix}.overlay.kind must be solid, linear, or radial")
                validate_color(overlay.get("color"), f"{prefix}.overlay.color", result)
                validate_unit_interval(overlay.get("strength"), f"{prefix}.overlay.strength", result)
                anchor = overlay.get("anchor")
                if not isinstance(anchor, list) or len(anchor) != 2:
                    result.errors.append(f"{prefix}.overlay.anchor must contain two numbers")
                else:
                    for index, value in enumerate(anchor):
                        validate_unit_interval(value, f"{prefix}.overlay.anchor[{index}]", result)
            preserved = view.get("preserveEdges")
            if preserved is not None:
                if not isinstance(preserved, dict):
                    result.errors.append(f"{prefix}.preserveEdges must be an object")
                else:
                    for edge in ("top", "right", "bottom", "left"):
                        validate_unit_interval(
                            preserved.get(edge),
                            f"{prefix}.preserveEdges.{edge}",
                            result,
                        )

    components = theme.get("components")
    if not isinstance(components, dict):
        result.errors.append("components must be an object")
    else:
        for name in ("chrome", "sidebar", "cards", "composer"):
            if not isinstance(components.get(name), dict):
                result.errors.append(f"components.{name} must be an object")
        chrome = components.get("chrome")
        if isinstance(chrome, dict):
            for key in ("background", "title", "border"):
                validate_component_color(chrome, key, "components.chrome", result)
        sidebar = components.get("sidebar")
        if isinstance(sidebar, dict):
            for key in ("background", "text", "active", "newTask"):
                validate_component_color(sidebar, key, "components.sidebar", result)
        for name in ("cards", "composer"):
            component = components.get(name)
            if isinstance(component, dict):
                validate_unit_interval(component.get("opacity"), f"components.{name}.opacity", result)
                for key in ("blur", "radius"):
                    value = component.get(key)
                    if not is_number(value) or not 0 <= float(value) <= 80:
                        result.errors.append(f"components.{name}.{key} must be from 0 to 80")
        cards_component = components.get("cards")
        if isinstance(cards_component, dict):
            for key in ("fill", "title", "subtitle"):
                validate_component_color(cards_component, key, "components.cards", result)
            border = cards_component.get("border")
            if border != "none":
                validate_component_color(cards_component, "border", "components.cards", result)
            require_string(cards_component, "shadow", "components.cards", result)
        composer_component = components.get("composer")
        if isinstance(composer_component, dict):
            for key in ("fill", "text"):
                validate_component_color(composer_component, key, "components.composer", result)
            outer = composer_component.get("outerBackground")
            if outer != "transparent":
                validate_component_color(
                    composer_component,
                    "outerBackground",
                    "components.composer",
                    result,
                )
            require_string(composer_component, "shadow", "components.composer", result)

    content = theme.get("content")
    if not isinstance(content, dict):
        result.errors.append("content must be an object")
    else:
        for key in ("heroTitle", "heroSubtitle", "composerPlaceholder"):
            require_string(content, key, "content", result)
        if isinstance(content.get("heroTitle"), str) and content["heroTitle"].count("{{project}}") != 1:
            result.errors.append("content.heroTitle must contain {{project}} exactly once to preserve the native project button")
        cards = content.get("cards")
        if not isinstance(cards, list) or not 1 <= len(cards) <= 4:
            result.errors.append("content.cards must contain one to four cards")
        else:
            for index, card in enumerate(cards):
                if not isinstance(card, dict):
                    result.errors.append(f"content.cards[{index}] must be an object")
                    continue
                require_string(card, "title", f"content.cards[{index}]", result)
                require_string(card, "subtitle", f"content.cards[{index}]", result)

    decorations = theme.get("decorations")
    if not isinstance(decorations, list):
        result.errors.append("decorations must be an array")
    else:
        if len(decorations) > 24:
            result.errors.append("decorations must contain at most 24 entries")
        for index, item in enumerate(decorations):
            if not isinstance(item, dict) or item.get("kind") not in {"text", "image"}:
                result.errors.append(f"decorations[{index}] must be a text or image object")
                continue
            validate_keys(
                item,
                {"kind", "surface", "position", "opacity", "size", "value", "asset", "color"},
                f"decorations[{index}]",
                result,
            )
            if item.get("kind") == "image":
                resolve_asset(theme_dir, item.get("asset"), f"decorations[{index}].asset", result)
            else:
                require_string(item, "value", f"decorations[{index}]", result)
            position = item.get("position")
            if not isinstance(position, list) or len(position) != 2:
                result.errors.append(f"decorations[{index}].position must contain two numbers")
            else:
                for p_index, value in enumerate(position):
                    validate_unit_interval(value, f"decorations[{index}].position[{p_index}]", result)
            surface = item.get("surface")
            if surface not in {"home", "chat", "all"}:
                result.errors.append(f"decorations[{index}].surface must be home, chat, or all")
            validate_unit_interval(item.get("opacity"), f"decorations[{index}].opacity", result)
            if item.get("kind") == "text":
                validate_color(item.get("color"), f"decorations[{index}].color", result)
            size = item.get("size")
            if not is_number(size) or not 4 <= float(size) <= 160:
                result.errors.append(f"decorations[{index}].size must be from 4 to 160")

    advanced = theme.get("advanced", {})
    if not isinstance(advanced, dict):
        result.errors.append("advanced must be an object")
    else:
        validate_custom_css(theme_dir, theme_id, advanced.get("customCss"), result)

    for key, value in iter_strings(theme):
        for pattern, label in FORBIDDEN_TEXT:
            if pattern.search(value):
                result.errors.append(f"{key} contains prohibited {label}")
        if key.startswith("$.assets") or key.endswith(".asset"):
            if value.startswith(("http://", "https://")):
                result.errors.append(f"{key} must not use a remote asset URL")

    return theme, result


def hex_to_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)


def rgba(value: str, alpha: float) -> str:
    red, green, blue = hex_to_rgb(value)
    return f"rgba({red}, {green}, {blue}, {alpha:.3f})"


def css_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def background_size(view: dict[str, Any]) -> str:
    scale = float(view["scale"])
    fit = view["fit"]
    if abs(scale - 1) < 0.001:
        return fit
    return f"{scale * 100:.1f}% auto"


def position(view: dict[str, Any]) -> str:
    x, y = view["focalPoint"]
    return f"{float(x) * 100:.1f}% {float(y) * 100:.1f}%"


def overlay_css(overlay: dict[str, Any]) -> str:
    color = overlay["color"]
    strength = float(overlay["strength"])
    x, y = overlay["anchor"]
    if overlay["kind"] == "solid":
        return rgba(color, strength)
    if overlay["kind"] == "radial":
        return (
            f"radial-gradient(115% 92% at {float(x) * 100:.1f}% {float(y) * 100:.1f}%, "
            f"{rgba(color, strength)} 0%, {rgba(color, strength * 0.55)} 42%, "
            f"{rgba(color, strength * 0.18)} 68%, transparent 86%)"
        )
    direction = "90deg" if float(x) <= 0.5 else "270deg"
    return (
        f"linear-gradient({direction}, {rgba(color, strength)} 0%, "
        f"{rgba(color, strength * 0.72)} 52%, {rgba(color, strength * 0.26)} 78%, transparent 100%)"
    )


def compile_tokens(theme: dict[str, Any]) -> dict[str, str]:
    native = theme["nativeTheme"]
    views = theme["views"]
    components = theme["components"]
    content = theme["content"]
    accent = native["accent"]
    ink = native["ink"]
    surface = native["surface"]
    title = components["chrome"]["title"]
    card = components["cards"]
    fullscreen = views["fullscreen"]
    banner = views["banner"]
    chat = views["chat"]

    return {
        "--dream-ink": ink,
        "--dream-purple": accent,
        "--dream-violet": components["sidebar"]["newTask"],
        "--dream-pink": components["chrome"]["border"],
        "--dream-page-bg-0": surface,
        "--dream-page-bg-1": components["sidebar"]["background"],
        "--dream-page-glow-a": rgba(accent, 0.28),
        "--dream-page-glow-b": rgba(components["chrome"]["border"], 0.22),
        "--dream-hero-art-size": background_size(banner),
        "--dream-hero-art-position": position(banner),
        "--dream-fullscreen-art-size": background_size(fullscreen),
        "--dream-fullscreen-art-position": position(fullscreen),
        "--dream-polaroid-art-size": background_size(fullscreen),
        "--dream-polaroid-art-position": position(fullscreen),
        "--dream-hero-overlay": overlay_css(banner["overlay"]),
        "--dream-fullscreen-overlay": overlay_css(fullscreen["overlay"]),
        "--dream-fullscreen-wash": rgba(fullscreen["overlay"]["color"], max(0.0, 1 - fullscreen["opacity"])),
        "--dream-hero-title-color": title,
        "--dream-hero-subtitle-color": rgba(title, 0.82),
        "--dream-hero-title-shadow": "0 1px 0 rgba(255, 255, 255, 0.9)",
        "--dream-hero-chip-color": accent,
        "--dream-hero-chip-bg": "rgba(255, 255, 255, 0.58)",
        "--dream-hero-chip-line": rgba(accent, 0.36),
        "--dream-hero-subtitle": css_string(content["heroSubtitle"]),
        "--dream-chat-art-size": background_size(chat),
        "--dream-chat-art-position": position(chat),
        "--dream-chat-art-opacity": f"{float(chat['opacity']):.3f}",
        "--dream-chat-wash": overlay_css(chat["overlay"]),
        "--dream-card-alpha": f"{float(card['opacity']):.3f}",
        "--dream-card-frame": "transparent" if card["border"] == "none" else card["border"],
        "--dream-card-ornament": "transparent",
        "--dream-card-sub-color": card["subtitle"],
        "--dream-card-icon-color": card["title"],
    }


def compile_generated_css(theme: dict[str, Any], asset_map: dict[str, str]) -> str:
    theme_id = theme["id"]
    scope = f"html.dream-theme-{theme_id}"
    components = theme["components"]
    chrome = components["chrome"]
    sidebar = components["sidebar"]
    cards = components["cards"]
    composer = components["composer"]
    lines = [
        "/* Generated by AutoSkin Codex. Edit theme.json, not this file. */",
        f"{scope} {{",
        f"  --autoskin-chrome-bg: {chrome['background']};",
        f"  --autoskin-chrome-title: {chrome['title']};",
        f"  --autoskin-chrome-border: {chrome['border']};",
        f"  --autoskin-sidebar-bg: {sidebar['background']};",
        f"  --autoskin-sidebar-text: {sidebar['text']};",
        f"  --autoskin-sidebar-active: {sidebar['active']};",
        f"  --autoskin-new-task: {sidebar['newTask']};",
        f"  --autoskin-card-fill: {rgba(cards['fill'], float(cards['opacity']))};",
        f"  --autoskin-card-blur: {float(cards['blur']):g}px;",
        f"  --autoskin-card-radius: {float(cards['radius']):g}px;",
        f"  --autoskin-card-shadow: {cards['shadow']};",
        f"  --autoskin-card-title: {cards['title']};",
        f"  --autoskin-card-subtitle: {cards['subtitle']};",
        f"  --autoskin-composer-fill: {rgba(composer['fill'], float(composer['opacity']))};",
        f"  --autoskin-composer-blur: {float(composer['blur']):g}px;",
        f"  --autoskin-composer-radius: {float(composer['radius']):g}px;",
        f"  --autoskin-composer-shadow: {composer['shadow']};",
        f"  --autoskin-composer-outer: {composer['outerBackground']};",
    ]
    for variable in sorted(asset_map):
        lines.append(f"  {variable}: var({variable}-url, none);")
    lines.append("}")
    lines.extend(
        [
            f"{scope} #codex-dream-skin-chrome {{ pointer-events: none; }}",
            f"{scope} .dream-sidebar {{ color: var(--autoskin-sidebar-text); }}",
            f"{scope} .dream-new-task {{ transition: transform .16s ease, box-shadow .16s ease; }}",
            f"{scope} .dream-new-task:hover {{ transform: translateY(-2px); box-shadow: 0 8px 18px rgba(18, 117, 136, .18); }}",
            f"{scope} .dream-composer-surface {{ box-shadow: var(--autoskin-composer-shadow); }}",
            f"{scope} #codex-dream-skin-chrome .dream-brand .dream-note {{ font-size: 0; }}",
            f"{scope} #codex-dream-skin-chrome .dream-brand .dream-note::after {{ content: ''; display: block; width: 32px; height: 32px; background: var(--autoskin-brand-icon) center / contain no-repeat; }}",
            f"{scope} .dream-sidebar button[aria-label^='切换模式']::after,",
            f"{scope} .dream-sidebar button[aria-label^='Switch mode']::after {{ content: ''; display: block !important; position: absolute !important; inset: 50% auto auto 100% !important; width: 18px; height: 18px; margin: -9px 0 0 4px !important; border-radius: 0 !important; pointer-events: none; background: var(--autoskin-brand-icon) center / contain no-repeat; }}",
            f"{scope} .dream-home .dream-suggestions button {{ border: 0 !important; color: var(--autoskin-card-title) !important; background: var(--autoskin-card-fill) !important; box-shadow: var(--autoskin-card-shadow) !important; -webkit-backdrop-filter: blur(var(--autoskin-card-blur)); backdrop-filter: blur(var(--autoskin-card-blur)); border-radius: var(--autoskin-card-radius) !important; }}",
            f"{scope} .dream-home .dream-suggestions button::before, {scope} .dream-home .dream-suggestions button::after {{ content: none !important; display: none !important; }}",
            f"{scope} .dream-home .dream-suggestions button > span:first-child > span:first-child svg {{ display: none !important; }}",
            f"{scope} .dream-home .dream-suggestions button > span:first-child > span:first-child::after {{ -webkit-mask: none !important; mask: none !important; background: var(--autoskin-card-image) center / contain no-repeat !important; }}",
        ]
    )
    for index in range(1, 5):
        lines.append(
            f"{scope} .dream-home .dream-suggestions [class~='grid'] > :nth-child({index}) button "
            f"{{ --autoskin-card-image: var(--autoskin-card-icon-{index}); }}"
        )
    advanced = theme.get("advanced", {})
    custom = advanced.get("customCss")
    if custom:
        lines.append(f"/* Custom source: {custom} (copied separately during package build). */")
    return "\n".join(lines) + "\n"


def asset_map_for(theme: dict[str, Any]) -> dict[str, str]:
    assets = theme["assets"]
    result: dict[str, str] = {}
    if assets.get("brandIcon"):
        result["--autoskin-brand-icon"] = assets["brandIcon"]
    for index, asset in enumerate(assets.get("cardIcons", []), start=1):
        if asset:
            result[f"--autoskin-card-icon-{index}"] = asset
    for index, decoration in enumerate(theme.get("decorations", []), start=1):
        if decoration.get("kind") == "image" and decoration.get("asset"):
            result[f"--autoskin-decoration-{index}"] = decoration["asset"]
    return result


def compile_runtime_asset_css(
    theme_dir: Path,
    theme_id: str,
    asset_map: dict[str, str],
) -> str:
    """Build the disposable compatibility layer required by the v1 runtime.

    Source themes and generated.css keep ordinary relative asset paths. The
    current safe runtime injects extra.css as a style element, so only this
    disposable runtime bundle receives data URLs.
    """
    if not asset_map:
        return ""
    scope = f"html.dream-theme-{theme_id}"
    lines = [
        "/* Generated runtime asset bridge. Do not hand-edit or commit as source CSS. */",
        f"{scope} {{",
    ]
    for variable, relative in sorted(asset_map.items()):
        source = theme_dir / relative
        payload = base64.b64encode(source.read_bytes()).decode("ascii")
        mime = ASSET_MIME[source.suffix.lower()]
        lines.append(f'  {variable}-url: url("data:{mime};base64,{payload}");')
    lines.append("}")
    return "\n".join(lines) + "\n"


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_theme(theme_dir: Path) -> tuple[Path, dict[str, Any]]:
    theme, result = validate_theme(theme_dir)
    result.require_ok()
    theme_id = theme["id"]
    build_parent = theme_dir / ".build"
    next_dir = build_parent / f".{theme_id}.next"
    output_dir = build_parent / theme_id
    if next_dir.exists():
        shutil.rmtree(next_dir)
    next_dir.mkdir(parents=True)

    shutil.copytree(theme_dir / "assets", next_dir / "assets")
    write_json(next_dir / "source-theme.json", theme)
    write_json(next_dir / "native-theme.json", theme["nativeTheme"])

    tokens = compile_tokens(theme)
    asset_map = asset_map_for(theme)
    cards = theme["content"]["cards"]
    runtime_manifest = {
        "name": theme_id,
        "order": 100,
        "default": True,
        "schemaVersion": 2,
        "runtimeAdapter": "codex-autoskin-v1-generated-assets",
        "meta": {
            "button": theme["meta"]["shortName"],
            "brand": theme["meta"]["name"],
            "edition": theme["meta"]["edition"],
            "signature": theme["meta"]["signature"],
        },
        "art": {"home": "art" + Path(theme["assets"]["background"]).suffix.lower()},
        "cards": {
            "subtitles": [card.get("subtitle", "") for card in cards],
            "icons": [None, None, None, None],
            "opacity": theme["components"]["cards"]["opacity"],
        },
        "composer": {"placeholder": theme["content"]["composerPlaceholder"]},
        "content": {
            "heroTitle": theme["content"]["heroTitle"],
            "cardTitles": [card.get("title", "") for card in cards],
        },
        "decorations": [
            {
                **{
                    key: decoration[key]
                    for key in ("kind", "surface", "position", "opacity", "size", "color", "value")
                    if key in decoration
                },
                **(
                    {"assetVar": f"--autoskin-decoration-{index}"}
                    if decoration.get("kind") == "image"
                    else {}
                ),
            }
            for index, decoration in enumerate(theme.get("decorations", []), start=1)
        ],
        "assetMap": asset_map,
        "tokens": tokens,
    }
    if theme["assets"].get("chatBackground") and theme["assets"]["chatBackground"] != theme["assets"]["background"]:
        runtime_manifest["art"]["chat"] = "chat-art" + Path(theme["assets"]["chatBackground"]).suffix.lower()
    write_json(next_dir / "theme.json", runtime_manifest)

    background_source = theme_dir / theme["assets"]["background"]
    shutil.copy2(background_source, next_dir / runtime_manifest["art"]["home"])
    if "chat" in runtime_manifest["art"]:
        shutil.copy2(theme_dir / theme["assets"]["chatBackground"], next_dir / runtime_manifest["art"]["chat"])

    generated_css = compile_generated_css(theme, asset_map)
    (next_dir / "generated.css").write_text(generated_css, encoding="utf-8")
    write_json(next_dir / "asset-map.json", asset_map)

    custom = theme.get("advanced", {}).get("customCss")
    runtime_css = generated_css + "\n" + compile_runtime_asset_css(theme_dir, theme_id, asset_map)
    if custom:
        shutil.copy2(theme_dir / custom, next_dir / "custom.css")
        runtime_css += "\n/* Validated custom theme CSS. */\n"
        runtime_css += (theme_dir / custom).read_text(encoding="utf-8").rstrip() + "\n"
    (next_dir / "extra.css").write_text(runtime_css, encoding="utf-8")

    files = {}
    for path in sorted(next_dir.rglob("*")):
        if path.is_file():
            files[str(path.relative_to(next_dir))] = hash_file(path)
    report = {
        "theme": theme_id,
        "schemaVersion": 2,
        "builder": "autoskin-codex/1",
        "warnings": result.warnings,
        "files": files,
    }
    write_json(next_dir / "build-report.json", report)

    build_parent.mkdir(parents=True, exist_ok=True)
    backup = build_parent / f".{theme_id}.previous"
    if backup.exists():
        shutil.rmtree(backup)
    if output_dir.exists():
        output_dir.rename(backup)
    next_dir.rename(output_dir)
    if backup.exists():
        shutil.rmtree(backup)
    return output_dir, report
