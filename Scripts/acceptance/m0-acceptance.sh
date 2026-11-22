#!/usr/bin/env bash
# RelayIDE M0 acceptance suite: the 9 rows of the M0 table plus the rows added by the 2026-11-14 rework.
# Everything that prints text is checked with --lang en and --lang zh.
#
# This script never opens the desktop window. Product commands go through Scripts/acceptance/relay-cli.sh,
# which refuses anything that is not a headless subcommand, with HOME pointed at a scratch directory.
# The default UI state (rows 7 and 8) is verified by headless view-model tests.
#
# Usage: Scripts/acceptance/m0-acceptance.sh [--record]
#   --record   write the output to reports/m0-acceptance.txt (default: a file in a temporary directory,
#              so that running the suite leaves the working tree untouched)
# Environment: RELAY_SWIFT_JOBS=<n> caps build parallelism.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

RECORD=0
for arg in "$@"; do
    case "${arg}" in
        --record) RECORD=1 ;;
        *)
            echo "error: unknown argument '${arg}' (usage: m0-acceptance.sh [--record])" >&2
            exit 2
            ;;
    esac
done

if [[ "${RECORD}" -eq 1 ]]; then
    mkdir -p "${ROOT_DIR}/reports"
    REPORT_FILE="${ROOT_DIR}/reports/m0-acceptance.txt"
else
    REPORT_FILE="$(mktemp -d "${TMPDIR:-/tmp}/relayide-report.XXXXXX")/m0-acceptance.txt"
fi

SWIFT_JOBS_ARGS=""
if [[ -n "${RELAY_SWIFT_JOBS:-}" ]]; then
    SWIFT_JOBS_ARGS="-j ${RELAY_SWIFT_JOBS}"
fi

# Recorded before anything is written. reports/ is left out because --record rewrites it.
if [[ -z "$(git status --porcelain -- . ':(exclude)reports')" ]]; then
    TREE_STATE="working tree clean outside reports/"
else
    TREE_STATE="working tree has uncommitted changes outside reports/"
fi

