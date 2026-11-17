#!/usr/bin/env bash
# RelayIDE M2 acceptance suite: integration branch merge pipeline and PTY verify execution
# through real agent-relay (relay.sh) with deterministic stub-agent.sh and stub-verify.sh doubles.
#
# Never opens the desktop window and never invokes any real coding agent CLI.
#
# Usage: Scripts/acceptance/m2-merge.sh [--quick] [--record]
#   --quick    run Row 1 only and exit 0 on pass (Stage 5; Row 34 scheduled for Stage 6)
#   --record   write the suite report to reports/m2-merge.txt (leaves working tree untouched otherwise)
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
            echo "error: unknown argument '${arg}' (usage: m2-merge.sh [--quick] [--record])" >&2
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
ORIG_PATH="${PATH}"
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

TMP_BASE="${TMPDIR:-/tmp}"
RAW_WORK_TMP="$(mktemp -d "${TMP_BASE%/}/relayide-m2-acc.XXXXXX")"
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

# Match processes whose command line contains this run's unique temp directory token.
list_procs_for_dir() {
    local target="${1:-${WORK_TMP}}"
    [[ -n "${target}" ]] || return 0
    local needle
    needle="$(work_tmp_match_token "${target}")"
    [[ -n "${needle}" ]] || return 0
    ps -axo pid=,command= | grep -F -- "${needle}" | grep -v -F -- "grep -F -- ${needle}" | awk -v self="$$" '$1 != self { print }' || true
}

# Match detached git background maintenance processes (whose argv omits the repo path because git chdirs first)
# via `lsof -a -d cwd -c git` inside the temporary directory (`03-relayide.md` Hypothesis 1b).
list_git_cwd_procs_for_dir() {
    local target="${1:-${WORK_TMP}}"
    [[ -n "${target}" ]] || return 0
    local needle
    needle="$(work_tmp_match_token "${target}")"
    [[ -n "${needle}" ]] || return 0
    /usr/sbin/lsof -n -P -a -d cwd -c git -Fpcn 2>/dev/null | /usr/bin/python3 -c '
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
    echo "leftover processes or git background processes matching '${needle}' after ${max_sec}s:" >&2
    list_procs_for_dir "${target}" >&2 || true
    list_git_cwd_procs_for_dir "${target}" >&2 || true
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
            print STDERR "\n[m2-merge watchdog] PID $pid exceeded ${sec}s timeout; killing\n";
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

# Set up isolated CLI home, stub copies, and 4 decoy CLIs inside WORK_TMP.
RELAY_CLI="${ROOT_DIR}/Scripts/acceptance/relay-cli.sh"
export RELAY_CLI_HOME="${WORK_TMP}/cli-home"
mkdir -p "${RELAY_CLI_HOME}" "${WORK_TMP}/empty-git-home"

STUB_DIR="${WORK_TMP}/stub-bin"
DECOY_DIR="${WORK_TMP}/decoys"
DECOY_MARKER="${WORK_TMP}/decoy-cli-invoked.marker"
mkdir -p "${STUB_DIR}" "${DECOY_DIR}"

cp "${ROOT_DIR}/Tests/Support/stub-agent.sh" "${STUB_DIR}/stub-agent.sh"
cp "${ROOT_DIR}/Tests/Support/stub-verify.sh" "${STUB_DIR}/stub-verify.sh"
chmod +x "${STUB_DIR}/stub-agent.sh" "${STUB_DIR}/stub-verify.sh"
STUB_BIN="${STUB_DIR}/stub-agent.sh"
STUB_VERIFY_BIN="${STUB_DIR}/stub-verify.sh"

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
    [[ -n "${STUB_VERIFY_BIN:-}" && -x "${STUB_VERIFY_BIN}" && "${STUB_VERIFY_BIN}" == "${WORK_TMP}/"* ]] || {
        echo "FATAL: STUB_VERIFY_BIN invalid" >&2
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
        err_fh.write(b"\n[m2-merge watchdog] Product command exceeded 120s timeout; killing process group\n")
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
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" config core.logAllRefUpdates true
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

# ------------------------------------------------------------------
# `snapshot_repo_state` & `assert_base_untouched` (`03-relayide.md` §12.3 & Row 29)
# Compares before vs after every `run` (including exit 2 and exit 125):
#   1. `base` commit OID
#   2. `git reflog refs/heads/<base>` line count (or tag OID invariance when `<base>` is a tag)
#   3. all refs outside `refs/heads/relay/<run_id>/` (`for-each-ref` refname + objectname)
#   4. main working tree `git status --porcelain`
#   5. main working tree `git symbolic-ref HEAD`
# ------------------------------------------------------------------
snapshot_repo_state() {
    local repo_dir="$1"
    local base_ref="$2"
    local snap_prefix="$3"
    mkdir -p "$(dirname "${snap_prefix}")"

    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" rev-parse --verify "${base_ref}^{commit}" 2>/dev/null || echo "<missing>")"
    printf '%s\n' "${base_oid}" > "${snap_prefix}.base_oid"

    if HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" show-ref --verify --quiet "refs/heads/${base_ref}"; then
        local reflog_cnt
        reflog_cnt="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" reflog show "refs/heads/${base_ref}" | wc -l | tr -d ' ')"
        printf 'branch:%s\n' "${reflog_cnt}" > "${snap_prefix}.reflog"
    elif HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" show-ref --verify --quiet "refs/tags/${base_ref}"; then
        local tag_oid
        tag_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" rev-parse --verify "refs/tags/${base_ref}")"
        printf 'tag:%s\n' "${tag_oid}" > "${snap_prefix}.reflog"
    else
        printf 'other:%s\n' "${base_oid}" > "${snap_prefix}.reflog"
    fi

    HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" for-each-ref --format='%(refname) %(objectname)' | LC_ALL=C sort > "${snap_prefix}.refs"
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" status --porcelain > "${snap_prefix}.porcelain"

    local sym_head
    if sym_head="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" symbolic-ref -q HEAD 2>/dev/null)"; then
        printf 'sym:%s\n' "${sym_head}" > "${snap_prefix}.head"
    else
        sym_head="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo_dir}" rev-parse HEAD 2>/dev/null || echo "<unborn>")"
        printf 'detached:%s\n' "${sym_head}" > "${snap_prefix}.head"
    fi
}

assert_base_untouched() {
    local repo_dir="$1"
    local base_ref="$2"
    local snap_prefix="$3"
    local run_id="${4:-}"

    local after_prefix="${snap_prefix}.after"
    snapshot_repo_state "${repo_dir}" "${base_ref}" "${after_prefix}"

    /usr/bin/python3 - "${snap_prefix}" "${after_prefix}" "${base_ref}" "${run_id}" <<'PY'
import sys

before_p, after_p, base_ref, run_id = sys.argv[1:5]

def read_text(p):
    with open(p, encoding="utf-8") as fh:
        return fh.read()

b_oid = read_text(before_p + ".base_oid").strip()
a_oid = read_text(after_p + ".base_oid").strip()
if b_oid != a_oid:
    sys.stderr.write(f"assert_base_untouched FAILED: base '{base_ref}' OID changed: before={b_oid} after={a_oid}\n")
    sys.exit(1)

b_reflog = read_text(before_p + ".reflog").strip()
a_reflog = read_text(after_p + ".reflog").strip()
if b_reflog != a_reflog:
    sys.stderr.write(f"assert_base_untouched FAILED: reflog/tag check for '{base_ref}' changed: before={b_reflog} after={a_reflog}\n")
    sys.exit(1)

allowed_prefix = f"refs/heads/relay/{run_id}/" if run_id else None

def filter_refs(lines):
    out = []
    for line in lines:
        if not line:
            continue
        refname = line.split(" ", 1)[0]
        if allowed_prefix and refname.startswith(allowed_prefix):
            continue
        out.append(line)
    return out

b_refs_raw = read_text(before_p + ".refs").splitlines()
a_refs_raw = read_text(after_p + ".refs").splitlines()
b_refs = filter_refs(b_refs_raw)
a_refs = filter_refs(a_refs_raw)
if b_refs != a_refs:
    sys.stderr.write(
        f"assert_base_untouched FAILED: refs outside {allowed_prefix or '<none>'} changed:\n"
        f"  before: {b_refs}\n"
        f"  after:  {a_refs}\n"
    )
    sys.exit(1)

b_porcelain = read_text(before_p + ".porcelain")
a_porcelain = read_text(after_p + ".porcelain")
if b_porcelain != a_porcelain:
    sys.stderr.write(
        f"assert_base_untouched FAILED: main working tree git status --porcelain changed:\n"
        f"  before: {b_porcelain!r}\n"
        f"  after:  {a_porcelain!r}\n"
    )
    sys.exit(1)

b_head = read_text(before_p + ".head").strip()
a_head = read_text(after_p + ".head").strip()
if b_head != a_head:
    sys.stderr.write(f"assert_base_untouched FAILED: symbolic-ref HEAD changed: before={b_head} after={a_head}\n")
    sys.exit(1)
PY
}

