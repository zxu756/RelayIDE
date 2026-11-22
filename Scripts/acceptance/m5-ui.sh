#!/usr/bin/env bash
# RelayIDE M5 acceptance suite: windowless real-time UI verification (Rows 1..9)
# covering 2-lane PTY/.relay/*.log streaming (<1s), budget-refused lane .pty fallback,
# 4-vendor lane completion status/spend/tokens (<2s), worktree file ownership FSEvents (<2s),
# M2 integration & git merge-file -p conflict view (R74), tightened complete-token & key-field
# number provenance audit, 2720x1680 ImageRenderer rasterization + 0 NSWindows, and post-run hygiene.
#
# Never opens any desktop window and never invokes any real coding agent CLI.
# Every product CLI call goes strictly through Scripts/acceptance/relay-cli.sh with
# isolated HOME, copied relay.sh/relay_util.py, stub agent, and decoy CLIs first in PATH.
#
# Usage:
#   Scripts/acceptance/m5-ui.sh [--quick] [--record [--allow-dirty]] [--mutation 1|2|3|4|5|6]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${ROOT_DIR}"

QUICK=0
RECORD=0
ALLOW_DIRTY=0
MUTATION=""
ONLY_ROW="${RELAY_M5_ONLY_ROW:-}"

usage() {
    cat <<'EOF' >&2
Usage: Scripts/acceptance/m5-ui.sh [--quick] [--record [--allow-dirty]] [--mutation 1|2|3|4|5|6]

Options:
  --quick              Fast smoke subset: runs Rows 1, 4, 6 (--lang en), 7, 8, 9; explicitly lists
                       skipped rows (Row 2, Row 3, Row 5, Row 6 --lang zh).
  --record             Write the full suite output to reports/m5-ui.txt (requires a clean working
                       tree outside reports/ unless --allow-dirty is also passed).
  --allow-dirty        Allow --record when the working tree has uncommitted changes outside reports/.
  --mutation <1..6>    Patch an isolated temporary copy of the package, build it, run the target row
                       of m5-ui.sh against it, delete the copy, and verify the target row turns RED:
                         1 (M5-Mut-1): observer reads only lanes/<lane>.pty, skips .relay/*.log -> Row 1 fails
                         2 (M5-Mut-2): disable workspace.sqlite-wal observer callback -> Row 3 fails
                         3 (M5-Mut-3): disable worktree FSEvents ownership refresh -> Row 4 fails
                         4 (M5-Mut-4): skip git merge-file -p on conflict -> Row 5 fails
                         5 (M5-Mut-5): add +7 to non-demo DAG lane count -> Row 6 fails
                         6 (M5-Mut-6): inject ungrounded constant (1.00x / 15000) in non-demo top bar -> Row 6 fails
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            QUICK=1
            shift
            ;;
        --record)
            RECORD=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --mutation)
            if [[ $# -lt 2 ]]; then
                echo "error: --mutation requires an argument (1..6)" >&2
                usage
                exit 2
            fi
            MUTATION="$2"
            shift 2
            ;;
        --mutation=*)
            MUTATION="${1#--mutation=}"
            shift
            ;;
        --only-row)
            ONLY_ROW="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ "${QUICK}" -eq 1 && "${RECORD}" -eq 1 ]]; then
    echo "error: --quick and --record cannot be used together" >&2
    exit 2
fi

if [[ -n "${MUTATION}" && ( "${QUICK}" -eq 1 || "${RECORD}" -eq 1 ) ]]; then
    echo "error: --mutation cannot be combined with --quick or --record" >&2
    exit 2
fi

case "${MUTATION}" in
    "") ;;
    1|M5-Mut-1|mut1) MUTATION="1" ;;
    2|M5-Mut-2|mut2) MUTATION="2" ;;
    3|M5-Mut-3|mut3) MUTATION="3" ;;
    4|M5-Mut-4|mut4) MUTATION="4" ;;
    5|M5-Mut-5|mut5) MUTATION="5" ;;
    6|M5-Mut-6|mut6) MUTATION="6" ;;
    *)
        echo "error: unsupported --mutation '${MUTATION}' (expected 1..6)" >&2
        exit 2
        ;;
esac

CALLER_HOME="${HOME}"
OS_USER_HOME="$(/usr/bin/python3 -I -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')"
ORIG_PATH="${PATH}"

if [[ -n "${RELAYIDE_RELAY_SH:-}" ]]; then
    CANDIDATE_RELAY_SH="${RELAYIDE_RELAY_SH}"
elif [[ -x "${CALLER_HOME}/.agents/skills/agent-relay/scripts/relay.sh" ]]; then
    CANDIDATE_RELAY_SH="${CALLER_HOME}/.agents/skills/agent-relay/scripts/relay.sh"
else
    CANDIDATE_RELAY_SH="${OS_USER_HOME}/.agents/skills/agent-relay/scripts/relay.sh"
fi

if [[ ! -f "${CANDIDATE_RELAY_SH}" || ! -x "${CANDIDATE_RELAY_SH}" ]]; then
    echo "没跑：找不到 relay.sh"
    exit 2
fi

REAL_RELAY_DIR="$(cd "$(dirname "${CANDIDATE_RELAY_SH}")" && pwd -P)"
REAL_RELAY_SH="${REAL_RELAY_DIR}/$(basename "${CANDIDATE_RELAY_SH}")"
REAL_RELAY_UTIL="${REAL_RELAY_DIR}/relay_util.py"
if [[ ! -f "${REAL_RELAY_UTIL}" || ! -r "${REAL_RELAY_UTIL}" ]]; then
    echo "没跑：找不到 relay.sh"
    exit 2
fi

SWIFT_JOBS_ARGS=()
if [[ -n "${RELAY_SWIFT_JOBS:-}" ]]; then
    SWIFT_JOBS_ARGS=(-j "${RELAY_SWIFT_JOBS}")
fi

sanitize_stream() {
    /usr/bin/python3 -I -c '
import re, sys

repo_dir, caller_home, os_home = sys.argv[1], sys.argv[2], sys.argv[3]
placeholders = {"alice", "developer", "test", "shared", "<name>", "<user>"}
u_prefix = "/Users" + "/"
user_pat = re.compile(re.escape(u_prefix) + r"([^/\s\"'\''`)]+)")

def repl_user(m):
    name = m.group(1)
    if name in placeholders or name.startswith("["):
        return m.group(0)
    return "<home>"

for line in sys.stdin:
    if repo_dir:
        line = line.replace(repo_dir, "<repo>")
    for h in (caller_home, os_home):
        if h and h != "/" and not h.startswith("/var/") and not h.startswith("/private/var/") and not h.startswith("/tmp/"):
            line = line.replace(h, "<home>")
    line = user_pat.sub(repl_user, line)
    sys.stdout.write(line)
    sys.stdout.flush()
' "${ROOT_DIR}" "${CALLER_HOME}" "${OS_USER_HOME}"
}

# ------------------------------------------------------------------
# Isolated Temporary-Copy Mutation Mode (--mutation 1..6)
# ------------------------------------------------------------------
run_mutation_mode() {
    local mut_id="$1"
    local git_before
    git_before="$(git status --porcelain)"

    local mut_tmp
    mut_tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/relayide-m5-mut${mut_id}.XXXXXX")" && pwd -P)"
    trap 'rm -rf "${mut_tmp}" 2>/dev/null || true' EXIT INT TERM HUP

    local pkg_copy="${mut_tmp}/pkg"
    mkdir -p "${pkg_copy}/Tests/RelayIDETests"
    cp "${ROOT_DIR}/Package.swift" "${pkg_copy}/Package.swift"
    if [[ -f "${ROOT_DIR}/Package.resolved" ]]; then
        cp "${ROOT_DIR}/Package.resolved" "${pkg_copy}/Package.resolved"
    fi
    cp -R "${ROOT_DIR}/Sources" "${pkg_copy}/Sources"
    cp "${ROOT_DIR}/Tests/RelayIDETests/M5UIAcceptanceTests.swift" "${pkg_copy}/Tests/RelayIDETests/M5UIAcceptanceTests.swift"

    local mut_label expected_fail_row target_row_num target_rel
    case "${mut_id}" in
        1)
            mut_label="M5-Mut-1 (terminal observer reads only lanes/<lane>.pty, skips <worktree>/.relay/*.log)"
            expected_fail_row="Row 1"
            target_row_num="1"
            target_rel="Sources/RelayStudioViews/RelayLiveWorkspaceObserver.swift"
            ;;
        2)
            mut_label="M5-Mut-2 (disable workspace.sqlite-wal observer callback)"
            expected_fail_row="Row 3"
            target_row_num="3"
            target_rel="Sources/RelayStudioViews/RelayLiveWorkspaceObserver.swift"
            ;;
        3)
            mut_label="M5-Mut-3 (disable worktree FSEvents ownership refresh trigger)"
            expected_fail_row="Row 4"
            target_row_num="4"
            target_rel="Sources/RelayWorktreeGit/RelayReadOnlyGitRunInspector.swift"
            ;;
        4)
            mut_label="M5-Mut-4 (skip git merge-file -p conflict block reconstruction)"
            expected_fail_row="Row 5"
            target_row_num="5"
            target_rel="Sources/RelayWorktreeGit/RelayReadOnlyGitRunInspector.swift"
            ;;
        5)
            mut_label="M5-Mut-5 (add +7 to non-demo DAG lane count)"
            expected_fail_row="Row 6"
            target_row_num="6"
            target_rel="Sources/RelayStudioViews/PTYMultiplexerAndDAGViews.swift"
            ;;
        6)
            mut_label="M5-Mut-6 (inject ungrounded constant 1.00× / 15000 into non-demo top bar)"
            expected_fail_row="Row 6"
            target_row_num="6"
            target_rel="Sources/RelayStudioViews/RelayMainWindowAndScreenshotExporter.swift"
            ;;
    esac

    echo "================================================================"
    echo "RelayIDE M5 Mutation Check: ${mut_label}"
    echo "Target file (in isolated temp copy): ${target_rel}"
    echo "Expected failing row:                ${expected_fail_row}"
    echo "================================================================"

    /usr/bin/python3 -I - "${mut_id}" "${pkg_copy}/${target_rel}" <<'PY'
import sys

mut_id, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

if mut_id == "1":
    old = "readRelayStepLogs: Bool = true,"
    new = "readRelayStepLogs: Bool = false, // M5-Mut-1"
elif mut_id == "2":
    old = "observeDatabaseChanges: Bool = true"
    new = "observeDatabaseChanges: Bool = false // M5-Mut-2"
elif mut_id == "3":
    old = "recomputeLanesOnQueue(laneIDs: dirtyLanes, forceEmit: false)"
    new = "// M5-Mut-3: recomputeLanesOnQueue(laneIDs: dirtyLanes, forceEmit: false)"
elif mut_id == "4":
    old = "conflictText = reconstructSingleFileConflictText("
    new = "conflictText = true ? nil : reconstructSingleFileConflictText( // M5-Mut-4"
elif mut_id == "5":
    old = 'viewModel.L("\\(run.lanes.count) lanes", "\\(run.lanes.count) 条通道"),'
    new = 'viewModel.L("\\(run.lanes.count + 7) lanes", "\\(run.lanes.count + 7) 条通道"), // M5-Mut-5'
elif mut_id == "6":
    old = "viewModel.activeWaveSummaryLabel,"
    new = '"\\(viewModel.activeWaveSummaryLabel) · 1.00× · 15000", // M5-Mut-6'
else:
    raise SystemExit(f"unknown mutation id: {mut_id}")

count = text.count(old)
if count != 1:
    sys.stderr.write(f"error: expected mutation target to appear once in {path}, found {count}\n")
    sys.exit(2)

patched = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(patched)
print(f"Applied M5-Mut-{mut_id} patch cleanly in temporary copy.")
PY

    echo "==> Building mutated package & headless test bundle in isolated temp directory..."
    local prod_name="Relay""IDE"
    PATH="${ORIG_PATH}" swift build --build-tests --package-path "${pkg_copy}" \
        ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} >/dev/null
    local mut_bin="${pkg_copy}/.build/debug/${prod_name}"
    if [[ ! -x "${mut_bin}" ]]; then
        echo "[FAIL] M5-Mut-${mut_id}: mutated binary missing at ${mut_bin}" >&2
        return 1
    fi

    local suite_out="${mut_tmp}/suite.out"
    local suite_rc=0
    set +e
    RELAY_CLI_BIN="${mut_bin}" \
    RELAY_M5_PACKAGE_PATH="${pkg_copy}" \
    RELAY_M5_SKIP_BUILD=1 \
    RELAY_M5_ONLY_ROW="${target_row_num}" \
    RELAYIDE_RELAY_SH="${REAL_RELAY_SH}" \
        "${ROOT_DIR}/Scripts/acceptance/m5-ui.sh" >"${suite_out}" 2>&1
    suite_rc=$?
    set -e

    echo "--- Inner m5-ui.sh summary against mutated copy (exit=${suite_rc}) ---"
    grep -E '^(\[(PASS|FAIL|RECORD|SKIP)\]|ALL M5|M5 UI ACCEPTANCE|Row [0-9]+ error:)' "${suite_out}" || cat "${suite_out}"

    rm -rf "${mut_tmp}/pkg"
    local git_after
    git_after="$(git status --porcelain)"
    if [[ "${git_after}" != "${git_before}" ]]; then
        echo "[FAIL] M5-Mut-${mut_id}: repository git status changed during mutation check!" >&2
        return 1
    fi

    if [[ "${suite_rc}" -eq 0 ]]; then
        echo "[FAIL] M5-Mut-${mut_id}: m5-ui.sh unexpectedly exited 0 (mutation NOT caught)" >&2
        cat "${suite_out}" >&2
        return 1
    fi
    if ! grep -Fq "[FAIL] ${expected_fail_row}:" "${suite_out}"; then
        echo "[FAIL] M5-Mut-${mut_id}: expected '[FAIL] ${expected_fail_row}:' in output, not found" >&2
        cat "${suite_out}" >&2
        return 1
    fi

    echo "================================================================"
    echo "[PASS] M5-Mut-${mut_id} CAUGHT: inner m5-ui.sh exited ${suite_rc} with [FAIL] ${expected_fail_row}; working tree untouched"
    echo "================================================================"
    return 0
}

if [[ -n "${MUTATION}" ]]; then
    run_mutation_mode "${MUTATION}" 2>&1 | sanitize_stream
    exit "${PIPESTATUS[0]}"
fi

# ------------------------------------------------------------------
# Clean-Tree Gate for --record
# ------------------------------------------------------------------
GIT_STATUS_BEFORE="$(git status --porcelain)"
DIRTY_OUTSIDE_REPORTS="$(git status --porcelain -- . ':(exclude)reports')"
if [[ -z "${DIRTY_OUTSIDE_REPORTS}" ]]; then
    TREE_STATE="working tree clean outside reports/"
else
    TREE_STATE="working tree has uncommitted changes outside reports/"
fi

if [[ "${RECORD}" -eq 1 && -n "${DIRTY_OUTSIDE_REPORTS}" && "${ALLOW_DIRTY}" -eq 0 ]]; then
    echo "error: --record requires a clean working tree outside reports/ (commit changes first, or pass --allow-dirty for a draft preview):" >&2
    printf '%s\n' "${DIRTY_OUTSIDE_REPORTS}" >&2
    exit 2
fi

SHA256_RELAY_SH_BEFORE="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
SHA256_RELAY_UTIL_BEFORE="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"

PREFS_DIR_OS="${OS_USER_HOME}/Library/Preferences"
PREFS_OS_BEFORE="$(ls -1 "${PREFS_DIR_OS}" 2>/dev/null | grep -i 'relayide' | sort || true)"

SUITE_START_EPOCH="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"

PACKAGE_DIR="${RELAY_M5_PACKAGE_PATH:-${ROOT_DIR}}"
PROD_NAME="Relay""IDE"
BUILD_ELAPSED_SEC="0.00"

if [[ "${RELAY_M5_SKIP_BUILD:-0}" != "1" ]]; then
    BUILD_T0="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    PATH="${ORIG_PATH}" swift build --build-tests --package-path "${PACKAGE_DIR}" \
        ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} >/dev/null
    BUILD_T1="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    BUILD_ELAPSED_SEC="$(/usr/bin/python3 -I -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "${BUILD_T0}" "${BUILD_T1}")"
fi

if [[ -n "${RELAY_CLI_BIN:-}" ]]; then
    TESTED_BIN="${RELAY_CLI_BIN}"
else
    TESTED_BIN="${PACKAGE_DIR}/.build/debug/${PROD_NAME}"
fi
if [[ ! -x "${TESTED_BIN}" ]]; then
    echo "没跑：可执行文件不存在 (${TESTED_BIN})" >&2
    exit 2
fi
export RELAY_CLI_BIN="${TESTED_BIN}"
BIN_BYTES="$(wc -c < "${TESTED_BIN}" | tr -d ' ')"
BIN_SHA256="$(shasum -a 256 "${TESTED_BIN}" | awk '{print $1}')"

RELAY_CLI_WRAPPER="${ROOT_DIR}/Scripts/acceptance/relay-cli.sh"

TMP_BASE="${TMPDIR:-/tmp}"
RAW_WORK_TMP="$(mktemp -d "${TMP_BASE%/}/relayide-m5-acc.XXXXXX")"
WORK_TMP="$(cd "${RAW_WORK_TMP}" && pwd -P)"
WORK_TMP_NAME="$(basename "${WORK_TMP}")"

work_tmp_match_token() {
    local target="$1"
    if [[ "${target}" == "${WORK_TMP}" || "${target}" == "${RAW_WORK_TMP}" ]]; then
        printf '%s' "${WORK_TMP_NAME}"
    elif [[ "${target}" == "${WORK_TMP}/"* ]]; then
        printf '%s/%s' "${WORK_TMP_NAME}" "${target#"${WORK_TMP}/"}"
    elif [[ "${target}" == "${RAW_WORK_TMP}/"* ]]; then
        printf '%s/%s' "${WORK_TMP_NAME}" "${target#"${RAW_WORK_TMP}/"}"
    else
        printf '%s' "${target#/private}"
    fi
}

list_procs_for_dir() {
    local target="${1:-${WORK_TMP}}"
    [[ -n "${target}" ]] || return 0
    local needle
    needle="$(work_tmp_match_token "${target}")"
    [[ -n "${needle}" ]] || return 0
    ps -axo pid=,command= | grep -F -- "${needle}" | grep -v -F -- "grep -F -- ${needle}" | awk -v self="$$" '$1 != self { print }' || true
}

list_git_cwd_procs_for_dir() {
    local target="${1:-${WORK_TMP}}"
    [[ -n "${target}" ]] || return 0
    local needle
    needle="$(work_tmp_match_token "${target}")"
    [[ -n "${needle}" ]] || return 0
    /usr/sbin/lsof -n -P -a -d cwd -c git -Fpcn 2>/dev/null | /usr/bin/python3 -I -c '
import sys
needle, self_pid = sys.argv[1], sys.argv[2]
cur_p = cur_c = ""
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    tag, val = line[0], line[1:]
    if tag == "p":
        cur_p, cur_c = val, ""
    elif tag == "c":
        cur_c = val
    elif tag == "n" and cur_p and cur_p != self_pid and needle in val:
        print(f"{cur_p} {cur_c} (cwd={val})")
' "${needle}" "$$" || true
}

kill_procs_for_dir() {
    local target="${1:-${WORK_TMP}}"
    [[ -n "${target}" ]] || return 0
    local lines git_lines combined pids
    lines="$(list_procs_for_dir "${target}")"
    git_lines="$(list_git_cwd_procs_for_dir "${target}")"
    combined="$(printf '%s\n%s\n' "${lines}" "${git_lines}" | sed '/^$/d' || true)"
    if [[ -n "${combined}" ]]; then
        pids="$(printf '%s\n' "${combined}" | awk '{print $1}' | sort -u)"
        if [[ -n "${pids}" ]]; then
            # shellcheck disable=SC2086
            kill -TERM ${pids} 2>/dev/null || true
            /usr/bin/perl -e 'select(undef, undef, undef, 0.15)' </dev/null
            lines="$(list_procs_for_dir "${target}")"
            git_lines="$(list_git_cwd_procs_for_dir "${target}")"
            combined="$(printf '%s\n%s\n' "${lines}" "${git_lines}" | sed '/^$/d' || true)"
            pids="$(printf '%s\n' "${combined}" | awk '{print $1}' | sort -u)"
            if [[ -n "${pids}" ]]; then
                # shellcheck disable=SC2086
                kill -KILL ${pids} 2>/dev/null || true
            fi
        fi
    fi
}

cleanup_work_tmp() {
    if [[ -n "${WORK_TMP:-}" && -e "${WORK_TMP}" ]]; then
        kill_procs_for_dir "${WORK_TMP}"
        rm -rf "${WORK_TMP}" 2>/dev/null || true
    fi
}

on_interrupt_signal() {
    cleanup_work_tmp
    exit 130
}

trap 'cleanup_work_tmp' EXIT
trap 'on_interrupt_signal' INT TERM HUP

poll_until_no_procs() {
    local target="$1"
    local max_sec="${2:-15}"
    local needle
    needle="$(work_tmp_match_token "${target}")"
    local deadline_ticks=$(( max_sec * 20 ))
    local tick=0
    while (( tick <= deadline_ticks )); do
        if [[ -z "$(list_procs_for_dir "${target}")" && -z "$(list_git_cwd_procs_for_dir "${target}")" ]]; then
            return 0
        fi
        /usr/bin/perl -e 'select(undef, undef, undef, 0.05)' </dev/null
        tick=$(( tick + 1 ))
    done
    echo "leftover processes matching '${needle}' after ${max_sec}s:" >&2
    list_procs_for_dir "${target}" >&2 || true
    list_git_cwd_procs_for_dir "${target}" >&2 || true
    return 1
}

# Set up isolated HOME, copied relay.sh + relay_util.py, decoy CLIs, and Python stub agent
ISO_HOME="${WORK_TMP}/iso-home"
DECOY_DIR="${WORK_TMP}/decoys"
DECOY_MARKER="${WORK_TMP}/decoy-invoked.marker"
RELAY_COPY_DIR="${WORK_TMP}/relay-copy"
STUB_DIR="${WORK_TMP}/stubs"
mkdir -p "${ISO_HOME}/Library/Preferences" "${DECOY_DIR}" "${RELAY_COPY_DIR}" "${STUB_DIR}"

cp "${REAL_RELAY_SH}" "${RELAY_COPY_DIR}/relay.sh"
cp "${REAL_RELAY_UTIL}" "${RELAY_COPY_DIR}/relay_util.py"
chmod +x "${RELAY_COPY_DIR}/relay.sh"
COPY_RELAY_SH="${RELAY_COPY_DIR}/relay.sh"

for cli in claude codex agy vibe opencode; do
    cat > "${DECOY_DIR}/${cli}" <<EOF
#!/usr/bin/env bash
printf 'DECOY %s %s\n' "${cli}" "\$*" >> "${DECOY_MARKER}"
exit 99
EOF
    chmod +x "${DECOY_DIR}/${cli}"
done

M5_STUB_AGENT="${STUB_DIR}/m5-stub-agent.py"
cat > "${M5_STUB_AGENT}" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time

args = sys.argv[1:]
if args[:1] in (["--version"], ["-V"]):
    print("m5-stub-agent 1.0.0")
    sys.exit(0)
if args[:2] == ["login", "status"]:
    print("Logged in (m5-stub)")
    sys.exit(0)
if args[:2] == ["features", "list"]:
    sys.exit(0)

vendor = None
workdir = os.getcwd()
prompt_file = None
prompt_inline = None
vibe_dir = None
codex_out = None
i = 0
while i < len(args):
    a = args[i]
    if a.startswith("--prompt-file"):
        prompt_file = a.split("=", 1)[1] if "=" in a else args[i + 1]
        if "=" not in a:
            i += 1
    elif a.startswith("--output-dir"):
        vibe_dir = a.split("=", 1)[1] if "=" in a else args[i + 1]
        if "=" not in a:
            i += 1
    elif a.startswith("--workdir"):
        workdir = a.split("=", 1)[1] if "=" in a else args[i + 1]
        if "=" not in a:
            i += 1
    elif a in ("-o", "--output-last-message") and i + 1 < len(args):
        codex_out = args[i + 1]
        i += 1
    elif a == "-C" and i + 1 < len(args):
        workdir = args[i + 1]
        i += 1
    elif a == "-p" and i + 1 < len(args) and not args[i + 1].startswith("--"):
        prompt_inline = args[i + 1]
        i += 1
    i += 1

if any(a.startswith("--permission-mode") or a.startswith("--max-budget-usd") for a in args):
    vendor = "claude"
elif any(a.startswith("--prompt-file") or a.startswith("--output-dir") or a.startswith("--workdir") for a in args):
    vendor = "vibe"
elif (args and args[0] == "exec") or any(a in ("--skip-git-repo-check", "-o", "--output-last-message") for a in args):
    vendor = "codex"
elif any(a.startswith("--mode") for a in args) or prompt_inline is not None:
    vendor = "agy"

if vendor in ("claude", "codex"):
    prompt_text = sys.stdin.read()
elif vendor == "agy":
    prompt_text = prompt_inline or ""
elif vendor == "vibe" and prompt_file:
    with open(prompt_file, "r", encoding="utf-8") as fh:
        prompt_text = fh.read()
else:
    prompt_text = ""

lane = os.path.basename(os.path.realpath(workdir))
cost_usd = 0.05
tokens = 1200
ticks = 0
interval = 1.0
sleep_sec = 0.0
exit_code = 0
write_rel = None
write_body = None

for raw in prompt_text.splitlines():
    line = raw.strip()
    if line.startswith("LANE="):
        lane = line.split("=", 1)[1].strip()
    elif line.startswith("COST="):
        cost_usd = float(line.split("=", 1)[1].strip())
    elif line.startswith("TOKENS="):
        tokens = int(line.split("=", 1)[1].strip())
    elif line.startswith("TICKS="):
        ticks = int(line.split("=", 1)[1].strip())
    elif line.startswith("SLEEP="):
        sleep_sec = float(line.split("=", 1)[1].strip())
    elif line.startswith("EXIT="):
        exit_code = int(line.split("=", 1)[1].strip())
    elif line.startswith("WRITE_CONTENT="):
        rest = line.split("=", 1)[1]
        rel, _, body = rest.partition("|")
        write_rel = rel.strip()
        write_body = body.replace("\\n", "\n")
    elif line.startswith("WRITE="):
        write_rel = line.split("=", 1)[1].strip()

trace_dir = os.environ.get("STUB_TRACE_DIR", "")
if trace_dir:
    os.makedirs(trace_dir, exist_ok=True)
    with open(os.path.join(trace_dir, f"{lane}.trace"), "a", encoding="utf-8") as tf:
        tf.write(f"start {time.time():.6f} {os.getpid()} {vendor} {lane}\n")

emitted = []
if ticks > 0:
    for seq in range(1, ticks + 1):
        if seq > 1:
            time.sleep(interval)
        ts = time.time()
        msg = f"STREAM lane={lane} seq={seq} emit={ts:.6f}"
        emitted.append(msg)
        stream = sys.stderr if vendor == "vibe" else sys.stdout
        stream.write(msg + "\n")
        stream.flush()
elif sleep_sec > 0:
    time.sleep(sleep_sec)

if write_rel and exit_code == 0:
    dst_path = os.path.join(workdir, write_rel)
    os.makedirs(os.path.dirname(dst_path) or workdir, exist_ok=True)
    with open(dst_path, "w", encoding="utf-8") as wf:
        if write_body is not None:
            wf.write(write_body)
        else:
            wf.write(f"ok {lane}\n")

status_word = "success" if exit_code == 0 else "failed"
summary = ("\n".join(emitted) + "\n" if emitted else "") + f"Completed {lane}\nSTATUS: {status_word}"
in_tok = (tokens * 2) // 3
out_tok = tokens - in_tok

if vendor == "claude":
    payload = {
        "type": "result",
        "subtype": "success" if exit_code == 0 else "error",
        "is_error": (exit_code != 0),
        "result": summary,
        "total_cost_usd": cost_usd,
        "session_id": f"stub-claude-{lane}",
        "usage": {"input_tokens": in_tok, "output_tokens": out_tok, "total_tokens": tokens},
    }
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()
elif vendor == "codex":
    if codex_out:
        os.makedirs(os.path.dirname(codex_out) or ".", exist_ok=True)
        with open(codex_out, "w", encoding="utf-8") as cf:
            cf.write(summary + "\n")
    sys.stdout.write(f"session id: stub-codex-{lane}\n{summary}\ntokens used\n{tokens:,}\n")
    sys.stdout.flush()
elif vendor == "agy":
    payload = {
        "response": summary,
        "status": "SUCCESS" if exit_code == 0 else "FAILED",
        "usage": {"input_tokens": in_tok, "output_tokens": out_tok, "total_tokens": tokens},
        "denied_actions": [],
    }
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()
elif vendor == "vibe":
    sys.stdout.write(json.dumps([{"type": "message", "role": "assistant", "content": summary}]) + "\n")
    sys.stdout.flush()
    if vibe_dir:
        os.makedirs(vibe_dir, exist_ok=True)
        exp = {
            "outcome": "finished" if exit_code == 0 else "stopped",
            "stop_reason": "end_turn" if exit_code == 0 else "error",
            "cost_usd": cost_usd,
            "usage": {"input_tokens": in_tok, "output_tokens": out_tok, "total_tokens": tokens},
            "config": {"active_model": "stub-vibe"},
        }
        with open(os.path.join(vibe_dir, "export.json"), "w", encoding="utf-8") as ef:
            json.dump(exp, ef)
            ef.write("\n")

if trace_dir:
    with open(os.path.join(trace_dir, f"{lane}.trace"), "a", encoding="utf-8") as tf:
        tf.write(f"end {time.time():.6f} {os.getpid()} {vendor} {lane} {exit_code}\n")

sys.exit(exit_code)
PY
chmod +x "${M5_STUB_AGENT}"

SAFE_CHILD_PATH="${DECOY_DIR}:/usr/bin:/bin:/usr/sbin:/sbin"
PROBE_PATH="${DECOY_DIR}:${ORIG_PATH}"

unset RELAY_REAL_AGENTS
unset RELAY_WORKER
unset AGY_CODER_WORKER
unset CLAUDECODE

STATE_DIR="${WORK_TMP}/state"
mkdir -p "${STATE_DIR}"
printf 'not-run' > "${STATE_DIR}/row1_metric"
printf 'not-run' > "${STATE_DIR}/row3_metric"
printf 'not-run' > "${STATE_DIR}/row4_metric"

invoke_product() {
    local out_file="$1"
    local err_file="$2"
    shift 2
    local extra_env=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        extra_env+=("$1")
        shift
    done
    [[ "${1:-}" == "--" ]] && shift
    /usr/bin/env \
        HOME="${ISO_HOME}" \
        CFFIXED_USER_HOME="${ISO_HOME}" \
        RELAY_CLI_HOME="${ISO_HOME}" \
        RELAY_CLI_CHILD_PATH="${SAFE_CHILD_PATH}" \
        RELAY_CLI_BIN="${TESTED_BIN}" \
        RELAYIDE_RELAY_SH="${COPY_RELAY_SH}" \
        RELAY_CLAUDE_BIN="${M5_STUB_AGENT}" \
        RELAY_CODEX_BIN="${M5_STUB_AGENT}" \
        RELAY_AGY_BIN="${M5_STUB_AGENT}" \
        RELAY_VIBE_BIN="${M5_STUB_AGENT}" \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_TERMINAL_PROMPT=0 \
        ${extra_env[@]+"${extra_env[@]}"} \
        "${RELAY_CLI_WRAPPER}" "$@" >"${out_file}" 2>"${err_file}"
}

run_ui_probe() {
    local spec_json="$1"
    local log_out="$2"
    if ! HOME="${ISO_HOME}" \
        CFFIXED_USER_HOME="${ISO_HOME}" \
        PATH="${PROBE_PATH}" \
        RELAY_M5_PROBE_SPEC="${spec_json}" \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_TERMINAL_PROMPT=0 \
        swift test --package-path "${PACKAGE_DIR}" --skip-build --no-parallel \
        --filter "M5UIAcceptanceTests/runM5AcceptanceProbe" >"${log_out}" 2>&1; then
        cat "${log_out}" >&2 || true
        return 1
    fi
}

init_sample_git_repo() {
    local repo_dir="$1"
    mkdir -p "${repo_dir}"
    HOME="${ISO_HOME}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null /usr/bin/git -C "${repo_dir}" init -b main >/dev/null
    HOME="${ISO_HOME}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null /usr/bin/git -C "${repo_dir}" config user.name "Relay M5 Acceptance"
    HOME="${ISO_HOME}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null /usr/bin/git -C "${repo_dir}" config user.email "m5-acceptance@relay.invalid"
    cat > "${repo_dir}/App.swift" <<'EOF'
public struct App {
    public static let mode = "baseline"
}
EOF
    cat > "${repo_dir}/README.md" <<'EOF'
# Sample Repository
EOF
    HOME="${ISO_HOME}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null /usr/bin/git -C "${repo_dir}" add App.swift README.md
    HOME="${ISO_HOME}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null /usr/bin/git -C "${repo_dir}" commit -m "initial" >/dev/null
}

wait_for_file() {
    local target="$1"
    local max_ticks="${2:-200}"
    local i=0
    while (( i < max_ticks )); do
        if [[ -f "${target}" ]]; then
            return 0
        fi
        /usr/bin/perl -e 'select(undef, undef, undef, 0.03)' </dev/null
        i=$(( i + 1 ))
    done
    return 1
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_LIST=()
ROW_TIMINGS_FILE="${WORK_TMP}/row_timings.tsv"
: > "${ROW_TIMINGS_FILE}"

read_state() {
    local f="${STATE_DIR}/$1"
    if [[ -f "${f}" ]]; then
        cat "${f}"
    fi
}

record_pass() {
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    echo "[PASS] Row $1: $2"
}

record_fail() {
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    echo "[FAIL] Row $1: $2"
}

record_skip() {
    SKIP_LIST+=("Row $1 ($2)")
    printf 'Row %s\t0.00\tSKIP\n' "$1" >> "${ROW_TIMINGS_FILE}"
    echo "[SKIP] Row $1: $2"
}

run_row() {
    local num="$1"
    local title="$2"
    local fn="$3"
    echo ""
    echo "--- Row ${num}: ${title} ---"
    local t0 t1 elapsed rc=0 detail=""
    t0="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    local detail_file="${WORK_TMP}/row${num}_detail.txt"
    local err_log="${WORK_TMP}/row${num}_exec.log"
    : > "${detail_file}"
    set +e
    ( set -euo pipefail; "${fn}" "${detail_file}" ) >"${err_log}" 2>&1
    rc=$?
    set -e
    t1="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    elapsed="$(/usr/bin/python3 -I -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "${t0}" "${t1}")"
    detail="$(tr '\n' ' ' < "${detail_file}" | sed 's/  */ /g; s/^ //; s/ $//')"

    if [[ "${rc}" -eq 0 ]]; then
        printf 'Row %s\t%s\tPASS\n' "${num}" "${elapsed}" >> "${ROW_TIMINGS_FILE}"
        record_pass "${num}" "${detail:-verified} (${elapsed}s)"
    else
        printf 'Row %s\t%s\tFAIL\n' "${num}" "${elapsed}" >> "${ROW_TIMINGS_FILE}"
        echo "Row ${num} error:" >&2
        tail -n 40 "${err_log}" >&2 || true
        record_fail "${num}" "${detail:-failed (see diagnostics above)} (${elapsed}s)"
    fi
}

