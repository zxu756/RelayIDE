# RelayIDE

**English** | **[简体中文](README.zh-CN.md)**

**macOS Workbench & Workspace Store for Multi-Agent Relay Workflows**

`RelayIDE` is a native macOS CLI, SQLite workspace store, MCP utility, and SwiftUI workbench built on top of `agent-relay` (`relay.sh`; you must install `agent-relay` first). **Current status (M5): `RelayIDE run` launches headless coding agents (`claude`, `codex`, `agy`, `vibe`) in isolated Git worktrees via `agent-relay`, commits `succeeded` or `partial` lanes to their own branches, and when all lanes succeed with changes, merges them in deterministic order onto `relay/<run-id>/integration` via `git merge --no-ff` (cleanly aborting and stopping on conflict) and runs optional `verify` in a POSIX PTY without modifying `base`; merge readiness is determined solely by `integration.ready` in the JSON output (`true` only when all lanes succeeded and integration status is `verified`). Spend (`claude`, `vibe` in USD; `codex`, `agy` as unpriced token counts) is read directly from each lane's `.relay/LOG.md`, aggregated in `status` and `export-html`, and gated across lanes by an optional whole-job USD budget (`RELAY_BUDGET_USD`, where parallel lanes in the same wave share the remaining budget at launch and may overshoot within that wave before the next wave is refused). The desktop UI is now a read-only live view of CLI runs: the PTY terminal grid (`⌘1`), DAG (`⌘2`), merge & conflict results (`⌘3`), and file ownership (`⌘4`) panes read real run data (`<worktree>/.relay/NN-<agent>.log` with `<lane>.pty` fallback, SQLite run ledgers, `git merge-file -p` conflict blocks, and `FSEvents`-triggered `git diff --name-only` + untracked files), the Guardrail Plugins pane (`⌘5`) shows `Not Connected` in non-demo mode, runs are started from the CLI, and non-demo mode has no broadcast input bar. Existing screenshots in `docs/` are rendered from `--demo` synthetic data; real-run screenshots are deferred to manual capture when running real agents before release. This version never merges into `base` and rejects multi-predecessor lanes.**

![RelayIDE Synthetic Demo Preview](docs/screenshot-pty-grid.png)
*Figure 1 (`[DEMO]`): Synthetic 4-lane preview rendered with `--demo` (`--export-screenshots`; real-run screenshots are deferred to manual capture during pre-release real-agent verification). Launching `RelayIDE` without `--demo` opens an empty workspace (`0` lanes, no terminal transcripts, no spend figures), or observes an existing `.relayproj` live when passed `--project <dir>`.*

---

## What Works Today (M5)