# Helper that snapshots repo state before `run`, invokes product, extracts `runID` (if JSON stdout produced),
# runs `assert_base_untouched` unconditionally, and returns `run`'s exit code.
# Usage: invoke_run_checked <repo_dir> <base_ref> <snap_prefix> <stdout_path> <stderr_path> [KEY=VAL ...] -- <run args...>
invoke_run_checked() {
    local repo_dir="$1"
    local base_ref="$2"
    local snap_prefix="$3"
    local out_file="$4"
    local err_file="$5"
    shift 5

    snapshot_repo_state "${repo_dir}" "${base_ref}" "${snap_prefix}"
    local rc=0
    invoke_product "${out_file}" "${err_file}" "$@" || rc=$?

    local run_id=""
    if [[ -s "${out_file}" ]]; then
        run_id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8")).get("runID") or "")' "${out_file}" 2>/dev/null || true)"
    fi
    if ! assert_base_untouched "${repo_dir}" "${base_ref}" "${snap_prefix}" "${run_id}"; then
        return 98
    fi
    return "${rc}"
}

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAIL_LOG="${WORK_TMP}/failed-rows.log"
: > "${FAIL_LOG}"

record_pass() {
    local row="$1"
    local msg="$2"
    echo "[PASS] Row ${row}: ${msg}"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
}

record_fail() {
    local row="$1"
    local msg="$2"
    echo "[FAIL] Row ${row}: ${msg}"
    if [[ -n "${WORK_TMP:-}" && -d "${WORK_TMP}" ]]; then
        printf 'Row %s: %s\n' "${row}" "${msg}" >> "${FAIL_LOG}"
    fi
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
}

record_skip() {
    local row="$1"
    local msg="$2"
    echo "[SKIP] Row ${row}: 没跑（第 6 段实现：${msg}）"
    SKIP_COUNT=$(( SKIP_COUNT + 1 ))
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

# ------------------------------------------------------------------
# Row 1: Two independent lanes a & b writing src/a.txt and src/b.txt without verify
# ------------------------------------------------------------------
row_01_two_independent_lanes_no_verify() {
    local d="${WORK_TMP}/r01"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    mkdir -p "${d}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"
    init_temp_project "${proj}"

    cat > "${d}/prompts/a.md" <<'EOF'
STUB WRITE src/a.txt alpha-from-lane-a
STUB COST 0.0100
EOF
    cat > "${d}/prompts/b.md" <<'EOF'
STUB WRITE src/b.txt beta-from-lane-b
STUB COST 0.0200
EOF
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": []}
  ]
}
EOF

    local rc=0
    invoke_run_checked "${repo}" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
        "STUB_TRACE_DIR=${traces}" -- \
        run "${d}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        cat "${d}/run.stderr" >&2 || true
        echo "Row 1 expected exit 0, got ${rc}" >&2
        return 1
    fi

    /usr/bin/python3 - "${d}/run.stdout" "${repo}" "${proj}" "${base_oid}" "${FAKE_AUTHOR_FULL}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, proj_dir, base_oid, expected_author, empty_home = sys.argv[1:7]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
assert data["status"] == "succeeded", data

lanes_by_id = {l["laneID"]: l for l in data["lanes"]}
assert set(lanes_by_id) == {"a", "b"}, lanes_by_id
a_oid = lanes_by_id["a"]["commitOID"]
b_oid = lanes_by_id["b"]["commitOID"]
assert a_oid and b_oid and a_oid != b_oid, (a_oid, b_oid)

integ = data["integration"]
assert integ is not None, "integration is null"
assert integ["status"] == "merged", integ
assert integ["ready"] is False, integ
assert integ["verify"] is None, integ
assert integ["baseCommitOID"] == base_oid, integ
int_branch = f"relay/{run_id}/integration"
assert integ["branch"] == int_branch, integ

expected_wt = os.path.realpath(os.path.join(proj_dir, "runs", run_id, "worktrees", "integration"))
assert os.path.isdir(expected_wt), f"missing integration worktree dir {expected_wt}"
assert os.path.realpath(integ["worktreePath"]) == expected_wt, (integ["worktreePath"], expected_wt)

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"

def git(*args, cwd=repo_dir, binary=False):
    res = subprocess.run(["/usr/bin/git", "-C", cwd, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True)
    return res.stdout if binary else res.stdout.decode("utf-8")

# First-parent commits from base..integration in chronological order (1st merge = a, 2nd merge = b)
fp = [x for x in git("rev-list", "--first-parent", "--reverse", f"{base_oid}..{int_branch}").splitlines() if x]
assert len(fp) == 2, f"expected 2 first-parent merge commits, got {fp}"
m1, m2 = fp
assert integ["headCommitOID"] == m2, (integ["headCommitOID"], m2)

p_m1 = git("rev-list", "--parents", "-n", "1", m1).strip().split()
p_m2 = git("rev-list", "--parents", "-n", "1", m2).strip().split()
assert p_m1 == [m1, base_oid, a_oid], f"m1 parents mismatch: {p_m1} vs {[m1, base_oid, a_oid]}"
assert p_m2 == [m2, m1, b_oid], f"m2 parents mismatch: {p_m2} vs {[m2, m1, b_oid]}"

merges = integ["merges"]
assert [m["laneID"] for m in merges] == ["a", "b"], merges
assert merges[0]["status"] == "merged" and merges[0]["mergeCommitOID"] == m1 and merges[0]["conflicts"] == [], merges[0]
assert merges[1]["status"] == "merged" and merges[1]["mergeCommitOID"] == m2 and merges[1]["conflicts"] == [], merges[1]

# Exact diff files & byte-identical content against each lane branch
diff_files = sorted(x for x in git("diff", "--name-only", base_oid, int_branch).splitlines() if x)
assert diff_files == ["src/a.txt", "src/b.txt"], diff_files
assert git("show", f"{int_branch}:src/a.txt", binary=True) == git("show", f"relay/{run_id}/a:src/a.txt", binary=True)
assert git("show", f"{int_branch}:src/b.txt", binary=True) == git("show", f"relay/{run_id}/b:src/b.txt", binary=True)

# Merge commit author, committer, and message format
for commit_oid, lane_id, agent_name, lane_oid in ((m1, "a", "claude", a_oid), (m2, "b", "vibe", b_oid)):
    author = git("log", "-1", "--format=%an <%ae>", commit_oid).strip()
    committer = git("log", "-1", "--format=%cn <%ce>", commit_oid).strip()
    assert author == expected_author, (commit_oid, author, expected_author)
    assert committer == expected_author, (commit_oid, committer, expected_author)
    full_msg = git("log", "-1", "--format=%B", commit_oid).rstrip("\n")
    expected_msg = (
        f"relay {run_id} merge {lane_id} ({agent_name})\n\n"
        f"Lane branch: relay/{run_id}/{lane_id}\n"
        f"Lane commit: {lane_oid}\n"
        f"Merged by RelayIDE; repository hooks skipped."
    )
    assert full_msg == expected_msg, f"commit message mismatch:\ngot:\n{full_msg!r}\nexpected:\n{expected_msg!r}"

# Integration worktree git status --porcelain is empty
wt_status = git("status", "--porcelain", cwd=expected_wt)
assert wt_status == "", f"integration worktree dirty: {wt_status!r}"

# Both lane branch commit OIDs remain unchanged
assert git("rev-parse", f"relay/{run_id}/a").strip() == a_oid
assert git("rev-parse", f"relay/{run_id}/b").strip() == b_oid
PY
}

# ------------------------------------------------------------------
# Row 2: 40-line file modified at line 5 by a and line 30 by b -> matches hand-computed & git merge-file -p
# ------------------------------------------------------------------
row_02_same_file_distant_lines_matches_git_merge_file() {
    local d="${WORK_TMP}/r02"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    mkdir -p "${d}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    mkdir -p "${repo}/src"
    /usr/bin/python3 - "${repo}/src/forty.txt" "${d}" <<'PY'
import os, sys
repo_file, d_dir = sys.argv[1], sys.argv[2]
base_lines = [f"line-{i:02d}" for i in range(1, 41)]
a_lines = list(base_lines)
a_lines[4] = "line-05-modified-by-lane-a"
b_lines = list(base_lines)
b_lines[29] = "line-30-modified-by-lane-b"
exp_lines = list(base_lines)
exp_lines[4] = "line-05-modified-by-lane-a"
exp_lines[29] = "line-30-modified-by-lane-b"

def write_lines(path, lines):
    with open(path, "wb") as fh:
        fh.write(("\n".join(lines) + "\n").encode("utf-8"))

write_lines(repo_file, base_lines)
write_lines(os.path.join(d_dir, "base-forty.txt"), base_lines)
write_lines(os.path.join(d_dir, "a-forty.txt"), a_lines)
write_lines(os.path.join(d_dir, "b-forty.txt"), b_lines)
write_lines(os.path.join(d_dir, "hand-expected.txt"), exp_lines)

with open(os.path.join(d_dir, "prompts", "a.md"), "wb") as fh:
    fh.write(("STUB WRITE_BLOCK src/forty.txt EOF_FORTY_A\n" + "\n".join(a_lines) + "\nEOF_FORTY_A\n").encode("utf-8"))
with open(os.path.join(d_dir, "prompts", "b.md"), "wb") as fh:
    fh.write(("STUB WRITE_BLOCK src/forty.txt EOF_FORTY_B\n" + "\n".join(b_lines) + "\nEOF_FORTY_B\n").encode("utf-8"))
PY

    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" add src/forty.txt
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" -c commit.gpgsign=false commit -q -m "Add 40-line baseline file"
    init_temp_project "${proj}"

    cat > "${d}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": []}
  ]
}
EOF

    local rc=0
    invoke_run_checked "${repo}" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
        "STUB_TRACE_DIR=${traces}" -- \
        run "${d}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        cat "${d}/run.stderr" >&2 || true
        echo "Row 2 expected exit 0, got ${rc}" >&2
        return 1
    fi

    HOME="${WORK_TMP}/empty-git-home" git merge-file -p \
        "${d}/a-forty.txt" "${d}/base-forty.txt" "${d}/b-forty.txt" > "${d}/git-merge-file.txt"

    /usr/bin/python3 - "${d}/run.stdout" "${repo}" "${d}/hand-expected.txt" "${d}/git-merge-file.txt" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, hand_p, gmf_p, empty_home = sys.argv[1:6]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