run_suite() {
    echo "================================================================"
    echo "RelayIDE M0 Acceptance Suite"
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Commit:    $(git rev-parse --short HEAD) (branch: $(git rev-parse --abbrev-ref HEAD); ${TREE_STATE})"
    echo "Tools:     $(git --version); $(/usr/bin/python3 --version 2>&1); node $(node --version 2>/dev/null || echo 'not found'); $(/usr/bin/xcrun swiftc --version 2>&1 | head -1)"
    echo "================================================================"

    # shellcheck disable=SC2086
    swift build ${SWIFT_JOBS_ARGS} >/dev/null
    RELAY_CLI="${ROOT_DIR}/Scripts/acceptance/relay-cli.sh"
    MERGE_CASES="${ROOT_DIR}/Fixtures/merge-cases"
    SYNTAX_CASES="${ROOT_DIR}/Fixtures/syntax-gate-cases"

    WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/relayide-m0-acc.XXXXXX")"
    trap 'rm -rf "${WORK_TMP}"' EXIT
    export RELAY_CLI_HOME="${WORK_TMP}/home"

    pass_row() {
        echo "[PASS] $1"
    }
    fail_row() {
        echo "[FAIL] $1" >&2
        exit 1
    }
    # Plain `git merge-file -p` with default settings, outside any repository and without user configuration.
    reference_git_merge() {
        (cd "${WORK_TMP}" && HOME="${WORK_TMP}/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null LC_ALL=C \
            git merge-file -p -L left -L base -L right "$2" "$1" "$3")
    }

    # ------------------------------------------------------------------
    # Row 1: build + README first paragraph states M2 scope & boundaries truthfully (R48, R63)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 1: swift build + README.md & README.zh-CN.md opening M2 scope disclosure (R48, R63) ---"
    "${RELAY_CLI}" version >/dev/null || fail_row "Row 1: built executable does not answer 'version' through ${RELAY_CLI}"
    /usr/bin/python3 - "${ROOT_DIR}/README.md" "${ROOT_DIR}/README.zh-CN.md" <<'PY'
import sys

en_path, zh_path = sys.argv[1], sys.argv[2]
en_text = open(en_path, encoding="utf-8").read()
zh_text = open(zh_path, encoding="utf-8").read()

def first_prose_paragraph(md: str) -> str:
    blocks = [b.strip() for b in md.split("\n\n") if b.strip()]
    for b in blocks:
        if b.startswith("#") or b.startswith("**English**") or b.startswith("**[English]"):
            continue
        if b.startswith("**macOS") or b.startswith("**面向 macOS"):
            continue
        return b
    return ""

en_p1 = first_prose_paragraph(en_text)
zh_p1 = first_prose_paragraph(zh_text)
print("EN para 1:", en_p1)
print("ZH para 1:", zh_p1)

for req_en in [
    "install `agent-relay` first",
    "`RelayIDE run`",
    "isolated Git worktrees via `agent-relay`",
    "`git merge --no-ff`",
    "runs optional `verify`",
    "`integration.ready`",
    "never merges into `base`",
    "`RELAY_BUDGET_USD`",
    "whole-job USD budget",
    "read-only live view",
    "no broadcast input bar",
    "screenshots in `docs/` are rendered from `--demo` synthetic data",
]:
    assert req_en in en_p1, f"README.md first paragraph missing M5 disclosure {req_en!r}"
assert "does not launch coding agents yet" not in en_text, "Stale M0 no-agent statement left in README.md"
assert "does not merge branches" not in en_text, "Stale M1 no-merge statement left in README.md"
assert "does not execute `verify`" not in en_text, "Stale M1 no-verify statement left in README.md"
assert "no whole-job budget" not in en_text, "Stale M2 no-budget statement left in README.md"
assert "does not connect the desktop UI to live runs yet" not in en_text, "Stale M4 no-live-UI statement left in README.md"

for req_zh in [
    "先安装 `agent-relay`",
    "`RelayIDE run`",
    "Git worktree",
    "`git merge --no-ff`",
    "执行可选的 `verify`",
    "`integration.ready`",
    "不把集成分支合入 `base`",
    "`RELAY_BUDGET_USD`",
    "整单美元预算",
    "只读实时视图",
    "没有广播输入栏",
    "现有截图由 `--demo` 演示数据合成",
]:
    assert req_zh in zh_p1, f"README.zh-CN.md first paragraph missing M5 disclosure {req_zh!r}"
assert "尚不会启动任何 coding agent" not in zh_text, "Stale M0 no-agent statement left in README.zh-CN.md"
assert "还不自动合并分支" not in zh_text, "Stale M1 no-merge statement left in README.zh-CN.md"
assert "不执行 `verify`" not in zh_text, "Stale M1 no-verify statement left in README.zh-CN.md"
assert "没有整单预算" not in zh_text, "Stale M2 no-budget statement left in README.zh-CN.md"
assert "桌面界面也尚未接入真实运行" not in zh_text, "Stale M4 no-live-UI statement left in README.zh-CN.md"

assert "—" not in en_text and "—" not in zh_text, "Em-dash found in README"
for forbidden in ["LOC", "zero external dependencies", "129 automated", "129 项", "forkpty"]:
    assert forbidden not in en_text and forbidden not in zh_text, f"Token {forbidden!r} found in README"
PY
    pass_row "Row 1: swift build succeeded and README.md & README.zh-CN.md state agent-relay runner, git merge --no-ff, verify, integration.ready, RELAY_BUDGET_USD whole-job budget, read-only live desktop UI, demo screenshot note, and untouched-base boundaries in paragraph 1"

    # ------------------------------------------------------------------
    # Row 2: --help, version, status (empty project) exit 0; [DEMO] / [演示数据] markers
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 2: --help, version, status (empty project) exit 0 + [DEMO] / [演示数据] markers (EN + ZH) ---"
    HELP_EN="$("${RELAY_CLI}" --help --lang en)"
    HELP_ZH="$("${RELAY_CLI}" --help --lang zh)"
    VER_EN="$("${RELAY_CLI}" version --lang en)"
    VER_ZH="$("${RELAY_CLI}" version --lang zh)"
    echo "version (--lang en): ${VER_EN}"
    echo "version (--lang zh): ${VER_ZH}"
    [[ "${HELP_EN}" != *"semantic-merge"* ]] || fail_row "Row 2: EN --help still lists removed semantic-merge"
    [[ "${HELP_EN}" != *"relay_semantic_merge"* ]] || fail_row "Row 2: EN --help still lists removed relay_semantic_merge"
    [[ "${HELP_EN}" == *"1 tool: relay_check_ownership"* ]] || fail_row "Row 2: EN --help does not list 1 MCP tool (relay_check_ownership)"
    [[ "${HELP_ZH}" != *"semantic-merge"* ]] || fail_row "Row 2: ZH --help still lists removed semantic-merge"
    [[ "${HELP_ZH}" != *"relay_semantic_merge"* ]] || fail_row "Row 2: ZH --help still lists removed relay_semantic_merge"
    [[ "${HELP_ZH}" == *"1 个工具：relay_check_ownership"* ]] || fail_row "Row 2: ZH --help does not list 1 MCP tool (relay_check_ownership)"

    for lang in en zh; do
        EMPTY_PROJ="${WORK_TMP}/clean-empty-${lang}.relayproj"
        "${RELAY_CLI}" init --project "${EMPTY_PROJ}" --lang "${lang}" >/dev/null
        STATUS_JSON="$("${RELAY_CLI}" status --project "${EMPTY_PROJ}" --lang "${lang}")"
        echo "Empty workspace status JSON (--lang ${lang}): ${STATUS_JSON}"
        /usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["activeLaneCount"]==0 and d["totalSpendUSD"]==0, d' "${STATUS_JSON}"
        LANES_EMPTY="$("${RELAY_CLI}" lanes --project "${EMPTY_PROJ}" --lang "${lang}")"
        WAVES_EMPTY="$("${RELAY_CLI}" dag-waves --project "${EMPTY_PROJ}" --lang "${lang}")"
        echo "Empty workspace lanes (--lang ${lang}): '${LANES_EMPTY}'; dag-waves: '${WAVES_EMPTY}'"
        [[ -z "${LANES_EMPTY}" ]] || fail_row "Row 2: a freshly initialised workspace lists lanes (${lang})"
    done

    SEED_EN_OUT="$("${RELAY_CLI}" init --project "${WORK_TMP}/demo-en.relayproj" --seed-demo --lang en)"
    SEED_ZH_OUT="$("${RELAY_CLI}" init --project "${WORK_TMP}/demo-zh.relayproj" --seed-demo --lang zh)"
    echo "EN seed output: ${SEED_EN_OUT}"
    echo "ZH seed output: ${SEED_ZH_OUT}"
    [[ "${SEED_EN_OUT}" == *"[DEMO]"* ]] || fail_row "Row 2: EN init --seed-demo missing [DEMO]"
    [[ "${SEED_ZH_OUT}" == *"[演示数据]"* ]] || fail_row "Row 2: ZH init --seed-demo missing [演示数据]"

    "${RELAY_CLI}" export-html "${WORK_TMP}/dossier-test.html" --project "${WORK_TMP}/demo-zh.relayproj" --lang zh >/dev/null
    grep -q '\[DEMO\]' "${WORK_TMP}/dossier-test.html" || fail_row "Row 2: exported HTML missing [DEMO]"
    grep -q '\[演示数据\]' "${WORK_TMP}/dossier-test.html" || fail_row "Row 2: exported HTML missing [演示数据]"
    grep -q '\[DEMO\]' "${ROOT_DIR}/docs/demo-relay-dossier.html" || fail_row "Row 2: docs/demo-relay-dossier.html missing [DEMO]"
    grep -q '\[演示数据\]' "${ROOT_DIR}/docs/demo-relay-dossier.html" || fail_row "Row 2: docs/demo-relay-dossier.html missing [演示数据]"
    pass_row "Row 2: --help, version, status (empty project) exit 0 (EN+ZH) and [DEMO]/[演示数据] markers verified"

    # ------------------------------------------------------------------
    # Row 3: nonexistent --project -> non-zero exit, nothing created
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 3: Nonexistent --project error & zero directory creation (EN + ZH) ---"
    for lang in en zh; do
        MISSING_PROJ="${WORK_TMP}/does-not-exist-${lang}-${RANDOM}.relayproj"
        for subcmd in status lanes dag-waves audit-plugins export-html mcp; do
            set +e
            if [[ "${subcmd}" == "export-html" ]]; then
                OUT_ERR="$("${RELAY_CLI}" "${subcmd}" "${WORK_TMP}/unused.html" --project "${MISSING_PROJ}" --lang "${lang}" 2>&1 >/dev/null)"
                RC=$?
            else
                OUT_ERR="$("${RELAY_CLI}" "${subcmd}" --project "${MISSING_PROJ}" --lang "${lang}" </dev/null 2>&1 >/dev/null)"
                RC=$?
            fi
            set -e
            if [[ "${RC}" -eq 0 ]]; then
                fail_row "Row 3: '${subcmd} --project ${MISSING_PROJ} --lang ${lang}' exited 0 on nonexistent project"
            fi
            if [[ -z "${OUT_ERR}" ]]; then
                fail_row "Row 3: '${subcmd} --lang ${lang}' produced empty stderr on nonexistent project"
            fi
            if [[ -e "${MISSING_PROJ}" ]]; then
                fail_row "Row 3: '${subcmd} --lang ${lang}' created nonexistent directory ${MISSING_PROJ}"
            fi
        done
        echo "Verified nonexistent --project across 6 subcommands (--lang ${lang}, exit=${RC}): last stderr='${OUT_ERR}'"
    done
    pass_row "Row 3: Nonexistent --project exits non-zero (1) without creating directory across all 6 project subcommands (EN+ZH)"

    # ------------------------------------------------------------------
    # Row 4: `semantic-merge` CLI subcommand has been removed per M3 decision (2026-11-21) and exits 2 as unknown subcommand.
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 4: removed semantic-merge exits 2 with empty stdout across Fixtures/merge-cases & syntax-gate-cases (EN + ZH) ---"
    CASE09_DIR="${MERGE_CASES}/09-py-triplequote"
    CASE12_DIR="${MERGE_CASES}/12-swift-true-conflict"
    mkdir -p "${WORK_TMP}/empty-path"
    for lang in en zh; do
        EXPECTED_UNKNOWN_MSG="Unknown subcommand 'semantic-merge'"
        if [[ "${lang}" == "zh" ]]; then
            EXPECTED_UNKNOWN_MSG="未知子命令 'semantic-merge'"
        fi

        for tag_case in "case09:${CASE09_DIR}/base.py:${CASE09_DIR}/left.py:${CASE09_DIR}/right.py" "case12:${CASE12_DIR}/base.swift:${CASE12_DIR}/left.swift:${CASE12_DIR}/right.swift"; do
            IFS=':' read -r tag b_arg l_arg r_arg <<<"${tag_case}"
            OUT_STDOUT="${WORK_TMP}/${tag}-${lang}.stdout"
            OUT_STDERR="${WORK_TMP}/${tag}-${lang}.stderr"
            set +e
            "${RELAY_CLI}" semantic-merge "${b_arg}" "${l_arg}" "${r_arg}" --lang "${lang}" >"${OUT_STDOUT}" 2>"${OUT_STDERR}"
            RC=$?
            set -e
            echo "${tag} semantic-merge (--lang ${lang}): exit=${RC}, stdout_bytes=$(wc -c < "${OUT_STDOUT}" | tr -d ' '), stderr='$(tr '\n' ' ' < "${OUT_STDERR}")'"
            [[ "${RC}" -eq 2 ]] || fail_row "Row 4: expected exit 2 on removed semantic-merge (${tag}, ${lang}), got ${RC}"
            [[ ! -s "${OUT_STDOUT}" ]] || fail_row "Row 4: expected empty stdout on removed semantic-merge (${tag}, ${lang})"
            grep -qF "${EXPECTED_UNKNOWN_MSG}" "${OUT_STDERR}" || fail_row "Row 4: stderr missing '${EXPECTED_UNKNOWN_MSG}' (${tag}, ${lang})"
        done

        set +e
        RELAY_CLI_CHILD_PATH="${WORK_TMP}/empty-path" "${RELAY_CLI}" semantic-merge "${CASE09_DIR}/base.py" "${CASE09_DIR}/left.py" "${CASE09_DIR}/right.py" --lang "${lang}" >"${WORK_TMP}/nogit-${lang}.stdout" 2>"${WORK_TMP}/nogit-${lang}.stderr"
        RC_NOGIT=$?
        set -e
        [[ "${RC_NOGIT}" -eq 2 ]] || fail_row "Row 4: expected exit 2 without git on removed semantic-merge (${lang}), got ${RC_NOGIT}"
        [[ ! -s "${WORK_TMP}/nogit-${lang}.stdout" ]] || fail_row "Row 4: expected empty stdout without git (${lang})"
    done

    echo ""
    echo "Independent removal check across all 40 cases (Scripts/acceptance/merge_cases_check.py, --lang en & zh):"
    /usr/bin/python3 "${ROOT_DIR}/Scripts/acceptance/merge_cases_check.py" --cli "${RELAY_CLI}" --cases "${MERGE_CASES}" --lang en >"${WORK_TMP}/merge-en.txt" \
        || { cat "${WORK_TMP}/merge-en.txt"; fail_row "Row 4: merge-case removal check failed (--lang en)"; }
    tail -n 3 "${WORK_TMP}/merge-en.txt"
    /usr/bin/python3 "${ROOT_DIR}/Scripts/acceptance/merge_cases_check.py" --cli "${RELAY_CLI}" --cases "${MERGE_CASES}" --lang zh >"${WORK_TMP}/merge-zh.txt" \
        || { cat "${WORK_TMP}/merge-zh.txt"; fail_row "Row 4: merge-case removal check failed (--lang zh)"; }
    tail -n 3 "${WORK_TMP}/merge-zh.txt"

    for lang in en zh; do
        /usr/bin/python3 "${ROOT_DIR}/Scripts/acceptance/merge_cases_check.py" --cli "${RELAY_CLI}" --cases "${SYNTAX_CASES}" --lang "${lang}" >"${WORK_TMP}/syntax-${lang}.txt" \
            || { cat "${WORK_TMP}/syntax-${lang}.txt"; fail_row "Row 4: syntax-gate removal check failed (--lang ${lang})"; }
    done
    tail -n 2 "${WORK_TMP}/syntax-en.txt"
    pass_row "Row 4: removed semantic-merge exits 2 with empty stdout and unknown-subcommand stderr across all 40 fixture cases (EN+ZH)"

    # ------------------------------------------------------------------
    # Row 5: MCP `relay_semantic_merge` removed -> returns the same error as any other unknown tool
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 5: MCP tools/call rejects removed relay_semantic_merge identically to any other unknown tool ---"
    /usr/bin/python3 - "${RELAY_CLI}" "${CASE12_DIR}" "${CASE09_DIR}" <<'PY'
import json, os, subprocess, sys

cli, case12, case09 = sys.argv[1:4]

def read(directory, name):
    return open(os.path.join(directory, name), encoding="utf-8").read()

requests = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "relay_semantic_merge",
        "arguments": {"path": "Conflict.swift", "base": read(case12, "base.swift"), "left": read(case12, "left.swift"), "right": read(case12, "right.swift")},
    }},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
        "name": "relay_semantic_merge",
        "arguments": {"path": "tpl.py", "base": read(case09, "base.py"), "left": read(case09, "left.py"), "right": read(case09, "right.py")},
    }},
    {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
        "name": "unknown_tool_probe",
        "arguments": {},
    }},
    {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
        "name": "relay_check_ownership",
        "arguments": {"relativePath": "Tests/SampleTests.swift", "allowedGlobs": ["Tests/**"]},
    }},
]
payload = "\n".join(json.dumps(r) for r in requests) + "\n"
proc = subprocess.run([cli, "mcp"], input=payload, capture_output=True, text=True, timeout=60)
assert proc.returncode == 0, f"mcp exited {proc.returncode}: {proc.stderr}"
replies = {m["id"]: m["result"] for m in (json.loads(line) for line in proc.stdout.splitlines() if line.strip())}

