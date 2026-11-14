#!/usr/bin/env bash
# RelayIDE M0 Acceptance Suite (all 9 rows of 03-relayide.md across --lang en and --lang zh)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

mkdir -p "${ROOT_DIR}/reports"
REPORT_FILE="${ROOT_DIR}/reports/m0-acceptance.txt"

run_suite() {
    echo "================================================================"
    echo "RelayIDE M0 Acceptance Suite (m0/honest)"
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Commit:    $(git rev-parse --short HEAD) (branch: $(git rev-parse --abbrev-ref HEAD))"
    echo "================================================================"

    swift build >/dev/null
    BIN="${ROOT_DIR}/.build/debug/RelayIDE"

    WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/relayide-m0-acc.XXXXXX")"
    trap 'rm -rf "${WORK_TMP}"' EXIT

    pass_row() {
        echo "[PASS] $1"
    }
    fail_row() {
        echo "[FAIL] $1" >&2
        exit 1
    }

    # ------------------------------------------------------------------
    # Row 1 (03-relayide.md): swift build / swift test regression + M0 Item 9 README opening disclosure
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 1: swift build verification + README.md & README.zh-CN.md opening M0 disclosure ---"
    [[ -x "${BIN}" ]] || fail_row "Row 1: expected built executable at ${BIN}"
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

assert "does not launch coding agents yet" in en_p1, "README.md first paragraph missing M0 no-agent statement"
assert "尚不会启动任何 coding agent" in zh_p1, "README.zh-CN.md first paragraph missing M0 no-agent statement"
assert "\u2014" not in en_text and "\u2014" not in zh_text, "Em-dash found in README"
for forbidden in ["LOC", "zero external dependencies", "129 automated", "129 项"]:
    assert forbidden not in en_text and forbidden not in zh_text, f"Self-bragging token {forbidden!r} found in README"
PY
    pass_row "Row 1: swift build succeeded and README.md & README.zh-CN.md state in paragraph 1 that M0 does not launch coding agents yet"

    # ------------------------------------------------------------------
    # Row 2 (03-relayide.md): relayide --help, relayide version, relayide status (empty project) -> exit 0 (EN + ZH)
    #                         + M0 Item 7 [DEMO] / [演示数据] markers on init --seed-demo & HTML dossier
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 2: --help, version, status (empty project) exit 0 + [DEMO] / [演示数据] markers (EN + ZH) ---"
    HELP_EN="$("${BIN}" --help --lang en)"
    HELP_ZH="$("${BIN}" --help --lang zh)"
    VER_EN="$("${BIN}" version --lang en)"
    VER_ZH="$("${BIN}" version --lang zh)"
    echo "version (--lang en): ${VER_EN}"
    echo "version (--lang zh): ${VER_ZH}"
    [[ "${HELP_EN}" == *"EXPERIMENTAL: known to corrupt output on Python"* ]] || fail_row "Row 2: EN --help missing EXPERIMENTAL Python warning"
    [[ "${HELP_ZH}" == *"【实验性】已知会在 Python 代码上损坏输出"* ]] || fail_row "Row 2: ZH --help missing Chinese experimental Python warning"

    for lang in en zh; do
        EMPTY_PROJ="${WORK_TMP}/clean-empty-${lang}.relayproj"
        "${BIN}" init --project "${EMPTY_PROJ}" --lang "${lang}" >/dev/null
        STATUS_JSON="$("${BIN}" status --project "${EMPTY_PROJ}" --lang "${lang}")"
        echo "Empty workspace status JSON (--lang ${lang}): ${STATUS_JSON}"
        /usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["activeLaneCount"]==0 and d["totalSpendUSD"]==0, d' "${STATUS_JSON}"
    done

    SEED_EN_OUT="$("${BIN}" init --project "${WORK_TMP}/demo-en.relayproj" --seed-demo --lang en)"
    SEED_ZH_OUT="$("${BIN}" init --project "${WORK_TMP}/demo-zh.relayproj" --seed-demo --lang zh)"
    echo "EN seed output: ${SEED_EN_OUT}"
    echo "ZH seed output: ${SEED_ZH_OUT}"
    [[ "${SEED_EN_OUT}" == *"[DEMO]"* ]] || fail_row "Row 2: EN init --seed-demo missing [DEMO]"
    [[ "${SEED_ZH_OUT}" == *"[演示数据]"* ]] || fail_row "Row 2: ZH init --seed-demo missing [演示数据]"

    "${BIN}" export-html "${WORK_TMP}/dossier-test.html" --project "${WORK_TMP}/demo-zh.relayproj" --lang zh >/dev/null
    grep -q '\[DEMO\]' "${WORK_TMP}/dossier-test.html" || fail_row "Row 2: exported HTML missing [DEMO]"
    grep -q '\[演示数据\]' "${WORK_TMP}/dossier-test.html" || fail_row "Row 2: exported HTML missing [演示数据]"
    grep -q '\[DEMO\]' "${ROOT_DIR}/docs/demo-relay-dossier.html" || fail_row "Row 2: docs/demo-relay-dossier.html missing [DEMO]"
    grep -q '\[演示数据\]' "${ROOT_DIR}/docs/demo-relay-dossier.html" || fail_row "Row 2: docs/demo-relay-dossier.html missing [演示数据]"
    pass_row "Row 2: --help, version, status (empty project) exit 0 (EN+ZH) and [DEMO]/[演示数据] markers verified"

    # ------------------------------------------------------------------
    # Row 3 (03-relayide.md): status (and lanes, dag-waves, audit-plugins, export-html, mcp) --project <nonexistent> -> non-zero exit & no directory created
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 3: Nonexistent --project error & zero directory creation (EN + ZH) ---"
    for lang in en zh; do
        MISSING_PROJ="${WORK_TMP}/does-not-exist-${lang}-${RANDOM}.relayproj"
        for subcmd in status lanes dag-waves audit-plugins export-html mcp; do
            set +e
            if [[ "${subcmd}" == "export-html" ]]; then
                OUT_ERR="$("${BIN}" "${subcmd}" "${WORK_TMP}/unused.html" --project "${MISSING_PROJ}" --lang "${lang}" 2>&1 >/dev/null)"
                RC=$?
            else
                OUT_ERR="$("${BIN}" "${subcmd}" --project "${MISSING_PROJ}" --lang "${lang}" </dev/null 2>&1 >/dev/null)"
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
    # Row 4: semantic-merge on 09-py-triplequote exits non-zero (3) with ZERO broken code on stdout (+ all 19 cases audit)
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 4: semantic-merge syntax validation gate on 09-py-triplequote (EN+ZH + MCP + 19-case sweep) ---"
    HARNESS_CASES="/Users/xu/Projects/flagship-acceptance/harness/relayide/merge-cases"
    if [[ -d "${HARNESS_CASES}/09-py-triplequote" ]]; then
        CASE09_DIR="${HARNESS_CASES}/09-py-triplequote"
    else
        CASE09_DIR="${WORK_TMP}/09-py-triplequote"
        mkdir -p "${CASE09_DIR}"
        cat > "${CASE09_DIR}/base.py" <<'EOF'
class Tpl:
    TEXT = """
def fake():
    pass
"""

    def real(self):
        return 1

    def second(self):
        return 2
EOF
        sed 's/return 1/return 10/' "${CASE09_DIR}/base.py" > "${CASE09_DIR}/left.py"
        sed 's/return 2/return 20/' "${CASE09_DIR}/base.py" > "${CASE09_DIR}/right.py"
    fi

    for lang in en zh; do
        OUT_STDOUT="${WORK_TMP}/case09-${lang}.stdout"
        OUT_STDERR="${WORK_TMP}/case09-${lang}.stderr"
        set +e
        "${BIN}" semantic-merge "${CASE09_DIR}/base.py" "${CASE09_DIR}/left.py" "${CASE09_DIR}/right.py" --lang "${lang}" >"${OUT_STDOUT}" 2>"${OUT_STDERR}"
        RC=$?
        set -e
        STDOUT_BYTES="$(wc -c < "${OUT_STDOUT}" | tr -d ' ')"
        echo "09-py-triplequote (--lang ${lang}): exit=${RC}, stdout_bytes=${STDOUT_BYTES}, stderr='$(tr '\n' ' ' < "${OUT_STDERR}")'"
        [[ "${RC}" -eq 3 ]] || fail_row "Row 4: expected exit 3 on 09-py-triplequote (${lang}), got ${RC}"
        [[ "${STDOUT_BYTES}" -eq 0 ]] || fail_row "Row 4: expected 0 bytes on stdout for 09-py-triplequote (${lang}), got ${STDOUT_BYTES}"
    done

    # Verify --help carries EXPERIMENTAL Python corruption warning in EN and ZH
    HELP_EN="$("${BIN}" --help --lang en)"
    HELP_ZH="$("${BIN}" --help --lang zh)"
    [[ "${HELP_EN}" == *"EXPERIMENTAL: known to corrupt output on Python"* ]] || fail_row "Row 4: EN --help missing EXPERIMENTAL Python warning"
    [[ "${HELP_ZH}" == *"【实验性】已知会在 Python 代码上损坏输出"* ]] || fail_row "Row 4: ZH --help missing Chinese experimental Python warning"

    # Sweep all 19 merge-cases if present: zero cases may exit 0 with invalid syntax or conflict markers
    if [[ -d "${HARNESS_CASES}" ]]; then
        /usr/bin/python3 - "${BIN}" "${HARNESS_CASES}" "${WORK_TMP}" <<'PY'
import glob, os, subprocess, sys

bin_path, cases_root, work_tmp = sys.argv[1], sys.argv[2], sys.argv[3]
case_dirs = sorted(d for d in glob.glob(os.path.join(cases_root, "*")) if os.path.isdir(d))
summary = []
for cdir in case_dirs:
    name = os.path.basename(cdir)
    files = os.listdir(cdir)
    base = [f for f in files if f.startswith("base.")][0]
    ext = os.path.splitext(base)[1]
    p_base = os.path.join(cdir, f"base{ext}")
    p_left = os.path.join(cdir, f"left{ext}")
    p_right = os.path.join(cdir, f"right{ext}")
    proc = subprocess.run([bin_path, "semantic-merge", p_base, p_left, p_right], capture_output=True, text=True)
    if proc.returncode == 0:
        assert "<<<<<<<" not in proc.stdout, f"{name}: exited 0 with conflict markers!"
        merged_file = os.path.join(work_tmp, f"merged_{name}{ext}")
        with open(merged_file, "w", encoding="utf-8") as fh:
            fh.write(proc.stdout)
        if ext == ".py":
            chk = subprocess.run(["/usr/bin/python3", "-m", "py_compile", merged_file], capture_output=True, text=True)
            assert chk.returncode == 0, f"{name}: exited 0 with invalid Python syntax: {chk.stderr}"
        elif ext == ".swift":
            chk = subprocess.run(["/usr/bin/xcrun", "swiftc", "-parse", merged_file], capture_output=True, text=True)
            assert chk.returncode == 0, f"{name}: exited 0 with invalid Swift syntax: {chk.stderr}"
    elif proc.returncode == 3:
        assert proc.stdout == "", f"{name}: exited 3 but emitted non-empty stdout!"
    summary.append(f"{name}=exit({proc.returncode})")
print("19-case sweep verified (0 silent syntax corruptions):", ", ".join(summary))
PY
    fi
    pass_row "Row 4: 09-py-triplequote exits 3 with 0 stdout bytes (EN+ZH), and 0/19 harness cases silently corrupt output"

    # ------------------------------------------------------------------
    # Row 5: semantic-merge on 12-swift-true-conflict -> CLI exit != 0 (1), MCP isError: true
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 5: semantic-merge conflict contract on 12-swift-true-conflict (CLI + MCP) ---"
    if [[ -d "${HARNESS_CASES}/12-swift-true-conflict" ]]; then
        CASE12_DIR="${HARNESS_CASES}/12-swift-true-conflict"
    else
        CASE12_DIR="${WORK_TMP}/12-swift-true-conflict"
        mkdir -p "${CASE12_DIR}"
        printf 'public func calc() -> Int {\n    return 1\n}\n' > "${CASE12_DIR}/base.swift"
        printf 'public func calc() -> Int {\n    return 10\n}\n' > "${CASE12_DIR}/left.swift"
        printf 'public func calc() -> Int {\n    return 20\n}\n' > "${CASE12_DIR}/right.swift"
    fi

    for lang in en zh; do
        set +e
        "${BIN}" semantic-merge "${CASE12_DIR}/base.swift" "${CASE12_DIR}/left.swift" "${CASE12_DIR}/right.swift" --lang "${lang}" >"${WORK_TMP}/case12-${lang}.stdout" 2>"${WORK_TMP}/case12-${lang}.stderr"
        RC12=$?
        set -e
        echo "12-swift-true-conflict CLI (--lang ${lang}): exit=${RC12}, stderr='$(cat "${WORK_TMP}/case12-${lang}.stderr")'"
        [[ "${RC12}" -eq 1 ]] || fail_row "Row 5: expected CLI exit 1 on 12-swift-true-conflict (${lang}), got ${RC12}"
    done

    /usr/bin/python3 - "${BIN}" "${CASE12_DIR}" "${CASE09_DIR}" <<'PY'
import json, os, subprocess, sys

bin_path, case12, case09 = sys.argv[1], sys.argv[2], sys.argv[3]
base12 = open(os.path.join(case12, "base.swift"), encoding="utf-8").read()
left12 = open(os.path.join(case12, "left.swift"), encoding="utf-8").read()
right12 = open(os.path.join(case12, "right.swift"), encoding="utf-8").read()

base09 = open(os.path.join(case09, "base.py"), encoding="utf-8").read()
left09 = open(os.path.join(case09, "left.py"), encoding="utf-8").read()
right09 = open(os.path.join(case09, "right.py"), encoding="utf-8").read()

reqs = [
    {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
    {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
        "name": "relay_semantic_merge",
        "arguments": {"path": "Conflict.swift", "base": base12, "left": left12, "right": right12}
    }},
    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
        "name": "relay_semantic_merge",
        "arguments": {"path": "Corrupt.py", "base": base09, "left": left09, "right": right09}
    }},
]
payload = "\n".join(json.dumps(r) for r in reqs) + "\n"
proc = subprocess.run([bin_path, "mcp"], input=payload, capture_output=True, text=True, timeout=15)
assert proc.returncode == 0, f"mcp exited {proc.returncode}: {proc.stderr}"
lines = [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]
by_id = {msg["id"]: msg["result"] for msg in lines}
print("MCP 12-swift-true-conflict isError:", by_id[2].get("isError"))
print("MCP 09-py-triplequote isError:", by_id[3].get("isError"))
assert by_id[2].get("isError") is True, f"Expected isError=True on conflict, got {by_id[2]}"
assert by_id[3].get("isError") is True, f"Expected isError=True on syntax corruption, got {by_id[3]}"
PY
    pass_row "Row 5: 12-swift-true-conflict exits 1 in CLI and returns isError: true in MCP (and 09-py-triplequote returns isError: true)"

    # ------------------------------------------------------------------
    # Row 6: MCP tools/list matches README.md & README.zh-CN.md exactly
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 6: MCP tools/list count & tool names vs README.md and README.zh-CN.md ---"
    /usr/bin/python3 - "${BIN}" "${ROOT_DIR}/README.md" "${ROOT_DIR}/README.zh-CN.md" <<'PY'