# ------------------------------------------------------------------
# Row 1: Two parallel lanes stream PTY/.relay/*.log line-by-line (<1s)
# ------------------------------------------------------------------
row_1_two_lanes_live_streaming() {
    local detail_file="$1"
    local d="${WORK_TMP}/r1"
    mkdir -p "${d}/prompts"
    init_sample_git_repo "${d}/repo"
    local bundle="${d}/Row1.relayproj"
    invoke_product "${d}/init.out" "${d}/init.err" -- init --project "${bundle}" --lang en

    cat > "${d}/prompts/claude.md" <<'EOF'
LANE=lane-claude
TICKS=4
COST=0.1100
TOKENS=1400
WRITE=ClaudeStream.swift
EOF
    cat > "${d}/prompts/vibe.md" <<'EOF'
LANE=lane-vibe
TICKS=4
COST=0.1900
TOKENS=1600
WRITE=VibeStream.swift
EOF
    /usr/bin/python3 -I - "${d}/repo" "${d}/prompts" "${d}/plan.json" <<'PY'
import json, sys
repo, pdir, out = sys.argv[1:4]
json.dump({
    "repo": repo,
    "base": "main",
    "lanes": [
        {"id": "lane-claude", "agent": "claude", "prompt": f"{pdir}/claude.md", "after": []},
        {"id": "lane-vibe", "agent": "vibe", "prompt": f"{pdir}/vibe.md", "after": []},
    ],
}, open(out, "w", encoding="utf-8"), indent=2)
PY

    /usr/bin/python3 -I - "${bundle}" "${d}/ready" "${d}/probe_out.json" "${d}/spec.json" <<'PY'
import json, sys
bundle, ready, out_json, spec = sys.argv[1:5]
json.dump({
    "mode": "row1_stream",
    "projectPath": bundle,
    "readyFilePath": ready,
    "outputJSONPath": out_json,
}, open(spec, "w", encoding="utf-8"), indent=2)
PY

    run_ui_probe "${d}/spec.json" "${d}/probe.log" &
    local probe_pid=$!
    if ! wait_for_file "${d}/ready" 300; then
        kill -TERM "${probe_pid}" 2>/dev/null || true
        echo "Row 1 probe failed to signal ready" >&2
        cat "${d}/probe.log" >&2 || true
        return 1
    fi

    invoke_product "${d}/run.out" "${d}/run.err" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${bundle}" --lang en

    local probe_rc=0
    set +e
    wait "${probe_pid}"
    probe_rc=$?
    set -e
    if [[ "${probe_rc}" -ne 0 ]]; then
        cat "${d}/probe.log" >&2 || true
    fi

    local summary
    summary="$(/usr/bin/python3 -I - "${d}/probe_out.json" <<'PY'
import json, sys
res = json.load(open(sys.argv[1], encoding="utf-8"))
if not res.get("ok"):
    sys.stderr.write("Violations: " + "; ".join(res.get("violations", [])) + "\n")
    sys.exit(1)
assert res.get("windowCount") == 0, res
max_lat = float(res["maxLatencySec"])
assert 0.0 <= max_lat <= 1.0, max_lat
lats = ", ".join(res.get("latencies", []))
print(f"2 parallel lanes streamed 4 lines/lane progressively (<1.0s threshold, max_line_latency={max_lat:.3f}s [{lats}]), mid-run & final ImageRenderer PDF matched .relay/*.log, windows=0")
PY
)"
    /usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); k="maxLatencySec"; print(f"{d[k]:.3f}s", end="")' "${d}/probe_out.json" > "${STATE_DIR}/row1_metric"
    printf '%s' "${summary}" > "${detail_file}"
    [[ "${probe_rc}" -eq 0 ]]
}

