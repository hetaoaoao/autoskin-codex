# Runtime and installation contract

## Contents

1. Safety boundary
2. State layout
3. Runtime bootstrap
4. Theme install transaction
5. Commands and states
6. Compatibility

## 1. Safety boundary

Never edit, replace, re-sign, or take ownership of the official Codex/ChatGPT application bundle
or `app.asar`. Preserve login state, tasks, plugins, pets, and the official executable.

Use a loopback CDP port and inject only the main `app://-/index.html` renderer. Auxiliary renderers
such as avatar overlays must remain transparent and unskinned.

## 2. State layout

Keep the attributed safe runtime, installed private themes, and this skill's snapshots separate:

```text
~/Library/Application Support/CodexAutoSkin/
├── runtime/                 # attributed safe renderer runtime
└── themes-private/          # private installed themes

~/Library/Application Support/AutoSkinCodex/
└── snapshots/               # automatic install/recovery snapshots
```

The Windows equivalent lives below `%LOCALAPPDATA%\\CodexAutoSkin`.

The standalone app creates this directory automatically. If the legacy `CodexDreamSkin` directory
exists and `CodexAutoSkin` does not, copy only recognized AutoSkin runtime/theme/state entries and
leave the legacy directory untouched.

The snapshot records source path, schema version, build hashes, installation time, target path,
and native-theme edit plan. Runtime menus enumerate both `runtime/themes/` and
`themes-private/`.

## 3. Runtime bootstrap

The safe renderer runtime is bundled in this skill. Do not require the older
`codex-autoskin` skill as a separate dependency.

On macOS:

```bash
bash scripts/autoskin-macos.sh doctor
bash scripts/autoskin-macos.sh install --no-start
```

The installer resolves the Node.js executable bundled with the official app when possible.
SwiftBar, Homebrew, npm, and a modified application bundle are not required. The optional native
Swift menu-bar controller is a convenience surface over the same runtime state, not an installation
dependency.

When replacing an older installed skill while keeping a live theme:

```bash
python3 scripts/adopt-runtime-macos.py
```

This refreshes only `CodexAutoSkin/runtime/` and its `sourceRoot`. It preserves
`themes-private/`, the selected theme, the paused marker, the LaunchAgent, and `~/.codex/config.toml`.

On Windows, use the native WinForms tray app under `app/windows`. Its first launch performs the
runtime copy, starter-theme build, Store-package validation, login registration, and apply flow.
PowerShell scripts are optional automation interfaces, not the end-user installer. Neither path
patches the installed application.

## 4. Theme install transaction

Perform steps in order:

1. `doctor`: resolve platform, Codex app, config, Node runtime, CDP port, current theme, and current
   runtime generation.
2. `validate`: reject schema, asset, safety, and Base64 in authored JSON/CSS.
3. `build`: create a fresh `.build/<id>` and content hashes.
4. `snapshot`: copy the current theme, runtime state, and official appearance keys to a timestamped
   snapshot. Do not snapshot user conversations.
5. `install`: stage the theme in a sibling temporary directory, then atomically rename it into
   `themes-private/`.
6. `native theme`: update only the official appearance keys represented by `nativeTheme`; retain
   the pre-install values in the snapshot.
7. `apply`: reload the injector or start Codex with CDP only when the user authorized a restart.
8. `verify`: assert selected theme, layout, injection marker, viewport overflow, and core control
   hit testing.
9. On failure, restore the snapshot and report which gate failed.

## 5. Commands and states

Keep the implemented actions distinct:

- `bash scripts/autoskin-macos.sh install`: install or refresh the runtime; it only backs up the current
  official appearance and does not impose starter colors.
- `python3 scripts/install_theme.py <theme> --apply`: validate, build, snapshot, atomically install,
  apply official `nativeTheme` values, select the theme, and verify. Failure restores the prior
  theme and config automatically.
- `theme`: select an already installed theme and layout.
- `pause`: remove live injection while keeping Codex open; the watcher honors a paused marker.
- `resume`: clear the paused marker and restore the selected theme.
- `restore`: remove the current live injection while preserving the installed runtime and themes.
- `uninstall --yes`: remove the runtime and recovery service, then restore the pre-bootstrap
  appearance backup when it exists.

There is no public named-snapshot rollback or single-theme removal command in this release. Do not
claim those commands exist. To remove one private theme, first switch to another theme, then delete
only that resolved folder under `themes-private/` after an explicit user confirmation.

macOS lifecycle commands are exposed by `scripts/autoskin-macos.sh`:

```text
install  start  pause  resume  status  quick-theme  theme
verify   doctor restore uninstall
```

Theme authoring commands are exposed by `scripts/theme_tool.py`:

```text
init  clone-example  validate  build  package  preview  preview-matrix
```

## 6. Compatibility

The generated compatibility manifest targets the attributed
`Finderchangchang/codex-autoskin` runtime while schema v2 remains the authoring source of truth.
The v1 runtime cannot resolve theme-relative images from an injected style element, so the
deterministic build may generate a disposable data-URL bridge in `.build/<id>/extra.css`.
Never hand-author that bridge or copy it back into the source theme.

Selector adapters are versioned. A Codex update that changes DOM markers must fail verification
and enter repair mode instead of silently reporting success.