for req_id in (2, 3):
    res = replies[req_id]
    print(f"MCP relay_semantic_merge call {req_id}: {res}")
    assert res.get("isError") is True, res
    assert res.get("content") == [{"type": "text", "text": "Unknown tool 'relay_semantic_merge'"}], res

probe = replies[4]
print(f"MCP unknown_tool_probe call: {probe}")
assert probe.get("isError") is True, probe
assert probe.get("content") == [{"type": "text", "text": "Unknown tool 'unknown_tool_probe'"}], probe

own = replies[5]
assert own.get("isError") is False, own
PY
    pass_row "Row 5: MCP tools/call rejects removed relay_semantic_merge with isError=true and 'Unknown tool' matching unknown_tool_probe"

    # ------------------------------------------------------------------
    # Row 6: MCP tools/list matches README.md & README.zh-CN.md (1 tool: relay_check_ownership)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 6: MCP tools/list count & tool names vs README.md and README.zh-CN.md ---"
    /usr/bin/python3 - "${RELAY_CLI}" "${ROOT_DIR}/README.md" "${ROOT_DIR}/README.zh-CN.md" <<'PY'
import json, re, subprocess, sys

cli, en_readme, zh_readme = sys.argv[1], sys.argv[2], sys.argv[3]
payload = "\n".join([
    json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
]) + "\n"
proc = subprocess.run([cli, "mcp"], input=payload, capture_output=True, text=True, timeout=30)
assert proc.returncode == 0
msgs = {m["id"]: m["result"] for m in (json.loads(l) for l in proc.stdout.splitlines() if l.strip())}
tools = msgs[2]["tools"]
names = [t["name"] for t in tools]
print(f"MCP tools/list returned {len(tools)} tool(s): {names}")
assert names == ["relay_check_ownership"], f"Unexpected tools: {names}"
assert "relay_semantic_merge" not in names

