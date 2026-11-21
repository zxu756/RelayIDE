#!/usr/bin/env bash
# Headless-only entry point to the RelayIDE executable for acceptance scripts.
#
# The executable opens the desktop GUI whenever its first argument is not a CLI subcommand
# (no arguments, --demo, --project, a bare .relayproj path, or simply a misspelled subcommand).
# Acceptance scripts must never open a window, so they do not call the executable directly:
# they call this wrapper, which refuses everything that is not a known headless subcommand.
#
# Environment:
#   RELAY_CLI_BIN   executable to run (default: <repo>/.build/debug/RelayIDE)
#   RELAY_CLI_HOME  if set, HOME and CFFIXED_USER_HOME of the child are pointed at this directory
#                   so product commands cannot touch the real user's home
#   RELAY_CLI_CHILD_PATH  if set, PATH of the child (used to check behaviour when git is not installed)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELAY_CLI_BIN="${RELAY_CLI_BIN:-${ROOT_DIR}/.build/debug/RelayIDE}"

# Housekeeping query for acceptance scripts (does not start anything): list processes running this executable.
if [[ "${1:-}" == "--relay-cli-running-processes" ]]; then
    pgrep -fl "${RELAY_CLI_BIN}" || true
    exit 0
fi

refuse() {
    echo "relay-cli.sh: refusing to run '${RELAY_CLI_BIN} $*': $REFUSE_REASON" >&2
    exit 64
}

subcommand=""
skip_next=0
for arg in "$@"; do
    case "${arg}" in
        --export-screenshots|--export-screenshots=*)
            REFUSE_REASON="--export-screenshots renders the desktop UI and is not a headless CLI subcommand."
            refuse "$@"
            ;;
    esac
done
for arg in "$@"; do
    if [[ "${skip_next}" -eq 1 ]]; then
        skip_next=0
        continue
    fi
    case "${arg}" in
        --lang) skip_next=1 ;;
        --lang=*) ;;
        *)
            subcommand="${arg}"
            break
            ;;
    esac
done

case "${subcommand}" in
    init|run|status|lanes|dag-waves|audit-plugins|export-html|mcp|help|--help|-h|version|--version) ;;
    # `semantic-merge` was removed per the M3 decision (2026-11-21). Forward it to the executable so acceptance
    # scripts can verify that `RelayIDE` itself rejects it with exit 2 as an unknown subcommand without opening GUI.
    semantic-merge) ;;
    *)
        REFUSE_REASON="first argument '${subcommand:-<none>}' is not a headless CLI subcommand, so the executable would open the desktop GUI."
        refuse "$@"
        ;;
esac

CHILD_ENV=()
if [[ -n "${RELAY_CLI_HOME:-}" ]]; then
    mkdir -p "${RELAY_CLI_HOME}"
    CHILD_ENV+=("HOME=${RELAY_CLI_HOME}" "CFFIXED_USER_HOME=${RELAY_CLI_HOME}")
fi
if [[ -n "${RELAY_CLI_CHILD_PATH:-}" ]]; then
    CHILD_ENV+=("PATH=${RELAY_CLI_CHILD_PATH}")
fi
if [[ "${#CHILD_ENV[@]}" -gt 0 ]]; then
    exec /usr/bin/env "${CHILD_ENV[@]}" "${RELAY_CLI_BIN}" "$@"
fi
exec "${RELAY_CLI_BIN}" "$@"
