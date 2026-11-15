#!/usr/bin/env bash
# RelayIDE M1 acceptance suite: real headless execution through agent-relay (relay.sh)
# with deterministic stub-agent.sh test doubles and isolated temporary git repositories.
#
# Covers M1 acceptance table rows 1..25, 29, and 30 (rows 26, 27, 28 live outside this script).
# Never opens the desktop window and never invokes any real coding agent CLI.
#
# Usage: Scripts/acceptance/m1-run.sh [--quick] [--record]
#   --quick    run a 1-lane subset of rows 2..4 and exit 0 on pass
#   --record   write the full suite report to reports/m1-run.txt (leaves working tree untouched otherwise)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "${ROOT_DIR}"

QUICK=0
RECORD=0
for arg in "$@"; do
    case "${arg}" in
        --quick) QUICK=1 ;;
        --record) RECORD=1 ;;
        *)
            echo "error: unknown argument '${arg}' (usage: m1-run.sh [--quick] [--record])" >&2
            exit 2
            ;;
    esac
done

if [[ "${QUICK}" -eq 1 && "${RECORD}" -eq 1 ]]; then
    echo "error: --quick and --record cannot be used together" >&2
    exit 2
fi

# Resolve real home and relay.sh BEFORE replacing HOME or RELAY_CLI_HOME.
REAL_HOME="${HOME}"
if [[ -n "${RELAYIDE_RELAY_SH:-}" ]]; then
    CANDIDATE_RELAY_SH="${RELAYIDE_RELAY_SH}"
else
    CANDIDATE_RELAY_SH="${REAL_HOME}/.agents/skills/agent-relay/scripts/relay.sh"
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

SHA256_RELAY_SH_BEFORE="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
SHA256_RELAY_UTIL_BEFORE="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"

GIT_STATUS_BEFORE="$(git status --porcelain)"
if [[ -z "$(git status --porcelain -- . ':(exclude)reports')" ]]; then
    TREE_STATE="working tree clean outside reports/"
else
    TREE_STATE="working tree has uncommitted changes outside reports/"
fi

PREFS_DIR="${REAL_HOME}/Library/Preferences"
PREFS_RELAY_BEFORE="$(ls -1 "${PREFS_DIR}" 2>/dev/null | grep -i 'relayide' | sort || true)"

SWIFT_JOBS_ARGS=()
if [[ -n "${RELAY_SWIFT_JOBS:-}" ]]; then
    SWIFT_JOBS_ARGS=(-j "${RELAY_SWIFT_JOBS}")
fi

RAW_WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/relayide-m1-acc.XXXXXX")"
WORK_TMP="$(cd "${RAW_WORK_TMP}" && pwd -P)"

# Strictly match processes whose command line contains the target path (`ps -axo pid=,command=` + `grep -F`).
list_procs_for_dir() {
    local needle="$1"
    [[ -n "${needle}" ]] || return 0
    ps -axo pid=,command= | grep -F -- "${needle}" | grep -v -F -- "grep -F -- ${needle}" | awk -v self="$$" '$1 != self { print }' || true
}

kill_procs_for_dir() {
    local needle="$1"
    [[ -n "${needle}" ]] || return 0
    local lines pids
    lines="$(list_procs_for_dir "${needle}")"
    if [[ -n "${lines}" ]]; then
        pids="$(printf '%s\n' "${lines}" | awk '{print $1}')"
        if [[ -n "${pids}" ]]; then
            # shellcheck disable=SC2086
            kill -TERM ${pids} 2>/dev/null || true
            /usr/bin/perl -e 'select(undef, undef, undef, 0.15)' </dev/null
            lines="$(list_procs_for_dir "${needle}")"
            pids="$(printf '%s\n' "${lines}" | awk '{print $1}')"
            if [[ -n "${pids}" ]]; then
                # shellcheck disable=SC2086
                kill -KILL ${pids} 2>/dev/null || true
            fi
        fi
    fi
}

cleanup_work_tmp() {
    if [[ -n "${WORK_TMP:-}" ]]; then
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
    local needle="$1"
    local max_sec="${2:-20}"
    local deadline_ticks=$(( max_sec * 20 ))
    local tick=0
    while (( tick <= deadline_ticks )); do
        if [[ -z "$(list_procs_for_dir "${needle}")" ]]; then
            return 0
        fi
        /usr/bin/perl -e 'select(undef, undef, undef, 0.05)' </dev/null
        tick=$(( tick + 1 ))
    done
    echo "leftover processes matching '${needle}' after ${max_sec}s:" >&2
    list_procs_for_dir "${needle}" >&2 || true
    return 1
}

wait_for_trace_start() {
    local trace_file="$1"
    local watched_pid="${2:-}"
    local max_sec="${3:-60}"
    local deadline_ticks=$(( max_sec * 25 ))
    local tick=0
    while (( tick <= deadline_ticks )); do
        if [[ -f "${trace_file}" ]] && grep -q '^start ' "${trace_file}" 2>/dev/null; then
            return 0
        fi
        if [[ -n "${watched_pid}" ]] && ! kill -0 "${watched_pid}" 2>/dev/null; then
            if [[ -f "${trace_file}" ]] && grep -q '^start ' "${trace_file}" 2>/dev/null; then
                return 0
            fi
            echo "watched PID ${watched_pid} exited before trace start appeared at ${trace_file}" >&2
            return 1
        fi
        /usr/bin/perl -e 'select(undef, undef, undef, 0.04)' </dev/null
        tick=$(( tick + 1 ))
    done
    echo "timed out after ${max_sec}s waiting for '^start ' in ${trace_file}" >&2
    return 1
}

