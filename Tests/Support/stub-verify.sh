#!/usr/bin/env bash
# Deterministic verification-command test double for RelayIDE M2 unit and acceptance tests.
#
# Processes flags sequentially from left to right:
#   --tag <token>                Explicit token included in long-running child process argv
#   --trace <path>               Append "start <ts> <pid>" now and "end <ts> <pid> <rc>" on exit
#   --stdout-bytes <N>           Emit exact <N> ASCII 'x' bytes to stdout
#   --stderr-bytes <N>           Emit exact <N> ASCII 'e' bytes to stderr
#   --stdout-line <text>         Emit <text>\n to stdout
#   --stderr-line <text>         Emit <text>\n to stderr
#   --write-marker <path>        Write a marker file (creates parent directories)
#   --marker <path>              Alias for --write-marker
#   --wait-timeout <sec>         Timeout in seconds for subsequent --wait-barrier (0 = unlimited)
#   --wait-barrier <path>        Wait until <path> exists (exits 124 on timeout)
#   --wait <path>                Alias for --wait-barrier
#   --sleep <sec>                Sleep <sec> seconds (child argv carries temp-dir tag)
#   --probe-file <path>          Write JSON with pwd -P, git rev-parse HEAD, git status --porcelain,
#                                $PATH, stdinIsTTY, and test -t 0 exit code
#   --dump-probe <path>          Alias for --probe-file
#   --git-log-1                  Run `git log -1` directly to stdout/stderr (tests terminal pager handling)
#   --git-log-oneline            Alias for --git-log-1
#   --modify-tracked <path>      Append a line to an existing tracked file
#   --cat-stdin                  Run `/bin/cat` reading standard input to stdout
#   --cat-stdin-to <path>        Run `/bin/cat` reading standard input into <path>
#   --stubborn-pid-file <path>   Write the next --spawn-stubborn child's PID to <path>
#   --spawn-stubborn <sec>       Spawn a background child in its own process group (`setpgrp`)
#                                ignoring SIGINT, SIGTERM, and SIGHUP for <sec> seconds
#   --kill-self <sig>            Terminate this process directly via signal <sig> (e.g. 9, TERM)
#   --exit <code>                Exit immediately with status <code>

set -u

now_epoch_ts() {
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time()' </dev/null
}

WORKDIR_REAL="$(pwd -P 2>/dev/null || pwd)"
DEFAULT_CONTEXT_TAG="${STUB_VERIFY_TAG:-${STUB_TRACE_DIR:-${WORKDIR_REAL}}}"
TAG_ARG="stub-verify-tag=${DEFAULT_CONTEXT_TAG}"

TRACE_FILE="${STUB_VERIFY_TRACE:-}"
TRACE_STARTED=0
WAIT_TIMEOUT_SEC="0"
STUBBORN_PID_FILE=""

record_trace_start_if_needed() {
    if [[ -n "$TRACE_FILE" && $TRACE_STARTED -eq 0 ]]; then
        TRACE_STARTED=1
        mkdir -p "$(dirname "$TRACE_FILE")"
        printf 'start %s %s\n' "$(now_epoch_ts)" "$$" >> "$TRACE_FILE"
    fi
}

finish_and_exit() {
    local rc="$1"
    record_trace_start_if_needed
    if [[ -n "$TRACE_FILE" ]]; then
        printf 'end %s %s %s\n' "$(now_epoch_ts)" "$$" "$rc" >> "$TRACE_FILE"
    fi
    exit "$rc"
}

