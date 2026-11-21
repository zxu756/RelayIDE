# RelayIDE

**[English](README.md)** | **简体中文**

**面向 macOS 的多智能体接力工作台与工作区存储工具**

`RelayIDE` 是建立在 `agent-relay`（`relay.sh`，使用前必须先安装 `agent-relay`）之上的原生 macOS 命令行工具、SQLite 工作区存储库、MCP 服务与 SwiftUI 桌面工作台。**当前状态（M2）：可通过 `RelayIDE run` 经 `agent-relay` 在各自的隔离 Git worktree 中无界面运行 coding agent（`claude`、`codex`、`agy`、`vibe`），将成功或部分完成的通道提交到各自分支，并在全部通道成功且有改动时按确定性顺序经 `git merge --no-ff` 合入集成分支 `relay/<run-id>/integration`（遇冲突干净撤销并停下）、在伪终端中执行可选的 `verify` 验证命令，全程不修改 `base`；是否可合入只看输出 JSON 中的 `integration.ready`（仅全部通道成功且集成状态为 `verified` 时为 `true`）。当前版本不把集成分支合入 `base`、不支持多前置通道、没有整单预算（`RELAY_BUDGET_USD`），桌面界面也尚未接入真实运行。**

![RelayIDE 合成演示预览](docs/screenshot-pty-grid-zh.png)
*图 1（`[演示数据]`）：传入 `--demo`（`--export-screenshots`）渲染的四通道合成预览界面。不带 `--demo` 启动 `RelayIDE` 时默认进入空状态：0 条泳道、无终端假输出、无费用数字、无代理地址。*

---

## 当前可用能力（M2）

