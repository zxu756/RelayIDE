# RelayIDE

**English** | **[简体中文](README.zh-CN.md)**

**macOS Workbench & Workspace Store for Multi-Agent Relay Workflows**

`RelayIDE` is a native macOS SwiftUI workbench, SQLite workspace store, and CLI/MCP utility for inspecting isolated Git worktree lanes, topological task waves, guardrail policies, and merge artifacts. **Current status (M0): This version does not launch coding agents yet; headless multi-agent execution via `agent-relay` is scheduled for M1.**

![RelayIDE Synthetic Demo Preview](docs/screenshot-pty-grid.png)
*Figure 1 (`[DEMO]`): Synthetic 4-lane preview rendered with `--demo` (`--export-screenshots`). Launching `RelayIDE` without `--demo` opens an empty workspace with `0` lanes, no terminal transcripts, no spend figures, and no active proxy.*

---

## What Works Today (M0)

- **Empty-by-Default Bilingual Workbench (`中文 / EN`)**: Launching the macOS app without `--demo` starts in an honest empty state (`0` lanes, empty terminal buffers, no spend numbers, and no proxy address). Live `中文 | EN` switching works across the toolbar pill, `⇧⌘L` shortcut, `⌘,` Preferences modal, `--lang zh|en`, and `RELAYIDE_LANG=zh|en`. Passing `--demo` (or clicking **Load Demo**) loads a clearly badged `[DEMO]` synthetic preview in a temporary bundle without touching user `.relayproj` directories.
- **`.relayproj` SQLite WAL Store, FTS5 Search & Checkpoints (`RelayWorkspaceStore`)**: Persists workspace metadata, lane records, DAG specs, merge reports, guardrail findings, FTS5 `BM25` search documents, SHA-256 checkpoints, and Undo/Redo history. Read-only CLI subcommands (`status`, `lanes`, `dag-waves`, `audit-plugins`, `export-html`, `mcp --project`) fail fast with a non-zero exit code if `--project <dir>` does not exist instead of creating directories behind the user's back. **These subcommands are read-only inspection: this version has no command that creates a lane or a DAG.** On a workspace made with `init`, `lanes` prints nothing and `dag-waves` prints `No DAG registered`; only `init --seed-demo` fills them, with synthetic `[DEMO]` rows.
- **Standalone Engine Primitives (Unit-Tested Libraries)**:
  - `RelayPTYCore`: `posix_openpt(2)` child-process PTY session wrapper, VT100 / `xterm-256color` / TrueColor screen buffer, Boyer-Moore scrollback search, and `.cast` v2 transcript codec.
  - `RelayWorktreeGit`: `git worktree` creation/inspection plumbing, glob territory rule evaluation (`FileOwnershipRule`), and `.relay/LOG.md` handoff parsing.
  - `RelayOrchestrator`: Kahn topological wave sort and Critical Path Method (`ES`/`EF`/`LS`/`LF`/slack) analyzer.
  - `RelayPluginSDK`: Sandboxed `JavaScriptCore` policy-pack & hook scratchpad evaluator (`audit-plugins` and interactive GUI scratchpad).
  - `RelayWiretapProxy`: Standalone loopback HTTP/1.1 + SSE token dissector, regex secret scanner, and in-memory budget circuit-breaker ledger.
