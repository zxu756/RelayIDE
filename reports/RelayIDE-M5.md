# RelayIDE M5 界面显示真实运行里程碑报告

## RelayIDE M5 报告

- **做了什么：** 基于 M4 收尾提交 `a4654e4` 在分支 `m5/ui` 上分三段完成 M5「界面显示真实运行」全部功能实现、收紧数字来源审计与无窗口端到端验收（未推送、未打 tag、未合并）：第 1 段（`ad2b7ef`、`97d2f00`）新增只读实时工作区观察器 `RelayLiveWorkspaceObserver`（`FSEvents` + `kqueue` 增量读取各通道 `<worktree>/.relay/NN-<agent>.log` 喂入 `VT100TerminalScreenBuffer`，无日志通道回退读取 `lanes/<lane>.pty`，监听 `workspace.sqlite-wal` 刷新状态/退出码/耗时/四位小数花费与未计价 token），清理非演示模式下空加速比 `1.00x`、`96x26`、`/ $0.00` 与护栏默认策略数字（`⌘5` 显示「护栏插件 · 未接入」），禁用非演示广播输入栏；第 2 段（`36d3f7f`、`95a1cf3`）新增只读 `RelayReadOnlyGitRunInspector` 与 `RelayWorktreeOwnershipLiveWatcher`（`FSEvents` 驱动 `git diff --no-renames --name-only -z <startCommitOID>` 并集未跟踪文件、排除 `.relay/` 与 `.git/`），接通 `⌘4` 文件归属实时视图、`⌘3` M2 真实合并与 `git merge-file -p` 只读冲突还原视图（彻底删除 R74 死开关 `autoRunSemanticMergeOnHandoff` 与写死 `18`/`24` 证据）、`⌘2` 真实运行依赖与实测时序 DAG，并使 `RelayRetinaScreenshotExporter` 支持传入真实 `.relayproj`；第 3 段编写 `Scripts/acceptance/m5-ui.sh`（覆盖第 1–9 行、`--quick`、`--record [--allow-dirty]` 与 `--mutation 1..6`），按完整数字 token 与 11 项关键字段逐值相等双重规则收紧第 6 行数字来源核查（堵住提交哈希/运行编号子串放过 `lanes + 7` 的漏洞），接入 `Scripts/test.sh milestone 5` 与 `release`，并同步更新双语 `README` 与 `m0-acceptance.sh` 首段断言。
- **跑的命令和结果：**
  - `Scripts/acceptance/m5-ui.sh`（第 3 段在未提交工作树上的完整运行输出保存在 `scratch/m5_03/logs/closing_01_m5_ui_full.log`，待总调度按分块提交后在干净工作树上用 `./Scripts/acceptance/m5-ui.sh --record` 正式生成 `reports/m5-ui.txt`）：退出码 **`0`**，第 1–8 行硬性检查全部 `[PASS]`、第 9 行指标完整输出（增量构建 `5.69s`，总墙钟 `46.64s`，第 1 行逐行流式最大延迟 `0.155s < 1.0s`，第 3 行四通道结束至全界面 PDF 更新延迟 `0.385s < 2.0s`，第 4 行手工改已跟踪/新建未跟踪文件至 PDF 刷新延迟 `0.083s` / `0.084s < 2.0s`；全程 `NSApplication.shared.windows.count == 0`，诱饵触发 `0` 次，`relay.sh` 与 `relay_util.py` SHA-256 前后不变）。
  - `Scripts/acceptance/m5-ui.sh --quick`（`scratch/m5_03/logs/closing_02_m5_ui_quick.log`）：退出码 **`0`**（总耗时 `16.48s`，运行第 1、4、6[EN]、7、8、9 行并显式列出跳过的 4 项）。
  - 六条临时副本变异检查 `Scripts/acceptance/m5-ui.sh --mutation 1..6`（`scratch/m5_03/logs/closing_03_mut_1..6.log`）：6 次外层退出码全为 **`0`**，内部对变异副本运行对应验收行均以退出码 **`1`** 失败并精准命中目标行（变异 1 -> `Row 1`、变异 2 -> `Row 3`、变异 3 -> `Row 4`、变异 4 -> `Row 5`、变异 5 -> `Row 6`、变异 6 -> `Row 6`），临时副本自动清理且工作树不变。
  - 全量隔离单测与跨里程碑回归：`Scripts/test.sh milestone 5`、`Scripts/test.sh milestone 0`、`Scripts/acceptance/m1-run.sh --quick`、`Scripts/acceptance/readme-commands.sh` 及 `swift test --no-parallel`（10 个测试套件共 214 个 `@Test`）全部退出码 **`0`**，全程 `0` 个桌面窗口。