WATCHDOG_PID=""
start_pid_watchdog() {
    local target_pid="$1"
    local timeout_sec="${2:-120}"
    ( exec /usr/bin/perl -e '
        my ($pid, $sec) = @ARGV;
        select(undef, undef, undef, $sec + 0);
        if (kill(0, $pid)) {
            print STDERR "\n[m1-run watchdog] PID $pid exceeded ${sec}s timeout; killing\n";
            kill("TERM", $pid);
            select(undef, undef, undef, 2.0);
            kill("KILL", $pid);
        }
    ' "${target_pid}" "${timeout_sec}" </dev/null ) &
    WATCHDOG_PID=$!
}

stop_pid_watchdog() {
    local wpid="${1:-}"
    if [[ -n "${wpid}" ]]; then
        kill -KILL "${wpid}" 2>/dev/null || true
        wait "${wpid}" 2>/dev/null || true
    fi
}

# Set up isolated CLI home, stub copy, and 4 decoy CLIs inside WORK_TMP.
RELAY_CLI="${ROOT_DIR}/Scripts/acceptance/relay-cli.sh"
export RELAY_CLI_HOME="${WORK_TMP}/cli-home"
mkdir -p "${RELAY_CLI_HOME}" "${WORK_TMP}/empty-git-home"

STUB_DIR="${WORK_TMP}/stub-bin"
DECOY_DIR="${WORK_TMP}/decoys"
DECOY_MARKER="${WORK_TMP}/decoy-cli-invoked.marker"
mkdir -p "${STUB_DIR}" "${DECOY_DIR}"

cp "${ROOT_DIR}/Tests/Support/stub-agent.sh" "${STUB_DIR}/stub-agent.sh"
chmod +x "${STUB_DIR}/stub-agent.sh"
STUB_BIN="${STUB_DIR}/stub-agent.sh"

for agent_name in claude codex agy vibe; do
    cat > "${DECOY_DIR}/${agent_name}" <<EOF
#!/usr/bin/env bash
printf 'decoy %s invoked: pid=%s args=%s\n' "${agent_name}" "\$\$" "\$*" >> "${DECOY_MARKER}"
exit 99
EOF
    chmod +x "${DECOY_DIR}/${agent_name}"
done

export RELAY_CLAUDE_BIN="${STUB_BIN}"
export RELAY_CODEX_BIN="${STUB_BIN}"
export RELAY_AGY_BIN="${STUB_BIN}"
export RELAY_VIBE_BIN="${STUB_BIN}"

SAFE_PATH="${DECOY_DIR}:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="${SAFE_PATH}"
export RELAY_CLI_CHILD_PATH="${SAFE_PATH}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

if [[ -n "${RELAY_CLI_BIN:-}" ]]; then
    export RELAY_CLI_BIN
fi

assert_stub_and_decoys_armed() {
    [[ -n "${WORK_TMP:-}" && -d "${WORK_TMP}" ]] || { echo "FATAL: WORK_TMP missing" >&2; exit 125; }
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
    for t in claude codex agy vibe; do
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
    /usr/bin/python3 - "${out_file}" "${err_file}" "${RELAY_CLI}" "${#env_overrides[@]}" \
        ${env_overrides[@]+"${env_overrides[@]}"} "$@" <<'PY'
import os
import signal
import subprocess
import sys

out_path = sys.argv[1]
err_path = sys.argv[2]
relay_cli = sys.argv[3]
num_env = int(sys.argv[4])
env_items = sys.argv[5 : 5 + num_env]
cli_args = sys.argv[5 + num_env :]

env = dict(os.environ)
for k in ("RELAY_WORKER", "AGY_CODER_WORKER", "CLAUDECODE", "RELAY_BUDGET_USD"):
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
        rc = proc.wait(timeout=120.0)
        sys.exit(rc)
    except subprocess.TimeoutExpired:
        err_fh.write(b"\n[m1-run watchdog] Product command exceeded 120s timeout; killing process group\n")
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
}

# Confirms via `ps` (and `<project>/run.lock` when present) that `pid` is the tested product binary itself.
verify_pid_is_tested_binary() {
    local pid="$1"
    local proj_dir="${2:-}"
    kill -0 "${pid}" 2>/dev/null || {
        echo "PID ${pid} is not alive" >&2
        return 1
    }
    local cmd_line
    cmd_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    if [[ -z "${cmd_line}" ]]; then
        echo "ps returned empty command for PID ${pid}" >&2
        return 1
    fi
    if [[ "${cmd_line}" == *"relay-cli.sh"* || "${cmd_line}" == *"perl -e"* ]]; then
        echo "PID ${pid} is still a wrapper (${cmd_line}), not the tested binary" >&2
        return 1
    fi
    if [[ -n "${RELAY_CLI_BIN:-}" ]]; then
        [[ "${cmd_line}" == *"${RELAY_CLI_BIN}"* ]] || {
            echo "PID ${pid} command '${cmd_line}' does not match RELAY_CLI_BIN '${RELAY_CLI_BIN}'" >&2
            return 1
        }
    else
        [[ "${cmd_line}" == *"/RelayIDE "* ]] || {
            echo "PID ${pid} command '${cmd_line}' is not the RelayIDE binary" >&2
            return 1
        }
    fi
    if [[ -n "${proj_dir}" && -s "${proj_dir}/run.lock" ]]; then
        /usr/bin/python3 - "${proj_dir}/run.lock" "${pid}" <<'PY'
import json, sys
info = json.load(open(sys.argv[1], encoding="utf-8"))
assert int(info["pid"]) == int(sys.argv[2]), (info, sys.argv[2])
PY
    fi
}

read_lock_run_id() {
    local proj_dir="$1"
    /usr/bin/python3 - "${proj_dir}/run.lock" <<'PY'
import json, sys, time
path = sys.argv[1]
for _ in range(100):
    try:
        raw = open(path, encoding="utf-8").read().strip()
        if raw:
            d = json.loads(raw)
            if d.get("runID"):
                print(d["runID"])
                sys.exit(0)
    except Exception:
        pass
    time.sleep(0.02)
sys.exit(1)
PY
}

FAKE_AUTHOR_NAME="Relay Acceptance Bot"
FAKE_AUTHOR_EMAIL="acceptance-bot@relayide.invalid"
FAKE_AUTHOR_FULL="${FAKE_AUTHOR_NAME} <${FAKE_AUTHOR_EMAIL}>"

init_temp_git_repo() {
    local repo_dir="$1"
    local configure_identity="${2:-1}"
    mkdir -p "${repo_dir}"
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" init -q -b main
    if [[ "${configure_identity}" -eq 1 ]]; then
        HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" config user.name "${FAKE_AUTHOR_NAME}"
        HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" config user.email "${FAKE_AUTHOR_EMAIL}"
        printf 'baseline\n' > "${repo_dir}/README.txt"
        HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" add README.txt
        HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" -c commit.gpgsign=false commit -q -m "Initial baseline"
    else
        printf 'baseline\n' > "${repo_dir}/README.txt"
        HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" add README.txt
        HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" \
            -c user.name="Bootstrap Seed" -c user.email="seed@relayide.invalid" -c commit.gpgsign=false \
            commit -q -m "Initial baseline"
    fi
}

init_temp_project() {
    local proj_dir="$1"
    local out_f="${WORK_TMP}/init-proj.out"
    local err_f="${WORK_TMP}/init-proj.err"
    invoke_product "${out_f}" "${err_f}" -- init --project "${proj_dir}" --lang zh
}

FAIL_COUNT=0
FAIL_LOG="${WORK_TMP}/failed-rows.log"
: > "${FAIL_LOG}"

record_pass() {
    local row="$1"
    local msg="$2"
    echo "[PASS] Row ${row}: ${msg}"
}

record_fail() {
    local row="$1"
    local msg="$2"
    echo "[FAIL] Row ${row}: ${msg}"
    printf 'Row %s: %s\n' "${row}" "${msg}" >> "${FAIL_LOG}"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}

run_row() {
    local row="$1"
    local desc="$2"
    local fn="$3"
    echo ""
    echo "--- Row ${row}: ${desc} ---"
    set +e
    ( set -euo pipefail; "${fn}" )
    local rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
        record_pass "${row}" "${desc}"
    else
        record_fail "${row}" "${desc} (exit=${rc})"
    fi
}

run_quick_mode() {
    echo "================================================================"
    echo "RelayIDE M1 Acceptance Quick Check (--quick, 1 lane subset of rows 2..4)"
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Commit:    $(git rev-parse --short HEAD) (branch: $(git rev-parse --abbrev-ref HEAD); ${TREE_STATE})"
    echo "relay.sh sha256 (start):      ${SHA256_RELAY_SH_BEFORE}"
    echo "relay_util.py sha256 (start): ${SHA256_RELAY_UTIL_BEFORE}"
    echo "================================================================"

    if [[ -z "${RELAY_CLI_BIN:-}" ]]; then
        swift build ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} >/dev/null
    else
        [[ -x "${RELAY_CLI_BIN}" ]] || { echo "error: RELAY_CLI_BIN is not executable" >&2; return 1; }
    fi

    local qdir="${WORK_TMP}/quick"
    local qrepo="${qdir}/repo"
    local qproj="${qdir}/Quick.relayproj"
    local qtraces="${qdir}/traces"
    mkdir -p "${qdir}/prompts" "${qtraces}"

    init_temp_git_repo "${qrepo}" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${qrepo}" rev-parse main)"
    init_temp_project "${qproj}"

    cat > "${qdir}/prompts/q.md" <<'EOF'
STUB WRITE src/quick.txt quick-single-lane
STUB COST 0.0123
STUB MESSAGE Quick lane completed cleanly
EOF

    cat > "${qdir}/plan.json" <<EOF
{
  "repo": "${qrepo}",
  "base": "main",
  "lanes": [
    {"id": "q", "agent": "claude", "prompt": "prompts/q.md", "after": []}
  ]
}
EOF

    set +e
    invoke_product "${qdir}/run.stdout" "${qdir}/run.stderr" "STUB_TRACE_DIR=${qtraces}" -- \
        run "${qdir}/plan.json" --project "${qproj}" --relay-sh "${REAL_RELAY_SH}" --lang zh
    local run_rc=$?
    set -e

    # Row 2 subset (single lane): exit 0, status succeeded, trace recorded
    if [[ "${run_rc}" -eq 0 ]] && /usr/bin/python3 - "${qdir}/run.stdout" "${qtraces}/q.trace" <<'PY'
import json, sys
run_json = json.load(open(sys.argv[1], encoding="utf-8"))
assert run_json["status"] == "succeeded", run_json
assert len(run_json["lanes"]) == 1, run_json["lanes"]
lane = run_json["lanes"][0]
assert lane["laneID"] == "q" and lane["status"] == "succeeded" and lane["exitCode"] == 0, lane
lines = [l.split() for l in open(sys.argv[2], encoding="utf-8").read().splitlines() if l.strip()]
starts = [float(x[1]) for x in lines if x[0] == "start"]
ends = [float(x[1]) for x in lines if x[0] == "end"]
assert len(starts) == 1 and len(ends) == 1 and starts[0] <= ends[0], lines
PY
    then
        record_pass "2" "(--quick, 1 lane) run exited 0, lane q succeeded (exit 0), trace start/end recorded"
    else
        cat "${qdir}/run.stderr" >&2 || true
        record_fail "2" "(--quick, 1 lane) run exited ${run_rc} or JSON/trace assertion failed"
    fi

    local run_id=""
    run_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runID"])' "${qdir}/run.stdout" 2>/dev/null || true)"

    # Row 3 subset (single lane): main repo clean, main OID unchanged, only relay/<runID>/q added
    local status_porcelain head_after branches_sorted expected_branches
    status_porcelain="$(HOME="${WORK_TMP}/empty-git-home" git -C "${qrepo}" status --porcelain)"
    head_after="$(HOME="${WORK_TMP}/empty-git-home" git -C "${qrepo}" rev-parse main)"
    branches_sorted="$(HOME="${WORK_TMP}/empty-git-home" git -C "${qrepo}" for-each-ref --format='%(refname:short)' refs/heads/ | sort | paste -sd ',' -)"
    expected_branches="$(printf 'main\nrelay/%s/q\n' "${run_id}" | sort | paste -sd ',' -)"
    if [[ -n "${run_id}" && -z "${status_porcelain}" && "${head_after}" == "${base_oid}" && "${branches_sorted}" == "${expected_branches}" ]]; then
        record_pass "3" "(--quick, 1 lane) main working tree clean, main OID unchanged, only branch relay/${run_id}/q added"
    else
        record_fail "3" "(--quick, 1 lane) status='${status_porcelain}', head=${head_after} vs ${base_oid}, branches='${branches_sorted}'"
    fi

    # Row 4 subset (single lane): +1 commit over base, diff is src/quick.txt, no .relay/, fake author
    local qbranch="relay/${run_id}/q"
    local ahead_cnt diff_files relay_tracked author_str
    ahead_cnt="$(HOME="${WORK_TMP}/empty-git-home" git -C "${qrepo}" rev-list --count "${base_oid}..${qbranch}" 2>/dev/null || echo bad)"
    diff_files="$(HOME="${WORK_TMP}/empty-git-home" git -C "${qrepo}" diff --name-only "${base_oid}..${qbranch}" 2>/dev/null || echo bad)"
    relay_tracked="$(HOME="${WORK_TMP}/empty-git-home" git -C "${qrepo}" ls-tree -r --name-only "${qbranch}" 2>/dev/null | grep -E '^\.relay($|/)' || true)"
    author_str="$(HOME="${WORK_TMP}/empty-git-home" git -C "${qrepo}" log -1 --format='%an <%ae>' "${qbranch}" 2>/dev/null || echo bad)"
    if [[ "${ahead_cnt}" == "1" && "${diff_files}" == "src/quick.txt" && -z "${relay_tracked}" && "${author_str}" == "${FAKE_AUTHOR_FULL}" ]]; then
        record_pass "4" "(--quick, 1 lane) branch +1 commit over base, diff is src/quick.txt, no .relay/ tracked, author matches repo config"
    else
        record_fail "4" "(--quick, 1 lane) ahead=${ahead_cnt}, diff='${diff_files}', relay_tracked='${relay_tracked}', author='${author_str}'"
    fi

    if [[ -e "${DECOY_MARKER}" ]]; then
        record_fail "quick-decoy" "decoy CLI was invoked during --quick"
    fi

    local leftover_quick fail_log_nonempty=0
    [[ -s "${FAIL_LOG}" ]] && fail_log_nonempty=1
    leftover_quick="$(list_procs_for_dir "${WORK_TMP}")"
    rm -rf "${WORK_TMP}"

    local sha_sh_after sha_util_after prefs_after
    sha_sh_after="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
    sha_util_after="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"
    prefs_after="$(ls -1 "${PREFS_DIR}" 2>/dev/null | grep -i 'relayide' | sort || true)"

    echo "relay.sh sha256 (end):        ${sha_sh_after}"
    echo "relay_util.py sha256 (end):   ${sha_util_after}"

    if [[ -n "${leftover_quick}" || -e "${WORK_TMP}" || "${sha_sh_after}" != "${SHA256_RELAY_SH_BEFORE}" || "${sha_util_after}" != "${SHA256_RELAY_UTIL_BEFORE}" || "${prefs_after}" != "${PREFS_RELAY_BEFORE}" ]]; then
        echo "[FAIL] Row quick-hygiene: post-run cleanup, preferences, or relay.sh sha256 check failed"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi

    [[ "${fail_log_nonempty}" -eq 0 && "${FAIL_COUNT}" -eq 0 ]]
}