integ = data["integration"]
assert integ["status"] == "merged" and integ["ready"] is False, integ

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"

branch_bytes = subprocess.run(
    ["/usr/bin/git", "-C", repo_dir, "show", f"relay/{run_id}/integration:src/forty.txt"],
    env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True
).stdout
wt_bytes = open(os.path.join(integ["worktreePath"], "src", "forty.txt"), "rb").read()
hand_bytes = open(hand_p, "rb").read()
gmf_bytes = open(gmf_p, "rb").read()

assert hand_bytes == gmf_bytes, "hand-computed expected bytes differed from git merge-file -p"
assert branch_bytes == hand_bytes, "integration branch file differed from hand-computed expected bytes"
assert branch_bytes == gmf_bytes, "integration branch file differed from git merge-file -p output"
assert wt_bytes == hand_bytes, "integration worktree file differed from expected bytes"
PY
}

# Shared Python verifier for Row 3 and Row 4 conflict & clean-abort invariants.
verify_conflict_abort_invariants() {
    local stdout_p="$1"
    local repo_dir="$2"
    local base_oid="$3"
    local marker_p="$4"
    local mode="$5"
    local extra_arg="${6:-}"

    /usr/bin/python3 - "${stdout_p}" "${repo_dir}" "${base_oid}" "${marker_p}" "${mode}" "${extra_arg}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, base_oid, marker_p, mode, extra_arg, empty_home = sys.argv[1:8]
assert not os.path.exists(marker_p), f"verify marker file must NOT exist on conflict: {marker_p}"

data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
lanes_by_id = {l["laneID"]: l for l in data["lanes"]}
a_oid = lanes_by_id["a"]["commitOID"]
assert a_oid, lanes_by_id["a"]

integ = data["integration"]
assert integ is not None, "integration is null"
assert integ["status"] == "conflict", integ
assert integ["ready"] is False, integ
assert integ["verify"] is None, integ

merges = integ["merges"]
assert [m["laneID"] for m in merges] == ["a", "b"], merges
m_a, m_b = merges[0], merges[1]
assert m_a["status"] == "merged" and m_a["mergeCommitOID"] and m_a["conflicts"] == [], m_a
assert m_b["status"] == "conflict" and m_b["mergeCommitOID"] is None, m_b

conflicts = m_b["conflicts"]
if mode == "exact_uu_f":
    assert conflicts == [{"code": "UU", "path": "f.txt"}], f"expected exact UU f.txt, got {conflicts}"
elif mode in ("AA", "UD", "DU", "UU"):
    assert any(c["code"] == mode and c["path"] == extra_arg for c in conflicts), f"expected ({extra_arg}, {mode}) in {conflicts}"
elif mode == "fd_tilde":
    assert any(c["path"].startswith("fd~") for c in conflicts), f"expected path starting with 'fd~' in {conflicts}"
else:
    raise AssertionError(f"unknown mode {mode}")

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"

def git(*args, cwd=repo_dir, check=True, binary=False):
    res = subprocess.run(["/usr/bin/git", "-C", cwd, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, check=check)
    return (res.returncode, res.stdout if binary else res.stdout.decode("utf-8", errors="replace"))

int_branch = f"relay/{run_id}/integration"
_, fp_out = git("rev-list", "--first-parent", "--reverse", f"{base_oid}..{int_branch}")
fp = [x for x in fp_out.splitlines() if x]
assert len(fp) == 1, f"expected exactly 1 first-parent commit on integration branch, got {fp}"
m1 = fp[0]
assert m1 == m_a["mergeCommitOID"] == integ["headCommitOID"], (m1, m_a["mergeCommitOID"], integ["headCommitOID"])

_, parents_str = git("rev-list", "--parents", "-n", "1", m1)
parents = parents_str.strip().split()
assert parents == [m1, base_oid, a_oid], f"integration HEAD parents mismatch: {parents}"

wt_dir = os.path.realpath(integ["worktreePath"])
assert os.path.isdir(wt_dir), wt_dir
_, wt_head = git("rev-parse", "HEAD", cwd=wt_dir)
assert wt_head.strip() == m1, (wt_head.strip(), m1)

# No MERGE_HEAD in integration worktree
mh_rc, _ = git("rev-parse", "-q", "--verify", "MERGE_HEAD", cwd=wt_dir, check=False)
assert mh_rc != 0, "MERGE_HEAD ref still resolves in integration worktree"
_, mh_git_path = git("rev-parse", "--git-path", "MERGE_HEAD", cwd=wt_dir)
mh_resolved = mh_git_path.strip()
if not os.path.isabs(mh_resolved):
    mh_resolved = os.path.join(wt_dir, mh_resolved)
assert not os.path.exists(mh_resolved), f"MERGE_HEAD file still exists at {mh_resolved}"

# `git status --porcelain -uall --ignored` is completely empty
_, st_out = git("status", "--porcelain=v1", "-uall", "--ignored", cwd=wt_dir)
assert st_out == "", f"integration worktree status not empty after abort: {st_out!r}"

# Walk integration worktree: no line starting with <<<<<<< (and for fd_tilde, no fd~* entries)
for root, dirs, files in os.walk(wt_dir):
    if ".git" in dirs:
        dirs.remove(".git")
    rel_root = os.path.relpath(root, wt_dir)
    if mode == "fd_tilde":
        for entry in list(dirs) + list(files):
            rel_entry = entry if rel_root == "." else os.path.join(rel_root, entry)
            assert not entry.startswith("fd~") and not rel_entry.startswith("fd~"), f"leftover fd~ path in worktree: {rel_entry}"
    for fname in files:
        fpath = os.path.join(root, fname)
        if os.path.islink(fpath):
            continue
        raw = open(fpath, "rb").read()
        for line in raw.splitlines():
            assert not line.startswith(b"<<<<<<<"), f"conflict marker found in {fpath}: {line!r}"

if mode == "UU" and extra_arg == "blob.bin":
    _, a_blob = git("show", f"relay/{run_id}/a:blob.bin", binary=True)
    wt_blob = open(os.path.join(wt_dir, "blob.bin"), "rb").read()
    assert wt_blob == a_blob and b"\x00" in wt_blob, "binary file in worktree does not match lane a version byte-for-byte"
PY
}

# ------------------------------------------------------------------
# Row 3: Same-line conflict on f.txt with marker-writing verify -> UU, clean abort, verify null, exit 1
# ------------------------------------------------------------------
row_03_same_line_conflict_aborts_cleanly_and_skips_verify() {
    local d="${WORK_TMP}/r03"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    local marker="${d}/verify-should-not-run.marker"
    mkdir -p "${d}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    printf 'line-1\nshared-conflict-line\nline-3\n' > "${repo}/f.txt"
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" add f.txt
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" -c commit.gpgsign=false commit -q -m "Add f.txt"
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"
    init_temp_project "${proj}"

    cat > "${d}/prompts/a.md" <<'EOF'
STUB WRITE_BLOCK f.txt EOF_A
line-1
alpha-replacement-line
line-3
EOF_A
EOF
    cat > "${d}/prompts/b.md" <<'EOF'
STUB WRITE_BLOCK f.txt EOF_B
line-1
beta-replacement-line
line-3
EOF_B
EOF
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": []}
  ],
  "verify": "'${STUB_VERIFY_BIN}' --tag '${WORK_TMP_NAME}' --write-marker '${marker}' --exit 0"
}
EOF

    local rc=0
    invoke_run_checked "${repo}" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
        "STUB_TRACE_DIR=${traces}" -- \
        run "${d}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
    if [[ "${rc}" -ne 1 ]]; then
        cat "${d}/run.stderr" >&2 || true
        echo "Row 3 expected exit 1, got ${rc}" >&2
        return 1
    fi

    verify_conflict_abort_invariants "${d}/run.stdout" "${repo}" "${base_oid}" "${marker}" "exact_uu_f"
}

