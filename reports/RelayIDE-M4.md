# RelayIDE M4 花费和预算里程碑报告

## RelayIDE M4 报告

- **做了什么：** 基于 M3 收尾提交 `d131055` 在分支 `m4/cost` 上分三段完成 M4「花费和预算」全部实现与端到端验收（未推送、未打 tag、未合并）：第 1 段（`2d201b7`、`0e39773`、`636fc49`）整包删除未接入产品路径且存在 R14/R20 缺陷的 `RelayWiretapProxy` 模块及桌面第 5 个标签页（净删源码与专属单测共 5,422 行及两张未引用演示截图）；第 2 段（`60b3a78`、`d61a5e0`、`aa7b3b2`）新增 SQLite Schema v7 迁移（`relay_runs.budget_usd`），在 `RelayRunRecord`（`run`、`status --run`、`status --runs`）顶层输出 7 个花费与未计价 token 汇总字段，将不带 `--run` 的 `status --project` 与 `export-html` 改为从 `relay_runs` / `relay_run_lanes` 真实运行台账汇总，并按用户拍板（P2 = A）接通 `RELAY_BUDGET_USD` 有限正数前置校验与跨 worktree 剩余额度扣减及 `relay.sh` 拒绝门控；第 3 段（`6bdeebe`、`e7e1743`）新增 `Scripts/acceptance/m4-budget.sh`（覆盖第 1–10 行及 `--quick`、`--record`、`--mutation 2/3/4`）、接入 `Scripts/test.sh milestone 4` 与 `release`、更新中英文 `README` 实测数字与路线图，由总调度在提交 `e7e1743` 干净工作树（`working tree clean outside reports/`）上重录 `reports/m4-budget.txt`，并在第 3b 段将双语 `README` 与本报告全部实测数字对齐至该重录记录。
- **跑的命令和结果：**
  - `./Scripts/acceptance/m4-budget.sh --record`（正式记录 `reports/m4-budget.txt`，总调度于 `2026-11-21T07:04:01Z` 在提交 `e7e1743` 干净工作树 `working tree clean outside reports/` 上以 `Mode: full` 重录）：退出码 **`0`**，第 1–9 行硬性检查全部 `[PASS]`、第 10 行指标已记录（构建耗时 `17.77s`，整套总耗时 `36.09s`，测试二进制 `<repo>/.build/debug/RelayIDE` `20,670,544` bytes / `19.71 MiB`，`sha256=58e1beedf78e2178732b668bd2e30b506c0f875040a1b821ef80a4ee58a3dc6b`；诱饵触发 `0` 次，`relay.sh` 与 `relay_util.py` SHA-256 跑前跑后一致）。第 3 段 worker 在改动尚未提交的工作树上曾用 `--record --allow-dirty` 自检过一次，总调度提交 `6bdeebe`、`e7e1743` 后已移走那份临时输出，此处仅作为过程交代，不作为证据。
  - `Scripts/acceptance/m4-budget.sh --quick`：退出码 **`0`**（满足 `<= 120s` 预算，运行第 1、2、3[en]、6、7[静态+CLI]、9、10 行并显式列出跳过的 5 项）。
  - 临时拷贝三项变异反证：`Scripts/acceptance/m4-budget.sh --mutation 2`、`--mutation 3`、`--mutation 4` 退出码均为 **`0`**（内部对变异二进制执行 `m4-budget.sh` 均以退出码 **`1`** 失败，分别精准命中第 3/4/5 行、第 1/2 行、第 2/8 行变红，跑完工作树干净无改动）。
  - 全量隔离单元测试与里程碑回归：`swift test --no-parallel`（7 个测试套件共 201 个测试通过）、`Scripts/test.sh milestone 0`、`1`、`2`、`3`、`4`、`Scripts/acceptance/readme-commands.sh` 以及 `Scripts/eval/**/test_*.py` 六套 Python 单元测试全部退出码 **`0`**。
