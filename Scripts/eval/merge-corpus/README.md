# Merge Evaluation Corpus (`Scripts/eval/merge-corpus`)

This directory contains the repository manifest, corpus extractor, and fixed syntax-parser module used by Milestone 3 (semantic merge evaluation).

## Repository Selection Criteria

`repos.tsv` pins 9 public open-source repositories (3 per language: Python, Swift, TypeScript) selected in Stage 0 against the following criteria:

1. **Public & OSI-approved license**: Publicly accessible over anonymous HTTPS with an OSI-approved license verified against the repository's `LICENSE*` file at the pinned commit.
2. **Merge-commit history on the default branch**: At least **1,000** two-parent merge commits (`git rev-list --min-parents=2 --max-parents=2 <commit>`) on the default branch.
3. **Packed repository size**: Bare clone size **<= 1 GB** (1,024 MB).
4. **Target-language two-sided modifications**: At least **300** target-language files changed on both sides across single-base two-parent merges.

### Stage 0 Screening Notes

- The 3 feasibility-check repositories (`pytest-dev/pytest`, `realm/SwiftLint`, `apollographql/apollo-client`) met all criteria directly and were retained at their pinned default-branch commits.
- Six additional Swift candidates were screened in Stage 0 and **excluded** because they missed one of the thresholds:
  - `Alamofire/Alamofire`: 159 two-parent merges on default branch (`master`) < 1,000.
  - `ReactiveX/RxSwift`: 513 two-parent merges on default branch (`main`) < 1,000.
  - `Moya/Moya`: 882 two-parent merges on default branch (`master`) < 1,000.
  - `onevcat/Kingfisher`: 900 two-parent merges on default branch (`master`) < 1,000.
  - `Quick/Nimble`: 521 two-parent merges on default branch (`main`) < 1,000.
  - `realm/realm-swift`: 2,821 two-parent merges on default branch (`community`, 84 MB), but only **298** Swift files modified on both sides (< 300).

## Environment Variables

Raw repository clones and extracted case blobs are never committed to this repository. No script uses a fallback path inside the repository or user `Library` directory.

- `RELAY_MERGE_CORPUS_DIR` *(required)*: Directory holding bare clones (`$RELAY_MERGE_CORPUS_DIR/bare/<owner>__<repo>.git`) and extracted case files (`$RELAY_MERGE_CORPUS_DIR/extract/cases/<case_id>/`). If unset, `extract.py` prints `没跑：没有语料缓存` and exits with code `2`.
- `RELAY_EVAL_PYTHON` *(required when parsing Python)*: Path to a CPython `>= 3.12` executable used for `python -I -c "ast.parse(...)"`. If unset, `parsers.py` / `extract.py` prints `没跑` and exits with code `2`.
- `RELAY_EVAL_TYPESCRIPT` *(required when parsing TypeScript)*: Path to a local `typescript` npm package directory loaded by `node` to check `ts.createSourceFile(...).parseDiagnostics` only (no type checking). If unset, `parsers.py` / `extract.py` prints `没跑` and exits with code `2`.
- `RELAY_EVAL_SWIFTC` *(optional)*: Override for `swiftc` (defaults to `swiftc` on `PATH`, invoked as `swiftc -frontend -parse`).

## Commands

```bash
# Anonymous bare clone of missing repos in repos.tsv (the ONLY step that accesses the network)
python3 -I Scripts/eval/merge-corpus/extract.py --fetch

# Count merges, skips, and candidate/conflict totals without writing extracted case files
python3 -I Scripts/eval/merge-corpus/extract.py --count-only

# Extract conflict cases + deterministic 500-file clean sample and write Fixtures/merge-corpus/cases.tsv
python3 -I Scripts/eval/merge-corpus/extract.py

# Verify repos.tsv licenses, Extraction accounting, Row 4 thresholds, and Row 5 git invariants
python3 -I Scripts/eval/merge-corpus/extract.py --verify

# Run extractor unit tests
python3 -I -m unittest Scripts/eval/merge-corpus/test_extract.py

# Run classifier git self-check on cases.tsv + optional tool result TSVs
python3 -I Scripts/eval/merge-corpus/classify.py [--tool cli=path/to/cli.tsv ...] [--summary-out summary.tsv] [--details-out details.tsv] [--rejected-out rejected.tsv]

# Classify the 39 fixed cases (35 merge-cases + 4 syntax-gate-cases) and write/check CLASSIFIED.tsv
python3 -I Scripts/eval/merge-corpus/classify.py --fixed-cases --write-classified Fixtures/merge-cases/CLASSIFIED.tsv
python3 -I Scripts/eval/merge-corpus/classify.py --fixed-cases --check-classified Fixtures/merge-cases/CLASSIFIED.tsv

# Run classifier unit tests
python3 -I -m unittest Scripts/eval/merge-corpus/test_classify.py
```

## Manifest Schemas

### `repos.tsv`

Tab-separated columns:
`language`, `extensions`, `url`, `default_branch`, `commit`, `license`

### `Fixtures/merge-corpus/cases.tsv`

Tab-separated columns:
`case_id`, `kind` (`conflict` | `clean`), `language`, `repo`, `merge`, `p1`, `p2`, `base`, `path`, `blob_base`, `blob_left`, `blob_right`, `blob_human`, `myers_conflicts`, `histogram_conflicts`, `pure_insertion` (`0` | `1`), `human_eq` (`left` | `right` | `none`), `human_parses` (`0` | `1`)

For each row in `cases.tsv`, the extracted four versions live at:
`$RELAY_MERGE_CORPUS_DIR/extract/cases/<case_id>/{base,left,right,human}<ext>` where `<ext>` is `os.path.splitext(path)[1]`.

### Tool Result Input TSV (`classify.py --tool <name>=<path>`)

UTF-8 tab-separated file (blank lines and `#` comments ignored; optional header row starting with `case_id` is skipped):
`case_id`, `exit_code`, `claimed_clean` (`1` | `0` | `skip`), `output_path`, `reason` *(optional)*, `strategy` *(optional)*

### `Fixtures/merge-cases/CLASSIFIED.tsv`

Tab-separated columns across the 39 fixed cases (`35` in `Fixtures/merge-cases` + `4` in `Fixtures/syntax-gate-cases`):
`case_id`, `ext`, `reference` (`expected` | `git_clean` | `true_conflict`), `git`, `cli_exit`, `cli_strategy`, `cli`, `cli_reason`, `engine` *(populated in Stage 4 via `--engine-tsv`)*
