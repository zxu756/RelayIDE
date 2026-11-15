#!/usr/bin/env bash
# Deterministic test double for unit tests of RelayPTYCore and downstream runners.
# Never invokes any external coding agent CLI.
#
# Supported options (CLI flags override FAKE_RELAY_* environment variables):
#   --exit <code>             Exit with integer status <code> (default: 0)
#   --sleep <seconds>         Sleep <seconds> before exiting or self-signaling
#   --kill-self <signal>      Terminate this process via <signal> (e.g. KILL, TERM, INT, 9, 15, 2)
#   --relay-message <text>    Print "relay: <text>" to stderr
#   --stdout <text>           Print "<text>" to stdout
#   --repeat-bytes <count>    Emit <count> deterministic ASCII bytes to stdout
#   --ready-file <path>       Create <path> once traps and helper children are armed
#   --child-pid-file <path>   Spawn a SIGHUP-ignoring child in the same process group and record its PID
#   --slow-term <seconds>     Catch SIGTERM, sleep <seconds>, then re-raise SIGTERM with SIG_DFL
#
# Positional arguments (such as <agent> <workdir> <prompt-file>) are accepted so callers that
# invoke a relay-shaped command line can drive behaviour through FAKE_RELAY_* variables too.

set -u

EXIT_CODE="${FAKE_RELAY_EXIT:-0}"
SLEEP_SECONDS="${FAKE_RELAY_SLEEP:-0}"
KILL_SELF_SIGNAL="${FAKE_RELAY_KILL_SELF:-}"
RELAY_MESSAGE="${FAKE_RELAY_MESSAGE:-}"
STDOUT_TEXT="${FAKE_RELAY_STDOUT:-}"
REPEAT_BYTES="${FAKE_RELAY_REPEAT_BYTES:-0}"
READY_FILE="${FAKE_RELAY_READY_FILE:-}"
CHILD_PID_FILE="${FAKE_RELAY_CHILD_PID_FILE:-}"
SLOW_TERM_SECONDS="${FAKE_RELAY_SLOW_TERM:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --exit)
            EXIT_CODE="${2:?missing value for --exit}"
            shift 2
            ;;
        --sleep)
            SLEEP_SECONDS="${2:?missing value for --sleep}"
            shift 2
            ;;
        --kill-self)
            KILL_SELF_SIGNAL="${2:?missing value for --kill-self}"
            shift 2
            ;;
        --relay-message|--print-relay)
            RELAY_MESSAGE="${2:?missing value for --relay-message}"
            shift 2
            ;;
        --stdout)
            STDOUT_TEXT="${2:?missing value for --stdout}"
            shift 2
            ;;
        --repeat-bytes)
            REPEAT_BYTES="${2:?missing value for --repeat-bytes}"
            shift 2
            ;;
        --ready-file)
            READY_FILE="${2:?missing value for --ready-file}"
            shift 2
            ;;
        --child-pid-file)
            CHILD_PID_FILE="${2:?missing value for --child-pid-file}"
            shift 2
            ;;
        --slow-term)
            SLOW_TERM_SECONDS="${2:?missing value for --slow-term}"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            shift
            ;;
    esac
done

die_by_signal() {
    local sig="$1"
    exec /usr/bin/perl -MPOSIX -e '
        my $s = shift;
        $s =~ s/^SIG//i;
        my $empty = POSIX::SigSet->new();
        POSIX::sigprocmask(SIG_SETMASK, $empty);
        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = $SIG{QUIT} = $SIG{ALRM} = "DEFAULT";
        kill $s, $$;
        sleep 1;
    ' "${sig}"
}

if [[ -n "${SLOW_TERM_SECONDS}" ]]; then
    trap 'sleep "'"${SLOW_TERM_SECONDS}"'"; die_by_signal TERM' TERM
fi

if [[ -n "${CHILD_PID_FILE}" ]]; then
    (
        trap '' HUP
        exec /bin/sleep 30 >/dev/null 2>&1 </dev/null
    ) &
    printf '%s\n' "$!" > "${CHILD_PID_FILE}"
fi

if [[ -n "${RELAY_MESSAGE}" ]]; then
    printf 'relay: %s\n' "${RELAY_MESSAGE}" >&2
fi

if [[ -n "${STDOUT_TEXT}" ]]; then
    printf '%s\n' "${STDOUT_TEXT}"
fi

if [[ "${REPEAT_BYTES}" -gt 0 ]] 2>/dev/null; then
    /usr/bin/python3 -I -c '
import sys
n = int(sys.argv[1])
block = b"0123456789abcdef" * 256
rem = n
out = sys.stdout.buffer
while rem > 0:
    chunk = block[:rem] if rem < len(block) else block
    out.write(chunk)
    rem -= len(chunk)
out.flush()
' "${REPEAT_BYTES}"
fi

if [[ -n "${READY_FILE}" ]]; then
    : > "${READY_FILE}"
fi

if [[ "${SLEEP_SECONDS}" != "0" && -n "${SLEEP_SECONDS}" ]]; then
    if [[ -n "${SLOW_TERM_SECONDS}" || -n "${CHILD_PID_FILE}" ]]; then
        /bin/sleep "${SLEEP_SECONDS}" &
        SLEEP_BG_PID=$!
        wait "${SLEEP_BG_PID}" 2>/dev/null || true
    else
        /bin/sleep "${SLEEP_SECONDS}"
    fi
fi

if [[ -n "${KILL_SELF_SIGNAL}" ]]; then
    die_by_signal "${KILL_SELF_SIGNAL}"
fi

exit "${EXIT_CODE}"
