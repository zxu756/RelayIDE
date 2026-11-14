# RelayIDE

**[English](README.md)** | **简体中文**

**面向 macOS 的多智能体接力工作台与工作区存储工具**

`RelayIDE` 是一款原生 macOS SwiftUI 桌面工作台、SQLite 工作区存储库以及 CLI/MCP 命令行工具，用于查看隔离 Git 工作树通道、拓扑任务波次、护栏策略与合并产物。**当前状态（M0）：当前版本尚不会启动任何 coding agent；基于 `agent-relay` 的无界面多智能体真实调度排在 M1。**

![RelayIDE 合成演示预览](docs/screenshot-pty-grid-zh.png)
*图 1（`[演示数据]`）：传入 `--demo`（`--export-screenshots`）渲染的四通道合成预览界面。不带 `--demo` 启动 `RelayIDE` 时默认进入空状态：0 条泳道、无终端假输出、无费用数字、无代理地址。*

---

## 当前可用能力（M0）

- **默认空启动的 `中文 / EN` 双语桌面工作台**：不带 `--demo` 启动 macOS 桌面端时，界面保持真实空状态（`0` 条通道、空终端缓冲区、无预算金额、无回环代理地址）。支持通过顶部工具栏 `中文 | EN` 胶囊、菜单快捷键 `⇧⌘L`、`⌘,` 偏好设置弹窗、CLI `--lang zh|en` 或环境变量 `RELAYIDE_LANG=zh|en` 实时切换中英文。仅在显式传入 `--demo`（或点击界面中的「载入演示数据」）时才会在临时目录载入带 `[演示数据]` 徽章的合成样本，绝不污染用户的 `.relayproj` 目录。
- **`.relayproj` SQLite WAL 存储、FTS5 检索与检查点（`RelayWorkspaceStore`）**：持久化保存工作区元数据、通道定义、DAG 拓扑描述、合并报告、护栏审计记录、FTS5 `BM25` 全文检索索引、SHA-256 快照以及 Undo/Redo 历史。所有只读/查询类 CLI 子命令（`status`、`lanes`、`dag-waves`、`audit-plugins`、`export-html`、`mcp --project`）在 `--project <dir>` 不存在时均立即报错并以非 0 状态码退出，不会在后台偷偷创建空目录或数据库。
- **独立基础库组件（已通过单元测试验证）**：
  - `RelayPTYCore`：基于 `posix_openpt(2)` 的本地子进程伪终端会话封装、VT100 / `xterm-256color` / 24 位真彩色屏幕缓冲区、Boyer-Moore 历史检索与 `.cast` v2 编解码。
  - `RelayWorktreeGit`：`git worktree` 创建与工作树差异检查、基于 glob 的文件领地规则匹配（`FileOwnershipRule`）以及 `.relay/LOG.md` 交接日志解析。
  - `RelayOrchestrator`：Kahn 拓扑波次排序与关键路径法（`ES`/`EF`/`LS`/`LF`/松弛时间）计算器。
  - `RelayPluginSDK`：沙箱化 `JavaScriptCore` 策略包与钩子演练台求值器（支持 `audit-plugins` 与 GUI 交互演练）。
  - `RelayWiretapProxy`：独立本地回环 HTTP/1.1 + SSE 流解析器、敏感凭据正则扫描器与内存预算熔断账本。
- **基于 stdio 的 JSON-RPC 2.0 MCP 服务器（共 `2` 个工具）**：`RelayIDE mcp [--project <dir>]` 通过标准输入/输出暴露 **2 个 MCP 工具**：
  1. `relay_semantic_merge`（实验性声明级三路合并；存在冲突或未通过语法校验时返回 `isError: true`）。
  2. `relay_check_ownership`（校验指定相对路径是否符合 `--project` 工作区中对应通道的 `FileOwnershipRule` 领地规则）。
- **实验性声明级三路合并（`semantic-merge`）**：
  - **【实验性】已知会在 Python 代码上损坏输出**（例如多行三引号字符串内出现顶格 `def`/`class` 或复杂缩进控制块时）。M3 之前在交接偏好中默认关闭。
  - 仅在无未决冲突**且**通过宿主机真实语法解析器（`xcrun swiftc -parse`、`python3 -m py_compile` 或 `node --check`）校验时退出码为 `0`；存在冲突标记时退出码为 `1`；语法校验失败时退出码为 `3` 且不在 `stdout` 输出损坏代码。
- **独立双语 HTML 报告导出（`export-html`）**：从已有 `.relayproj` 导出单文件 `中文 | EN` HTML 报告（当数据源来自 `--seed-demo` 时自动标注 `[DEMO]` / `[演示数据]`）。

