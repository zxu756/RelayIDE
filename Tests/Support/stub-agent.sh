#!/usr/bin/env bash
# Deterministic test-double coding agent CLI for RelayIDE tests and acceptance harnesses.
# Recognizes vendor argv shapes (claude, codex, agy, vibe), executes STUB directives from the prompt,
# and records start/end timestamps + PIDs under $STUB_TRACE_DIR/<lane>.trace when STUB_TRACE_DIR is set.
# Never invokes any real external coding agent CLI or network endpoint.

set -u

now_epoch_ts() {
    /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time()' < /dev/null
}

START_TS="$(now_epoch_ts)"

if [[ "${1:-}" == "--version" || "${1:-}" == "-V" ]]; then
    echo "stub-agent 1.0.0"
    exit 0
fi
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
    echo "Logged in (stub-agent)"
    exit 0
fi
if [[ "${1:-}" == "features" && "${2:-}" == "list" ]]; then
    exit 0
fi

VENDOR=""
WORKDIR="$PWD"
PROMPT_TEXT=""
PROMPT_FILE=""
CODEX_OUT_FILE=""
VIBE_OUTPUT_DIR=""
REQ_MODEL=""
CLI_BUDGET_CAP=""

ARGS=("$@")
NARGS=${#ARGS[@]}

# 1. Classify vendor from argv shape.
for (( i=0; i<NARGS; i++ )); do
    arg="${ARGS[$i]}"
    case "$arg" in
        --permission-mode|--permission-mode=*|--max-budget-usd|--max-budget-usd=*)
            VENDOR="claude"
            break
            ;;
        --mode|--mode=*|--settings|--settings=*)
            VENDOR="agy"
            break
            ;;
        --prompt-file|--prompt-file=*|--output-dir|--output-dir=*|--workdir|--workdir=*|--trust)
            VENDOR="vibe"
            break
            ;;
        --skip-git-repo-check|-o|--output-last-message)
            VENDOR="codex"
            break
            ;;
    esac
done

if [[ -z "$VENDOR" && $NARGS -gt 0 && "${ARGS[0]}" == "exec" ]]; then
    VENDOR="codex"
fi

if [[ -z "$VENDOR" ]]; then
    for (( i=0; i<NARGS; i++ )); do
        if [[ "${ARGS[$i]}" == "-p" ]]; then
            next_i=$(( i + 1 ))
            if [[ $next_i -ge $NARGS || "${ARGS[$next_i]}" == "--output-format" || "${ARGS[$next_i]}" == "--model" ]]; then
                VENDOR="claude"
            else
                VENDOR="agy"
            fi
            break
        fi
    done
fi

if [[ -z "$VENDOR" ]]; then
    echo "stub-agent: unrecognized argv shape: $*" >&2
    exit 2
fi