# ------------------------------------------------------------------
# Row 2: Budget-refused lane without .relay/*.log displays lanes/b.pty
# ------------------------------------------------------------------
row_2_budget_refused_pty_fallback() {
    local detail_file="$1"
    local d="${WORK_TMP}/r2"
    mkdir -p "${d}/prompts"
    init_sample_git_repo "${d}/repo"
    local bundle="${d}/Row2.relayproj"
    invoke_product "${d}/init.out" "${d}/init.err" -- init --project "${bundle}" --lang en

    printf 'LANE=a\nCOST=0.3000\nTOKENS=900\nWRITE=A.swift\n' > "${d}/prompts/a.md"
    printf 'LANE=b\nCOST=0.1000\nTOKENS=500\nWRITE=B.swift\n' > "${d}/prompts/b.md"
    /usr/bin/python3 -I - "${d}/repo" "${d}/prompts" "${d}/plan.json" <<'PY'
import json, sys
repo, pdir, out = sys.argv[1:4]
json.dump({
    "repo": repo,
    "base": "main",
    "lanes": [
        {"id": "a", "agent": "claude", "prompt": f"{pdir}/a.md", "after": []},
        {"id": "b", "agent": "claude", "prompt": f"{pdir}/b.md", "after": ["a"]},
    ],
}, open(out, "w", encoding="utf-8"), indent=2)
PY

    local run_rc=0
    set +e
    invoke_product "${d}/run.out" "${d}/run.err" \
        "STUB_TRACE_DIR=${d}/traces" "RELAY_BUDGET_USD=0.20" -- \
        run "${d}/plan.json" --project "${bundle}" --lang en
    run_rc=$?
    set -e
    if [[ "${run_rc}" -ne 1 ]]; then
        echo "Expected exit 1 on budget refusal, got ${run_rc}" >&2
        return 1
    fi

    /usr/bin/python3 -I - "${bundle}" "${d}/run.out" "${d}/probe_out.json" "${d}/spec.json" <<'PY'
import glob, json, os, sys
bundle, run_out, out_json, spec = sys.argv[1:5]
rec = json.load(open(run_out, encoding="utf-8"))
lanes = {l["laneID"]: l for l in rec["lanes"]}
assert lanes["b"]["status"] == "refused" and lanes["b"]["exitCode"] == 2, lanes["b"]
b_wt = lanes["b"].get("worktreePath") or os.path.join(bundle, "runs", rec["runID"], "worktrees", "b")
assert glob.glob(os.path.join(b_wt, ".relay", "*.log")) == [], "Refused lane b unexpectedly created .relay/*.log"
b_pty = os.path.join(bundle, "runs", rec["runID"], "lanes", "b.pty")
assert "not started: the job budget" in open(b_pty, encoding="utf-8").read()
json.dump({
    "mode": "row2_refused",
    "projectPath": bundle,
    "outputJSONPath": out_json,
}, open(spec, "w", encoding="utf-8"), indent=2)
PY

    run_ui_probe "${d}/spec.json" "${d}/probe.log"
    /usr/bin/python3 -I - "${d}/probe_out.json" <<'PY'
import json, sys
res = json.load(open(sys.argv[1], encoding="utf-8"))
assert res.get("ok") and res.get("windowCount") == 0, res
PY
    printf '%s' "lane b (no .relay/*.log) rendered status=refused, exitCode=2 & 'not started: the job budget' from lanes/b.pty in EN & ZH PDF, windows=0" > "${detail_file}"
}