- **无界面多智能体工作树运行器、合并流水线与 `verify` 验证（`run`、`status`）**：`RelayIDE run <plan.json> --project <dir> [--relay-sh <path>] [--lang zh|en]` 在真实 Git 仓库上经 `agent-relay`（按 `--relay-sh`、`RELAYIDE_RELAY_SH`、`~/.agents/skills/agent-relay/scripts/relay.sh` 顺序定位，同目录需有 `relay_util.py`）执行多通道计划，将完成的通道合入独立集成分支，并执行可选验证命令。
  - **前置校验与工程锁。** 在触碰磁盘或任何 Git 引用前校验 `plan.json`：顶层字段仅允许 `repo`、`base`、`lanes`、可选字符串 `verify` 与可选整数秒 `verify_timeout`（`1...86400`，默认 `1800`；非整数、越界或没有非空 `verify` 却指定时返回退出码 `2`）；通道字段仅允许 `id`（匹配 `^[a-z0-9][a-z0-9-]{0,39}$`，`integration` 保留给集成分支）、`agent`（`claude`、`codex`、`agy`、`vibe`）、`prompt` 与可选 `after`（每条通道最多一个前置；多前置通道仍不支持，返回退出码 `2`）；顶层或通道出现未知字段时返回退出码 `2` 并指明字段名；无环；目标仓库已配置 Git `user.name` 与 `user.email`；`--project` 已初始化且位于仓库工作区之外；未设 `RELAY_BUDGET_USD`（退出码 `2`）；未设 `RELAY_WORKER`（退出码 `125`）。随后以非阻塞 `flock` 获取 `<project>/run.lock`，并将 `base` 一次性解析为不可变的提交号。
  - **仓库 Git 钩子一律跳过（`-c core.hooksPath=/dev/null`）。** `RelayIDE` 自身执行的全部 Git 写操作（建通道 worktree、通道提交、建集成 worktree、`git merge --no-ff` 合并）均传入 `-c core.hooksPath=/dev/null`，跳过全部仓库钩子（`post-checkout`、`pre-commit`、`prepare-commit-msg`、`commit-msg`、`post-commit`、`pre-merge-commit`、`post-merge` 等），并在提交说明中写明 `"repository hooks skipped"`。仓库自身的检查与初始化请放进 `verify`。
  - **通道执行、伪终端记录与分支提交。** 串行在 `<project>/runs/<run-id>/worktrees/<lane>` 创建 worktree 与新分支 `relay/<run-id>/<lane>`（`git worktree add -b`，绝不重置已有分支），在伪终端中运行 `<relay.sh> <agent> <worktree> <prompt>`，并将伪终端主端字节追加至 `<project>/runs/<run-id>/lanes/<lane>.pty`（该 `.pty` 文件是经伪终端行规程把 `\n` 转为 `\r\n` 的终端记录，不是程序的逐字节原始输出；agent 原始输出以 `relay.sh` 写入的 `<worktree>/.relay/NN-<agent>.log` 为准）。无前置通道立即并行启动；单前置通道在前置以 `succeeded` 或 `succeeded-no-changes` 结束时立即从前置提交后的分支头启动，否则标为 `skipped` 且不建 worktree 与分支。`succeeded` 和 `partial` 通道用仓库配置的 Git 身份提交改动（`-c core.hooksPath=/dev/null`、`--no-verify`、`--no-gpg-sign`，排除 `.relay/`；无改动时记为 `succeeded-no-changes`、`commitOID: null`）；失败、超时、被拒绝、已取消、被强制结束的通道不提交并记录未提交文件列表。
  - **顺序集成合并（`git merge --no-ff`）与冲突处理。** 合并只在全部通道结束后才开始，且仅在运行未被取消、`RelayIDE` 未出错、所有通道均为 `succeeded` 或 `succeeded-no-changes` 时执行：
    - 只要有任一通道不是成功（`failed`、`timeout`、`partial`、`refused`、`skipped`、`cancelled`、`killed`），一律不合并：`integration.status` 记为 `skipped`（写明哪几条通道及状态），不建集成分支和 worktree，不跑 `verify`，`run` 退出码 `1`。
    - 所有通道均无提交（全为 `succeeded-no-changes`）时，`integration.status` 记为 `nothing-to-merge`，不建集成分支和 worktree，不跑 `verify`，`run` 退出码 `0`。
    - 其余情况下，从初始解析的 `base` 提交号在 `<project>/runs/<run-id>/worktrees/integration` 创建分支 `relay/<run-id>/integration`（`git worktree add -b`，从不修改 `base` 或主仓库工作树），按确定性的“拓扑序、并列按 `plan.json` 先后”顺序逐条合并各通道的 `commitOID`（例如 `[b(after a), c, a]` 的合并顺序为 `c, a, b`）。`commitOID` 为 `null` 或已是 `HEAD` 祖先时记 `no-changes`，不调用 `git merge`。每次合并执行 `git merge --no-ff --no-edit --no-log --no-stat --no-squash --no-autostash --no-verify-signatures --no-gpg-sign`（带 `-c core.hooksPath=/dev/null -c rerere.enabled=false -c gc.auto=0 -c maintenance.auto=false -c user.useConfigOnly=true`），并校验双父提交（`HEAD^1` 与 `HEAD^2`）。
    - 遇到首次合并冲突（非零退出且存在 `MERGE_HEAD`）时立即停下：先记录 `git status --porcelain=v1 -z` 中全部未合并项（`path` 与 `UU`、`AA`、`UD`、`DU` 等双字母状态码）及 `CONFLICT (...)` 行，再执行 `git merge --abort` 并校验 `HEAD`、无 `MERGE_HEAD` 及 `git status --porcelain=v1 -uall --ignored` 为空，将该通道记 `conflict`、后续通道记 `not-attempted`、`integration.status = "conflict"`、`ready = false`，不跑 `verify`，`run` 退出码 `1`。非冲突的 `git merge` 失败（无 `MERGE_HEAD`）不跑 `--abort`，记 `integration.status = "error"` 并以 `125` 退出。
  - **伪终端 `verify` 执行。** 只在全部合并成功后运行：
    - 计划未配置 `verify`（或仅含空白）时，合并完成后集成状态为 `merged`、`ready: false`、`verify: null`，`run` 退出码 `0`。
    - 配置了 `verify` 时，在 `<project>/runs/<run-id>/worktrees/integration` 的伪终端中启动 `/bin/sh -c 'exec </dev/null; exec /bin/sh -c "$1"' relayide-verify '<verify>'`（非登录 shell，不读启动文件，原样保留调用方 `PATH` 与环境并叠加 `PAGER=cat`、`GIT_PAGER=cat`，保住控制终端的同时把标准输入重定向到 `/dev/null`）。
    - 伪终端主端输出原样追加到 `<project>/runs/<run-id>/verify.pty`，上限 `16 MiB`（`16,777,216` 字节；达到上限后停止写盘、标记 `logTruncated: true`，并继续排空主端直至退出）。与 `<lane>.pty` 相同，`verify.pty` 是伪终端把 `\n` 换成 `\r\n` 后的终端记录，不是逐字节的程序原始输出。
    - 到达 `verify_timeout` 或收到 `SIGINT`/`SIGTERM` 时，在发送第一个信号之前先枚举全部后代进程与进程组（`proc_listchildpids`，失败时回退 `sysctl(KERN_PROC_ALL)`），对全部已收集进程组依次发送 `SIGINT`（等 `10s`）-> `SIGTERM`（等 `5s`）-> `SIGKILL` 并等待所有组清空。退出状态经 `POSIXWaitStatus` 解码（被信号杀死记 `status: "failed"`、`signal: N`、`exitCode: null`）。退出 `0` 后用 `git status --porcelain=v1 --untracked-files=no` 检查集成 worktree，若改了已跟踪文件则记 `verify` 为 `failed`（`integration.status = "verify-failed"`、`ready = false`）并在 `modifiedTrackedFiles` 列出文件。
  - **可合入判定（`integration.ready`）、花费、信号与 `status`。**
    - **可合入只看 JSON 里的 `integration.ready`**：仅当全部通道成功、未取消且 `integration.status == "verified"` 时 `integration.ready` 为 `true`，其余情形（包括未配置 `verify` 时的 `merged` 与全无改动时的 `nothing-to-merge`）一律为 `false`。`RelayIDE` 从不把 `relay/<run-id>/integration` 合入 `base`，这一步留给人执行。
    - 从 `<worktree>/.relay/LOG.md` 解析美元花费（`costSource: "usd"`）、未计价 token 数（`costUSD: null`，`costSource: "unpriced"`）或无记录（`costSource: "no_record"`）。在通道、合并、`verify` 三阶段统一响应 `SIGINT`（`130`）与 `SIGTERM`（`143`）；`RelayIDE` 被 `kill -9` 后由 `run.lock` 失锁对账将运行、集成与 `verify` 标为 `interrupted`（`pending` 集成标为 `skipped`）。
    - 标准输出打印含 `integration` 的运行台账 JSON，与 `RelayIDE status --project <dir> --run <run-id> [--json]` 逐字节一致。`RelayIDE status [--project <dir>] [--run <id> | --runs] [--json]` 本来就只输出 JSON，写与不写 `--json` 结果完全相同；传入多余位置参数返回退出码 `2`。
  - **`RelayIDE run` 退出码表：**

    | 退出码 | 情形 |
    |---|---|
    | `0` | 所有通道成功（含 `succeeded-no-changes`），并且 `integration.status` 是 `verified`、`merged`（计划没有 `verify`）或 `nothing-to-merge` |
    | `1` | 跑完了但不是上面那样：有通道不成功（集成 `skipped`）、合并冲突（`conflict`）、或 `verify` 失败（`verify-failed`）或超时（`verify-timeout`） |
    | `2` | 计划、命令行选项或 Git 身份错误，在动任何东西之前发现（含 `verify_timeout` 不合法、计划有未知字段、多前置通道、设了 `RELAY_BUDGET_USD`、或 `status` 带多余位置参数）；标准输出为空 |
    | `125` | `RelayIDE` 或环境出错（找不到 `relay.sh`、环境有 `RELAY_WORKER`、`run.lock` 被占用、建 worktree 失败、`git merge` 非冲突失败、`git merge --abort` 后状态不干净、`verify` 起不来、数据库写失败）；标准输出为空 |
    | `130` / `143` | 通道、合并或 `verify` 任一阶段收到 `SIGINT`（`130`）/ `SIGTERM`（`143`） |

  - **当前 M2 边界。** 不更新也不合入 `base`（由人在确认 `integration.ready == true` 后自行合入 `relay/<run-id>/integration`）；多前置通道（`after` 超过 1 项）仍拒绝并返回 `2`；只用 Git 自带的合并（`git merge --no-ff`），不提供自动冲突解决/重试、重跑合并或 `verify` 的子命令、或清理旧 worktree 的子命令；设了 `RELAY_BUDGET_USD` 时返回 `2`（各 worktree 的 `LOG.md` 跨通道不累计，整单预算排在 M4）；桌面界面尚未接入真实运行（排在 M5），未知的非选项非 `.relayproj` 首参数报错并以退出码 `2` 结束，不会打开桌面窗口。
