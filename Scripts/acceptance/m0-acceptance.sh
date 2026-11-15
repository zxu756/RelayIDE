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
    # Row 1: build + README first paragraph states M1 scope & boundaries truthfully (R48)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 1: swift build + README.md & README.zh-CN.md opening M1 scope disclosure (R48) ---"
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
    "does not merge branches",
    "does not execute `verify`",
    "no whole-job budget",
]:
    assert req_en in en_p1, f"README.md first paragraph missing M1 disclosure {req_en!r}"
assert "does not launch coding agents yet" not in en_text, "Stale M0 no-agent statement left in README.md"

for req_zh in [
    "先安装 `agent-relay`",
    "`RelayIDE run`",
    "Git worktree",
    "还不自动合并分支",
    "不执行 `verify`",
    "没有整单预算",
]:
    assert req_zh in zh_p1, f"README.zh-CN.md first paragraph missing M1 disclosure {req_zh!r}"
assert "尚不会启动任何 coding agent" not in zh_text, "Stale M0 no-agent statement left in README.zh-CN.md"

assert "—" not in en_text and "—" not in zh_text, "Em-dash found in README"
for forbidden in ["LOC", "zero external dependencies", "129 automated", "129 项", "forkpty"]:
    assert forbidden not in en_text and forbidden not in zh_text, f"Token {forbidden!r} found in README"
