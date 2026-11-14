#!/usr/bin/env bash
# Executes every CLI/MCP command documented in README.md and README.zh-CN.md against isolated temp workspaces.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

mkdir -p "${ROOT_DIR}/reports"
REPORT_FILE="${ROOT_DIR}/reports/readme-commands.txt"

run_readme_verification() {
    echo "================================================================"
    echo "RelayIDE README & README.zh-CN Command Verification"
    echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "Commit:    $(git rev-parse --short HEAD)"
    echo "================================================================"

    swift build >/dev/null
    BIN="${ROOT_DIR}/.build/debug/RelayIDE"

    WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/relayide-readme-cmd.XXXXXX")"
    trap 'rm -rf "${WORK_TMP}"' EXIT

    echo ""
    echo "--- 1. Empty workspace commands (EN + ZH) ---"
    "${BIN}" init --project "${WORK_TMP}/my-empty.relayproj"
    "${BIN}" status --project "${WORK_TMP}/my-empty.relayproj"
    "${BIN}" lanes --project "${WORK_TMP}/my-empty.relayproj"

    "${BIN}" init --project "${WORK_TMP}/my-empty-zh.relayproj" --lang zh
    "${BIN}" status --project "${WORK_TMP}/my-empty-zh.relayproj" --lang zh
    "${BIN}" lanes --project "${WORK_TMP}/my-empty-zh.relayproj" --lang zh

    echo ""
    echo "--- 2. Explicit [DEMO] seeded workspace & HTML export commands (EN + ZH) ---"
    "${BIN}" init --project "${WORK_TMP}/demo.relayproj" --seed-demo --lang en
    "${BIN}" dag-waves --project "${WORK_TMP}/demo.relayproj" --lang en
    "${BIN}" audit-plugins --project "${WORK_TMP}/demo.relayproj" --lang en
    "${BIN}" export-html "${WORK_TMP}/demo-dossier.html" --project "${WORK_TMP}/demo.relayproj" --lang en

    "${BIN}" init --project "${WORK_TMP}/demo-zh.relayproj" --seed-demo --lang zh
    "${BIN}" dag-waves --project "${WORK_TMP}/demo-zh.relayproj" --lang zh
    "${BIN}" audit-plugins --project "${WORK_TMP}/demo-zh.relayproj" --lang zh
    "${BIN}" export-html "${WORK_TMP}/demo-dossier-zh.html" --project "${WORK_TMP}/demo-zh.relayproj" --lang zh

    echo ""
    echo "--- 3. Experimental semantic-merge command (EN + ZH) ---"
    cat > "${WORK_TMP}/base.swift" <<'EOF'
public struct Counter {
    public init() {}
}
EOF
    cat > "${WORK_TMP}/left.swift" <<'EOF'
public struct Counter {
    public init() {}
    public func increment(_ x: Int) -> Int { x + 1 }
}
EOF
    cat > "${WORK_TMP}/right.swift" <<'EOF'
public struct Counter {
    public init() {}
    public func decrement(_ x: Int) -> Int { x - 1 }
}
EOF
    "${BIN}" semantic-merge "${WORK_TMP}/base.swift" "${WORK_TMP}/left.swift" "${WORK_TMP}/right.swift" > "${WORK_TMP}/merged.swift"
    /usr/bin/xcrun swiftc -parse "${WORK_TMP}/merged.swift"
    "${BIN}" semantic-merge "${WORK_TMP}/base.swift" "${WORK_TMP}/left.swift" "${WORK_TMP}/right.swift" --lang zh > "${WORK_TMP}/merged-zh.swift"
    /usr/bin/xcrun swiftc -parse "${WORK_TMP}/merged-zh.swift"
    echo "Verified clean Swift semantic-merge output passes 'xcrun swiftc -parse' (EN + ZH)."

    echo ""
    echo "--- 4. MCP stdio server command (EN + ZH) ---"
    printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' \
        | "${BIN}" mcp --project "${WORK_TMP}/my-empty.relayproj"
    printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' \
        | "${BIN}" mcp --project "${WORK_TMP}/my-empty-zh.relayproj" --lang zh

    echo ""
    echo "================================================================"
    echo "ALL README & README.zh-CN COMMANDS VERIFIED SUCCESSFULLY"
    echo "================================================================"
}

run_readme_verification 2>&1 | tee "${REPORT_FILE}"