- **默认空启动的 `中文 / EN` 双语桌面工作台**：不带 `--demo` 启动 macOS 桌面端时，界面保持真实空状态（`0` 条通道、空终端缓冲区、无预算金额、无回环代理地址）。支持通过顶部工具栏 `中文 | EN` 胶囊、菜单快捷键 `⇧⌘L`、`⌘,` 偏好设置弹窗、CLI `--lang zh|en` 或环境变量 `RELAYIDE_LANG=zh|en` 实时切换中英文。仅在显式传入 `--demo`（或点击界面中的「载入演示数据」）时才会在临时目录载入带 `[演示数据]` 徽章的合成样本，绝不污染用户的 `.relayproj` 目录。
- **`.relayproj` SQLite WAL 存储、运行与集成台账、FTS5 检索与检查点（`RelayWorkspaceStore`）**：数据库 v6 迁移（启用 `busy_timeout`）持久化保存 M1/M2 运行、通道、集成与合并步台账（`relay_runs`、`relay_run_lanes`、`relay_run_integration`、`relay_run_merges`；M1 的 v5 库可平滑升级，旧运行的 `integration` 为 `null`，由 `status --run <id> [--json]` 与 `status --runs [--json]` 查询）以及工作区元数据、通道定义、DAG 拓扑描述、合并报告、护栏审计记录、FTS5 `BM25` 全文检索索引、SHA-256 快照与 Undo/Redo 历史。所有只读/查询类 CLI 子命令（`status`、`lanes`、`dag-waves`、`audit-plugins`、`export-html`、`mcp --project`）在 `--project <dir>` 不存在时均立即报错并以非 0 状态码退出，不会在后台偷偷创建空目录或数据库。对 `init` 建出来的工作区，不带参数的 `status` 报告 `activeLaneCount: 0` 与 `schemaVersion: 6`，`status --runs` 输出 `[]`，`lanes` 没有输出，`dag-waves` 输出“当前工作区尚未注册任何 DAG”；`init --seed-demo` 会向 M0 预览表写入带 `[演示数据]` 标记的合成数据。
- **独立基础库组件（已通过单元测试验证）**：
  - `RelayPTYCore`：基于 `posix_openpt(2)` 的本地子进程伪终端会话封装、`<sys/wait.h>` 退出码与信号解码（`POSIXWaitStatus`）、首个信号前的后代进程组枚举（`proc_listchildpids` 加 `sysctl(KERN_PROC_ALL)` 回退）与按组排空取消阶梯、可选 `.pty` 原始记录字节上限、VT100 / `xterm-256color` / 24 位真彩色屏幕缓冲区、Boyer-Moore 历史检索与 `.cast` v2 编解码。
  - `RelayWorktreeGit`：全路径跳过钩子（`-c core.hooksPath=/dev/null`）的通道与集成 `git worktree add -b` 创建、通道改动暂存与提交（排除 `.relay/`）、`git merge --no-ff` 集成合并与 porcelain 冲突项提取及 `git merge --abort` 三项干净校验、基于 glob 的文件领地规则匹配（`FileOwnershipRule`）以及 `.relay/LOG.md` 交接日志解析。
  - `RelayOrchestrator`：无波次单前置事件驱动调度器（`RelayDAGRunScheduler`）、拓扑加计划序集成合并运行器（`RelayIntegrationMergeRunner`）、伪终端 `verify` 运行器（`RelayVerifyRunner`）、`.relay/LOG.md` 花费与 token 解析器、Kahn 拓扑波次排序与关键路径法（`ES`/`EF`/`LS`/`LF`/松弛时间）计算器。
  - `RelayPluginSDK`：沙箱化 `JavaScriptCore` 策略包与钩子演练台求值器（支持 `audit-plugins` 与 GUI 交互演练）。
  - `RelayWiretapProxy`：独立本地回环 HTTP/1.1 + SSE 流解析器、敏感凭据正则扫描器与内存预算熔断账本。