- **没验证的项和原因：**
  - **全量级真实付费 agent CLI 运行（`RELAY_REAL_AGENTS=1 RELAY_BUDGET_USD=2 Scripts/test.sh release`）：** 按总则第 4 节与项目测试分级规定，真实调用付费 CLI 仅在发版前经用户批准运行；本里程碑全程使用 `Tests/Support/stub-agent.sh` 配合真实 `relay.sh` 验证，诱饵门卫确认真实 `claude`、`codex`、`agy`、`vibe` 调用次数为 `0`。
  - **桌面界面实时显示运行状态与通道花费列表（M5）：** 按路线图与用户拍板（P4 = B），删掉原第 5 个空壳标签页后，将真实通道花费接入 SwiftUI 通道列表与实时伪终端网格排在 M5，不在 M4 声称为已完成。
  - **同一并行波次内的硬性并发分摊拦截：** 按用户拍板（P2 = A），并发通道共享启动那一刻的剩余额度（`budget - 已完成通道累计美元`），单波并行之内可能略超预算、下一波严格拦截，已在双语 `README`「当前 M4 边界」中如实写明。
- **待验证的假设里，哪些已证实、哪些被推翻：**
  - **向新 worktree 的 `relay.sh` 注入 `RELAY_BUDGET_USD=0.0000` 可在不污染该通道 `LOG.md` 的前提下原生触发退出码 `2` 拒绝（含未计价的 `agy`/`codex`）：** 实测证实成立（第 3 行 `claude` 通道 `c` 与第 5 行 `agy` 通道 `b` 均在启动前被 `relay.sh` 以退出码 `2` 拒绝，输出 `relay: not started: the job budget of $0.0000 is spent ($0.000000 recorded in LOG.md)`，替身 `0` 次执行，新 worktree 未生成 `LOG.md` 步骤）。
  - **`claude`/`vibe` 美元花费与 `relay_util.py spent` 逐通道一致，`codex`/`agy` 在 `LOG.md` 仅记 token 数且 `spent` 输出 `0.000000`：** 实测证实成立（第 1 行四通道实测：`c1` `$0.1234`、`v1` `$0.2500` 与 `relay_util.py spent` 差值 `< 1e-9`；`a1` `4,500` tokens、`x1` `1,200` tokens 在 JSON 中保持 `costUSD: null`、`costSource: "unpriced"`，绝不写成 `0`）。
  - **多通道隔离 worktree 下 `b.pty` 验证剩余额度 `$0.7000` 的方式：** 核对发现 `relay.sh` 仅在单个 worktree 自身 `LOG.md` 已花 `>= 75%` 时打印 `warning`；隔离 worktree 模式下 `b` 的 `LOG.md` 从 `0` 开始，`relay.sh` 将剩余额度 `0.7000` 通过 `--max-price 0.7000`（`vibe`）/ `--max-budget-usd 0.7000`（`claude`）及环境变量传给子进程，由 `stub-agent.sh` 记录至 `b.budget` 并回显进 `b.pty`，第 4 行实测验证通过。
- **删掉或冻结的代码：**
  - **删除：** 整包删除 `Sources/RelayWiretapProxy/`（5 个源文件共 4,433 行）与 `Tests/RelayIDETests/WiretapSSEAndDLPCircuitBreakerTests.swift`（989 行，20 个仅测已删代理的 `@Test`），删除桌面第 5 个标签页 `WiretapBudgetStudioView`（`StudioViewModelAndHonestyTests` 移除 1 个仅测内存熔断开关的 `@Test`）及两张无引用的 `docs/` Wiretap 演示截图，清理 `RelayHandoffProtocolCodec.buildWorkerEnvironment` 中未使用的 `wiretapProxyURL` 参数。
  - **保留兼容 / 冻结：** 保留 SQLite v3 迁移中的 `wiretap_spans` 空表 DDL 以兼容历史 `.relayproj` 打开升级（产品代码不再向其写入也不再从其汇总花费）；保留桌面其余 5 个面板的默认空状态与显式 `--demo` 预览，待 M5 接入实时运行。

---

## 1. 运行环境、分支提交与外部工具校验和