# ------------------------------------------------------------------
# Helper to ensure 4-lane run bundle exists (Row 3 & standalone Row 6)
# ------------------------------------------------------------------
prepare_four_lane_plan() {
    local d="$1"
    mkdir -p "${d}/prompts"
    init_sample_git_repo "${d}/repo"
    printf 'LANE=c1\nSLEEP=0.25\nCOST=0.1234\nTOKENS=1500\nWRITE=c1.txt\n' > "${d}/prompts/c1.md"
    printf 'LANE=v1\nSLEEP=0.30\nCOST=0.2500\nTOKENS=900\nEXIT=3\n' > "${d}/prompts/v1.md"
    printf 'LANE=a1\nSLEEP=0.25\nTOKENS=4500\nWRITE=a1.txt\n' > "${d}/prompts/a1.md"
    printf 'LANE=x1\nSLEEP=0.25\nTOKENS=1200\nWRITE=x1.txt\n' > "${d}/prompts/x1.md"
    /usr/bin/python3 -I - "${d}/repo" "${d}/prompts" "${d}/plan.json" <<'PY'
import json, sys
repo, pdir, out = sys.argv[1:4]
json.dump({
    "repo": repo,
    "base": "main",
    "lanes": [
        {"id": "c1", "agent": "claude", "prompt": f"{pdir}/c1.md", "after": []},
        {"id": "v1", "agent": "vibe",   "prompt": f"{pdir}/v1.md", "after": []},
        {"id": "a1", "agent": "agy",    "prompt": f"{pdir}/a1.md", "after": []},
        {"id": "x1", "agent": "codex",  "prompt": f"{pdir}/x1.md", "after": []},
    ],
}, open(out, "w", encoding="utf-8"), indent=2)
PY
}