# ------------------------------------------------------------------
# Scenario 1: Rows 1, 2, 3, 4 (leaves artifacts in ${WORK_TMP}/s1 for Rows 22 & 23)
# ------------------------------------------------------------------
run_scenario_01_rows_1_to_4() {
    local s1="${WORK_TMP}/s1"
    local repo="${s1}/repo"
    local proj="${s1}/Proj.relayproj"
    local traces="${s1}/traces"
    local barrier="${s1}/release.barrier"
    mkdir -p "${s1}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"
    printf '%s\n' "${base_oid}" > "${s1}/base_oid.txt"
    init_temp_project "${proj}"

    cat > "${s1}/prompts/a.md" <<EOF
STUB WRITE src/from_a.txt alpha-payload
STUB COST 0.0123
STUB MESSAGE Final message from lane a
STUB WAIT ${barrier} 90
EOF
    cat > "${s1}/prompts/b.md" <<EOF
STUB WRITE src/from_b.txt beta-payload
STUB COST 0.0234
STUB MESSAGE Final message from lane b
STUB WAIT ${barrier} 90
EOF
    cat > "${s1}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": []}
  ]
}
EOF

    echo ""
    echo "--- Row 1: Two independent lanes a & b blocked on barrier: worktree list + live status --run ---"
    assert_stub_and_decoys_armed
    ( exec /usr/bin/perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
        /usr/bin/env -u RELAY_WORKER -u AGY_CODER_WORKER -u CLAUDECODE -u RELAY_BUDGET_USD \
        "STUB_TRACE_DIR=${traces}" \
        "${RELAY_CLI}" run "${s1}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh \
        >"${s1}/run.stdout" 2>"${s1}/run.stderr" ) &
    local bg_pid=$!
    start_pid_watchdog "${bg_pid}" 120

    local row1_ok=1
    if ! wait_for_trace_start "${traces}/a.trace" "${bg_pid}" 60 || ! wait_for_trace_start "${traces}/b.trace" "${bg_pid}" 60; then
        row1_ok=0
    fi

    local run_id=""
    if [[ "${row1_ok}" -eq 1 ]]; then
        if ! verify_pid_is_tested_binary "${bg_pid}" "${proj}"; then
            row1_ok=0
        fi
        run_id="$(read_lock_run_id "${proj}" || true)"
        if [[ -z "${run_id}" ]]; then
            row1_ok=0
        else
            printf '%s\n' "${run_id}" > "${s1}/run_id.txt"
        fi
    fi

    if [[ "${row1_ok}" -eq 1 ]]; then
        HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" worktree list --porcelain > "${s1}/wt-live.txt"
        set +e
        invoke_product "${s1}/status-live.stdout" "${s1}/status-live.stderr" -- \
            status --project "${proj}" --run "${run_id}" --lang zh
        local st_rc=$?
        set -e
        if [[ "${st_rc}" -ne 0 ]] || grep -qi 'SQLITE_BUSY' "${s1}/status-live.stderr"; then
            row1_ok=0
        elif ! /usr/bin/python3 - "${s1}/wt-live.txt" "${s1}/status-live.stdout" "${repo}" "${proj}" "${run_id}" <<'PY'
import json, os, sys

wt_text = open(sys.argv[1], encoding="utf-8").read()
st = json.load(open(sys.argv[2], encoding="utf-8"))
repo_dir = os.path.realpath(sys.argv[3])
proj_dir = os.path.realpath(sys.argv[4])
run_id = sys.argv[5]

wt_paths = [os.path.realpath(line[len("worktree "):].strip()) for line in wt_text.splitlines() if line.startswith("worktree ")]
assert len(wt_paths) == 3, f"expected main + 2 worktrees, got {wt_paths}"
assert wt_paths[0] == repo_dir, wt_paths
lane_wts = wt_paths[1:]
assert len(set(lane_wts)) == 2, lane_wts
expected_root = os.path.join(proj_dir, "runs", run_id, "worktrees") + os.sep
for p in lane_wts:
    assert p.startswith(expected_root), (p, expected_root)

assert st["status"] == "running", st
lanes = {l["laneID"]: l for l in st["lanes"]}
assert set(lanes) == {"a", "b"}, lanes
for lid in ("a", "b"):
    l = lanes[lid]
    assert l["status"] == "running", l
    pid = l["pid"]
    assert isinstance(pid, int) and pid > 0, l
    os.kill(pid, 0)
PY
        then
            row1_ok=0
        fi
    fi

    if [[ "${row1_ok}" -eq 1 ]]; then
        record_pass "1" "main + 2 distinct worktrees under <project>/runs/${run_id}/worktrees/; live status --run returned running with alive PIDs"
    else
        record_fail "1" "live worktree or status --run check failed while blocked on barrier"
    fi

    # Release barrier for Row 2
    echo ""
    echo "--- Row 2: Release barrier -> run exits 0, both succeeded (exit 0), trace intervals overlap ---"
    : > "${barrier}"
    set +e
    wait "${bg_pid}"
    local run_rc=$?
    set -e
    stop_pid_watchdog "${WATCHDOG_PID}"

    if [[ "${run_rc}" -eq 0 ]] && /usr/bin/python3 - "${s1}/run.stdout" "${traces}/a.trace" "${traces}/b.trace" <<'PY'
import json, sys

d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "succeeded", d
lanes = {l["laneID"]: l for l in d["lanes"]}
for lid in ("a", "b"):
    assert lanes[lid]["status"] == "succeeded" and lanes[lid]["exitCode"] == 0 and lanes[lid]["signal"] is None, lanes[lid]

def span(path):
    rows = [r.split() for r in open(path, encoding="utf-8").read().splitlines() if r.strip()]
    s = [float(r[1]) for r in rows if r[0] == "start"][0]
    e = [float(r[1]) for r in rows if r[0] == "end"][-1]
    return s, e

sa, ea = span(sys.argv[2])
sb, eb = span(sys.argv[3])
assert sa < eb and sb < ea, f"non-overlapping intervals: a=({sa}, {ea}), b=({sb}, {eb})"
PY
    then
        record_pass "2" "run exited 0, lanes a & b succeeded (exit 0), and trace intervals overlapped"
    else
        cat "${s1}/run.stderr" >&2 || true
        record_fail "2" "after barrier release, run exited ${run_rc} or trace overlap failed"
    fi

    if [[ -z "${run_id}" && -s "${s1}/run.stdout" ]]; then
        run_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runID"])' "${s1}/run.stdout" 2>/dev/null || true)"
        [[ -n "${run_id}" ]] && printf '%s\n' "${run_id}" > "${s1}/run_id.txt"
    fi

    echo ""
    echo "--- Row 3: Main repository clean, main OID unchanged, only relay/<runID>/a and relay/<runID>/b added ---"
    local st_porcelain main_after actual_branches expected_branches
    st_porcelain="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" status --porcelain)"
    main_after="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"
    actual_branches="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" for-each-ref --format='%(refname:short)' refs/heads/ | sort | paste -sd ',' -)"
    expected_branches="$(printf 'main\nrelay/%s/a\nrelay/%s/b\n' "${run_id}" "${run_id}" | sort | paste -sd ',' -)"
    if [[ -n "${run_id}" && -z "${st_porcelain}" && "${main_after}" == "${base_oid}" && "${actual_branches}" == "${expected_branches}" ]]; then
        record_pass "3" "main git status empty, main OID unchanged, only branches relay/${run_id}/a and relay/${run_id}/b added"
    else
        record_fail "3" "status='${st_porcelain}', main=${main_after} vs ${base_oid}, branches='${actual_branches}'"
    fi

    echo ""
    echo "--- Row 4: Each lane branch +1 commit over base, exact file diff, no .relay/, configured author + dependent chain ---"
    local row4_ok=1
    for pair in "a:src/from_a.txt" "b:src/from_b.txt"; do
        local lid="${pair%%:*}"
        local exp_file="${pair#*:}"
        local br="relay/${run_id}/${lid}"
        local cnt diff_out relay_files author_out
        cnt="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-list --count "${base_oid}..${br}" 2>/dev/null || echo bad)"
        diff_out="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" diff --name-only "${base_oid}..${br}" 2>/dev/null || echo bad)"
        relay_files="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" ls-tree -r --name-only "${br}" 2>/dev/null | grep -E '^\.relay($|/)' || true)"
        author_out="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" log -1 --format='%an <%ae>' "${br}" 2>/dev/null || echo bad)"
        if [[ "${cnt}" != "1" || "${diff_out}" != "${exp_file}" || -n "${relay_files}" || "${author_out}" != "${FAKE_AUTHOR_FULL}" ]]; then
            echo "lane ${lid} mismatch: cnt=${cnt}, diff='${diff_out}', relay='${relay_files}', author='${author_out}'" >&2
            row4_ok=0
        fi
    done

    # Also verify dependent lane (`c` after `a`) starts from `a`'s committed branch head.
    local dep_dir="${WORK_TMP}/s1-dep"
    mkdir -p "${dep_dir}/prompts" "${dep_dir}/traces"
    init_temp_git_repo "${dep_dir}/repo" 1
    local dep_base
    dep_base="$(HOME="${WORK_TMP}/empty-git-home" git -C "${dep_dir}/repo" rev-parse main)"
    init_temp_project "${dep_dir}/Dep.relayproj"
    printf 'STUB WRITE src/a.txt from-a\n' > "${dep_dir}/prompts/a.md"
    printf 'STUB WRITE src/c.txt from-c\n' > "${dep_dir}/prompts/c.md"
    cat > "${dep_dir}/plan.json" <<EOF
{
  "repo": "${dep_dir}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "c", "agent": "agy",    "prompt": "prompts/c.md", "after": ["a"]}
  ]
}
EOF
    set +e
    invoke_product "${dep_dir}/run.stdout" "${dep_dir}/run.stderr" "STUB_TRACE_DIR=${dep_dir}/traces" -- \
        run "${dep_dir}/plan.json" --project "${dep_dir}/Dep.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh
    local dep_rc=$?
    set -e
    if [[ "${dep_rc}" -ne 0 ]]; then
        row4_ok=0
    else
        local dep_run_id a_head c_parent c_diff
        dep_run_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runID"])' "${dep_dir}/run.stdout")"
        a_head="$(HOME="${WORK_TMP}/empty-git-home" git -C "${dep_dir}/repo" rev-parse "relay/${dep_run_id}/a")"
        c_parent="$(HOME="${WORK_TMP}/empty-git-home" git -C "${dep_dir}/repo" rev-parse "relay/${dep_run_id}/c^")"
        c_diff="$(HOME="${WORK_TMP}/empty-git-home" git -C "${dep_dir}/repo" diff --name-only "${a_head}..relay/${dep_run_id}/c")"
        if [[ "${a_head}" == "${dep_base}" || "${c_parent}" != "${a_head}" || "${c_diff}" != "src/c.txt" ]]; then
            echo "dependent chain mismatch: a_head=${a_head}, c_parent=${c_parent}, c_diff='${c_diff}'" >&2
            row4_ok=0
        fi
    fi

    if [[ "${row4_ok}" -eq 1 ]]; then
        record_pass "4" "each lane branch has +1 commit with exact file, zero .relay/ paths, repo-configured author, and dependent lane starts from predecessor head"
    else
        record_fail "4" "branch commit count, file diff, .relay exclusion, author, or dependent start check failed"
    fi
}