- **基于 stdio 的 JSON-RPC 2.0 MCP 服务器（共 `1` 个工具）**：`RelayIDE mcp [--project <dir>]` 通过标准输入/输出暴露 **1 个 MCP 工具**：`relay_check_ownership`（校验指定相对路径是否符合 `--project` 工作区中对应通道的 `FileOwnershipRule` 领地规则）。
- **独立双语 HTML 报告导出（`export-html`）**：从已有 `.relayproj` 导出单文件 `中文 | EN` HTML 报告（当数据源来自 `--seed-demo` 时自动标注 `[DEMO]` / `[演示数据]`）。

> **本版已删除（M3，2026-11-21）：** `v1.4.0` 及以前附带的 `semantic-merge` 子命令（及其对应 MCP 工具）已在这一版删除，原因和 2026-11-21 由 `Scripts/acceptance/m3-merge-eval.sh` 在 9 个开源仓库真实合并冲突语料上测得的数字见 [reports/m3-merge-eval.md](reports/m3-merge-eval.md)（发布的命令“与人工相同”：Python `1/330`、Swift `0/377`、TypeScript `0/611`）。

---

## 后续路线图（尚未实现）

- **M4（花费汇总与整单预算）**：跨通道整单预算控制，以及决定保留还是删除独立本地回环代理。
- **M5（桌面界面接入真实运行）**：将 SwiftUI 终端网格、通道状态与花费列表、文件归属视图与冲突视图接到 M1/M2 的真实运行上，并接入真实广播命令（当前触发 `⌘⇧B` 仍提示「广播命令尚未实现（排在 M5）」）。