- **Headless Multi-Agent Worktree Runner, Merge Pipeline, Spend Ledger & Whole-Job Budget (`run`, `status`)**: `RelayIDE run <plan.json> --project <dir> [--relay-sh <path>] [--lang zh|en]` executes a multi-lane plan on a real Git repository through `agent-relay` (`relay.sh`, resolved from `--relay-sh`, `RELAYIDE_RELAY_SH`, or `~/.agents/skills/agent-relay/scripts/relay.sh` alongside `relay_util.py`), merges completed lanes onto a dedicated integration branch, and runs optional verification.
  - **Validation & locking.** Validates `plan.json` before touching disk or Git refs: top-level keys restricted to `repo`, `base`, `lanes`, optional `verify` (string), and optional `verify_timeout` (integer seconds `1...86400`, default `1800`; rejected with exit `2` if non-integer, out of range, or given without a non-empty `verify`); lane keys restricted to `id` (`^[a-z0-9][a-z0-9-]{0,39}$`, with `integration` reserved for the integration branch), `agent` (`claude`, `codex`, `agy`, `vibe`), `prompt`, and optional `after` (at most one predecessor per lane; multi-predecessor lanes are still unsupported and rejected with exit `2`); unknown JSON fields rejected with exit `2` naming the field; acyclicity; configured repository Git `user.name` and `user.email`; `--project` existing outside the repository working tree; optional `RELAY_BUDGET_USD` (unset or empty means no whole-job cap; when non-empty it must be a finite positive number in USD, otherwise `run` exits `2` before touching disk); `RELAY_WORKER` unset (exit `125`). Acquires a non-blocking `flock` on `<project>/run.lock` and resolves `base` once to an immutable commit OID.
  - **Repository hooks skipped (`-c core.hooksPath=/dev/null`).** Every Git write performed by `RelayIDE` itself (creating lane worktrees, committing lane changes, creating the integration worktree, and running `git merge --no-ff`) passes `-c core.hooksPath=/dev/null` so all repository Git hooks (`post-checkout`, `pre-commit`, `prepare-commit-msg`, `commit-msg`, `post-commit`, `pre-merge-commit`, `post-merge`, etc.) are skipped, and commit messages explicitly note `"repository hooks skipped"`. Put repository checks and any required worktree setup in `verify`.
  - **Lane execution, PTY transcripts & commits.** Serially creates isolated worktrees at `<project>/runs/<run-id>/worktrees/<lane>` on new branches `relay/<run-id>/<lane>` (`git worktree add -b`, never resetting existing branches), runs `<relay.sh> <agent> <worktree> <prompt>` inside a POSIX PTY, and appends PTY master bytes to `<project>/runs/<run-id>/lanes/<lane>.pty` (this `.pty` file is a PTY terminal transcript where the PTY line discipline translates `\n` to `\r\n`, not byte-for-byte program output; raw agent CLI output is written by `relay.sh` to `<worktree>/.relay/NN-<agent>.log`). Independent lanes start immediately; a single-predecessor lane starts from its predecessor's committed branch head as soon as that predecessor finishes `succeeded` or `succeeded-no-changes`, and is marked `skipped` without creating a worktree or branch otherwise. `succeeded` and `partial` lanes commit their changes (`-c core.hooksPath=/dev/null`, `--no-verify`, `--no-gpg-sign`, excluding `.relay/`) using the repository's configured Git identity (`succeeded` without changes becomes `succeeded-no-changes` with `commitOID: null`); failed, timed-out, refused, cancelled, or killed lanes are not committed and record their uncommitted file list.
  - **Sequential integration merge (`git merge --no-ff`) & conflict handling.** Merging starts only after all lanes finish, and only when the run was not cancelled, `RelayIDE` encountered no internal error, and every lane finished `succeeded` or `succeeded-no-changes`:
    - If any lane finished non-succeeded (`failed`, `timeout`, `partial`, `refused`, `skipped`, `cancelled`, `killed`), no lanes are merged: `integration.status` is `skipped` (naming the non-succeeded lanes and their statuses), no integration branch or worktree is created, `verify` does not run, and `run` exits `1`.
    - If every lane finished `succeeded-no-changes` (no commits to merge), `integration.status` is `nothing-to-merge`, no integration branch or worktree is created, `verify` does not run, and `run` exits `0`.
    - Otherwise `RelayIDE` creates branch `relay/<run-id>/integration` at `<project>/runs/<run-id>/worktrees/integration` from the resolved `base` commit OID (`git worktree add -b`, never modifying `base` or the main working tree) and merges lane `commitOID`s in deterministic topological order, breaking ties by `plan.json` order (for example `[b(after a), c, a]` merges as `c, a, b`). Lanes with `commitOID: null` or already ancestor of `HEAD` record `no-changes` without invoking `git merge`. Each merge runs `git merge --no-ff --no-edit --no-log --no-stat --no-squash --no-autostash --no-verify-signatures --no-gpg-sign` (with `-c core.hooksPath=/dev/null -c rerere.enabled=false -c gc.auto=0 -c maintenance.auto=false -c user.useConfigOnly=true`) and verifies two parents (`HEAD^1` and `HEAD^2`).
    - On the first merge conflict (non-zero exit with `MERGE_HEAD`), `RelayIDE` stops immediately: it records unmerged `git status --porcelain=v1 -z` items (`path` and two-letter `code` such as `UU`, `AA`, `UD`, `DU`) and `CONFLICT (...)` lines, runs `git merge --abort`, verifies `HEAD`, absence of `MERGE_HEAD`, and empty `git status --porcelain=v1 -uall --ignored`, marks that lane `conflict` and remaining lanes `not-attempted`, sets `integration.status = "conflict"` and `ready = false`, skips `verify`, and exits `1`. Non-conflict `git merge` errors (no `MERGE_HEAD`) do not run `--abort`, record `integration.status = "error"`, and exit `125`.
  - **`verify` execution in a POSIX PTY.** Runs only after all merges succeed:
    - When `plan.json` omits `verify` (or it is whitespace-only), integration finishes with `status: "merged"`, `ready: false`, `verify: null`, and `run` exits `0`.
    - When `verify` is configured, `RelayIDE` spawns `/bin/sh -c 'exec </dev/null; exec /bin/sh -c "$1"' relayide-verify '<verify>'` inside a POSIX PTY in `<project>/runs/<run-id>/worktrees/integration` (non-login shell, no startup files read, caller `PATH` and environment preserved verbatim plus `PAGER=cat` and `GIT_PAGER=cat`, stdin redirected from `/dev/null` while retaining the controlling terminal).
    - PTY master output is appended to `<project>/runs/<run-id>/verify.pty` up to `16 MiB` (`16,777,216` bytes; beyond that cap writing stops with `logTruncated: true` while draining continues until exit). Like `<lane>.pty`, `verify.pty` is a PTY terminal transcript where `\n` becomes `\r\n`, not byte-for-byte program output.
    - On `verify_timeout` or `SIGINT`/`SIGTERM`, `RelayIDE` enumerates all descendant PIDs and process groups (`proc_listchildpids` with `sysctl(KERN_PROC_ALL)` fallback) before sending the first signal, then escalates `SIGINT` (`10s`) -> `SIGTERM` (`5s`) -> `SIGKILL` across all collected groups until every group is empty. Exit status is decoded via `POSIXWaitStatus` (signal death records `status: "failed"`, `signal: N`, `exitCode: null`). If `verify` exits `0` but modifies tracked files (`git status --porcelain=v1 --untracked-files=no`), `verify` is marked `failed` (`integration.status = "verify-failed"`, `ready = false`) and `modifiedTrackedFiles` lists the paths.
  - **Merge readiness (`integration.ready`), `.relay/LOG.md` spend, whole-job `RELAY_BUDGET_USD`, signals & `status`.**
    - **Merge readiness looks only at `integration.ready` in JSON**: `integration.ready` is `true` if and only if all lanes succeeded without cancellation and `integration.status == "verified"`, and `false` in every other case (including `merged` when `plan.json` has no `verify`, and `nothing-to-merge`). `RelayIDE` never merges `relay/<run-id>/integration` back into `base`; that step is left to a human.
    - Parses USD spend (`costSource: "usd"` for `claude` and `vibe`), unpriced token counts (`costUSD: null`, `costSource: "unpriced"` for `codex` and `agy`), or missing records (`costUSD: null`, `tokens: null`, `costSource: "no_record"`) from `<worktree>/.relay/LOG.md` without turning unpriced or missing records into `0`. When `RELAY_BUDGET_USD` is set, before spawning each lane `RelayIDE` sums `costUSD` across completed lanes (`spentSoFar`) and passes `RELAY_BUDGET_USD = max(0, budget - spentSoFar)` (`%.4f`) to `relay.sh` (concurrent lanes in the same parallel wave share the remaining allowance at their launch instant, so a parallel wave may overshoot within that wave before subsequent lanes are blocked); once exhausted, `relay.sh` refuses subsequent lanes (including unpriced `agy`/`codex` lanes) with exit `2` (`status: "refused"`, downstream `after` lanes `skipped`, run exits `1`). Handles `SIGINT` (`130`) and `SIGTERM` (`143`) across lane, merge, and `verify` phases, and reconciles runs/integrations/`verify` orphaned by `kill -9` to `interrupted` (or `skipped` for `pending` integration) when `run.lock` is no longer held.
    - Prints the run JSON ledger on stdout (including `integration` and top-level `budgetUSD`, `totalCostUSD`, `unpricedTokens`, `pricedLaneCount`, `unpricedLaneCount`, `noRecordLaneCount`, and `budgetExhausted`), byte-identical to `RelayIDE status --project <dir> --run <run-id> [--json]`. Plain `RelayIDE status [--project <dir>] [--json]` aggregates `totalSpendUSD` and `totalTokensObserved` across `relay_run_lanes` in the workspace (`status` always outputs JSON, so passing `--json` produces identical output to omitting it; passing extra positional arguments exits `2`).
  - **Measured M4 acceptance results (`2026-11-21`, `Scripts/acceptance/m4-budget.sh`, [reports/m4-budget.txt](reports/m4-budget.txt), [reports/RelayIDE-M4.md](reports/RelayIDE-M4.md)).** Measured headlessly on `2026-11-21` (`2026-11-21T07:04:01Z`, commit `e7e1743`) by running `Scripts/acceptance/m4-budget.sh` through `Scripts/acceptance/relay-cli.sh` and real `agent-relay` (`relay.sh` + `relay_util.py`) with `Tests/Support/stub-agent.sh`, isolated `HOME`, and decoy `claude`/`codex`/`agy`/`vibe`/`opencode` executables first in `PATH` (`9` hard checks passed, Row `10` recorded, `36.09s` total, `0` decoy invocations; per-row timings and full record in [reports/m4-budget.txt](reports/m4-budget.txt)):
    - **Rows 1 & 2 (4-vendor spend, workspace `status`, and `export-html`)**: 4-lane run (`c1` `claude` `$0.1234`, `v1` `vibe` `$0.2500`, `a1` `agy` `costUSD: null` / `4,500` tokens, `x1` `codex` `costUSD: null` / `1,200` tokens) matched `relay_util.py spent` on each `.relay/LOG.md` (`0.123400` + `0.250000` = `0.373400`), produced byte-identical `run` and `status --run` JSON (`totalCostUSD: 0.3734`, `unpricedTokens: 5700`, `pricedLaneCount: 2`, `unpricedLaneCount: 2`, `budgetUSD: null`), and reported `totalSpendUSD: 0.3734` and `totalTokensObserved: 5700` in plain `status --project` and bilingual `export-html` without `[DEMO]` markers.
    - **Rows 3, 4 & 5 (`RELAY_BUDGET_USD` gating)**: On chain `a ($0.30) -> b ($0.25) -> c ($0.10) -> d` with `RELAY_BUDGET_USD=0.50` (`--lang en` and `--lang zh`), `a` and `b` succeeded (`totalCostUSD: 0.55`, `budgetExhausted: true`), `c` was refused by `relay.sh` with exit `2` (`0` stub runs, `0` `LOG.md` steps, reason citing `$0.5500 / $0.5000` and `not started`), `d` was marked `skipped`, and `run` exited `1`; with `RELAY_BUDGET_USD=1.00` and `verify: "true"`, `b` received remaining `$0.7000` (`RELAY_BUDGET_USD=0.7000`, `--max-price 0.7000` in `b.pty`) and finished `integration.ready: true` (exit `0`); after `claude` spent `$0.60` against `RELAY_BUDGET_USD=0.50`, subsequent unpriced `agy` lane `b` was refused with exit `2` (run exit `1`).
    - **Rows 6, 7, 8, 9 & 10 (validation, proxy removal, Schema v6 -> v7 upgrade, hygiene, record & mutations)**: `5` invalid `RELAY_BUDGET_USD` values (`0`, `-2.5`, `abc`, `NaN`, `inf`) across EN and ZH (`10/10` runs) exited `2` with `0`-byte stdout and `0` disk/Git/SQLite side effects; proxy files had `0` matches across `Package.swift`, `Sources/`, and `README*` with `$0` default empty spend; a genuine Schema v6 SQLite database upgraded cleanly to v7 preserving historical run `budgetUSD: null` (`totalCostUSD: 0.042`, `unpricedTokens: 1800`) and persisted a new v7 run (`$0.15` under `budgetUSD: 0.80`, cumulative workspace `totalSpendUSD: 0.192`); post-suite hygiene verified `0` leftover processes and unchanged `~/Library/Preferences` and `agent-relay` SHA-256s, Row `10` recorded timings, checksums, and the `20,670,544`-byte `.build/debug/RelayIDE` binary to [reports/m4-budget.txt](reports/m4-budget.txt), and all `3/3` temporary-copy mutations (`--mutation 2`, `--mutation 3`, `--mutation 4`) failed on their target rows (`Row 3`, `Row 1`, `Row 2`).
  - **Exit codes of `RelayIDE run`:**

    | Exit code | Condition |
    |---|---|
    | `0` | All lanes succeeded (including `succeeded-no-changes`), and `integration.status` is `verified`, `merged` (plan has no `verify`), or `nothing-to-merge` |
    | `1` | Run completed otherwise: at least one non-succeeded lane (including `refused` when `RELAY_BUDGET_USD` is exhausted; `integration.status == "skipped"`), merge `conflict`, or `verify` failed (`verify-failed`) or timed out (`verify-timeout`) |
    | `2` | Plan, CLI option, `RELAY_BUDGET_USD`, or Git identity validation error detected before touching anything (including invalid `verify_timeout`, unknown JSON fields, multi-predecessor lanes, non-positive/non-numeric `RELAY_BUDGET_USD`, or positional arguments to `status`); stdout is empty |
    | `125` | `RelayIDE` or environment error (`relay.sh` missing, `RELAY_WORKER` set, `run.lock` busy, worktree creation failure, non-conflict `git merge` failure, unclean state after `git merge --abort`, `verify` startup failure, or SQLite write failure); stdout is empty |
    | `130` / `143` | Received `SIGINT` (`130`) / `SIGTERM` (`143`) during lane, merge, or `verify` phase |

  - **Current M5 boundaries.** Spend comes solely from `relay.sh`'s `<worktree>/.relay/LOG.md` (the local proxy is removed; use `agent-xray` for single-request inspection); `codex` and `agy` record token counts only (`costUSD: null`, `costSource: "unpriced"`), do not report USD cost, and do not count toward USD totals (`totalCostUSD` or `totalSpendUSD`); under `RELAY_BUDGET_USD`, parallel lanes in the same concurrent wave share the remaining allowance at launch (`P2 = A`), so spend may overshoot within one parallel wave before the next wave is refused. The desktop UI is strictly a read-only live observer (runs are started via `RelayIDE run` in the CLI, non-demo mode has no broadcast input bar, and the `⌘5` Guardrail Plugins pane displays `Not Connected` outside `--demo`). In addition, `RelayIDE` never updates or merges into `base` (a human merges `relay/<run-id>/integration` after checking `integration.ready == true`), multi-predecessor lanes (`after` with more than one lane) are rejected with exit `2`, only Git's built-in merge (`git merge --no-ff`) is used (no automatic conflict retry, re-merge/re-verify subcommands, or worktree cleanup subcommands), and unknown non-flag non-`.relayproj` first arguments exit `2` on stderr instead of opening the desktop window.
