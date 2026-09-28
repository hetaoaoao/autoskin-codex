# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

AutoSkin Codex 是一个独立的 macOS 菜单栏 App（AutoSkin.app），负责为 Codex／ChatGPT 桌面端安装、切换、暂停、恢复和验证自定义皮肤。`skill/` 目录是可选的 Agent 适配层（自然语言主题制作与跨平台脚本工具箱），不是产品本体。

硬性安全边界（所有改动必须遵守）：
- 永不修改、替换、重签名或取得官方 Codex／ChatGPT App bundle 或 `app.asar` 的所有权。
- 运行时只通过本机回环 CDP 端口注入主 renderer（`app://-/index.html`），辅助 renderer（如头像浮层）保持透明不换肤。
- 拒绝远程图片 URL、`data:` 图片、手写 Base64 素材、目录穿越和未限定作用域的自定义 CSS。
- 私人主题保存在可持久化的 `themes-private/`，升级／修复时不得删除该目录或用删除运行时目录的方式更新主题。

## 常用命令

### 构建 / 安装 App

```bash
bash scripts/build-macos-app.sh        # 产出 ad-hoc 签名的 .build/AutoSkin.app 并校验签名与内置主题
bash scripts/install-macos-app.sh      # 安装到 ~/Applications
open "$HOME/Applications/AutoSkin.app"
```

### 测试

```bash
# 主题 schema-v2 校验、构建与打包的回归测试（Python unittest）
python3 skill/scripts/tests/test_theme_core.py

# macOS 运行时脚本回归（bash 语法、注入器、打包完整性等）
bash skill/scripts/tests/test-runtime-macos.sh

# App bundle 结构与菜单动作回归（内部会真正执行一次 build）
bash app/macos/tests/test-app-bundle.sh
```

运行单个 Python 测试：

```bash
cd skill/scripts && python3 -m unittest tests.test_theme_core.ThemeValidationTests.<test_name>
```

### 主题工具链（skill/scripts/theme_tool.py）

```bash
python3 skill/scripts/theme_tool.py init <theme-id> --image <绝对路径> --output <绝对路径>
python3 skill/scripts/theme_tool.py clone-example --output <绝对路径>
python3 skill/scripts/theme_tool.py validate <theme-dir>
python3 skill/scripts/theme_tool.py build <theme-dir>
python3 skill/scripts/theme_tool.py preview <theme-dir> --open        # 或 --screenshot <png>
python3 skill/scripts/theme_tool.py preview-matrix <theme-dir> --open
python3 skill/scripts/theme_tool.py package <theme-dir> --output <zip>
```

### 运行时生命周期（macOS）

```bash
bash skill/scripts/autoskin-macos.sh doctor      # 检查运行时与兼容状态
bash skill/scripts/autoskin-macos.sh install --no-start
python3 skill/scripts/install_theme.py <theme-dir> --apply
bash skill/scripts/autoskin-macos.sh verify
bash skill/scripts/autoskin-macos.sh restore     # 移除实时注入但保留运行时
bash skill/scripts/autoskin-macos.sh uninstall --yes
```

### 真实 UI 回归审计

```bash
node skill/scripts/live-ui-audit.mjs --port 9335
```

审计会临时覆盖 4 种视口（1708×977 / 1180×820 / 900×760 / 720×700），结束后恢复原布局。发布前应在 Work 首页、Chat 首页、有内容的会话、Settings、Plugins、Sites、Scheduled 各运行一次。

## 架构

### App 优先、Skill 为适配层

- `app/macos/AutoSkinApp.swift`（由 `scripts/build-macos-app.sh` 用 `xcrun swiftc` 编译）：原生菜单栏控制器，枚举已安装主题、切换、暂停/恢复、打开主题目录。菜单动作通过 `app/macos/autoskin-app-command.sh` 落到同一套运行时 CLI。
- App bundle 把 `skill/` 下的 `scripts/ assets/ styles/ themes/ examples/` 作为 `AutoSkinRuntime` 资源打包（见 build 脚本中的 ditto 循环）。
- 首次启动时 App 自动检测 Codex、比对 bundle 内运行时版本与已安装版本、创建状态目录、安装内置 Chiikawa Summer 示例并自动 apply／修复。

### 状态布局（包体外，可持久化）

```text
~/Library/Application Support/CodexAutoSkin/
├── runtime/            # 已安装的 attributed safe renderer runtime
└── themes-private/     # 私人已安装主题（升级时必须保留）

~/Library/Application Support/AutoSkinCodex/
└── snapshots/          # 安装/恢复快照
```

Windows 等价目录在 `%LOCALAPPDATA%\CodexAutoSkin`。检测到旧 `CodexDreamSkin` 目录时只复制识别的状态，旧目录原样保留。

### DOM 适配层（关键设计）

`skill/assets/renderer-inject.js` 使用语义化、带置信度评分的 DOM 适配器：根据角色、可访问性属性、可见性、几何关系和多组兼容信号发现侧栏、主界面、建议卡、输入框等区域，给 live DOM 打上稳定的 `dream-*` 标记。主题 CSS 与验证只依赖这些 AutoSkin 自生成的标记，不依赖 Codex 构建期 class 名。Mutation Observer 在导航或界面更新后重新发现；置信度低于阈值视为 `stale` 并自动恢复，不会静默套错界面。Codex 更新后的修复手段是重装运行时（兼容层），不是重做主题。

### 主题数据流

`theme.json`（schema v2，契约见 `skill/references/theme-schema.md` 与 `theme.schema.json`）+ 原始素材 → `theme_tool.py` 确定性构建到 `.build/<theme-id>/` → 预览矩阵确认 → 打包 ZIP → `install_theme.py` 快照优先安装。`.build/` 是可丢弃产物：改主题要改 `theme.json` 或原始素材后重新构建，不要反向编辑生成的 CSS。全屏首页、顶部 Banner、新建对话背景是三个相互独立的配置面，预览必须逐面验证。

### 关键文档（改动前应先读对应文件）

- `skill/references/theme-schema.md` + `theme.schema.json`：字段语义与 schema v2 契约。
- `skill/references/authoring-and-qa.md`：裁切、透明度、素材与 UI 验收规则。
- `skill/references/runtime-install.md`：安装事务、失败恢复与兼容流程。
- `skill/references/provenance.md`：上游归属（运行时思路来自 `Finderchangchang/codex-autoskin`，保留其 MIT 许可）与复用边界。
- `docs/app-architecture.md`：App-first 架构说明。