---

## 后续路线图（M0 尚未实现）

- **M1（真实多智能体接力运行器）**：实现 `RelayIDE run`，在隔离 Git 工作树中无界面启动真实的 `claude`、`codex`、`agy` 与 `vibe` CLI 进程，通过 `.relay/` 文件完成交接，接入实时 PTY 输出流与真实广播命令（当前在 M0 中触发 `⌘⇧B` 会明确提示「广播命令尚未实现（排在 M1）」）。
- **M2（Git 工作树自动合入与验证门禁）**：基于 `git merge-tree` / `git merge-file` 完成跑完后的分支安全合入、构建/测试验证门禁与跨通道越界修改核查。
- **M3（基于真实语法树的语义合并）**：用 `SwiftSyntax` / `tree-sitter` 替代当前基于正则与缩进的声明切分器，通过全量边界用例后再接入合并流水线。
- **M4（实时回环 Wiretap 代理与外发 DLP 网关）**：将 `LoopbackWiretapProxyServer` 注入子智能体进程的 `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` 环境变量，在真实请求链路上执行 HTTP `429` 预算熔断与外发敏感凭据脱敏。

---

## 合成演示界面预览（`--demo`，`[演示数据]` 样本）

以下四张截图均由合成样本数据渲染（`--export-screenshots` 内部启用 `loadDemoWorkspace: true`），窗口顶栏均带有醒目的 `[演示数据]` 标识：

| 2x2 并行终端网格（`[演示数据]`） | 声明级三路合并工作台（`[演示数据]`） |
|---|---|
| ![并行终端网格演示](docs/screenshot-pty-grid-zh.png) | ![三路语义合并演示](docs/screenshot-semantic-merge-zh.png) |

| 等轴测领地围栏地图（`[演示数据]`） | Wiretap 遥测与护栏插件（`[演示数据]`） |
|---|---|
| ![领地围栏地图演示](docs/screenshot-territory-map-zh.png) | ![Wiretap 与插件演示](docs/screenshot-wiretap-guardrails-zh.png) |

---

## 构建、验证与使用说明

> **可执行文件名说明**：从源码通过 SwiftPM 构建生成 `.build/debug/RelayIDE`（运行 `./Scripts/build-app.sh` 生成 `build/RelayIDE.app/Contents/MacOS/RelayIDE`）；通过 Homebrew Cask（`brew install --cask zxu756/tap/relayide`）安装时会将小写命令 `relayide` 软链至 `/opt/homebrew/bin/relayide`。

### 从源码构建与运行验收测试

```bash
swift build
./Scripts/test.sh milestone 0
./Scripts/build-app.sh
```

### 命令行（CLI）与 MCP 服务器用法

```bash
# 1. 初始化空工作区（0 条通道）并查看状态
.build/debug/RelayIDE init --project /tmp/my-empty.relayproj --lang zh
.build/debug/RelayIDE status --project /tmp/my-empty.relayproj --lang zh
.build/debug/RelayIDE lanes --project /tmp/my-empty.relayproj --lang zh

# 2. 显式创建带 [演示数据] 标记的合成演示工作区并导出 HTML 报告
.build/debug/RelayIDE init --project /tmp/demo.relayproj --seed-demo --lang zh
.build/debug/RelayIDE dag-waves --project /tmp/demo.relayproj --lang zh
.build/debug/RelayIDE audit-plugins --project /tmp/demo.relayproj --lang zh
.build/debug/RelayIDE export-html /tmp/demo-dossier.html --project /tmp/demo.relayproj --lang zh

# 3. 实验性三路合并（无冲突且语法合法退出 0；有冲突退出 1；语法损坏退出 3）
.build/debug/RelayIDE semantic-merge base.swift left.swift right.swift --lang zh

# 4. 启动基于 stdio 的 JSON-RPC 2.0 MCP 服务器（共 2 个工具：relay_semantic_merge、relay_check_ownership）
.build/debug/RelayIDE mcp --project /tmp/my-empty.relayproj --lang zh
```

### 桌面工作台启动方式

```bash
# 默认空工作区启动（0 条通道，无合成演示数据）
build/RelayIDE.app/Contents/MacOS/RelayIDE

# 显式载入 [演示数据] 合成预览（支持中英文参数切换）
build/RelayIDE.app/Contents/MacOS/RelayIDE --demo --lang zh
build/RelayIDE.app/Contents/MacOS/RelayIDE --demo --lang en
```

---

## 开源许可

MIT License. Copyright (c) 2026 Xu (`zxu756`).