en_txt = open(en_readme, encoding="utf-8").read()
zh_txt = open(zh_readme, encoding="utf-8").read()
assert "1 MCP tool" in en_txt, "README.md missing exact '1 MCP tool' count"
assert "1 个 MCP 工具" in zh_txt, "README.zh-CN.md missing exact '1 个 MCP 工具' count"
for tool_name in names:
    assert tool_name in en_txt, f"README.md missing {tool_name}"
    assert tool_name in zh_txt, f"README.zh-CN.md missing {tool_name}"
assert "relay_semantic_merge" not in en_txt, "README.md still mentions removed relay_semantic_merge"
assert "relay_semantic_merge" not in zh_txt, "README.zh-CN.md still mentions removed relay_semantic_merge"
assert re.search(r"\b([2-9]|\d{2,})\s+MCP tools?", en_txt) is None, "Inflated MCP count found in README.md"
assert re.search(r"([2-9]|\d{2,})\s*个\s*MCP\s*工具", zh_txt) is None, "Inflated MCP count found in README.zh-CN.md"
for token in ("reports/m3-merge-eval.md", "1/330", "0/377", "0/611"):
    assert token in en_txt, f"README.md missing M3 removal evidence token {token!r}"
    assert token in zh_txt, f"README.zh-CN.md missing M3 removal evidence token {token!r}"
