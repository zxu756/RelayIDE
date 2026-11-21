#!/usr/bin/env python3
"""Mutation checks for retained `LanguageSyntaxValidator` and M3 removal of `semantic-merge` (run by hand).

1. Verifies directly via `Scripts/acceptance/relay-cli.sh` that `Sources/RelaySemanticMerge/LineAnchoredGuardedMerge.swift`
   has been deleted, `semantic-merge` exits `2` as an unknown subcommand (`--lang en` and `--lang zh`), `--help` omits
   `semantic-merge`, and MCP `tools/list` / `tools/call` omit and reject `relay_semantic_merge`.
2. Mutates retained `LanguageSyntaxValidator` and `RelayCLIRunnerAndMCPServer` in place, verifies that the corresponding
   unit tests go red, and restores every mutated file byte for byte (verified by SHA-256).

Usage:
  Scripts/acceptance/mutation-checks.py                 run removal guard + every mutation
  Scripts/acceptance/mutation-checks.py --list          list mutation names
  Scripts/acceptance/mutation-checks.py NAME [NAME...]  run the named mutations only
  --allow-dirty   run although the files to be mutated have uncommitted changes
Environment: RELAY_SWIFT_JOBS=<n> caps build parallelism.

Python 3.9 compatible, standard library only.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VALIDATOR = "Sources/RelaySemanticMerge/LanguageSyntaxValidator.swift"
REMOVED_GATE = "Sources/RelaySemanticMerge/LineAnchoredGuardedMerge.swift"
CLI_MCP = "Sources/RelayCLIAndMCP/RelayCLIRunnerAndMCPServer.swift"


def bypass(signature, parser):
    return (
        signature,
        signature + '\n        if Bool(true) { return SyntaxValidationVerdict(passed: true, parserUsed: "%s") } // MUTATION' % parser,
    )


# name, file, [(old, new)], test filter, substrings of the test names that must go red
MUTATIONS = [
    (
        "syntax-check-off-swift",
        VALIDATOR,
        [bypass("    private static func validateSwift(source: String) -> SyntaxValidationVerdict {", "swiftc -parse")],
        "SyntaxGateExits3",
        ["not valid Swift (R29)"],
    ),
    (
        "syntax-check-off-javascript",
        VALIDATOR,
        [bypass("    private static func validateJavaScript(source: String, fileExtension: String) -> SyntaxValidationVerdict {", "node --check")],
        "SyntaxGateExits3",
        ["not valid JavaScript (R29)"],
    ),
    (
        "syntax-check-off-typescript",
        VALIDATOR,
        [bypass("    private static func validateTypeScript(source: String, fileExtension: String) -> SyntaxValidationVerdict {", "node stripTypeScriptTypes + --check")],
        "SyntaxGateExits3",
        ["not valid TypeScript (R29)"],
    ),
    (
        "syntax-check-off-python",
        VALIDATOR,
        [bypass("    private static func validatePython(source: String) -> SyntaxValidationVerdict {", "python3 -m py_compile")],
        "SyntaxGateExits3",
        ["not valid Python (R29 companion)"],
    ),
    (
        "semantic-merge-relisted-in-known-subcommands",
        CLI_MCP,
        [('        "dag-waves",\n', '        "dag-waves",\n        "semantic-merge", // MUTATION\n')],
        "m3SemanticMergeCommandAndMCPToolRemoved",
        ["M3 decision (2026-11-21): semantic-merge CLI exits 2"],
    ),
    (
        "semantic-merge-relisted-in-help",
        CLI_MCP,
        [
            (
                "          dag-waves [--project <path.relayproj>]                Compute topological execution waves for registered DAG\n",
                "          dag-waves [--project <path.relayproj>]                Compute topological execution waves for registered DAG\n"
                "          semantic-merge <base> <left> <right>                  MUTATION\n",
            )
        ],
        "m3SemanticMergeCommandAndMCPToolRemoved",
        ["M3 decision (2026-11-21): semantic-merge CLI exits 2"],
    ),
    (
        "relay-semantic-merge-relisted-in-mcp-tools",
        CLI_MCP,
        [
            (
                '                        "name": "relay_check_ownership",\n',
                '                        "name": "relay_semantic_merge",\n                    ],\n                    [\n                        "name": "relay_check_ownership",\n',
            )
        ],
        "m3SemanticMergeCommandAndMCPToolRemoved",
        ["M3 decision (2026-11-21): semantic-merge CLI exits 2"],
    ),
]


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def verify_removed_surfaces(jobs):
    removed_abs = os.path.join(REPO, REMOVED_GATE)
    if os.path.exists(removed_abs):
        print("FAIL: %s still exists on disk" % REMOVED_GATE, file=sys.stderr)
        return False

    subprocess.run(["swift", "build", *jobs], cwd=REPO, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    cli = os.path.join(REPO, "Scripts/acceptance/relay-cli.sh")
    tmp = tempfile.mkdtemp(prefix="relayide-mut-check.")
    try:
        home = os.path.join(tmp, "home")
        os.makedirs(os.path.join(home, "Library/Preferences"), exist_ok=True)
        env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home, RELAY_CLI_HOME=home)

        for lang, expected_err in (("en", "Unknown subcommand 'semantic-merge'"), ("zh", "未知子命令 'semantic-merge'")):
            p = subprocess.run([cli, "semantic-merge", "--lang", lang], cwd=REPO, env=env, capture_output=True, text=True)
            if p.returncode != 2 or p.stdout != "" or expected_err not in p.stderr:
                print("FAIL: semantic-merge --lang %s expected exit 2 / empty stdout / %r, got %d / %r / %r"
                      % (lang, expected_err, p.returncode, p.stdout, p.stderr), file=sys.stderr)
                return False
            h = subprocess.run([cli, "--help", "--lang", lang], cwd=REPO, env=env, capture_output=True, text=True)
            if h.returncode != 0 or "semantic-merge" in h.stdout or "relay_semantic_merge" in h.stdout:
                print("FAIL: --help --lang %s still mentions removed merge entry" % lang, file=sys.stderr)
                return False

        reqs = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "relay_semantic_merge", "arguments": {}}},
        ]
        payload = "\n".join(json.dumps(r) for r in reqs) + "\n"
        m = subprocess.run([cli, "mcp"], cwd=REPO, env=env, input=payload, capture_output=True, text=True, timeout=30)
        if m.returncode != 0:
            print("FAIL: mcp exited %d: %s" % (m.returncode, m.stderr), file=sys.stderr)
            return False
        replies = {obj["id"]: obj["result"] for obj in (json.loads(l) for l in m.stdout.splitlines() if l.strip())}
        names = [t["name"] for t in replies[2]["tools"]]
        if "relay_semantic_merge" in names:
            print("FAIL: MCP tools/list still contains relay_semantic_merge: %r" % (names,), file=sys.stderr)
            return False
        if replies[3].get("isError") is not True or replies[3].get("content") != [
            {"type": "text", "text": "Unknown tool 'relay_semantic_merge'"}
        ]:
            print("FAIL: MCP tools/call relay_semantic_merge unexpected reply: %r" % (replies[3],), file=sys.stderr)
            return False
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("=== preflight: LineAnchoredGuardedMerge.swift absent; semantic-merge exits 2; --help & MCP tools/list clean")
    return True


def main():
    args = sys.argv[1:]
    if "--list" in args:
        for name, *_ in MUTATIONS:
            print(name)
        return 0
    allow_dirty = "--allow-dirty" in args
    selected = {a for a in args if not a.startswith("--")}
    unknown = selected - {m[0] for m in MUTATIONS}
    if unknown:
        print("unknown mutation(s): %s" % ", ".join(sorted(unknown)), file=sys.stderr)
        return 2
    target_files = sorted({m[1] for m in MUTATIONS if not selected or m[0] in selected})
    if not allow_dirty:
        dirty = subprocess.run(
            ["git", "status", "--porcelain", "--", *target_files],
            cwd=REPO,
            stdout=subprocess.PIPE,
        ).stdout.decode().strip()
        if dirty:
            print("refusing to mutate files with uncommitted changes (use --allow-dirty):\n" + dirty, file=sys.stderr)
            return 2
    jobs = ["-j", os.environ["RELAY_SWIFT_JOBS"]] if os.environ.get("RELAY_SWIFT_JOBS") else []

    if not verify_removed_surfaces(jobs):
        return 1

    all_caught = True
    for name, rel, edits, test_filter, must_be_red in MUTATIONS:
        if selected and name not in selected:
            continue
        path = os.path.join(REPO, rel)
        with open(path, "rb") as fh:
            original = fh.read()
        original_hash = sha(path)
        text = original.decode("utf-8")
        for old, new in edits:
            if text.count(old) != 1:
                print("=== %s: cannot apply, the source line to mutate was not found exactly once" % name)
                return 2
            text = text.replace(old, new)
        try:
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
            proc = subprocess.run(
                ["swift", "test", *jobs, "--no-parallel", "--filter", test_filter],
                cwd=REPO,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
        finally:
            with open(path, "wb") as fh:
                fh.write(original)
        if sha(path) != original_hash:
            print("=== %s: FAILED TO RESTORE %s" % (name, rel))
            return 2
        log = proc.stdout.decode("utf-8", "replace")
        red = sorted({l.split('"')[1] for l in log.splitlines() if l.startswith('✘ Test "') and " failed after " in l})
        green = sorted({l.split('"')[1] for l in log.splitlines() if l.startswith('✔ Test "') and " passed after " in l})
        missed = [needle for needle in must_be_red if not any(needle in test for test in red)]
        print(
            "=== %s: swift test exit=%d; red=%d, green=%d; %s"
            % (name, proc.returncode, len(red), len(green), "CAUGHT" if not missed and red else "NOT CAUGHT")
        )
        for test in red:
            print("    RED   " + test)
        if missed or not red:
            all_caught = False
            for needle in missed:
                print("    expected to go red but did not: " + needle)
            if not red and not green:
                print("    no test results (build problem?):")
                print("\n".join("      " + l for l in log.splitlines()[-12:]))
        sys.stdout.flush()

    # Leave the build products matching the restored sources.
    subprocess.run(["swift", "build", "--build-tests", *jobs], cwd=REPO, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("all mutations caught; sources restored" if all_caught else "SOME MUTATIONS WERE NOT CAUGHT; sources restored")
    return 0 if all_caught else 1


if __name__ == "__main__":
    sys.exit(main())