- **没验证的项和原因：**
  - **全量级真实付费 agent CLI 运行（`RELAY_REAL_AGENTS=1 RELAY_BUDGET_USD=2 Scripts/test.sh release`）：** 按总则第 4 节规定，真实调用付费 coding agent CLI 仅在发版前经用户批准运行；本里程碑全程通过 `Scripts/acceptance/relay-cli.sh`、复制到临时目录的真实 `relay.sh` / `relay_util.py` 与 Python 替身 agent 验证，诱饵门卫确认真实 `claude`、`codex`、`agy`、`vibe` 调用次数为 `0`。
  - **真实运行的桌面截图替换（`docs/screenshot-*.png`）：** 按 2026-11-22 用户拍板第 1 件（选项 C）及总则规则 11，本里程碑全程严禁打开任何窗口或运行 `--export-screenshots`，`docs/` 下现有 6 张 PNG 保持不变并在双语 `README` 中明确说明其由 `--demo` 演示数据合成，真实运行的截图留到发版前跑真实付费 agent 时人工截取（`RelayRetinaScreenshotExporter` 已接入真实 `--project` 参数并经无窗口单测覆盖）。
  - **干净工作树上的 `--record` 正式录制件（`reports/m5-ui.txt`）：** 按第 3 段分工指令，worker 不执行 `git commit` 亦不运行 `--record`，留待总调度提交各分块后在干净工作树（`working tree clean outside reports/`）上执行 `./Scripts/acceptance/m5-ui.sh --record` 录制。
- **待验证的假设里，哪些已证实、哪些被推翻：**
  - **无窗口 `ImageRenderer`（矢量 PDF 文本提取 + `2720x1680` `CGImage` 位图采样）配合 `RelayStudioViewModel` 可在不触发任何 `NSWindow` 的前提下端到端验证界面绑定与光栅化：** 实测证实成立（在 `NSApplication.ActivationPolicy.prohibited` 下完成 `70` 次跨面板/抽屉/弹窗双语矢量 PDF 渲染与 `15` 次 `2720x1680` 位图渲染，全程 `NSApplication.shared.windows.count == 0`，独立 RGB 色值 `>= 28`）。
  - **只读 `<runs>/<runID>/lanes/<lane>.pty` 能否满足运行中逐行流式显示：** 实测被推翻（`relay.sh` 运行期间将 agent 实时输出写入 `<worktree>/.relay/NN-<agent>.log`，结束时才向 `.pty` 打印汇总；变异 1 强制只读 `.pty` 后第 1 行立即因运行期间无流式行变红，证实必须优先增量读取 `.relay/NN-<agent>.log` 并对无日志拒绝通道回退 `.pty`）。
  - **子串/宽松集合核对能否拦截小整数篡改（如 DAG 通道数 `+ 7`）：** 实测被推翻（第 3 段红灯实验 `scratch/m5_03/logs/step1a_red_mut5_old_check.log` 证实，若将十六进制提交号/`runID`/`LOG.md` 时间戳拆成数字段放入真值集，四通道运行上 `4 + 7 = 11` 会混过第 6 行；改为「整串标识符消解 + 完整数字 token 比较 + 11 项关键字段逐项与 SQLite/`.relay/LOG.md`/只读 Git 输出比相等」后，变异 5 在第 6 行稳定变红）。
- **删掉或冻结的代码：**
  - **删除：** 删除 `RelayPreferencesModalView` 与 `RelayUserPreferencesSnapshot` 中的 R74 死开关 `autoRunSemanticMergeOnHandoff`，删除 `RelayStudioViewModel.resolveConflictChunk` 中写死的 `passedTestCount: 18` / `24` 证据及按钮文案中的 `18/18`；移除非演示模式下的 `96x26`、`1.00x`、`/ $0.00` 及护栏默认数字。
  - **冻结 / 仅演示保留：** 交互式三路 AST 冲突裁决、`2.5D` 等轴测耦合塔与 `JavaScriptCore` 护栏策略演练台严格限制在显式 `--demo` 模式下展示，非演示产品路径只做 M1/M2/M4 运行数据的只读实时观察，且禁用广播输入栏。