PY
    pass_row "Row 6: MCP tools/list exposes 1 tool (relay_check_ownership, omitting relay_semantic_merge), matching README.md & README.zh-CN.md"

    # ------------------------------------------------------------------
    # Rows 7 & 8: default UI state, verified WITHOUT opening a window.
    #   The desktop app builds exactly one RelayStudioViewModel from its arguments. The headless tests build the same
    #   view model (default launch, and opening a freshly initialised .relayproj) and assert that it stays empty.
    # Added row A (C2): running the tests must not add a file to ~/Library/Preferences.
    #   The same test run also covers the script guards (C1), the README replay rules (C4) and the CLI contracts.
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 7 & Row 8 + added row A: headless view-model tests, no preference files written ---"
    PREFS_DIR="${HOME}/Library/Preferences"
    ls -1 "${PREFS_DIR}" 2>/dev/null | sort >"${WORK_TMP}/prefs-before.txt"
    TEST_LOG="${WORK_TMP}/row7-8-tests.log"
    set +e
    # shellcheck disable=SC2086
    swift test ${SWIFT_JOBS_ARGS} --no-parallel --filter 'StudioViewModelAndHonestyTests|CLIMCPAndWorkbenchShellTests' >"${TEST_LOG}" 2>&1
    TEST_RC=$?
    set -e
    sleep 2
    ls -1 "${PREFS_DIR}" 2>/dev/null | sort >"${WORK_TMP}/prefs-after.txt"
    grep -E '^✘ Test ' "${TEST_LOG}" || true
    grep -E '^(✔|✘) Test run with ' "${TEST_LOG}" || true
    [[ "${TEST_RC}" -eq 0 ]] || { tail -40 "${TEST_LOG}"; fail_row "Row 7/8: swift test exited ${TEST_RC}"; }
    require_passed() {
        grep -qF "Test \"$1\" passed" "${TEST_LOG}" || fail_row "$2: test \"$1\" did not run or did not pass"
        echo "passed: $1"
    }
    require_passed "RelayStudioViewModel starts completely empty without --demo in both EN and ZH (Row 7)" "Row 7"
    pass_row "Row 7: default RelayStudioViewModel (no --demo) has 0 lanes, no terminal content, no spend, no proxy address (EN+ZH, headless)"
    require_passed "Opening an empty user .relayproj in RelayStudioViewModel never seeds demo lanes into disk DB (Row 8)" "Row 8"
    pass_row "Row 8: opening a freshly initialised .relayproj in RelayStudioViewModel leaves 0 lanes on disk (headless)"

    require_passed "Acceptance scripts reach the product binary only through the headless-subcommand wrapper (C1)" "Added row"
    require_passed "UserDefaults used by tests are stored in a temporary directory, never in ~/Library/Preferences (C2)" "Added row A"
    require_passed "readme-commands.sh replays the commands found in README.md and README.zh-CN.md instead of a hand-kept copy (C4)" "Added row"
    PREFS_BEFORE="$(wc -l <"${WORK_TMP}/prefs-before.txt" | tr -d ' ')"
    PREFS_AFTER="$(wc -l <"${WORK_TMP}/prefs-after.txt" | tr -d ' ')"
    NEW_PREFS="$(comm -13 "${WORK_TMP}/prefs-before.txt" "${WORK_TMP}/prefs-after.txt")"
    NEW_RELAY_PREFS="$(printf '%s\n' "${NEW_PREFS}" | grep -E '^(io\.relayide\.|io\.github\.zxu756\.RelayIDE)' || true)"
    echo "~/Library/Preferences entries: before=${PREFS_BEFORE}, after=${PREFS_AFTER}; new RelayIDE entries: $(printf '%s' "${NEW_RELAY_PREFS}" | grep -c . || true)"
    if [[ -n "${NEW_PREFS}" ]]; then
        echo "entries that appeared during the test run (other programs on this machine also write here):"
        printf '%s\n' "${NEW_PREFS}"
    fi
    [[ -z "${NEW_RELAY_PREFS}" ]] || fail_row "Added row A: the test run left RelayIDE preference files in ~/Library/Preferences: ${NEW_RELAY_PREFS}"
    pass_row "Added row A: the test run added no RelayIDE file to ~/Library/Preferences (entries before=${PREFS_BEFORE}, after=${PREFS_AFTER})"

    # ------------------------------------------------------------------
    # Row 9: repo-wide search for the fake broadcast echo and verification that the local proxy has been removed (M4)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 9: Repo-wide grep for forbidden fake echo & verification that local proxy is removed ---"
    PAT_ECHO="Executed across isolated"
    PAT_ECHO="${PAT_ECHO} worktree"
    PAT_PORT="127.0.0.1"
    PAT_PORT="${PAT_PORT}:43118"

    /usr/bin/python3 - "${ROOT_DIR}" "${PAT_ECHO}" "${PAT_PORT}" <<'PY'