resolve_path() {
    local raw="$1"
    case "$raw" in
        /*) printf '%s' "$raw" ;;
        *)  printf '%s/%s' "$WORKDIR_REAL" "$raw" ;;
    esac
}

emit_repeated_bytes() {
    local count="$1"
    local fill_char="$2"
    local target_stream="$3"
    /usr/bin/python3 -I -c '
import os, sys
n = int(sys.argv[1])
ch = sys.argv[2].encode("ascii")[:1]
fd = 1 if sys.argv[3] == "stdout" else 2
chunk = ch * min(n, 65536) if n > 0 else b""
rem = n
while rem > 0:
    piece = chunk if rem >= len(chunk) else ch * rem
    written = os.write(fd, piece)
    rem -= written
' "$count" "$fill_char" "$target_stream"
}

record_trace_start_if_needed

while [[ $# -gt 0 ]]; do
    opt="$1"
    shift
    case "$opt" in
        --tag)
            [[ $# -ge 1 ]] || { echo "stub-verify: --tag requires a value" >&2; finish_and_exit 2; }
            TAG_ARG="stub-verify-tag=$1--cwd=${WORKDIR_REAL}"
            shift
            ;;
        --trace)
            [[ $# -ge 1 ]] || { echo "stub-verify: --trace requires a path" >&2; finish_and_exit 2; }
            TRACE_FILE="$(resolve_path "$1")"
            shift
            record_trace_start_if_needed
            ;;
        --stdout-bytes)
            [[ $# -ge 1 ]] || { echo "stub-verify: --stdout-bytes requires byte count" >&2; finish_and_exit 2; }
            emit_repeated_bytes "$1" "x" "stdout" || finish_and_exit 2
            shift
            ;;
        --stderr-bytes)
            [[ $# -ge 1 ]] || { echo "stub-verify: --stderr-bytes requires byte count" >&2; finish_and_exit 2; }
            emit_repeated_bytes "$1" "e" "stderr" || finish_and_exit 2
            shift
            ;;
        --stdout-line)
            [[ $# -ge 1 ]] || { echo "stub-verify: --stdout-line requires text" >&2; finish_and_exit 2; }
            printf '%s\n' "$1"
            shift
            ;;
        --stderr-line)
            [[ $# -ge 1 ]] || { echo "stub-verify: --stderr-line requires text" >&2; finish_and_exit 2; }
            printf '%s\n' "$1" >&2
            shift
            ;;
        --write-marker|--marker)
            [[ $# -ge 1 ]] || { echo "stub-verify: ${opt} requires a path" >&2; finish_and_exit 2; }
            marker_p="$(resolve_path "$1")"
            shift
            mkdir -p "$(dirname "$marker_p")" || finish_and_exit 2
            printf 'marker pid=%s ts=%s\n' "$$" "$(now_epoch_ts)" > "$marker_p" || finish_and_exit 2
            ;;
        --wait-timeout)
            [[ $# -ge 1 ]] || { echo "stub-verify: --wait-timeout requires seconds" >&2; finish_and_exit 2; }
            WAIT_TIMEOUT_SEC="$1"
            shift
            ;;
        --wait-barrier|--wait)
            [[ $# -ge 1 ]] || { echo "stub-verify: ${opt} requires a barrier path" >&2; finish_and_exit 2; }
            barrier_p="$(resolve_path "$1")"
            shift
            /usr/bin/perl -MTime::HiRes=time -e '
                my ($p, $limit_s, $tag) = @ARGV;
                my $limit = ($limit_s ne "" ? $limit_s + 0 : 0);
                my $t0 = time();
                while (! -e $p) {
                    if ($limit > 0 && (time() - $t0) >= $limit) { exit 124; }
                    select(undef, undef, undef, 0.02);
                }
            ' "$barrier_p" "$WAIT_TIMEOUT_SEC" "$TAG_ARG" </dev/null
            wrc=$?
            if [[ $wrc -ne 0 ]]; then
                echo "stub-verify: barrier wait timed out for $barrier_p" >&2
                finish_and_exit "$wrc"
            fi
            ;;
        --sleep)
            [[ $# -ge 1 ]] || { echo "stub-verify: --sleep requires seconds" >&2; finish_and_exit 2; }
            sleep_s="$1"
            shift
            /usr/bin/perl -e '
                my ($sec, $tag) = @ARGV;
                select(undef, undef, undef, $sec + 0);
            ' "$sleep_s" "$TAG_ARG" </dev/null
            ;;
        --probe-file|--dump-probe)
            [[ $# -ge 1 ]] || { echo "stub-verify: ${opt} requires output path" >&2; finish_and_exit 2; }
            probe_p="$(resolve_path "$1")"
            shift
            pwd_val="$(pwd -P)"
            head_val="$(/usr/bin/git rev-parse HEAD)" || finish_and_exit 2
            status_val="$(/usr/bin/git status --porcelain)" || finish_and_exit 2
            if test -t 0; then
                t0_rc=0
            else
                t0_rc=$?
            fi
            /usr/bin/python3 -I -c '
import json, os, sys
out_p, pwd_v, head_v, status_v, path_v, t0_rc_s = sys.argv[1:7]
t0_rc = int(t0_rc_s)
parent = os.path.dirname(out_p)
if parent:
    os.makedirs(parent, exist_ok=True)
payload = {
    "pwdP": pwd_v,
    "gitHead": head_v,
    "gitStatusPorcelain": status_v,
    "path": path_v,
    "stdinIsTTY": (t0_rc == 0),
    "testT0ExitCode": t0_rc,
}
with open(out_p, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
' "$probe_p" "$pwd_val" "$head_val" "$status_val" "${PATH:-}" "$t0_rc" || finish_and_exit 2
            ;;
        --git-log-1|--git-log-oneline)
            /usr/bin/git log -1 || finish_and_exit 2
            ;;
        --modify-tracked)
            [[ $# -ge 1 ]] || { echo "stub-verify: --modify-tracked requires a path" >&2; finish_and_exit 2; }
            mod_p="$(resolve_path "$1")"
            shift
            if [[ ! -f "$mod_p" ]]; then
                echo "stub-verify: tracked file does not exist: $mod_p" >&2
                finish_and_exit 2
            fi
            printf 'modified-by-stub-verify\n' >> "$mod_p" || finish_and_exit 2
            ;;
        --cat-stdin)
            /bin/cat || finish_and_exit 2
            ;;
        --cat-stdin-to)
            [[ $# -ge 1 ]] || { echo "stub-verify: --cat-stdin-to requires output path" >&2; finish_and_exit 2; }
            cat_out_p="$(resolve_path "$1")"
            shift
            mkdir -p "$(dirname "$cat_out_p")" || finish_and_exit 2
            /bin/cat > "$cat_out_p" || finish_and_exit 2
            ;;
        --stubborn-pid-file)
            [[ $# -ge 1 ]] || { echo "stub-verify: --stubborn-pid-file requires output path" >&2; finish_and_exit 2; }
            STUBBORN_PID_FILE="$(resolve_path "$1")"
            shift
            ;;
        --spawn-stubborn)
            [[ $# -ge 1 ]] || { echo "stub-verify: --spawn-stubborn requires sleep seconds" >&2; finish_and_exit 2; }
            stubborn_sec="$1"
            shift
            sync_tmp="${TMPDIR:-/tmp}"
            sync_tmp="${sync_tmp%/}/stub-verify-ready.$$.${RANDOM}"
            rm -f "$sync_tmp"
            if [[ -n "$STUBBORN_PID_FILE" ]]; then
                mkdir -p "$(dirname "$STUBBORN_PID_FILE")" || finish_and_exit 2
            fi
            /usr/bin/perl -MPOSIX -e '
                my ($sec, $pid_file, $sync_file, $tag) = @ARGV;
                POSIX::setpgid(0, 0) or die "setpgid: $!";
                $SIG{INT} = "IGNORE";
                $SIG{TERM} = "IGNORE";
                $SIG{HUP} = "IGNORE";
                if ($pid_file ne "") {
                    open(my $pf, ">", "$pid_file.tmp.$$") or die "pf: $!";
                    print $pf "$$\n";
                    close($pf);
                    rename("$pid_file.tmp.$$", $pid_file) or die "ren: $!";
                }
                open(my $sf, ">", $sync_file) or die "sf: $!";
                print $sf "$$\n";
                close($sf);
                select(undef, undef, undef, $sec + 0);
            ' "$stubborn_sec" "$STUBBORN_PID_FILE" "$sync_tmp" "$TAG_ARG" </dev/null >/dev/null 2>&1 &
            stubborn_pid=$!
            STUBBORN_PID_FILE=""
            /usr/bin/perl -MTime::HiRes=time -e '
                my ($sf, $cpid) = @ARGV;
                my $t0 = time();
                while (! -e $sf) {
                    my $k = kill 0, $cpid;
                    if (!$k) { exit 1; }
                    if ((time() - $t0) >= 5.0) { exit 2; }
                    select(undef, undef, undef, 0.01);
                }
                unlink($sf);
            ' "$sync_tmp" "$stubborn_pid" </dev/null || {
                rm -f "$sync_tmp"
                echo "stub-verify: failed to synchronize stubborn child startup" >&2
                finish_and_exit 2
            }
            ;;
        --kill-self)
            [[ $# -ge 1 ]] || { echo "stub-verify: --kill-self requires signal" >&2; finish_and_exit 2; }
            sig_tok="$1"
            shift
            record_trace_start_if_needed
            exec /usr/bin/perl -MPOSIX -e '
                my $s = shift;
                $s =~ s/^SIG//i;
                my $empty = POSIX::SigSet->new();
                POSIX::sigprocmask(SIG_SETMASK, $empty);
                $SIG{INT} = $SIG{TERM} = $SIG{HUP} = $SIG{QUIT} = $SIG{ALRM} = "DEFAULT";
                kill $s, $$;
                sleep 1;
            ' "$sig_tok"
            ;;
        --exit)
            [[ $# -ge 1 ]] || { echo "stub-verify: --exit requires exit code" >&2; finish_and_exit 2; }
            rc_tok="$1"
            shift
            finish_and_exit "$rc_tok"
            ;;
        *)
            echo "stub-verify: unknown option '$opt'" >&2
            finish_and_exit 2
            ;;
    esac
done

finish_and_exit 0