- **Read-Only Live Desktop Workbench & Empty-by-Default Bilingual Shell (`中文 / EN`)**:
  - **Four live panes (`⌘1` to `⌘4`) & honest `⌘5` state**: Opening `--project <dir.relayproj>` without `--demo` attaches read-only `FSEvents` and `kqueue` observers (`RelayLiveWorkspaceObserver` and `RelayWorktreeOwnershipLiveWatcher`) without running independent orchestration or mutating Git/SQLite state:
    - `⌘1` **PTY Grid & Lane Rail**: Streams each lane's `<worktree>/.relay/NN-<agent>.log` line by line into `VT100TerminalScreenBuffer` (threshold `< 1.0s` per emitted line), falling back to `<project>/runs/<run-id>/lanes/<lane>.pty` when no `.relay/*.log` exists (such as budget-refused lanes), and updates lane status, exit code, elapsed duration, 4-decimal USD spend (`$0.1234`), or unpriced token counts (`<N> tokens · unpriced`, never `$0.00`) within `< 2.0s` of lane completion (omitting `/ $0.00` when `RELAY_BUDGET_USD` is unset, and disabling the broadcast input bar).
    - `⌘2` **Relay DAG**: Renders single-predecessor `after` topology edges and measured start/finish offsets from `RelayRunRecord.lanes`, or an honest empty state when no run exists (no synthetic `1.00x` speedup).
    - `⌘3` **Merge & Conflict View**: Displays M2 `RelayRunIntegrationRecord` status, `ready`, step-by-step `mergeCommitOID`s, `verify.pty` transcript, and read-only Git conflict blocks reconstructed in a temporary directory via `git merge-file -p` (interactive AST conflict buttons are restricted to `--demo`, and dead R74 toggles are removed).
    - `⌘4` **Live Worktree File Ownership**: Queries `git diff --no-renames --name-only -z <startCommitOID>` unioned with `git ls-files --others --exclude-standard -z` (excluding `.relay/` and `.git/`) on worktree `FSEvents`, distinguishing `committed` vs `uncommitted` files with `+add / -del` line counts within `< 2.0s` of manual or agent edits.
    - `⌘5` **Guardrail Plugins**: Displays `Guardrail Plugins · Not Connected` in non-demo mode without loading synthetic policy numbers.
  - **Windowless M5 acceptance & tightened number provenance (`Scripts/acceptance/m5-ui.sh`, `reports/m5-ui.txt`, [reports/RelayIDE-M5.md](reports/RelayIDE-M5.md))**: Verified headlessly with `NSApplication.ActivationPolicy.prohibited` (`0` `NSWindow`s) across `9` acceptance rows (`8` hard checks + Row `9` recorded metrics) and `9` temporary-copy mutations (`--mutation 1..9`), rendering `70` offscreen `ImageRenderer` vector PDFs and `15` `2720x1680` `CGImage` bitmaps: every number rendered in non-demo mode is checked both by complete-token provenance (hex commit hashes, `runID`s, lane IDs, and paths are matched only as whole tokens, never split into sub-digits) and by per-pane regex extraction and exact equality (per-lane where adjacent and multiset across each single rendered pane) against SQLite, `.relay/LOG.md`, and read-only Git output; measured latencies and timings vary per machine load and are recorded in `reports/m5-ui.txt` (see [reports/RelayIDE-M5.md](reports/RelayIDE-M5.md)).
  - **Empty default & `[DEMO]` isolation**: Launching without `--demo` or `--project` starts in an empty state (`0` lanes, empty terminal buffers, no spend numbers). Live `中文 | EN` switching works across the toolbar pill, `⇧⌘L`, `⌘,` Preferences, `--lang zh|en`, and `RELAYIDE_LANG=zh|en`. Passing `--demo` (or clicking **Load Demo**) loads a `[DEMO]` synthetic preview in a temporary bundle without touching user `.relayproj` directories.