# ------------------------------------------------------------------
# Row 4: Remaining conflict types run separately: AA, UD, DU, binary NUL (UU), file vs directory (fd~)
# ------------------------------------------------------------------
row_04_remaining_conflict_types_abort_cleanly() {
    local root="${WORK_TMP}/r04"
    rm -rf "${root}"
    mkdir -p "${root}"

    # 4.1 add/add (AA)
    {
        local d="${root}/aa"
        mkdir -p "${d}/prompts" "${d}/traces"
        init_temp_git_repo "${d}/repo" 1
        local base_oid
        base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
        init_temp_project "${d}/Proj.relayproj"
        printf 'STUB WRITE added.txt from-lane-a\n' > "${d}/prompts/a.md"
        printf 'STUB WRITE added.txt from-lane-b\n' > "${d}/prompts/b.md"
        cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": []}
  ],
  "verify": "'${STUB_VERIFY_BIN}' --tag '${WORK_TMP_NAME}' --write-marker '${d}/v.marker' --exit 0"
}
EOF
        local rc=0
        invoke_run_checked "${d}/repo" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
            "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 1 ]] || { echo "Row 4 (AA) expected exit 1, got ${rc}" >&2; return 1; }
        verify_conflict_abort_invariants "${d}/run.stdout" "${d}/repo" "${base_oid}" "${d}/v.marker" "AA" "added.txt"
    }

    # 4.2 a modifies, b deletes (UD)
    {
        local d="${root}/ud"
        mkdir -p "${d}/prompts" "${d}/traces"
        init_temp_git_repo "${d}/repo" 1
        printf 'original\n' > "${d}/repo/moddel.txt"
        HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" add moddel.txt
        HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" -c commit.gpgsign=false commit -q -m "Add moddel.txt"
        local base_oid
        base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
        init_temp_project "${d}/Proj.relayproj"
        printf 'STUB WRITE moddel.txt modified-by-a\n' > "${d}/prompts/a.md"
        printf 'STUB DELETE moddel.txt\n' > "${d}/prompts/b.md"
        cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": []}
  ],
  "verify": "'${STUB_VERIFY_BIN}' --tag '${WORK_TMP_NAME}' --write-marker '${d}/v.marker' --exit 0"
}
EOF
        local rc=0
        invoke_run_checked "${d}/repo" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
            "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 1 ]] || { echo "Row 4 (UD) expected exit 1, got ${rc}" >&2; return 1; }
        verify_conflict_abort_invariants "${d}/run.stdout" "${d}/repo" "${base_oid}" "${d}/v.marker" "UD" "moddel.txt"
    }

    # 4.3 a deletes, b modifies (DU)
    {
        local d="${root}/du"
        mkdir -p "${d}/prompts" "${d}/traces"
        init_temp_git_repo "${d}/repo" 1
        printf 'original\n' > "${d}/repo/delmod.txt"
        HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" add delmod.txt
        HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" -c commit.gpgsign=false commit -q -m "Add delmod.txt"
        local base_oid
        base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
        init_temp_project "${d}/Proj.relayproj"
        printf 'STUB DELETE delmod.txt\n' > "${d}/prompts/a.md"
        printf 'STUB WRITE delmod.txt modified-by-b\n' > "${d}/prompts/b.md"
        cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "agy",    "prompt": "prompts/b.md", "after": []}
  ],
  "verify": "'${STUB_VERIFY_BIN}' --tag '${WORK_TMP_NAME}' --write-marker '${d}/v.marker' --exit 0"
}
EOF
        local rc=0
        invoke_run_checked "${d}/repo" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
            "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 1 ]] || { echo "Row 4 (DU) expected exit 1, got ${rc}" >&2; return 1; }
        verify_conflict_abort_invariants "${d}/run.stdout" "${d}/repo" "${base_oid}" "${d}/v.marker" "DU" "delmod.txt"
    }

    # 4.4 Binary NUL conflict (UU; worktree file matches lane a byte-for-byte)
    {
        local d="${root}/bin"
        mkdir -p "${d}/prompts" "${d}/traces"
        init_temp_git_repo "${d}/repo" 1
        /usr/bin/python3 -c 'import sys; open(sys.argv[1], "wb").write(bytes.fromhex("000102000304"))' "${d}/repo/blob.bin"
        HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" add blob.bin
        HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" -c commit.gpgsign=false commit -q -m "Add binary blob.bin"
        local base_oid
        base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
        init_temp_project "${d}/Proj.relayproj"
        printf 'STUB WRITE_HEX blob.bin 00aa1100bb227f00\n' > "${d}/prompts/a.md"
        printf 'STUB WRITE_HEX blob.bin 00cc3300dd44fe00\n' > "${d}/prompts/b.md"
        cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": []}
  ],
  "verify": "'${STUB_VERIFY_BIN}' --tag '${WORK_TMP_NAME}' --write-marker '${d}/v.marker' --exit 0"
}
EOF
        local rc=0
        invoke_run_checked "${d}/repo" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
            "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 1 ]] || { echo "Row 4 (binary) expected exit 1, got ${rc}" >&2; return 1; }
        verify_conflict_abort_invariants "${d}/run.stdout" "${d}/repo" "${base_oid}" "${d}/v.marker" "UU" "blob.bin"
    }

    # 4.5 File vs directory (a deletes fd and creates fd/inner; b modifies fd -> conflict path starts with fd~, none left after abort)
    {
        local d="${root}/fd"
        mkdir -p "${d}/prompts" "${d}/traces"
        init_temp_git_repo "${d}/repo" 1
        printf 'initial-fd-file\n' > "${d}/repo/fd"
        HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" add fd
        HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" -c commit.gpgsign=false commit -q -m "Add file fd"
        local base_oid
        base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
        init_temp_project "${d}/Proj.relayproj"
        cat > "${d}/prompts/a.md" <<'EOF'
STUB DELETE fd
STUB WRITE fd/inner inside-dir-from-a
EOF
        printf 'STUB WRITE fd modified-file-from-b\n' > "${d}/prompts/b.md"
        cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": []}
  ],
  "verify": "'${STUB_VERIFY_BIN}' --tag '${WORK_TMP_NAME}' --write-marker '${d}/v.marker' --exit 0"
}
EOF
        local rc=0
        invoke_run_checked "${d}/repo" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
            "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 1 ]] || { echo "Row 4 (fd~) expected exit 1, got ${rc}" >&2; return 1; }
        verify_conflict_abort_invariants "${d}/run.stdout" "${d}/repo" "${base_oid}" "${d}/v.marker" "fd_tilde"
    }
}

# ------------------------------------------------------------------
# Row 5: a & b conflict, independent lane c last in plan -> a merged, b conflict, c not-attempted
# ------------------------------------------------------------------
row_05_conflict_leaves_subsequent_lane_not_attempted() {
    local d="${WORK_TMP}/r05"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    mkdir -p "${d}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    printf 'shared-baseline\n' > "${repo}/shared.txt"
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" add shared.txt
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" -c commit.gpgsign=false commit -q -m "Add shared.txt"
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"
    init_temp_project "${proj}"

    printf 'STUB WRITE shared.txt from-a\n' > "${d}/prompts/a.md"
    printf 'STUB WRITE shared.txt from-b\n' > "${d}/prompts/b.md"
    printf 'STUB WRITE src/c.txt independent-c\n' > "${d}/prompts/c.md"
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": []},
    {"id": "c", "agent": "vibe",   "prompt": "prompts/c.md", "after": []}
  ]
}
EOF

    local rc=0
    invoke_run_checked "${repo}" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
        "STUB_TRACE_DIR=${traces}" -- \
        run "${d}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
    if [[ "${rc}" -ne 1 ]]; then
        cat "${d}/run.stderr" >&2 || true
        echo "Row 5 expected exit 1, got ${rc}" >&2
        return 1
    fi

    /usr/bin/python3 - "${d}/run.stdout" "${repo}" "${base_oid}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, base_oid, empty_home = sys.argv[1:5]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
lanes = {l["laneID"]: l for l in data["lanes"]}
for lid in ("a", "b", "c"):
    assert lanes[lid]["status"] == "succeeded" and lanes[lid]["commitOID"], lanes[lid]

integ = data["integration"]
assert integ["status"] == "conflict" and integ["ready"] is False, integ
merges = integ["merges"]
assert [m["laneID"] for m in merges] == ["a", "b", "c"], merges
assert merges[0]["status"] == "merged" and merges[0]["mergeCommitOID"], merges[0]
assert merges[1]["status"] == "conflict" and merges[1]["mergeCommitOID"] is None, merges[1]
assert merges[2]["status"] == "not-attempted" and merges[2]["mergeCommitOID"] is None, merges[2]
assert merges[2]["laneCommitOID"] == lanes["c"]["commitOID"], merges[2]

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"

def git(*args):
    return subprocess.run(["/usr/bin/git", "-C", repo_dir, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True).stdout.decode("utf-8")

fp = [x for x in git("rev-list", "--first-parent", "--reverse", f"{base_oid}..relay/{run_id}/integration").splitlines() if x]
assert len(fp) == 1 and fp[0] == merges[0]["mergeCommitOID"], fp
c_ref_oid = git("rev-parse", f"relay/{run_id}/c").strip()
assert c_ref_oid == lanes["c"]["commitOID"], (c_ref_oid, lanes["c"]["commitOID"])
assert git("diff", "--name-only", f"{base_oid}..relay/{run_id}/c").strip() == "src/c.txt"
PY
}

# ------------------------------------------------------------------
# Row 6: Plan order [b (after a), c, a] -> merge order c, a, b on --first-parent chain
# ------------------------------------------------------------------
row_06_topological_and_plan_priority_merge_order() {
    local d="${WORK_TMP}/r06"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    mkdir -p "${d}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"
    init_temp_project "${proj}"

    printf 'STUB WRITE src/b.txt from-b-after-a\n' > "${d}/prompts/b.md"
    printf 'STUB WRITE src/c.txt from-c\n' > "${d}/prompts/c.md"
    printf 'STUB WRITE src/a.txt from-a\n' > "${d}/prompts/a.md"
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "b", "agent": "codex",  "prompt": "prompts/b.md", "after": ["a"]},
    {"id": "c", "agent": "vibe",   "prompt": "prompts/c.md", "after": []},
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []}
  ]
}
EOF

    local rc=0
    invoke_run_checked "${repo}" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
        "STUB_TRACE_DIR=${traces}" -- \
        run "${d}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        cat "${d}/run.stderr" >&2 || true
        echo "Row 6 expected exit 0, got ${rc}" >&2
        return 1
    fi

    /usr/bin/python3 - "${d}/run.stdout" "${repo}" "${base_oid}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, base_oid, empty_home = sys.argv[1:5]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
lanes = {l["laneID"]: l for l in data["lanes"]}
integ = data["integration"]
assert integ["status"] == "merged" and integ["ready"] is False, integ

merges = integ["merges"]
assert [m["laneID"] for m in merges] == ["c", "a", "b"], merges
for m in merges:
    assert m["status"] == "merged" and m["mergeCommitOID"], m

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"