# ------------------------------------------------------------------
# Rows 5..11: Spend/tokens, 4 vendors, failure/skip, partial, 125/2 mapping, timeout, secret refusal
# ------------------------------------------------------------------
row_05_spend_and_tokens() {
    local d="${WORK_TMP}/r05"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj.relayproj"

    cat > "${d}/prompts/c1.md" <<'EOF'
STUB WRITE src/c1.txt claude-spend
STUB COST 0.0123
EOF
    cat > "${d}/prompts/a1.md" <<'EOF'
STUB WRITE src/a1.txt agy-tokens
STUB TOKENS 3456
EOF
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "c1", "agent": "claude", "prompt": "prompts/c1.md", "after": []},
    {"id": "a1", "agent": "agy",    "prompt": "prompts/a1.md", "after": []}
  ]
}
EOF

    invoke_product "${d}/run.stdout" "${d}/run.stderr" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh

    /usr/bin/python3 - "${d}/run.stdout" "${d}/run.stderr" "${REAL_RELAY_UTIL}" <<'PY'
import json, os, subprocess, sys

run_data = json.load(open(sys.argv[1], encoding="utf-8"))
stderr_text = open(sys.argv[2], encoding="utf-8").read()
relay_util = sys.argv[3]

assert run_data["status"] == "succeeded", run_data
lanes = {l["laneID"]: l for l in run_data["lanes"]}

c1 = lanes["c1"]
assert c1["status"] == "succeeded", c1
assert c1["costUSD"] is not None and abs(float(c1["costUSD"]) - 0.0123) < 1e-9, c1
assert c1["costSource"] == "usd", c1
c1_log = os.path.join(c1["worktreePath"], ".relay", "LOG.md")
spent_raw = subprocess.check_output(["/usr/bin/python3", "-I", relay_util, "spent", c1_log], text=True).strip()
assert abs(float(spent_raw) - float(c1["costUSD"])) < 1e-9, (spent_raw, c1["costUSD"])

