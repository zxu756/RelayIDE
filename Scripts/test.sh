#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

run_with_watchdog() {
    local timeout_sec="$1"
    shift
    /usr/bin/python3 - "${timeout_sec}" "$@" <<'PY'
import os, signal, subprocess, sys

timeout_sec = float(sys.argv[1])
cmd = sys.argv[2:]
proc = subprocess.Popen(cmd, start_new_session=True)
try:
    rc = proc.wait(timeout=timeout_sec)
    sys.exit(rc)
except subprocess.TimeoutExpired:
    sys.stderr.write(f"\n[test.sh watchdog] Process group exceeded {timeout_sec:.0f}s timeout; killing {' '.join(cmd)}\n")
    sys.stderr.flush()
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

usage() {
    cat <<'EOF' >&2
Usage:
  Scripts/test.sh scope <ModuleOrFilter...>
  Scripts/test.sh milestone <0>
  Scripts/test.sh release

Modules supported by `scope`:
  RelayModels          (shared models -> runs all unit test suites)
  RelayPTYCore         (PTYAndTerminalMultiplexerTests)
  RelayWorktreeGit     (WorktreeGitDiffAndHandoffTests)
  RelayWorkspaceStore  (WorkspaceStoreFTSAndUndoTests + dependent store suites)
  RelaySemanticMerge   (SemanticASTMergeAndCouplingTests)
  RelayWiretapProxy    (WiretapSSEAndDLPCircuitBreakerTests)
  RelayPluginSDK       (PluginSDKAndOrchestratorCPMTests)
  RelayOrchestrator    (PluginSDKAndOrchestratorCPMTests)
  RelayCLIAndMCP       (CLIMCPAndWorkbenchShellTests)
  RelayWorkbenchShell  (CLIMCPAndWorkbenchShellTests)
  RelayStudioViews     (StudioViewModelAndHonestyTests)
EOF
}

map_module_to_filter() {
    local token="$1"
    case "${token}" in
        RelayModels)
            echo "RelayIDETests"
            ;;
        RelayPTYCore)
            echo "PTYAndTerminalMultiplexerTests"
            ;;
        RelayWorktreeGit)
            echo "WorktreeGitDiffAndHandoffTests"
            ;;
        RelayWorkspaceStore)
            echo "WorkspaceStoreFTSAndUndoTests|CLIMCPAndWorkbenchShellTests|StudioViewModelAndHonestyTests"
            ;;
        RelaySemanticMerge)
            echo "SemanticASTMergeAndCouplingTests"
            ;;
        RelayWiretapProxy)
            echo "WiretapSSEAndDLPCircuitBreakerTests"
            ;;
        RelayPluginSDK|RelayOrchestrator)
            echo "PluginSDKAndOrchestratorCPMTests"
            ;;
        RelayCLIAndMCP|RelayWorkbenchShell)
            echo "CLIMCPAndWorkbenchShellTests"
            ;;
        RelayStudioViews)
            echo "StudioViewModelAndHonestyTests"
            ;;
        *)
            echo "${token}"
            ;;
    esac
}

run_scope() {
    if [[ $# -eq 0 ]]; then
        echo "error: 'scope' requires at least one module or filter argument." >&2
        usage
        exit 2
    fi

    local patterns=()
    for arg in "$@"; do
        patterns+=("$(map_module_to_filter "${arg}")")
    done

    local joined=""
    for pat in "${patterns[@]}"; do
        if [[ -z "${joined}" ]]; then
            joined="${pat}"
        else
            joined="${joined}|${pat}"
        fi
    done

    local timeout_sec="${RELAY_SCOPE_TIMEOUT_SEC:-90}"
    echo "==> [scope] swift test --no-parallel --filter \"${joined}\" (watchdog=${timeout_sec}s)"
    run_with_watchdog "${timeout_sec}" swift test --no-parallel --filter "${joined}"
}

run_milestone() {
    local m="${1:-}"
    case "${m}" in
        0|m0|M0)
            echo "==> [milestone 0] Running M0 scoped unit test suites..."
            run_scope RelaySemanticMerge RelayWiretapProxy RelayWorkspaceStore RelayCLIAndMCP RelayStudioViews

            if [[ ! -x "${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh" ]]; then
                echo "error: missing executable ${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh" >&2
                exit 1
            fi
            echo "==> [milestone 0] Running Scripts/acceptance/m0-acceptance.sh..."
            "${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh"

            if [[ ! -x "${ROOT_DIR}/Scripts/acceptance/readme-commands.sh" ]]; then
                echo "error: missing executable ${ROOT_DIR}/Scripts/acceptance/readme-commands.sh" >&2
                exit 1
            fi
            echo "==> [milestone 0] Running Scripts/acceptance/readme-commands.sh..."
            "${ROOT_DIR}/Scripts/acceptance/readme-commands.sh"
            ;;
        *)
            echo "error: milestone '${m}' acceptance suite is not implemented yet." >&2
            exit 2
            ;;
    esac
}

run_release() {
    local timeout_sec="${RELAY_RELEASE_TIMEOUT_SEC:-300}"
    echo "==> [release] Running full unit test suite (swift test --no-parallel, watchdog=${timeout_sec}s)..."
    run_with_watchdog "${timeout_sec}" swift test --no-parallel

    if [[ -x "${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh" ]]; then
        echo "==> [release] Running Scripts/acceptance/m0-acceptance.sh..."
        "${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh"
    else
        echo "error: missing executable ${ROOT_DIR}/Scripts/acceptance/m0-acceptance.sh" >&2
        exit 1
    fi

    if [[ -x "${ROOT_DIR}/Scripts/acceptance/readme-commands.sh" ]]; then
        echo "==> [release] Running Scripts/acceptance/readme-commands.sh..."
        "${ROOT_DIR}/Scripts/acceptance/readme-commands.sh"
    else
        echo "error: missing executable ${ROOT_DIR}/Scripts/acceptance/readme-commands.sh" >&2
        exit 1
    fi

    if [[ "${RELAY_REAL_AGENTS:-0}" == "1" ]]; then
        if [[ -x "${ROOT_DIR}/Scripts/acceptance/real-agents.sh" ]]; then
            echo "==> [release] Running real-agent integration suite (RELAY_REAL_AGENTS=1)..."
            "${ROOT_DIR}/Scripts/acceptance/real-agents.sh"
        else
            echo "error: RELAY_REAL_AGENTS=1 requested, but real-agent runner (M1+) is not implemented yet." >&2
            exit 2
        fi
    else
        echo "==> [release] Real-agent live execution suite: SKIPPED (RELAY_REAL_AGENTS!=1)"
    fi
}

MODE="${1:-}"
if [[ -z "${MODE}" ]]; then
    usage
    exit 2
fi
shift

case "${MODE}" in
    scope)
        run_scope "$@"
        ;;
    milestone)
        run_milestone "$@"
        ;;
    release)
        run_release "$@"
        ;;
    -h|--help|help)
        usage
        exit 0
        ;;
    *)
        echo "error: unknown mode '${MODE}'" >&2
        usage
        exit 2
        ;;
esac
