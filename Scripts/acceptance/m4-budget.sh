#!/usr/bin/env bash
# RelayIDE M4 acceptance suite: real .relay/LOG.md spend & unpriced token ledger,
# workspace & HTML aggregation, whole-job RELAY_BUDGET_USD enforcement, proxy removal
# cleanliness, and Schema v6 -> v7 upgrade compatibility (Rows 1..10).
#
# Never opens the desktop window and never invokes any real coding agent CLI.
# Every product call goes strictly through Scripts/acceptance/relay-cli.sh with
# isolated HOME, stub-agent.sh, and decoy claude/codex/agy/vibe/opencode first in PATH.
#
# Usage:
#   Scripts/acceptance/m4-budget.sh [--quick] [--record [--allow-dirty]] [--mutation 2|3|4]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${ROOT_DIR}"

QUICK=0
RECORD=0
ALLOW_DIRTY=0
MUTATION=""

usage() {
    cat <<'EOF' >&2
Usage: Scripts/acceptance/m4-budget.sh [--quick] [--record [--allow-dirty]] [--mutation 2|3|4]

Options:
  --quick            Fast smoke subset (<120s): runs Rows 1, 2, 3 (--lang en), 6, 7 (static+CLI),
                     9, 10; explicitly reports skipped items (Row 3 --lang zh, Row 4, Row 5,
                     Row 7 swift test, Row 8).
  --record           Write the full suite output to reports/m4-budget.txt (requires a clean
                     working tree outside reports/ unless --allow-dirty is also passed).
  --allow-dirty      Allow --record when the working tree has uncommitted changes outside reports/.
  --mutation <2|3|4> Patch an isolated temporary copy of Package.swift + Sources/, build a mutated
                     RelayIDE binary, run m4-budget.sh against it, and verify the target row fails:
                       2 (M4-Mut-2): passthrough RELAY_BUDGET_USD without subtracting spentSoFar -> Row 3 fails
                       3 (M4-Mut-3): unpriced lane costUSD set to 0.0 instead of null -> Row 1 fails
                       4 (M4-Mut-4): computeStats() totalSpendUSD reads wiretap_spans (0.0) -> Row 2 fails
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
                echo "error: --mutation requires an argument (2, 3, or 4)" >&2
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
    2|M4-Mut-2|mut2) MUTATION="2" ;;
    3|M4-Mut-3|mut3) MUTATION="3" ;;
    4|M4-Mut-4|mut4) MUTATION="4" ;;
    *)
        echo "error: unsupported --mutation '${MUTATION}' (expected 2, 3, or 4)" >&2
        exit 2
        ;;
esac

# Resolve both caller HOME and OS account pw_dir BEFORE replacing HOME so neither can leak or be missed.
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
# Isolated Temporary-Copy Mutation Mode (--mutation 2 | 3 | 4)
# ------------------------------------------------------------------
run_mutation_mode() {
    local mut_id="$1"
    local git_before
    git_before="$(git status --porcelain)"

    local mut_tmp
    mut_tmp="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/relayide-m4-mut${mut_id}.XXXXXX")" && pwd -P)"
    trap 'rm -rf "${mut_tmp}" 2>/dev/null || true' EXIT INT TERM HUP

    local pkg_copy="${mut_tmp}/pkg"
    mkdir -p "${pkg_copy}/Tests/RelayIDETests"
    cp "${ROOT_DIR}/Package.swift" "${pkg_copy}/Package.swift"
    if [[ -f "${ROOT_DIR}/Package.resolved" ]]; then
        cp "${ROOT_DIR}/Package.resolved" "${pkg_copy}/Package.resolved"
    fi
    cp -R "${ROOT_DIR}/Sources" "${pkg_copy}/Sources"
    printf 'import Testing\n' > "${pkg_copy}/Tests/RelayIDETests/PlaceholderTests.swift"

    local mut_label expected_fail_row target_rel
    case "${mut_id}" in
        2)
            mut_label="M4-Mut-2 (passthrough RELAY_BUDGET_USD without subtracting completed lanes spentSoFar)"
            expected_fail_row="Row 3"
            target_rel="Sources/RelayOrchestrator/RelayDAGRunScheduler.swift"
            ;;
        3)
            mut_label="M4-Mut-3 (unpriced lane costUSD mutated from nil to 0.0 in RelayLogSpendParser)"
            expected_fail_row="Row 1"
            target_rel="Sources/RelayOrchestrator/RelayDAGRunScheduler.swift"
            ;;
        4)
            mut_label="M4-Mut-4 (RelayProjectDatabase.computeStats() totalSpendUSD reads wiretap_spans returning 0.0)"
            expected_fail_row="Row 2"
            target_rel="Sources/RelayWorkspaceStore/RelaySQLiteStore.swift"
            ;;
    esac

    echo "================================================================"
    echo "RelayIDE M4 Mutation Check: ${mut_label}"
    echo "Target file (in isolated temp copy): ${target_rel}"
    echo "Expected failing row:                ${expected_fail_row}"
    echo "================================================================"

    /usr/bin/python3 -I - "${mut_id}" "${pkg_copy}/${target_rel}" <<'PY'
import sys

mut_id, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

if mut_id == "2":
    old = "let remaining = max(0.0, jobBudget - spentBeforeSpawn)"
    new = "let remaining = jobBudget // M4-Mut-2"
elif mut_id == "3":
    old = """        } else if let tok = last.tokens {
            return RelayLaneSpendReading(
                didAppendStepEntry: true,
                stepID: last.stepID,
                costUSD: nil,
                tokens: tok,
                costSource: "unpriced"
            )"""
    new = """        } else if let tok = last.tokens {
            return RelayLaneSpendReading(
                didAppendStepEntry: true,
                stepID: last.stepID,
                costUSD: 0.0,
                tokens: tok,
                costSource: "unpriced"
            )"""
elif mut_id == "4":
    old = 'let rawSpend = queryDouble("SELECT COALESCE(SUM(cost_usd), 0.0) FROM relay_run_lanes;")'
    new = 'let rawSpend = queryDouble("SELECT COALESCE(SUM(cost_usd), 0.0) FROM wiretap_spans;") // M4-Mut-4'
else:
    raise SystemExit(f"unknown mutation id: {mut_id}")

count = text.count(old)
if count != 1:
    sys.stderr.write(f"error: expected mutation target to appear once in {path}, found {count}\n")
    sys.exit(2)

patched = text.replace(old, new, 1)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(patched)
print(f"Applied M4-Mut-{mut_id} patch cleanly in temporary copy.")
PY

    echo "==> Building mutated RelayIDE binary in isolated temp package..."
    local prod_name="Relay""IDE"
    PATH="${ORIG_PATH}" swift build --package-path "${pkg_copy}" \
        ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} --product "${prod_name}" >/dev/null
    local mut_bin="${pkg_copy}/.build/debug/${prod_name}"
    if [[ ! -x "${mut_bin}" ]]; then
        echo "[FAIL] M4-Mut-${mut_id}: mutated binary missing at ${mut_bin}" >&2
        return 1
    fi

    local suite_out="${mut_tmp}/suite.out"
    local suite_rc=0
    set +e
    RELAY_CLI_BIN="${mut_bin}" RELAYIDE_RELAY_SH="${REAL_RELAY_SH}" RELAY_M4_MUTATION_CHILD=1 \
        "${ROOT_DIR}/Scripts/acceptance/m4-budget.sh" >"${suite_out}" 2>&1
    suite_rc=$?
    set -e

    echo "--- Inner m4-budget.sh summary against mutated binary (exit=${suite_rc}) ---"
    grep -E '^(\[(PASS|FAIL|RECORD|SKIP)\]|M4 BUDGET ACCEPTANCE)' "${suite_out}" || cat "${suite_out}"

    rm -rf "${mut_tmp}/pkg"
    local git_after
    git_after="$(git status --porcelain)"
    if [[ "${git_after}" != "${git_before}" ]]; then
        echo "[FAIL] M4-Mut-${mut_id}: repository git status changed during mutation check!" >&2
        return 1
    fi

    if [[ "${suite_rc}" -eq 0 ]]; then
        echo "[FAIL] M4-Mut-${mut_id}: m4-budget.sh unexpectedly exited 0 (mutation NOT caught)" >&2
        return 1
    fi
    if ! grep -Fq "[FAIL] ${expected_fail_row}:" "${suite_out}"; then
        echo "[FAIL] M4-Mut-${mut_id}: expected '[FAIL] ${expected_fail_row}:' in output, not found" >&2
        cat "${suite_out}" >&2
        return 1
    fi

    echo "================================================================"
    echo "[PASS] M4-Mut-${mut_id} CAUGHT: inner m4-budget.sh exited ${suite_rc} with [FAIL] ${expected_fail_row}; working tree untouched"
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