a1 = lanes["a1"]
assert a1["status"] == "succeeded", a1
assert a1["costUSD"] is None, f"expected costUSD=None (not 0), got {a1['costUSD']!r}"
assert a1["tokens"] == 3456, a1
assert a1["costSource"] == "unpriced", a1
assert "未计价" in stderr_text, stderr_text
PY
}

row_06_four_vendors() {
    local d="${WORK_TMP}/r06"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj.relayproj"

    printf 'STUB WRITE src/claude.txt ok-claude\nSTUB COST 0.0111\n' > "${d}/prompts/claude.md"
    printf 'STUB WRITE src/codex.txt ok-codex\nSTUB TOKENS 2222\n' > "${d}/prompts/codex.md"
    printf 'STUB WRITE src/agy.txt ok-agy\nSTUB TOKENS 3333\n' > "${d}/prompts/agy.md"
    printf 'STUB WRITE src/vibe.txt ok-vibe\nSTUB COST 0.0444\n' > "${d}/prompts/vibe.md"

    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "l-claude", "agent": "claude", "prompt": "prompts/claude.md", "after": []},
    {"id": "l-codex",  "agent": "codex",  "prompt": "prompts/codex.md",  "after": []},
    {"id": "l-agy",    "agent": "agy",    "prompt": "prompts/agy.md",    "after": []},
    {"id": "l-vibe",   "agent": "vibe",   "prompt": "prompts/vibe.md",   "after": []}
  ]
}
EOF

    invoke_product "${d}/run.stdout" "${d}/run.stderr" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh

    /usr/bin/python3 - "${d}/run.stdout" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "succeeded", d
lanes = {l["laneID"]: l for l in d["lanes"]}
assert set(lanes) == {"l-claude", "l-codex", "l-agy", "l-vibe"}, lanes
for lid, l in lanes.items():
    assert l["status"] == "succeeded" and l["exitCode"] == 0 and l["commitOID"], (lid, l)
PY
}

row_07_failed_skips_dependent() {
    local d="${WORK_TMP}/r07"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
    init_temp_project "${d}/Proj.relayproj"

    cat > "${d}/prompts/a.md" <<'EOF'
STUB WRITE dirty_a.txt uncommitted-from-a
STUB EXIT 3
EOF
    printf 'STUB WRITE src/b.txt should-not-run\n' > "${d}/prompts/b.md"
    printf 'STUB WRITE src/c.txt independent-ok\n' > "${d}/prompts/c.md"

    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": ["a"]},
    {"id": "c", "agent": "vibe",   "prompt": "prompts/c.md", "after": []}
  ]
}
EOF

    set +e
    invoke_product "${d}/run.stdout" "${d}/run.stderr" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh
    local rc=$?
    set -e
    [[ "${rc}" -eq 1 ]] || { echo "expected exit 1, got ${rc}" >&2; return 1; }

    local run_id
    run_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runID"])' "${d}/run.stdout")"

    [[ ! -e "${d}/traces/b.trace" ]] || { echo "b.trace should not exist" >&2; return 1; }
    [[ ! -e "${d}/Proj.relayproj/runs/${run_id}/worktrees/b" ]] || { echo "b worktree should not exist" >&2; return 1; }
    if HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" show-ref --verify --quiet "refs/heads/relay/${run_id}/b"; then
        echo "branch relay/${run_id}/b should not exist" >&2
        return 1
    fi
    local a_ahead
    a_ahead="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-list --count "${base_oid}..relay/${run_id}/a")"
    [[ "${a_ahead}" == "0" ]] || { echo "expected 0 commits on a, got ${a_ahead}" >&2; return 1; }

    /usr/bin/python3 - "${d}/run.stdout" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
lanes = {l["laneID"]: l for l in d["lanes"]}

la = lanes["a"]
assert la["status"] == "failed" and la["exitCode"] == 3 and la["signal"] is None, la
assert la["commitOID"] is None, la
assert la["uncommittedFiles"] == ["dirty_a.txt"], la

lb = lanes["b"]
assert lb["status"] == "skipped" and lb["exitCode"] is None, lb
assert lb["worktreePath"] is None and lb["branch"] is None and lb["commitOID"] is None, lb
reason_b = lb["reason"] or ""
assert re.search(r"(^|[^a-z0-9])a([^a-z0-9]|$)", reason_b), f"reason for b does not name predecessor a: {reason_b!r}"

lc = lanes["c"]
assert lc["status"] == "succeeded" and lc["exitCode"] == 0 and lc["commitOID"], lc
PY
}

row_08_partial_commits_and_skips_dependent() {
    local d="${WORK_TMP}/r08"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
    init_temp_project "${d}/Proj.relayproj"

    cat > "${d}/prompts/a.md" <<'EOF'
STUB WRITE src/partial_a.txt half-finished
STUB STATUS partial
EOF
    printf 'STUB WRITE src/b.txt should-not-run\n' > "${d}/prompts/b.md"

    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "agy",    "prompt": "prompts/b.md", "after": ["a"]}
  ]
}
EOF

    set +e
    invoke_product "${d}/run.stdout" "${d}/run.stderr" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh
    local rc=$?
    set -e
    [[ "${rc}" -eq 1 ]] || { echo "expected exit 1, got ${rc}" >&2; return 1; }

    local run_id a_ahead a_diff
    run_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runID"])' "${d}/run.stdout")"
    a_ahead="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-list --count "${base_oid}..relay/${run_id}/a")"
    a_diff="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" diff --name-only "${base_oid}..relay/${run_id}/a")"
    [[ "${a_ahead}" == "1" && "${a_diff}" == "src/partial_a.txt" ]] || {
        echo "partial lane commit mismatch: ahead=${a_ahead}, diff='${a_diff}'" >&2
        return 1
    }
    [[ ! -e "${d}/traces/b.trace" && ! -e "${d}/Proj.relayproj/runs/${run_id}/worktrees/b" ]] || return 1
    if HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" show-ref --verify --quiet "refs/heads/relay/${run_id}/b"; then
        return 1
    fi

    /usr/bin/python3 - "${d}/run.stdout" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
lanes = {l["laneID"]: l for l in d["lanes"]}
assert lanes["a"]["status"] == "partial" and lanes["a"]["exitCode"] == 5 and lanes["a"]["commitOID"], lanes["a"]
assert lanes["b"]["status"] == "skipped" and lanes["b"]["worktreePath"] is None and lanes["b"]["branch"] is None, lanes["b"]
PY
}

row_09_lane_exit_125_and_2_never_leak_to_run_exit() {
    local d="${WORK_TMP}/r09"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj.relayproj"

    for code in 125 2; do
        printf 'STUB WRITE dirty_%s.txt fail-%s\nSTUB EXIT %s\n' "${code}" "${code}" "${code}" > "${d}/prompts/p${code}.md"
        cat > "${d}/plan-${code}.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "lane-${code}", "agent": "claude", "prompt": "prompts/p${code}.md", "after": []}
  ]
}
EOF
        set +e
        invoke_product "${d}/out-${code}.json" "${d}/err-${code}.txt" "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan-${code}.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh
        local rc=$?
        set -e
        [[ "${rc}" -eq 1 ]] || { echo "for stub exit ${code}, expected run exit 1 (not ${code}), got ${rc}" >&2; return 1; }

        /usr/bin/python3 - "${d}/out-${code}.json" "${code}" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
expected = int(sys.argv[2])
lane = d["lanes"][0]
assert lane["status"] == "failed" and lane["exitCode"] == expected and lane["commitOID"] is None, lane
PY
    done
}

row_10_timeout_124_and_no_leftover_processes() {
    local d="${WORK_TMP}/r10"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj.relayproj"

    cat > "${d}/prompts/slow.md" <<'EOF'
STUB WRITE dirty_timeout.txt timed-out
STUB SLEEP 60
EOF
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "slow", "agent": "claude", "prompt": "prompts/slow.md", "after": []}
  ]
}
EOF

    set +e
    invoke_product "${d}/run.stdout" "${d}/run.stderr" "RELAY_TIMEOUT=2" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh
    local rc=$?
    set -e
    [[ "${rc}" -eq 1 ]] || { echo "expected exit 1 on timeout, got ${rc}" >&2; return 1; }

    /usr/bin/python3 - "${d}/run.stdout" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
lane = d["lanes"][0]
assert lane["status"] == "timeout" and lane["exitCode"] == 124 and lane["commitOID"] is None, lane
assert lane["uncommittedFiles"] == ["dirty_timeout.txt"], lane
PY

    poll_until_no_procs "${WORK_TMP}" 30
}

