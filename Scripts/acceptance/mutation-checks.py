#!/usr/bin/env python3
"""Mutation checks for the guarded `semantic-merge` (not part of `Scripts/test.sh`; run by hand).

Each mutation breaks one piece of the implementation in place, runs the tests that are supposed to notice,
checks that the expected tests go red, and restores the file byte for byte (verified by SHA-256).
The script exits 0 only if every mutation was caught by every test listed for it.

Usage:
  Scripts/acceptance/mutation-checks.py                 run every mutation
  Scripts/acceptance/mutation-checks.py --list          list mutation names
  Scripts/acceptance/mutation-checks.py NAME [NAME...]  run the named mutations only
  --allow-dirty   run although the files to be mutated have uncommitted changes
Environment: RELAY_SWIFT_JOBS=<n> caps build parallelism.

Do not interrupt it with SIGKILL: a killed run can leave a mutated source file behind
(`git diff -- Sources/RelaySemanticMerge` shows it; every mutated line carries the comment `// MUTATION`).
Python 3.9 compatible, standard library only.
"""
import hashlib
import os
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VALIDATOR = "Sources/RelaySemanticMerge/LanguageSyntaxValidator.swift"
GATE = "Sources/RelaySemanticMerge/LineAnchoredGuardedMerge.swift"


def bypass(signature, parser):
    return (signature, signature + '\n        if Bool(true) { return SyntaxValidationVerdict(passed: true, parserUsed: "%s") } // MUTATION' % parser)


# name, file, [(old, new)], test filter, substrings of the test names that must go red
MUTATIONS = [
    ("syntax-check-off-swift", VALIDATOR,
     [bypass("    private static func validateSwift(source: String) -> SyntaxValidationVerdict {", "swiftc -parse")],
     "SyntaxGateExits3", ["not valid Swift (R29)"]),
    ("syntax-check-off-javascript", VALIDATOR,
     [bypass("    private static func validateJavaScript(source: String, fileExtension: String) -> SyntaxValidationVerdict {", "node --check")],
     "SyntaxGateExits3", ["not valid JavaScript (R29)"]),
    ("syntax-check-off-typescript", VALIDATOR,
     [bypass("    private static func validateTypeScript(source: String, fileExtension: String) -> SyntaxValidationVerdict {", "node stripTypeScriptTypes + --check")],
     "SyntaxGateExits3", ["not valid TypeScript (R29)"]),
    ("syntax-check-off-python", VALIDATOR,
     [bypass("    private static func validatePython(source: String) -> SyntaxValidationVerdict {", "python3 -m py_compile")],
     "SyntaxGateExits3", ["not valid Python (R29 companion)"]),
    ("engine-agreement-not-required", GATE,
     [("        guard offset >= 0, offset + needle.count <= haystack.count else { return false }",
       "        if Bool(true) { return true } // MUTATION\n        guard offset >= 0, offset + needle.count <= haystack.count else { return false }"),
      ("        guard cursor == engineLines.count else {", "        guard cursor == engineLines.count || Bool(true) else { // MUTATION")],
     "guardedMerger|semanticMergeFixtureSweep",
     ["falls back to git's conflict text when the engine does not reproduce every non-blank line in place",
      "semantic-merge on every Fixtures/merge-cases case"]),
    ("conflicts-touching-base-lines-allowed", GATE,
     [("                if !baseLines.isEmpty {", "                if !baseLines.isEmpty && Bool(false) { // MUTATION")],
     "guardedMerger|semanticMergeFixtureSweep",
     ["never resolves a conflict block that modifies or deletes base lines"]),
    ("engine-text-emitted", GATE,
     [("        let assembledText = String(decoding: assembled, as: UTF8.self)", "        let assembledText = report.mergedText // MUTATION")],
     "guardedMerger|semanticMergeFixtureSweep",
     ["keeps both insertions using git's bytes, not the engine's reformatted text",
      "semantic-merge on every Fixtures/merge-cases case"]),
    ("engine-consulted-without-syntax-checker", GATE,
     [("        guard LanguageSyntaxValidator.hasSyntaxChecker(forFilePath: relativePath) else {",
       "        guard LanguageSyntaxValidator.hasSyntaxChecker(forFilePath: relativePath) || Bool(true) else { // MUTATION")],
     "guardedMerger|semanticMergeVerbatimStdoutNotes",
     ["behaves exactly like git merge-file for file types without a syntax checker"]),
    ("git-not-verified", GATE,
     [("        guard hasOpeningMarker else {", "        guard hasOpeningMarker || Bool(true) else { // MUTATION"),
      ("            if result.exitedNormally, result.status == 0, text.hasPrefix(\"git version \") {", "            if Bool(true) { // MUTATION")],
     "guardedMergerRefusesWithoutWorkingGit",
     ["refuses to merge when git is missing, is not git, or fails"]),
]


def sha(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


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
    if not allow_dirty:
        dirty = subprocess.run(["git", "status", "--porcelain", "--", VALIDATOR, GATE], cwd=REPO,
                               stdout=subprocess.PIPE).stdout.decode().strip()
        if dirty:
            print("refusing to mutate files with uncommitted changes (use --allow-dirty):\n" + dirty, file=sys.stderr)
            return 2
    jobs = ["-j", os.environ["RELAY_SWIFT_JOBS"]] if os.environ.get("RELAY_SWIFT_JOBS") else []

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
            proc = subprocess.run(["swift", "test", *jobs, "--no-parallel", "--filter", test_filter],
                                  cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        finally:
            with open(path, "wb") as fh:
                fh.write(original)
        if sha(path) != original_hash:
            print("=== %s: FAILED TO RESTORE %s" % (name, rel))
            return 2
        log = proc.stdout.decode("utf-8", "replace")
        red = sorted({l.split('"')[1] for l in log.splitlines() if l.startswith("✘ Test \"") and " failed after " in l})
        green = sorted({l.split('"')[1] for l in log.splitlines() if l.startswith("✔ Test \"") and " passed after " in l})
        missed = [needle for needle in must_be_red if not any(needle in test for test in red)]
        print("=== %s: swift test exit=%d; red=%d, green=%d; %s" % (
            name, proc.returncode, len(red), len(green), "CAUGHT" if not missed and red else "NOT CAUGHT"))
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