import os, sys

root, pat_echo, pat_port = sys.argv[1], sys.argv[2], sys.argv[3]
skip_dirs = {".git", ".build", "build"}
hits_outside_tests = []
hits_in_tests = []

removed_paths = [
    "Sources/" + "RelayWiretap" + "Proxy",
    "Tests/RelayIDETests/" + "WiretapSSEAndDLP" + "CircuitBreakerTests.swift",
    "docs/" + "screenshot-wiretap" + "-guardrails.png",
    "docs/" + "screenshot-wiretap" + "-guardrails-zh.png",
]
for rel_removed in removed_paths:
    assert not os.path.exists(os.path.join(root, rel_removed)), f"Removed proxy path still exists: {rel_removed}"

pkg_text = open(os.path.join(root, "Package.swift"), encoding="utf-8").read()
mod_name = "RelayWiretap" + "Proxy"
assert mod_name not in pkg_text, f"Package.swift still references {mod_name}"

proxy_tokens = [
    mod_name,
    "LoopbackWiretap" + "ProxyServer",
    "OutboundSecret" + "DLPEngine",
    "screenshot-wiretap" + "-guardrails",
    pat_port,
]
proxy_ci_tokens = [
    "outbound secret " + "dlp",
]
checked_proxy_hits = []

for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in skip_dirs]
    for fn in filenames:
        if fn.endswith((".png", ".jpg", ".icns", ".sqlite", ".o", ".dylib")):
            continue
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, root)
        try:
            text = open(full, encoding="utf-8").read()
        except UnicodeDecodeError:
            continue
        for pat in (pat_echo, pat_port):
            if pat in text:
                if rel.startswith("Tests/"):
                    hits_in_tests.append((rel, pat))
                else:
                    hits_outside_tests.append((rel, pat))
        if rel in ("Package.swift", "README.md", "README.zh-CN.md") or rel.startswith(("Sources/", "Tests/")):
            lower = text.lower()
            for tok in proxy_tokens:
                if tok in text:
                    checked_proxy_hits.append((rel, tok))
            for tok_ci in proxy_ci_tokens:
                if tok_ci in lower:
                    checked_proxy_hits.append((rel, tok_ci))

