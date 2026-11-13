# RelayIDE `v1.1.0`

**[English](README.md)** | **简体中文**

**面向 macOS 的多厂商 AI 编程智能体并行编排工作台、三路 AST 语义合并引擎与 Wiretap 预算熔断网关**

![RelayIDE 并行终端网格与关键路径 DAG](docs/screenshot-pty-grid-zh.png)

`RelayIDE v1.1.0`（纯 Swift 6 编写，包含 11 个隔离的 SwiftPM 核心模块、原生 macOS 桌面工作台与完整 `@Test` 自动化测试套件）是一款专为多智能体协同工程打造的原生 macOS IDE 工作台。它允许开发者在同一代码仓库的隔离 Git 工作树中并行调度 `Claude Code`、`OpenAI Codex`、`Google Antigravity (agy)` 与 `Mistral Vibe`，从根源上消除跨通道文件踩踏、API 预算失控以及传统 Git 行级 diff 产生的虚假合并冲突。

---

## 核心特性 (`v1.1.0`)

- **应用内实时 `中文 / EN` 双语无感切换 (`v1.1.0`)**：顶部工具栏内置包豪斯暖砂纸风格（`#F4F2EC` / `#18181B` / `#C2410C`）`中文 | EN` 分段切换胶囊，支持菜单快捷键 `⇧⌘L`、`⌘,` 偏好设置语言选择、CLI `--lang zh|en`（或环境变量 `RELAYIDE_LANG=zh|en`）覆盖以及 macOS 中文系统语言自动识别；所有工作台面板、命令面板与独立 HTML 审计报告均支持零重启即时切换。
- **四厂商原生 POSIX PTY 终端多路复用网格 (`RelayPTYCore`, `5,836 LOC`)**：直接基于 `posix_openpt(2)` 与 `TIOCSWINSZ` 构建伪终端监管器，内置手写 VT100 / `xterm-256color` / 24 位真彩色终端仿真器、WCAG AA/AAA 对比度自动钳制、Boyer-Moore 回滚搜索、Asciinema v2 `.cast` 录制导出、二叉树分屏网格（`2×2 四象限`、`1+3 主从编排`、`双栏并排`）以及 60 Hz 帧合并渲染。
- **五语言声明级三路 AST 语义合并引擎 (`RelaySemanticMerge`, `7,983 LOC`)**：手写 `Swift`、`Python`、`TypeScript`、`Rust`、`Go` 五语言声明级解析器与三路语义合并器；当多个智能体在同一文件新增不同函数或离散导入时自动无冲突合并（消解传统 `git merge` / `diff3` 假阳性冲突），并内置 Myers $O(ND)$ + Patience Diff、跨文件调用点参数签名漂移检测以及 Robert C. Martin `(Ca, Ce, I, A, D)` 架构耦合度分析。
- **Git 工作树底层管道与实时领地围栏守卫 (`RelayWorktreeGit`, `4,208 LOC`)**：为每条智能体通道创建独立 Git 工作树，包含纯 Swift RFC 1950 zlib 松散对象解析器、基于 `CoreServices` `FSEvents` 的毫秒级领地越界监控与自动回滚、`.relay/LOG.md` SHA-256 交接契约校验以及子智能体递归套娃拦截。
- **本地回环 HTTP/SSE Wiretap 代理与美元预算熔断网关 (`RelayWiretapProxy`, `4,413 LOC`)**：在 `127.0.0.1` 本地解析 Anthropic Messages、OpenAI Responses、Google Gemini 与 Mistral Chat 流式 SSE 令牌，提供保持 JSON 结构完整的外发敏感凭据 DLP 自动脱敏、EWMA 消耗速率预测，以及超额自动返回 HTTP `429` 的通道级美元预算熔断器。
- **SQLite WAL 持久化、FTS5 全文检索与 `JavaScriptCore` 护栏插件 SDK**：`.relayproj` SQLite3 WAL 模式存储（`v1..v4` 模式迁移）、剥离 ANSI 控制码的 FTS5 `BM25` 全文检索、持久化无限 Undo/Redo 与 SHA-256 工作区快照，以及带微秒级延迟剖析（p50/p95/p99）的能力门禁 `JavaScriptCore` 生命周期护栏沙箱。

---

## 模块架构（11 个 SwiftPM 核心库 + 原生桌面端）