# ------------------------------------------------------------------
# Row 3: 4-vendor lane completion updates status/exitCode/spend/tokens <2s
# ------------------------------------------------------------------
row_3_four_lanes_completion_under_2s() {
    local detail_file="$1"
    local d="${WORK_TMP}/r3"
    prepare_four_lane_plan "${d}"
    local bundle="${d}/Row3FourLanes.relayproj"
    invoke_product "${d}/init.out" "${d}/init.err" -- init --project "${bundle}" --lang en

    /usr/bin/python3 -I - "${bundle}" "${d}/ready" "${d}/probe_out.json" "${d}/spec.json" <<'PY'
import json, sys
bundle, ready, out_json, spec = sys.argv[1:5]
json.dump({
    "mode": "row3_four_lanes",
    "projectPath": bundle,
    "readyFilePath": ready,
    "outputJSONPath": out_json,
}, open(spec, "w", encoding="utf-8"), indent=2)
PY

    run_ui_probe "${d}/spec.json" "${d}/probe.log" &
    local probe_pid=$!
    if ! wait_for_file "${d}/ready" 300; then
        kill -TERM "${probe_pid}" 2>/dev/null || true
        cat "${d}/probe.log" >&2 || true
        return 1
    fi

    local run_rc=0
    set +e
    invoke_product "${d}/run.out" "${d}/run.err" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${bundle}" --lang en
    run_rc=$?
    set -e
    if [[ "${run_rc}" -eq 0 ]]; then
        echo "Expected non-zero exit because v1 exited 3" >&2
        return 1
    fi

    local probe_rc=0
    set +e
    wait "${probe_pid}"
    probe_rc=$?
    set -e
    if [[ "${probe_rc}" -ne 0 ]]; then
        cat "${d}/probe.log" >&2 || true
    fi

    local summary
    summary="$(/usr/bin/python3 -I - "${d}/probe_out.json" "${d}/traces" <<'PY'
import json, os, sys

res = json.load(open(sys.argv[1], encoding="utf-8"))
trace_dir = sys.argv[2]
if not res.get("ok"):
    sys.stderr.write("Violations: " + "; ".join(res.get("violations", [])) + "\n")
    sys.exit(1)
assert res.get("windowCount") == 0, res
obs = res["laneObservedEpochs"]
pdf_epoch = float(res["pdfAllFourEpoch"])

lags = {}
latest_exit = 0.0
for lid in ("c1", "v1", "a1", "x1"):
    lines = open(os.path.join(trace_dir, f"{lid}.trace"), encoding="utf-8").read().splitlines()
    end_lines = [ln for ln in lines if ln.startswith("end ")]
    assert end_lines, f"missing end trace for {lid}"
    end_ts = float(end_lines[-1].split()[1])
    latest_exit = max(latest_exit, end_ts)
    lag = float(obs[lid]) - end_ts
    assert 0.0 <= lag <= 2.0, f"lane {lid} lag {lag:.3f}s exceeded 2.0s"
    lags[lid] = lag

pdf_lag = pdf_epoch - latest_exit
assert 0.0 <= pdf_lag <= 2.0, f"PDF render lag {pdf_lag:.3f}s exceeded 2.0s"
lag_str = ", ".join(f"{k}={v:.3f}s" for k, v in lags.items())
print(f"4 lanes updated <2.0s ({lag_str}; full_pdf_lag={pdf_lag:.3f}s), c1=$0.1234, v1=$0.2500 (exit 3), total=$0.3734, a1=4500 & x1=1200 unpriced tokens (no $0.00), windows=0")
PY
)"
    /usr/bin/python3 -I - "${d}/probe_out.json" "${d}/traces" <<'PY' > "${STATE_DIR}/row3_metric"