- **`.relayproj` SQLite WAL Store, Run & Integration Ledger, FTS5 Search & Checkpoints (`RelayWorkspaceStore`)**: Schema v7 (with `busy_timeout`) persists run, lane, budget, integration, and merge ledgers (`relay_runs` including `budget_usd`, `relay_run_lanes`, `relay_run_integration`, `relay_run_merges`; M1 v5 and M2 v6 bundles upgrade cleanly with `budgetUSD: null` on historical runs, queried via `status --run <id> [--json]` and `status --runs [--json]`) alongside workspace metadata, lane records, DAG specs, merge reports, guardrail findings, FTS5 `BM25` search documents, SHA-256 checkpoints, and Undo/Redo history. Read-only CLI subcommands (`status`, `lanes`, `dag-waves`, `audit-plugins`, `export-html`, `mcp --project`) fail fast with a non-zero exit code if `--project <dir>` does not exist instead of creating directories behind the user's back. On a workspace made with `init`, plain `status` reports `activeLaneCount: 0`, `totalSpendUSD: 0`, `totalTokensObserved: 0`, and `schemaVersion: 7`, `status --runs` prints `[]`, `lanes` prints nothing, and `dag-waves` prints `No DAG registered`; `init --seed-demo` populates synthetic `[DEMO]` preview rows (including a `[DEMO]` run ledger).
- **Standalone Engine Primitives (Unit-Tested Libraries)**:
  - `RelayPTYCore`: `posix_openpt(2)` child-process PTY session wrapper, `<sys/wait.h>` exit/signal decoder (`POSIXWaitStatus`), pre-signal descendant process-group enumeration (`proc_listchildpids` with `sysctl(KERN_PROC_ALL)` fallback) and group-drain escalation, optional raw `.pty` byte cap, VT100 / `xterm-256color` / TrueColor screen buffer, Boyer-Moore scrollback search, and `.cast` v2 transcript codec.
  - `RelayWorktreeGit`: Hook-skipping (`-c core.hooksPath=/dev/null`) lane and integration `git worktree add -b` creation, lane change staging/committing (excluding `.relay/`), `git merge --no-ff` integration merging with porcelain conflict extraction and verified `git merge --abort` rollback, glob territory rule evaluation (`FileOwnershipRule`), and `.relay/LOG.md` handoff parsing.
  - `RelayOrchestrator`: Event-driven single-predecessor lane scheduler (`RelayDAGRunScheduler`), topological + plan-order integration merge runner (`RelayIntegrationMergeRunner`), POSIX PTY `verify` runner (`RelayVerifyRunner`), `.relay/LOG.md` spend/token parser, Kahn topological wave sort, and Critical Path Method (`ES`/`EF`/`LS`/`LF`/slack) analyzer.
  - `RelayPluginSDK`: Sandboxed `JavaScriptCore` policy-pack & hook scratchpad evaluator (`audit-plugins` and interactive GUI scratchpad).