# 2. Extract vendor-specific options.
case "$VENDOR" in
    claude)
        for (( i=0; i<NARGS; i++ )); do
            case "${ARGS[$i]}" in
                --model)
                    (( i + 1 < NARGS )) && { REQ_MODEL="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                --model=*)
                    REQ_MODEL="${ARGS[$i]#--model=}"
                    ;;
                --max-budget-usd)
                    (( i + 1 < NARGS )) && { CLI_BUDGET_CAP="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                --max-budget-usd=*)
                    CLI_BUDGET_CAP="${ARGS[$i]#--max-budget-usd=}"
                    ;;
            esac
        done
        PROMPT_TEXT="$(cat; printf x)"
        PROMPT_TEXT="${PROMPT_TEXT%x}"
        ;;
    codex)
        for (( i=0; i<NARGS; i++ )); do
            case "${ARGS[$i]}" in
                -C)
                    (( i + 1 < NARGS )) && { WORKDIR="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                -o|--output-last-message)
                    (( i + 1 < NARGS )) && { CODEX_OUT_FILE="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
            esac
        done
        PROMPT_TEXT="$(cat; printf x)"
        PROMPT_TEXT="${PROMPT_TEXT%x}"
        ;;
    agy)
        for (( i=0; i<NARGS; i++ )); do
            case "${ARGS[$i]}" in
                -p)
                    (( i + 1 < NARGS )) && { PROMPT_TEXT="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                --model)
                    (( i + 1 < NARGS )) && { REQ_MODEL="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                --model=*)
                    REQ_MODEL="${ARGS[$i]#--model=}"
                    ;;
            esac
        done
        ;;
    vibe)
        for (( i=0; i<NARGS; i++ )); do
            case "${ARGS[$i]}" in
                --workdir)
                    (( i + 1 < NARGS )) && { WORKDIR="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                --workdir=*)
                    WORKDIR="${ARGS[$i]#--workdir=}"
                    ;;
                --prompt-file)
                    (( i + 1 < NARGS )) && { PROMPT_FILE="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                --prompt-file=*)
                    PROMPT_FILE="${ARGS[$i]#--prompt-file=}"
                    ;;
                --output-dir)
                    (( i + 1 < NARGS )) && { VIBE_OUTPUT_DIR="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                --output-dir=*)
                    VIBE_OUTPUT_DIR="${ARGS[$i]#--output-dir=}"
                    ;;
                --max-price)
                    (( i + 1 < NARGS )) && { CLI_BUDGET_CAP="${ARGS[$((i+1))]}"; i=$((i+1)); }
                    ;;
                --max-price=*)
                    CLI_BUDGET_CAP="${ARGS[$i]#--max-price=}"
                    ;;
            esac
        done
        if [[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]]; then
            PROMPT_TEXT="$(cat "$PROMPT_FILE"; printf x)"
            PROMPT_TEXT="${PROMPT_TEXT%x}"
        fi
        ;;
esac

if [[ -d "$WORKDIR" ]]; then
    cd "$WORKDIR" || exit 2
    WORKDIR="$(pwd -P)"
fi

LANE_NAME="${STUB_LANE:-$(basename "$WORKDIR")}"

# Pre-scan for `STUB LANE <id>` outside WRITE_BLOCK regions so trace filename is settled before start trace.
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
                if [[ -n "$pre_eof" ]]; then
                    PRE_IN_BLOCK=1
                    PRE_EOF="$pre_eof"
                fi
            elif [[ "$pre_cmd" == "LANE" && -n "$pre_arg" ]]; then
                LANE_NAME="${pre_arg%%[[:space:]]*}"
            fi
            ;;
    esac
done 3<<< "$PROMPT_TEXT"

START_TRACE_WRITTEN=0

ensure_start_trace_written() {
    if [[ $START_TRACE_WRITTEN -eq 0 ]]; then
        START_TRACE_WRITTEN=1
        if [[ -n "${STUB_TRACE_DIR:-}" ]]; then
            mkdir -p "$STUB_TRACE_DIR"
            printf 'start %s %s %s %s\n' "$START_TS" "$$" "$VENDOR" "$LANE_NAME" >> "${STUB_TRACE_DIR}/${LANE_NAME}.trace"
            if [[ -n "${RELAY_BUDGET_USD:-}" || -n "${CLI_BUDGET_CAP:-}" ]]; then
                printf 'RELAY_BUDGET_USD=%s\nCLI_BUDGET_CAP=%s\n' "${RELAY_BUDGET_USD:-}" "${CLI_BUDGET_CAP:-}" > "${STUB_TRACE_DIR}/${LANE_NAME}.budget"
            fi
        fi
    fi
}