# Build or validate product executable BEFORE narrowing PATH to SAFE_PATH.
BUILD_ELAPSED_SEC="0.00"
PROD_NAME="Relay""IDE"
if [[ -n "${RELAY_CLI_BIN:-}" ]]; then
    if [[ ! -x "${RELAY_CLI_BIN}" ]]; then
        echo "没跑：指定的 RELAY_CLI_BIN 不可执行 (${RELAY_CLI_BIN})" >&2
        exit 2
    fi
    TESTED_BIN="${RELAY_CLI_BIN}"
else
    BUILD_T0="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    PATH="${ORIG_PATH}" swift build ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} --product "${PROD_NAME}" >/dev/null
    BUILD_T1="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    BUILD_ELAPSED_SEC="$(/usr/bin/python3 -I -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "${BUILD_T0}" "${BUILD_T1}")"
    TESTED_BIN="${ROOT_DIR}/.build/debug/${PROD_NAME}"
fi
export RELAY_CLI_BIN="${TESTED_BIN}"
BIN_BYTES="$(wc -c < "${TESTED_BIN}" | tr -d ' ')"
BIN_SHA256="$(shasum -a 256 "${TESTED_BIN}" | awk '{print $1}')"

TMP_BASE="${TMPDIR:-/tmp}"
RAW_WORK_TMP="$(mktemp -d "${TMP_BASE%/}/relayide-m4-acc.XXXXXX")"
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
    local max_sec="${2:-20}"
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

# Set up isolated CLI home, stub-agent.sh copy, and decoy CLIs first in PATH (same arm/assert pattern as m1-run.sh).
RELAY_CLI="${ROOT_DIR}/Scripts/acceptance/relay-cli.sh"
export RELAY_CLI_HOME="${WORK_TMP}/cli-home"
mkdir -p "${RELAY_CLI_HOME}/Library/Preferences"

STUB_DIR="${WORK_TMP}/stub-bin"
DECOY_DIR="${WORK_TMP}/decoys"
DECOY_MARKER="${WORK_TMP}/decoy-cli-invoked.marker"
ROW_TIMINGS_FILE="${WORK_TMP}/row-timings.tsv"
FAIL_LOG="${WORK_TMP}/failures.log"
mkdir -p "${STUB_DIR}" "${DECOY_DIR}"
: > "${ROW_TIMINGS_FILE}"
: > "${FAIL_LOG}"

cp "${ROOT_DIR}/Tests/Support/stub-agent.sh" "${STUB_DIR}/stub-agent.sh"
chmod +x "${STUB_DIR}/stub-agent.sh"
STUB_BIN="${STUB_DIR}/stub-agent.sh"

for agent_name in claude codex agy vibe opencode; do
    cat > "${DECOY_DIR}/${agent_name}" <<EOF
#!/usr/bin/env bash
printf 'decoy %s invoked: pid=%s args=%s\n' "${agent_name}" "\$\$" "\$*" >> "${DECOY_MARKER}"
exit 99
EOF
    chmod +x "${DECOY_DIR}/${agent_name}"
done

export RELAYIDE_RELAY_SH="${REAL_RELAY_SH}"
export RELAY_CLAUDE_BIN="${STUB_BIN}"
export RELAY_CODEX_BIN="${STUB_BIN}"
export RELAY_AGY_BIN="${STUB_BIN}"
export RELAY_VIBE_BIN="${STUB_BIN}"

SAFE_PATH="${DECOY_DIR}:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${SAFE_PATH}"
export RELAY_CLI_CHILD_PATH="${SAFE_PATH}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
unset RELAY_REAL_AGENTS RELAY_BUDGET_USD RELAY_WORKER AGY_CODER_WORKER CLAUDECODE

assert_stub_and_decoys_armed() {
    [[ -n "${WORK_TMP:-}" && -d "${WORK_TMP}" ]] || { echo "FATAL: WORK_TMP missing" >&2; exit 125; }
    [[ ! -e "${DECOY_MARKER}" ]] || {
        echo "FATAL: decoy agent CLI was invoked!" >&2
        cat "${DECOY_MARKER}" >&2 || true
        exit 99
    }
    [[ -n "${STUB_BIN:-}" && -x "${STUB_BIN}" && "${STUB_BIN}" == "${WORK_TMP}/"* ]] || {
        echo "FATAL: STUB_BIN invalid" >&2
        exit 125
    }
    local v val
    for v in RELAY_CLAUDE_BIN RELAY_CODEX_BIN RELAY_AGY_BIN RELAY_VIBE_BIN; do
        val="${!v:-}"
        [[ "${val}" == "${STUB_BIN}" && -x "${val}" ]] || {
            echo "FATAL: ${v} does not point to stub inside WORK_TMP" >&2
            exit 125
        }
    done
    [[ "${PATH}" == "${DECOY_DIR}:"* && "${RELAY_CLI_CHILD_PATH:-}" == "${DECOY_DIR}:"* ]] || {
        echo "FATAL: DECOY_DIR is not first in PATH / RELAY_CLI_CHILD_PATH" >&2
        exit 125
    }
    local t
    for t in claude codex agy vibe opencode; do
        [[ -x "${DECOY_DIR}/${t}" ]] || { echo "FATAL: decoy ${t} missing" >&2; exit 125; }
    done
    [[ -n "${RELAY_CLI_HOME:-}" && "${RELAY_CLI_HOME}" == "${WORK_TMP}/"* ]] || {
        echo "FATAL: RELAY_CLI_HOME outside WORK_TMP" >&2
        exit 125
    }
}

# Synchronous product call through relay-cli.sh with a 120s process-group watchdog.
# Usage: invoke_product <stdout_path> <stderr_path> [KEY=VAL ...] -- <relay-cli args...>
invoke_product() {
    assert_stub_and_decoys_armed
    local out_file="$1"
    local err_file="$2"
    shift 2
    local env_overrides=()
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "--" ]]; then
            shift
            break
        fi
        env_overrides+=("$1")
        shift
    done
    local rc=0
    if /usr/bin/python3 -I - "${out_file}" "${err_file}" "${RELAY_CLI}" "${#env_overrides[@]}" \
        ${env_overrides[@]+"${env_overrides[@]}"} "$@" <<'PY'
import os, signal, subprocess, sys

out_path, err_path, relay_cli = sys.argv[1], sys.argv[2], sys.argv[3]
num_env = int(sys.argv[4])
env_items = sys.argv[5 : 5 + num_env]
cli_args = sys.argv[5 + num_env :]

env = dict(os.environ)
for k in ("RELAY_WORKER", "AGY_CODER_WORKER", "CLAUDECODE", "RELAY_BUDGET_USD", "RELAY_REAL_AGENTS"):
    env.pop(k, None)

for item in env_items:
    k, sep, v = item.partition("=")
    if sep:
        env[k] = v

with open(out_path, "wb") as out_fh, open(err_path, "wb") as err_fh:
    proc = subprocess.Popen(
        [relay_cli] + cli_args,
        stdin=subprocess.DEVNULL,
        stdout=out_fh,
        stderr=err_fh,
        env=env,
        start_new_session=True,
    )
    try:
        sys.exit(proc.wait(timeout=120.0))
    except subprocess.TimeoutExpired:
        err_fh.write(b"\n[m4-budget watchdog] Product command exceeded 120s timeout; killing process group\n")
        err_fh.flush()
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        sys.exit(124)
PY
    then
        rc=0
    else
        rc=$?
    fi
    if [[ -e "${DECOY_MARKER}" ]]; then
        echo "FATAL: decoy agent CLI invoked during invoke_product!" >&2
        cat "${DECOY_MARKER}" >&2 || true
        exit 99
    fi
    return "${rc}"
}