- **Stdio JSON-RPC 2.0 MCP Server (`1` Tool)**: `RelayIDE mcp [--project <dir>]` exposes **1 MCP tool** over stdio: `relay_check_ownership` (evaluates whether a relative file path is permitted by a lane's `FileOwnershipRule` in the bound `--project` workspace).
- **Standalone Bilingual HTML Report (`export-html`)**: Exports a single-file `中文 | EN` HTML summary from an existing `.relayproj` including the recorded `relay_runs` / `relay_run_lanes` spend and token ledger (stamped with `[DEMO]` / `[演示数据]` when exported from `--seed-demo` synthetic data).

> **Removed in this version (2026-11-21):** The `semantic-merge` subcommand shipped in v1.4.0 and earlier (along with its MCP counterpart) has been removed in this version; see [reports/m3-merge-eval.md](reports/m3-merge-eval.md) for the rationale and 9-repository open-source merge-conflict corpus numbers measured by `Scripts/acceptance/m3-merge-eval.sh` on 2026-11-21 (the published command matched human merges byte-for-byte on Python `1/330`, Swift `0/377`, and TypeScript `0/611`). The local proxy (along with its desktop tab) has also been removed; use `agent-xray` for single-request inspection.

---

## Roadmap

- **Completed Milestones**: **M0** (honest empty defaults & `[DEMO]` separation), **M1** (headless `agent-relay` isolated-worktree execution), **M2** (deterministic `git merge --no-ff` integration branch & POSIX PTY `verify`), **M3** (9-repository semantic-merge evaluation & removal of `semantic-merge`; see [reports/m3-merge-eval.md](reports/m3-merge-eval.md)), **M4** (`.relay/LOG.md` USD spend & unpriced token ledger, workspace `status` and `export-html` aggregation, whole-job `RELAY_BUDGET_USD` gating, Schema v7 migration, and local proxy removal; see [reports/RelayIDE-M4.md](reports/RelayIDE-M4.md) and [reports/m4-budget.txt](reports/m4-budget.txt)), and **M5 (Completed, 2026-11-22: Desktop UI Connected to Live Runs)**: read-only live SwiftUI terminal grid (`⌘1`), run dependency DAG (`⌘2`), M2 integration & `git merge-file -p` conflict view (`⌘3`, fixing R74), and `FSEvents` worktree file ownership view (`⌘4`), verified headlessly by `Scripts/acceptance/m5-ui.sh` (`9` rows + `9` mutations; see [reports/RelayIDE-M5.md](reports/RelayIDE-M5.md) and `reports/m5-ui.txt`).
- **Planned / Deferred Before Release**:
  - **Real-run desktop screenshots**: Replacing the synthetic `--demo` PNGs under `docs/` by manually capturing screenshots from a real paid-agent run during pre-release full verification (`RELAY_REAL_AGENTS=1`; `--export-screenshots` already accepts `--project <dir.relayproj>`).
  - **Multi-predecessor DAG lanes**: Supporting more than one predecessor in `after` (currently rejected with exit `2`).

---

## Known Issues

- **Repository Git hooks are skipped across worktrees, commits, and merges.** Because `RelayIDE` passes `-c core.hooksPath=/dev/null` on all of its own Git writes, repositories that rely on hooks such as `post-checkout` (for example `husky`) to initialize worktree tooling will not have those hooks run automatically; invoke any required setup or repository checks inside `verify`.
- **Uncatchable `SIGKILL` (`kill -9`) mid-merge or with detached `verify` subgroups.** If `RelayIDE` itself is killed with `kill -9` while a `git merge` is in progress, the integration worktree may remain stopped on an unfinished merge (`MERGE_HEAD`); `status` reconciles the run and integration to `interrupted` and notes this in `reason`. If `RelayIDE` is killed with `kill -9` during `verify`, same-group children exit on PTY hangup (`SIGHUP`), whereas background descendants that call `setpgrp` and ignore `SIGHUP` cannot be swept because `kill -9` prevents the termination ladder from running.
- **Legacy workspace inspection CLI subcommands & synthetic `--demo` screenshots in `docs/`.** `RelayIDE run`, `status`, `export-html`, and the non-demo desktop UI (`⌘1` to `⌘4`) read and write the Schema v7 `relay_runs`, `relay_run_lanes`, `relay_run_integration`, and `relay_run_merges` tables and live worktrees, whereas the older `lanes`, `dag-waves`, and `audit-plugins` CLI subcommands inspect the M0 workspace tables (populated by `init --seed-demo`). Per M5 scope, the 6 screenshots currently in `docs/` remain synthetic `--demo` previews (showing `SQLite WAL v4` in the footer) until real-agent screenshots are captured manually before release.

---

## Synthetic Demo Gallery (`--demo`, `[DEMO]` Fixtures)

All three views below are rendered from synthetic sample data (`--export-screenshots` with `loadDemoWorkspace: true`) and carry the `[DEMO]` badge in the window header; real-run screenshots are deferred to manual capture when running real agents before release:

| 2x2 PTY Multiplexer Grid (`[DEMO]`) | Merge Conflict Studio (`[DEMO]`) |
|---|---|
| ![PTY Grid Demo](docs/screenshot-pty-grid.png) | ![Merge Conflict Demo](docs/screenshot-semantic-merge.png) |

| Isometric Territory Map (`[DEMO]`) |
|---|
| ![Territory Map Demo](docs/screenshot-territory-map.png) |

---

## Build, Verify & Usage

> **Executable name & prerequisite**: Building from source with SwiftPM produces `.build/debug/RelayIDE` (and `./Scripts/build-app.sh` packages `build/RelayIDE.app/Contents/MacOS/RelayIDE`). Installing via Homebrew Cask (`brew install --cask zxu756/tap/relayide`) links the lowercase `relayide` CLI wrapper into `/opt/homebrew/bin/relayide`. Running `RelayIDE run` requires `agent-relay` installed at `~/.agents/skills/agent-relay/scripts/relay.sh` (or passed via `--relay-sh` / `RELAYIDE_RELAY_SH`).

### Build & Run Tests From Source

```bash
swift build
./Scripts/test.sh milestone 0
./Scripts/test.sh milestone 1
./Scripts/test.sh milestone 2
./Scripts/test.sh milestone 3
./Scripts/test.sh milestone 4
./Scripts/test.sh milestone 5
./Scripts/build-app.sh
```

### `plan.json` Format for `RelayIDE run`

Run a multi-lane plan against an existing `.relayproj` outside the target Git repository (with `user.name` and `user.email` configured in that repository); `readme-commands.sh` marks `RelayIDE run` as `SKIP-AGENTS` because live coding agents are never invoked during README replay (the full pipeline and live UI observer are verified with stub agents by `m1-run.sh`, `m2-merge.sh`, `m4-budget.sh`, and `m5-ui.sh`):

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
# Launches coding agents via agent-relay; classified SKIP-AGENTS by readme-commands.sh (covered with stub agents by m1-run.sh, m2-merge.sh, m4-budget.sh, and m5-ui.sh)
.build/debug/RelayIDE run plan.json --project ../target.relayproj --lang en
```

### Headless CLI & MCP Commands

Run these from the repository root after `swift build`. They are exactly the commands `Scripts/acceptance/readme-commands.sh` extracts from this file and executes.

```bash
# 0. Scratch directory for the examples below
WORK="$(mktemp -d)"

# 1. Inspect CLI help, initialize an empty workspace (0 lanes), and inspect its status and run ledger (--json is optional and identical)
.build/debug/RelayIDE --help --lang en
.build/debug/RelayIDE version --lang en
.build/debug/RelayIDE init --project "$WORK/my-empty.relayproj" --lang en
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj" --lang en
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj" --runs --lang en
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj" --runs --json --lang en
.build/debug/RelayIDE lanes --project "$WORK/my-empty.relayproj" --lang en

# 2. Seed an explicit [DEMO] synthetic workspace and export a [DEMO] HTML report
.build/debug/RelayIDE init --project "$WORK/demo.relayproj" --seed-demo --lang en
.build/debug/RelayIDE dag-waves --project "$WORK/demo.relayproj" --lang en
.build/debug/RelayIDE audit-plugins --project "$WORK/demo.relayproj" --lang en
.build/debug/RelayIDE export-html "$WORK/demo-dossier.html" --project "$WORK/demo.relayproj" --lang en

# 3. stdio JSON-RPC 2.0 MCP server (1 tool: relay_check_ownership): list the tools
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | .build/debug/RelayIDE mcp --project "$WORK/my-empty.relayproj" --lang en
```

### Desktop GUI Launch

Pass `--project <dir.relayproj>` (or open a `.relayproj` bundle) to observe an existing CLI run live in read-only mode:

```bash
# Launch empty workbench (0 lanes, no synthetic data; pass --project ../target.relayproj to observe a live run)
build/RelayIDE.app/Contents/MacOS/RelayIDE

# Launch with explicit [DEMO] synthetic preview data in English or Simplified Chinese
build/RelayIDE.app/Contents/MacOS/RelayIDE --demo --lang en
build/RelayIDE.app/Contents/MacOS/RelayIDE --demo --lang zh
```

---

## License

MIT License. Copyright (c) 2026 Xu (`zxu756`).
