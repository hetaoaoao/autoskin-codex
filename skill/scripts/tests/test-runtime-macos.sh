#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NODE_BIN="${NODE_BIN:-$(command -v node)}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-autoskin-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  echo "macOS test failed: $*" >&2
  exit 1
}

POOL_ART="$ROOT/examples/chiikawa-summer/assets/pool-background.png"
[ -f "$POOL_ART" ] || fail "bundled Chiikawa example art is missing"

echo "Checking shell and JavaScript syntax..."
while IFS= read -r script; do
  /bin/bash -n "$script"
done < <(find "$ROOT/scripts" -type f -name '*.sh' -print | sort)
while IFS= read -r command_file; do
  /bin/bash -n "$command_file"
  [ -x "$command_file" ] || fail "Finder entry point is not executable: $command_file"
done < <(find "$ROOT" -maxdepth 1 -type f -name '*.command' -print | sort)
while IFS= read -r module; do
  "$NODE_BIN" --check "$module"
done < <(find "$ROOT/scripts" -type f -name '*.mjs' -print | sort)
"$NODE_BIN" -e '
  const fs = require("fs");
  const path = require("path");
  const files = [
    ...fs.readdirSync(process.argv[1]).filter((name) => name.endsWith(".command")).map((name) => path.join(process.argv[1], name)),
    ...fs.readdirSync(path.join(process.argv[1], "scripts")).filter((name) => name.endsWith(".sh")).map((name) => path.join(process.argv[1], "scripts", name)),
  ];
  const unsafe = [];
  for (const file of files) {
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
    lines.forEach((line, index) => {
      if (/\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]/.test(line)) unsafe.push(`${file}:${index + 1}: ${line.trim()}`);
    });
  }
  if (unsafe.length) throw new Error(`brace shell variables before non-ASCII text:\n${unsafe.join("\n")}`);
' "$ROOT"

echo "Checking semantic GUI adapter boundaries..."
for marker in dream-sidebar dream-main-surface dream-composer-surface dream-suggestions dream-hero-source; do
  grep -q "$marker" "$ROOT/assets/renderer-inject.js" || fail "semantic adapter marker is missing: $marker"
done
if grep -Eq 'aside\.app-shell-left-panel|main\.main-surface|group\\/home-suggestions' \
  "$ROOT/styles/dream/style.css" "$ROOT/scripts/theme_core.py"; then
  fail "core theme CSS still depends on Codex build-time DOM classes"
fi
grep -q 'adapter.confidence >= 0.65' "$ROOT/scripts/injector.mjs" || \
  fail "renderer verification does not enforce adapter confidence"
grep -q 'composerLooksLocal' "$ROOT/scripts/injector.mjs" || \
  fail "renderer verification accepts a whole-page composer marker"
grep -q 'candidate.classList.remove("dream-composer-surface")' "$ROOT/assets/renderer-inject.js" || \
  fail "semantic adapter does not clear its previous composer paint before rescoring"
grep -q 'surfaceKind === "utility"' "$ROOT/assets/renderer-inject.js" || \
  fail "semantic adapter does not distinguish utility pages from conversations"
grep -q 'sidebar?.parentElement?.children' "$ROOT/assets/renderer-inject.js" || \
  fail "semantic adapter cannot resolve the classless Settings content pane"
grep -q 'dream-sidebar::before' "$ROOT/styles/dream/style.css" || \
  fail "history column is not rendered as a complete themed surface"
grep -q 'isolation: isolate' "$ROOT/styles/dream/style.css" || \
  fail "conversation artwork is not isolated behind native message content"
if [ "$(grep -c 'z-index: -1' "$ROOT/styles/dream/style.css")" -lt 2 ]; then
  fail "conversation artwork or wash can still cover native message content"
fi
grep -q 'noHomeComposerOverlap' "$ROOT/scripts/live-ui-audit.mjs" || \
  fail "live UI audit does not check home/composer overlap"
grep -q 'sidebarHit' "$ROOT/scripts/live-ui-audit.mjs" || \
  fail "live UI audit does not hit-test the themed history column"
grep -q 'homeModeToggleHit' "$ROOT/scripts/live-ui-audit.mjs" || \
  fail "live UI audit does not hit-test the Chat/Work mode toggle"
if grep -q 'dream-main-surface > \*' "$ROOT/styles/dream/style.css"; then
  fail "theme CSS overrides every main child z-index and can block titlebar controls"
fi
grep -q 'const localSurface' "$ROOT/assets/renderer-inject.js" || \
  fail "composer resolver can still promote a whole-page painted ancestor"
grep -q 'remainingPercent' "$ROOT/assets/renderer-inject.js" || \
  fail "usage gauge does not consume Codex remaining quota semantically"