- **测试日期与记录时间戳**：`2026-11-21`（`reports/m4-budget.txt` 记录时间戳 `2026-11-21T07:04:01Z`）
- **仓库分支与提交**：分支 `m4/cost`，正式记录提交 `e7e1743`（`working tree clean outside reports/`；起点 `d131055`，历经第 1 段 `2d201b7`、`0e39773`、`636fc49`，第 2 段 `60b3a78`、`d61a5e0`、`aa7b3b2`，以及第 3 段 `6bdeebe`、`e7e1743`；第 3 段 worker 在改动未提交工作树上跑的那次自检仅作为过程经过，总调度按分块提交后已在 `e7e1743` 干净工作树上用 `--record` 重录 `reports/m4-budget.txt` 作为正式记录）
- **操作系统与硬件**：macOS arm64（Apple Silicon）
- **隔离措施**：全部验收与回归命令均将 `HOME`、`CFFIXED_USER_HOME`、`RELAY_CLI_HOME` 指向新建临时目录（含 `Library/Preferences`），`PATH` 最前面放置 `claude`、`codex`、`agy`、`vibe`、`opencode` 五个诱饵可执行文件（被调用即写标记文件并以退出码 `99` 失败），产品可执行文件一律经 `<repo>/Scripts/acceptance/relay-cli.sh` 无界面包装器调用，不设 `RELAY_REAL_AGENTS`。

| 组件 | 路径 / 版本 / SHA-256 |
|---|---|
| 产品无界面入口 | `<repo>/Scripts/acceptance/relay-cli.sh` -> `<repo>/.build/debug/RelayIDE`（`20,670,544` bytes / `19.71 MiB`，`sha256=58e1beedf78e2178732b668bd2e30b506c0f875040a1b821ef80a4ee58a3dc6b`） |
| `agent-relay` 主脚本 | `<home>/.agents/skills/agent-relay/scripts/relay.sh`（跑前与跑后 `sha256=bfa2ecaa82f3f8fb33173ccd15079cfd48f62d7e71d98dd56e6d220438204868`） |
| `agent-relay` 辅助脚本 | `<home>/.agents/skills/agent-relay/scripts/relay_util.py`（跑前与跑后 `sha256=4045f18261151d520bf68f5044bd4e30d0fa20d9b64894c4a22cf32b39050629`） |
| 测试替身 | `<repo>/Tests/Support/stub-agent.sh` |
| M3 评估固定解析器 | Python 3.14.9（`RELAY_EVAL_PYTHON`）、TypeScript 5.9.3（`RELAY_EVAL_TYPESCRIPT`）、`mergiraf 0.20.0` |

---

## 2. 三段实现摘要（第 1–3 段）

1. **第 1 段：删除本地回环代理与耦合桌面标签页（提交 `2d201b7`、`0e39773`、`636fc49`）**
   - 移除 `Sources/RelayWiretapProxy/`、`Tests/RelayIDETests/WiretapSSEAndDLPCircuitBreakerTests.swift` 及 `Package.swift` 依赖；从 `RelayStudioViews` / `RelayWorkbenchShell` / `RelayModels` 移除第 5 个标签页 `WiretapBudgetStudioView`、命令面板熔断项与外发脱敏偏好（工作台从 6 栏减为 5 栏）；在 `m0-acceptance.sh` 第 9 行加入代理符号、回环端口 `:43118` 与已删截图零残留检查。