row_11_secret_prompt_refused_without_leaking_value() {
    local d="${WORK_TMP}/r11"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj.relayproj"

    # Generate credential-shaped token dynamically at runtime; store only in temp files inside WORK_TMP.
    /usr/bin/python3 - "${d}/secret.val" "${d}/prompts/sec.md" <<'PY'
import secrets, sys
tok = ("s" + "k" + "-ant-api03-") + secrets.token_urlsafe(24)
open(sys.argv[1], "w", encoding="utf-8").write(tok)
open(sys.argv[2], "w", encoding="utf-8").write(
    f"Please inspect credential {tok} before proceeding.\nSTUB WRITE src/sec.txt should-not-run\n"
)
PY

    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "sec", "agent": "claude", "prompt": "prompts/sec.md", "after": []}
  ]
}
EOF

    set +e
    invoke_product "${d}/run.stdout" "${d}/run.stderr" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh
    local rc=$?
    set -e
    [[ "${rc}" -eq 1 ]] || { echo "expected exit 1 on secret refusal, got ${rc}" >&2; return 1; }
    [[ ! -e "${d}/traces/sec.trace" ]] || { echo "stub should not have run when relay.sh refused prompt" >&2; return 1; }

    /usr/bin/python3 - "${d}/secret.val" "${d}/run.stdout" "${d}/run.stderr" "${d}/Proj.relayproj" <<'PY'
import json, os, sys

secret_str = open(sys.argv[1], encoding="utf-8").read().strip()
assert len(secret_str) >= 35
secret_bytes = secret_str.encode("utf-8")

stdout_path, stderr_path, proj_dir = sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(stdout_path, encoding="utf-8"))
run_id = d["runID"]
lane = d["lanes"][0]

assert lane["status"] == "refused" and lane["exitCode"] == 2 and lane["commitOID"] is None, lane
reason = lane["reason"] or ""
assert "not sent" in reason.lower(), f"expected 'not sent' in reason, got {reason!r}"

wt_path = lane["worktreePath"]
assert wt_path and os.path.isdir(wt_path), lane
log_md = os.path.join(wt_path, ".relay", "LOG.md")
if os.path.exists(log_md):
    headers = [ln for ln in open(log_md, encoding="utf-8", errors="replace").read().splitlines() if ln.startswith("## ")]
    assert len(headers) == 0, f"expected no step in LOG.md, got {headers}"

pty_path = os.path.join(proj_dir, "runs", run_id, "lanes", "sec.pty")
sqlite_path = os.path.join(proj_dir, "workspace.sqlite")
assert os.path.isfile(pty_path), f"missing {pty_path}"
assert os.path.isfile(sqlite_path), f"missing {sqlite_path}"

files_to_scan = [
    stdout_path,
    stderr_path,
    pty_path,
    sqlite_path,
    sqlite_path + "-wal",
    sqlite_path + "-shm",
]
for fp in files_to_scan:
    if os.path.exists(fp):
        raw = open(fp, "rb").read()
        assert secret_bytes not in raw, f"secret leaked into {os.path.basename(fp)}"
PY
    rm -f "${d}/secret.val"
}

# ------------------------------------------------------------------
# Rows 12..17: Signal death (kill -9 relay.sh), SIGINT/SIGTERM cancellation, kill -9 RelayIDE crash recovery,
#              same-project lock contention, and two projects concurrently on one repository
# ------------------------------------------------------------------
row_12_kill9_lane_relay_sh_records_signal_9() {
    local d="${WORK_TMP}/r12"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj.relayproj"

    cat > "${d}/prompts/s.md" <<'EOF'
STUB WRITE dirty_s.txt killed-mid-flight
STUB SLEEP 30
EOF
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "s", "agent": "claude", "prompt": "prompts/s.md", "after": []}
  ]
}
EOF

    assert_stub_and_decoys_armed
    ( exec /usr/bin/perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
        /usr/bin/env -u RELAY_WORKER -u AGY_CODER_WORKER -u CLAUDECODE -u RELAY_BUDGET_USD \
        "STUB_TRACE_DIR=${d}/traces" \
        "${RELAY_CLI}" run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh \
        >"${d}/run.stdout" 2>"${d}/run.stderr" ) &
    local bg_pid=$!
    start_pid_watchdog "${bg_pid}" 120
    local wpid="${WATCHDOG_PID}"

    if ! wait_for_trace_start "${d}/traces/s.trace" "${bg_pid}" 60; then
        stop_pid_watchdog "${wpid}"
        kill_procs_for_dir "${d}"
        return 1
    fi
    verify_pid_is_tested_binary "${bg_pid}" "${d}/Proj.relayproj"

    local run_id wt_path relay_sh_pid
    run_id="$(read_lock_run_id "${d}/Proj.relayproj")"
    wt_path="${d}/Proj.relayproj/runs/${run_id}/worktrees/s"

    # Match the session/process-group leader (`pid == pgid`) for this lane's `relay.sh` (not its subshell).
    relay_sh_pid="$(ps -axo pid=,pgid=,command= | awk -v wt="${wt_path}" -v rsh="${REAL_RELAY_SH}" '
        $1 == $2 && index($0, rsh) > 0 && index($0, wt) > 0 { print $1; exit }
    ')"
    if [[ ! "${relay_sh_pid}" =~ ^[0-9]+$ ]]; then
        echo "failed to locate top-level relay.sh PID for worktree ${wt_path}" >&2
        stop_pid_watchdog "${wpid}"
        kill_procs_for_dir "${d}"
        return 1
    fi

    kill -9 "${relay_sh_pid}"
    set +e
    wait "${bg_pid}"
    local rc=$?
    set -e
    stop_pid_watchdog "${wpid}"

    # Clean up the orphaned independent-process-group stub sleep left behind by external `kill -9 relay.sh`.
    kill_procs_for_dir "${d}"
    poll_until_no_procs "${d}" 10

    [[ "${rc}" -eq 1 ]] || { echo "expected run exit 1 after kill -9 relay.sh, got ${rc}" >&2; return 1; }

    /usr/bin/python3 - "${d}/run.stdout" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "failed", d
lane = d["lanes"][0]
assert lane["status"] == "failed" and lane["status"] != "succeeded", lane
assert lane["signal"] == 9 and lane["exitCode"] is None and lane["commitOID"] is None, lane
PY
}

check_signal_cancellation() {
    local d="$1"
    local sig_name="$2"
    local expected_rc="$3"
    local gate="${d}/release.gate"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
    init_temp_project "${d}/Proj.relayproj"

    cat > "${d}/prompts/a.md" <<EOF
STUB WRITE dirty_a.txt wip-a
STUB WAIT ${gate} 90
EOF
    cat > "${d}/prompts/b.md" <<EOF
STUB WRITE dirty_b.txt wip-b
STUB WAIT ${gate} 90
EOF
    printf 'STUB WRITE src/c.txt should-not-start\n' > "${d}/prompts/c.md"

    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": []},
    {"id": "c", "agent": "agy",    "prompt": "prompts/c.md", "after": ["a"]}
  ]
}
EOF

    assert_stub_and_decoys_armed
    ( exec /usr/bin/perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
        /usr/bin/env -u RELAY_WORKER -u AGY_CODER_WORKER -u CLAUDECODE -u RELAY_BUDGET_USD \
        "STUB_TRACE_DIR=${d}/traces" \
        "${RELAY_CLI}" run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh \
        >"${d}/run.stdout" 2>"${d}/run.stderr" ) &
    local bg_pid=$!
    start_pid_watchdog "${bg_pid}" 120
    local wpid="${WATCHDOG_PID}"

    if ! wait_for_trace_start "${d}/traces/a.trace" "${bg_pid}" 60 || ! wait_for_trace_start "${d}/traces/b.trace" "${bg_pid}" 60; then
        stop_pid_watchdog "${wpid}"
        kill_procs_for_dir "${d}"
        return 1
    fi
    verify_pid_is_tested_binary "${bg_pid}" "${d}/Proj.relayproj"
    local run_id
    run_id="$(read_lock_run_id "${d}/Proj.relayproj")"

    kill "-${sig_name}" "${bg_pid}"
    set +e
    wait "${bg_pid}"
    local rc=$?
    set -e
    stop_pid_watchdog "${wpid}"

    [[ "${rc}" -eq "${expected_rc}" ]] || { echo "expected exit ${expected_rc} on SIG${sig_name}, got ${rc}" >&2; return 1; }
    poll_until_no_procs "${WORK_TMP}" 20

    local wt_a="${d}/Proj.relayproj/runs/${run_id}/worktrees/a"
    local wt_b="${d}/Proj.relayproj/runs/${run_id}/worktrees/b"
    local wt_c="${d}/Proj.relayproj/runs/${run_id}/worktrees/c"
    [[ -d "${wt_a}" && -d "${wt_b}" ]] || { echo "cancelled worktrees a/b missing" >&2; return 1; }
    [[ ! -e "${wt_c}" && ! -e "${d}/traces/c.trace" ]] || { echo "skipped lane c should have no worktree/trace" >&2; return 1; }
    if HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" show-ref --verify --quiet "refs/heads/relay/${run_id}/c"; then
        echo "skipped lane c should have no branch" >&2
        return 1
    fi

    local ahead_a ahead_b
    ahead_a="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-list --count "${base_oid}..relay/${run_id}/a")"
    ahead_b="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-list --count "${base_oid}..relay/${run_id}/b")"
    [[ "${ahead_a}" == "0" && "${ahead_b}" == "0" ]] || {
        echo "cancelled branches must have 0 new commits (a=${ahead_a}, b=${ahead_b})" >&2
        return 1
    }

    grep -q 'exit 130' "${wt_a}/.relay/LOG.md" || { echo "a LOG.md missing exit 130" >&2; return 1; }
    grep -q 'exit 130' "${wt_b}/.relay/LOG.md" || { echo "b LOG.md missing exit 130" >&2; return 1; }

    invoke_product "${d}/status.stdout" "${d}/status.stderr" -- \
        status --project "${d}/Proj.relayproj" --run "${run_id}" --lang zh
    cmp -s "${d}/run.stdout" "${d}/status.stdout" || { echo "run stdout != status --run stdout" >&2; return 1; }

    /usr/bin/python3 - "${d}/status.stdout" <<'PY'
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "cancelled", st
lanes = {l["laneID"]: l for l in st["lanes"]}
assert all(l["status"] != "running" for l in lanes.values()), lanes
assert lanes["a"]["status"] == "cancelled" and lanes["a"]["commitOID"] is None, lanes["a"]
assert lanes["b"]["status"] == "cancelled" and lanes["b"]["commitOID"] is None, lanes["b"]
assert lanes["c"]["status"] == "skipped" and lanes["c"]["worktreePath"] is None and lanes["c"]["branch"] is None, lanes["c"]
PY
}