grep -q 'usageOrb' "$ROOT/scripts/live-ui-audit.mjs" || \
  fail "live UI audit does not verify the usage orb"
grep -q 'dream-usage-orb' "$ROOT/assets/renderer-inject.js" || \
  fail "weekly usage is not rendered as a composer orb"
grep -q 'dream-usage-orb-fill' "$ROOT/assets/renderer-inject.js" || \
  fail "weekly usage heart has no liquid fill element"
grep -q 'removeAttribute("title")' "$ROOT/assets/renderer-inject.js" || \
  fail "usage heart can still show a duplicate native tooltip"
grep -q 'setAttribute("role", "progressbar")' "$ROOT/assets/renderer-inject.js" || \
  fail "usage quota does not expose accessible progress semantics"
grep -q 'getQueryData(\["rate-limit-status"\])' "$ROOT/assets/renderer-inject.js" || \
  fail "usage orb does not read Codex rate-limit reset data"

CHROME_BIN="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ -x "$CHROME_BIN" ]; then
  echo "Checking renderer discovery and observer stability in isolated Chrome..."
  CHROME_BIN="$CHROME_BIN" "$NODE_BIN" "$ROOT/scripts/tests/test-renderer-adapter.mjs"
else
  echo "Skipping browser adapter tests (set CHROME_BIN to run them)."
fi

echo "Checking that the public runtime has no bundled fallback themes..."
if "$NODE_BIN" "$ROOT/scripts/injector.mjs" --themes >"$TMP_ROOT/themes.json" 2>"$TMP_ROOT/themes.error"; then
  fail "public runtime unexpectedly discovered a bundled fallback theme"
fi
grep -q "No valid themes found" "$TMP_ROOT/themes.error" || fail "empty-theme error was not explicit"

echo "Checking appearance backup/restore without bootstrap color changes..."
CONFIG_PATH="$TMP_ROOT/config.toml"
BACKUP_PATH="$TMP_ROOT/config.backup.toml"
ORIGINAL_PATH="$TMP_ROOT/config.original.toml"
printf '%s\n' \
  'model = "gpt-5"' \
  '' \
  '[desktop]' \
  'appearanceTheme = "dark"' \
  'appearanceLightCodeThemeId = "solarized"' \
  'appearanceLightChromeTheme = { accent = "#123456" }' \
  'notifications = true' >"$CONFIG_PATH"
cp "$CONFIG_PATH" "$ORIGINAL_PATH"
"$NODE_BIN" "$ROOT/scripts/configure-base-theme.mjs" \
  --config "$CONFIG_PATH" --backup "$BACKUP_PATH" --platform darwin >/dev/null
cp "$CONFIG_PATH" "$TMP_ROOT/config.once.toml"
"$NODE_BIN" "$ROOT/scripts/configure-base-theme.mjs" \
  --config "$CONFIG_PATH" --backup "$BACKUP_PATH" --platform darwin >/dev/null
cmp "$CONFIG_PATH" "$ORIGINAL_PATH" || fail "runtime bootstrap changed official appearance colors"
cmp "$CONFIG_PATH" "$TMP_ROOT/config.once.toml" || fail "appearance backup is not idempotent"
"$NODE_BIN" "$ROOT/scripts/configure-base-theme.mjs" \
  --config "$CONFIG_PATH" --backup "$BACKUP_PATH" --restore >/dev/null
cmp "$CONFIG_PATH" "$ORIGINAL_PATH" || fail "base colors were not restored exactly"

echo "Checking stable runtime synchronization..."
RUNTIME_ROOT="$TMP_ROOT/runtime"
"$NODE_BIN" "$ROOT/scripts/sync-macos-runtime.mjs" \
  --source "$ROOT" --destination "$RUNTIME_ROOT" >/dev/null
for entry in scripts assets styles themes .runtime.json; do
  [ -e "$RUNTIME_ROOT/$entry" ] || fail "runtime is missing $entry"
done
[ -L "$RUNTIME_ROOT/themes-private" ] || fail "runtime private themes are not linked to durable storage"
[ -x "$RUNTIME_ROOT/scripts/autoskin-macos.sh" ] || fail "runtime scripts lost executable permissions"
"$NODE_BIN" "$ROOT/scripts/sync-macos-runtime.mjs" \
  --source "$ROOT" --destination "$RUNTIME_ROOT" >/dev/null
if "$NODE_BIN" "$RUNTIME_ROOT/scripts/injector.mjs" --themes >"$TMP_ROOT/runtime-empty.json" 2>"$TMP_ROOT/runtime-empty.error"; then
  fail "runtime synchronization unexpectedly added a fallback theme"
fi
grep -q "No valid themes found" "$TMP_ROOT/runtime-empty.error" || fail "synchronized runtime did not report an empty theme set"