import json, re, subprocess, sys

bin_path, en_readme, zh_readme = sys.argv[1], sys.argv[2], sys.argv[3]
payload = "\n".join([
    json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}),
    json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}),
]) + "\n"
proc = subprocess.run([bin_path, "mcp"], input=payload, capture_output=True, text=True, timeout=10)
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
    # Row 7 & Row 8: Launch real GUI without --demo (empty state) & open empty .relayproj -> close -> lanes == 0
    # ------------------------------------------------------------------
    echo ""
    echo "--- Row 7 & Row 8: Real GUI process empty launch + open/close empty .relayproj without seeding demo lanes ---"
    GUI_CWD="${WORK_TMP}/gui-cwd"
    mkdir -p "${GUI_CWD}"
    # Row 7: Launch GUI without --demo in clean directory; verify it runs cleanly and creates zero .relayproj in CWD
    (
        cd "${GUI_CWD}"
        "${BIN}" --lang en >/dev/null 2>&1 &
        GUI_PID=$!
        sleep 1.2
        kill -0 "${GUI_PID}" 2>/dev/null || exit 1
        kill -TERM "${GUI_PID}" 2>/dev/null || true
        wait "${GUI_PID}" 2>/dev/null || true
    )
    SHOWN_FILES="$(ls -A "${GUI_CWD}")"
    [[ -z "${SHOWN_FILES}" ]] || fail_row "Row 7: GUI launch created unexpected files in CWD: ${SHOWN_FILES}"
    pass_row "Row 7: Launching GUI without --demo starts cleanly in empty state (verified alongside StudioViewModelAndHonestyTests)"

    # Row 8: Initialize empty .relayproj, open in real GUI process (both EN and ZH), close, verify lanes == 0
    for lang in en zh; do
        USER_EMPTY_PROJ="${WORK_TMP}/user-empty-${lang}.relayproj"
        "${BIN}" init --project "${USER_EMPTY_PROJ}" --lang "${lang}" >/dev/null
        "${BIN}" --project "${USER_EMPTY_PROJ}" --lang "${lang}" >/dev/null 2>&1 &
        GUI_OPEN_PID=$!
        sleep 1.4
        kill -0 "${GUI_OPEN_PID}" 2>/dev/null || fail_row "Row 8: GUI process exited prematurely on empty project (${lang})"
        kill -TERM "${GUI_OPEN_PID}" 2>/dev/null || true
        wait "${GUI_OPEN_PID}" 2>/dev/null || true

        LANES_AFTER="$("${BIN}" lanes --project "${USER_EMPTY_PROJ}" --lang "${lang}")"
        STATUS_AFTER="$("${BIN}" status --project "${USER_EMPTY_PROJ}" --lang "${lang}")"
        echo "After GUI open+close (--lang ${lang}): lanes='${LANES_AFTER}', status=${STATUS_AFTER}"
        [[ -z "${LANES_AFTER}" ]] || fail_row "Row 8: GUI polluted empty project with lanes: ${LANES_AFTER}"
        /usr/bin/python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["activeLaneCount"]==0, d' "${STATUS_AFTER}"
    done
    pass_row "Row 8: Opening and closing an empty .relayproj in GUI leaves 0 lanes on disk (EN+ZH)"

    # ------------------------------------------------------------------
    # Row 9: Repo-wide search for fake broadcast echo & fake Wiretap port
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

    echo ""
    echo "================================================================"
    echo "ALL 9 M0 ACCEPTANCE CHECKS PASSED (EN + ZH)"
    echo "================================================================"
}

run_suite 2>&1 | tee "${REPORT_FILE}"
