# Changelog

## Unreleased

- Add a native Windows WinForms tray app with the same Themes / Original Skin / Open Folder / Quit menu as macOS.
- Render the Windows tray menu with Windows 11 spacing, rounded-corner hints, system light/dark colors,
  Segoe UI Variable, modern hover states, separators, arrows, and accent checkmarks.
- Make first-run Windows runtime installation, update, login startup, theme switching, pause, and recovery GUI-driven rather than PowerShell-driven.
- Install the Windows runtime outside the source checkout and preserve `themes-private/` across updates.
- Validate the Store Codex package, Node.js 22+, loopback CDP endpoint, managed paths, and live renderer before reporting success.
- Promote AutoSkin to a standalone macOS menu-bar app with an optional Skill adapter.
- Detect, install, update, and apply the runtime automatically when the app opens.
- Enumerate installed themes in the menu bar and switch themes without a command-line workflow.
- Open the editable theme folder directly from the macOS menu bar.
- Rename the external runtime directory to `CodexAutoSkin` and copy recognized legacy `CodexDreamSkin` state automatically without removing the old directory.
- Add a semantic, confidence-scored DOM adapter so core styling does not depend on Codex build-time classes.
- Surface stale GUI compatibility and recover the renderer automatically after Codex updates.
- Keep Chiikawa Summer Pool as the only bundled editable theme example.
- Remove the upstream Aurora Veil and Ember Bloom demo themes from the public package.
- Allow runtime installation to finish cleanly before a private theme has been installed.
- Detect renderer-level skin loss after a desktop app update and automatically reinject the theme.

## 0.1.0 - 2026-08-11

- Publish the rewritten schema-v2 authoring and preview workflow.
- Add independent fullscreen, Banner, and new-chat preview surfaces.
- Add deterministic validation, build, and theme packaging scripts.
- Add snapshot-first installation and the attributed safe local renderer runtime.
- Add native macOS runtime lifecycle commands and optional menu-bar controller workflow.
- Add the bundled Chiikawa Summer Pool non-commercial Fan Art example.
- Keep runtime bootstrap neutral so it no longer imposes starter pink/purple colors.
- Make Hero/card copy and schema decorations consistent between preview and installed runtime.
- Normalize macOS runtime executable permissions after GitHub archive-based Skill installation.