import json, os, sys
res = json.load(open(sys.argv[1], encoding="utf-8"))
latest = max(
    float([ln for ln in open(os.path.join(sys.argv[2], f"{lid}.trace")).read().splitlines() if ln.startswith("end ")][-1].split()[1])
    for lid in ("c1", "v1", "a1", "x1")
)
print(f"{float(res['pdfAllFourEpoch']) - latest:.3f}s", end="")
PY
    printf '%s' "${bundle}" > "${STATE_DIR}/row3_bundle"
    printf '%s' "${summary}" > "${detail_file}"
    [[ "${probe_rc}" -eq 0 ]]
}

# ------------------------------------------------------------------
# Row 4: File ownership view (⌘4) refreshes within <2.0s via FSEvents
# ------------------------------------------------------------------
row_4_file_ownership_under_2s() {
    local detail_file="$1"
    local d="${WORK_TMP}/r4"
    mkdir -p "${d}/prompts"
    init_sample_git_repo "${d}/repo"
    local bundle="${d}/Row4Ownership.relayproj"
    invoke_product "${d}/init.out" "${d}/init.err" -- init --project "${bundle}" --lang en

    printf 'LANE=lane-own-a\nCOST=0.0400\nTOKENS=600\nWRITE=AlphaOwned.swift\n' > "${d}/prompts/a.md"
    printf 'LANE=lane-own-b\nCOST=0.0500\nTOKENS=700\nWRITE=BetaOwned.swift\n' > "${d}/prompts/b.md"
    /usr/bin/python3 -I - "${d}/repo" "${d}/prompts" "${d}/plan.json" <<'PY'
import json, sys
repo, pdir, out = sys.argv[1:4]
json.dump({
    "repo": repo,
    "base": "main",
    "lanes": [
        {"id": "lane-own-a", "agent": "claude", "prompt": f"{pdir}/a.md", "after": []},
        {"id": "lane-own-b", "agent": "vibe",   "prompt": f"{pdir}/b.md", "after": ["lane-own-a"]},
    ],
}, open(out, "w", encoding="utf-8"), indent=2)
PY

    invoke_product "${d}/run.out" "${d}/run.err" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${bundle}" --lang en

    local wt_a
    wt_a="$(/usr/bin/python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print([l["worktreePath"] for l in r["lanes"] if l["laneID"]=="lane-own-a"][0])' "${d}/run.out")"

    /usr/bin/python3 -I - "${bundle}" "${d}/ready" "${d}/probe_out.json" "${d}/spec.json" <<'PY'
import json, sys
bundle, ready, out_json, spec = sys.argv[1:5]
json.dump({
    "mode": "row4_ownership",
    "projectPath": bundle,
    "readyFilePath": ready,
    "outputJSONPath": out_json,
}, open(spec, "w", encoding="utf-8"), indent=2)
PY

    run_ui_probe "${d}/spec.json" "${d}/probe.log" &
    local probe_pid=$!
    if ! wait_for_file "${d}/ready" 300; then
        kill -TERM "${probe_pid}" 2>/dev/null || true
        cat "${d}/probe.log" >&2 || true
        return 1
    fi
    /usr/bin/perl -e 'select(undef, undef, undef, 0.12)' </dev/null

    /usr/bin/python3 -I - "${wt_a}" "${d}/edits.json" <<'PY'
import json, os, sys, time

wt, edits_out = sys.argv[1], sys.argv[2]
p1 = os.path.join(wt, "App.swift")
with open(p1, "w", encoding="utf-8") as fh:
    fh.write('public struct App {\n    public static let mode = "edited-in-worktree"\n    public static let rev = 2\n}\n')
    fh.flush()
    os.fsync(fh.fileno())
t_tracked = time.time()

time.sleep(0.35)

noise = os.path.join(wt, ".relay", "99-noise.log")
with open(noise, "w", encoding="utf-8") as nf:
    nf.write("internal relay log noise\n")
    nf.flush()
    os.fsync(nf.fileno())

p2 = os.path.join(wt, "ManualOwnershipProbe.swift")
with open(p2, "w", encoding="utf-8") as fh:
    fh.write("public enum ManualOwnershipProbe {\n    public static let ok = true\n}\n")
    fh.flush()
    os.fsync(fh.fileno())
t_untracked = time.time()

json.dump({"trackedWriteEpoch": t_tracked, "untrackedWriteEpoch": t_untracked}, open(edits_out, "w", encoding="utf-8"))
PY

    local probe_rc=0
    set +e
    wait "${probe_pid}"
    probe_rc=$?
    set -e
    if [[ "${probe_rc}" -ne 0 ]]; then
        cat "${d}/probe.log" >&2 || true
    fi

    local summary
    summary="$(/usr/bin/python3 -I - "${d}/probe_out.json" "${d}/edits.json" <<'PY'
import json, sys

res = json.load(open(sys.argv[1], encoding="utf-8"))
ed = json.load(open(sys.argv[2], encoding="utf-8"))
if not res.get("ok"):
    sys.stderr.write("Violations: " + "; ".join(res.get("violations", [])) + "\n")
    sys.exit(1)
assert res.get("windowCount") == 0, res

t_vm = float(res["trackedVMEpoch"]) - float(ed["trackedWriteEpoch"])
t_pdf = float(res["trackedPDFEpoch"]) - float(ed["trackedWriteEpoch"])
u_vm = float(res["untrackedVMEpoch"]) - float(ed["untrackedWriteEpoch"])
u_pdf = float(res["untrackedPDFEpoch"]) - float(ed["untrackedWriteEpoch"])

for label, val in (("tracked_vm", t_vm), ("tracked_pdf", t_pdf), ("untracked_vm", u_vm), ("untracked_pdf", u_pdf)):
    assert 0.0 <= val <= 2.0, f"{label} latency {val:.4f}s outside [0, 2.0s]"

print(f"⌘4 refreshed <2.0s (tracked_vm={t_vm:.3f}s, tracked_pdf={t_pdf:.3f}s, untracked_vm={u_vm:.3f}s, untracked_pdf={u_pdf:.3f}s), committed files retained, .relay/.git excluded, windows=0")
PY
)"
    /usr/bin/python3 -I - "${d}/probe_out.json" "${d}/edits.json" <<'PY' > "${STATE_DIR}/row4_metric"
import json, sys
res = json.load(open(sys.argv[1], encoding="utf-8"))
ed = json.load(open(sys.argv[2], encoding="utf-8"))
print(f"tracked={float(res['trackedPDFEpoch'])-float(ed['trackedWriteEpoch']):.3f}s, untracked={float(res['untrackedPDFEpoch'])-float(ed['untrackedWriteEpoch']):.3f}s", end="")
PY
    printf '%s' "${bundle}" > "${STATE_DIR}/row4_bundle"
    printf '%s' "${summary}" > "${detail_file}"
    [[ "${probe_rc}" -eq 0 ]]
}

