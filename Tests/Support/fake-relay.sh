#!/usr/bin/env bash
# Deterministic test double for unit tests of RelayPTYCore and RelayIDE `run` scheduling.
# Never invokes the real relay.sh or any external coding agent CLI.
#
# Mode 1 — Flag / env-driven PTY session tests (CLI flags override FAKE_RELAY_* env vars):
#   --exit <code>             Exit with integer status <code> (default: 0)
#   --sleep <seconds>         Sleep <seconds> before exiting or self-signaling
#   --kill-self <signal>      Terminate this process via <signal> (e.g. KILL, TERM, INT, 9, 15, 2)
#   --relay-message <text>    Print "relay: <text>" to stderr
#   --stdout <text>           Print "<text>" to stdout
#   --repeat-bytes <count>    Emit <count> deterministic ASCII bytes to stdout
#   --ready-file <path>       Create <path> once traps and helper children are armed
#   --child-pid-file <path>   Spawn a SIGHUP-ignoring child in the same process group and record its PID
#   --subgroup-pid-file <p>   Spawn a SIGHUP/SIGINT/SIGTERM-ignoring child in its own process group (setpgid)
#   --ignore-int              Ignore SIGINT (logging "INT" to --signal-log if set)
#   --ignore-term             Ignore SIGTERM (logging "TERM" to --signal-log if set)
#   --signal-log <path>       Append received signal names ("INT", "TERM") one per line
#   --slow-term <seconds>     Catch SIGTERM, sleep <seconds>, then re-raise SIGTERM with SIG_DFL
#
# Mode 2 — Relay step invocation `<fake-relay.sh> <agent> <workdir> <prompt-file>` (when invoked with
# 3 positional arguments, no `--*` flags, and no `FAKE_RELAY_*` overrides):
#   Reads deterministic `STUB ...` and `FAKE_RELAY ...` directives from `<prompt-file>`, operates
#   inside `<workdir>`, writes a realistic `<workdir>/.relay/LOG.md` step entry (unless suppressed),
#   records `$STUB_TRACE_DIR/<lane>.trace` timestamps when `STUB_TRACE_DIR` is set, and exits with
#   `relay.sh`-compatible exit codes (0, 2, 5, 124, N, or signal death).

set -u

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

now_epoch_ts() {
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time()' < /dev/null
}

HAS_FAKE_ENV=0
if [[ -n "${FAKE_RELAY_EXIT:-}" || -n "${FAKE_RELAY_SLEEP:-}" || -n "${FAKE_RELAY_KILL_SELF:-}" || \
      -n "${FAKE_RELAY_MESSAGE:-}" || -n "${FAKE_RELAY_STDOUT:-}" || -n "${FAKE_RELAY_REPEAT_BYTES:-}" || \
      -n "${FAKE_RELAY_READY_FILE:-}" || -n "${FAKE_RELAY_CHILD_PID_FILE:-}" || -n "${FAKE_RELAY_SLOW_TERM:-}" || \
      -n "${FAKE_RELAY_IGNORE_INT:-}" || -n "${FAKE_RELAY_IGNORE_TERM:-}" || -n "${FAKE_RELAY_SIGNAL_LOG:-}" || \
      -n "${FAKE_RELAY_SUBGROUP_PID_FILE:-}" ]]; then
    HAS_FAKE_ENV=1
fi

HAS_DASH_FLAG=0
for arg in "$@"; do
    case "$arg" in
        -*)
            HAS_DASH_FLAG=1
            break
            ;;
    esac
done