---

## 1. 运行环境、分支提交与外部工具校验和

- **测试日期与日志时间戳**：`2026-11-22`（完整运行日志 `scratch/m5_03/logs/closing_01_m5_ui_full.log` 记录时间戳 `2026-11-22T11:09:58Z`）
- **仓库分支与提交**：分支 `m5/ui`，第 3 段起点提交 `95a1cf3`（历经第 1 段 `ad2b7ef`、`97d2f00` 与第 2 段 `36d3f7f`、`95a1cf3`；第 3 段改动保留在工作树供总调度分块提交后重录 `reports/m5-ui.txt`）
- **工具链与系统**：macOS arm64（Apple Silicon），`/Applications/Xcode.app/Contents/Developer`（`Xcode 27.2`, `Build version 27B52`）
- **安全与零窗口隔离措施**：所有产品 CLI 命令一律经 `<repo>/Scripts/acceptance/relay-cli.sh` 调用；每次运行新建临时 `HOME`（含 `Library/Preferences`），将真实 `relay.sh` 与 `relay_util.py` 复制到 `mktemp -d` 并通过 `RELAYIDE_RELAY_SH` 指向副本，`PATH` 最前放置 `claude`、`codex`、`agy`、`vibe`、`opencode` 五个诱饵可执行文件，卸载 `RELAY_REAL_AGENTS` / `RELAY_WORKER` / `AGY_CODER_WORKER` / `CLAUDECODE`；所有界面检查均在 `@MainActor` 下设 `NSApplication.shared.setActivationPolicy(.prohibited)` 并断言 `NSApplication.shared.windows.isEmpty`。

| 组件 | 路径 / 版本 / SHA-256 |
|---|---|
| 产品无界面入口 | `<repo>/Scripts/acceptance/relay-cli.sh` -> `<repo>/.build/debug/RelayIDE`（第 3 段实测构建 `22,719,728` bytes / `21.67 MiB`，`sha256=5b35fbae7d91ca74ef16282c9104b93311c6e488b817d03cfa21315c68556091`） |
| 无窗口 UI 验收探针与审计器 | `<repo>/Tests/RelayIDETests/M5UIAcceptanceTests.swift`（`ImageRenderer` 矢量 PDF + `2720x1680` `CGImage` + `M5NumberProvenanceAndFieldAuditor`） |
| `agent-relay` 主脚本 | `<home>/.agents/skills/agent-relay/scripts/relay.sh`（跑前与跑后 `sha256=bfa2ecaa82f3f8fb33173ccd15079cfd48f62d7e71d98dd56e6d220438204868`） |
| `agent-relay` 辅助脚本 | `<home>/.agents/skills/agent-relay/scripts/relay_util.py`（跑前与跑后 `sha256=4045f18261151d520bf68f5044bd4e30d0fa20d9b64894c4a22cf32b39050629`） |

---

## 2. `Scripts/acceptance/m5-ui.sh` 逐行实测结果（第 1–9 行）

完整运行日志：`scratch/m5_03/logs/closing_01_m5_ui_full.log`（`Mode: full`，退出码 **`0`**，增量构建 `5.69s`，总耗时 `46.64s`；正式干净工作树记录将由总调度提交后通过 `./Scripts/acceptance/m5-ui.sh --record` 写入 `reports/m5-ui.txt`）。