2. **第 2 段：数据库 Schema v7、`LOG.md` 花费汇总与整单预算 `RELAY_BUDGET_USD`（提交 `60b3a78`、`d61a5e0`、`aa7b3b2`）**
   - `RelaySQLiteStore` 与 `RelaySchemaMigrationsAndFTSStore` 升至 Schema v7（`relay_runs` 新增可空列 `budget_usd REAL`，`v5`/`v6` 旧库平滑升级为 `budgetUSD: null`）；`RelayRunRecord` 顶层新增 `budgetUSD`、`totalCostUSD`、`unpricedTokens`、`pricedLaneCount`、`unpricedLaneCount`、`noRecordLaneCount`、`budgetExhausted`；`computeStats()` 与 `BauhausRelayHTMLReportExporter` 改从 `relay_runs` / `relay_run_lanes` 汇总真实花费与 token；`RelayPlanValidator` 校验有限正数 `RELAY_BUDGET_USD`（非法值动盘前退出 `2`）；`RelayDAGRunScheduler` 按已完成通道美元花费向 `relay.sh` 注入剩余额度 `max(0, budget - spentSoFar)`（`%.4f`），识别预算耗尽退出 `2` 并标注 `status: "refused"` 与中英文原因。
3. **第 3 段：`m4-budget.sh` 验收脚本、`milestone 4`、三项变异检查、双语 `README` 与 M4 报告（提交 `6bdeebe`、`e7e1743` 及第 3b 段文档对齐）**
   - 编写 `Scripts/acceptance/m4-budget.sh`（第 1–10 行、`--quick`、`--record` 干净工作树门禁、`--mutation 2/3/4` 临时拷贝编译反证）；在 `Scripts/test.sh` 中新增 `milestone 4` 并接入 `release`（`6bdeebe`）；将 M4 验收结果、测量方法与日期、已完成路线图及四条当前边界写入 `README.md` 与 `README.zh-CN.md`（`e7e1743`）；由总调度在 `e7e1743` 干净工作树上运行 `./Scripts/acceptance/m4-budget.sh --record` 正式重录 `reports/m4-budget.txt`，并在第 3b 段将中英文 `README` 与 `reports/RelayIDE-M4.md` 全部数字对齐至该记录。

---

## 3. 跑的命令和结果

### 3.1 `Scripts/acceptance/m4-budget.sh` 逐行实测结果（第 1–10 行）

完整记录文件：`reports/m4-budget.txt`（由总调度于 `2026-11-21T07:04:01Z` 在提交 `e7e1743` 干净工作树 `working tree clean outside reports/` 上以 `Mode: full` 运行 `./Scripts/acceptance/m4-budget.sh --record` 重录；退出码 **`0`**，构建耗时 `17.77s`，整套总墙钟 `36.09s`。第 3 段 worker 在工作树尚未提交时用 `--record --allow-dirty` 跑过的临时结果已在提交后移走，仅作开发过程说明，不作为证据）。