- **Stdio JSON-RPC 2.0 MCP Server (`2` Tools)**: `RelayIDE mcp [--project <dir>]` exposes **2 MCP tools** over stdio:
  1. `relay_semantic_merge` (the same guarded 3-way merge as the `semantic-merge` subcommand described below; `isError` is `false` only where the subcommand would exit `0`).
  2. `relay_check_ownership` (evaluates whether a relative file path is permitted by a lane's `FileOwnershipRule` in the bound `--project` workspace).
- **Guarded 3-Way Merge (`semantic-merge`, experimental)**: `RelayIDE semantic-merge <base> <left> <right>` is anchored on `git merge-file` and needs `git` on `PATH`. Disabled by default in handoff preferences before M3.
  - **What it does.** It first runs the line-level merge `git merge-file -p`. If git merges cleanly, the output is git's text, byte for byte. If git reports conflicts, the output is git's conflict-marked text, with one exception: when every conflict block is a plain "both sides inserted lines at the same place" block, the file type has a syntax checker, and the declaration-level engine, asked as a referee, produces the same non-blank lines in the same order, both insertions are kept (one side's lines, then the other's, in the order the engine chose). The printed text is always assembled from git's own output. The engine's text is never printed.
  - **What exit `0` guarantees.** Every line either side added is in the output. Every line neither side touched is byte-identical, blank lines and string contents included. For `.py`/`.pyi`, `.swift`, `.js`/`.mjs`/`.cjs`, `.ts`/`.tsx` and `.json` the output passed that language's parser (`python3 -m py_compile`, `xcrun swiftc -parse`, `node --check`, `tsc --noEmit` or, without `tsc`, Node type stripping plus `node --check`, `JSONSerialization`).
  - **What it does not guarantee.** A merge that parses can still be wrong in meaning, exactly as with `git merge`. When both insertions are kept, which one comes first is the engine's choice and is only checked by the parser. The declaration-level engine on its own is known to corrupt Python and Swift (it drops decorators and attributes and re-spaces declarations), which is why it only gets a veto and why most conflicts stay conflicts. Whether the engine is kept at all is decided in M3.
  - **Other file types.** For every other extension (`.rs`, `.go`, `.java`, `.jsx`, no extension, ...) there is no syntax checker. The command then behaves exactly like `git merge-file`: a clean result with exit `0` and a note on stderr that it was not syntax-checked, or git's conflict text with exit `1`. The declaration-level engine is not consulted.
  - **Exit codes.** `0` clean. `1` conflict; stdout is git's conflict-marked text. `2` usage error, unreadable file or input that is not UTF-8. `3` git merged cleanly but the result does not parse; nothing is printed. `4` git is missing or `git merge-file` failed; nothing is merged. One stderr line says which result was used: `[strategy=line-level]`, `[strategy=declaration-level]` or `[strategy=none]`.
  - **Measured on `Fixtures/merge-cases`** (35 three-way cases in Swift, Python, TypeScript, JavaScript, Rust, Go and Java; checked on 2026-11-14 by `Scripts/acceptance/merge_cases_check.py`, which compares every result with `git merge-file`; output in `reports/m0-acceptance.txt`): 15 clean results identical to git, 8 conflicts resolved by keeping both insertions, 12 conflicts reported with git's own text, 0 cases worse than `git merge-file`.
- **Standalone Bilingual HTML Report (`export-html`)**: Exports a single-file `中文 | EN` HTML summary from an existing `.relayproj` (stamped with `[DEMO]` / `[演示数据]` when exported from `--seed-demo` synthetic data).

---

## Planned Roadmap (Not Implemented in M0)

- **M1 (Real Multi-Agent Relay Runner)**: `RelayIDE run` spawning real `claude`, `codex`, `agy`, and `vibe` headless CLI workers in isolated Git worktrees via `.relay/` file handoff, live PTY stdout/stderr streaming, and real broadcast command execution (`⌘⇧B` currently reports `"Broadcast command is not implemented yet (M1)"`).
- **M2 (Post-Run Git Worktree Integration & Verification Gate)**: Deterministic branch integration via `git merge-tree` / `git merge-file`, post-merge build/test verification gate, and automatic territory violation checks across real agent runs.
- **M3 (Parser-Backed Semantic Merge)**: Replacing regex/indentation declaration heuristics with real AST parsers (`SwiftSyntax` / `tree-sitter`) across edge cases before enabling semantic merge in automated pipelines.
- **M4 (Live Loopback Wiretap & Outbound DLP Gateway)**: Wiring `LoopbackWiretapProxyServer` into child agent `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` environment variables, enforcing live HTTP `429` budget circuit breakers, and redacting outbound secrets on live network traffic.

---

## Known Issues

- **`semantic-merge` and TypeScript without `tsc`.** When `tsc` is not on `PATH`, TypeScript is checked with Node's built-in type stripping, which rejects syntax that cannot simply be erased (`enum`, `namespace`, constructor parameter properties) and JSX in `.tsx`. A merge of such a file exits `3` even when the merge itself is fine.
- **`semantic-merge` resolves few conflicts.** It only ever keeps both sides of "both inserted at the same place" conflicts, and only when the declaration-level engine reproduces every non-blank line. Renames, edits to adjacent lines and anything the engine misreads stay conflicts, as with `git merge-file`.
- **Verification gate hangs on large output (library only).** `VerificationCommandGateEvaluator.runGateCommand` reads the child's stdout and stderr only after the child has exited. A command that prints more than the pipe buffer (about 64 KB) blocks, runs into the timeout and is reported as exit `124` instead of its real status. No command in this version calls this function; it must be fixed before M2 uses it.
- **Verification gate timeout kills one process only (library only).** On timeout the same function terminates the shell it started, not the shell's process group, so child processes of the verification command keep running.
- **No CLI command creates lanes or DAGs.** `lanes`, `dag-waves` and `audit-plugins` only list what is already in the workspace store, and the only CLI command that writes lanes, DAGs or guardrail findings is `init --seed-demo`, which writes synthetic data.

---

## Synthetic Demo Gallery (`--demo`, `[DEMO]` Fixtures)

All four views below are rendered from synthetic sample data (`--export-screenshots`, which sets `loadDemoWorkspace: true`) and carry the `[DEMO]` badge in the window header:

| 2x2 PTY Multiplexer Grid (`[DEMO]`) | 3-Way Semantic Merge Studio (`[DEMO]`) |
|---|---|
| ![PTY Grid Demo](docs/screenshot-pty-grid.png) | ![Semantic Merge Demo](docs/screenshot-semantic-merge.png) |

| Isometric Territory Map (`[DEMO]`) | Wiretap Telemetry & Guardrails (`[DEMO]`) |
|---|---|
| ![Territory Map Demo](docs/screenshot-territory-map.png) | ![Wiretap & Plugins Demo](docs/screenshot-wiretap-guardrails.png) |

---

## Build, Verify & Usage

> **Executable name**: Building from source with SwiftPM produces `.build/debug/RelayIDE` (and `./Scripts/build-app.sh` packages `build/RelayIDE.app/Contents/MacOS/RelayIDE`). Installing via Homebrew Cask (`brew install --cask zxu756/tap/relayide`) links the lowercase `relayide` CLI wrapper into `/opt/homebrew/bin/relayide`.

### Build & Run Tests From Source

```bash
swift build
./Scripts/test.sh milestone 0
./Scripts/build-app.sh
```

### Headless CLI & MCP Commands

Run these from the repository root after `swift build`. They are exactly the commands `Scripts/acceptance/readme-commands.sh` extracts from this file and executes.

```bash
# 0. Scratch directory for the examples below
WORK="$(mktemp -d)"

# 1. Initialize an empty workspace (0 lanes) and inspect its status
.build/debug/RelayIDE init --project "$WORK/my-empty.relayproj"
.build/debug/RelayIDE status --project "$WORK/my-empty.relayproj"
.build/debug/RelayIDE lanes --project "$WORK/my-empty.relayproj"

# 2. Seed an explicit [DEMO] synthetic workspace and export a [DEMO] HTML report
.build/debug/RelayIDE init --project "$WORK/demo.relayproj" --seed-demo --lang en
.build/debug/RelayIDE dag-waves --project "$WORK/demo.relayproj" --lang en
.build/debug/RelayIDE audit-plugins --project "$WORK/demo.relayproj" --lang en
.build/debug/RelayIDE export-html "$WORK/demo-dossier.html" --project "$WORK/demo.relayproj" --lang en

# 3. Guarded 3-way merge: git merges this one cleanly, so the output is git's text (exit 0)
.build/debug/RelayIDE semantic-merge \
  Fixtures/merge-cases/20-py-decorator-added/base.py \
  Fixtures/merge-cases/20-py-decorator-added/left.py \
  Fixtures/merge-cases/20-py-decorator-added/right.py --lang en

#    Both sides add a method at the same place: git reports a conflict, both insertions are kept (exit 0)
.build/debug/RelayIDE semantic-merge \
  Fixtures/merge-cases/02-swift-both-add-func/base.swift \
  Fixtures/merge-cases/02-swift-both-add-func/left.swift \
  Fixtures/merge-cases/02-swift-both-add-func/right.swift --lang en

#    A real conflict: stdout is git's conflict-marked text and the exit code is 1
.build/debug/RelayIDE semantic-merge \
  Fixtures/merge-cases/12-swift-true-conflict/base.swift \
  Fixtures/merge-cases/12-swift-true-conflict/left.swift \
  Fixtures/merge-cases/12-swift-true-conflict/right.swift --lang en || echo "semantic-merge exit code: $?"

# 4. stdio JSON-RPC 2.0 MCP server (2 tools: relay_semantic_merge, relay_check_ownership): list the tools
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | .build/debug/RelayIDE mcp --project "$WORK/my-empty.relayproj" --lang en
```

### Desktop GUI Launch

```bash
# Launch empty workbench (0 lanes, no synthetic data)
build/RelayIDE.app/Contents/MacOS/RelayIDE

# Launch with explicit [DEMO] synthetic preview data in English or Simplified Chinese
build/RelayIDE.app/Contents/MacOS/RelayIDE --demo --lang en
build/RelayIDE.app/Contents/MacOS/RelayIDE --demo --lang zh
```

---

## License

MIT License. Copyright (c) 2026 Xu (`zxu756`).