| 行号 | 检查内容 | 实测结果与关键数据（引自 `closing_01_m5_ui_full.log`） | 耗时 | 状态 |
|---:|---|---|---:|---|
| **1** | 两条并行通道（`claude` + `vibe` 替身各每秒打印 1 行，共 4 行）实时伪终端流式显示（修 R7） | 两格按秒逐行递增显示第 `1..4` 行（非结束后一次性刷出），每行从发出到进入 `terminalSnapshotsByLane` 最大延迟 `0.155s < 1.0s`（`lane-claude`: `0.155s, 0.064s, 0.004s, 0.091s`；`lane-vibe`: `0.153s, 0.060s, 0.004s, 0.092s`），运行中途与结束后的 `ImageRenderer` PDF 均与各自 `<worktree>/.relay/01-<agent>.log` 一致，`windows=0` | `6.53s` | `PASS` |
| **2** | 预算拒绝等无 `.relay/*.log` 通道的输出与原因回退显示 | 设 `RELAY_BUDGET_USD=0.20` 跑 `a ($0.30) -> b`（`run` 退出 `1`），确认 `b` 无 `.relay/*.log`；界面通道列表与 `b` 终端格在中英文 PDF 下准确渲染 `status=refused`、`exitCode=2`（`exit 2` / `退出码 2`）及 `lanes/b.pty` 中的 `not started: the job budget` 拒绝信息，`windows=0` | `3.22s` | `PASS` |
| **3** | 四通道结束状态、退出码、耗时、四位小数花费与未计价 token 在 `< 2.0s` 内更新 | `c1`（`$0.1234`）、`v1`（`$0.2500`，`exit 3`）、`a1`（`4500` tok 未计价）、`x1`（`1200` tok 未计价）各通道退出到 ViewModel 更新延迟分别为 `c1=0.422s, v1=0.169s, a1=0.373s, x1=0.173s`，全界面 PDF 渲染出 `$0.3734`、`exit 3`、`4500`/`1200` 未计价（无 `/ $0.00` 与 `$0.00`）延迟 `0.385s < 2.0s`，`windows=0` | `2.57s` | `PASS` |
| **4** | 文件归属视图（`⌘4`）经 worktree `FSEvents` 在 `< 2.0s` 内实时刷新 | 在 `lane-own-a` worktree 中手工修改已跟踪 `App.swift`（ViewModel `0.056s`、PDF `0.083s < 2.0s`）并新建未跟踪 `ManualOwnershipProbe.swift`（ViewModel `0.057s`、PDF `0.084s < 2.0s`），已提交文件 `AlphaOwned.swift` 完整保留，同步写入的 `.relay/99-noise.log` 与 `.git/` 被严格排除，`windows=0` | `3.71s` | `PASS` |
| **5** | 合并视图（`⌘3`）显示 M2 真实集成结果与 `git merge-file -p` 冲突内容（修 R74） | ① 干净合并工程中英 PDF 显示 `verified`、`ready: true`、逐步 `mergeCommitOID` 与 `verify.pty` 输出（无交互式 AST 按钮）；② 冲突工程中英 PDF 显示 `conflict`、`ready: false`、`UU App.swift` 及与独立 `/usr/bin/git merge-file -p` 逐行一致的 `<<<<<<< integration` / `=======` / `>>>>>>>` 冲突块；全仓 `Sources/` 扫描 R74 残留为 `0`，`windows=0` | `6.83s` | `PASS` |
| **6** | 收紧后的非演示模式数字来源核查与关键字段逐项相等核对 + `--demo` 隔离 | 遍历默认空启动、空 `init` 工程、四通道运行工程、干净合并工程、冲突工程在中英双语下全部 `5` 个面板 + 底部抽屉 + `⌘,` 偏好弹窗共 `70` 次矢量 PDF 渲染：无来源数字 `0` 个，11 类关键字段逐项与 SQLite / `.relay/LOG.md` / 只读 Git 输出不一致项 `0` 个；显式 `--demo` 正常渲染 `[DEMO]`/`[演示数据]` 且空用户工程保持 `0` 通道 / `$0` 花费，`windows=0` | `14.51s` | `PASS` |
| **7** | `2720x1680` `ImageRenderer` 光栅化完整性与零弹窗/零残留进程检查 | 空状态、真实运行、演示模式共 `15` 张 `CGImage` 尺寸全为 `2720x1680`、最小独立 RGB 色值数 `28 >= 8`（非空白），`NSApplication.windows=0`，`relay-cli.sh --relay-cli-running-processes` 残留进程数 `0` | `2.73s` | `PASS` |
| **8** | 跑后环境卫生检查 | 诱饵 CLI 触发 `0` 次；临时目录残留进程 `0`；宿主机 `~/Library/Preferences` 无变化；真实 `relay.sh` 与 `relay_util.py` SHA-256 未变；工作树 `git status` 前后一致 | `0.12s` | `PASS` |
| **9** | 只记录指标 | 输出构建耗时、各行耗时、流式/完成/归属延迟指标、`relay.sh` / `relay_util.py` SHA-256 与可执行文件体积/校验和（仅 `--record` 时写入 `reports/m5-ui.txt`） | - | `RECORD` |