| 行号 | 检查内容 | 实测结果与关键数据 | 耗时 | 状态 |
|---:|---|---|---:|---|
| **1** | 四家替身运行（`c1` claude `$0.1234`、`v1` vibe `$0.2500`、`a1` agy `4500` tok、`x1` codex `1200` tok）+ `status --run` + `status --runs` + `relay_util.py spent` 独立核对 | `runID=20261121-070402-4d44`；`run`、`status --run`、`status --runs` 退出码均为 `0`，`run` 与 `status --run` 输出 JSON 逐字节相同；`c1.costUSD=0.1234`、`v1.costUSD=0.25`（`$0.2500`）与各自 `<worktree>/.relay/LOG.md` 的 `relay_util.py spent`（`0.123400`、`0.250000`）完全一致；`a1`/`x1` 的 `costUSD` 均为 `null`、`costSource="unpriced"`、`tokens` 为 `4500`/`1200`；顶层 `totalCostUSD=0.3734`、`unpricedTokens=5700`、`pricedLaneCount=2`、`unpricedLaneCount=2`、`noRecordLaneCount=0`、`budgetUSD=null`、`budgetExhausted=false`、`integration.ready=true` | `2.73s` | `PASS` |
| **2** | 对第 1 行同一工程执行不带 `--run` 的 `status --project P` 与中英文 `export-html` | 退出码均为 `0`；中英 `status` 均输出 `schemaVersion=7`、`totalSpendUSD=0.3734`、`totalTokensObserved=5700`；中英 HTML 报告均包含 `$0.3734`、`5700`、`$0.1234`、`$0.2500`、`4500`、`1200`、`unpriced`/`未计价`、`Schema v7`/`架构 v7` 及 4 条通道，且不含 `[DEMO]` / `[演示数据]` | `0.41s` | `PASS` |
| **3** | 链式 `a ($0.30) -> b ($0.25) -> c ($0.10) -> d` 设 `RELAY_BUDGET_USD=0.50`（`--lang en` 与 `--lang zh` 各跑一次） | 两次 `run` 退出码均为 `1`；`a`、`b` 均为 `succeeded` 且有提交；`c` 被 `relay.sh` 拒绝（`status="refused"`、`exitCode=2`、`commitOID=null`、`costUSD=null`、`costSource="no_record"`、`c.trace` 与 `c` 的 `LOG.md` 均不存在，英文 `reason` 为 `'budget spent ($0.5500 / $0.5000); relay: not started: the job budget of $0.0000 is spent ($0.000000 recorded in LOG.md)'`，中文为 `'预算已用完（已花费 $0.5500 / 预算 $0.5000）；relay: not started: the job budget of $0.0000 is spent ($0.000000 recorded in LOG.md)'`）；`d` 为 `skipped`（无 worktree、无 trace）；`integration.status="skipped"`、`ready=false`；顶层 `budgetUSD=0.5`、`totalCostUSD=0.55`、`budgetExhausted=true` | `3.97s` | `PASS` |
| **4** | 充足预算 `RELAY_BUDGET_USD=1.00` 跑 `a ($0.30) -> b ($0.25)` + `verify: "true"` | `run` 退出码 `0`；`a`、`b` 均 `succeeded`；`b.pty` 与 `--max-price`（及 `b.budget`）均记录 `b` 收到剩余额度 `$0.7000`；`integration.status="verified"`、`ready=true`；`budgetUSD=1.0`、`totalCostUSD=0.55`、`budgetExhausted=false` | `1.80s` | `PASS` |
| **5** | 美元通道 `a`（claude `$0.60`）耗尽 `RELAY_BUDGET_USD=0.50` 后接未计价通道 `b`（agy `3000` tokens） | `run` 退出码 `1`；`a` 完成（`costUSD=0.60 >= 0.50`），后续未计价 `agy` 通道 `b` 在启动时同样被 `relay.sh` 拒绝（`status="refused"`、`exitCode=2`、`b.trace` 不存在、`reason` 含 `not started: the job budget`）；`budgetExhausted=true` | `1.42s` | `PASS` |
| **6** | 非法 `RELAY_BUDGET_USD` 参数校验：`0`、`-2.5`、`abc`、`NaN`、`inf`（中英文共 10 次） | 10 次调用退出码全为 `2`、标准输出全为空（`0` 字节）、标准错误指明 `RELAY_BUDGET_USD` 非法；目标仓库仅保留 `main` 分支与 1 个主 worktree，`.relayproj` 无 `runs/` 目录、`status --runs` 为 `[]`、替身 trace 目录为空（零磁盘/Git/SQLite 副作用） | `1.20s` | `PASS` |
| **7** | 删代理代码洁净度与默认空启动花费核查 | 已删路径（`Sources/RelayWiretapProxy`、旧代理单测、两张 Wiretap 演示截图）均不存在；`Package.swift`、`Sources/`、`README.md`、`README.zh-CN.md` 中旧代理模块名、服务器类名、回环端口 `:43118` 与外发脱敏短语匹配数全为 `0`；空工作区 `status` 与无界面 `StudioViewModelAndHonestyTests/defaultInitWithoutDemoIsCompletelyEmpty` 单测均退出 `0` 且花费为 `0` | `4.45s` | `PASS` |
| **8** | 数据库升级兼容：直接用 `sqlite3` 建真实 Schema v6 旧库（`max_version=6`、无 `budget_usd` 列，含历史运行 `$0.042` + `1800` tok），再用当前构建执行 `status` 与新 `run` | 打开后平滑迁移至 Schema v7（`schema_migrations` 为 `[1..7]`，物理列 `budget_usd` 已添加）；历史运行 `20261117-120000-0006` 的 `budgetUSD` 为 `null`、`totalCostUSD=0.042`、`unpricedTokens=1800` 原样保留；随后设 `RELAY_BUDGET_USD=0.80` 跑新通道 `fresh`（`$0.15`）退出 `0`、写入第 2 条运行（`budgetUSD=0.8`），工作区累计 `totalSpendUSD=0.192` | `1.37s` | `PASS` |
| **9** | 跑后环境卫生检查（全套单测与跨里程碑回归在 `Scripts/test.sh` 中串联） | 诱饵标记文件不存在（`0` 次触发）；临时目录关联残留进程数 `0`；宿主机 `~/Library/Preferences` 无变化；`relay.sh` 与 `relay_util.py` SHA-256 未变；工作树 `git status` 未变 | `0.20s` | `PASS` |
| **10** | 只记录指标：各行耗时、`relay.sh` / `relay_util.py` SHA-256、测试二进制体积与校验和 | 已写入 `reports/m4-budget.txt`（构建 `17.77s`，总耗时 `36.09s`，`<repo>/.build/debug/RelayIDE` 体积 `20,670,544` bytes / `19.71 MiB`，`sha256=58e1beedf78e2178732b668bd2e30b506c0f875040a1b821ef80a4ee58a3dc6b`，`relay.sh` 与 `relay_util.py` 结束 SHA-256 与跑前一致） | - | `RECORD` |