make_git_repo_and_project() {
    local base_dir="$1"
    local init_proj="${2:-1}"
    mkdir -p "${base_dir}/repo" "${base_dir}/traces" "${base_dir}/prompts"
    /usr/bin/git -C "${base_dir}/repo" -c init.defaultBranch=main init -q
    /usr/bin/git -C "${base_dir}/repo" config user.name "Relay Acceptance"
    /usr/bin/git -C "${base_dir}/repo" config user.email "relay-acceptance@example.com"
    printf 'seed\n' > "${base_dir}/repo/README.txt"
    /usr/bin/git -C "${base_dir}/repo" add README.txt
    /usr/bin/git -C "${base_dir}/repo" commit -q --no-gpg-sign -m "Initial commit"
    if [[ "${init_proj}" -eq 1 ]]; then
        invoke_product "${base_dir}/init.out" "${base_dir}/init.err" -- \
            init --project "${base_dir}/proj.relayproj" --lang en
    fi
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_LIST=()

record_pass() {
    local row="$1"
    local msg="$2"
    echo "[PASS] Row ${row}: ${msg}"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}

record_fail() {
    local row="$1"
    local msg="$2"
    echo "[FAIL] Row ${row}: ${msg}" >&2
    printf 'Row %s: %s\n' "${row}" "${msg}" >> "${FAIL_LOG}"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}

record_skip() {
    local row="$1"
    local msg="$2"
    echo "[SKIP] Row ${row}: ${msg}"
    SKIP_LIST+=("Row ${row} (${msg})")
}

run_row() {
    local row_num="$1"
    local row_title="$2"
    local fn_name="$3"
    echo ""
    echo "--- Row ${row_num}: ${row_title} ---"
    local t0 t1 elapsed rc=0
    t0="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    set +e
    ( set -euo pipefail; "${fn_name}" )
    rc=$?
    set -e
    t1="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    elapsed="$(/usr/bin/python3 -I -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "${t0}" "${t1}")"
    printf 'Row %s\t%s\t%s\n' "${row_num}" "${elapsed}" "$( [[ "${rc}" -eq 0 ]] && echo PASS || echo FAIL )" >> "${ROW_TIMINGS_FILE}"
    if [[ -e "${DECOY_MARKER}" ]]; then
        echo "[FAIL] FATAL: decoy agent CLI invoked during Row ${row_num}!" >&2
        cat "${DECOY_MARKER}" >&2 || true
        exit 99
    fi
    if [[ "${rc}" -eq 0 ]]; then
        record_pass "${row_num}" "${row_title} (${elapsed}s)"
    else
        record_fail "${row_num}" "${row_title} (exit=${rc}, ${elapsed}s)"
    fi
}

# ------------------------------------------------------------------
# Row 1: 4-vendor spend & unpriced tokens + status --run / --runs + relay_util.py spent
# ------------------------------------------------------------------
row_1_four_vendor_spend_and_status_run() {
    local d="${WORK_TMP}/r1"
    make_git_repo_and_project "${d}" 1

    printf 'STUB LANE c1\nSTUB WRITE c1.txt claude\nSTUB COST 0.1234\n' > "${d}/prompts/c1.md"
    printf 'STUB LANE v1\nSTUB WRITE v1.txt vibe\nSTUB COST 0.2500\n' > "${d}/prompts/v1.md"
    printf 'STUB LANE a1\nSTUB WRITE a1.txt agy\nSTUB TOKENS 4500\n' > "${d}/prompts/a1.md"
    printf 'STUB LANE x1\nSTUB WRITE x1.txt codex\nSTUB TOKENS 1200\n' > "${d}/prompts/x1.md"

    /usr/bin/python3 -I - "${d}/repo" "${d}/plan.json" <<'PY'
import json, sys
repo_p, plan_p = sys.argv[1], sys.argv[2]
plan = {
    "repo": repo_p,
    "base": "main",
    "lanes": [
        {"id": "c1", "agent": "claude", "prompt": "prompts/c1.md", "after": []},
        {"id": "v1", "agent": "vibe",   "prompt": "prompts/v1.md", "after": []},
        {"id": "a1", "agent": "agy",    "prompt": "prompts/a1.md", "after": []},
        {"id": "x1", "agent": "codex",  "prompt": "prompts/x1.md", "after": []},
    ],
    "verify": "true",
}
with open(plan_p, "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
PY

    invoke_product "${d}/run.out" "${d}/run.err" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${d}/proj.relayproj" --lang en

    local run_id
    run_id="$(/usr/bin/python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["runID"])' "${d}/run.out")"

    invoke_product "${d}/status-run.out" "${d}/status-run.err" -- \
        status --project "${d}/proj.relayproj" --run "${run_id}" --lang en
    invoke_product "${d}/status-runs.out" "${d}/status-runs.err" -- \
        status --project "${d}/proj.relayproj" --runs --lang en

    /usr/bin/python3 -I - "${d}/run.out" "${d}/status-run.out" "${d}/status-runs.out" "${REAL_RELAY_UTIL}" <<'PY'
import json, subprocess, sys

run_p, srun_p, sruns_p, relay_util = sys.argv[1:5]
run_bytes = open(run_p, "rb").read()
srun_bytes = open(srun_p, "rb").read()
assert run_bytes == srun_bytes, f"run stdout ({len(run_bytes)} B) != status --run stdout ({len(srun_bytes)} B)"

obj = json.loads(run_bytes.decode("utf-8"))
runs_arr = json.load(open(sruns_p, encoding="utf-8"))
assert isinstance(runs_arr, list) and len(runs_arr) == 1, f"expected 1 run in --runs, got {len(runs_arr)}"
assert runs_arr[0]["runID"] == obj["runID"]

# Top-level summary checks
assert obj.get("budgetUSD", "MISSING") is None, f"expected budgetUSD=None, got {obj.get('budgetUSD')!r}"
assert abs(obj["totalCostUSD"] - 0.3734) < 1e-9, f"expected totalCostUSD=0.3734, got {obj['totalCostUSD']}"
assert obj["unpricedTokens"] == 5700, f"expected unpricedTokens=5700, got {obj['unpricedTokens']}"
assert obj["pricedLaneCount"] == 2, f"expected pricedLaneCount=2, got {obj['pricedLaneCount']}"
assert obj["unpricedLaneCount"] == 2, f"expected unpricedLaneCount=2, got {obj['unpricedLaneCount']}"
assert obj["noRecordLaneCount"] == 0, f"expected noRecordLaneCount=0, got {obj['noRecordLaneCount']}"
assert obj["budgetExhausted"] is False, f"expected budgetExhausted=False, got {obj['budgetExhausted']}"
assert obj["integration"]["status"] == "verified" and obj["integration"]["ready"] is True

lanes = {l["laneID"]: l for l in obj["lanes"]}
assert set(lanes.keys()) == {"c1", "v1", "a1", "x1"}

# Dollar-priced lanes
for lid, expected_usd in (("c1", 0.1234), ("v1", 0.25)):
    lane = lanes[lid]
    assert lane["costUSD"] is not None and abs(lane["costUSD"] - expected_usd) < 1e-9, f"{lid} costUSD={lane['costUSD']!r}"
    assert lane["tokens"] is None, f"{lid} tokens expected None, got {lane['tokens']!r}"
    assert lane["costSource"] == "usd", f"{lid} costSource={lane['costSource']!r}"
    log_md = lane["worktreePath"] + "/.relay/LOG.md"
    util_out = subprocess.check_output(["/usr/bin/python3", "-I", relay_util, "spent", log_md], text=True).strip()
    util_val = float(util_out)
    assert abs(util_val - expected_usd) < 1e-9, f"{lid} relay_util.py spent={util_val} != {expected_usd}"

# Unpriced token-only lanes (MUST have costUSD == None, never 0 / 0.0!)
for lid, expected_tok in (("a1", 4500), ("x1", 1200)):
    lane = lanes[lid]
    assert lane["costUSD"] is None, f"{lid} costUSD must be null (None), got {lane['costUSD']!r}"
    assert lane["tokens"] == expected_tok, f"{lid} tokens expected {expected_tok}, got {lane['tokens']!r}"
    assert lane["costSource"] == "unpriced", f"{lid} costSource={lane['costSource']!r}"
    log_md = lane["worktreePath"] + "/.relay/LOG.md"
    util_out = subprocess.check_output(["/usr/bin/python3", "-I", relay_util, "spent", log_md], text=True).strip()
    assert abs(float(util_out) - 0.0) < 1e-9, f"{lid} relay_util.py spent expected 0.0, got {util_out}"

print(
    f"Row 1 verified: runID={obj['runID']}, byte-identical status --run, "
    f"c1=$0.1234, v1=$0.2500, a1=null/4500 tok, x1=null/1200 tok, "
    f"totalCostUSD={obj['totalCostUSD']}, unpricedTokens={obj['unpricedTokens']}, budgetUSD=null"
)
PY
}

# ------------------------------------------------------------------
# Row 2: Workspace status --project P (no --run) & export-html on Row 1 project
# ------------------------------------------------------------------
row_2_workspace_status_and_export_html() {
    local proj="${WORK_TMP}/r1/proj.relayproj"
    local d="${WORK_TMP}/r2"
    mkdir -p "${d}"
    [[ -d "${proj}" ]] || { echo "Row 1 project missing at ${proj}" >&2; return 1; }

    invoke_product "${d}/status-en.out" "${d}/status-en.err" -- \
        status --project "${proj}" --lang en
    invoke_product "${d}/status-zh.out" "${d}/status-zh.err" -- \
        status --project "${proj}" --lang zh
    invoke_product "${d}/html-en.out" "${d}/html-en.err" -- \
        export-html "${d}/dossier-en.html" --project "${proj}" --lang en
    invoke_product "${d}/html-zh.out" "${d}/html-zh.err" -- \
        export-html "${d}/dossier-zh.html" --project "${proj}" --lang zh

    /usr/bin/python3 -I - "${d}/status-en.out" "${d}/status-zh.out" "${d}/dossier-en.html" "${d}/dossier-zh.html" <<'PY'
import json, sys

st_en = json.load(open(sys.argv[1], encoding="utf-8"))
st_zh = json.load(open(sys.argv[2], encoding="utf-8"))
html_en = open(sys.argv[3], encoding="utf-8").read()
html_zh = open(sys.argv[4], encoding="utf-8").read()

for label, st in (("en", st_en), ("zh", st_zh)):
    assert st["schemaVersion"] == 7, f"({label}) expected schemaVersion=7, got {st['schemaVersion']}"
    assert abs(st["totalSpendUSD"] - 0.3734) < 1e-9, f"({label}) expected totalSpendUSD=0.3734, got {st['totalSpendUSD']}"
    assert st["totalTokensObserved"] == 5700, f"({label}) expected totalTokensObserved=5700, got {st['totalTokensObserved']}"

for label, html in (("en", html_en), ("zh", html_zh)):
    for needle in ("$0.3734", "5700", "$0.1234", "$0.2500", "4500", "1200", "c1", "v1", "a1", "x1"):
        assert needle in html, f"({label}) HTML missing expected string {needle!r}"
    for forbidden in ("[DEMO]", "[演示数据]"):
        assert forbidden not in html, f"({label}) real HTML dossier unexpectedly contains {forbidden!r}"

assert "Schema v7" in html_en and "unpriced" in html_en
assert "架构 v7" in html_zh and "未计价" in html_zh

print(
    f"Row 2 verified: status totalSpendUSD={st_en['totalSpendUSD']}, "
    f"totalTokensObserved={st_en['totalTokensObserved']}, HTML (EN+ZH) contains $0.3734 & 4 lanes without [DEMO]"
)
PY
}

# ------------------------------------------------------------------
# Row 3: Chain a->b->c->d with RELAY_BUDGET_USD=0.50 (--lang zh and --lang en)
# ------------------------------------------------------------------
row_3_chain_budget_exhaustion() {
    local langs=("en" "zh")
    if [[ "${QUICK}" -eq 1 ]]; then
        langs=("en")
        echo "Note (--quick): running Row 3 in --lang en only (skipping duplicate --lang zh replay)"
    fi

    local lang
    for lang in "${langs[@]}"; do
        local d="${WORK_TMP}/r3-${lang}"
        make_git_repo_and_project "${d}" 1

        printf 'STUB LANE a\nSTUB WRITE a.txt ok\nSTUB COST 0.3000\n' > "${d}/prompts/a.md"
        printf 'STUB LANE b\nSTUB WRITE b.txt ok\nSTUB COST 0.2500\n' > "${d}/prompts/b.md"
        printf 'STUB LANE c\nSTUB WRITE c.txt should-not-run\nSTUB COST 0.1000\n' > "${d}/prompts/c.md"
        printf 'STUB LANE d\nSTUB WRITE d.txt should-be-skipped\nSTUB TOKENS 900\n' > "${d}/prompts/d.md"

        /usr/bin/python3 -I - "${d}/repo" "${d}/plan.json" <<'PY'
import json, sys
repo_p, plan_p = sys.argv[1], sys.argv[2]
plan = {
    "repo": repo_p,
    "base": "main",
    "lanes": [
        {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
        {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": ["a"]},
        {"id": "c", "agent": "claude", "prompt": "prompts/c.md", "after": ["b"]},
        {"id": "d", "agent": "codex",  "prompt": "prompts/d.md", "after": ["c"]},
    ],
}
with open(plan_p, "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
PY

        local rc=0
        if invoke_product "${d}/run.out" "${d}/run.err" \
            "STUB_TRACE_DIR=${d}/traces" "RELAY_BUDGET_USD=0.50" -- \
            run "${d}/plan.json" --project "${d}/proj.relayproj" --lang "${lang}"
        then
            rc=0
        else
            rc=$?
        fi
        if [[ "${rc}" -ne 1 ]]; then
            echo "(${lang}) expected RelayIDE run exit 1, got ${rc}" >&2
            cat "${d}/run.err" >&2 || true
            return 1
        fi

        /usr/bin/python3 -I - "${lang}" "${d}/run.out" "${d}/traces" <<'PY'
import json, os, sys

lang, out_p, traces_dir = sys.argv[1:4]
obj = json.load(open(out_p, encoding="utf-8"))

assert abs(obj["budgetUSD"] - 0.50) < 1e-9, f"({lang}) expected budgetUSD=0.50, got {obj['budgetUSD']}"
assert abs(obj["totalCostUSD"] - 0.55) < 1e-9, f"({lang}) expected totalCostUSD=0.55, got {obj['totalCostUSD']}"
assert obj["pricedLaneCount"] == 2
assert obj["noRecordLaneCount"] == 1
assert obj["budgetExhausted"] is True, f"({lang}) expected budgetExhausted=True"
assert obj["integration"]["status"] == "skipped" and obj["integration"]["ready"] is False

by_id = {l["laneID"]: l for l in obj["lanes"]}
for lid, usd in (("a", 0.30), ("b", 0.25)):
    l = by_id[lid]
    assert l["status"] == "succeeded", f"({lang}) {lid} status={l['status']}"
    assert l["commitOID"] is not None, f"({lang}) {lid} missing commitOID"
    assert abs(l["costUSD"] - usd) < 1e-9
    assert os.path.exists(os.path.join(traces_dir, f"{lid}.trace"))

c = by_id["c"]
assert c["status"] == "refused", f"({lang}) expected c.status='refused', got {c['status']!r}"
assert c["exitCode"] == 2, f"({lang}) expected c.exitCode=2, got {c['exitCode']!r}"
assert c["commitOID"] is None, f"({lang}) expected c.commitOID=None"
assert c["costUSD"] is None and c["costSource"] == "no_record"
assert not os.path.exists(os.path.join(traces_dir, "c.trace")), f"({lang}) c.trace must not exist"
if c.get("worktreePath"):
    log_c = os.path.join(c["worktreePath"], ".relay", "LOG.md")
    assert not os.path.exists(log_c), f"({lang}) c LOG.md must not exist ({log_c})"
reason_c = c.get("reason") or ""
assert "not started: the job budget" in reason_c, f"({lang}) reason missing relay.sh message: {reason_c!r}"
assert "$0.5500" in reason_c and "$0.5000" in reason_c, f"({lang}) reason missing dollar figures: {reason_c!r}"
if lang == "zh":
    assert "预算已用完" in reason_c, f"(zh) reason missing Chinese budget phrase: {reason_c!r}"
else:
    assert "budget spent" in reason_c, f"(en) reason missing English budget phrase: {reason_c!r}"

d = by_id["d"]
assert d["status"] == "skipped", f"({lang}) expected d.status='skipped', got {d['status']!r}"
assert d["worktreePath"] is None
assert not os.path.exists(os.path.join(traces_dir, "d.trace")), f"({lang}) d.trace must not exist"

print(f"Row 3 ({lang}) verified: exit=1, a=$0.30 & b=$0.25 succeeded, c refused (exit=2, reason={reason_c!r}), d skipped")
PY
    done
}

# ------------------------------------------------------------------
# Row 4: Sufficient budget RELAY_BUDGET_USD=1.00 passes remaining $0.7000 to b and verifies
# ------------------------------------------------------------------
row_4_sufficient_budget_remaining_passed() {
    local d="${WORK_TMP}/r4"
    make_git_repo_and_project "${d}" 1

    printf 'STUB LANE a\nSTUB WRITE a.txt ok\nSTUB COST 0.3000\n' > "${d}/prompts/a.md"
    printf 'STUB LANE b\nSTUB WRITE b.txt ok\nSTUB COST 0.2500\n' > "${d}/prompts/b.md"

    /usr/bin/python3 -I - "${d}/repo" "${d}/plan.json" <<'PY'
import json, sys
repo_p, plan_p = sys.argv[1], sys.argv[2]
plan = {
    "repo": repo_p,
    "base": "main",
    "lanes": [
        {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
        {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": ["a"]},
    ],
    "verify": "true",
}
with open(plan_p, "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
PY

    invoke_product "${d}/run.out" "${d}/run.err" \
        "STUB_TRACE_DIR=${d}/traces" "RELAY_BUDGET_USD=1.00" -- \
        run "${d}/plan.json" --project "${d}/proj.relayproj" --lang en

    /usr/bin/python3 -I - "${d}/run.out" "${d}/proj.relayproj" "${d}/traces" <<'PY'
import json, os, sys

out_p, proj_p, traces_dir = sys.argv[1:4]
obj = json.load(open(out_p, encoding="utf-8"))
run_id = obj["runID"]

assert abs(obj["budgetUSD"] - 1.0) < 1e-9, f"expected budgetUSD=1.0, got {obj['budgetUSD']}"
assert abs(obj["totalCostUSD"] - 0.55) < 1e-9, f"expected totalCostUSD=0.55, got {obj['totalCostUSD']}"
assert obj["budgetExhausted"] is False, f"expected budgetExhausted=False"
assert obj["integration"]["status"] == "verified" and obj["integration"]["ready"] is True

by_id = {l["laneID"]: l for l in obj["lanes"]}
assert by_id["a"]["status"] == "succeeded" and by_id["b"]["status"] == "succeeded"

b_pty_path = os.path.join(proj_p, "runs", run_id, "lanes", "b.pty")
b_pty_text = open(b_pty_path, encoding="utf-8", errors="replace").read()
assert "0.7000" in b_pty_text, f"expected b.pty to contain remaining allowance 0.7000; got:\n{b_pty_text}"

b_budget_path = os.path.join(traces_dir, "b.budget")
b_budget_text = open(b_budget_path, encoding="utf-8").read()
assert "RELAY_BUDGET_USD=0.7000" in b_budget_text, f"expected RELAY_BUDGET_USD=0.7000 in b.budget, got {b_budget_text!r}"
assert "CLI_BUDGET_CAP=0.7000" in b_budget_text, f"expected CLI_BUDGET_CAP=0.7000 in b.budget, got {b_budget_text!r}"

print(f"Row 4 verified: exit=0, budgetUSD=1.0, totalCostUSD=0.55, b received $0.7000 in b.pty & --max-price, integration.ready=true")
PY
}

# ------------------------------------------------------------------
# Row 5: Dollar lane ($0.60) exhausts RELAY_BUDGET_USD=0.50 -> subsequent unpriced agy lane refused
# ------------------------------------------------------------------
row_5_unpriced_agy_refused_after_dollar_exhaustion() {
    local d="${WORK_TMP}/r5"
    make_git_repo_and_project "${d}" 1

    printf 'STUB LANE a\nSTUB WRITE a.txt spend\nSTUB COST 0.6000\n' > "${d}/prompts/a.md"
    printf 'STUB LANE b\nSTUB WRITE b.txt agy-should-not-run\nSTUB TOKENS 3000\n' > "${d}/prompts/b.md"

    /usr/bin/python3 -I - "${d}/repo" "${d}/plan.json" <<'PY'
import json, sys
repo_p, plan_p = sys.argv[1], sys.argv[2]
plan = {
    "repo": repo_p,
    "base": "main",
    "lanes": [
        {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
        {"id": "b", "agent": "agy",    "prompt": "prompts/b.md", "after": ["a"]},
    ],
}
with open(plan_p, "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
PY

    local rc=0
    if invoke_product "${d}/run.out" "${d}/run.err" \
        "STUB_TRACE_DIR=${d}/traces" "RELAY_BUDGET_USD=0.50" -- \
        run "${d}/plan.json" --project "${d}/proj.relayproj" --lang en
    then
        rc=0
    else
        rc=$?
    fi
    if [[ "${rc}" -ne 1 ]]; then
        echo "expected RelayIDE run exit 1, got ${rc}" >&2
        cat "${d}/run.err" >&2 || true
        return 1
    fi

    /usr/bin/python3 -I - "${d}/run.out" "${d}/traces" <<'PY'
import json, os, sys

out_p, traces_dir = sys.argv[1], sys.argv[2]
obj = json.load(open(out_p, encoding="utf-8"))

assert abs(obj["budgetUSD"] - 0.50) < 1e-9
assert abs(obj["totalCostUSD"] - 0.60) < 1e-9
assert obj["budgetExhausted"] is True
assert obj["integration"]["status"] == "skipped" and obj["integration"]["ready"] is False

by_id = {l["laneID"]: l for l in obj["lanes"]}
assert by_id["a"]["status"] == "succeeded" and abs(by_id["a"]["costUSD"] - 0.60) < 1e-9

b = by_id["b"]
assert b["agent"] == "agy"
assert b["status"] == "refused", f"expected agy lane b status='refused', got {b['status']!r}"
assert b["exitCode"] == 2, f"expected agy lane b exitCode=2, got {b['exitCode']!r}"
assert b["costUSD"] is None and b["tokens"] is None and b["costSource"] == "no_record"
assert "not started: the job budget" in (b.get("reason") or "")
assert not os.path.exists(os.path.join(traces_dir, "b.trace")), "agy stub must not execute when refused"

print("Row 5 verified: after a=$0.60 >= $0.50, unpriced agy lane b refused with exit=2 (run exit=1)")
PY
}

# ------------------------------------------------------------------
# Row 6: Invalid RELAY_BUDGET_USD values (0, -2.5, abc, NaN, inf) -> exit 2, zero side effects
# ------------------------------------------------------------------
row_6_invalid_budget_values_rejected() {
    local d="${WORK_TMP}/r6"
    make_git_repo_and_project "${d}" 1

    printf 'STUB LANE a\nSTUB WRITE a.txt should-not-run\n' > "${d}/prompts/a.md"
    /usr/bin/python3 -I - "${d}/repo" "${d}/plan.json" <<'PY'
import json, sys
repo_p, plan_p = sys.argv[1], sys.argv[2]
plan = {
    "repo": repo_p,
    "base": "main",
    "lanes": [{"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []}],
}
with open(plan_p, "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
PY

    local bad lang idx=0
    for bad in "0" "-2.5" "abc" "NaN" "inf"; do
        for lang in "en" "zh"; do
            idx=$(( idx + 1 ))
            local out_f="${d}/out-${idx}.txt"
            local err_f="${d}/err-${idx}.txt"
            local rc=0
            if invoke_product "${out_f}" "${err_f}" \
                "STUB_TRACE_DIR=${d}/traces" "RELAY_BUDGET_USD=${bad}" -- \
                run "${d}/plan.json" --project "${d}/proj.relayproj" --lang "${lang}"
            then
                rc=0
            else
                rc=$?
            fi
            if [[ "${rc}" -ne 2 ]]; then
                echo "RELAY_BUDGET_USD='${bad}' (${lang}): expected exit 2, got ${rc}" >&2
                cat "${err_f}" >&2 || true
                return 1
            fi
            if [[ -s "${out_f}" ]]; then
                echo "RELAY_BUDGET_USD='${bad}' (${lang}): expected empty stdout, got non-empty" >&2
                return 1
            fi
            if ! grep -Fq "RELAY_BUDGET_USD" "${err_f}"; then
                echo "RELAY_BUDGET_USD='${bad}' (${lang}): stderr did not mention RELAY_BUDGET_USD" >&2
                cat "${err_f}" >&2 || true
                return 1
            fi
        done
    done

    local branches wt_count
    branches="$(/usr/bin/git -C "${d}/repo" branch --format='%(refname:short)')"
    wt_count="$(/usr/bin/git -C "${d}/repo" worktree list --porcelain | grep -c '^worktree ' || true)"
    [[ "${branches}" == "main" ]] || { echo "unexpected git branches: ${branches}" >&2; return 1; }
    [[ "${wt_count}" -eq 1 ]] || { echo "unexpected git worktree count: ${wt_count}" >&2; return 1; }
    [[ ! -e "${d}/proj.relayproj/runs" ]] || { echo "proj.relayproj/runs created on invalid budget" >&2; return 1; }
    [[ -z "$(ls -A "${d}/traces" 2>/dev/null || true)" ]] || { echo "stub trace created on invalid budget" >&2; return 1; }

    invoke_product "${d}/runs.out" "${d}/runs.err" -- \
        status --project "${d}/proj.relayproj" --runs --lang en
    /usr/bin/python3 -I -c 'import json, sys; assert json.load(open(sys.argv[1])) == []' "${d}/runs.out"

    echo "Row 6 verified: 5 invalid RELAY_BUDGET_USD values (0, -2.5, abc, NaN, inf) x (en, zh) all exited 2 with empty stdout and zero disk/git/SQLite side effects"
}

# ------------------------------------------------------------------
# Row 7: Proxy-removal cleanliness & empty default RelayStudioViewModel / workspace spend == 0
# ------------------------------------------------------------------
row_7_proxy_removed_and_empty_default() {
    local d="${WORK_TMP}/r7"
    mkdir -p "${d}"

    /usr/bin/python3 -I - "${ROOT_DIR}" <<'PY'
import os, sys

root = sys.argv[1]
mod_name = "RelayWiretap" + "Proxy"
srv_name = "LoopbackWiretap" + "ProxyServer"
dlp_name = "OutboundSecret" + "DLPEngine"
port_tok = "127.0.0.1" + ":43118"
dlp_phrase = "outbound secret " + "dlp"

removed_paths = [
    "Sources/" + mod_name,
    "Tests/RelayIDETests/WiretapSSEAndDLP" + "CircuitBreakerTests.swift",
    "docs/screenshot-wiretap" + "-guardrails.png",
    "docs/screenshot-wiretap" + "-guardrails-zh.png",
]
for rel in removed_paths:
    assert not os.path.exists(os.path.join(root, rel)), f"Removed path still exists: {rel}"

pkg_text = open(os.path.join(root, "Package.swift"), encoding="utf-8").read()
assert mod_name not in pkg_text, f"Package.swift still contains {mod_name}"

targets = ["README.md", "README.zh-CN.md"]
for dirpath, _, filenames in os.walk(os.path.join(root, "Sources")):
    for fn in filenames:
        if fn.endswith(".swift"):
            targets.append(os.path.relpath(os.path.join(dirpath, fn), root))

hits = []
for rel in targets:
    text = open(os.path.join(root, rel), encoding="utf-8").read()
    lower = text.lower()
    for tok in (mod_name, srv_name, dlp_name, port_tok):
        if tok in text:
            hits.append((rel, tok))
    if dlp_phrase in lower:
        hits.append((rel, dlp_phrase))

assert not hits, f"Forbidden proxy/DLP tokens found in Sources/ or README*: {hits}"
print("Static check passed: Sources/RelayWiretapProxy absent, Package.swift clean, 0 proxy/port/DLP hits in Sources/ & README*.")
PY

    invoke_product "${d}/init.out" "${d}/init.err" -- init --project "${d}/empty.relayproj" --lang en
    invoke_product "${d}/st.out" "${d}/st.err" -- status --project "${d}/empty.relayproj" --lang en
    /usr/bin/python3 -I -c '
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["totalSpendUSD"] == 0 and st["totalTokensObserved"] == 0 and st["activeLaneCount"] == 0, st
' "${d}/st.out"

    if [[ "${QUICK}" -eq 1 || "${RELAY_M4_MUTATION_CHILD:-0}" == "1" ]]; then
        echo "Note: skipping StudioViewModelAndHonestyTests swift test invocation in --quick / --mutation child mode (static + CLI empty check passed)."
    else
        HOME="${RELAY_CLI_HOME}" CFFIXED_USER_HOME="${RELAY_CLI_HOME}" PATH="${DECOY_DIR}:${ORIG_PATH}" \
            swift test ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} --no-parallel \
            --filter "StudioViewModelAndHonestyTests/defaultInitWithoutDemoIsCompletelyEmpty" \
            >"${d}/vm-test.out" 2>&1
        grep -Fq "defaultInitWithoutDemoIsCompletelyEmpty" "${d}/vm-test.out" || true
        echo "Headless ViewModel check passed: StudioViewModelAndHonestyTests/defaultInitWithoutDemoIsCompletelyEmpty exited 0."
    fi
}

# ------------------------------------------------------------------
# Row 8: Schema v6 -> v7 upgrade (genuine SQLite v6 DB without budget_usd + status --runs + new run)
# ------------------------------------------------------------------
row_8_schema_v6_to_v7_upgrade() {
    local d="${WORK_TMP}/r8"
    make_git_repo_and_project "${d}" 0

    local bundle="${d}/legacy-v6.relayproj"
    mkdir -p "${bundle}"

    # Construct a genuine Schema v6 SQLite database directly via sqlite3 (versions 1..6, NO budget_usd column).
    /usr/bin/python3 -I - "${bundle}/workspace.sqlite" "${d}/repo" <<'PY'
import sqlite3, sys

db_path, repo_path = sys.argv[1], sys.argv[2]
conn = sqlite3.connect(db_path)
conn.executescript("""
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);
CREATE TABLE workspace_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE managed_lanes (lane_id TEXT PRIMARY KEY, vendor TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE dag_specs (dag_id TEXT PRIMARY KEY, name TEXT NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE semantic_merge_reports (relative_path TEXT PRIMARY KEY, auto_merged_count INTEGER NOT NULL, conflict_count INTEGER NOT NULL, payload_json TEXT NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE wiretap_spans (span_id TEXT PRIMARY KEY, lane_id TEXT NOT NULL, vendor TEXT NOT NULL, total_tokens INTEGER NOT NULL, cost_usd REAL NOT NULL, payload_json TEXT NOT NULL, recorded_at REAL NOT NULL);
CREATE TABLE guardrail_findings (finding_id TEXT PRIMARY KEY, plugin_id TEXT NOT NULL, severity TEXT NOT NULL, payload_json TEXT NOT NULL, created_at REAL NOT NULL);
CREATE TABLE undo_redo_stack (seq INTEGER PRIMARY KEY AUTOINCREMENT, stack_kind TEXT NOT NULL, title TEXT NOT NULL, mutation_json TEXT NOT NULL, created_at REAL NOT NULL);
CREATE TABLE relay_runs (
    run_id TEXT PRIMARY KEY,
    repo_path TEXT NOT NULL,
    plan_copy_path TEXT NOT NULL,
    base_ref TEXT NOT NULL,
    base_commit_oid TEXT NOT NULL,
    verify_command TEXT,
    relay_sh_path TEXT NOT NULL,
    relay_sh_sha256 TEXT NOT NULL,
    started_at REAL NOT NULL,
    finished_at REAL,
    status TEXT NOT NULL,
    reason TEXT,
    relayide_pid INTEGER NOT NULL
);
CREATE TABLE relay_run_lanes (
    run_id TEXT NOT NULL REFERENCES relay_runs(run_id) ON DELETE CASCADE,
    lane_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    agent TEXT NOT NULL,
    prompt_path TEXT NOT NULL,
    after_json TEXT NOT NULL,
    status TEXT NOT NULL,
    exit_code INTEGER,
    signal INTEGER,
    reason TEXT,
    started_at REAL,
    finished_at REAL,
    pid INTEGER,
    cost_usd REAL,
    tokens INTEGER,
    cost_source TEXT,
    branch TEXT,
    commit_oid TEXT,
    worktree_path TEXT,
    uncommitted_files_json TEXT,
    PRIMARY KEY (run_id, lane_id)
);
CREATE INDEX idx_relay_run_lanes_run ON relay_run_lanes(run_id, ordinal);
CREATE TABLE relay_run_integration (
    run_id TEXT PRIMARY KEY REFERENCES relay_runs(run_id) ON DELETE CASCADE,
    branch TEXT,
    worktree_path TEXT,
    base_commit_oid TEXT NOT NULL,
    head_commit_oid TEXT,
    status TEXT NOT NULL,
    reason TEXT,
    ready INTEGER NOT NULL DEFAULT 0,
    verify_command TEXT,
    verify_timeout_sec INTEGER,
    verify_status TEXT,
    verify_exit_code INTEGER,
    verify_signal INTEGER,
    verify_pid INTEGER,
    verify_started_at REAL,
    verify_finished_at REAL,
    verify_log_path TEXT,
    verify_log_bytes INTEGER,
    verify_log_truncated INTEGER,
    verify_modified_tracked_files_json TEXT
);
CREATE TABLE relay_run_merges (
    run_id TEXT NOT NULL REFERENCES relay_runs(run_id) ON DELETE CASCADE,
    ordinal INTEGER NOT NULL,
    lane_id TEXT NOT NULL,
    lane_commit_oid TEXT,
    status TEXT NOT NULL,
    merge_commit_oid TEXT,
    conflicts_json TEXT NOT NULL,
    conflict_lines_json TEXT NOT NULL,
    started_at REAL,
    finished_at REAL,
    PRIMARY KEY (run_id, lane_id)
);
INSERT INTO schema_migrations (version, applied_at) VALUES
    (1, 1763000001), (2, 1763000002), (3, 1763000003),
    (4, 1763000004), (5, 1763000005), (6, 1763000006);
INSERT INTO workspace_meta (key, value) VALUES ('workspace_name', 'LegacyV6Bundle');
""")
conn.execute(
    """INSERT INTO relay_runs (
        run_id, repo_path, plan_copy_path, base_ref, base_commit_oid,
        verify_command, relay_sh_path, relay_sh_sha256,
        started_at, finished_at, status, reason, relayide_pid
    ) VALUES (?, ?, ?, 'main', ?, 'true', '/tmp/relay.sh', ?, 1763300000, 1763300030, 'succeeded', NULL, 7777)""",
    ("20261117-120000-0006", repo_path, repo_path + "/plan.json", "1" * 40, "2" * 64),
)
conn.execute(
    """INSERT INTO relay_run_lanes VALUES
        ('20261117-120000-0006', 'legacy-claude', 0, 'claude', '/tmp/c.md', '[]', 'succeeded', 0, NULL, NULL,
         1763300001, 1763300015, 7778, 0.042, NULL, 'usd', 'relay/20261117-120000-0006/legacy-claude', ?, '/tmp/wt/c', NULL),
        ('20261117-120000-0006', 'legacy-agy', 1, 'agy', '/tmp/a.md', '["legacy-claude"]', 'succeeded', 0, NULL, NULL,
         1763300016, 1763300028, 7779, NULL, 1800, 'unpriced', 'relay/20261117-120000-0006/legacy-agy', ?, '/tmp/wt/a', NULL)""",
    ("3" * 40, "4" * 40),
)
conn.execute(
    """INSERT INTO relay_run_integration VALUES
        ('20261117-120000-0006', 'relay/20261117-120000-0006/integration', '/tmp/wt/int', ?, ?,
         'verified', NULL, 1, 'true', 1800, 'succeeded', 0, NULL, NULL, 1763300028, 1763300030, '/tmp/v.pty', 8, 0, '[]')""",
    ("1" * 40, "5" * 40),
)
cols = [r[1] for r in conn.execute("PRAGMA table_info(relay_runs)").fetchall()]
max_v = conn.execute("SELECT MAX(version) FROM schema_migrations").fetchone()[0]
assert "budget_usd" not in cols and max_v == 6, (cols, max_v)
conn.commit()
conn.close()
print("Constructed genuine Schema v6 SQLite database (max_version=6, budget_usd absent).")
PY

    invoke_product "${d}/runs-before.out" "${d}/runs-before.err" -- \
        status --project "${bundle}" --runs --lang en
    invoke_product "${d}/st-before.out" "${d}/st-before.err" -- \
        status --project "${bundle}" --lang en

    # Now execute a new v7 run with RELAY_BUDGET_USD=0.80 on the upgraded bundle.
    printf 'STUB LANE fresh\nSTUB WRITE fresh.txt v7\nSTUB COST 0.1500\n' > "${d}/prompts/fresh.md"
    /usr/bin/python3 -I - "${d}/repo" "${d}/plan.json" <<'PY'
import json, sys
repo_p, plan_p = sys.argv[1], sys.argv[2]
plan = {
    "repo": repo_p,
    "base": "main",
    "lanes": [{"id": "fresh", "agent": "vibe", "prompt": "prompts/fresh.md", "after": []}],
    "verify": "true",
}
with open(plan_p, "w", encoding="utf-8") as fh:
    json.dump(plan, fh, indent=2)
PY

    invoke_product "${d}/new-run.out" "${d}/new-run.err" \
        "STUB_TRACE_DIR=${d}/traces" "RELAY_BUDGET_USD=0.80" -- \
        run "${d}/plan.json" --project "${bundle}" --lang en
    invoke_product "${d}/runs-after.out" "${d}/runs-after.err" -- \
        status --project "${bundle}" --runs --lang en
    invoke_product "${d}/st-after.out" "${d}/st-after.err" -- \
        status --project "${bundle}" --lang en

    /usr/bin/python3 -I - "${bundle}/workspace.sqlite" "${d}/runs-before.out" "${d}/st-before.out" \
        "${d}/new-run.out" "${d}/runs-after.out" "${d}/st-after.out" <<'PY'
import json, sqlite3, sys

db_p, rb_p, sb_p, nr_p, ra_p, sa_p = sys.argv[1:7]

conn = sqlite3.connect(db_p)
cols = [r[1] for r in conn.execute("PRAGMA table_info(relay_runs)").fetchall()]
versions = [r[0] for r in conn.execute("SELECT version FROM schema_migrations ORDER BY version").fetchall()]
conn.close()
assert "budget_usd" in cols, f"expected budget_usd column after v7 migration, got {cols}"
assert versions == [1, 2, 3, 4, 5, 6, 7], f"expected migrations [1..7], got {versions}"

rb = json.load(open(rb_p, encoding="utf-8"))
sb = json.load(open(sb_p, encoding="utf-8"))
assert len(rb) == 1
v6_run = rb[0]
assert v6_run["runID"] == "20261117-120000-0006"
assert v6_run["budgetUSD"] is None
assert abs(v6_run["totalCostUSD"] - 0.042) < 1e-9
assert v6_run["unpricedTokens"] == 1800
assert sb["schemaVersion"] == 7
assert abs(sb["totalSpendUSD"] - 0.042) < 1e-9 and sb["totalTokensObserved"] == 1800

nr = json.load(open(nr_p, encoding="utf-8"))
assert abs(nr["budgetUSD"] - 0.80) < 1e-9 and abs(nr["totalCostUSD"] - 0.15) < 1e-9
assert nr["integration"]["ready"] is True

ra = {r["runID"]: r for r in json.load(open(ra_p, encoding="utf-8"))}
assert len(ra) == 2
assert ra["20261117-120000-0006"]["budgetUSD"] is None
assert abs(ra["20261117-120000-0006"]["totalCostUSD"] - 0.042) < 1e-9
assert abs(ra[nr["runID"]]["budgetUSD"] - 0.80) < 1e-9

sa = json.load(open(sa_p, encoding="utf-8"))
assert abs(sa["totalSpendUSD"] - 0.192) < 1e-9, f"expected cumulative totalSpendUSD=0.192, got {sa['totalSpendUSD']}"
assert sa["totalTokensObserved"] == 1800

print("Row 8 verified: v6 DB upgraded cleanly to Schema v7, legacy run budgetUSD=null & $0.042/1800 tok preserved, new v7 run ($0.15 / cap $0.80) persisted (workspace total $0.192).")
PY
}

# ------------------------------------------------------------------
# Main Suite Execution (Rows 1..10)
# ------------------------------------------------------------------
run_suite() {
    echo "================================================================"
    echo "RelayIDE M4 Acceptance Suite (Spend Ledger & Whole-Job Budget)"
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Commit:    $(git rev-parse --short HEAD) (branch: $(git rev-parse --abbrev-ref HEAD); ${TREE_STATE})"
    echo "Mode:      $( [[ "${QUICK}" -eq 1 ]] && echo "quick" || echo "full" )"
    echo "relay.sh sha256 (start):      ${SHA256_RELAY_SH_BEFORE}"
    echo "relay_util.py sha256 (start): ${SHA256_RELAY_UTIL_BEFORE}"
    echo "================================================================"

    run_row "1" "4-vendor run (c1 \$0.1234, v1 \$0.25, a1 4500 tok, x1 1200 tok) matches relay_util.py spent, status --run byte-identical, status --runs" row_1_four_vendor_spend_and_status_run
    run_row "2" "Workspace status --project P and export-html report \$0.3734 & 5700 tokens without [DEMO]" row_2_workspace_status_and_export_html
    run_row "3" "Chain a->b->c->d with RELAY_BUDGET_USD=0.50 refuses c (exit 2) and skips d (exit 1)" row_3_chain_budget_exhaustion
    if [[ "${QUICK}" -eq 1 ]]; then
        SKIP_LIST+=("Row 3 (--lang zh duplicate replay)")
    fi

    if [[ "${QUICK}" -eq 1 ]]; then
        record_skip "4" "--quick skips sufficient-budget 2-lane verify scenario"
        record_skip "5" "--quick skips mixed dollar + unpriced agy refusal scenario"
    else
        run_row "4" "Sufficient RELAY_BUDGET_USD=1.00 passes remaining \$0.7000 to lane b and verifies ready=true" row_4_sufficient_budget_remaining_passed
        run_row "5" "Exhausted RELAY_BUDGET_USD=0.50 after \$0.60 dollar lane refuses subsequent unpriced agy lane" row_5_unpriced_agy_refused_after_dollar_exhaustion
    fi

    run_row "6" "Invalid RELAY_BUDGET_USD (0, -2.5, abc, NaN, inf) exit 2 with empty stdout and zero side effects" row_6_invalid_budget_values_rejected
    run_row "7" "Proxy removed across Package.swift/Sources/README* and default empty StudioViewModel/workspace spend is 0" row_7_proxy_removed_and_empty_default
    if [[ "${QUICK}" -eq 1 ]]; then
        SKIP_LIST+=("Row 7 (StudioViewModel swift test)")
    fi

    if [[ "${QUICK}" -eq 1 ]]; then
        record_skip "8" "--quick skips Schema v6 -> v7 SQLite upgrade + live run scenario"
    else
        run_row "8" "Genuine Schema v6 SQLite bundle upgrades to v7 (legacy budgetUSD=null preserved) and accepts new v7 run" row_8_schema_v6_to_v7_upgrade
    fi

    # --- Row 9: Post-suite hygiene (decoy marker absent, 0 leftover procs, ~/Library unchanged, relay.sh sha256, git status) ---
    echo ""
    echo "--- Row 9: Post-suite hygiene (0 decoy hits, 0 leftover processes, ~/Library unchanged, relay.sh sha256 & git status; scoped/full tests chained by Scripts/test.sh) ---"
    local r9_t0 r9_t1 r9_elapsed r9_ok=1
    r9_t0="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"

    if [[ -e "${DECOY_MARKER}" ]]; then
        echo "Decoy CLI marker file exists!" >&2
        cat "${DECOY_MARKER}" >&2 || true
        r9_ok=0
    fi
    if ! poll_until_no_procs "${WORK_TMP}" 10; then
        r9_ok=0
    fi

    local prefs_os_after sha_sh_after sha_util_after git_status_after
    prefs_os_after="$(ls -1 "${PREFS_DIR_OS}" 2>/dev/null | grep -i 'relayide' | sort || true)"
    sha_sh_after="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
    sha_util_after="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"

    if [[ "${prefs_os_after}" != "${PREFS_OS_BEFORE}" ]]; then
        echo "~/Library/Preferences RelayIDE entries changed: before='${PREFS_OS_BEFORE}' after='${prefs_os_after}'" >&2
        r9_ok=0
    fi
    if [[ "${sha_sh_after}" != "${SHA256_RELAY_SH_BEFORE}" || "${sha_util_after}" != "${SHA256_RELAY_UTIL_BEFORE}" ]]; then
        echo "relay.sh or relay_util.py sha256 changed during run!" >&2
        r9_ok=0
    fi
    if [[ "${RECORD}" -eq 0 ]]; then
        git_status_after="$(git status --porcelain)"
        if [[ "${git_status_after}" != "${GIT_STATUS_BEFORE}" ]]; then
            echo "git status --porcelain changed during run without --record" >&2
            r9_ok=0
        fi
    fi

    r9_t1="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    r9_elapsed="$(/usr/bin/python3 -I -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "${r9_t0}" "${r9_t1}")"
    printf 'Row 9\t%s\t%s\n' "${r9_elapsed}" "$( [[ "${r9_ok}" -eq 1 ]] && echo PASS || echo FAIL )" >> "${ROW_TIMINGS_FILE}"

    if [[ "${r9_ok}" -eq 1 ]]; then
        record_pass "9" "0 decoy CLI hits, 0 leftover processes, ~/Library/Preferences unchanged, relay.sh & relay_util.py sha256 unchanged, working tree unchanged (${r9_elapsed}s; swift test & milestones chained in Scripts/test.sh)"
    else
        record_fail "9" "post-suite hygiene check failed (${r9_elapsed}s)"
    fi

    # --- Row 10: Record-only telemetry (timings, relay.sh/relay_util.py SHA-256, binary size) ---
    local suite_end_epoch total_elapsed bin_mib
    suite_end_epoch="$(/usr/bin/python3 -I -c 'import time; print(f"{time.time():.3f}")')"
    total_elapsed="$(/usr/bin/python3 -I -c 'import sys; print(f"{float(sys.argv[2])-float(sys.argv[1]):.2f}")' "${SUITE_START_EPOCH}" "${suite_end_epoch}")"
    bin_mib="$(/usr/bin/python3 -I -c 'import sys; print(f"{int(sys.argv[1])/(1024*1024):.2f}")' "${BIN_BYTES}")"

    echo ""
    echo "--- Row 10 (Record-Only): Per-row timings, agent-relay checksums, and binary size ---"
    echo "Build elapsed:                ${BUILD_ELAPSED_SEC}s"
    while IFS=$'\t' read -r r_label r_sec r_st; do
        printf '  %-8s %-7s %ss\n' "${r_label}" "[${r_st}]" "${r_sec}"
    done < "${ROW_TIMINGS_FILE}"
    echo "Suite total wall-clock:       ${total_elapsed}s"
    echo "relay.sh sha256 (end):        ${sha_sh_after}"
    echo "relay_util.py sha256 (end):   ${sha_util_after}"
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
    echo "[RECORD] Row 10: total=${total_elapsed}s, build=${BUILD_ELAPSED_SEC}s, binary=${BIN_BYTES} B (${bin_mib} MiB), relay.sh=${sha_sh_after}"

    rm -rf "${WORK_TMP}" 2>/dev/null || true

    echo ""
    echo "================================================================"
    if [[ "${FAIL_COUNT}" -eq 0 ]]; then
        if [[ "${QUICK}" -eq 1 ]]; then
            echo "ALL M4 QUICK ACCEPTANCE CHECKS PASSED (passed=${PASS_COUNT}, skipped=${#SKIP_LIST[@]}, total=${total_elapsed}s)"
        else
            echo "ALL M4 BUDGET ACCEPTANCE CHECKS PASSED (Rows 1..9 hard checks + Row 10 recorded; total=${total_elapsed}s)"
        fi
        echo "================================================================"
        return 0
    else
        echo "M4 BUDGET ACCEPTANCE SUITE FAILED (passed=${PASS_COUNT}, failed=${FAIL_COUNT}, total=${total_elapsed}s)"
        echo "================================================================"
        return 1
    fi
}

if [[ "${RECORD}" -eq 1 ]]; then
    mkdir -p "${ROOT_DIR}/reports"
    REPORT_REL="reports/m4-budget.txt"
    run_suite 2>&1 | sanitize_stream | tee "${ROOT_DIR}/${REPORT_REL}"
    SUITE_RC="${PIPESTATUS[0]}"
    echo "Report written to <repo>/${REPORT_REL}"
    exit "${SUITE_RC}"
else
    run_suite 2>&1 | sanitize_stream
    exit "${PIPESTATUS[0]}"
fi
