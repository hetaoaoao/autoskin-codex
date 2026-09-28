#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOURCE_ROOT="${AUTOSKIN_RESOURCE_ROOT:-$SCRIPT_DIR}"
AUTOSKIN_ROOT="$RESOURCE_ROOT/AutoSkinRuntime"
CLI="$AUTOSKIN_ROOT/scripts/autoskin-macos.sh"
THEME_INSTALLER="$AUTOSKIN_ROOT/scripts/install_theme.py"
STARTER_THEME="$AUTOSKIN_ROOT/examples/chiikawa-summer"
STATE_ROOT="$HOME/Library/Application Support/CodexAutoSkin"
INSTALLED_ROOT="$STATE_ROOT/runtime"
INSTALLED_CLI="$INSTALLED_ROOT/scripts/autoskin-macos.sh"
INSTALLED_MENU="$INSTALLED_ROOT/scripts/autoskin-menubar-macos.sh"
SCREENSHOT_ROOT="$HOME/Library/Application Support/AutoSkinCodex/verification"
APP_STATE_ROOT="$HOME/Library/Application Support/AutoSkinCodex"
APP_INFO="$RESOURCE_ROOT/../Info.plist"

die() {
  echo "AutoSkin.app: $*" >&2
  exit 1
}

require_resources() {
  [ -x "$CLI" ] || die "bundled runtime is missing: $CLI"
  [ -f "$THEME_INSTALLER" ] || die "theme installer is missing: $THEME_INSTALLER"
  [ -f "$STARTER_THEME/theme.json" ] || die "starter theme is missing: $STARTER_THEME"
}

install_skin() {
  require_resources
  bash "$CLI" install --no-start
  /usr/bin/python3 "$THEME_INSTALLER" "$STARTER_THEME" --layout fullscreen
  mkdir -p "$APP_STATE_ROOT"
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO" >"$APP_STATE_ROOT/app-runtime-version"
}

apply_skin() {
  [ -x "$INSTALLED_CLI" ] || die "runtime is not installed; choose Install / Update first"
  bash "$INSTALLED_CLI" start --restart-existing
}

ensure_skin() {
  require_resources
  local bundle_version installed_version=""
  local needs_apply=false
  bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_INFO")"
  [ ! -f "$APP_STATE_ROOT/app-runtime-version" ] || installed_version="$(<"$APP_STATE_ROOT/app-runtime-version")"
  if [ ! -x "$INSTALLED_CLI" ] || [ "$installed_version" != "$bundle_version" ] || \
     [ ! -f "$STATE_ROOT/themes-private/chiikawa-summer/theme.json" ]; then
    install_skin
    needs_apply=true
  fi
  local status
  status="$(bash "$INSTALLED_CLI" status 2>/dev/null || true)"
  if [ "$needs_apply" = true ] || ! printf '%s\n' "$status" | grep -q '^session=active$'; then
    apply_skin
  fi
}

launch_skin() {
  # Opening the app means the user wants the skin: clear the paused marker left
  # by a previous app shutdown, then apply the last selected theme.
  rm -f "$STATE_ROOT/paused"
  ensure_skin
}

shutdown_skin() {
  # Closing the app means the user wants the original skin. The watcher honors
  # the paused marker, so it will not re-inject while the app stays closed.
  [ -x "$INSTALLED_CLI" ] || return 0
  bash "$INSTALLED_CLI" pause
}

list_themes() {
  [ -x "$INSTALLED_CLI" ] || { echo '{"themes":[]}'; return; }
  local install_state="$STATE_ROOT/install-state.json"
  local node_bin
  node_bin="$(/usr/bin/plutil -extract nodePath raw -o - "$install_state" 2>/dev/null || true)"
  [ -x "$node_bin" ] || die "installed Node.js path is unavailable"
  "$node_bin" "$INSTALLED_ROOT/scripts/injector.mjs" --themes 2>/dev/null
}

verify_skin() {
  [ -x "$INSTALLED_CLI" ] || die "runtime is not installed"
  if [ "${1:-}" = "--screenshot" ]; then
    mkdir -p "$SCREENSHOT_ROOT"
    local output="$SCREENSHOT_ROOT/chiikawa-summer.png"
    # Use an OS window capture. Page.captureScreenshot disconnects the live
    # renderer CDP socket in current Codex builds and is therefore unsafe here.
    bash "$INSTALLED_CLI" verify --screenshot "$output"
    echo "screenshot=$output"
  else
    bash "$INSTALLED_CLI" verify
  fi
}

COMMAND="${1:-status}"
[ "$#" -eq 0 ] || shift

case "$COMMAND" in
  install)
    install_skin
    ;;
  apply)
    apply_skin
    ;;
  install-and-apply)
    install_skin
    apply_skin
    verify_skin
    ;;
  ensure)
    ensure_skin
    ;;
  launch)
    launch_skin
    ;;
  shutdown)
    shutdown_skin
    ;;
  themes)
    list_themes
    ;;
  theme)
    [ -n "${1:-}" ] || die "theme id is required"
    [ -x "$INSTALLED_MENU" ] || die "runtime is not installed"
    bash "$INSTALLED_MENU" theme "$1"
    ;;
  original)
    [ -x "$INSTALLED_CLI" ] || die "runtime is not installed"
    bash "$INSTALLED_CLI" pause
    ;;
  verify)
    verify_skin "$@"
    ;;
  status|pause|resume)
    if [ -x "$INSTALLED_CLI" ]; then
      bash "$INSTALLED_CLI" "$COMMAND"
    elif [ "$COMMAND" = status ]; then
      echo "session=not-installed"
      echo "codex=false"
      echo "theme="
      echo "layout="
      echo "adapter="
      echo "port=9335"
    else
      die "runtime is not installed"
    fi
    ;;
  layout)
    case "${1:-}" in
      fullscreen|banner) ;;
      *) die "layout must be fullscreen or banner" ;;
    esac
    [ -x "$INSTALLED_CLI" ] || die "runtime is not installed"
    bash "$INSTALLED_CLI" theme "$1"
    ;;
  doctor)
    require_resources
    bash "$CLI" doctor
    ;;
  open-themes)
    # App launch normally prepares this directory through `ensure`; running a
    # lightweight status probe here also covers a direct command invocation.
    bash "$CLI" status >/dev/null 2>&1 || true
    mkdir -p "$STATE_ROOT/themes-private"
    /usr/bin/open "$STATE_ROOT/themes-private"
    ;;
  self-test)
    require_resources
    /usr/bin/python3 "$AUTOSKIN_ROOT/scripts/theme_tool.py" validate "$STARTER_THEME"
    echo "CodexSkin.app resources are valid."
    ;;
  *)
    die "unknown command: $COMMAND"
    ;;
esac
