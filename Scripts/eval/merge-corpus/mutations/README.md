# M3 Semantic Merge Mutation Patches (Row 17: A & B)

These unified diff patches correspond to Acceptance Row 17 mutations **A** and **B** (`03-relayide.md` §M3) against the post-R70 source tree. Never apply them directly inside a dirty working tree without restoring afterwards; build each mutant inside an isolated source copy under `$RELAY_MERGE_CORPUS_DIR/mutants/<A|B>/src`.

## Patches

1. **`A-no-guards.patch`** (`Sources/RelaySemanticMerge/LineAnchoredGuardedMerge.swift`)
   - Removes all post-`git merge-file` guards on conflict files (syntax-checker availability check, final-newline consistency check, `--diff3` empty-base pure-insertion check, line-by-line non-blank agreement check, and post-merge syntax validation).
   - Whenever `git merge-file` reports conflicts and `ThreeWaySemanticASTMerger().mergeFile(...)` reports `isCleanlyMerged == true`, `LineAnchoredGuardedMerger` directly returns `.clean` with `report.mergedText`.
   - **Expected acceptance failure**: Row 6 fails (`damaged > 0` on the conflict corpus).

2. **`B-validator-pass.patch`** (`Sources/RelaySemanticMerge/LanguageSyntaxValidator.swift`)
   - Replaces `validatePython`, `validateSwift`, and `validateTypeScript` so all three unconditionally return `SyntaxValidationVerdict(passed: true, ...)`.
   - **Expected acceptance failure**: Row 12 fails (`Fixtures/syntax-gate-cases` for Python, Swift, and TypeScript exit `0` instead of `3`, and `classify.py --fixed-cases` reports `damaged >= 1`).

## Isolated Build & Smoke-Check Procedure

```bash
MUT_ROOT="${RELAY_MERGE_CORPUS_DIR}/mutants"

for M in A B; do
  PATCH_FILE="$(ls Scripts/eval/merge-corpus/mutations/${M}-*.patch)"
  SRC_DIR="${MUT_ROOT}/${M}/src"
  rm -rf "${SRC_DIR}"
  mkdir -p "${SRC_DIR}"
  rsync -a --exclude '.git' --exclude '.build' ./ "${SRC_DIR}/"
  (
    cd "${SRC_DIR}"
    /usr/bin/patch -p1 --forward < "${OLDPWD}/${PATCH_FILE}"
    swift build -c release --product RelayIDE
  )
done
```

Invoke a mutant binary exclusively through `Scripts/acceptance/relay-cli.sh`:

```bash
TMP_HOME="$(mktemp -d)"
RELAY_CLI_HOME="${TMP_HOME}" \
RELAY_CLI_BIN="${RELAY_MERGE_CORPUS_DIR}/mutants/A/src/.build/release/RelayIDE" \
  Scripts/acceptance/relay-cli.sh semantic-merge \
  Fixtures/merge-cases/01-swift-samefunc-difflines/base.swift \
  Fixtures/merge-cases/01-swift-samefunc-difflines/left.swift \
  Fixtures/merge-cases/01-swift-samefunc-difflines/right.swift \
  --lang en
rm -rf "${TMP_HOME}"
```