| 模块名称 | 代码量 (LOC) | 核心职责 |
|---|---:|---|
| `RelayModels` | `1,640` | 多厂商智能体名册、`RelayLocalizer` 实时双语引擎（`zh-Hans` / `en`）、VT100/真彩色单元格模型、Git 工作树归属规则、AST 语义合并与 Wiretap 领域模型 |
| `RelayPTYCore` | `5,836` | POSIX `posix_openpt` 进程多路复用器、手写 VT100 / `xterm-256color` / TrueColor 仿真器、Boyer-Moore 搜索、`.cast` v2 编解码、二叉分屏树 |
| `RelayWorktreeGit` | `4,208` | Git 工作树生命周期管理、RFC 1950 zlib 松散对象读取器、`FSEvents` 领地围栏监听器、行内差异解析、`.relay` SHA-256 交接契约 |
| `RelaySemanticMerge` | `7,983` | 五语言（`Swift`/`Python`/`TS`/`Rust`/`Go`）声明级 AST 解析器、**三路 AST 语义合并引擎**、Myers/Patience Diff3、跨文件调用签名检查、Martin 耦合度指标 |
| `RelayWorkspaceStore` | `2,939` | `.relayproj` SQLite3 WAL 数据库（`v1..v4`）、FTS5 `BM25` 全文索引库、崩溃安全快照日志、持久化无限撤销/重做栈 |
| `RelayWiretapProxy` | `4,413` | `127.0.0.1` HTTP/1.1 + 四厂商 SSE 流式令牌解析器、外发敏感凭据 DLP 脱敏引擎、EWMA 速率统计、单通道美元预算熔断器 |
| `RelayPluginSDK` | `1,833` | 沙箱化 `JavaScriptCore` 编排护栏宿主、p50/p95/p99 微秒级性能剖析、内置生命周期护栏插件、`.relay-guardrails.json` 策略包编解码 |
| `RelayOrchestrator` | `2,700` | Kahn 拓扑波次调度器、关键路径法（`ES`/`EF`/`LS`/`LF`/松弛时间）分析器、配额故障转移控制器、多智能体演示工程合成器 |
| `RelayCLIAndMCP` | `710` | 无头 `RelayIDE` `v1.1.0` CLI（`init`、`status`、`lanes`、`dag-waves`、`semantic-merge`、`audit-plugins`、`export-html`、`mcp`）、JSON-RPC 2.0 MCP 服务、双语 HTML 审计报告导出 |
| `RelayWorkbenchShell` | `2,420` | 包豪斯暖砂纸（`#F4F2EC`）+ 碳黑内嵌（`#18181B`）主题令牌、双语 `⌘K` 模糊子序列命令面板、双键和弦快捷键冲突检测注册表 |
| `RelayStudioViews` + `RelayIDE` | `7,540` | 双语 2×2 实时 PTY 终端网格、关键路径 DAG 画布、三栏 AST 语义合并工作台、2.5D 等轴测领地耦合地图、Wiretap 火焰图与护栏插件工作台 |
| `RelayIDETests` | `5,840` | 覆盖 7 大端到端测试套件的 `129` 项 Swift Testing（`@Test`）自动化验证用例 |

---

## 界面预览（2x Retina 高清截图 `2720 × 1680`）

| 2×2 多厂商并行终端网格与关键路径 DAG | 声明级三路 AST 语义合并工作台 |
|---|---|
| ![并行终端网格](docs/screenshot-pty-grid-zh.png) | ![三路语义合并](docs/screenshot-semantic-merge-zh.png) |

| 2.5D 等轴测领地耦合与围栏冲突地图 | Wiretap 令牌火焰图、预算熔断与 DLP 审计 |
|---|---|
| ![领地围栏地图](docs/screenshot-territory-map-zh.png) | ![Wiretap 预算网关](docs/screenshot-wiretap-guardrails-zh.png) |

---

## 安装与使用

### Homebrew Cask 一键安装

```bash
brew install --cask zxu756/tap/relayide
```

### 从源码构建与运行测试

```bash
git clone https://github.com/zxu756/RelayIDE.git
cd RelayIDE
swift test --no-parallel
./Scripts/build-app.sh
open build/RelayIDE.app
```

### 命令行工具 (CLI)、双语报告导出与 MCP 服务器

```bash
# 初始化可复现的四厂商演示工程并导出带「中文 | EN」切换胶囊的独立 HTML 审计报告
relayide init --project ./demo.relayproj --seed-demo
relayide status --project ./demo.relayproj
relayide lanes --project ./demo.relayproj
relayide dag-waves --project ./demo.relayproj
relayide semantic-merge base.swift left.swift right.swift
relayide export-html ./relay-dossier.html --project ./demo.relayproj

# 指定界面语言启动或导出 2x Retina (2720 × 1680) 中英文工作台截图
relayide --lang zh
relayide --export-screenshots ./docs --lang zh
relayide --export-screenshots ./docs --lang en

# 启动基于 stdio 的 JSON-RPC 2.0 MCP 服务器（供外部智能体调用 relay_semantic_merge 与 relay_check_ownership）
relayide mcp
```

---

## 开源许可

MIT License. Copyright (c) 2026 Xu (`zxu756`).