row_13_sigint_cancels_lanes() {
    check_signal_cancellation "${WORK_TMP}/r13" "INT" 130
}

row_14_sigterm_cancels_lanes() {
    check_signal_cancellation "${WORK_TMP}/r14" "TERM" 143
}

row_15_kill9_relayide_reconciles_interrupted_and_recovers() {
    local d="${WORK_TMP}/r15"
    local gate="${d}/release.gate"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj.relayproj"

    cat > "${d}/prompts/a.md" <<EOF
STUB WRITE dirty_a.txt crash-a
STUB WAIT ${gate} 90
EOF
    cat > "${d}/prompts/b.md" <<EOF
STUB WRITE dirty_b.txt crash-b
STUB WAIT ${gate} 90
EOF
    printf 'STUB WRITE src/c.txt should-not-start\n' > "${d}/prompts/c.md"

    cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": []},
    {"id": "c", "agent": "agy",    "prompt": "prompts/c.md", "after": ["a"]}
  ]
}
EOF

    assert_stub_and_decoys_armed
    ( exec /usr/bin/perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
        /usr/bin/env -u RELAY_WORKER -u AGY_CODER_WORKER -u CLAUDECODE -u RELAY_BUDGET_USD \
        "STUB_TRACE_DIR=${d}/traces" \
        "${RELAY_CLI}" run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh \
        >"${d}/run.stdout" 2>"${d}/run.stderr" ) &
    local bg_pid=$!
    start_pid_watchdog "${bg_pid}" 120
    local wpid="${WATCHDOG_PID}"

    if ! wait_for_trace_start "${d}/traces/a.trace" "${bg_pid}" 60 || ! wait_for_trace_start "${d}/traces/b.trace" "${bg_pid}" 60; then
        stop_pid_watchdog "${wpid}"
        kill_procs_for_dir "${d}"
        return 1
    fi
    verify_pid_is_tested_binary "${bg_pid}" "${d}/Proj.relayproj"
    local run_id
    run_id="$(read_lock_run_id "${d}/Proj.relayproj")"

    kill -9 "${bg_pid}"
    set +e
    wait "${bg_pid}" 2>/dev/null
    set -e
    stop_pid_watchdog "${wpid}"

    poll_until_no_procs "${WORK_TMP}" 20

    invoke_product "${d}/status.stdout" "${d}/status.stderr" -- \
        status --project "${d}/Proj.relayproj" --run "${run_id}" --lang zh

    /usr/bin/python3 - "${d}/status.stdout" <<'PY'
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
assert st["status"] == "interrupted", st
lanes = {l["laneID"]: l for l in st["lanes"]}
assert all(l["status"] != "running" for l in lanes.values()), lanes
assert lanes["a"]["status"] == "interrupted", lanes["a"]
assert lanes["b"]["status"] == "interrupted", lanes["b"]
assert lanes["c"]["status"] == "skipped", lanes["c"]
PY

    # Subsequent small plan on the exact same project must succeed with exit 0.
    printf 'STUB WRITE src/recovered.txt after-crash\n' > "${d}/prompts/recover.md"
    cat > "${d}/small-plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "recover", "agent": "claude", "prompt": "prompts/recover.md", "after": []}
  ]
}
EOF
    invoke_product "${d}/small.stdout" "${d}/small.stderr" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/small-plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh

    /usr/bin/python3 - "${d}/small.stdout" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["status"] == "succeeded" and d["lanes"][0]["status"] == "succeeded", d
PY
}

row_16_concurrent_same_project_locked_125() {
    local d="${WORK_TMP}/r16"
    local gate="${d}/release.gate"
    mkdir -p "${d}/prompts" "${d}/traces"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj.relayproj"

    cat > "${d}/prompts/hold.md" <<EOF
STUB WRITE src/hold.txt first-run
STUB WAIT ${gate} 90
EOF
    printf 'STUB WRITE src/second.txt second-run\n' > "${d}/prompts/second.md"

    cat > "${d}/plan1.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "hold", "agent": "claude", "prompt": "prompts/hold.md", "after": []}
  ]
}
EOF
    cat > "${d}/plan2.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "second", "agent": "codex", "prompt": "prompts/second.md", "after": []}
  ]
}
EOF

    assert_stub_and_decoys_armed
    ( exec /usr/bin/perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
        /usr/bin/env -u RELAY_WORKER -u AGY_CODER_WORKER -u CLAUDECODE -u RELAY_BUDGET_USD \
        "STUB_TRACE_DIR=${d}/traces" \
        "${RELAY_CLI}" run "${d}/plan1.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh \
        >"${d}/run1.stdout" 2>"${d}/run1.stderr" ) &
    local bg_pid=$!
    start_pid_watchdog "${bg_pid}" 120
    local wpid="${WATCHDOG_PID}"

    if ! wait_for_trace_start "${d}/traces/hold.trace" "${bg_pid}" 60; then
        stop_pid_watchdog "${wpid}"
        kill_procs_for_dir "${d}"
        return 1
    fi
    verify_pid_is_tested_binary "${bg_pid}" "${d}/Proj.relayproj"
    local run1_id
    run1_id="$(read_lock_run_id "${d}/Proj.relayproj")"

    local wt_before br_before wt_after br_after
    wt_before="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" worktree list --porcelain)"
    br_before="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" for-each-ref --format='%(refname)' refs/heads/ | sort)"

    set +e
    invoke_product "${d}/run2.stdout" "${d}/run2.stderr" "STUB_TRACE_DIR=${d}/traces" -- \
        run "${d}/plan2.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh
    local rc2=$?
    set -e

    wt_after="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" worktree list --porcelain)"
    br_after="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" for-each-ref --format='%(refname)' refs/heads/ | sort)"

    : > "${gate}"
    set +e
    wait "${bg_pid}"
    local rc1=$?
    set -e
    stop_pid_watchdog "${wpid}"

    [[ "${rc2}" -eq 125 ]] || { echo "expected second run exit 125, got ${rc2}" >&2; return 1; }
    [[ ! -s "${d}/run2.stdout" ]] || { echo "expected empty stdout on second run" >&2; return 1; }
    grep -Fq -- "${run1_id}" "${d}/run2.stderr" || { echo "second run stderr missing first runID ${run1_id}" >&2; return 1; }
    [[ "${wt_after}" == "${wt_before}" && "${br_after}" == "${br_before}" && ! -e "${d}/traces/second.trace" ]] || {
        echo "second run created unexpected worktree, branch, or trace" >&2
        return 1
    }
    [[ "${rc1}" -eq 0 ]] || { echo "expected first run exit 0 after gate release, got ${rc1}" >&2; return 1; }
}

