#!/usr/bin/env bash
# Replays the commands that README.md and README.zh-CN.md contain.
#
# The commands are read from the two README files by readme_replay.py; this script keeps no copy of them.
# The replay fails when the two files disagree, when a command cannot be classified, or when a command fails.
# Commands that would open the desktop window are listed and never executed.
#
# Usage: Scripts/acceptance/readme-commands.sh [--record]
#   --record   write the output to reports/readme-commands.txt (default: a file in a temporary directory)
# Environment: RELAY_SWIFT_JOBS=<n> caps build parallelism.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

RECORD=0
for arg in "$@"; do
    case "${arg}" in
        --record) RECORD=1 ;;
        *)
            echo "error: unknown argument '${arg}' (usage: readme-commands.sh [--record])" >&2
            exit 2
            ;;
    esac
done

if [[ "${RECORD}" -eq 1 ]]; then
    mkdir -p "${ROOT_DIR}/reports"
    REPORT_FILE="${ROOT_DIR}/reports/readme-commands.txt"
else
    REPORT_FILE="$(mktemp -d "${TMPDIR:-/tmp}/relayide-report.XXXXXX")/readme-commands.txt"
fi

SWIFT_JOBS_ARGS=""
if [[ -n "${RELAY_SWIFT_JOBS:-}" ]]; then
    SWIFT_JOBS_ARGS="-j ${RELAY_SWIFT_JOBS}"
fi

# Recorded before anything is written. reports/ is left out because --record rewrites it.
if [[ -z "$(git status --porcelain -- . ':(exclude)reports')" ]]; then
    TREE_STATE="working tree clean outside reports/"
else
    TREE_STATE="working tree has uncommitted changes outside reports/"
fi

run_readme_verification() {
    echo "================================================================"
    echo "RelayIDE README.md & README.zh-CN.md command replay"
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Commit:    $(git rev-parse --short HEAD) (${TREE_STATE})"
    echo "================================================================"

    # shellcheck disable=SC2086
    swift build ${SWIFT_JOBS_ARGS} >/dev/null

    echo ""
    /usr/bin/python3 "${ROOT_DIR}/Scripts/acceptance/readme_replay.py" --run --repo-root "${ROOT_DIR}" \
        "${ROOT_DIR}/README.md" "${ROOT_DIR}/README.zh-CN.md"

    echo ""
    echo "================================================================"
    echo "README & README.zh-CN COMMANDS: SAME IN BOTH FILES, ALL RUNNABLE ONES EXITED 0"
    echo "================================================================"
}

# Absolute paths of this checkout are replaced so a recorded report carries no machine-specific path.
run_readme_verification 2>&1 | sed "s|${ROOT_DIR}|<repo>|g" | tee "${REPORT_FILE}"
echo "Report written to ${REPORT_FILE}"