print(f"Removed proxy paths verified absent: {removed_paths}")
print(f"Occurrences inside Tests/: {len(hits_in_tests)} -> {[h[0] for h in hits_in_tests]}")
print(f"Occurrences outside Tests/: {len(hits_outside_tests)}")
print(f"Proxy/DLP hits in Package.swift, Sources/, Tests/, README*: {len(checked_proxy_hits)}")
assert not hits_outside_tests, f"Forbidden fake strings found outside Tests/: {hits_outside_tests}"
assert not checked_proxy_hits, f"Removed proxy/DLP symbols still present: {checked_proxy_hits}"
PY
    pass_row "Row 9: Local proxy removed (Package.swift, Sources/, Tests/, README*) and zero occurrences of fake broadcast echo or fake wiretap port"

    # ------------------------------------------------------------------
    # Added row B (C5): no path of a real machine in committed files.
    #   A git grep for the macOS home-directory prefix cannot be empty in this repository: the outbound-secret
    #   scanner's patterns exist to match such paths, its tests feed it sample paths, and the demo workspace uses an
    #   invented one. The check therefore lists every match and fails on any home directory name that is not one of
    #   those placeholders, which is what a leaked local path would be.
    #   (The prefix is assembled at run time so that this script does not match itself.)
    # ------------------------------------------------------------------
    HOME_PREFIX="/Users"
    HOME_PREFIX="${HOME_PREFIX}/"
    echo ""
    echo "--- Added row B: git grep -n for the macOS home-directory prefix ---"
    git grep -n "${HOME_PREFIX}" >"${WORK_TMP}/users-grep.txt" || true
    /usr/bin/python3 - "${WORK_TMP}/users-grep.txt" "${HOME_PREFIX}" <<'PY'