row_17_two_projects_same_repo_concurrent_0() {
    local d="${WORK_TMP}/r17"
    local gate="${d}/release.gate"
    mkdir -p "${d}/prompts" "${d}/traces1" "${d}/traces2"
    init_temp_git_repo "${d}/repo" 1
    init_temp_project "${d}/Proj1.relayproj"
    init_temp_project "${d}/Proj2.relayproj"

    cat > "${d}/prompts/p1.md" <<EOF
STUB WRITE src/p1.txt from-proj-1
STUB WAIT ${gate} 90
EOF
    cat > "${d}/prompts/p2.md" <<EOF
STUB WRITE src/p2.txt from-proj-2
STUB WAIT ${gate} 90
EOF

    cat > "${d}/plan1.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "lane", "agent": "claude", "prompt": "prompts/p1.md", "after": []}
  ]
}
EOF
    cat > "${d}/plan2.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "lane", "agent": "vibe", "prompt": "prompts/p2.md", "after": []}
  ]
}
EOF

    assert_stub_and_decoys_armed
    ( exec /usr/bin/perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
        /usr/bin/env -u RELAY_WORKER -u AGY_CODER_WORKER -u CLAUDECODE -u RELAY_BUDGET_USD \
        "STUB_TRACE_DIR=${d}/traces1" \
        "${RELAY_CLI}" run "${d}/plan1.json" --project "${d}/Proj1.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh \
        >"${d}/run1.stdout" 2>"${d}/run1.stderr" ) &
    local bg1=$!
    start_pid_watchdog "${bg1}" 120
    local wpid1="${WATCHDOG_PID}"

    ( exec /usr/bin/perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
        /usr/bin/env -u RELAY_WORKER -u AGY_CODER_WORKER -u CLAUDECODE -u RELAY_BUDGET_USD \
        "STUB_TRACE_DIR=${d}/traces2" \
        "${RELAY_CLI}" run "${d}/plan2.json" --project "${d}/Proj2.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh \
        >"${d}/run2.stdout" 2>"${d}/run2.stderr" ) &
    local bg2=$!
    start_pid_watchdog "${bg2}" 120
    local wpid2="${WATCHDOG_PID}"

    local ok_wait=1
    if ! wait_for_trace_start "${d}/traces1/lane.trace" "${bg1}" 60 || ! wait_for_trace_start "${d}/traces2/lane.trace" "${bg2}" 60; then
        ok_wait=0
    fi

    : > "${gate}"
    set +e
    wait "${bg1}"; local rc1=$?
    wait "${bg2}"; local rc2=$?
    set -e
    stop_pid_watchdog "${wpid1}"
    stop_pid_watchdog "${wpid2}"

    [[ "${ok_wait}" -eq 1 && "${rc1}" -eq 0 && "${rc2}" -eq 0 ]] || {
        echo "concurrent two-project run failed: ok_wait=${ok_wait}, rc1=${rc1}, rc2=${rc2}" >&2
        return 1
    }

    /usr/bin/python3 - "${d}/run1.stdout" "${d}/run2.stdout" "${d}/repo" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys
d1 = json.load(open(sys.argv[1], encoding="utf-8"))
d2 = json.load(open(sys.argv[2], encoding="utf-8"))
repo_dir, empty_home = sys.argv[3], sys.argv[4]

assert d1["status"] == "succeeded" and d2["status"] == "succeeded", (d1, d2)
b1 = d1["lanes"][0]["branch"]
b2 = d2["lanes"][0]["branch"]
assert b1 and b2 and b1 != b2, (b1, b2)

env = dict(os.environ, HOME=empty_home)
refs = subprocess.check_output(["git", "-C", repo_dir, "for-each-ref", "--format=%(refname:short)", "refs/heads/"], text=True, env=env).splitlines()
assert b1 in refs and b2 in refs, (b1, b2, refs)
PY
}

run_full_suite() {
    echo "================================================================"
    echo "RelayIDE M1 Acceptance Suite"
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Commit:    $(git rev-parse --short HEAD) (branch: $(git rev-parse --abbrev-ref HEAD); ${TREE_STATE})"
    echo "relay.sh sha256 (start):      ${SHA256_RELAY_SH_BEFORE}"
    echo "relay_util.py sha256 (start): ${SHA256_RELAY_UTIL_BEFORE}"
    echo "================================================================"

    if [[ -z "${RELAY_CLI_BIN:-}" ]]; then
        swift build ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} >/dev/null
    else
        [[ -x "${RELAY_CLI_BIN}" ]] || { echo "error: RELAY_CLI_BIN is not executable" >&2; return 1; }
    fi

    run_scenario_01_rows_1_to_4

    run_row "5"  "Claude USD spend matches relay_util.py spent; agy tokens-only has null costUSD and unpriced source" row_05_spend_and_tokens
    run_row "6"  "claude, codex, agy, and vibe lanes each reply in vendor format and succeed" row_06_four_vendors
    run_row "7"  "Lane a exit 3 -> failed (uncommitted tracked), dependent b skipped (no worktree/branch/trace), independent c succeeded, run exit 1" row_07_failed_skips_dependent
    run_row "8"  "Lane a STATUS: partial -> partial (exit 5, committed), dependent b skipped, run exit 1" row_08_partial_commits_and_skips_dependent
    run_row "9"  "Stub exit 125 and stub exit 2 -> lane failed (125 / 2), both runs exit 1 (not 125 or 2)" row_09_lane_exit_125_and_2_never_leak_to_run_exit
    run_row "10" "Stub sleeps 60s with RELAY_TIMEOUT=2 -> lane timeout (124), run exit 1, zero processes left within 30s" row_10_timeout_124_and_no_leftover_processes
    run_row "11" "Runtime-generated secret in prompt -> refused (exit 2, not sent), no trace/LOG.md step, value absent from stdout/stderr/DB/.pty" row_11_secret_prompt_refused_without_leaking_value
    run_row "12" "kill -9 lane's relay.sh process -> lane failed (signal 9, exitCode null, not succeeded), run exit 1" row_12_kill9_lane_relay_sh_records_signal_9
    run_row "13" "SIGINT to RelayIDE -> exit 130, a & b cancelled (worktrees kept, 0 commits, LOG.md exit 130), c skipped, 0 procs <=20s, status --run has no running" row_13_sigint_cancels_lanes
    run_row "14" "SIGTERM to RelayIDE -> exit 143, same invariants as Row 13" row_14_sigterm_cancels_lanes
    run_row "15" "kill -9 RelayIDE -> 0 procs <=20s, status --run shows interrupted (no running), subsequent small run on same project exits 0" row_15_kill9_relayide_reconciles_interrupted_and_recovers
    run_row "16" "Concurrent second run on locked project -> exit 125, empty stdout, stderr names first runID, no new worktree/branch, first run exits 0 after gate" row_16_concurrent_same_project_locked_125
    run_row "17" "Two separate projects concurrently running on the same repository -> both exit 0 with distinct branches" row_17_two_projects_same_repo_concurrent_0

    local sha_sh_after sha_util_after
    sha_sh_after="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
    sha_util_after="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"
    echo ""
    echo "relay.sh sha256 (end):        ${sha_sh_after}"
    echo "relay_util.py sha256 (end):   ${sha_util_after}"
    if [[ "${sha_sh_after}" != "${SHA256_RELAY_SH_BEFORE}" || "${sha_util_after}" != "${SHA256_RELAY_UTIL_BEFORE}" ]]; then
        record_fail "sha256" "relay.sh or relay_util.py sha256 changed during run"
    fi

    local fail_log_nonempty=0
    [[ -s "${FAIL_LOG}" ]] && fail_log_nonempty=1

    [[ "${fail_log_nonempty}" -eq 0 && "${FAIL_COUNT}" -eq 0 ]]
}

sanitize_stream() {
    /usr/bin/python3 -c '
import sys
repo_dir, home_dir = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    if repo_dir:
        line = line.replace(repo_dir, "<repo>")
    if home_dir and home_dir != "/":
        line = line.replace(home_dir, "<home>")
    sys.stdout.write(line)
    sys.stdout.flush()
' "${ROOT_DIR}" "${REAL_HOME}"
}

if [[ "${QUICK}" -eq 1 ]]; then
    run_quick_mode 2>&1 | sanitize_stream
else
    if [[ "${RECORD}" -eq 1 ]]; then
        mkdir -p "${ROOT_DIR}/reports"
        REPORT_REL="reports/m1-run.txt"
        run_full_suite 2>&1 | sanitize_stream | tee "${ROOT_DIR}/${REPORT_REL}"
        echo "Report written to <repo>/${REPORT_REL}"
    else
        run_full_suite 2>&1 | sanitize_stream
    fi
fi