echo "Checking one-image theme generation..."
"$NODE_BIN" "$ROOT/scripts/generate-quick-theme-macos.mjs" \
  --image "$POOL_ART" \
  --name ci-quick-theme \
  --themes-root "$RUNTIME_ROOT/themes-private" \
  --reserved-root "$RUNTIME_ROOT/themes" >"$TMP_ROOT/quick-theme-result.json"
"$NODE_BIN" -e '
  const fs = require("fs");
  const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (!result.ok || result.route !== "light") throw new Error("unexpected generated theme report");
  if (manifest.notes.generator !== "quick-theme") throw new Error("generator marker is missing");
  if (Object.keys(manifest.tokens).length !== 28) throw new Error("generated theme must contain 28 tokens");
' "$TMP_ROOT/quick-theme-result.json" "$TMP_ROOT/themes-private/ci-quick-theme/theme.json"
"$NODE_BIN" "$ROOT/scripts/generate-quick-theme-macos.mjs" \
  --image "$POOL_ART" \
  --name ci-quick-theme \
  --themes-root "$RUNTIME_ROOT/themes-private" \
  --reserved-root "$RUNTIME_ROOT/themes" >/dev/null
"$NODE_BIN" "$ROOT/scripts/sync-macos-runtime.mjs" \
  --source "$ROOT" --destination "$RUNTIME_ROOT" >/dev/null
[ -f "$TMP_ROOT/themes-private/ci-quick-theme/theme.json" ] || fail "runtime refresh deleted a generated theme"
"$NODE_BIN" "$RUNTIME_ROOT/scripts/injector.mjs" --themes >"$TMP_ROOT/runtime-themes.json"
"$NODE_BIN" -e '
  const report = require(process.argv[1]);
  if (!report.themes.some((theme) => theme.name === "ci-quick-theme" && theme.source === "themes-private")) {
    throw new Error("generated private theme was not discovered");
  }
' "$TMP_ROOT/runtime-themes.json"
mkdir -p "$RUNTIME_ROOT/themes/reserved-theme"
printf '{}\n' >"$RUNTIME_ROOT/themes/reserved-theme/theme.json"
if "$NODE_BIN" "$ROOT/scripts/generate-quick-theme-macos.mjs" \
  --image "$POOL_ART" \
  --name reserved-theme \
  --themes-root "$RUNTIME_ROOT/themes-private" \
  --reserved-root "$RUNTIME_ROOT/themes" >/dev/null 2>&1; then
  fail "quick-theme overwrote a reserved runtime theme"
fi
/usr/bin/sips -s format jpeg "$POOL_ART" --out "$TMP_ROOT/泳池.jpg" >/dev/null
"$NODE_BIN" "$ROOT/scripts/generate-quick-theme-macos.mjs" \
  --image "$TMP_ROOT/泳池.jpg" \
  --themes-root "$RUNTIME_ROOT/themes-private" \
  --reserved-root "$RUNTIME_ROOT/themes" >"$TMP_ROOT/auto-name-result.json"
"$NODE_BIN" -e '
  const fs = require("fs");
  const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const manifest = JSON.parse(fs.readFileSync(`${result.themeDirectory}/theme.json`, "utf8"));
  if (!/^my-theme-[a-f0-9]{6}$/.test(result.name)) throw new Error("non-Latin filename fallback is invalid");
  if (manifest.art.home !== "art.jpg" || result.route !== "light") throw new Error("JPG light-route generation failed");
' "$TMP_ROOT/auto-name-result.json"
mkdir -p "$TMP_ROOT/themes-private/manual-theme"
printf '{}\n' >"$TMP_ROOT/themes-private/manual-theme/theme.json"
if "$NODE_BIN" "$ROOT/scripts/generate-quick-theme-macos.mjs" \
  --image "$POOL_ART" \
  --name manual-theme \
  --themes-root "$RUNTIME_ROOT/themes-private" \
  --reserved-root "$RUNTIME_ROOT/themes" >/dev/null 2>&1; then
  fail "quick-theme overwrote a manually-authored theme"
fi

echo "Checking LaunchAgent generation..."
PLIST_PATH="$TMP_ROOT/com.codex-autoskin.watcher.plist"
"$NODE_BIN" "$ROOT/scripts/macos-launch-agent.mjs" \
  --output "$PLIST_PATH" \
  --watcher "$RUNTIME_ROOT/scripts/watch-dream-skin.sh" \
  --node "$NODE_BIN" \
  --app "$TMP_ROOT/Fake Codex.app" \
  --port 19335 \
  --stdout "$TMP_ROOT/watcher.log" \
  --stderr "$TMP_ROOT/watcher-error.log" >/dev/null
/usr/bin/plutil -lint "$PLIST_PATH" >/dev/null
/usr/bin/plutil -p "$PLIST_PATH" | grep -q -- '--ignore-existing-app' || fail "LaunchAgent safety flag is missing"