resolve_target_path() {
    local raw_p="$1"
    case "$raw_p" in
        /*) printf '%s' "$raw_p" ;;
        *)  printf '%s/%s' "$WORKDIR" "$raw_p" ;;
    esac
}

die_by_signal() {
    local sig="$1"
    ensure_start_trace_written
    exec /usr/bin/perl -MPOSIX -e '
        my $s = shift;
        $s =~ s/^SIG//i;
        my $empty = POSIX::SigSet->new();
        POSIX::sigprocmask(SIG_SETMASK, $empty);
        $SIG{INT} = $SIG{TERM} = $SIG{HUP} = $SIG{QUIT} = $SIG{ALRM} = "DEFAULT";
        kill $s, $$;
        sleep 1;
    ' "$sig"
}

finish_and_exit() {
    local rc="$1"
    ensure_start_trace_written
    if [[ -n "${STUB_TRACE_DIR:-}" ]]; then
        local end_ts
        end_ts="$(now_epoch_ts)"
        printf 'end %s %s %s %s %s\n' "$end_ts" "$$" "$VENDOR" "$LANE_NAME" "$rc" >> "${STUB_TRACE_DIR}/${LANE_NAME}.trace"
    fi
    exit "$rc"
}

COST_USD="0.001"
TOTAL_TOKENS="1200"
WORKER_STATUS="success"
MESSAGE_BODY=""
NO_JSON=0
EXIT_CODE=0

IN_BLOCK=0
BLOCK_TARGET=""
BLOCK_EOF=""
BLOCK_BUF=""

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

    case "$line" in
        STUB|"STUB "*|"STUB	"*)
            rest="${line#STUB}"
            rest="${rest#"${rest%%[![:space:]]*}"}"
            [[ -z "$rest" ]] && continue
            cmd="${rest%%[[:space:]]*}"
            arg_str="${rest#"$cmd"}"
            cmd_upper="$(printf '%s' "$cmd" | tr '[:lower:]' '[:upper:]')"

            case "$cmd_upper" in
                LANE)
                    ;;
                WRITE)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    [[ -z "$trimmed" ]] && continue
                    if [[ "$trimmed" == *[[:space:]]* ]]; then
                        rel_p="${trimmed%%[[:space:]]*}"
                        rem="${trimmed#"$rel_p"}"
                        rem="${rem# }"
                        target_p="$(resolve_target_path "$rel_p")"
                        mkdir -p "$(dirname "$target_p")"
                        printf '%s\n' "$rem" > "$target_p"
                    else
                        target_p="$(resolve_target_path "$trimmed")"
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
                        target_p="$(resolve_target_path "$rel_p")"
                        mkdir -p "$(dirname "$target_p")"
                        printf '%s\n' "$rem" >> "$target_p"
                    else
                        target_p="$(resolve_target_path "$trimmed")"
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
                        BLOCK_TARGET="$(resolve_target_path "$rel_p")"
                        BLOCK_EOF="$eof_tok"
                        BLOCK_BUF=""
                    fi
                    ;;
                DELETE)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    if [[ -z "$trimmed" ]]; then
                        echo "stub-agent: DELETE requires <path>" >&2
                        finish_and_exit 2
                    fi
                    rel_p="${trimmed%%[[:space:]]*}"
                    target_p="$(resolve_target_path "$rel_p")"
                    if [[ ! -e "$target_p" && ! -L "$target_p" ]]; then
                        echo "stub-agent: DELETE target does not exist: $target_p" >&2
                        finish_and_exit 2
                    fi
                    if ! rm -rf -- "$target_p"; then
                        echo "stub-agent: DELETE failed for $target_p" >&2
                        finish_and_exit 2
                    fi
                    ;;
                MOVE)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    if [[ -z "$trimmed" ]]; then
                        echo "stub-agent: MOVE requires <src> <dst>" >&2
                        finish_and_exit 2
                    fi
                    src_raw="${trimmed%%[[:space:]]*}"
                    rem="${trimmed#"$src_raw"}"
                    rem="${rem#"${rem%%[![:space:]]*}"}"
                    dst_raw="${rem%%[[:space:]]*}"
                    if [[ -z "$src_raw" || -z "$dst_raw" ]]; then
                        echo "stub-agent: MOVE requires <src> <dst>" >&2
                        finish_and_exit 2
                    fi
                    src_p="$(resolve_target_path "$src_raw")"
                    dst_p="$(resolve_target_path "$dst_raw")"
                    if [[ ! -e "$src_p" && ! -L "$src_p" ]]; then
                        echo "stub-agent: MOVE source does not exist: $src_p" >&2
                        finish_and_exit 2
                    fi
                    mkdir -p "$(dirname "$dst_p")" || finish_and_exit 2
                    if ! mv -- "$src_p" "$dst_p"; then
                        echo "stub-agent: MOVE failed from $src_p to $dst_p" >&2
                        finish_and_exit 2
                    fi
                    ;;
                WRITE_HEX)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    if [[ -z "$trimmed" ]]; then
                        echo "stub-agent: WRITE_HEX requires <path> <hex>" >&2
                        finish_and_exit 2
                    fi
                    rel_p="${trimmed%%[[:space:]]*}"
                    rem="${trimmed#"$rel_p"}"
                    rem="${rem#"${rem%%[![:space:]]*}"}"
                    if [[ -z "$rel_p" || -z "$rem" ]]; then
                        echo "stub-agent: WRITE_HEX requires <path> <hex>" >&2
                        finish_and_exit 2
                    fi
                    target_p="$(resolve_target_path "$rel_p")"
                    if ! /usr/bin/python3 -I -c '
import os, sys
dst, hex_str = sys.argv[1], sys.argv[2]
raw = bytes.fromhex(hex_str)
parent = os.path.dirname(dst)
if parent:
    os.makedirs(parent, exist_ok=True)
with open(dst, "wb") as fh:
    fh.write(raw)
' "$target_p" "$rem"; then
                        echo "stub-agent: WRITE_HEX failed for $target_p" >&2
                        finish_and_exit 2
                    fi
                    ;;
                GIT_COMMIT)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    if [[ -z "$trimmed" ]]; then
                        echo "stub-agent: GIT_COMMIT requires <message>" >&2
                        finish_and_exit 2
                    fi
                    if ! /usr/bin/git -C "$WORKDIR" -c core.hooksPath=/dev/null -c gc.auto=0 -c maintenance.auto=false add -A -- .; then
                        echo "stub-agent: GIT_COMMIT git add failed in $WORKDIR" >&2
                        finish_and_exit 2
                    fi
                    /usr/bin/git -C "$WORKDIR" -c core.hooksPath=/dev/null -c gc.auto=0 -c maintenance.auto=false reset -q HEAD -- .relay 2>/dev/null || true
                    if ! /usr/bin/git -C "$WORKDIR" -c core.hooksPath=/dev/null -c gc.auto=0 -c maintenance.auto=false -c user.useConfigOnly=true commit --no-gpg-sign -q -m "$trimmed"; then
                        echo "stub-agent: GIT_COMMIT git commit failed in $WORKDIR" >&2
                        finish_and_exit 2
                    fi
                    ;;
                SLEEP)
                    ensure_start_trace_written
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    sleep_sec="${trimmed%%[[:space:]]*}"
                    if [[ -n "$sleep_sec" ]]; then
                        /usr/bin/perl -e '
                            my ($sec, $tag) = @ARGV;
                            select(undef, undef, undef, $sec + 0);
                        ' "$sleep_sec" "$TRACE_TAG" < /dev/null
                    fi
                    ;;
                WAIT|WAIT_FILE|BARRIER)
                    ensure_start_trace_written
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    [[ -z "$trimmed" ]] && continue
                    wait_raw="${trimmed%%[[:space:]]*}"
                    rem="${trimmed#"$wait_raw"}"
                    rem="${rem#"${rem%%[![:space:]]*}"}"
                    wait_timeout="${rem%%[[:space:]]*}"
                    wait_target="$(resolve_target_path "$wait_raw")"
                    /usr/bin/perl -MTime::HiRes=time -e '
                        my ($p, $t, $tag) = @ARGV;
                        my $limit = ($t ne "" ? $t + 0 : 0);
                        my $t0 = time();
                        while (! -e $p) {
                            if ($limit > 0 && (time() - $t0) >= $limit) { exit 124; }
                            select(undef, undef, undef, 0.02);
                        }
                    ' "$wait_target" "${wait_timeout:-0}" "$TRACE_TAG" < /dev/null
                    wait_rc=$?
                    if [[ $wait_rc -ne 0 ]]; then
                        echo "stub-agent: barrier wait timed out for $wait_target" >&2
                        finish_and_exit "$wait_rc"
                    fi
                    ;;
                COST)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    [[ -n "$trimmed" ]] && COST_USD="${trimmed%%[[:space:]]*}"
                    ;;
                TOKENS)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    if [[ -n "$trimmed" ]]; then
                        tok_raw="${trimmed%%[[:space:]]*}"
                        TOTAL_TOKENS="${tok_raw//,/}"
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
                    trimmed="${arg_str# }"
                    MESSAGE_BODY="$trimmed"
                    ;;
                STDERR)
                    trimmed="${arg_str# }"
                    printf '%s\n' "$trimmed" >&2
                    ;;
                NO_JSON|NO-JSON|OMIT_JSON)
                    NO_JSON=1
                    ;;
                KILL_SELF|SIGNAL|KILL)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    sig_tok="${trimmed%%[[:space:]]*}"
                    if [[ -n "$sig_tok" ]]; then
                        die_by_signal "$sig_tok"
                    fi
                    ;;
                EXIT)
                    trimmed="${arg_str#"${arg_str%%[![:space:]]*}"}"
                    code_tok="${trimmed%%[[:space:]]*}"
                    EXIT_CODE="${code_tok:-0}"
                    if [[ "$EXIT_CODE" != "0" ]]; then
                        echo "stub-agent: exiting with code $EXIT_CODE" >&2
                        finish_and_exit "$EXIT_CODE"
                    fi
                    break
                    ;;
            esac
            ;;
    esac
done 3<<< "$PROMPT_TEXT"

ensure_start_trace_written

if [[ $NO_JSON -eq 1 ]]; then
    finish_and_exit "$EXIT_CODE"
fi

/usr/bin/python3 -I - "$VENDOR" "$LANE_NAME" "$COST_USD" "$TOTAL_TOKENS" "$WORKER_STATUS" "$MESSAGE_BODY" "$CODEX_OUT_FILE" "$VIBE_OUTPUT_DIR" "$REQ_MODEL" "$CLI_BUDGET_CAP" <<'PY'
import json
import os
import sys

vendor, lane, cost_s, tokens_s, status_word, body, codex_out, vibe_dir, req_model, cli_cap = sys.argv[1:11]
cost_val = float(cost_s)
total_tokens = int(tokens_s)
in_tokens = (total_tokens * 2) // 3
out_tokens = total_tokens - in_tokens

if not body:
    env_budget = os.environ.get("RELAY_BUDGET_USD", "")
    if env_budget:
        cap_part = f", cli_cap=${cli_cap}" if cli_cap else ""
        body = f"Stub agent ({vendor}) completed lane {lane} (budget=${env_budget}{cap_part})."
    else:
        body = f"Stub agent ({vendor}) completed lane {lane}."
final_message = f"{body}\nSTATUS: {status_word}"

if vendor == "claude":
    payload = {
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "result": final_message,
        "total_cost_usd": cost_val,
        "session_id": f"stub-claude-{lane}",
        "usage": {
            "input_tokens": in_tokens,
            "output_tokens": out_tokens,
            "total_tokens": total_tokens,
        },
    }
    print(json.dumps(payload, ensure_ascii=False))
elif vendor == "codex":
    if codex_out:
        parent = os.path.dirname(codex_out)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(codex_out, "w", encoding="utf-8") as fh:
            fh.write(final_message + "\n")
    print(f"session id: stub-codex-{lane}")
    print(final_message)
    print("tokens used")
    print(f"{total_tokens:,}")
elif vendor == "agy":
    payload = {
        "response": final_message,
        "status": "SUCCESS",
        "usage": {
            "input_tokens": in_tokens,
            "output_tokens": out_tokens,
            "total_tokens": total_tokens,
        },
        "denied_actions": [],
    }
    print(json.dumps(payload, ensure_ascii=False))
elif vendor == "vibe":
    messages = [
        {
            "type": "message",
            "role": "assistant",
            "content": final_message,
        }
    ]
    print(json.dumps(messages, ensure_ascii=False))
    if vibe_dir:
        os.makedirs(vibe_dir, exist_ok=True)
        export_payload = {
            "outcome": "finished",
            "stop_reason": "end_turn",
            "cost_usd": cost_val,
            "usage": {
                "input_tokens": in_tokens,
                "output_tokens": out_tokens,
                "total_tokens": total_tokens,
            },
            "config": {
                "active_model": req_model or "stub-vibe",
            },
        }
        with open(os.path.join(vibe_dir, "export.json"), "w", encoding="utf-8") as fh:
            json.dump(export_payload, fh, ensure_ascii=False)
            fh.write("\n")
PY

finish_and_exit "$EXIT_CODE"
