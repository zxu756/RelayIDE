# RelayIDE

**[English](README.md)** | **简体中文**

**面向 macOS 的多智能体接力工作台与工作区存储工具**

`RelayIDE` 是建立在 `agent-relay`（`relay.sh`，使用前必须先安装 `agent-relay`）之上的原生 macOS 命令行工具、SQLite 工作区存储库、MCP 服务与 SwiftUI 桌面工作台。**当前状态（M1）：可通过 `RelayIDE run` 经 `agent-relay` 在各自的隔离 Git worktree 中无界面运行 coding agent（`claude`、`codex`、`agy`、`vibe`），并将成功或部分完成的通道提交到各自分支；当前版本还不自动合并分支、不执行 `verify` 验证命令、没有整单预算（`RELAY_BUDGET_USD`），桌面界面也尚未接入真实运行。**

![RelayIDE 合成演示预览](docs/screenshot-pty-grid-zh.png)
*图 1（`[演示数据]`）：传入 `--demo`（`--export-screenshots`）渲染的四通道合成预览界面。不带 `--demo` 启动 `RelayIDE` 时默认进入空状态：0 条泳道、无终端假输出、无费用数字、无代理地址。*

---

## 当前可用能力（M1）

- **无界面多智能体工作树运行器（`run`、`status --run`、`status --runs`）**：`RelayIDE run <plan.json> --project <dir> [--relay-sh <path>] [--lang zh|en]` 在真实 Git 仓库上经 `agent-relay`（按 `--relay-sh`、`RELAYIDE_RELAY_SH`、`~/.agents/skills/agent-relay/scripts/relay.sh` 顺序定位，同目录需有 `relay_util.py`）执行多通道计划。
  - **前置校验与工程锁。** 在创建任何目录、分支或运行记录前校验 `plan.json`（仅认 `claude`、`codex`、`agy`、`vibe`；通道名匹配 `^[a-z0-9][a-z0-9-]{0,39}$` 且 `integration` 留给 M2；M1 每条通道最多一个前置；无环；目标仓库已配置 Git `user.name` 与 `user.email`；`--project` 已初始化且位于仓库工作区之外；未设 `RELAY_BUDGET_USD`；未设 `RELAY_WORKER`），并以非阻塞 `flock` 获取 `<project>/run.lock`。
  - **隔离执行、终端记录与分支提交。** 串行在 `<project>/runs/<run-id>/worktrees/<lane>` 创建 worktree 与新分支 `relay/<run-id>/<lane>`（`git worktree add -b`，绝不重置已有分支），在伪终端中启动 `<relay.sh> <agent> <worktree> <prompt>`，并将伪终端主端读到的字节写入 `<project>/runs/<run-id>/lanes/<lane>.pty`（该 `.pty` 文件是带 `\r\n` 行规程的伪终端记录，不是 agent 的逐字节原始输出；原始输出以 `relay.sh` 写入的 `<worktree>/.relay/NN-<agent>.log` 为准）。无前置通道并行启动；有前置通道在前置以 `succeeded` 或 `succeeded-no-changes` 结束时立即从前置提交后的分支头启动，否则标为 `skipped` 且不建 worktree 与分支。`succeeded` 和 `partial` 通道用仓库配置的 Git 身份提交改动（`git commit --no-verify`，排除 `.relay/`）；失败、超时、被拒绝、已取消、被强制结束的通道不提交并记录未提交文件列表。
  - **花费解析、信号与退出码。** 从 `<worktree>/.relay/LOG.md` 解析美元花费（`costSource: "usd"`）、未计价 token 数（`costUSD: null`，`costSource: "unpriced"`）或无记录（`costSource: "no_record"`）。收到 `SIGINT`（`130`）或 `SIGTERM`（`143`）时按 `SIGINT -> SIGTERM -> 后代进程组 SIGKILL` 阶梯清理运行中通道且不提交；`RelayIDE` 被 `kill -9` 后由 `run.lock` 失锁对账将运行标为 `interrupted`。`run` 退出码：`0` 全部通道成功；`1` 跑完但至少一条通道非成功；`2` 计划、参数或缺少 Git 身份错误（标准输出为空）；`125` 环境、文件锁或内部错误（标准输出为空）；`130` / `143` 收到 `SIGINT` / `SIGTERM`。结束时在标准输出打印运行台账 JSON，与 `RelayIDE status --project <dir> --run <run-id>` 逐字节一致。
  - **当前 M1 边界。** 还不将通道分支合并到集成分支（排在 M2）；`verify` 字段只记入数据库并在标准错误提示将于 M2 执行；设了 `RELAY_BUDGET_USD` 时拒绝运行并返回 `2`（各 worktree 的 `LOG.md` 跨通道不累计，整单预算排在 M4）；未知的非选项非 `.relayproj` 首参数报错并以退出码 `2` 结束，不会打开桌面窗口。