PY
    pass_row "Row 1: swift build succeeded and README.md & README.zh-CN.md state M1 agent-relay runner scope, agent-relay prerequisite, and unmerged/no-verify/no-budget boundaries in paragraph 1"

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
    [[ "${HELP_EN}" == *"EXPERIMENTAL 3-way merge anchored on git merge-file"* ]] || fail_row "Row 2: EN --help does not describe semantic-merge as experimental and git-anchored"
    [[ "${HELP_EN}" == *"known to corrupt Python and Swift output, so its text is never printed"* ]] || fail_row "Row 2: EN --help does not state the declaration engine's known corruption"
    [[ "${HELP_ZH}" == *"【实验性】以 git merge-file 为准的三路合并"* ]] || fail_row "Row 2: ZH --help does not describe semantic-merge as experimental and git-anchored"
    [[ "${HELP_ZH}" == *"已知会损坏 Python 和 Swift 的输出，所以它的文本从不输出"* ]] || fail_row "Row 2: ZH --help does not state the declaration engine's known corruption"

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
    # Row 4: semantic-merge never exits 0 with a damaged result.
    #   The original row asked for a non-zero exit on 09-py-triplequote because the old engine printed broken
    #   Python for it. git merges that case cleanly; the command now prints git's text, which is valid Python,
    #   so exit 0 is correct there. What the row protects ("no exit 0 with output that fails py_compile") is
    #   checked on every case, together with the rework rule: exit 0 means no added line lost and no untouched
    #   line altered.
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 4: semantic-merge on 09-py-triplequote + every case in Fixtures/merge-cases (EN + ZH) ---"
    CASE09_DIR="${MERGE_CASES}/09-py-triplequote"
    reference_git_merge "${CASE09_DIR}/base.py" "${CASE09_DIR}/left.py" "${CASE09_DIR}/right.py" >"${WORK_TMP}/case09.git" \
        || fail_row "Row 4: git merge-file does not merge 09-py-triplequote cleanly"
    for lang in en zh; do
        OUT_STDOUT="${WORK_TMP}/case09-${lang}.py"
        OUT_STDERR="${WORK_TMP}/case09-${lang}.stderr"
        set +e
        "${RELAY_CLI}" semantic-merge "${CASE09_DIR}/base.py" "${CASE09_DIR}/left.py" "${CASE09_DIR}/right.py" --lang "${lang}" >"${OUT_STDOUT}" 2>"${OUT_STDERR}"
        RC=$?
        set -e
        echo "09-py-triplequote (--lang ${lang}): exit=${RC}, stdout_bytes=$(wc -c < "${OUT_STDOUT}" | tr -d ' '), stderr='$(tr '\n' ' ' < "${OUT_STDERR}")'"
        [[ "${RC}" -eq 0 ]] || fail_row "Row 4: expected exit 0 on 09-py-triplequote (${lang}), got ${RC}"
        cmp -s "${OUT_STDOUT}" "${WORK_TMP}/case09.git" || fail_row "Row 4: 09-py-triplequote output (${lang}) is not byte-identical to git merge-file"
        PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m py_compile "${OUT_STDOUT}" || fail_row "Row 4: 09-py-triplequote output (${lang}) fails py_compile"
    done
    echo "09-py-triplequote: output is byte-identical to 'git merge-file -p' and passes py_compile (EN+ZH)"

    echo ""
    echo "Independent check of all cases (Scripts/acceptance/merge_cases_check.py, --lang en):"
    /usr/bin/python3 "${ROOT_DIR}/Scripts/acceptance/merge_cases_check.py" --cli "${RELAY_CLI}" --cases "${MERGE_CASES}" --lang en \
        || fail_row "Row 4: merge-case check failed (--lang en)"
    echo ""
    echo "Same check with --lang zh (summary lines):"
    /usr/bin/python3 "${ROOT_DIR}/Scripts/acceptance/merge_cases_check.py" --cli "${RELAY_CLI}" --cases "${MERGE_CASES}" --lang zh >"${WORK_TMP}/merge-zh.txt" \
        || { cat "${WORK_TMP}/merge-zh.txt"; fail_row "Row 4: merge-case check failed (--lang zh)"; }
    tail -n 3 "${WORK_TMP}/merge-zh.txt"

    echo ""
    echo "Syntax gate (Fixtures/syntax-gate-cases: each side parses, git merges cleanly, the merged text does not parse):"
    for lang in en zh; do
        /usr/bin/python3 "${ROOT_DIR}/Scripts/acceptance/merge_cases_check.py" --cli "${RELAY_CLI}" --cases "${SYNTAX_CASES}" --lang "${lang}" --expect-all-exit 3 >"${WORK_TMP}/syntax-${lang}.txt" \
            || { cat "${WORK_TMP}/syntax-${lang}.txt"; fail_row "Row 4: syntax-gate check failed (--lang ${lang})"; }
    done
    cat "${WORK_TMP}/syntax-en.txt"
    tail -n 1 "${WORK_TMP}/syntax-zh.txt"

    echo ""
    echo "git not available (child PATH is an empty directory):"
    mkdir -p "${WORK_TMP}/empty-path"
    for lang in en zh; do
        set +e
        RELAY_CLI_CHILD_PATH="${WORK_TMP}/empty-path" "${RELAY_CLI}" semantic-merge "${CASE09_DIR}/base.py" "${CASE09_DIR}/left.py" "${CASE09_DIR}/right.py" --lang "${lang}" >"${WORK_TMP}/nogit-${lang}.stdout" 2>"${WORK_TMP}/nogit-${lang}.stderr"
        RC=$?
        set -e
        echo "no git (--lang ${lang}): exit=${RC}, stdout_bytes=$(wc -c < "${WORK_TMP}/nogit-${lang}.stdout" | tr -d ' '), stderr='$(tr '\n' ' ' < "${WORK_TMP}/nogit-${lang}.stderr")'"
        [[ "${RC}" -eq 4 ]] || fail_row "Row 4: expected exit 4 without git (${lang}), got ${RC}"
        [[ ! -s "${WORK_TMP}/nogit-${lang}.stdout" ]] || fail_row "Row 4: output printed although git is unavailable (${lang})"
    done
    pass_row "Row 4: no case exits 0 with lost, altered or unparsable content; 09-py-triplequote equals git merge-file; unparsable clean merges exit 3 with empty stdout; without git the command exits 4 (EN+ZH)"

    # ------------------------------------------------------------------
    # Row 5: 12-swift-true-conflict -> CLI exit 1 with git's conflict text, MCP isError: true
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 5: semantic-merge conflict contract on 12-swift-true-conflict (CLI + MCP) ---"
    CASE12_DIR="${MERGE_CASES}/12-swift-true-conflict"
    set +e
    reference_git_merge "${CASE12_DIR}/base.swift" "${CASE12_DIR}/left.swift" "${CASE12_DIR}/right.swift" >"${WORK_TMP}/case12.git"
    GIT12_RC=$?
    set -e
    [[ "${GIT12_RC}" -ge 1 && "${GIT12_RC}" -le 127 ]] || fail_row "Row 5: git merge-file does not report a conflict on 12-swift-true-conflict (status ${GIT12_RC})"
    for lang in en zh; do
        set +e
        "${RELAY_CLI}" semantic-merge "${CASE12_DIR}/base.swift" "${CASE12_DIR}/left.swift" "${CASE12_DIR}/right.swift" --lang "${lang}" >"${WORK_TMP}/case12-${lang}.stdout" 2>"${WORK_TMP}/case12-${lang}.stderr"
        RC12=$?
        set -e
        echo "12-swift-true-conflict CLI (--lang ${lang}): exit=${RC12}, stderr='$(tr '\n' ' ' < "${WORK_TMP}/case12-${lang}.stderr")'"
        [[ "${RC12}" -eq 1 ]] || fail_row "Row 5: expected CLI exit 1 on 12-swift-true-conflict (${lang}), got ${RC12}"
        cmp -s "${WORK_TMP}/case12-${lang}.stdout" "${WORK_TMP}/case12.git" || fail_row "Row 5: conflict output (${lang}) is not byte-identical to git merge-file"
    done

    /usr/bin/python3 - "${RELAY_CLI}" "${CASE12_DIR}" "${CASE09_DIR}" "${SYNTAX_CASES}/swift-string-delimiters" "${WORK_TMP}" <<'PY'