# Enter Mode 2 when invoked as `<fake-relay.sh> <agent> <workdir> <prompt-file>` without Mode 1 overrides.
if [[ $HAS_FAKE_ENV -eq 0 && $HAS_DASH_FLAG -eq 0 && $# -eq 3 && -f "$3" ]]; then
    AGENT="$1"
    WORKDIR="$2"
    PROMPT_FILE="$3"

    if [[ -n "${RELAY_WORKER:-}" ]]; then
        printf 'relay: refusing to start a relay step from inside a relay worker (RELAY_WORKER=%s)\n' "${RELAY_WORKER}" >&2
        exit 2
    fi

    case "$AGENT" in
        claude|codex|agy|vibe) ;;
        *)
            printf 'relay: unknown agent: %s\n' "$AGENT" >&2
            exit 2
            ;;
    esac

    if [[ ! -d "$WORKDIR" ]]; then
        printf 'relay: workdir does not exist: %s\n' "$WORKDIR" >&2
        exit 2
    fi

    cd "$WORKDIR" || exit 2
    WORKDIR="$(pwd -P)"
    LANE_NAME="${STUB_LANE:-$(basename "$WORKDIR")}"
    START_TS="$(now_epoch_ts)"
    PROMPT_TEXT="$(cat "$PROMPT_FILE"; printf x)"
    PROMPT_TEXT="${PROMPT_TEXT%x}"

    # Pre-scan for `STUB LANE <id>` outside WRITE_BLOCK regions.
    PRE_IN_BLOCK=0
    PRE_EOF=""
    while IFS= read -r -u 3 pre_raw || [[ -n "$pre_raw" ]]; do
        pre_line="${pre_raw%$'\r'}"
        if [[ $PRE_IN_BLOCK -eq 1 ]]; then
            [[ "$pre_line" == "$PRE_EOF" ]] && PRE_IN_BLOCK=0
            continue
        fi
        case "$pre_line" in
            "STUB "*|"STUB	"*)
                pre_rest="${pre_line#STUB}"
                pre_rest="${pre_rest#"${pre_rest%%[![:space:]]*}"}"
                pre_cmd="$(printf '%s' "${pre_rest%%[[:space:]]*}" | tr '[:lower:]' '[:upper:]')"
                pre_arg="${pre_rest#"${pre_rest%%[[:space:]]*}"}"
                pre_arg="${pre_arg#"${pre_arg%%[![:space:]]*}"}"
                if [[ "$pre_cmd" == "WRITE_BLOCK" && -n "$pre_arg" ]]; then
                    pre_p="${pre_arg%%[[:space:]]*}"
                    pre_rem="${pre_arg#"$pre_p"}"
                    pre_rem="${pre_rem#"${pre_rem%%[![:space:]]*}"}"
                    pre_eof="${pre_rem%%[[:space:]]*}"
                    [[ -n "$pre_eof" ]] && { PRE_IN_BLOCK=1; PRE_EOF="$pre_eof"; }
                elif [[ "$pre_cmd" == "LANE" && -n "$pre_arg" ]]; then
                    LANE_NAME="${pre_arg%%[[:space:]]*}"
                fi
                ;;
        esac
    done 3<<< "$PROMPT_TEXT"

    START_TRACE_WRITTEN=0
    ensure_start_trace() {
        if [[ $START_TRACE_WRITTEN -eq 0 ]]; then
            START_TRACE_WRITTEN=1
            if [[ -n "${STUB_TRACE_DIR:-}" ]]; then
                mkdir -p "$STUB_TRACE_DIR"
                printf 'start %s %s %s %s\n' "$START_TS" "$$" "$AGENT" "$LANE_NAME" >> "${STUB_TRACE_DIR}/${LANE_NAME}.trace"
            fi
        fi
    }

    write_end_trace() {
        local rc="$1"
        if [[ -n "${STUB_TRACE_DIR:-}" ]]; then
            local end_ts
            end_ts="$(now_epoch_ts)"
            printf 'end %s %s %s %s %s\n' "$end_ts" "$$" "$AGENT" "$LANE_NAME" "$rc" >> "${STUB_TRACE_DIR}/${LANE_NAME}.trace"
        fi
    }

    resolve_path() {
        local raw_p="$1"
        case "$raw_p" in
            /*) printf '%s' "$raw_p" ;;
            *)  printf '%s/%s' "$WORKDIR" "$raw_p" ;;
        esac
    }

    EXPLICIT_COST=""
    EXPLICIT_TOKENS=""
    NO_COST=0
    NO_LOG=0
    WORKER_STATUS="success"
    MESSAGE_BODY=""
    EXIT_CODE=0
    IN_BLOCK=0
    BLOCK_TARGET=""
    BLOCK_EOF=""
    BLOCK_BUF=""
    IGNORE_INT=0
    IGNORE_TERM=0
    SIGNAL_LOG=""
    SUBGROUP_PID_FILE=""
    ARM_READY_FILE=""
    TRACE_TAG="stub-trace-dir=${STUB_TRACE_DIR:-untagged}"

    while IFS= read -r -u 3 raw_line || [[ -n "$raw_line" ]]; do
        line="${raw_line%$'\r'}"
        if [[ $IN_BLOCK -eq 1 ]]; then
            if [[ "$line" == "$BLOCK_EOF" ]]; then
                mkdir -p "$(dirname "$BLOCK_TARGET")"
                printf '%s' "$BLOCK_BUF" > "$BLOCK_TARGET"
                IN_BLOCK=0
                BLOCK_TARGET=""
                BLOCK_EOF=""
                BLOCK_BUF=""
            else
                BLOCK_BUF="${BLOCK_BUF}${line}"$'\n'
            fi
            continue
        fi

        PREFIX_KIND=""
        case "$line" in
            "FAKE_RELAY "*|"FAKE_RELAY	"*)
                PREFIX_KIND="FAKE_RELAY"
                rest="${line#FAKE_RELAY}"
                ;;
            STUB|"STUB "*|"STUB	"*)
                PREFIX_KIND="STUB"
                rest="${line#STUB}"
                ;;
            *)
                continue
                ;;
        esac

        rest="${rest#"${rest%%[![:space:]]*}"}"
        [[ -z "$rest" ]] && continue
        cmd="${rest%%[[:space:]]*}"
        arg_str="${rest#"$cmd"}"
        cmd_upper="$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')"

        case "$cmd_upper" in
            LANE)
                ;;
            REFUSE)
                msg="${arg_str#"${arg_str%%[![:space:]]*}"}"
                printf 'relay: %s\n' "${msg:-not sent: refused by fake-relay}" >&2
                exit 2
                ;;
            WARNING)
                msg="${arg_str#"${arg_str%%[![:space:]]*}"}"
                printf 'relay: warning: %s\n' "$msg" >&2
                ;;
            NO_LOG)
                NO_LOG=1
                ;;
            NO_COST)
                NO_COST=1
                ;;
            IGNORE_INT)
                IGNORE_INT=1
                trap ':' INT
                ;;
            IGNORE_TERM)
                IGNORE_TERM=1
                trap ':' TERM
                ;;
            SIGNAL_LOG)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                if [[ -n "$trimmed" ]]; then
                    SIGNAL_LOG="$(resolve_path "${trimmed%%[[:space:]]*}")"
                    mkdir -p "$(dirname "$SIGNAL_LOG")"
                    trap ':' INT TERM
                fi
                ;;
            ARM_READY)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                if [[ -n "$trimmed" ]]; then
                    ARM_READY_FILE="$(resolve_path "${trimmed%%[[:space:]]*}")"
                    mkdir -p "$(dirname "$ARM_READY_FILE")"
                fi
                ;;
            SUBGROUP_PID_FILE)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                if [[ -n "$trimmed" ]]; then
                    SUBGROUP_PID_FILE="$(resolve_path "${trimmed%%[[:space:]]*}")"
                    mkdir -p "$(dirname "$SUBGROUP_PID_FILE")"
                    /usr/bin/perl -MPOSIX=setpgid -e '
                        my ($pid_file, $tag) = @ARGV;
                        setpgid(0, 0);
                        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "IGNORE";
                        open(my $fh, ">", $pid_file) or die $!;
                        print $fh "$$\n";
                        close($fh);
                        select(undef, undef, undef, 60);
                    ' "$SUBGROUP_PID_FILE" "$TRACE_TAG" </dev/null >/dev/null 2>&1 &
                    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
                        [[ -s "$SUBGROUP_PID_FILE" ]] && break
                        /usr/bin/perl -e 'select(undef, undef, undef, 0.01)' </dev/null
                    done
                fi
                ;;
            TIMEOUT)
                ensure_start_trace
                EXIT_CODE=124
                NO_COST=1
                break
                ;;
            KILL_SELF|KILL_RELAY|SIGNAL)
                ensure_start_trace
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                sig_tok="${trimmed%%[[:space:]]*}"
                [[ -n "$sig_tok" ]] && die_by_signal "$sig_tok"
                ;;
            READY|TOUCH)
                ensure_start_trace
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                if [[ -n "$trimmed" ]]; then
                    ready_p="$(resolve_path "${trimmed%%[[:space:]]*}")"
                    mkdir -p "$(dirname "$ready_p")"
                    : > "$ready_p"
                fi
                ;;
            WRITE)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                [[ -z "$trimmed" ]] && continue
                if [[ "$trimmed" == *[[:space:]]* ]]; then
                    rel_p="${trimmed%%[[:space:]]*}"
                    rem="${trimmed#"$rel_p"}"
                    rem="${rem# }"
                    target_p="$(resolve_path "$rel_p")"
                    mkdir -p "$(dirname "$target_p")"
                    printf '%s\n' "$rem" > "$target_p"
                else
                    target_p="$(resolve_path "$trimmed")"
                    mkdir -p "$(dirname "$target_p")"
                    : > "$target_p"
                fi
                ;;
            APPEND)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                [[ -z "$trimmed" ]] && continue
                if [[ "$trimmed" == *[[:space:]]* ]]; then
                    rel_p="${trimmed%%[[:space:]]*}"
                    rem="${trimmed#"$rel_p"}"
                    rem="${rem# }"
                    target_p="$(resolve_path "$rel_p")"
                    mkdir -p "$(dirname "$target_p")"
                    printf '%s\n' "$rem" >> "$target_p"
                else
                    target_p="$(resolve_path "$trimmed")"
                    mkdir -p "$(dirname "$target_p")"
                    printf '\n' >> "$target_p"
                fi
                ;;
            WRITE_BLOCK)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                [[ -z "$trimmed" ]] && continue
                rel_p="${trimmed%%[[:space:]]*}"
                rem="${trimmed#"$rel_p"}"
                rem="${rem#"${rem%%[![:space:]]*}"}"
                eof_tok="${rem%%[[:space:]]*}"
                if [[ -n "$rel_p" && -n "$eof_tok" ]]; then
                    IN_BLOCK=1
                    BLOCK_TARGET="$(resolve_path "$rel_p")"
                    BLOCK_EOF="$eof_tok"
                    BLOCK_BUF=""
                fi
                ;;
            SLEEP)
                ensure_start_trace
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                sleep_sec="${trimmed%%[[:space:]]*}"
                if [[ -n "$sleep_sec" ]]; then
                    /usr/bin/perl -MTime::HiRes=time -e '
                        my ($sec, $ig_int, $ig_term, $sig_log, $arm_ready, $tag) = @ARGV;
                        sub log_sig {
                            my ($name) = @_;
                            return unless defined($sig_log) && $sig_log ne "";
                            if (open(my $fh, ">>", $sig_log)) {
                                select((select($fh), $| = 1)[0]);
                                print $fh "$name\n";
                                close($fh);
                            }
                        }
                        if ($ig_int) {
                            $SIG{INT} = sub { log_sig("INT"); };
                        } elsif (defined($sig_log) && $sig_log ne "") {
                            $SIG{INT} = sub { log_sig("INT"); $SIG{INT} = "DEFAULT"; kill "INT", $$; };
                        }
                        if ($ig_term) {
                            $SIG{TERM} = sub { log_sig("TERM"); };
                        } elsif (defined($sig_log) && $sig_log ne "") {
                            $SIG{TERM} = sub { log_sig("TERM"); $SIG{TERM} = "DEFAULT"; kill "TERM", $$; };
                        }
                        if (defined($arm_ready) && $arm_ready ne "") {
                            if (open(my $rf, ">", $arm_ready)) { close($rf); }
                        }
                        my $deadline = time() + ($sec + 0);
                        while (1) {
                            my $rem = $deadline - time();
                            last if $rem <= 0;
                            select(undef, undef, undef, $rem > 0.05 ? 0.05 : $rem);
                        }
                    ' "$sleep_sec" "$IGNORE_INT" "$IGNORE_TERM" "$SIGNAL_LOG" "$ARM_READY_FILE" "$TRACE_TAG" < /dev/null
                    sleep_rc=$?
                    ARM_READY_FILE=""
                    if [[ $sleep_rc -eq 130 && $IGNORE_INT -eq 0 ]]; then
                        die_by_signal INT
                    elif [[ $sleep_rc -eq 143 && $IGNORE_TERM -eq 0 ]]; then
                        die_by_signal TERM
                    elif [[ $sleep_rc -eq 129 ]]; then
                        die_by_signal HUP
                    fi
                fi
                ;;
            WAIT|WAIT_FILE|BARRIER)
                ensure_start_trace
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                [[ -z "$trimmed" ]] && continue
                wait_raw="${trimmed%%[[:space:]]*}"
                rem="${trimmed#"$wait_raw"}"
                rem="${rem#"${rem%%[![:space:]]*}"}"
                wait_timeout="${rem%%[[:space:]]*}"
                wait_target="$(resolve_path "$wait_raw")"
                /usr/bin/perl -MTime::HiRes=time -e '
                    my ($p, $t, $ig_int, $ig_term, $sig_log, $arm_ready, $tag) = @ARGV;
                    sub log_sig {
                        my ($name) = @_;
                        return unless defined($sig_log) && $sig_log ne "";
                        if (open(my $fh, ">>", $sig_log)) {
                            select((select($fh), $| = 1)[0]);
                            print $fh "$name\n";
                            close($fh);
                        }
                    }
                    if ($ig_int) {
                        $SIG{INT} = sub { log_sig("INT"); };
                    } elsif (defined($sig_log) && $sig_log ne "") {
                        $SIG{INT} = sub { log_sig("INT"); $SIG{INT} = "DEFAULT"; kill "INT", $$; };
                    }
                    if ($ig_term) {
                        $SIG{TERM} = sub { log_sig("TERM"); };
                    } elsif (defined($sig_log) && $sig_log ne "") {
                        $SIG{TERM} = sub { log_sig("TERM"); $SIG{TERM} = "DEFAULT"; kill "TERM", $$; };
                    }
                    if (defined($arm_ready) && $arm_ready ne "") {
                        if (open(my $rf, ">", $arm_ready)) { close($rf); }
                    }
                    my $limit = ($t ne "" ? $t + 0 : 0);
                    my $t0 = time();
                    while (! -e $p) {
                        if ($limit > 0 && (time() - $t0) >= $limit) { exit 124; }
                        select(undef, undef, undef, 0.02);
                    }
                ' "$wait_target" "${wait_timeout:-0}" "$IGNORE_INT" "$IGNORE_TERM" "$SIGNAL_LOG" "$ARM_READY_FILE" "$TRACE_TAG" < /dev/null
                wait_rc=$?
                ARM_READY_FILE=""
                if [[ $wait_rc -eq 130 && $IGNORE_INT -eq 0 ]]; then
                    die_by_signal INT
                elif [[ $wait_rc -eq 143 && $IGNORE_TERM -eq 0 ]]; then
                    die_by_signal TERM
                elif [[ $wait_rc -eq 129 ]]; then
                    die_by_signal HUP
                elif [[ $wait_rc -ne 0 ]]; then
                    EXIT_CODE="$wait_rc"
                    NO_COST=1
                    break
                fi
                ;;
            GIT_COMMIT)
                msg="${arg_str#"${arg_str%%[![:space:]]*}"}"
                /usr/bin/git add -A -- . >/dev/null 2>&1 || true
                /usr/bin/git reset -q HEAD -- .relay >/dev/null 2>&1 || true
                /usr/bin/git -c user.useConfigOnly=true -c commit.gpgsign=false commit --no-verify -m "${msg:-agent commit}" >/dev/null 2>&1 || true
                ;;
            COST)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                [[ -n "$trimmed" ]] && EXPLICIT_COST="${trimmed%%[[:space:]]*}"
                ;;
            TOKENS)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                if [[ -n "$trimmed" ]]; then
                    tok_raw="${trimmed%%[[:space:]]*}"
                    EXPLICIT_TOKENS="${tok_raw//,/}"
                fi
                ;;
            STATUS|STATUS:)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                trimmed="${trimmed#:}"
                trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
                if [[ -n "$trimmed" ]]; then
                    WORKER_STATUS="$(printf '%s' "${trimmed%%[[:space:]]*}" | tr '[:upper:]' '[:lower:]')"
                fi
                ;;
            MESSAGE)
                MESSAGE_BODY="${arg_str# }"
                ;;
            EXIT)
                trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                EXIT_CODE="${trimmed%%[[:space:]]*}"
                EXIT_CODE="${EXIT_CODE:-0}"
                if [[ "$EXIT_CODE" != "0" ]]; then
                    NO_COST=1
                    break
                fi
                ;;
        esac
    done 3<<< "$PROMPT_TEXT"

    ensure_start_trace

    RC="$EXIT_CODE"
    if [[ "$RC" -eq 0 ]]; then
        if [[ "$WORKER_STATUS" == "partial" ]]; then
            RC=5
        elif [[ "$WORKER_STATUS" == "failed" ]]; then
            RC=1
        fi
    fi

    case "$RC" in
        0) STATUS_TEXT="ok" ;;
        5) STATUS_TEXT="partial (the worker reported STATUS: partial)" ;;
        124) STATUS_TEXT="timeout after 2s" ;;
        *) STATUS_TEXT="failed (exit $RC)" ;;
    esac

    if [[ $NO_COST -eq 1 ]]; then
        META_LINE="${AGENT}: model ?, cost \$?"
    elif [[ -n "$EXPLICIT_COST" ]]; then
        FMT_COST="$(awk -v c="$EXPLICIT_COST" 'BEGIN { printf "%.4f", c }')"
        META_LINE="${AGENT}: model fake-${AGENT}, cost \$${FMT_COST}"
    elif [[ -n "$EXPLICIT_TOKENS" ]]; then
        FMT_TOK="$(/usr/bin/python3 -I -c 'import sys; print("{:,}".format(int(sys.argv[1])))' "$EXPLICIT_TOKENS")"
        META_LINE="${AGENT}: model fake-${AGENT}, tokens ${FMT_TOK}"
    elif [[ "$AGENT" == "claude" || "$AGENT" == "vibe" ]]; then
        META_LINE="${AGENT}: model fake-${AGENT}, cost \$0.0010"
    else
        META_LINE="${AGENT}: model fake-${AGENT}, tokens 1,200"
    fi

    FINAL_BODY="${MESSAGE_BODY:-Fake relay (${AGENT}) completed lane ${LANE_NAME}.}"
    STEP_TS="$(date -u '+%Y-%m-%d %H:%M')"

    if /usr/bin/git -C "${WORKDIR}" rev-parse --git-dir >/dev/null 2>&1; then
        EX_PATH="$(/usr/bin/git -C "${WORKDIR}" rev-parse --git-path info/exclude 2>/dev/null || true)"
        if [[ -n "${EX_PATH}" ]]; then
            case "${EX_PATH}" in /*) ;; *) EX_PATH="${WORKDIR}/${EX_PATH}" ;; esac
            mkdir -p "$(dirname "${EX_PATH}")"
            grep -qx '.relay/' "${EX_PATH}" 2>/dev/null || echo '.relay/' >> "${EX_PATH}"
        fi
    fi

    if [[ $NO_LOG -eq 0 ]]; then
        mkdir -p "${WORKDIR}/.relay"
        {
            printf '## 01-%s: %s, 1s, %s\n\n' "$AGENT" "$STATUS_TEXT" "$STEP_TS"
            printf -- '- prompt: .relay/01-%s.prompt.md, log: .relay/01-%s.log\n' "$AGENT" "$AGENT"
            printf -- '- %s\n' "$META_LINE"
            printf -- '- files changed:\n  - (recorded)\n'
            printf -- '- final message:\n\n'
            if [[ "$RC" -eq 0 || "$RC" -eq 5 ]]; then
                printf '> %s\n> STATUS: %s\n\n' "$FINAL_BODY" "$WORKER_STATUS"
            else
                printf '> (empty; see the log)\n\n'
            fi
        } >> "${WORKDIR}/.relay/LOG.md"
    fi

    printf 'relay 01-%s: %s in 1s; files changed: 0; %s\n' "$AGENT" "$STATUS_TEXT" "$META_LINE"
    if [[ "$RC" -eq 0 || "$RC" -eq 5 ]]; then
        printf '%s\nSTATUS: %s\n' "$FINAL_BODY" "$WORKER_STATUS"
    fi

    write_end_trace "$RC"
    exit "$RC"
fi

# Mode 1 — Flag / env-driven PTY session behavior
EXIT_CODE="${FAKE_RELAY_EXIT:-0}"
SLEEP_SECONDS="${FAKE_RELAY_SLEEP:-0}"
KILL_SELF_SIGNAL="${FAKE_RELAY_KILL_SELF:-}"
RELAY_MESSAGE="${FAKE_RELAY_MESSAGE:-}"
STDOUT_TEXT="${FAKE_RELAY_STDOUT:-}"
REPEAT_BYTES="${FAKE_RELAY_REPEAT_BYTES:-0}"
READY_FILE="${FAKE_RELAY_READY_FILE:-}"
CHILD_PID_FILE="${FAKE_RELAY_CHILD_PID_FILE:-}"
SUBGROUP_PID_FILE="${FAKE_RELAY_SUBGROUP_PID_FILE:-}"
IGNORE_INT="${FAKE_RELAY_IGNORE_INT:-0}"
IGNORE_TERM="${FAKE_RELAY_IGNORE_TERM:-0}"
SIGNAL_LOG="${FAKE_RELAY_SIGNAL_LOG:-}"
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
        --subgroup-pid-file)
            SUBGROUP_PID_FILE="${2:?missing value for --subgroup-pid-file}"
            shift 2
            ;;
        --ignore-int)
            IGNORE_INT=1
            shift
            ;;
        --ignore-term)
            IGNORE_TERM=1
            shift
            ;;
        --signal-log)
            SIGNAL_LOG="${2:?missing value for --signal-log}"
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

if [[ -n "${SUBGROUP_PID_FILE}" ]]; then
    mkdir -p "$(dirname "${SUBGROUP_PID_FILE}")"
    /usr/bin/perl -MPOSIX=setpgid -e '
        my ($pid_file) = @ARGV;
        setpgid(0, 0);
        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = "IGNORE";
        open(my $fh, ">", $pid_file) or die $!;
        print $fh "$$\n";
        close($fh);
        select(undef, undef, undef, 60);
    ' "${SUBGROUP_PID_FILE}" </dev/null >/dev/null 2>&1 &
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40; do
        [[ -s "${SUBGROUP_PID_FILE}" ]] && break
        /usr/bin/perl -e 'select(undef, undef, undef, 0.01)' </dev/null
    done
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

if [[ "${IGNORE_INT}" == "1" || "${IGNORE_TERM}" == "1" || -n "${SIGNAL_LOG}" ]]; then
    [[ -n "${SIGNAL_LOG}" ]] && mkdir -p "$(dirname "${SIGNAL_LOG}")"
    exec /usr/bin/perl -MPOSIX -MTime::HiRes=time -e '
        my ($sleep_sec, $ig_int, $ig_term, $sig_log, $ready_file, $kill_sig, $exit_code) = @ARGV;
        sub log_sig {
            my ($name) = @_;
            return unless defined($sig_log) && $sig_log ne "";
            if (open(my $fh, ">>", $sig_log)) {
                select((select($fh), $| = 1)[0]);
                print $fh "$name\n";
                close($fh);
            }
        }
        if ($ig_int) {
            $SIG{INT} = sub { log_sig("INT"); };
        } else {
            $SIG{INT} = sub { log_sig("INT"); $SIG{INT} = "DEFAULT"; kill "INT", $$; };
        }
        if ($ig_term) {
            $SIG{TERM} = sub { log_sig("TERM"); };
        } else {
            $SIG{TERM} = sub { log_sig("TERM"); $SIG{TERM} = "DEFAULT"; kill "TERM", $$; };
        }
        if (defined($ready_file) && $ready_file ne "") {
            if (open(my $rf, ">", $ready_file)) { close($rf); }
        }
        if (defined($sleep_sec) && ($sleep_sec + 0) > 0) {
            my $deadline = time() + ($sleep_sec + 0);
            while (1) {
                my $rem = $deadline - time();
                last if $rem <= 0;
                select(undef, undef, undef, $rem > 0.05 ? 0.05 : $rem);
            }
        }
        if (defined($kill_sig) && $kill_sig ne "") {
            $kill_sig =~ s/^SIG//i;
            $SIG{INT} = $SIG{TERM} = $SIG{HUP} = $SIG{QUIT} = $SIG{ALRM} = "DEFAULT";
            kill $kill_sig, $$;
            sleep 1;
        }
        exit($exit_code + 0);
    ' "${SLEEP_SECONDS}" "${IGNORE_INT}" "${IGNORE_TERM}" "${SIGNAL_LOG}" "${READY_FILE}" "${KILL_SELF_SIGNAL}" "${EXIT_CODE}"
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