- **默认空启动的 `中文 / EN` 双语桌面工作台**：不带 `--demo` 启动 macOS 桌面端时，界面保持真实空状态（`0` 条通道、空终端缓冲区、无预算金额、无回环代理地址）。支持通过顶部工具栏 `中文 | EN` 胶囊、菜单快捷键 `⇧⌘L`、`⌘,` 偏好设置弹窗、CLI `--lang zh|en` 或环境变量 `RELAYIDE_LANG=zh|en` 实时切换中英文。仅在显式传入 `--demo`（或点击界面中的「载入演示数据」）时才会在临时目录载入带 `[演示数据]` 徽章的合成样本，绝不污染用户的 `.relayproj` 目录。
- **`.relayproj` SQLite WAL 存储、运行台账、FTS5 检索与检查点（`RelayWorkspaceStore`）**：数据库 v5 迁移（启用 `busy_timeout`）持久化保存 M1 运行与通道台账（`relay_runs`、`relay_run_lanes`，由 `status --run <id>` 与 `status --runs` 查询）以及工作区元数据、通道定义、DAG 拓扑描述、合并报告、护栏审计记录、FTS5 `BM25` 全文检索索引、SHA-256 快照与 Undo/Redo 历史。所有只读/查询类 CLI 子命令（`status`、`lanes`、`dag-waves`、`audit-plugins`、`export-html`、`mcp --project`）在 `--project <dir>` 不存在时均立即报错并以非 0 状态码退出，不会在后台偷偷创建空目录或数据库。对 `init` 建出来的工作区，不带参数的 `status` 报告 `activeLaneCount: 0`，`status --runs` 输出 `[]`，`lanes` 没有输出，`dag-waves` 输出“当前工作区尚未注册任何 DAG”；`init --seed-demo` 会向 M0 预览表写入带 `[演示数据]` 标记的合成数据。
- **独立基础库组件（已通过单元测试验证）**：
  - `RelayPTYCore`：基于 `posix_openpt(2)` 的本地子进程伪终端会话封装、`<sys/wait.h>` 退出码与信号解码（`POSIXWaitStatus`）、后代进程树枚举（`proc_listchildpids`）、VT100 / `xterm-256color` / 24 位真彩色屏幕缓冲区、Boyer-Moore 历史检索与 `.cast` v2 编解码。
  - `RelayWorktreeGit`：`git worktree add -b` 创建、通道改动暂存与提交（`--no-verify`，排除 `.relay/`）、基于 glob 的文件领地规则匹配（`FileOwnershipRule`）以及 `.relay/LOG.md` 交接日志解析。
  - `RelayOrchestrator`：无波次单前置事件驱动调度器（`RelayDAGRunScheduler`）、`.relay/LOG.md` 花费与 token 解析器、Kahn 拓扑波次排序与关键路径法（`ES`/`EF`/`LS`/`LF`/松弛时间）计算器。
  - `RelayPluginSDK`：沙箱化 `JavaScriptCore` 策略包与钩子演练台求值器（支持 `audit-plugins` 与 GUI 交互演练）。
  - `RelayWiretapProxy`：独立本地回环 HTTP/1.1 + SSE 流解析器、敏感凭据正则扫描器与内存预算熔断账本。
- **基于 stdio 的 JSON-RPC 2.0 MCP 服务器（共 `2` 个工具）**：`RelayIDE mcp [--project <dir>]` 通过标准输入/输出暴露 **2 个 MCP 工具**：
  1. `relay_semantic_merge`（和下面 `semantic-merge` 子命令是同一个带保全检查的三路合并；只有子命令会退出 `0` 的情况才返回 `isError: false`）。
  2. `relay_check_ownership`（校验指定相对路径是否符合 `--project` 工作区中对应通道的 `FileOwnershipRule` 领地规则）。