此外，`Scripts/acceptance/m4-budget.sh --record` 在未提交工作树上不带 `--allow-dirty` 运行时按预期以退出码 **`2`** 拒绝写入 `reports/`；`Scripts/acceptance/m4-budget.sh --quick` 以退出码 **`0`** 在 `<= 120s` 预算内完成快速冒烟检查（`passed=6, skipped=5`）。

### 3.2 全量单元测试与 `milestone 0..4` / README 回放验证汇总

仓内仅 `reports/m4-budget.txt` 为正式录制文件（耗时与指标以第 3.1 节为准）；其余回归与变异命令不单独落盘录制件，下表仅保留每次运行恒定的退出码与断言结果：

| 命令 | 退出码 | 关键输出与断言结果 |
|---|---:|---|
| `./Scripts/acceptance/m4-budget.sh --record` | `0` | `ALL M4 BUDGET ACCEPTANCE CHECKS PASSED (Rows 1..9 hard checks + Row 10 recorded; total=36.09s)`，于提交 `e7e1743` 干净工作树写入 `reports/m4-budget.txt`（构建 `17.77s`） |
| `./Scripts/acceptance/m4-budget.sh --quick` | `0` | `ALL M4 QUICK ACCEPTANCE CHECKS PASSED`（`passed=6, skipped=5`，满足 `<= 120s` 预算） |
| `./Scripts/acceptance/m4-budget.sh --mutation 2` | `0` | `[PASS] M4-Mut-2 CAUGHT: inner m4-budget.sh exited 1 with [FAIL] Row 3; working tree untouched` |
| `./Scripts/acceptance/m4-budget.sh --mutation 3` | `0` | `[PASS] M4-Mut-3 CAUGHT: inner m4-budget.sh exited 1 with [FAIL] Row 1; working tree untouched` |
| `./Scripts/acceptance/m4-budget.sh --mutation 4` | `0` | `[PASS] M4-Mut-4 CAUGHT: inner m4-budget.sh exited 1 with [FAIL] Row 2; working tree untouched` |
| `swift test --no-parallel` | `0` | 7 个测试套件共 201 个测试全部通过（诱饵 `0` 触发） |
| `./Scripts/test.sh milestone 0` | `0` | M0 范围单测 + `m0-acceptance.sh` + `readme-commands.sh` 全部通过，工作树不变 |
| `./Scripts/test.sh milestone 1` | `0` | M1 范围单测 + `m0` + `readme-commands` + `m1-run.sh`（Rows 1..25, 29, 30）全部通过，工作树不变 |
| `./Scripts/test.sh milestone 2` | `0` | M2 范围单测 + `m0` + `readme-commands` + `m1` + `m2-merge.sh`（31 项）全部通过，工作树不变 |
| `./Scripts/test.sh milestone 3` | `0` | M3 范围单测 + `m0` + `m3-merge-eval.sh --quick`（`<= 120s`）全部通过，工作树不变 |
| `./Scripts/test.sh milestone 4` | `0` | M4 五模块范围单测（140 个 `@Test`）+ 构建 + `m4-budget.sh` 全部通过，工作树不变 |
| `./Scripts/acceptance/readme-commands.sh` | `0` | 中英 `README` 4 个代码块共 24 条命令一一对应、`README & README.zh-CN COMMANDS: SAME IN BOTH FILES, ALL RUNNABLE ONES EXITED 0` |
| `python3 -I Scripts/eval/**/test_*.py`（6 套） | `0` | `test_classify`、`test_extract`、`test_report`、`test_run_published`、`test_run_mergiraf`、`test_run_engine` 全部 `OK` |