def git(*args):
    return subprocess.run(["/usr/bin/git", "-C", repo_dir, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True).stdout.decode("utf-8")

int_branch = f"relay/{run_id}/integration"
fp = [x for x in git("rev-list", "--first-parent", "--reverse", f"{base_oid}..{int_branch}").splitlines() if x]
assert len(fp) == 3, f"expected 3 merge commits, got {fp}"
expected_lanes = ["c", "a", "b"]
prev_first_parent = base_oid
for idx, (m_oid, lid) in enumerate(zip(fp, expected_lanes)):
    assert merges[idx]["mergeCommitOID"] == m_oid, (idx, merges[idx], m_oid)
    parents = git("rev-list", "--parents", "-n", "1", m_oid).strip().split()
    assert parents == [m_oid, prev_first_parent, lanes[lid]["commitOID"]], f"step {idx} ({lid}) parents mismatch: {parents}"
    prev_first_parent = m_oid

diff_files = sorted(x for x in git("diff", "--name-only", base_oid, int_branch).splitlines() if x)
assert diff_files == ["src/a.txt", "src/b.txt", "src/c.txt"], diff_files
PY
}

# ------------------------------------------------------------------
# Row 7: (a) x makes no changes, y writes 1 file -> x no-changes, 1 merge, exit 0
#        (b) neither lane makes changes -> nothing-to-merge, no branch/worktree/verify marker, exit 0
# ------------------------------------------------------------------
row_07_no_changes_lane_and_nothing_to_merge() {
    local root="${WORK_TMP}/r07"
    rm -rf "${root}"
    mkdir -p "${root}"

    # 7a: x makes no changes, y writes src/y.txt
    {
        local d="${root}/one-nochange"
        mkdir -p "${d}/prompts" "${d}/traces"
        init_temp_git_repo "${d}/repo" 1
        local base_oid
        base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${d}/repo" rev-parse main)"
        init_temp_project "${d}/Proj.relayproj"

        printf 'STUB MESSAGE Lane x inspected files and made zero edits\n' > "${d}/prompts/x.md"
        printf 'STUB WRITE src/y.txt payload-from-y\n' > "${d}/prompts/y.md"
        cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "x", "agent": "claude", "prompt": "prompts/x.md", "after": []},
    {"id": "y", "agent": "vibe",   "prompt": "prompts/y.md", "after": []}
  ]
}
EOF
        local rc=0
        invoke_run_checked "${d}/repo" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
            "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 0 ]] || { cat "${d}/run.stderr" >&2 || true; echo "Row 7a expected exit 0, got ${rc}" >&2; return 1; }

        /usr/bin/python3 - "${d}/run.stdout" "${d}/repo" "${base_oid}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, base_oid, empty_home = sys.argv[1:5]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
lanes = {l["laneID"]: l for l in data["lanes"]}
assert lanes["x"]["status"] == "succeeded-no-changes" and lanes["x"]["commitOID"] is None, lanes["x"]
assert lanes["y"]["status"] == "succeeded" and lanes["y"]["commitOID"], lanes["y"]

integ = data["integration"]
assert integ["status"] == "merged" and integ["ready"] is False, integ
merges = integ["merges"]
assert [m["laneID"] for m in merges] == ["x", "y"], merges
assert merges[0]["status"] == "no-changes" and merges[0]["mergeCommitOID"] is None, merges[0]
assert merges[1]["status"] == "merged" and merges[1]["mergeCommitOID"], merges[1]

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"
fp = subprocess.run(
    ["/usr/bin/git", "-C", repo_dir, "rev-list", "--first-parent", "--reverse", f"{base_oid}..relay/{run_id}/integration"],
    env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True
).stdout.decode("utf-8").splitlines()
fp = [x for x in fp if x]
assert len(fp) == 1 and fp[0] == merges[1]["mergeCommitOID"], fp
PY
    }

    # 7b: neither lane makes changes -> nothing-to-merge, no branch, no worktree, no verify marker, exit 0
    {
        local d="${root}/all-nochange"
        local marker="${d}/verify-must-not-run.marker"
        mkdir -p "${d}/prompts" "${d}/traces"
        init_temp_git_repo "${d}/repo" 1
        init_temp_project "${d}/Proj.relayproj"

        printf 'STUB MESSAGE Lane x made no changes\n' > "${d}/prompts/x.md"
        printf 'STUB MESSAGE Lane y made no changes\n' > "${d}/prompts/y.md"
        cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "x", "agent": "claude", "prompt": "prompts/x.md", "after": []},
    {"id": "y", "agent": "codex",  "prompt": "prompts/y.md", "after": []}
  ],
  "verify": "'${STUB_VERIFY_BIN}' --tag '${WORK_TMP_NAME}' --write-marker '${marker}' --exit 0"
}
EOF
        local rc=0
        invoke_run_checked "${d}/repo" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
            "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 0 ]] || { cat "${d}/run.stderr" >&2 || true; echo "Row 7b expected exit 0, got ${rc}" >&2; return 1; }
        [[ ! -e "${marker}" ]] || { echo "Row 7b verify marker exists unexpectedly" >&2; return 1; }

        /usr/bin/python3 - "${d}/run.stdout" "${d}/repo" "${d}/Proj.relayproj" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, proj_dir, empty_home = sys.argv[1:5]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
integ = data["integration"]
assert integ["status"] == "nothing-to-merge", integ
assert integ["ready"] is False, integ
assert integ["branch"] is None and integ["worktreePath"] is None, integ
assert integ["verify"] is None and integ["merges"] == [], integ

int_wt_path = os.path.join(proj_dir, "runs", run_id, "worktrees", "integration")
assert not os.path.exists(int_wt_path), f"integration worktree should not exist: {int_wt_path}"

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"
sr = subprocess.run(
    ["/usr/bin/git", "-C", repo_dir, "show-ref", "--verify", "--quiet", f"refs/heads/relay/{run_id}/integration"],
    env=env, stdin=subprocess.DEVNULL, capture_output=True
)
assert sr.returncode != 0, "integration branch should not exist when status is nothing-to-merge"
PY
    }
}

# ------------------------------------------------------------------
# Row 8: Stub runs GIT_COMMIT on first file, then writes second file uncommitted -> parent chain & merge
# ------------------------------------------------------------------
row_08_stub_git_commit_preserved_under_relay_commit() {
    local d="${WORK_TMP}/r08"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    mkdir -p "${d}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"
    init_temp_project "${proj}"

    cat > "${d}/prompts/a.md" <<'EOF'
STUB WRITE src/agent_committed.txt committed-by-stub-agent
STUB GIT_COMMIT feat(lane-a): stub agent direct commit
STUB WRITE src/relay_committed.txt committed-by-relayide-afterward
EOF
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []}
  ]
}
EOF

    local rc=0
    invoke_run_checked "${repo}" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
        "STUB_TRACE_DIR=${traces}" -- \
        run "${d}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        cat "${d}/run.stderr" >&2 || true
        echo "Row 8 expected exit 0, got ${rc}" >&2
        return 1
    fi

    /usr/bin/python3 - "${d}/run.stdout" "${repo}" "${base_oid}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, base_oid, empty_home = sys.argv[1:5]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
lane_a = data["lanes"][0]
lane_oid = lane_a["commitOID"]
assert lane_a["status"] == "succeeded" and lane_oid, lane_a

integ = data["integration"]
assert integ["status"] == "merged" and integ["ready"] is False, integ
m1 = integ["headCommitOID"]
assert m1 and integ["merges"][0]["mergeCommitOID"] == m1, integ

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"

def git(*args):
    return subprocess.run(["/usr/bin/git", "-C", repo_dir, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True).stdout.decode("utf-8")

# Lane commitOID's first parent is the stub's own GIT_COMMIT commit, whose parent is base_oid
assert git("rev-list", "--count", f"{base_oid}..{lane_oid}").strip() == "2"
stub_commit_oid = git("rev-parse", f"{lane_oid}^1").strip()
assert git("rev-parse", f"{stub_commit_oid}^1").strip() == base_oid
assert git("log", "-1", "--format=%s", stub_commit_oid).strip() == "feat(lane-a): stub agent direct commit"

# Integration branch contains both files and merge commit's second parent equals lane_oid
int_branch = f"relay/{run_id}/integration"
diff_files = sorted(x for x in git("diff", "--name-only", base_oid, int_branch).splitlines() if x)
assert diff_files == ["src/agent_committed.txt", "src/relay_committed.txt"], diff_files
assert git("show", f"{int_branch}:src/agent_committed.txt") == "committed-by-stub-agent\n"
assert git("show", f"{int_branch}:src/relay_committed.txt") == "committed-by-relayide-afterward\n"

parents = git("rev-list", "--parents", "-n", "1", m1).strip().split()
assert parents == [m1, base_oid, lane_oid], f"merge commit parents mismatch: {parents}"
PY
}