- **带保全检查的三路合并（`semantic-merge`，实验性）**：`RelayIDE semantic-merge <base> <left> <right>` 以 `git merge-file` 为准，要求 `PATH` 里有 `git`。M3 之前在交接偏好中默认关闭。
  - **它做什么。** 先跑行级合并 `git merge-file -p`。git 能干净合并时，输出就是 git 的结果，逐字节相同。git 报冲突时，输出是 git 带冲突标记的结果，只有一种例外：每个冲突块都只是“两边在同一位置各自插入了几行”，这种文件类型有语法检查器，并且把声明级引擎当裁判问一遍，它给出的非空行和顺序都对得上，这时两边插入的内容都保留（一边的行在前，另一边在后，先后顺序取引擎给的）。输出的文本始终是用 git 自己的输出拼出来的，引擎的文本从不输出。
  - **退出码 `0` 保证什么。** 两边各自新增的每一行都在输出里。两边都没碰的行逐字节不变，空行和字符串内容也算在内。`.py`/`.pyi`、`.swift`、`.js`/`.mjs`/`.cjs`、`.ts`/`.tsx`、`.json` 的输出通过了该语言自己的解析器（`python3 -m py_compile`、`xcrun swiftc -parse`、`node --check`、`tsc --noEmit`，没有 `tsc` 时用 Node 的类型擦除加 `node --check`、`JSONSerialization`）。
  - **它不保证什么。** 能通过解析的合并结果，含义仍然可能是错的，这一点和 `git merge` 一样。两边内容都保留时，谁先谁后由引擎决定，只有语法检查替它把关。声明级引擎单独使用时已知会损坏 Python 和 Swift（丢装饰器和属性、改动声明之间的空行），所以它只有否决权，大多数冲突仍然按冲突报告。这个引擎留不留，等 M3 的评估结果。
  - **其他文件类型。** 其他扩展名（`.rs`、`.go`、`.java`、`.jsx`、没有扩展名等）没有语法检查器。这时命令的行为和 `git merge-file` 完全一样：要么干净合并、退出码 `0`，并在 stderr 注明没做语法检查；要么输出 git 的冲突结果、退出码 `1`。声明级引擎不参与。
  - **退出码。** `0` 无冲突。`1` 有冲突，stdout 是 git 带冲突标记的结果。`2` 用法错误、文件读不了或不是 UTF-8。`3` git 干净合并了但结果过不了语法检查，不输出任何内容。`4` 找不到 git 或 `git merge-file` 运行失败，拒绝合并。stderr 有一行说明用的是哪种结果：`[strategy=line-level]`、`[strategy=declaration-level]` 或 `[strategy=none]`。
  - **在 `Fixtures/merge-cases` 上的实测**（35 组三路合并用例，涉及 Swift、Python、TypeScript、JavaScript、Rust、Go、Java；2026-11-14 由 `Scripts/acceptance/merge_cases_check.py` 逐组对照 `git merge-file` 检查，输出在 `reports/m0-acceptance.txt`）：15 组干净合并且与 git 相同，8 组冲突靠保留两边插入内容解决，12 组按冲突报告且输出与 git 相同，0 组比 `git merge-file` 差。
- **独立双语 HTML 报告导出（`export-html`）**：从已有 `.relayproj` 导出单文件 `中文 | EN` HTML 报告（当数据源来自 `--seed-demo` 时自动标注 `[DEMO]` / `[演示数据]`）。

---

## 后续路线图（尚未实现）

- **M2（合并流水线与 `verify` 门禁）**：将完成的通道分支按拓扑顺序通过 `git merge --no-ff` 合入 `relay/<run-id>/integration`，遇冲突干净中止，流式读取 `verify` 命令输出并按进程组超时清理。
- **M3（语义合并去留评估）**：在开源仓库真实合并冲突语料上对比 `git merge-file`、现有引擎与 `mergiraf`，决定用 `SwiftSyntax` / `tree-sitter` 重写还是删除。
- **M4（花费汇总与整单预算）**：跨通道整单预算控制，以及决定保留还是删除独立本地回环代理。
- **M5（桌面界面接入真实运行）**：将 SwiftUI 终端网格、通道状态与花费列表、文件归属视图与合并视图接到 M1/M2 的真实运行上，并接入真实广播命令（当前触发 `⌘⇧B` 仍提示「广播命令尚未实现（排在 M5）」）。

---

## 已知问题

- **没有 `tsc` 时 `semantic-merge` 对 TypeScript 的检查偏严。** `PATH` 里没有 `tsc` 时，TypeScript 用 Node 自带的类型擦除来检查，它不接受无法直接擦掉的语法（`enum`、`namespace`、构造函数参数属性），也不接受 `.tsx` 里的 JSX。这类文件即使合并本身没问题，也会以退出码 `3` 结束。
- **`semantic-merge` 能解决的冲突很少。** 它只会保留“两边在同一位置各自插入”这一类冲突的两边内容，而且要求声明级引擎把每一个非空行都原样给出来。改名、相邻行的修改、引擎读错的文件，都和 `git merge-file` 一样按冲突报告。
- **验证门禁在输出很大时卡死（只是库，没有接进任何命令）。** `VerificationCommandGateEvaluator.runGateCommand` 等子进程退出之后才读它的 stdout 和 stderr。命令输出超过管道缓冲（约 64 KB）时会卡住，一直到超时，最后报成退出码 `124`，不是命令真实的退出码。M1 的 `RelayIDE run` 不执行 `verify`，M2 用到它之前必须修。
- **验证门禁超时只杀一个进程（只是库）。** 同一个函数超时后只结束它启动的那个 shell，不结束整个进程组，验证命令派生出来的子进程会继续运行。
- **旧工作区检视表与 M1 运行台账尚未在界面打通。** `RelayIDE run` 将运行和通道记入 v5 新增的 `relay_runs` 与 `relay_run_lanes` 表（通过 `status --run <id>` 和 `status --runs` 查询）；旧的 `lanes`、`dag-waves`、`audit-plugins`、`export-html` 子命令与桌面界面仍读取 M0 工作区表（仅 `init --seed-demo` 会写入合成样本），等 M5 接入真实运行。

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