此外，`./Scripts/acceptance/m5-ui.sh --quick`（`scratch/m5_03/logs/closing_02_m5_ui_quick.log`）以退出码 **`0`** 在 `16.48s` 内通过（`passed=5, skipped=4`，显式打印跳过的 `Row 2`、`Row 3`、`Row 5` 与 `Row 6 --lang zh`）；未提交工作树上不带 `--allow-dirty` 运行 `--record` 按预期以退出码 **`2`** 拒绝改写 `reports/m5-ui.txt`。

---

## 3. 六条变异检查结果（`M5-Mut-1` 至 `M5-Mut-6`）

六条变异均由 `Scripts/acceptance/m5-ui.sh --mutation <1..6>` 在 `mktemp -d` 独立临时包副本中修改源码、独立构建、仅针对目标验收行执行内部 `m5-ui.sh`，验证目标行 `[FAIL]` 且内部脚本以非零退出码（`1`）结束后立即删除临时副本，并核验仓库 `git status --porcelain` 前后逐字不变（日志：`scratch/m5_03/logs/closing_03_mut_1.log` 至 `closing_03_mut_6.log`）：

| 变异编号 | 临时副本补丁位置与内容 | 预期变红行 | 内部 `m5-ui.sh` 结果 | 外层判定与耗时 |
|---|---|---|---|---|
| **`M5-Mut-1`** (`--mutation 1`) | `RelayLiveWorkspaceObserver.swift` 将 `readRelayStepLogs` 默认值由 `true` 改为 `false`（只读 `lanes/<lane>.pty`，不读 `<worktree>/.relay/*.log`） | 第 `1` 行 | 退出码 `1`，`[FAIL] Row 1`（运行期间 `0` 行流式输出） | `[PASS] M5-Mut-1 CAUGHT`（`24.76s`） |
| **`M5-Mut-2`** (`--mutation 2`) | `RelayLiveWorkspaceObserver.swift` 将 `observeDatabaseChanges` 默认值由 `true` 改为 `false`（去掉对 `workspace.sqlite-wal` 的监听回调） | 第 `3` 行 | 退出码 `1`，`[FAIL] Row 3`（四通道结束后 `< 2.0s` 内未更新状态与花费） | `[PASS] M5-Mut-2 CAUGHT`（`44.21s`） |
| **`M5-Mut-3`** (`--mutation 3`) | `RelayReadOnlyGitRunInspector.swift` 注释掉 `RelayWorktreeOwnershipLiveWatcher` 的 `recomputeLanesOnQueue(laneIDs: dirtyLanes, forceEmit: false)` | 第 `4` 行 | 退出码 `1`，`[FAIL] Row 4`（手工修改与新建文件未在 `< 2.0s` 内刷新到 `⌘4`） | `[PASS] M5-Mut-3 CAUGHT`（`31.97s`） |
| **`M5-Mut-4`** (`--mutation 4`) | `RelayReadOnlyGitRunInspector.swift` 在冲突还原分支令 `conflictText = nil`（不调用 `git merge-file -p`） | 第 `5` 行 | 退出码 `1`，`[FAIL] Row 5`（缺失 `<<<<<<< integration` 冲突块文本） | `[PASS] M5-Mut-4 CAUGHT`（`24.52s`） |
| **`M5-Mut-5`** (`--mutation 5`) | `PTYMultiplexerAndDAGViews.swift` 将非演示 DAG 顶栏 `run.lanes.count` 改为 `run.lanes.count + 7` | 第 `6` 行 | 退出码 `1`，`[FAIL] Row 6`（旧核查在 `step1a_red_mut5_old_check.log` 中放过 `11`，收紧后同时被完整数字差集与 DAG 通道数字段核对抓红） | `[PASS] M5-Mut-5 CAUGHT`（`26.44s`） |
| **`M5-Mut-6`** (`--mutation 6`) | `RelayMainWindowAndScreenshotExporter.swift` 在非演示顶栏拼入无来源常数 `1.00× · 15000` | 第 `6` 行 | 退出码 `1`，`[FAIL] Row 6`（捕获无来源常数 `1.00` 与 `15000`） | `[PASS] M5-Mut-6 CAUGHT`（`26.45s`） |