# ------------------------------------------------------------------
# Row 5: Merge view (⌘3) M2 verified + git merge-file -p conflicts & R74
# ------------------------------------------------------------------
row_5_merge_and_conflicts() {
    local detail_file="$1"
    local d="${WORK_TMP}/r5"
    mkdir -p "${d}/prompts"
    init_sample_git_repo "${d}/repo_clean"
    init_sample_git_repo "${d}/repo_conflict"

    local clean_bundle="${d}/Row5Clean.relayproj"
    local conflict_bundle="${d}/Row5Conflict.relayproj"
    invoke_product "${d}/init1.out" "${d}/init1.err" -- init --project "${clean_bundle}" --lang en
    invoke_product "${d}/init2.out" "${d}/init2.err" -- init --project "${conflict_bundle}" --lang en

    printf 'LANE=lane-alpha\nCOST=0.0500\nTOKENS=700\nWRITE=Alpha.swift\n' > "${d}/prompts/alpha.md"
    printf 'LANE=lane-beta\nCOST=0.0600\nTOKENS=850\nWRITE=Beta.swift\n' > "${d}/prompts/beta.md"
    /usr/bin/python3 -I - "${d}/repo_clean" "${d}/prompts" "${d}/plan_clean.json" <<'PY'
import json, sys
repo, pdir, out = sys.argv[1:4]
json.dump({
    "repo": repo,
    "base": "main",
    "verify": "echo VERIFY_M5_OK && test -f Alpha.swift && test -f Beta.swift",
    "lanes": [
        {"id": "lane-alpha", "agent": "claude", "prompt": f"{pdir}/alpha.md", "after": []},
        {"id": "lane-beta",  "agent": "vibe",   "prompt": f"{pdir}/beta.md",  "after": ["lane-alpha"]},
    ],
}, open(out, "w", encoding="utf-8"), indent=2)
PY

    invoke_product "${d}/clean_run.out" "${d}/clean_run.err" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan_clean.json" --project "${clean_bundle}" --lang en

    printf 'LANE=lane-left\nCOST=0.0500\nTOKENS=600\nWRITE_CONTENT=App.swift|public struct App {\\n    public static let mode = "left-lane-choice"\\n}\\n\n' > "${d}/prompts/left.md"
    printf 'LANE=lane-right\nCOST=0.0600\nTOKENS=650\nWRITE_CONTENT=App.swift|public struct App {\\n    public static let mode = "right-lane-choice"\\n}\\n\n' > "${d}/prompts/right.md"
    /usr/bin/python3 -I - "${d}/repo_conflict" "${d}/prompts" "${d}/plan_conflict.json" <<'PY'
import json, sys
repo, pdir, out = sys.argv[1:4]
json.dump({
    "repo": repo,
    "base": "main",
    "lanes": [
        {"id": "lane-left",  "agent": "claude", "prompt": f"{pdir}/left.md",  "after": []},
        {"id": "lane-right", "agent": "vibe",   "prompt": f"{pdir}/right.md", "after": []},
    ],
}, open(out, "w", encoding="utf-8"), indent=2)
PY

    local conf_rc=0
    set +e
    invoke_product "${d}/conf_run.out" "${d}/conf_run.err" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan_conflict.json" --project "${conflict_bundle}" --lang en
    conf_rc=$?
    set -e
    if [[ "${conf_rc}" -ne 1 ]]; then
        echo "Expected conflict run exit 1, got ${conf_rc}" >&2
        return 1
    fi

    # Independently reconstruct conflict block via /usr/bin/git merge-file -p
    /usr/bin/python3 -I - "${d}/repo_conflict" "${d}/conf_run.out" "${d}/expected_conflict.txt" \
        "${clean_bundle}" "${conflict_bundle}" "${d}/probe_out.json" "${d}/spec.json" <<'PY'
import json, os, subprocess, sys, tempfile

repo, conf_run_p, exp_conf_p, clean_b, conf_b, out_json, spec_p = sys.argv[1:8]
rec = json.load(open(conf_run_p, encoding="utf-8"))
integ = rec["integration"]
assert integ["status"] == "conflict" and integ["ready"] is False, integ
cur = integ["baseCommitOID"]
conflict_step = None
for m in integ["merges"]:
    if m["status"] == "merged":
        cur = m["mergeCommitOID"]
    elif m["status"] == "conflict":
        conflict_step = m
        break
assert conflict_step is not None
lane_oid = conflict_step["laneCommitOID"]
mb = subprocess.check_output(["/usr/bin/git", "--no-optional-locks", "-C", repo, "merge-base", cur, lane_oid], text=True).strip()
with tempfile.TemporaryDirectory() as td:
    bp, op, tp = os.path.join(td, "base"), os.path.join(td, "ours"), os.path.join(td, "theirs")
    for dst, rev in ((bp, mb), (op, cur), (tp, lane_oid)):
        blob = subprocess.check_output(["/usr/bin/git", "--no-optional-locks", "-C", repo, "cat-file", "blob", f"{rev}:App.swift"])
        open(dst, "wb").write(blob)
    p = subprocess.run(
        ["/usr/bin/git", "--no-optional-locks", "merge-file", "-p",
         "-L", "integration", "-L", "base", "-L", conflict_step["laneID"], op, bp, tp],
        capture_output=True, text=True
    )
    open(exp_conf_p, "w", encoding="utf-8").write(p.stdout)

json.dump({
    "mode": "row5_merge",
    "projectPath": clean_b,
    "secondProjectPath": conf_b,
    "expectedConflictFile": exp_conf_p,
    "outputJSONPath": out_json,
}, open(spec_p, "w", encoding="utf-8"), indent=2)
PY

    run_ui_probe "${d}/spec.json" "${d}/probe.log"
    /usr/bin/python3 -I - "${d}/probe_out.json" <<'PY'
import json, sys
res = json.load(open(sys.argv[1], encoding="utf-8"))
assert res.get("ok") and res.get("windowCount") == 0, res
PY

    printf '%s' "${clean_bundle}" > "${STATE_DIR}/row5_clean_bundle"
    printf '%s' "${conflict_bundle}" > "${STATE_DIR}/row5_conflict_bundle"
    printf '%s' "clean run rendered verified + ready:true + mergeCommitOIDs + verify.pty; conflict run matched git merge-file -p (UU App.swift) in EN & ZH; 0 R74 tokens in Sources/; windows=0" > "${detail_file}"
}

# ------------------------------------------------------------------
# Row 6: Tightened non-demo number provenance & key-field exact equality
# ------------------------------------------------------------------
row_6_tightened_number_provenance() {
    local detail_file="$1"
    local d="${WORK_TMP}/r6"
    mkdir -p "${d}"

    local empty_init="${d}/EmptyInit.relayproj"
    invoke_product "${d}/init.out" "${d}/init.err" -- init --project "${empty_init}" --lang en

    local shared_r3 shared_r4 shared_r5c shared_r5f
    shared_r3="$(read_state row3_bundle)"
    shared_r4="$(read_state row4_bundle)"
    shared_r5c="$(read_state row5_clean_bundle)"
    shared_r5f="$(read_state row5_conflict_bundle)"

    local live_bundle="${shared_r3}"
    if [[ -z "${live_bundle}" || ! -d "${live_bundle}" ]]; then
        if [[ "${QUICK}" -eq 1 && -n "${shared_r4}" && -d "${shared_r4}" ]]; then
            live_bundle="${shared_r4}"
        else
            local sub="${d}/standalone_4lane"
            prepare_four_lane_plan "${sub}"
            live_bundle="${sub}/Standalone4Lanes.relayproj"
            invoke_product "${sub}/init.out" "${sub}/init.err" -- init --project "${live_bundle}" --lang en
            set +e
            invoke_product "${sub}/run.out" "${sub}/run.err" "STUB_TRACE_DIR=${sub}/traces" -- \
                run "${sub}/plan.json" --project "${live_bundle}" --lang en
            set -e
        fi
    fi

    /usr/bin/python3 -I - "${empty_init}" "${live_bundle}" "${shared_r5c}" \
        "${shared_r5f}" "${QUICK}" "${d}/probe_out.json" "${d}/spec.json" <<'PY'
import json, sys
empty_p, live_p, c_p, f_p, quick_s, out_json, spec_p = sys.argv[1:8]
json.dump({
    "mode": "row6_number_audit",
    "projectPath": empty_p,
    "secondProjectPath": live_p,
    "thirdProjectPath": c_p if c_p else None,
    "fourthProjectPath": f_p if f_p else None,
    "quick": (quick_s == "1"),
    "outputJSONPath": out_json,
}, open(spec_p, "w", encoding="utf-8"), indent=2)
PY

    run_ui_probe "${d}/spec.json" "${d}/probe.log"
    local summary
    summary="$(/usr/bin/python3 -I - "${d}/probe_out.json" "${QUICK}" <<'PY'
import json, sys
res = json.load(open(sys.argv[1], encoding="utf-8"))
quick = (sys.argv[2] == "1")
if not res.get("ok"):
    sys.stderr.write("Violations: " + "; ".join(res.get("violations", [])) + "\n")
    sys.exit(1)
assert res.get("windowCount") == 0, res
langs = "EN" if quick else "EN & ZH"
print(f"0 ungrounded numbers & 0 key-field mismatches across {res['auditedRenders']} PDF renders ({langs}, panes ⌘1..⌘5 + drawer + ⌘,), --demo badged & isolated, windows=0")
PY
)"
    printf '%s' "${summary}" > "${detail_file}"
}

# ------------------------------------------------------------------
# Row 7: 2720x1680 ImageRenderer rasterization & 0 windows / 0 GUI procs
# ------------------------------------------------------------------
row_7_raster_and_zero_windows() {
    local detail_file="$1"
    local d="${WORK_TMP}/r7"
    mkdir -p "${d}"
    local r3_b r4_b live_ref
    r3_b="$(read_state row3_bundle)"
    r4_b="$(read_state row4_bundle)"
    live_ref="${r3_b:-${r4_b}}"

    /usr/bin/python3 -I - "${live_ref}" "${d}/probe_out.json" "${d}/spec.json" <<'PY'
import json, sys
live_p, out_json, spec_p = sys.argv[1:4]
json.dump({
    "mode": "row7_raster",
    "projectPath": live_p if live_p else None,
    "outputJSONPath": out_json,
}, open(spec_p, "w", encoding="utf-8"), indent=2)
PY

    run_ui_probe "${d}/spec.json" "${d}/probe.log"

    local lingering
    lingering="$("${RELAY_CLI_WRAPPER}" --relay-cli-running-processes)"
    if [[ -n "${lingering}" ]]; then
        echo "Unexpected lingering RelayIDE processes: ${lingering}" >&2
        return 1
    fi

    local summary
    summary="$(/usr/bin/python3 -I - "${d}/probe_out.json" <<'PY'
import json, sys
res = json.load(open(sys.argv[1], encoding="utf-8"))
assert res.get("ok") and res.get("windowCount") == 0, res
print(f"{res['checkedBitmaps']} offscreen CGImages verified at 2720x1680 (min_distinct_rgb={res['minDistinctRGB']}), NSApplication.windows=0, lingering RelayIDE procs=0")
PY
)"
    printf '%s' "${summary}" > "${detail_file}"
}