> **可执行文件名与前置依赖**：从源码通过 SwiftPM 构建生成 `.build/debug/RelayIDE`（运行 `./Scripts/build-app.sh` 生成 `build/RelayIDE.app/Contents/MacOS/RelayIDE`）；通过 Homebrew Cask（`brew install --cask zxu756/tap/relayide`）安装时会将小写命令 `relayide` 软链至 `/opt/homebrew/bin/relayide`。运行 `RelayIDE run` 需要先将 `agent-relay` 安装到 `~/.agents/skills/agent-relay/scripts/relay.sh`（或通过 `--relay-sh` / `RELAYIDE_RELAY_SH` 指定路径）。

### 从源码构建与运行验收测试

```bash
swift build
./Scripts/test.sh milestone 0
./Scripts/test.sh milestone 1
./Scripts/build-app.sh
```

### `RelayIDE run` 的 `plan.json` 示例

对位于目标 Git 仓库之外且已 `init` 的 `.relayproj`（目标仓库需已配置 `user.name` 与 `user.email`）调用 `.build/debug/RelayIDE run <plan.json> --project <dir.relayproj> [--relay-sh <path>] [--lang zh|en]`：

```json
{
  "repo": "../target-repo",
  "base": "main",
  "lanes": [
    {"id": "api",  "agent": "claude", "prompt": "prompts/api.md",  "after": []},
    {"id": "docs", "agent": "agy",    "prompt": "prompts/docs.md", "after": ["api"]}
  ],
  "verify": "swift build && swift test"
}
```

### 命令行（CLI）与 MCP 服务器用法

`swift build` 之后在仓库根目录运行。`Scripts/acceptance/readme-commands.sh` 就是从本文件里取出这些命令原样执行的。

```bash
# 0. 给下面的示例准备一个临时目录
WORK="$(mktemp -d)"

# 1. 查看命令行帮助与版本，初始化空工作区（0 条通道），并查看工作区统计与运行台账
.build/debug/RelayIDE --help --lang zh
.build/debug/RelayIDE version --lang zh
.build/debug/RelayIDE init --project "$WORK/my-empty.relayproj" --lang zh
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj" --lang zh
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj" --runs --lang zh
.build/debug/RelayIDE lanes --project "$WORK/my-empty.relayproj" --lang zh

# 2. 显式创建带 [演示数据] 标记的合成演示工作区并导出 HTML 报告
.build/debug/RelayIDE init --project "$WORK/demo.relayproj" --seed-demo --lang zh
.build/debug/RelayIDE dag-waves --project "$WORK/demo.relayproj" --lang zh
.build/debug/RelayIDE audit-plugins --project "$WORK/demo.relayproj" --lang zh
.build/debug/RelayIDE export-html "$WORK/demo-dossier.html" --project "$WORK/demo.relayproj" --lang zh

# 3. 带保全检查的三路合并：这一组 git 能干净合并，输出就是 git 的结果（退出码 0）
.build/debug/RelayIDE semantic-merge \
  Fixtures/merge-cases/20-py-decorator-added/base.py \
  Fixtures/merge-cases/20-py-decorator-added/left.py \
  Fixtures/merge-cases/20-py-decorator-added/right.py --lang zh

#    两边在同一位置各加了一个方法：git 报冲突，两边内容都保留（退出码 0）
.build/debug/RelayIDE semantic-merge \
  Fixtures/merge-cases/02-swift-both-add-func/base.swift \
  Fixtures/merge-cases/02-swift-both-add-func/left.swift \
  Fixtures/merge-cases/02-swift-both-add-func/right.swift --lang zh

#    真冲突：stdout 是 git 带冲突标记的结果，退出码 1
.build/debug/RelayIDE semantic-merge \
  Fixtures/merge-cases/12-swift-true-conflict/base.swift \
  Fixtures/merge-cases/12-swift-true-conflict/left.swift \
  Fixtures/merge-cases/12-swift-true-conflict/right.swift --lang zh || echo "semantic-merge exit code: $?"

# 4. 基于 stdio 的 JSON-RPC 2.0 MCP 服务器（共 2 个工具：relay_semantic_merge、relay_check_ownership）：列出工具
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