# ------------------------------------------------------------------
# Row 9: Non-succeeded lane (a exits 3; second run a returns STATUS: partial) -> skipped, no branch/wt/verify, exit 1
# ------------------------------------------------------------------
row_09_failed_or_partial_lane_skips_integration() {
    local root="${WORK_TMP}/r09"
    rm -rf "${root}"
    mkdir -p "${root}"

    for submode in "failed:STUB EXIT 3" "partial:STUB STATUS partial"; do
        local expected_lane_st="${submode%%:*}"
        local directive="${submode#*:}"
        local d="${root}/${expected_lane_st}"
        local marker="${d}/verify-must-not-run.marker"
        mkdir -p "${d}/prompts" "${d}/traces"

        init_temp_git_repo "${d}/repo" 1
        init_temp_project "${d}/Proj.relayproj"

        printf 'STUB WRITE src/a.txt from-a\n%s\n' "${directive}" > "${d}/prompts/a.md"
        printf 'STUB WRITE src/b.txt from-b\n' > "${d}/prompts/b.md"
        cat > "${d}/plan.json" <<EOF
{
  "repo": "${d}/repo",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": []}
  ],
  "verify": "'${STUB_VERIFY_BIN}' --tag '${WORK_TMP_NAME}' --write-marker '${marker}' --exit 0"
}
EOF
        local rc=0
        invoke_run_checked "${d}/repo" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
            "STUB_TRACE_DIR=${d}/traces" -- \
            run "${d}/plan.json" --project "${d}/Proj.relayproj" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 1 ]] || { cat "${d}/run.stderr" >&2 || true; echo "Row 9 (${expected_lane_st}) expected exit 1, got ${rc}" >&2; return 1; }
        [[ ! -e "${marker}" ]] || { echo "Row 9 (${expected_lane_st}) verify marker exists unexpectedly" >&2; return 1; }

        /usr/bin/python3 - "${d}/run.stdout" "${d}/repo" "${d}/Proj.relayproj" "${expected_lane_st}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, proj_dir, exp_st, empty_home = sys.argv[1:6]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
lanes = {l["laneID"]: l for l in data["lanes"]}
assert lanes["a"]["status"] == exp_st, lanes["a"]
assert lanes["b"]["status"] == "succeeded", lanes["b"]

integ = data["integration"]
assert integ["status"] == "skipped", integ
assert integ["ready"] is False, integ
assert integ["branch"] is None and integ["worktreePath"] is None, integ
assert integ["verify"] is None and integ["merges"] == [], integ
reason = integ.get("reason") or ""
assert "a" in reason and exp_st in reason, f"expected lane 'a' and status '{exp_st}' in integration.reason, got: {reason!r}"

int_wt_path = os.path.join(proj_dir, "runs", run_id, "worktrees", "integration")
assert not os.path.exists(int_wt_path), f"integration worktree must not exist: {int_wt_path}"

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"
sr = subprocess.run(
    ["/usr/bin/git", "-C", repo_dir, "show-ref", "--verify", "--quiet", f"refs/heads/relay/{run_id}/integration"],
    env=env, stdin=subprocess.DEVNULL, capture_output=True
)
assert sr.returncode != 0, "integration branch must not exist when integration is skipped"
PY
    done
}

# ------------------------------------------------------------------
# Row 22: Merge-phase 125: while lanes wait on barrier, place regular file at worktrees/integration -> 125, empty stdout, status=error
# ------------------------------------------------------------------
row_22_merge_phase_125_obstructed_integration_worktree() {
    local d="${WORK_TMP}/r22"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    local barrier="${d}/release.barrier"
    mkdir -p "${d}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"
    init_temp_project "${proj}"

    cat > "${d}/prompts/a.md" <<EOF
STUB WRITE src/a.txt alpha-r22
STUB WAIT ${barrier} 90
EOF
    cat > "${d}/prompts/b.md" <<EOF
STUB WRITE src/b.txt beta-r22
STUB WAIT ${barrier} 90
EOF
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": []}
  ]
}
EOF

    snapshot_repo_state "${repo}" "main" "${d}/snap"
    assert_stub_and_decoys_armed
    ( exec /usr/bin/perl -e '$SIG{INT}="DEFAULT"; $SIG{TERM}="DEFAULT"; exec @ARGV' \
        /usr/bin/env -u RELAY_WORKER -u AGY_CODER_WORKER -u CLAUDECODE -u RELAY_BUDGET_USD \
        "STUB_TRACE_DIR=${traces}" \
        "${RELAY_CLI}" run "${d}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh \
        >"${d}/run.stdout" 2>"${d}/run.stderr" ) &
    local bg_pid=$!
    start_pid_watchdog "${bg_pid}" 120

    wait_for_trace_start "${traces}/a.trace" "${bg_pid}" 60
    wait_for_trace_start "${traces}/b.trace" "${bg_pid}" 60
    verify_pid_is_tested_binary "${bg_pid}" "${proj}"

    local run_id
    run_id="$(read_lock_run_id "${proj}")"
    [[ -n "${run_id}" ]] || { stop_pid_watchdog "${WATCHDOG_PID}"; echo "Row 22 failed to read runID from run.lock" >&2; return 1; }

    mkdir -p "${proj}/runs/${run_id}/worktrees"
    printf 'regular-file-obstructing-integration-worktree\n' > "${proj}/runs/${run_id}/worktrees/integration"

    : > "${barrier}"
    set +e
    wait "${bg_pid}"
    local run_rc=$?
    set -e
    stop_pid_watchdog "${WATCHDOG_PID}"

    assert_base_untouched "${repo}" "main" "${d}/snap" "${run_id}"

    [[ "${run_rc}" -eq 125 ]] || { cat "${d}/run.stderr" >&2 || true; echo "Row 22 expected exit 125, got ${run_rc}" >&2; return 1; }
    [[ ! -s "${d}/run.stdout" ]] || { echo "Row 22 expected empty stdout on exit 125" >&2; return 1; }
    [[ -s "${d}/run.stderr" ]] || { echo "Row 22 expected non-empty stderr explaining reason" >&2; return 1; }

    local st_rc=0
    invoke_product "${d}/status.stdout" "${d}/status.stderr" -- \
        status --project "${proj}" --run "${run_id}" --lang zh || st_rc=$?
    [[ "${st_rc}" -eq 0 ]] || { echo "Row 22 status --run exited ${st_rc}" >&2; return 1; }

    /usr/bin/python3 - "${d}/status.stdout" "${repo}" "${base_oid}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

st_p, repo_dir, base_oid, empty_home = sys.argv[1:5]
data = json.load(open(st_p, encoding="utf-8"))
run_id = data["runID"]
integ = data["integration"]
assert integ is not None, "integration is null"
assert integ["status"] == "error", integ
assert integ["ready"] is False, integ
assert (integ.get("reason") or "").strip() != "", integ

lanes = {l["laneID"]: l for l in data["lanes"]}
for lid in ("a", "b"):
    assert lanes[lid]["status"] == "succeeded" and lanes[lid]["commitOID"], lanes[lid]

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"

def git(*args, check=True):
    return subprocess.run(["/usr/bin/git", "-C", repo_dir, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, check=check)

for lid in ("a", "b"):
    ref_oid = git("rev-parse", f"relay/{run_id}/{lid}").stdout.decode("utf-8").strip()
    assert ref_oid == lanes[lid]["commitOID"], (lid, ref_oid, lanes[lid]["commitOID"])
    ahead = git("rev-list", "--count", f"{base_oid}..{ref_oid}").stdout.decode("utf-8").strip()
    assert ahead == "1", (lid, ahead)

sr = git("show-ref", "--verify", "--quiet", f"refs/heads/relay/{run_id}/integration", check=False)
assert sr.returncode != 0, "integration branch should not exist when worktree creation failed"
PY
}

# ------------------------------------------------------------------
# Row 23: Hostile repository config + 7 failing hooks -> run exits 0, exact Row 1 merge commits, no hook marker
# ------------------------------------------------------------------
row_23_hostile_repo_configs_and_failing_hooks() {
    local d="${WORK_TMP}/r23"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    local hook_marker="${d}/hook-triggered.marker"
    mkdir -p "${d}/prompts" "${traces}"

    init_temp_git_repo "${repo}" 1
    local base_oid
    base_oid="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" rev-parse main)"

    # Hostile repository git config settings
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" config merge.verifySignatures true
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" config commit.gpgSign true
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" config merge.log true
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" config merge.ff only
    HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" config rerere.enabled true

    # Install 7 failing hooks that record marker if ever invoked
    mkdir -p "${repo}/.git/hooks"
    local hname
    for hname in pre-commit prepare-commit-msg commit-msg post-commit pre-merge-commit post-merge post-checkout; do
        cat > "${repo}/.git/hooks/${hname}" <<EOF
#!/bin/sh
printf '%s\n' "${hname}" >> "${hook_marker}"
exit 1
EOF
        chmod +x "${repo}/.git/hooks/${hname}"
    done

    init_temp_project "${proj}"
    printf 'STUB WRITE src/a.txt hostile-lane-a\n' > "${d}/prompts/a.md"
    printf 'STUB WRITE src/b.txt hostile-lane-b\n' > "${d}/prompts/b.md"
    cat > "${d}/plan.json" <<EOF
{
  "repo": "${repo}",
  "base": "main",
  "lanes": [
    {"id": "a", "agent": "claude", "prompt": "prompts/a.md", "after": []},
    {"id": "b", "agent": "vibe",   "prompt": "prompts/b.md", "after": []}
  ]
}
EOF

    local rc=0
    invoke_run_checked "${repo}" "main" "${d}/snap" "${d}/run.stdout" "${d}/run.stderr" \
        "STUB_TRACE_DIR=${traces}" -- \
        run "${d}/plan.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        cat "${d}/run.stderr" >&2 || true
        echo "Row 23 expected exit 0, got ${rc}" >&2
        return 1
    fi
    if [[ -e "${hook_marker}" ]]; then
        echo "Row 23 hook marker file exists (hooks were not skipped):" >&2
        cat "${hook_marker}" >&2 || true
        return 1
    fi

    /usr/bin/python3 - "${d}/run.stdout" "${repo}" "${base_oid}" "${WORK_TMP}/empty-git-home" <<'PY'
import json, os, subprocess, sys

stdout_p, repo_dir, base_oid, empty_home = sys.argv[1:5]
data = json.load(open(stdout_p, encoding="utf-8"))
run_id = data["runID"]
lanes = {l["laneID"]: l for l in data["lanes"]}
a_oid = lanes["a"]["commitOID"]
b_oid = lanes["b"]["commitOID"]

integ = data["integration"]
assert integ["status"] == "merged" and integ["ready"] is False, integ

env = dict(os.environ)
env["HOME"] = empty_home
env["GIT_CONFIG_NOSYSTEM"] = "1"
env["GIT_CONFIG_GLOBAL"] = "/dev/null"

def git(*args):
    return subprocess.run(["/usr/bin/git", "-C", repo_dir, *args], env=env, stdin=subprocess.DEVNULL, capture_output=True, check=True).stdout.decode("utf-8")

int_branch = f"relay/{run_id}/integration"
fp = [x for x in git("rev-list", "--first-parent", "--reverse", f"{base_oid}..{int_branch}").splitlines() if x]
assert len(fp) == 2, fp
m1, m2 = fp
assert git("rev-list", "--parents", "-n", "1", m1).strip().split() == [m1, base_oid, a_oid]
assert git("rev-list", "--parents", "-n", "1", m2).strip().split() == [m2, m1, b_oid]

# Commit message must match Row 1 verbatim (no merge.log commit summary appended)
for commit_oid, lane_id, agent_name, lane_oid in ((m1, "a", "claude", a_oid), (m2, "b", "vibe", b_oid)):
    full_msg = git("log", "-1", "--format=%B", commit_oid).rstrip("\n")
    expected_msg = (
        f"relay {run_id} merge {lane_id} ({agent_name})\n\n"
        f"Lane branch: relay/{run_id}/{lane_id}\n"
        f"Lane commit: {lane_oid}\n"
        f"Merged by RelayIDE; repository hooks skipped."
    )
    assert full_msg == expected_msg, f"Row 23 commit message mismatch:\ngot:\n{full_msg!r}\nexpected:\n{expected_msg!r}"
PY
}