---

## 4. 变异检查结果（`M4-Mut-2`、`M4-Mut-3`、`M4-Mut-4`）

三项变异均通过 `Scripts/acceptance/m4-budget.sh --mutation <2|3|4>` 在 `mktemp -d` 独立临时包拷贝中打补丁、编译变异二进制并经 `RELAY_CLI_BIN` 运行完整 `m4-budget.sh`，完全不触碰仓库源码与 `.build`，跑前跑后核验 `git status --porcelain` 逐字一致：

1. **`M4-Mut-2`（跨通道预算不扣减已完成花费）**：
   - **补丁位置**：`Sources/RelayOrchestrator/RelayDAGRunScheduler.swift` 将 `let remaining = max(0.0, jobBudget - spentBeforeSpawn)` 改为 `let remaining = jobBudget`（把整单 `RELAY_BUDGET_USD` 原样透传给每个子 worktree）。
   - **实测结果**：内部 `m4-budget.sh` 以**退出码 `1` 失败**，**第 3 行、第 4 行、第 5 行同时变红**（`passed=6, failed=3`：第 3 行通道 `c` 未被拒、第 4 行通道 `b` 未收到扣减后的 `$0.7000`、第 5 行未计价 `agy` 通道 `b` 未被拒），外层断言捕获成功并退出 `0`。
2. **`M4-Mut-3`（未计价通道 `costUSD` 写成 `0.0`）**：
   - **补丁位置**：`Sources/RelayOrchestrator/RelayDAGRunScheduler.swift` 将 `RelayLogSpendParser` 中 `"unpriced"` 分支的 `costUSD: nil` 改为 `costUSD: 0.0`。
   - **实测结果**：内部 `m4-budget.sh` 以**退出码 `1` 失败**，**第 1 行与第 2 行同时变红**（`passed=7, failed=2`：第 1 行断言 `a1.costUSD is None` 捕获到 `0.0` 失败；第 2 行 HTML 报告将未计价通道渲染成 `$0.0000` 而非 `unpriced` / `未计价` 失败），外层断言捕获成功并退出 `0`。
3. **`M4-Mut-4`（工作区汇总数据源改回读空的 `wiretap_spans`）**：
   - **补丁位置**：`Sources/RelayWorkspaceStore/RelaySQLiteStore.swift` 将 `RelayProjectDatabase.computeStats()` 的 `SELECT COALESCE(SUM(cost_usd), 0.0) FROM relay_run_lanes;` 改回 `SELECT COALESCE(SUM(cost_usd), 0.0) FROM wiretap_spans;`（返回 `0.0`）。
   - **实测结果**：内部 `m4-budget.sh` 以**退出码 `1` 失败**，**第 2 行与第 8 行变红**（`passed=7, failed=2`：第 1 行单次运行台账仍通过，第 2 行 `status --project` 与 `export-html` 报 `$0.0000` != `$0.3734` 立即失败，第 8 行升级后工作区汇总报 `0.0` != `0.042` 亦失败），外层断言捕获成功并退出 `0`。