---

## 已知问题

- **建 worktree、提交与合并时一律跳过仓库 Git 钩子。** `RelayIDE` 自身的全部 Git 写入都带 `-c core.hooksPath=/dev/null`，依赖 `post-checkout` 等钩子（如 `husky`）做工作树初始化的仓库不会自动执行那些钩子；所需的初始化与仓库检查请写进 `verify`。
- **合并途中或 `verify` 含独立进程组后代时遭遇 `SIGKILL`（`kill -9`）。** 若 `RelayIDE` 在单步 `git merge` 执行途中被 `kill -9` 强杀，集成 worktree 可能停在未完成的合并（存在 `MERGE_HEAD`）上；随后 `status` 会将运行与集成对账为 `interrupted` 并在 `reason` 中写明。若 `RelayIDE` 在 `verify` 期间被 `kill -9`，同进程组的子进程会因伪终端主端关闭收到 `SIGHUP` 挂断退出，但自行调用 `setpgrp` 另起进程组且忽略 `SIGHUP` 的后台子进程因无法触发取消阶梯而不会被自动清掉。
- **旧工作区检视表与 M1/M2 运行台账尚未在界面打通（以及 M0 演示截图）。** `RelayIDE run` 将运行、通道、集成状态与合并步记入数据库 v6 的 `relay_runs`、`relay_run_lanes`、`relay_run_integration` 与 `relay_run_merges` 表（通过 `status --run <id>` 和 `status --runs` 查询）；旧的 `lanes`、`dag-waves`、`audit-plugins`、`export-html` 子命令与桌面界面仍读取 M0 工作区表（仅 `init --seed-demo` 会写入合成样本），等 M5 接入真实运行；`docs/` 下的 8 张 `[演示数据]` 截图仍为 M0 时渲染（左下角状态栏显示 `SQLite WAL v4`）。

---

## 合成演示界面预览（`--demo`，`[演示数据]` 样本）

以下四张截图均由合成样本数据渲染（`--export-screenshots` 内部启用 `loadDemoWorkspace: true`），窗口顶栏均带有醒目的 `[演示数据]` 标识：

| 2x2 并行终端网格（`[演示数据]`） | 合并冲突检视台（`[演示数据]`） |
|---|---|
| ![并行终端网格演示](docs/screenshot-pty-grid-zh.png) | ![合并冲突演示](docs/screenshot-semantic-merge-zh.png) |

