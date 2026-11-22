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

# Optional cap on build parallelism, e.g. RELAY_SWIFT_JOBS=3 (passed to swift build / swift test as -j).
SWIFT_JOBS_ARGS=()
if [[ -n "${RELAY_SWIFT_JOBS:-}" ]]; then
    SWIFT_JOBS_ARGS=(-j "${RELAY_SWIFT_JOBS}")
fi

usage() {
    cat <<'EOF' >&2
Usage:
  Scripts/test.sh scope <ModuleOrFilter...>
  Scripts/test.sh milestone <0|1|2|3|4|5> [--record]
  Scripts/test.sh release [--record]

Acceptance output goes to a temporary directory. Only with --record are reports/*.txt rewritten.
release runs full unit tests, M0-M5 acceptance suites, and m5-ui.sh --mutation 1..9.
No mode opens the desktop window. Environment: RELAY_SWIFT_JOBS=<n> caps build parallelism.

Modules supported by `scope`:
  RelayModels          (shared models -> runs all unit test suites)
  RelayPTYCore         (PTYAndTerminalMultiplexerTests)
  RelayWorktreeGit     (WorktreeGitDiffAndHandoffTests)
  RelayWorkspaceStore  (WorkspaceStoreFTSAndUndoTests + dependent store suites)
  RelaySemanticMerge   (SemanticASTMergeAndCouplingTests + CLIMCPAndWorkbenchShellTests)
  RelayPluginSDK       (PluginSDKAndOrchestratorCPMTests)
  RelayOrchestrator    (PluginSDKAndOrchestratorCPMTests)
  RelayCLIAndMCP       (CLIMCPAndWorkbenchShellTests)
  RelayWorkbenchShell  (CLIMCPAndWorkbenchShellTests)
  RelayStudioViews     (StudioViewModelAndHonestyTests + M5LiveWorkspaceObserverTests + M5StudioViewsHeadlessTests + M5UIAcceptanceTests)
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
            echo "WorkspaceStoreFTSAndUndoTests|CLIMCPAndWorkbenchShellTests|StudioViewModelAndHonestyTests|M5LiveWorkspaceObserverTests|M5StudioViewsHeadlessTests|M5UIAcceptanceTests"
            ;;
        RelaySemanticMerge)
            # The guarded merge is exercised both directly and through the CLI / MCP entry points.
            echo "SemanticASTMergeAndCouplingTests|CLIMCPAndWorkbenchShellTests"
            ;;
        RelayPluginSDK|RelayOrchestrator)
            echo "PluginSDKAndOrchestratorCPMTests"
            ;;
        RelayCLIAndMCP|RelayWorkbenchShell)
            echo "CLIMCPAndWorkbenchShellTests"
            ;;
        RelayStudioViews)
            echo "StudioViewModelAndHonestyTests|M5LiveWorkspaceObserverTests|M5StudioViewsHeadlessTests|M5UIAcceptanceTests"
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

    # Build first, outside the watchdog: the watchdog exists to stop tests that hang, not to kill a cold build.
    echo "==> [scope] swift build --build-tests ${SWIFT_JOBS_ARGS[*]:-}"
    swift build --build-tests ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"}

    local timeout_sec="${RELAY_SCOPE_TIMEOUT_SEC:-180}"
    echo "==> [scope] swift test --skip-build --no-parallel --filter \"${joined}\" (watchdog=${timeout_sec}s)"
    run_with_watchdog "${timeout_sec}" swift test --skip-build --no-parallel --filter "${joined}"
}

# Splits "--record" out of the arguments of milestone / release.
RECORD_ARGS=()
POSITIONAL_ARGS=()
split_record_flag() {
    RECORD_ARGS=()
    POSITIONAL_ARGS=()
    for arg in "$@"; do
        if [[ "${arg}" == "--record" ]]; then
            RECORD_ARGS=(--record)
        else
            POSITIONAL_ARGS+=("${arg}")
        fi
    done
}

run_acceptance_script() {
    local script="${ROOT_DIR}/Scripts/acceptance/$1"
    if [[ ! -x "${script}" ]]; then
        echo "error: missing executable ${script}" >&2
        exit 1
    fi
    echo "==> Running Scripts/acceptance/$1 ${RECORD_ARGS[*]:-}"
    "${script}" ${RECORD_ARGS[@]+"${RECORD_ARGS[@]}"}
}

run_milestone() {
    split_record_flag "$@"
    local m="${POSITIONAL_ARGS[0]:-}"
    case "${m}" in
        0|m0|M0)
            local tree_before
            tree_before="$(git status --porcelain)"

            echo "==> [milestone 0] Running M0 scoped unit test suites..."
            run_scope RelaySemanticMerge RelayWorkspaceStore RelayCLIAndMCP RelayStudioViews RelayPTYCore

            run_acceptance_script m0-acceptance.sh
            run_acceptance_script readme-commands.sh

            if [[ "${#RECORD_ARGS[@]}" -eq 0 ]]; then
                local tree_after
                tree_after="$(git status --porcelain)"
                if [[ "${tree_before}" != "${tree_after}" ]]; then
                    echo "error: 'Scripts/test.sh milestone 0' changed the working tree:" >&2
                    diff <(printf '%s\n' "${tree_before}") <(printf '%s\n' "${tree_after}") >&2 || true
                    exit 1
                fi
                echo "==> [milestone 0] git status --short after the run: ${tree_after:-(no output)}"
            else
                echo "==> [milestone 0] --record: reports/*.txt were rewritten"
            fi
            ;;
        1|m1|M1)
            local tree_before
            tree_before="$(git status --porcelain)"

            echo "==> [milestone 1] Running M1 scoped unit test suites..."
            run_scope RelayPTYCore RelayWorktreeGit RelayWorkspaceStore RelayCLIAndMCP RelayOrchestrator

            run_acceptance_script m0-acceptance.sh
            run_acceptance_script readme-commands.sh
            run_acceptance_script m1-run.sh

            if [[ "${#RECORD_ARGS[@]}" -eq 0 ]]; then
                local tree_after
                tree_after="$(git status --porcelain)"
                if [[ "${tree_before}" != "${tree_after}" ]]; then
                    echo "error: 'Scripts/test.sh milestone 1' changed the working tree:" >&2
                    diff <(printf '%s\n' "${tree_before}") <(printf '%s\n' "${tree_after}") >&2 || true
                    exit 1
                fi
                echo "==> [milestone 1] git status --short after the run: ${tree_after:-(no output)}"
            else
                echo "==> [milestone 1] --record: reports/*.txt were rewritten"
            fi
            ;;
        2|m2|M2)
            local tree_before
            tree_before="$(git status --porcelain)"

            echo "==> [milestone 2] Running M2 scoped unit test suites..."
            run_scope RelayPTYCore RelayWorktreeGit RelayWorkspaceStore RelayCLIAndMCP RelayOrchestrator

            run_acceptance_script m0-acceptance.sh
            run_acceptance_script readme-commands.sh
            run_acceptance_script m1-run.sh
            run_acceptance_script m2-merge.sh

            if [[ "${#RECORD_ARGS[@]}" -eq 0 ]]; then
                local tree_after
                tree_after="$(git status --porcelain)"
                if [[ "${tree_before}" != "${tree_after}" ]]; then
                    echo "error: 'Scripts/test.sh milestone 2' changed the working tree:" >&2
                    diff <(printf '%s\n' "${tree_before}") <(printf '%s\n' "${tree_after}") >&2 || true
                    exit 1
                fi
                echo "==> [milestone 2] git status --short after the run: ${tree_after:-(no output)}"
            else
                echo "==> [milestone 2] --record: reports/*.txt were rewritten"
            fi
            ;;
        3|m3|M3)
            if [[ "${#RECORD_ARGS[@]}" -ne 0 ]]; then
                echo "没跑：发布的命令已按 M3 结论删除（2026-11-21）（reports/ 下三份评估报告留作记录，不再覆盖）"
                exit 2
            fi

            local tree_before
            tree_before="$(git status --porcelain)"

            echo "==> [milestone 3] Running M3 scoped unit test suites..."
            run_scope RelaySemanticMerge RelayCLIAndMCP

            run_acceptance_script m0-acceptance.sh
            if [[ ! -x "${ROOT_DIR}/Scripts/acceptance/m3-merge-eval.sh" ]]; then
                echo "error: missing executable ${ROOT_DIR}/Scripts/acceptance/m3-merge-eval.sh" >&2
                exit 1
            fi
            echo "==> [milestone 3] 没跑：发布的命令已按 M3 结论删除（2026-11-21）（跳过 run_published 两列及验收第 6、7、8、11 行；固定用例引擎与 mergiraf 两列及 report.py --check 核对已记录报告照跑）"
            echo "==> Running Scripts/acceptance/m3-merge-eval.sh --quick"
            "${ROOT_DIR}/Scripts/acceptance/m3-merge-eval.sh" --quick

            local tree_after
            tree_after="$(git status --porcelain)"
            if [[ "${tree_before}" != "${tree_after}" ]]; then
                echo "error: 'Scripts/test.sh milestone 3' changed the working tree:" >&2
                diff <(printf '%s\n' "${tree_before}") <(printf '%s\n' "${tree_after}") >&2 || true
                exit 1
            fi
            echo "==> [milestone 3] git status --short after the run: ${tree_after:-(no output)}"
            ;;
        4|m4|M4)
            local tree_before
            tree_before="$(git status --porcelain)"

            echo "==> [milestone 4] Running M4 scoped unit test suites..."
            run_scope RelayWorktreeGit RelayWorkspaceStore RelayOrchestrator RelayCLIAndMCP RelayStudioViews

            echo "==> [milestone 4] Building RelayIDE debug executable..."
            swift build ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} --product RelayIDE

            run_acceptance_script m4-budget.sh

            if [[ "${#RECORD_ARGS[@]}" -eq 0 ]]; then
                local tree_after
                tree_after="$(git status --porcelain)"
                if [[ "${tree_before}" != "${tree_after}" ]]; then
                    echo "error: 'Scripts/test.sh milestone 4' changed the working tree:" >&2
                    diff <(printf '%s\n' "${tree_before}") <(printf '%s\n' "${tree_after}") >&2 || true
                    exit 1
                fi
                echo "==> [milestone 4] git status --short after the run: ${tree_after:-(no output)}"
            else
                echo "==> [milestone 4] --record: reports/*.txt were rewritten"
            fi
            ;;
        5|m5|M5)
            local tree_before
            tree_before="$(git status --porcelain)"

            echo "==> [milestone 5] Running M5 scoped unit test suites..."
            run_scope RelayStudioViews RelayWorktreeGit RelayWorkspaceStore RelayCLIAndMCP RelayWorkbenchShell

            echo "==> [milestone 5] Building RelayIDE debug executable & test bundle..."
            swift build --build-tests ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"}

            run_acceptance_script m5-ui.sh

            if [[ "${#RECORD_ARGS[@]}" -eq 0 ]]; then
                local tree_after
                tree_after="$(git status --porcelain)"
                if [[ "${tree_before}" != "${tree_after}" ]]; then
                    echo "error: 'Scripts/test.sh milestone 5' changed the working tree:" >&2
                    diff <(printf '%s\n' "${tree_before}") <(printf '%s\n' "${tree_after}") >&2 || true
                    exit 1
                fi
                echo "==> [milestone 5] git status --short after the run: ${tree_after:-(no output)}"
            else
                echo "==> [milestone 5] --record: reports/*.txt were rewritten"
            fi
            ;;
        *)
            echo "error: milestone '${m}' acceptance suite is not implemented yet." >&2
            exit 2
            ;;
    esac
}

run_release() {
    split_record_flag "$@"
    local timeout_sec="${RELAY_RELEASE_TIMEOUT_SEC:-300}"
    echo "==> [release] swift build --build-tests ${SWIFT_JOBS_ARGS[*]:-}"
    swift build --build-tests ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"}
    echo "==> [release] Running full unit test suite (swift test --skip-build --no-parallel, watchdog=${timeout_sec}s)..."
    run_with_watchdog "${timeout_sec}" swift test --skip-build --no-parallel

    run_acceptance_script m0-acceptance.sh
    run_acceptance_script readme-commands.sh
    run_acceptance_script m1-run.sh
    run_acceptance_script m2-merge.sh

    if [[ -n "${RELAY_MERGE_CORPUS_DIR:-}" ]]; then
        echo "==> [release] 没跑：发布的命令已按 M3 结论删除（2026-11-21）（m3-merge-eval.sh 跳过 run_published 两列及第 6、7、8、11 行，固定用例引擎与 mergiraf 及 report.py --check 照跑）"
        echo "==> Running Scripts/acceptance/m3-merge-eval.sh"
        "${ROOT_DIR}/Scripts/acceptance/m3-merge-eval.sh"
    else
        echo "==> [release] M3 full merge corpus evaluation: SKIPPED (RELAY_MERGE_CORPUS_DIR unset)"
    fi

    run_acceptance_script m4-budget.sh
    run_acceptance_script m5-ui.sh

    echo "==> [release] Running m5-ui.sh temporary-copy mutations 1..9..."
    for m5_mut in 1 2 3 4 5 6 7 8 9; do
        "${ROOT_DIR}/Scripts/acceptance/m5-ui.sh" --mutation "${m5_mut}"
    done

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