# ------------------------------------------------------------------
# Row 24: Plan validation errors (9 cases) and `status <runID> --project <proj>` -> all exit 2, empty stdout, untouched state
# ------------------------------------------------------------------
row_24_m2_plan_errors_and_status_positional_arg_exit_2() {
    local d="${WORK_TMP}/r24"
    rm -rf "${d}"
    local repo="${d}/repo"
    local proj="${d}/Proj.relayproj"
    local traces="${d}/traces"
    mkdir -p "${d}/prompts" "${d}/plans" "${traces}"

    init_temp_git_repo "${repo}" 1
    init_temp_project "${proj}"
    printf 'STUB WRITE src/a.txt never-runs\n' > "${d}/prompts/a.md"

    local wt_before branches_before
    wt_before="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" worktree list --porcelain)"
    branches_before="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" for-each-ref --format='%(refname) %(objectname)' refs/heads/ | LC_ALL=C sort)"

    # Generate all 9 invalid plans
    /usr/bin/python3 - "${d}/plans" "${repo}" "${d}/prompts/a.md" <<'PY'
import json, os, sys

plans_dir, repo_dir, prompt_p = sys.argv[1:4]
base_lane = {"id": "a", "agent": "claude", "prompt": prompt_p, "after": []}

cases = [
    ("01_verify_array",         {"repo": repo_dir, "base": "main", "lanes": [base_lane], "verify": ["echo", "hi"]}),
    ("02_verify_number",        {"repo": repo_dir, "base": "main", "lanes": [base_lane], "verify": 123}),
    ("03_timeout_zero",         {"repo": repo_dir, "base": "main", "lanes": [base_lane], "verify": "true", "verify_timeout": 0}),
    ("04_timeout_86401",        {"repo": repo_dir, "base": "main", "lanes": [base_lane], "verify": "true", "verify_timeout": 86401}),
    ("05_timeout_float",        None),
    ("06_timeout_string",       {"repo": repo_dir, "base": "main", "lanes": [base_lane], "verify": "true", "verify_timeout": "60"}),
    ("07_timeout_no_verify",    {"repo": repo_dir, "base": "main", "lanes": [base_lane], "verify_timeout": 30}),
    ("08_unknown_top_timout",   {"repo": repo_dir, "base": "main", "lanes": [base_lane], "verify": "true", "verify_timout": 30}),
    ("09_unknown_lane_befor",   {"repo": repo_dir, "base": "main", "lanes": [{"id": "a", "agent": "claude", "prompt": prompt_p, "befor": []}]}),
]

for name, obj in cases:
    p = os.path.join(plans_dir, f"{name}.json")
    if name == "05_timeout_float":
        raw = (
            '{\n'
            f'  "repo": {json.dumps(repo_dir)},\n'
            '  "base": "main",\n'
            f'  "lanes": [{json.dumps(base_lane)}],\n'
            '  "verify": "true",\n'
            '  "verify_timeout": 1.5\n'
            '}\n'
        )
        open(p, "w", encoding="utf-8").write(raw)
    else:
        open(p, "w", encoding="utf-8").write(json.dumps(obj, indent=2) + "\n")
PY

    local case_name
    for case_name in \
        01_verify_array \
        02_verify_number \
        03_timeout_zero \
        04_timeout_86401 \
        05_timeout_float \
        06_timeout_string \
        07_timeout_no_verify \
        08_unknown_top_timout \
        09_unknown_lane_befor
    do
        local out_f="${d}/${case_name}.stdout"
        local err_f="${d}/${case_name}.stderr"
        local rc=0
        invoke_run_checked "${repo}" "main" "${d}/snap-${case_name}" "${out_f}" "${err_f}" \
            "STUB_TRACE_DIR=${traces}" -- \
            run "${d}/plans/${case_name}.json" --project "${proj}" --relay-sh "${REAL_RELAY_SH}" --lang zh || rc=$?
        [[ "${rc}" -eq 2 ]] || { echo "Row 24 (${case_name}) expected exit 2, got ${rc}" >&2; cat "${err_f}" >&2 || true; return 1; }
        [[ ! -s "${out_f}" ]] || { echo "Row 24 (${case_name}) expected empty stdout" >&2; return 1; }
        [[ -s "${err_f}" ]] || { echo "Row 24 (${case_name}) expected non-empty stderr" >&2; return 1; }

        if [[ "${case_name}" == "08_unknown_top_timout" ]]; then
            grep -Fq "verify_timout" "${err_f}" || { echo "Row 24 (${case_name}) stderr missing field name 'verify_timout'" >&2; return 1; }
        elif [[ "${case_name}" == "09_unknown_lane_befor" ]]; then
            grep -Fq "befor" "${err_f}" || { echo "Row 24 (${case_name}) stderr missing field name 'befor'" >&2; return 1; }
        fi

        local wt_now branches_now
        wt_now="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" worktree list --porcelain)"
        branches_now="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" for-each-ref --format='%(refname) %(objectname)' refs/heads/ | LC_ALL=C sort)"
        [[ "${wt_now}" == "${wt_before}" ]] || { echo "Row 24 (${case_name}) worktree list changed" >&2; return 1; }
        [[ "${branches_now}" == "${branches_before}" ]] || { echo "Row 24 (${case_name}) branch list changed" >&2; return 1; }

        invoke_product "${d}/runs-check.stdout" "${d}/runs-check.stderr" -- status --project "${proj}" --runs --lang zh
        /usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r == [], r' "${d}/runs-check.stdout"
    done

    # 10th check: `status <runID> --project <project>` (extra positional argument -> exit 2, empty stdout)
    snapshot_repo_state "${repo}" "main" "${d}/snap-status-pos"
    local st_pos_rc=0
    invoke_product "${d}/status-pos.stdout" "${d}/status-pos.stderr" -- \
        status "20261117-000000-beef" --project "${proj}" --lang zh || st_pos_rc=$?
    assert_base_untouched "${repo}" "main" "${d}/snap-status-pos" ""
    [[ "${st_pos_rc}" -eq 2 ]] || { echo "Row 24 (status positional) expected exit 2, got ${st_pos_rc}" >&2; return 1; }
    [[ ! -s "${d}/status-pos.stdout" ]] || { echo "Row 24 (status positional) expected empty stdout" >&2; return 1; }
    [[ -s "${d}/status-pos.stderr" ]] || { echo "Row 24 (status positional) expected non-empty stderr" >&2; return 1; }

    local wt_final branches_final
    wt_final="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" worktree list --porcelain)"
    branches_final="$(HOME="${WORK_TMP}/empty-git-home" git -C "${repo}" for-each-ref --format='%(refname) %(objectname)' refs/heads/ | LC_ALL=C sort)"
    [[ "${wt_final}" == "${wt_before}" && "${branches_final}" == "${branches_before}" ]] || return 1
    invoke_product "${d}/runs-final.stdout" "${d}/runs-final.stderr" -- status --project "${proj}" --runs --lang zh
    /usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r == [], r' "${d}/runs-final.stdout"
    [[ -z "$(ls -A "${traces}" 2>/dev/null || true)" ]] || { echo "Row 24 stub agent ran unexpectedly" >&2; return 1; }
}

