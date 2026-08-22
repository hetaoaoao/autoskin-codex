# AutoSkin Codex

**A standalone Codex theme manager—from multi-surface previews to reversible installation.**

[中文说明](README.md) · [Preview](#preview) · [Install](#install) ·
[Support](SUPPORT.md) · [Issues](https://github.com/Jiaranbb/autoskin-codex/issues)

AutoSkin Codex is a standalone macOS menu-bar and Windows system-tray app for installing, switching, pausing, recovering,
and verifying Codex desktop themes. It rebuilds the theme schema, preview workflow, and installer
around the safe local renderer-injection approach established by
[`Finderchangchang/codex-autoskin`](https://github.com/Finderchangchang/codex-autoskin).

The `skill/` directory is now an optional agent adapter and cross-platform toolbox, not the product
boundary. `AutoSkin.app` embeds the local runtime and the Chiikawa Summer example, so ordinary use
does not depend on installing a Codex Skill.

It keeps source images as ordinary files, separates official Codex appearance values from runtime
styling, and previews fullscreen home, Banner, and new-chat surfaces independently before touching
the live app. The repository includes a complete **Chiikawa Summer Pool** worked example.

This is the only bundled editable example. The upstream Aurora Veil and Ember Bloom demo themes are
not redistributed. The safe runtime, generator, previewer, and installer remain complete; cloned or
newly generated themes are installed into durable `themes-private/` storage.

## Preview

![Installed Chiikawa Summer Pool theme](docs/images/chiikawa-summer-preview.jpg)

The sidebar labels in this real installed screenshot have been obscured. They are not bundled data.

## Install

### Windows native tray app

Windows users do not run a PowerShell installer. Publish the app, keep `AutoSkin.exe` beside its
`AutoSkinRuntime` directory, and double-click it:

```powershell
dotnet publish app\windows\AutoSkin.Windows.csproj -c Release -r win-x64 --self-contained `
  -p:PublishSingleFile=true -o dist\AutoSkin-win-x64
```

On first launch it validates Codex, Node.js, and Python, self-installs below
`%LOCALAPPDATA%\CodexAutoSkin\app`, installs the replaceable runtime and starter theme, applies
AutoSkin, and registers the installed copy for login. The tray menu matches macOS: Themes,
Original Codex Skin, Open Theme Folder, and Quit AutoSkin. It does not modify `WindowsApps` or
`app.asar`.

First launch also creates an `AutoSkin Codex` Start Menu shortcut so Windows Search can discover the
installed app. Theme metadata from Node is decoded explicitly as UTF-8.

### macOS menu-bar app

Build and install the standalone macOS app:

```bash
bash scripts/build-macos-app.sh
bash scripts/install-macos-app.sh
open "$HOME/Applications/AutoSkin.app"
```

No initialization command is required after first launch. The app detects Codex, the installed
runtime generation, and local themes, installs or updates missing pieces, and applies the skin.
Its menu-bar palette dynamically lists every installed theme and layout. The status row also shows
DOM-adapter confidence.

After a Codex GUI update, the runtime re-discovers the visible DOM using semantic roles,
accessibility attributes, geometry, and multiple compatibility signals. Core styles target stable
AutoSkin markers instead of Codex build-time class names. Low-confidence matches enter `stale`
recovery rather than silently styling the wrong surface.

For natural-language theme authoring, optionally install the Skill adapter:

```bash
python3 ~/.codex/skills/.system/skill-installer/scripts/install-skill-from-github.py \
  --repo Jiaranbb/autoskin-codex \
  --path skill \
  --name autoskin-codex
```

Open a new Codex task after installation, then ask:

```text
Use autoskin-codex to clone and preview the bundled Chiikawa Summer example. Do not install it
until I approve the fullscreen, Banner, and new-chat previews.
```

## What can be customized

- Official Codex accent, surface, ink, contrast, fonts, and opacity strategy.
- Independent fullscreen, Banner, and new-chat background crops, focal points, opacity, and wash.
- Theme brand icon, title, edition, signature, and chrome colors.
- Sidebar colors, selected rows, and the new-task button.
- Four card icons, glass opacity, blur, radius, shadow, title color, subtitle color, and copy.
- Composer fill, blur, radius, shadow, outer wrapper, text color, and placeholder.
- Non-interactive text or image decorations with per-surface visibility.

## Safety boundary

AutoSkin Codex does not modify, replace, re-sign, or unpack the official Codex/ChatGPT application.
The runtime connects only to a loopback Chromium debugging endpoint. Authored themes reject remote
images, embedded Base64 payloads, path traversal, JavaScript URLs, and unscoped custom CSS.

macOS is locally tested. Windows now uses a native WinForms tray app rather than a PowerShell
installation flow. Python 3.9+ is required; Windows also requires Node.js 22+, while macOS normally
reuses the desktop app's bundled Node.js and does not require Homebrew or SwiftBar.

## Fan Art notice

The bundled example contains independently created, unofficial, non-commercial fan art based on
the Chiikawa IP. Character names, designs, and related rights belong to Nagano and the respective
official rightsholders. These assets are not covered by the MIT code license and may only be used
for personal, non-commercial theme customization and sharing. See
[`skill/examples/chiikawa-summer/ASSET-NOTICE.md`](skill/examples/chiikawa-summer/ASSET-NOTICE.md).

## Related projects

- [ecommerce-helper](https://github.com/Jiaranbb/ecommerce-helper) — a complete e-commerce asset-pack Skill from new-product research and RMB pricing to PDP and social content;
- [report-helper](https://github.com/Jiaranbb/report-helper) — long-form, source-linked research reports and polished PDFs from one request;
- [content-reader](https://github.com/Jiaranbb/content-reader) — agent skills for saving Xiaohongshu, Twitter/X, YouTube, and Bilibili content;
- [xhs-reader](https://github.com/Jiaranbb/xhs-reader) — save Xiaohongshu posts locally without logging in;
- [pdf-reader](https://github.com/Jiaranbb/pdf-reader) — convert PDFs into Markdown with page markers and quality metrics;
- [dreamy-photo](https://github.com/Jiaranbb/dreamy-photo) — dreamy photo editing while preserving real subject details;
- [jiucai-helper](https://github.com/Jiaranbb/jiucai-helper) — a testable personal investment-decision Skill combining method and discipline.

See more original projects on [Jiaranbb's GitHub profile](https://github.com/Jiaranbb?tab=repositories).

## About the author

**Jiaran (Jiaranbb)** — independent developer / AI Builder

I turn workflows I genuinely need into reusable AI tools and Skills.

- Website: [c.aoao.ai](https://c.aoao.ai)
- GitHub: [github.com/Jiaranbb](https://github.com/Jiaranbb)
- X/Twitter: [@_jiaran](https://x.com/_jiaran)
- WeChat: `evadebot`
- WeChat official account: **嘉然学习笔记**
- Support: [SUPPORT.md](SUPPORT.md)
- Project issues: [GitHub Issues](https://github.com/Jiaranbb/autoskin-codex/issues)

## License

Project code is released under the [MIT License](LICENSE). The adapted upstream runtime retains its
original notice in
[`skill/references/upstream-runtime-LICENSE.txt`](skill/references/upstream-runtime-LICENSE.txt).
Fan Art assets follow their separate notice above.