# ------------------------------------------------------------------
# Main Suite Execution (Rows 1..9)
# ------------------------------------------------------------------
run_suite() {
    echo "================================================================"
    echo "RelayIDE M5 Acceptance Suite (Windowless Live UI & Number Audit)"
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Commit:    $(git rev-parse --short HEAD) (branch: $(git rev-parse --abbrev-ref HEAD); ${TREE_STATE})"
    echo "Mode:      $( [[ -n "${ONLY_ROW}" ]] && echo "only-row-${ONLY_ROW}" || ( [[ "${QUICK}" -eq 1 ]] && echo "quick" || echo "full" ) )"
    echo "relay.sh sha256 (start):      ${SHA256_RELAY_SH_BEFORE}"
    echo "relay_util.py sha256 (start): ${SHA256_RELAY_UTIL_BEFORE}"
    echo "================================================================"

    if [[ -z "${ONLY_ROW}" || "${ONLY_ROW}" == "1" ]]; then
        run_row "1" "2 parallel stub lanes stream PTY/.relay/*.log line-by-line (<1.0s) matching logs (R7)" row_1_two_lanes_live_streaming
    fi

    if [[ -z "${ONLY_ROW}" || "${ONLY_ROW}" == "2" ]]; then
        if [[ "${QUICK}" -eq 1 && -z "${ONLY_ROW}" ]]; then
            record_skip "2" "--quick skips budget-refused lane .pty fallback scenario"
        else
            run_row "2" "Budget-refused lane without .relay/*.log displays lanes/b.pty refusal reason" row_2_budget_refused_pty_fallback
        fi
    fi

    if [[ -z "${ONLY_ROW}" || "${ONLY_ROW}" == "3" ]]; then
        if [[ "${QUICK}" -eq 1 && -z "${ONLY_ROW}" ]]; then
            record_skip "3" "--quick skips 4-vendor <2.0s completion latency scenario"
        else
            run_row "3" "4-vendor run updates status, exitCode, duration, spend & unpriced tokens in <2.0s" row_3_four_lanes_completion_under_2s
        fi
    fi

    if [[ -z "${ONLY_ROW}" || "${ONLY_ROW}" == "4" ]]; then
        run_row "4" "File ownership view (⌘4) refreshes tracked edit & untracked file in <2.0s" row_4_file_ownership_under_2s
    fi

    if [[ -z "${ONLY_ROW}" || "${ONLY_ROW}" == "5" ]]; then
        if [[ "${QUICK}" -eq 1 && -z "${ONLY_ROW}" ]]; then
            record_skip "5" "--quick skips M2 clean/conflict merge studio scenario"
        else
            run_row "5" "Merge view (⌘3) displays M2 verified result & git merge-file -p conflicts (fixes R74)" row_5_merge_and_conflicts
        fi
    fi

    if [[ -z "${ONLY_ROW}" || "${ONLY_ROW}" == "6" ]]; then
        run_row "6" "Tightened non-demo number provenance & key-field exact equality audit" row_6_tightened_number_provenance
        if [[ "${QUICK}" -eq 1 && -z "${ONLY_ROW}" ]]; then
            SKIP_LIST+=("Row 6 (--lang zh duplicate audit)")
        fi
    fi

    if [[ -z "${ONLY_ROW}" || "${ONLY_ROW}" == "7" ]]; then
        run_row "7" "2720x1680 ImageRenderer rasterization integrity & zero-window check" row_7_raster_and_zero_windows
    fi

    # --- Row 8: Post-suite hygiene ---
    if [[ -z "${ONLY_ROW}" || "${ONLY_ROW}" == "8" ]]; then
        echo ""
        echo "--- Row 8: Post-suite hygiene (0 decoy hits, 0 leftover processes, ~/Library unchanged, relay.sh sha256 & git status) ---"
        local r8_t0 r8_t1 r8_elapsed r8_ok=1
        r8_t0="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"

        if [[ -e "${DECOY_MARKER}" ]]; then
            echo "Decoy CLI marker file exists!" >&2
            cat "${DECOY_MARKER}" >&2 || true
            r8_ok=0
        fi
        if ! poll_until_no_procs "${WORK_TMP}" 10; then
            r8_ok=0
        fi

        local prefs_os_after sha_sh_after sha_util_after git_status_after
        prefs_os_after="$(ls -1 "${PREFS_DIR_OS}" 2>/dev/null | grep -i 'relayide' | sort || true)"
        sha_sh_after="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
        sha_util_after="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"

        if [[ "${prefs_os_after}" != "${PREFS_OS_BEFORE}" ]]; then
            echo "~/Library/Preferences RelayIDE entries changed: before='${PREFS_OS_BEFORE}' after='${prefs_os_after}'" >&2
            r8_ok=0
        fi
        if [[ "${sha_sh_after}" != "${SHA256_RELAY_SH_BEFORE}" || "${sha_util_after}" != "${SHA256_RELAY_UTIL_BEFORE}" ]]; then
            echo "relay.sh or relay_util.py sha256 changed during run!" >&2
            r8_ok=0
        fi
        if [[ "${RECORD}" -eq 0 ]]; then
            git_status_after="$(git status --porcelain)"
            if [[ "${git_status_after}" != "${GIT_STATUS_BEFORE}" ]]; then
                echo "git status --porcelain changed during run without --record" >&2
                r8_ok=0
            fi
        fi

        r8_t1="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
        r8_elapsed="$(/usr/bin/python3 -I -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "${r8_t0}" "${r8_t1}")"
        printf 'Row 8\t%s\t%s\n' "${r8_elapsed}" "$( [[ "${r8_ok}" -eq 1 ]] && echo PASS || echo FAIL )" >> "${ROW_TIMINGS_FILE}"

        if [[ "${r8_ok}" -eq 1 ]]; then
            record_pass "8" "0 decoy CLI hits, 0 leftover processes, ~/Library/Preferences unchanged, relay.sh & relay_util.py sha256 unchanged, working tree unchanged (${r8_elapsed}s)"
        else
            record_fail "8" "post-suite hygiene check failed (${r8_elapsed}s)"
        fi
    fi

    # --- Row 9: Record-only metrics ---
    local suite_end_epoch total_elapsed bin_mib sha_sh_end sha_util_end
    suite_end_epoch="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    total_elapsed="$(/usr/bin/python3 -I -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "${SUITE_START_EPOCH}" "${suite_end_epoch}")"
    bin_mib="$(/usr/bin/python3 -I -c 'import sys; print(f"{int(sys.argv[1])/(1024*1024):.2f}")' "${BIN_BYTES}")"
    sha_sh_end="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
    sha_util_end="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"

    local r1_m r3_m r4_m
    r1_m="$(read_state row1_metric)"
    r3_m="$(read_state row3_metric)"
    r4_m="$(read_state row4_metric)"

    echo ""
    echo "--- Row 9 (Record-Only): Per-row timings, latency metrics, agent-relay checksums, and binary size ---"
    echo "Build elapsed:                ${BUILD_ELAPSED_SEC}s"
    while IFS=$'\t' read -r r_label r_sec r_st; do
        printf '  %-8s %-7s %ss\n' "${r_label}" "[${r_st}]" "${r_sec}"
    done < "${ROW_TIMINGS_FILE}"
    echo "Row 1 max stream latency:     ${r1_m}"
    echo "Row 3 4-lane PDF lag:         ${r3_m}"
    echo "Row 4 ownership FSEvents lag: ${r4_m}"
    echo "Suite total wall-clock:       ${total_elapsed}s"
    echo "relay.sh sha256 (end):        ${sha_sh_end}"
    echo "relay_util.py sha256 (end):   ${sha_util_end}"
    echo "Tested binary:                ${TESTED_BIN}"
    echo "Tested binary size:           ${BIN_BYTES} bytes (${bin_mib} MiB)"
    echo "Tested binary sha256:         ${BIN_SHA256}"
    if [[ "${#SKIP_LIST[@]}" -gt 0 ]]; then
        local skip_joined="" s_item
        for s_item in "${SKIP_LIST[@]}"; do
            if [[ -z "${skip_joined}" ]]; then
                skip_joined="${s_item}"
            else
                skip_joined="${skip_joined}; ${s_item}"
            fi
        done
        echo "Skipped items (--quick):      ${skip_joined}"
    fi
    echo "[RECORD] Row 9: total=${total_elapsed}s, build=${BUILD_ELAPSED_SEC}s, stream_max=${r1_m}, completion_lag=${r3_m}, ownership_lag=(${r4_m}), binary=${BIN_BYTES} B (${bin_mib} MiB), relay.sh=${sha_sh_end}"

    rm -rf "${WORK_TMP}" 2>/dev/null || true

    echo ""
    echo "================================================================"
    if [[ "${FAIL_COUNT}" -eq 0 ]]; then
        if [[ "${QUICK}" -eq 1 ]]; then
            echo "ALL M5 QUICK ACCEPTANCE CHECKS PASSED (passed=${PASS_COUNT}, skipped=${#SKIP_LIST[@]}, total=${total_elapsed}s)"
        else
            echo "ALL M5 UI ACCEPTANCE CHECKS PASSED (Rows 1..8 hard checks + Row 9 recorded; total=${total_elapsed}s)"
        fi
        echo "================================================================"
        return 0
    else
        echo "M5 UI ACCEPTANCE SUITE FAILED (passed=${PASS_COUNT}, failed=${FAIL_COUNT}, total=${total_elapsed}s)"
        echo "================================================================"
        return 1
    fi
}

if [[ "${RECORD}" -eq 1 ]]; then
    mkdir -p "${ROOT_DIR}/reports"
    REPORT_REL="reports/m5-ui.txt"
    run_suite 2>&1 | sanitize_stream | tee "${ROOT_DIR}/${REPORT_REL}"
    SUITE_RC="${PIPESTATUS[0]}"
    echo "Report written to <repo>/${REPORT_REL}"
    exit "${SUITE_RC}"
else
    run_suite 2>&1 | sanitize_stream
    exit "${PIPESTATUS[0]}"
fi