echo "Checking remembered port and app discovery..."
TEST_HOME="$TMP_ROOT/home"
FAKE_APP="$TMP_ROOT/Fake Codex.app"
mkdir -p "$TEST_HOME/Library/Application Support/CodexDreamSkin" "$FAKE_APP/Contents/MacOS"
/usr/bin/plutil -create xml1 "$FAKE_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string com.openai.codex "$FAKE_APP/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string FakeCodex "$FAKE_APP/Contents/Info.plist"
: >"$FAKE_APP/Contents/MacOS/FakeCodex"
chmod +x "$FAKE_APP/Contents/MacOS/FakeCodex"
"$NODE_BIN" -e '
  const fs = require("fs");
  fs.writeFileSync(process.argv[1], JSON.stringify({
    port: 19335, appPath: process.argv[2], nodePath: process.execPath
  }));
' "$TEST_HOME/Library/Application Support/CodexDreamSkin/install-state.json" "$FAKE_APP"
HOME="$TEST_HOME" /bin/bash -c '
  set -euo pipefail
  . "$1/scripts/lib/mac-common.sh"
  [ "$(dream_installed_port)" = "19335" ]
  [ -f "$HOME/Library/Application Support/CodexAutoSkin/install-state.json" ]
  [ -f "$HOME/Library/Application Support/CodexAutoSkin/.migrated-from-CodexDreamSkin" ]
  [ -f "$HOME/Library/Application Support/CodexDreamSkin/install-state.json" ]
  dream_resolve_app ""
  [ "$APP_BUNDLE" = "$2" ]
' test "$ROOT" "$FAKE_APP"

echo "Checking isolated one-command installation..."
mkdir -p "$TEST_HOME/.codex"
printf '%s\n' '[desktop]' 'appearanceTheme = "dark"' >"$TEST_HOME/.codex/config.toml"
HOME="$TEST_HOME" bash "$ROOT/scripts/autoskin-macos.sh" install \
  --no-start --no-auto-recover --port 19337 --app "$FAKE_APP" --node "$NODE_BIN" >/dev/null
INSTALLED_ROOT="$TEST_HOME/Library/Application Support/CodexAutoSkin"
[ -x "$INSTALLED_ROOT/runtime/scripts/autoskin-macos.sh" ] || fail "unified installer did not create a stable runtime"
[ -f "$INSTALLED_ROOT/config.before-dream-skin.toml" ] || fail "unified installer did not back up base colors"
[ ! -e "$TEST_HOME/Library/LaunchAgents/com.codex-autoskin.watcher.plist" ] || fail "--no-auto-recover installed a LaunchAgent"
HOME="$TEST_HOME" bash "$ROOT/scripts/autoskin-macos.sh" install \
  --no-auto-recover --port 19337 --app "$FAKE_APP" --node "$NODE_BIN" >"$TMP_ROOT/empty-install.log"
grep -q "no theme is installed yet" "$TMP_ROOT/empty-install.log" || fail "empty runtime install did not stop with guidance"
HOME="$TEST_HOME" /bin/bash -c '
  set -euo pipefail
  . "$1/runtime/scripts/lib/mac-common.sh"
  [ "$(dream_installed_port)" = "19337" ]
' test "$INSTALLED_ROOT"
HOME="$TEST_HOME" "$INSTALLED_ROOT/runtime/scripts/autoskin-macos.sh" quick-theme \
  "$POOL_ART" --name installed-quick-theme --no-apply --node "$NODE_BIN" >/dev/null
[ -f "$INSTALLED_ROOT/themes-private/installed-quick-theme/theme.json" ] || fail "installed quick-theme did not persist its theme"
"$NODE_BIN" "$INSTALLED_ROOT/runtime/scripts/injector.mjs" --themes >"$TMP_ROOT/installed-themes.json"
"$NODE_BIN" -e '
  const report = require(process.argv[1]);
  if (!report.themes.some((theme) => theme.name === "installed-quick-theme")) {
    throw new Error("installed runtime did not discover its generated theme");
  }
' "$TMP_ROOT/installed-themes.json"

echo "Checking repeatable uninstall without a backup..."
rm -f "$INSTALLED_ROOT/config.before-dream-skin.toml"
for _ in 1 2; do
  HOME="$TEST_HOME" bash "$ROOT/scripts/restore-dream-skin.sh" \
    --uninstall --restore-base-theme --port 19337 --node "$NODE_BIN" >/dev/null
done
[ ! -e "$TEST_HOME/Library/Application Support/CodexAutoSkin/runtime" ] || fail "runtime was not removed"
[ ! -e "$TEST_HOME/Library/Application Support/CodexAutoSkin/install-state.json" ] || fail "install state was not removed"

echo "All macOS tests passed."