import re, sys

prefix = sys.argv[2]
placeholders = {"alice", "developer", "test", "shared", "<name>", "<user>"}
lines = [l.rstrip("\n") for l in open(sys.argv[1], encoding="utf-8") if l.strip()]
leaks = []
for line in lines:
    content = line.split(":", 2)[-1]
    for name in re.findall(re.escape(prefix) + r"([^/\s\"'`)]+)", content):
        if name in placeholders or name.startswith("["):
            continue
        leaks.append((line, name))
# The matched text itself is not echoed, so that a recorded report does not add matches of its own.
print(f"git grep -n for the home-directory prefix prints {len(lines)} line(s):")
for line in lines:
    location = ":".join(line.split(":", 2)[:2])
    names = re.findall(re.escape(prefix) + r"([^/\s\"'`)]+)", line.split(":", 2)[-1])
    print(f"  {location}  home directory name(s): {', '.join(names) if names else '(prefix only, no name)'}")
assert not leaks, f"path of a real home directory in committed files: {[(l.split(':', 2)[:2], n) for l, n in leaks]}"
print("none of them names a real home directory (only scanner patterns, sample inputs and the invented demo path)")
PY
    pass_row "Added row B: no committed file contains the path of a real home directory (the literal expectation 'no output' is not met, see the list above)"

    # ------------------------------------------------------------------
    # Added row C (C1): this run started no desktop process
    # ------------------------------------------------------------------
    echo ""
    echo "--- Added row C: no RelayIDE desktop process was started ---"
    LEFTOVER="$("${RELAY_CLI}" --relay-cli-running-processes)"
    echo "RelayIDE processes from this checkout still running: ${LEFTOVER:-none}"
    [[ -z "${LEFTOVER}" ]] || fail_row "Added row C: a RelayIDE process from this checkout is still running"
    pass_row "Added row C: every product command went through relay-cli.sh (headless subcommands only); no RelayIDE process is left running"

    echo ""
    echo "================================================================"
    echo "ALL M0 ACCEPTANCE CHECKS PASSED (EN + ZH)"
    echo "================================================================"
}

# Absolute paths of this checkout are replaced so a recorded report carries no machine-specific path.
run_suite 2>&1 | sed "s|${ROOT_DIR}|<repo>|g" | tee "${REPORT_FILE}"
echo "Report written to ${REPORT_FILE}"