import json, os, subprocess, sys

cli, case12, case09, syntax_case, work = sys.argv[1:6]

def read(directory, name):
    return open(os.path.join(directory, name), encoding="utf-8").read()

def call(arguments, child_path=None):
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "relay_semantic_merge", "arguments": arguments}},
    ]
    payload = "\n".join(json.dumps(r) for r in requests) + "\n"
    env = dict(os.environ)
    if child_path is not None:
        env["RELAY_CLI_CHILD_PATH"] = child_path
    proc = subprocess.run([cli, "mcp"], input=payload, capture_output=True, text=True, timeout=60, env=env)
    assert proc.returncode == 0, f"mcp exited {proc.returncode}: {proc.stderr}"
    replies = {m["id"]: m["result"] for m in (json.loads(line) for line in proc.stdout.splitlines() if line.strip())}
    result = replies[2]
    texts = [c["text"] for c in result["content"]]
    return result.get("isError"), texts

conflict_args = {"path": "Conflict.swift", "base": read(case12, "base.swift"), "left": read(case12, "left.swift"), "right": read(case12, "right.swift")}
is_error, texts = call(conflict_args)
print("MCP 12-swift-true-conflict: isError =", is_error)
assert is_error is True, texts
assert texts[0] == open(os.path.join(work, "case12.git"), encoding="utf-8").read(), "MCP conflict text is not git's conflict text"

clean_args = {"path": "tpl.py", "base": read(case09, "base.py"), "left": read(case09, "left.py"), "right": read(case09, "right.py")}
is_error, texts = call(clean_args)
print("MCP 09-py-triplequote: isError =", is_error)
assert is_error is False, texts
assert texts[0] == open(os.path.join(work, "case09.git"), encoding="utf-8").read(), "MCP clean text is not git's text"

syntax_args = {"path": "Broken.swift", "base": read(syntax_case, "base.swift"), "left": read(syntax_case, "left.swift"), "right": read(syntax_case, "right.swift")}
is_error, texts = call(syntax_args)
print("MCP swift-string-delimiters (clean line merge that does not parse): isError =", is_error)
assert is_error is True and len(texts) == 1, texts

is_error, texts = call(clean_args, child_path=os.path.join(work, "empty-path"))
print("MCP without git: isError =", is_error)
assert is_error is True and len(texts) == 1 and "git" in texts[0], texts
PY
    pass_row "Row 5: 12-swift-true-conflict exits 1 with git's conflict text (EN+ZH); MCP isError is true for conflict, unparsable merge and missing git, false with git's text for 09-py-triplequote"

    # ------------------------------------------------------------------
    # Row 6: MCP tools/list matches README.md & README.zh-CN.md
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
print(f"MCP tools/list returned {len(tools)} tools: {names}")
assert names == ["relay_semantic_merge", "relay_check_ownership"], f"Unexpected tools: {names}"

en_txt = open(en_readme, encoding="utf-8").read()
zh_txt = open(zh_readme, encoding="utf-8").read()
assert "2 MCP tools" in en_txt, "README.md missing exact '2 MCP tools' count"
assert "2 个 MCP 工具" in zh_txt, "README.zh-CN.md missing exact '2 个 MCP 工具' count"
for tool_name in names:
    assert tool_name in en_txt, f"README.md missing {tool_name}"
    assert tool_name in zh_txt, f"README.zh-CN.md missing {tool_name}"
assert re.search(r"\b([3-9]|\d{2,})\s+MCP tools", en_txt) is None, "Inflated MCP count found in README.md"
assert re.search(r"([3-9]|\d{2,})\s*个\s*MCP\s*工具", zh_txt) is None, "Inflated MCP count found in README.zh-CN.md"
PY
    pass_row "Row 6: MCP tools/list exposes 2 tools (relay_semantic_merge, relay_check_ownership), matching README.md & README.zh-CN.md"

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
    # Row 9: repo-wide search for the fake broadcast echo and the fake proxy endpoint
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 9: Repo-wide grep for forbidden fake echo & fake proxy endpoint ---"
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

print(f"Occurrences inside Tests/: {len(hits_in_tests)} -> {[h[0] for h in hits_in_tests]}")
print(f"Occurrences outside Tests/: {len(hits_outside_tests)}")
assert not hits_outside_tests, f"Forbidden fake strings found outside Tests/: {hits_outside_tests}"
PY
    pass_row "Row 9: Zero occurrences of fake broadcast echo or fake wiretap port outside Tests/"

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