run_quick_mode() {
    echo "================================================================"
    echo "RelayIDE M2 Acceptance Quick Check (--quick, Row 1)"
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

    run_row "1" "(--quick) Two independent lanes a & b merge with --no-ff, configured identity, clean integration worktree, and untouched base" row_01_two_independent_lanes_no_verify

    if [[ -e "${DECOY_MARKER}" ]]; then
        record_fail "quick-decoy" "decoy CLI was invoked during --quick"
    fi

    local fail_log_nonempty=0
    [[ -s "${FAIL_LOG}" ]] && fail_log_nonempty=1

    if ! poll_until_no_procs "${WORK_TMP}" 10; then
        echo "[FAIL] Row quick-hygiene: leftover processes or git background maintenance processes detected"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
    rm -rf "${WORK_TMP}"

    local sha_sh_after sha_util_after prefs_after git_status_after
    sha_sh_after="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
    sha_util_after="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"
    prefs_after="$(ls -1 "${PREFS_DIR}" 2>/dev/null | grep -i 'relayide' | sort || true)"
    git_status_after="$(git status --porcelain)"

    echo ""
    echo "relay.sh sha256 (end):        ${sha_sh_after}"
    echo "relay_util.py sha256 (end):   ${sha_util_after}"

    if [[ -e "${WORK_TMP}" || "${sha_sh_after}" != "${SHA256_RELAY_SH_BEFORE}" || "${sha_util_after}" != "${SHA256_RELAY_UTIL_BEFORE}" || "${prefs_after}" != "${PREFS_RELAY_BEFORE}" || "${git_status_after}" != "${GIT_STATUS_BEFORE}" ]]; then
        echo "[FAIL] Row quick-hygiene: post-run cleanup, preferences, working tree, or relay.sh sha256 check failed"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi

    [[ "${fail_log_nonempty}" -eq 0 && "${FAIL_COUNT}" -eq 0 ]]
}

run_full_suite() {
    echo "================================================================"
    echo "RelayIDE M2 Acceptance Suite"
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

    run_row "1" "Two independent lanes a & b merge with --no-ff, configured identity, exact message, clean integration worktree, and unchanged lane OIDs" row_01_two_independent_lanes_no_verify
    run_row "2" "40-line file modified at line 5 (a) and line 30 (b) matches hand-computed bytes and git merge-file -p" row_02_same_file_distant_lines_matches_git_merge_file
    run_row "3" "Same-line conflict on f.txt records UU, aborts cleanly without MERGE_HEAD/markers, skips verify, and exits 1" row_03_same_line_conflict_aborts_cleanly_and_skips_verify
    run_row "4" "Remaining conflict types (AA, UD, DU, binary NUL, file/directory fd~) record expected codes and abort cleanly" row_04_remaining_conflict_types_abort_cleanly
    run_row "5" "Conflict in b leaves trailing independent lane c as not-attempted with its branch & commit OID intact" row_05_conflict_leaves_subsequent_lane_not_attempted
    run_row "6" "Plan order [b (after a), c, a] merges in topological + plan order c, a, b along --first-parent" row_06_topological_and_plan_priority_merge_order
    run_row "7" "No-change lane records no-changes (null mergeCommitOID); all-no-change run records nothing-to-merge without branch/worktree/verify" row_07_no_changes_lane_and_nothing_to_merge
    run_row "8" "Stub GIT_COMMIT preserved as parent of lane commitOID and both files land on integration branch" row_08_stub_git_commit_preserved_under_relay_commit
    run_row "9" "Non-succeeded lane (exit 3 or STATUS: partial) marks integration skipped naming lane & status without branch/worktree/verify" row_09_failed_or_partial_lane_skips_integration
    record_skip "10" "verify passes: probes pwd -P, HEAD, git status, PATH, test -t 0, git log -1, cat"
    record_skip "11" "verify exits 3 -> verify-failed, ready=false, merges kept, run exits 1"
    record_skip "12" "verify emits 307200 stdout bytes + stderr marker + exit 1 -> failed (not timeout)"
    record_skip "13" "verify emits 20 MiB + exit 0 -> verify.pty capped at 16777216 bytes, logTruncated=true"
    record_skip "14" "verify spawns setpgrp + INT/TERM/HUP-ignoring child with timeout 2s -> 0 leftover procs"
    record_skip "15" "verify kill -9 self -> signal=9, exitCode=null, run exits 1"
    record_skip "16" "verify modifies tracked file + exit 0 -> failed, modifiedTrackedFiles=['src/a.txt']"
    record_skip "17" "live status --run while verify blocked on barrier -> verifying + alive PID"
    record_skip "18" "SIGINT / SIGTERM during verify -> 130 / 143, cancelled, merges kept, 0 procs"
    record_skip "19" "SIGINT during custom merge driver -> 130, cancelled, clean integration worktree"
    record_skip "20" "kill -9 RelayIDE during verify -> 0 procs, status shows interrupted, recovery run exits 0"
    record_skip "21" "SIGINT while lanes blocked on barrier -> 130, integration skipped, no branch/worktree"
    run_row "22" "Merge-phase 125 when regular file obstructs worktrees/integration -> exit 125, empty stdout, status=error, lanes & base intact" row_22_merge_phase_125_obstructed_integration_worktree
    run_row "23" "Hostile repository (verifySignatures, gpgSign, merge.log, ff=only, rerere + 7 exit-1 hooks) merges cleanly with exact Row 1 messages and zero hook runs" row_23_hostile_repo_configs_and_failing_hooks
    run_row "24" "M2 plan validation errors and status extra positional argument each exit 2 with empty stdout and zero repo/DB side effects" row_24_m2_plan_errors_and_status_positional_arg_exit_2
    record_skip "25" "Two projects concurrently running + verifying against same repository"
    record_skip "26" "Same plan run twice -> distinct integration branches, first unchanged"
    record_skip "27" "Rows 1, 3, 11, 18 run stdout byte-identical to status --run"
    record_skip "28" "Rows 3 and 11 with --lang zh vs --lang en -> stderr differs, JSON identical"
    record_skip "29" "base untouched across un-checked-out branch dev and tag v0"
    record_skip "34" "m2-merge.sh --quick 1-lane + verify:true check"

    local fail_log_nonempty=0
    [[ -s "${FAIL_LOG}" ]] && fail_log_nonempty=1

    # --- Row 33: Post-suite hygiene (decoy marker absent, 0 temp-dir procs, 0 git cwd procs, WORK_TMP removed, Preferences, relay.sh sha256, working tree) ---
    echo ""
    echo "--- Row 33: Post-suite decoy marker, process, git maintenance cwd, temp dir, Preferences, relay.sh sha256, and working tree check ---"
    local row33_ok=1
    if [[ -e "${DECOY_MARKER}" ]]; then
        echo "decoy CLI marker exists:" >&2
        cat "${DECOY_MARKER}" >&2 || true
        row33_ok=0
    fi
    if ! poll_until_no_procs "${WORK_TMP}" 10; then
        row33_ok=0
    fi
    rm -rf "${WORK_TMP}"
    if [[ -e "${WORK_TMP}" ]]; then
        echo "WORK_TMP still exists after rm -rf" >&2
        row33_ok=0
    fi

    local prefs_after sha_sh_after sha_util_after git_status_after
    prefs_after="$(ls -1 "${PREFS_DIR}" 2>/dev/null | grep -i 'relayide' | sort || true)"
    sha_sh_after="$(shasum -a 256 "${REAL_RELAY_SH}" | awk '{print $1}')"
    sha_util_after="$(shasum -a 256 "${REAL_RELAY_UTIL}" | awk '{print $1}')"
    if [[ "${prefs_after}" != "${PREFS_RELAY_BEFORE}" ]]; then
        echo "Preferences RelayIDE files changed: before='${PREFS_RELAY_BEFORE}' after='${prefs_after}'" >&2
        row33_ok=0
    fi
    if [[ "${sha_sh_after}" != "${SHA256_RELAY_SH_BEFORE}" || "${sha_util_after}" != "${SHA256_RELAY_UTIL_BEFORE}" ]]; then
        echo "relay.sh or relay_util.py sha256 changed" >&2
        row33_ok=0
    fi
    if [[ "${RECORD}" -eq 0 ]]; then
        git_status_after="$(git status --porcelain)"
        if [[ "${git_status_after}" != "${GIT_STATUS_BEFORE}" ]]; then
            echo "git status --porcelain changed during run without --record" >&2
            row33_ok=0
        fi
    fi

    if [[ "${row33_ok}" -eq 1 ]]; then
        record_pass "33" "decoy marker absent, zero temp-dir or git background processes, temp dir removed, Preferences & relay.sh sha256 & working tree unchanged"
    else
        record_fail "33" "post-run decoy, process, temp dir, Preferences, sha256, or working tree check failed"
    fi

    echo ""
    echo "relay.sh sha256 (end):        ${sha_sh_after}"
    echo "relay_util.py sha256 (end):   ${sha_util_after}"
    echo "================================================================"
    if [[ "${fail_log_nonempty}" -eq 0 && "${FAIL_COUNT}" -eq 0 ]]; then
        echo "M2 ACCEPTANCE SUITE PASSED (passed=${PASS_COUNT}, skipped_not_run=${SKIP_COUNT}, failed=0)"
        echo "================================================================"
        return 0
    else
        echo "M2 ACCEPTANCE SUITE FAILED (passed=${PASS_COUNT}, skipped_not_run=${SKIP_COUNT}, failed=${FAIL_COUNT})"
        echo "================================================================"
        return 1
    fi
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
        REPORT_REL="reports/m2-merge.txt"
        run_full_suite 2>&1 | sanitize_stream | tee "${ROOT_DIR}/${REPORT_REL}"
        echo "Report written to <repo>/${REPORT_REL}"
    else
        run_full_suite 2>&1 | sanitize_stream
    fi
fi