| 等轴测领地围栏地图（`[演示数据]`） | Wiretap 遥测与护栏插件（`[演示数据]`） |
|---|---|
| ![领地围栏地图演示](docs/screenshot-territory-map-zh.png) | ![Wiretap 与插件演示](docs/screenshot-wiretap-guardrails-zh.png) |

---

## 构建、验证与使用说明

> **可执行文件名与前置依赖**：从源码通过 SwiftPM 构建生成 `.build/debug/RelayIDE`（运行 `./Scripts/build-app.sh` 生成 `build/RelayIDE.app/Contents/MacOS/RelayIDE`）；通过 Homebrew Cask（`brew install --cask zxu756/tap/relayide`）安装时会将小写命令 `relayide` 软链至 `/opt/homebrew/bin/relayide`。运行 `RelayIDE run` 需要先将 `agent-relay` 安装到 `~/.agents/skills/agent-relay/scripts/relay.sh`（或通过 `--relay-sh` / `RELAYIDE_RELAY_SH` 指定路径）。

### 从源码构建与运行验收测试

```bash
swift build
./Scripts/test.sh milestone 0
./Scripts/test.sh milestone 1
./Scripts/test.sh milestone 2
./Scripts/test.sh milestone 3
./Scripts/build-app.sh
```

### `RelayIDE run` 的 `plan.json` 示例

对位于目标 Git 仓库之外且已 `init` 的 `.relayproj`（目标仓库需已配置 `user.name` 与 `user.email`）运行多通道计划；`readme-commands.sh` 将 `RelayIDE run` 归类为 `SKIP-AGENTS` 不直接回放，因为回放期间绝不调用真实 coding agent（完整流水线由 `m1-run.sh` 与 `m2-merge.sh` 用替身 agent 验证）：

```json
{
  "repo": "../target-repo",
  "base": "main",
  "lanes": [
    {"id": "api",  "agent": "claude", "prompt": "prompts/api.md",  "after": []},
    {"id": "docs", "agent": "agy",    "prompt": "prompts/docs.md", "after": ["api"]}
  ],
  "verify": "swift build && swift test",
  "verify_timeout": 1800
}
```

```bash
# 经 agent-relay 启动 coding agent；readme-commands.sh 标为 SKIP-AGENTS 不回放（由 m1-run.sh 与 m2-merge.sh 用替身验证）
.build/debug/RelayIDE run plan.json --project ../target.relayproj --lang zh
```

### 命令行（CLI）与 MCP 服务器用法

`swift build` 之后在仓库根目录运行。`Scripts/acceptance/readme-commands.sh` 就是从本文件里取出这些命令原样执行的。

```bash
# 0. 给下面的示例准备一个临时目录
WORK="$(mktemp -d)"

# 1. 查看命令行帮助与版本，初始化空工作区（0 条通道），并查看工作区统计与运行台账（--json 可选且输出相同）
.build/debug/RelayIDE --help --lang zh
.build/debug/RelayIDE version --lang zh
.build/debug/RelayIDE init --project "$WORK/my-empty.relayproj" --lang zh
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj" --lang zh
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj" --runs --lang zh
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj" --runs --json --lang zh
.build/debug/RelayIDE lanes --project "$WORK/my-empty.relayproj" --lang zh

# 2. 显式创建带 [演示数据] 标记的合成演示工作区并导出 HTML 报告
.build/debug/RelayIDE init --project "$WORK/demo.relayproj" --seed-demo --lang zh
.build/debug/RelayIDE dag-waves --project "$WORK/demo.relayproj" --lang zh
.build/debug/RelayIDE audit-plugins --project "$WORK/demo.relayproj" --lang zh
.build/debug/RelayIDE export-html "$WORK/demo-dossier.html" --project "$WORK/demo.relayproj" --lang zh

# 3. 基于 stdio 的 JSON-RPC 2.0 MCP 服务器（共 1 个工具：relay_check_ownership）：列出工具
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | .build/debug/RelayIDE mcp --project "$WORK/my-empty.relayproj" --lang zh
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
