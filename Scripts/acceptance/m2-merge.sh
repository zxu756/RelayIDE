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
    record_skip "2"  "40-line same-file non-overlapping merge vs hand-computed & git merge-file -p"
    record_skip "3"  "Same-line UU conflict aborts cleanly and skips verify"
    record_skip "4"  "Remaining conflict types (AA, UD, DU, binary NUL, file/directory fd~) abort cleanly"
    record_skip "5"  "Conflict stops merge pipeline leaving trailing lane not-attempted"
    record_skip "6"  "Topological + plan-order merge sequence [b(after a), c, a] -> c, a, b"
    record_skip "7"  "no-changes lane skipped in merge and all-no-changes -> nothing-to-merge"
    record_skip "8"  "Agent GIT_COMMIT preserved before RelayIDE lane commit and merged cleanly"
    record_skip "9"  "Failed or partial lane -> integration skipped without branch/worktree/verify"
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
    record_skip "22" "Merge-phase 125 when file obstructs worktrees/integration -> empty stdout, integration error"
    record_skip "23" "Hostile repo config (verifySignatures, gpgSign, log, ff=only, rerere) + 7 failing hooks"
    record_skip "24" "M2 plan schema errors & status extra positional argument -> exit 2, empty stdout"
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
