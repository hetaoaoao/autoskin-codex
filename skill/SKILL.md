---
name: autoskin-codex
description: Optional agent adapter for the standalone AutoSkin app. Create, preview, validate, package, install, switch, repair, or remove custom themes for the Codex desktop app when a user wants natural-language theme authoring or cross-platform automation.
---

# AutoSkin Codex

This Skill is an optional automation adapter, not the AutoSkin product or long-running runtime.
Prefer `AutoSkin.app` for ordinary macOS installation and lifecycle control. Use this adapter to
build themes from semantic data and ordinary asset files. Attribute the runtime approach to
`Finderchangchang/codex-autoskin`; do not patch, replace, or re-sign the official Codex app.

## Workflow

1. Inspect the source image and the live Codex viewport before choosing crop or opacity values.
2. Initialize a theme:

   ```bash
   python3 scripts/theme_tool.py init <theme-id> --image <path> --output <directory>
   ```

   To start from the complete bundled example instead:

   ```bash
   python3 scripts/theme_tool.py clone-example --output <directory>
   ```

3. Edit `<directory>/theme.json`. Read `references/theme-schema.md` for fields and
   `references/authoring-and-qa.md` for crop, transparency, asset, and UI acceptance rules.
4. Validate and build:

   ```bash
   python3 scripts/theme_tool.py validate <directory>
   python3 scripts/theme_tool.py build <directory>
   ```

5. Generate previews before touching the live app:

   ```bash
   python3 scripts/theme_tool.py preview <directory> --open
   python3 scripts/theme_tool.py preview <directory> --screenshot <preview.png>
   python3 scripts/theme_tool.py preview-matrix <directory> --open
   ```

6. Review fullscreen, banner, chat, narrow-width, safe-area, and interaction states. Do not
   install while any preview/live mismatch is unexplained.
7. On Windows, prefer the native `AutoSkin.exe` tray app. Its first launch installs or updates the
   managed runtime, seeds the bundled example, applies the skin, and registers login startup without
   requiring a PowerShell installation command. The tray menu mirrors macOS: Themes, Original Codex
   Skin, Open Theme Folder, and Quit AutoSkin.
8. On the first macOS install, prepare the bundled safe runtime:

   ```bash
   bash scripts/autoskin-macos.sh install --no-start
   ```

   The official app's bundled Node.js is used when available; Homebrew and SwiftBar are not
   required.
9. Run the theme installer only after validation:

   ```bash
   python3 scripts/install_theme.py <directory> --apply
   ```

   Read `references/runtime-install.md` before install, compatibility repair, recovery, or runtime changes.
10. Use the installed runtime for lifecycle actions:

   ```bash
   bash scripts/autoskin-macos.sh status
   bash scripts/autoskin-macos.sh theme <theme-id> fullscreen
   bash scripts/autoskin-macos.sh pause
   bash scripts/autoskin-macos.sh resume
   bash scripts/autoskin-macos.sh verify
   ```

## Rules

- Keep authored images under the theme's `assets/`; manifests and CSS use relative paths.
- Reject `data:` images, Base64 payloads, remote image URLs, path traversal, and unscoped CSS.
- Treat generated `.build/` files as disposable. Change `theme.json` or assets, then rebuild.
- Prefer `nativeTheme` for official Codex colors. Generate CSS only for unsupported surfaces.
- Keep background, card, title bar, sidebar, composer, and decoration settings independent.
- Keep fullscreen, banner, and chat crops independent; never approve one screenshot for all.
- Preserve native controls and pointer behavior. Decorations must never replace fake controls.
- Snapshot current state before install and verify again after launch, restart, pause, and resume.
- Keep private themes outside replaceable runtime directories.

## Resources

- `references/theme-schema.md`: complete schema v2 contract and field semantics.
- `references/theme.schema.json`: editor-readable JSON Schema for `theme.json`.
- `references/authoring-and-qa.md`: image preparation, preview matrix, and session-derived QA.
- `references/runtime-install.md`: deterministic install, failure recovery, and compatibility workflow.
- `references/provenance.md`: upstream attribution and reuse boundary.
- `scripts/theme_tool.py`: initialize, validate, build, preview, and package themes.
- `scripts/install_theme.py`: preflighted, snapshot-first installer for an existing safe runtime.
- `scripts/autoskin-macos.sh`: bundled macOS runtime install, launch, switch, verify,
  pause/resume, live restore, and uninstall entry point. Reinstall the runtime for compatibility repair.
- `../app/windows/`: native Windows tray application and GUI-driven first-run installation. The
  PowerShell scripts remain optional automation and compatibility entry points.
- `scripts/*.ps1`: optional Windows automation for launch, verification, watch, and restoration.
- `scripts/adopt-runtime-macos.py`: migrate an existing runtime to this skill without changing the
  selected theme or official color configuration.
- `assets/renderer-inject.js`, `styles/dream/`, and `themes/`: attributed safe runtime resources.
  The public package intentionally ships no upstream fallback themes; install the worked example or
  a generated theme into durable `themes-private/` storage before starting the runtime.
- `assets/previewer/`: deterministic browser preview shell; never embed source images.
- `assets/theme-template/theme.json`: starter manifest copied by the initializer.
- `examples/chiikawa-summer/`: complete default theme and ordinary image assets.
- `references/upstream-runtime-LICENSE.txt`: retained MIT license for migrated runtime files.
