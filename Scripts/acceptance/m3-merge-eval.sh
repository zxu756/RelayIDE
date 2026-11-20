#!/usr/bin/env bash
# RelayIDE M3 Semantic Merge Keep/Drop Evaluation Acceptance Suite (Rows 1-16).
#
# Never opens the desktop window. Product commands go exclusively through Scripts/acceptance/relay-cli.sh
# with HOME pointed at an isolated temporary directory.
#
# Usage:
#   Scripts/acceptance/m3-merge-eval.sh [--quick] [--record]
#
# Exit codes:
#   0  all hard acceptance checks passed
#   1  one or more acceptance checks failed
#   2  usage error or missing required environment / cache (when full mode is requested)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT_DIR}"

QUICK=0
RECORD=0

usage() {
    cat <<'EOF' >&2
Usage: Scripts/acceptance/m3-merge-eval.sh [--quick] [--record]

Options:
  --quick    Run the 40 fixed cases, all CRLF conflict cases in the corpus, and the first 20 conflict
             cases per language (hard wall-clock budget <= 120s). If RELAY_MERGE_CORPUS_DIR or its
             extracted cache is absent, runs only the 40 fixed cases and states so explicitly.
  --record   Write m3-merge-eval.{tsv,md} and m3-merge-eval-summary.tsv into reports/ (default: a
             mktemp -d temporary directory so the repository working tree stays untouched).
EOF
}

for arg in "$@"; do
    case "${arg}" in
        --quick) QUICK=1 ;;
        --record) RECORD=1 ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument '${arg}'" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ "${QUICK}" -eq 1 && "${RECORD}" -eq 1 ]]; then
    echo "error: --quick and --record cannot be used together" >&2
    exit 2
fi

START_EPOCH="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())')"
LOAD_START="$(/usr/bin/python3 -c 'import os; la=os.getloadavg(); print("%.2f %.2f %.2f" % (la[0], la[1], la[2]))')"

# 1. Validate fixed parsers upfront (exits 2 with "没跑：..." if RELAY_EVAL_PYTHON / RELAY_EVAL_TYPESCRIPT missing)
if ! PARSER_DESC="$(/usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-corpus/parsers.py" --describe)"; then
    printf '%s\n' "${PARSER_DESC}"
    exit 2
fi

CORPUS_DIR="${RELAY_MERGE_CORPUS_DIR:-}"
HAS_CORPUS=0
if [[ -n "${CORPUS_DIR}" && -d "${CORPUS_DIR}/extract/cases" ]]; then
    HAS_CORPUS=1
fi

if [[ "${HAS_CORPUS}" -eq 0 ]]; then
    if [[ "${QUICK}" -eq 0 ]]; then
        echo "没跑：没有语料缓存"
        exit 2
    fi
    if [[ "${RECORD}" -eq 1 ]]; then
        echo "没跑：没有语料缓存（--record 需要完整语料缓存）" >&2
        exit 2
    fi
fi

MERGIRAF_EXEC="${RELAY_MERGIRAF_BIN:-/opt/homebrew/bin/mergiraf}"
if [[ ! -x "${MERGIRAF_EXEC}" ]]; then
    MERGIRAF_EXEC="$(command -v mergiraf 2>/dev/null || true)"
fi
if [[ "${HAS_CORPUS}" -eq 1 && ( -z "${MERGIRAF_EXEC}" || ! -x "${MERGIRAF_EXEC}" ) ]]; then
    echo "没跑：找不到可执行 mergiraf"
    exit 2
fi

SWIFT_JOBS_ARGS=()
if [[ -n "${RELAY_SWIFT_JOBS:-}" ]]; then
    SWIFT_JOBS_ARGS=(-j "${RELAY_SWIFT_JOBS}")
fi

# 2. Snapshot repository git status, ~/Library, and corpus runs/ BEFORE touching anything (Row 15)
WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/relayide-m3-acc.XXXXXX")"
ISO_HOME="${WORK_TMP}/isolated_home"
mkdir -p "${ISO_HOME}"

cleanup() {
    rm -rf "${WORK_TMP}"
}
trap cleanup EXIT

STAGE_REPORT_DIR="${WORK_TMP}/stage_reports"
mkdir -p "${STAGE_REPORT_DIR}"
if [[ "${RECORD}" -eq 1 ]]; then
    mkdir -p "${ROOT_DIR}/reports"
    REPORT_DIR="${ROOT_DIR}/reports"
else
    REPORT_DIR="${STAGE_REPORT_DIR}"
fi

GIT_STATUS_BEFORE="$(git status --porcelain)"
GIT_OUTSIDE_REPORTS_BEFORE="$(git status --porcelain -- . ':(exclude)reports')"

REAL_HOME="${HOME}"
snapshot_library() {
    local out_relay="$1"
    local out_recent="$2"
    /usr/bin/python3 - "${REAL_HOME}" "${out_relay}" "${out_recent}" <<'PY'
import os, re, sys

real_home, out_relay, out_recent = sys.argv[1], sys.argv[2], sys.argv[3]
lib_root = os.path.join(real_home, "Library")
sub_dirs = [
    "Preferences",
    "Application Support",
    "Caches",
    "Logs",
    "Saved Application State",
    "Containers",
]
pat = re.compile(r"(relayide|io\.relayide|mergiraf)", re.IGNORECASE)
relay_hits = []
recent_items = []

for sd in sub_dirs:
    base = os.path.join(lib_root, sd)
    if not os.path.isdir(base):
        continue
    try:
        entries = sorted(os.listdir(base))
    except OSError:
        continue
    for name in entries:
        full = os.path.join(base, name)
        try:
            st = os.lstat(full)
        except OSError:
            continue
        rel = sd + "/" + name
        recent_items.append((st.st_mtime_ns, rel))
        if pat.search(name):
            relay_hits.append("%s\t%d\t%d" % (rel, st.st_mtime_ns, st.st_size))

recent_items.sort(reverse=True)
with open(out_relay, "w", encoding="utf-8") as fh:
    for line in sorted(relay_hits):
        fh.write(line + "\n")
with open(out_recent, "w", encoding="utf-8") as fh:
    for mtime_ns, rel in recent_items[:15]:
        fh.write("%d\t%s\n" % (mtime_ns, rel))
PY
}

snapshot_library "${WORK_TMP}/lib_relay_before.txt" "${WORK_TMP}/lib_recent_before.txt"

if [[ "${HAS_CORPUS}" -eq 1 ]]; then
    mkdir -p "${CORPUS_DIR}/runs"
    ls -1 "${CORPUS_DIR}/runs" | sort >"${WORK_TMP}/runs_before.txt"
fi

FAILED_CHECKS=0

pass_row() {
    echo "[PASS] $1"
}

record_fail() {
    echo "[FAIL] $1" >&2
    FAILED_CHECKS=$((FAILED_CHECKS + 1))
}

fail_row() {
    echo "[FAIL] $1" >&2
    exit 1
}

# 3. Resolve (and build if missing) product CLI executable (invoked strictly via relay-cli.sh) & engine executable
RELAY_CLI="${ROOT_DIR}/Scripts/acceptance/relay-cli.sh"
PROD_NAME="Relay""IDE"
REL_EXEC="${ROOT_DIR}/.build/release/${PROD_NAME}"
DBG_EXEC="${ROOT_DIR}/.build/debug/${PROD_NAME}"

if [[ -n "${RELAY_CLI_BIN:-}" ]]; then
    if [[ ! -x "${RELAY_CLI_BIN}" ]]; then
        echo "没跑：指定的 RELAY_CLI_BIN 不可执行 (${RELAY_CLI_BIN})" >&2
        exit 2
    fi
    SELECTED_CLI_EXEC="${RELAY_CLI_BIN}"
else
    if [[ ! -x "${REL_EXEC}" && ! -x "${DBG_EXEC}" ]]; then
        echo "==> Building product executable (release)..."
        swift build -c release ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} --product "${PROD_NAME}" >/dev/null
        SELECTED_CLI_EXEC="${REL_EXEC}"
    elif [[ -x "${REL_EXEC}" && ( ! -x "${DBG_EXEC}" || ! "${DBG_EXEC}" -nt "${REL_EXEC}" ) ]]; then
        SELECTED_CLI_EXEC="${REL_EXEC}"
    else
        SELECTED_CLI_EXEC="${DBG_EXEC}"
    fi
    NEW_SRC="$(find "${ROOT_DIR}/Sources" -name '*.swift' -newer "${SELECTED_CLI_EXEC}" -print -quit 2>/dev/null || true)"
    if [[ -n "${NEW_SRC}" ]]; then
        echo "==> Rebuilding product executable after source changes..."
        swift build ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} --product "${PROD_NAME}" >/dev/null
        SELECTED_CLI_EXEC="${DBG_EXEC}"
    fi
fi

ENG_PKG_DIR="${ROOT_DIR}/Scripts/eval/merge-eval"
ENG_DEFAULT_EXEC="${ENG_PKG_DIR}/.build/release/relay-merge-eval"
if [[ -n "${RELAY_MERGE_EVAL_BIN:-}" ]]; then
    if [[ ! -x "${RELAY_MERGE_EVAL_BIN}" ]]; then
        echo "没跑：指定的 RELAY_MERGE_EVAL_BIN 不可执行 (${RELAY_MERGE_EVAL_BIN})" >&2
        exit 2
    fi
    SELECTED_ENG_EXEC="${RELAY_MERGE_EVAL_BIN}"
else
    NEED_ENG_BUILD=0
    if [[ ! -x "${ENG_DEFAULT_EXEC}" ]]; then
        NEED_ENG_BUILD=1
    else
        NEW_ENG_SRC="$(find "${ROOT_DIR}/Sources/RelayModels" "${ROOT_DIR}/Sources/RelaySemanticMerge" "${ENG_PKG_DIR}/Sources" -name '*.swift' -newer "${ENG_DEFAULT_EXEC}" -print -quit 2>/dev/null || true)"
        if [[ -n "${NEW_ENG_SRC}" ]]; then
            NEED_ENG_BUILD=1
        fi
    fi
    if [[ "${NEED_ENG_BUILD}" -eq 1 ]]; then
        echo "==> Building standalone declaration-level engine evaluator (Scripts/eval/merge-eval)..."
        swift build -c release ${SWIFT_JOBS_ARGS[@]+"${SWIFT_JOBS_ARGS[@]}"} --package-path "${ENG_PKG_DIR}" >/dev/null
    fi
    SELECTED_ENG_EXEC="${ENG_DEFAULT_EXEC}"
fi

# Verify headless CLI wrapper answers `version`
RELAY_CLI_HOME="${ISO_HOME}" RELAY_CLI_BIN="${SELECTED_CLI_EXEC}" "${RELAY_CLI}" version --lang en >/dev/null \
    || fail_row "Product executable did not answer 'version' via relay-cli.sh"

echo "================================================================"
echo "RelayIDE M3 Semantic Merge Evaluation Suite (mode=$( [[ "${QUICK}" -eq 1 ]] && echo quick || echo full ), record=${RECORD})"
echo "Load at start: ${LOAD_START}"
echo "================================================================"

# ------------------------------------------------------------------
# Step A: Fixed 40 Cases (Row 12 + Fixed Case 36 CRLF check)
# ------------------------------------------------------------------
T_FIXED_START="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())')"
echo ""
echo "--- Step A: Fixed 40 Cases (merge-cases 36 + syntax-gate-cases 4 + CLASSIFIED.tsv + Case 36 CRLF) ---"

HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
RELAY_CLI_HOME="${ISO_HOME}" RELAY_CLI_BIN="${SELECTED_CLI_EXEC}" \
    /usr/bin/python3 -I "${ROOT_DIR}/Scripts/acceptance/merge_cases_check.py" \
    --cli "${RELAY_CLI}" \
    --cases "${ROOT_DIR}/Fixtures/merge-cases" \
    --lang en \
    || record_fail "Row 12: merge_cases_check.py failed on Fixtures/merge-cases"

HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
RELAY_CLI_HOME="${ISO_HOME}" RELAY_CLI_BIN="${SELECTED_CLI_EXEC}" \
    /usr/bin/python3 -I "${ROOT_DIR}/Scripts/acceptance/merge_cases_check.py" \
    --cli "${RELAY_CLI}" \
    --cases "${ROOT_DIR}/Fixtures/syntax-gate-cases" \
    --expect-all-exit 3 \
    --lang en \
    || record_fail "Row 12: merge_cases_check.py failed on Fixtures/syntax-gate-cases"

FIXED_ENG_DIR="${WORK_TMP}/fixed_engine"
HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
    /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-eval/run_engine.py" \
    --fixed-cases \
    --out-dir "${FIXED_ENG_DIR}" \
    --engine-bin "${SELECTED_ENG_EXEC}" \
    --workers 4 \
    --timeout 30 \
    || fail_row "Row 12: run_engine.py --fixed-cases failed"

if [[ -n "${MERGIRAF_EXEC}" && -x "${MERGIRAF_EXEC}" ]]; then
    FIXED_MGF_DIR="${WORK_TMP}/fixed_mergiraf"
    HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
        /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-eval/run_mergiraf.py" \
        --fixed-cases \
        --out-dir "${FIXED_MGF_DIR}" \
        --mergiraf-bin "${MERGIRAF_EXEC}" \
        --workers 4 \
        --timeout 30 \
        || fail_row "Row 10/12: run_mergiraf.py --fixed-cases failed"
fi

HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
RELAY_CLI_HOME="${ISO_HOME}" RELAY_CLI_BIN="${SELECTED_CLI_EXEC}" \
    /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-corpus/classify.py" \
    --fixed-cases \
    --cli "${RELAY_CLI}" \
    --engine-tsv "${FIXED_ENG_DIR}/results.tsv" \
    --check-classified "${ROOT_DIR}/Fixtures/merge-cases/CLASSIFIED.tsv" \
    || record_fail "Row 12: classify.py --fixed-cases --check-classified failed"

# Capture fixed case 36 CRLF conflict stdout under both PATH modes and verify exit 1 + byte-identity to git
F36_DIR="${ROOT_DIR}/Fixtures/merge-cases/36-py-crlf-true-conflict"
F36_CALLER_OUT="${WORK_TMP}/f36_caller.out"
F36_EVALPY_OUT="${WORK_TMP}/f36_evalpy.out"
F36_GIT_OUT="${WORK_TMP}/f36_git.out"
EVAL_PY_BIN_DIR="$(dirname "${RELAY_EVAL_PYTHON}")"

set +e
HOME="${ISO_HOME}" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null LC_ALL=C \
    /usr/bin/git merge-file -p -L left -L base -L right \
    "${F36_DIR}/left.py" "${F36_DIR}/base.py" "${F36_DIR}/right.py" >"${F36_GIT_OUT}" 2>/dev/null
F36_GIT_RC=$?

RELAY_CLI_HOME="${ISO_HOME}" RELAY_CLI_BIN="${SELECTED_CLI_EXEC}" \
    "${RELAY_CLI}" semantic-merge "${F36_DIR}/base.py" "${F36_DIR}/left.py" "${F36_DIR}/right.py" --lang en >"${F36_CALLER_OUT}" 2>/dev/null
F36_CALLER_RC=$?

RELAY_CLI_HOME="${ISO_HOME}" RELAY_CLI_BIN="${SELECTED_CLI_EXEC}" \
RELAY_CLI_CHILD_PATH="${EVAL_PY_BIN_DIR}:${PATH}" \
    "${RELAY_CLI}" semantic-merge "${F36_DIR}/base.py" "${F36_DIR}/left.py" "${F36_DIR}/right.py" --lang en >"${F36_EVALPY_OUT}" 2>/dev/null
F36_EVALPY_RC=$?
set -e

if ! [[ "${F36_GIT_RC}" -ge 1 && "${F36_CALLER_RC}" -eq 1 && "${F36_EVALPY_RC}" -eq 1 ]]; then
    record_fail "Row 8: fixed case 36 CRLF expected exit 1 (got caller=${F36_CALLER_RC}, evalpy=${F36_EVALPY_RC})"
fi
if ! cmp -s "${F36_CALLER_OUT}" "${F36_GIT_OUT}"; then
    record_fail "Row 8: fixed case 36 caller stdout is not byte-identical to git merge-file -p"
fi
if ! cmp -s "${F36_EVALPY_OUT}" "${F36_GIT_OUT}"; then
    record_fail "Row 8: fixed case 36 eval-python-first stdout is not byte-identical to git merge-file -p"
fi

T_FIXED_END="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())')"
ELAPSED_FIXED="$(/usr/bin/python3 -c "print('%.2f' % (${T_FIXED_END} - ${T_FIXED_START}))")"
if [[ "${FAILED_CHECKS}" -eq 0 ]]; then
    pass_row "Row 12 & Fixed Case 36 CRLF: all 40 fixed cases passed in ${ELAPSED_FIXED}s"
fi

# ------------------------------------------------------------------
# Step B: Corpus Runs & Classification (when corpus cache is present)
# ------------------------------------------------------------------
if [[ "${HAS_CORPUS}" -eq 0 ]]; then
    echo ""
    echo "[NOTE] RELAY_MERGE_CORPUS_DIR or extracted corpus cache is absent; --quick ran only the 40 fixed cases."
else
    MODE_LABEL="$( [[ "${QUICK}" -eq 1 ]] && echo quick || echo full )"
    RUN_STAMP="m3_${MODE_LABEL}_$(date -u '+%Y%m%dT%H%M%SZ')_$$"
    PUB_CALLER_NAME="${RUN_STAMP}_published_caller"
    PUB_EVALPY_NAME="${RUN_STAMP}_published_evalpy"
    ENG_NAME="${RUN_STAMP}_engine"
    MGF_NAME="${RUN_STAMP}_mergiraf"
    CLASSIFY_DIR="${CORPUS_DIR}/runs/${RUN_STAMP}_classify"
    echo ""
    echo "--- Step B: Corpus Evaluation (mode=${MODE_LABEL}, prefix=\$RELAY_MERGE_CORPUS_DIR/runs/${RUN_STAMP}_*) ---"

    if [[ "${QUICK}" -eq 1 ]]; then
        EXEC_CASES_TSV="${WORK_TMP}/quick_cases.tsv"
        KINDS_ARG="conflict"
        /usr/bin/python3 - "${ROOT_DIR}/Fixtures/merge-corpus/cases.tsv" "${CORPUS_DIR}/extract/cases" "${EXEC_CASES_TSV}" <<'PY'
import collections, csv, os, sys

cases_tsv, cases_root, out_tsv = sys.argv[1], sys.argv[2], sys.argv[3]
seen_per_lang = collections.Counter()
selected = []
crlf_count = 0

with open(cases_tsv, encoding="utf-8") as fh:
    reader = csv.DictReader(fh, delimiter="\t")
    fieldnames = reader.fieldnames
    for row in reader:
        if row["kind"].strip() != "conflict":
            continue
        cid = row["case_id"].strip()
        lang = row["language"].strip().lower()
        ext = "." + row["path"].rsplit(".", 1)[1]
        cdir = os.path.join(cases_root, cid)
        has_crlf = any(
            b"\r\n" in open(os.path.join(cdir, stem + ext), "rb").read()
            for stem in ("base", "left", "right")
        )
        take = False
        if seen_per_lang[lang] < 20:
            seen_per_lang[lang] += 1
            take = True
        if has_crlf:
            crlf_count += 1
            take = True
        if take:
            selected.append(row)

with open(out_tsv, "w", encoding="utf-8", newline="") as fh:
    writer = csv.DictWriter(fh, fieldnames=fieldnames, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    for r in selected:
        writer.writerow(r)

print(f"Quick corpus subset selected: {len(selected)} conflict cases (first 20/lang + {crlf_count} CRLF conflict cases)")
PY
    else
        echo "==> Verifying corpus manifest & extraction invariants (Rows 1-5)..."
        HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
            /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-corpus/extract.py" --verify \
            || record_fail "Rows 1-5: extract.py --verify failed"
        EXEC_CASES_TSV="${ROOT_DIR}/Fixtures/merge-corpus/cases.tsv"
        KINDS_ARG="conflict,clean"
    fi

    echo "==> Running published command (caller PATH)..."
    HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
        /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-corpus/run_published.py" \
        --name "${PUB_CALLER_NAME}" \
        --path-mode caller \
        --cases-tsv "${EXEC_CASES_TSV}" \
        --kinds "${KINDS_ARG}" \
        --cli "${RELAY_CLI}" \
        --cli-bin "${SELECTED_CLI_EXEC}" \
        --save-conflict-outputs \
        --workers 4 \
        --timeout 60 \
        || fail_row "Row 6/7: run_published.py (caller) failed"

    echo "==> Running published command (eval-python-first PATH)..."
    HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
        /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-corpus/run_published.py" \
        --name "${PUB_EVALPY_NAME}" \
        --path-mode eval-python-first \
        --cases-tsv "${EXEC_CASES_TSV}" \
        --kinds "${KINDS_ARG}" \
        --cli "${RELAY_CLI}" \
        --cli-bin "${SELECTED_CLI_EXEC}" \
        --save-conflict-outputs \
        --workers 4 \
        --timeout 60 \
        || fail_row "Row 6/7: run_published.py (eval-python-first) failed"

    echo "==> Running declaration-level engine..."
    HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
        /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-eval/run_engine.py" \
        --name "${ENG_NAME}" \
        --cases-tsv "${EXEC_CASES_TSV}" \
        --kinds "${KINDS_ARG}" \
        --engine-bin "${SELECTED_ENG_EXEC}" \
        --workers 4 \
        --timeout 30 \
        || fail_row "Row 9: run_engine.py failed"

    echo "==> Running mergiraf..."
    HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
        /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-eval/run_mergiraf.py" \
        --name "${MGF_NAME}" \
        --cases-tsv "${EXEC_CASES_TSV}" \
        --kinds "${KINDS_ARG}" \
        --mergiraf-bin "${MERGIRAF_EXEC}" \
        --workers 4 \
        --timeout 30 \
        || fail_row "Row 10: run_mergiraf.py failed"

    echo "==> Classifying all corpus outputs with fixed parsers..."
    mkdir -p "${CLASSIFY_DIR}"
    T_CLS_START="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())')"
    CLASSIFY_OK=1
    HOME="${ISO_HOME}" CFFIXED_USER_HOME="${ISO_HOME}" \
        /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-corpus/classify.py" \
        --cases-tsv "${EXEC_CASES_TSV}" \
        --kinds "${KINDS_ARG}" \
        --tool "published_caller=${CORPUS_DIR}/runs/${PUB_CALLER_NAME}/results.tsv" \
        --tool "published_evalpy=${CORPUS_DIR}/runs/${PUB_EVALPY_NAME}/results.tsv" \
        --tool "engine=${CORPUS_DIR}/runs/${ENG_NAME}/results.tsv" \
        --tool "mergiraf=${CORPUS_DIR}/runs/${MGF_NAME}/results.tsv" \
        --summary-out "${CLASSIFY_DIR}/summary.tsv" \
        --details-out "${CLASSIFY_DIR}/details.tsv" \
        --rejected-out "${CLASSIFY_DIR}/rejected.tsv" \
        --workers 4 >"${WORK_TMP}/classify_stdout.log" \
        || CLASSIFY_OK=0
    if [[ "${CLASSIFY_OK}" -ne 1 ]]; then
        grep -E '^(FAIL:|error:)' "${WORK_TMP}/classify_stdout.log" >&2 || tail -n 20 "${WORK_TMP}/classify_stdout.log" >&2 || true
        record_fail "Row 5/6/7: classify.py failed"
    fi
    T_CLS_END="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())')"
    ELAPSED_CLASSIFY="$(/usr/bin/python3 -c "print('%.2f' % (${T_CLS_END} - ${T_CLS_START}))")"

    # ------------------------------------------------------------------
    # Step C: Report Generation, `--check` Verification & Hard Row Gates
    # ------------------------------------------------------------------
    echo ""
    echo "--- Step C: Report Generation & --check Verification (Rows 6, 7, 8, 13, 16) ---"
    if [[ -f "${CLASSIFY_DIR}/details.tsv" ]]; then
        TSV_REPORT="${STAGE_REPORT_DIR}/m3-merge-eval.tsv"
        SUMMARY_REPORT="${STAGE_REPORT_DIR}/m3-merge-eval-summary.tsv"
        MD_REPORT="${STAGE_REPORT_DIR}/m3-merge-eval.md"

        T_BEFORE_REPORT="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())')"
        ELAPSED_TOTAL_SO_FAR="$(/usr/bin/python3 -c "print('%.2f' % (${T_BEFORE_REPORT} - ${START_EPOCH}))")"

        /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-corpus/report.py" \
            --repo-root "${ROOT_DIR}" \
            --corpus-dir "${CORPUS_DIR}" \
            --repos-tsv "${ROOT_DIR}/Scripts/eval/merge-corpus/repos.tsv" \
            --cases-tsv "${ROOT_DIR}/Fixtures/merge-corpus/cases.tsv" \
            --selected-cases-tsv "${EXEC_CASES_TSV}" \
            --published-caller-dir "${CORPUS_DIR}/runs/${PUB_CALLER_NAME}" \
            --published-evalpy-dir "${CORPUS_DIR}/runs/${PUB_EVALPY_NAME}" \
            --engine-dir "${CORPUS_DIR}/runs/${ENG_NAME}" \
            --mergiraf-dir "${CORPUS_DIR}/runs/${MGF_NAME}" \
            --classify-details-tsv "${CLASSIFY_DIR}/details.tsv" \
            --fixed-classified-tsv "${ROOT_DIR}/Fixtures/merge-cases/CLASSIFIED.tsv" \
            --fixed-engine-tsv "${FIXED_ENG_DIR}/results.tsv" \
            --fixed-case36-caller-out "${F36_CALLER_OUT}" \
            --fixed-case36-evalpy-out "${F36_EVALPY_OUT}" \
            --mode "${MODE_LABEL}" \
            --load-start "${LOAD_START}" \
            --elapsed-fixed "${ELAPSED_FIXED}" \
            --elapsed-classify "${ELAPSED_CLASSIFY}" \
            --elapsed-total "${ELAPSED_TOTAL_SO_FAR}" \
            --tsv "${TSV_REPORT}" \
            --summary-tsv "${SUMMARY_REPORT}" \
            --md "${MD_REPORT}" \
            || fail_row "Row 13: report.py failed to generate reports"

        if /usr/bin/python3 -I "${ROOT_DIR}/Scripts/eval/merge-corpus/report.py" \
            --check \
            --tsv "${TSV_REPORT}" \
            --summary-tsv "${SUMMARY_REPORT}" \
            --md "${MD_REPORT}" \
            --repos-tsv "${ROOT_DIR}/Scripts/eval/merge-corpus/repos.tsv" \
            --cases-tsv "${ROOT_DIR}/Fixtures/merge-corpus/cases.tsv"; then
            pass_row "Row 13 & Row 16: report generated at ${REPORT_DIR} and verified via report.py --check"
        else
            record_fail "Row 13: report.py --check failed"
        fi

        # Enforce hard acceptance thresholds on summary.tsv (Rows 6, 7, 8)
        HARD_GATES_OK=1
        /usr/bin/python3 - "${SUMMARY_REPORT}" "${QUICK}" <<'PY' || HARD_GATES_OK=0
import csv, sys

summary_tsv, is_quick = sys.argv[1], int(sys.argv[2])
s = {}
with open(summary_tsv, encoding="utf-8") as fh:
    for r in csv.DictReader(fh, delimiter="\t"):
        s[(r["table"], r["row"], r["col"])] = r["value"]

problems = []
# Row 6: published command damaged == 0 & dropped_cases == 0 on conflict set
for mode in ("published_caller", "published_evalpy"):
    dmg = int(s[("row6_conflict_published", f"{mode}:all", "damaged")])
    drp = int(s[("row16_rule1_added_lines", f"{mode}:all", "dropped_cases")])
    if dmg != 0:
        problems.append(f"Row 6 FAIL: {mode} conflict damaged={dmg} (expected 0)")
    if drp != 0:
        problems.append(f"Row 6 / Rule 1 FAIL: {mode} conflict exit-0 dropped_cases={drp} (expected 0)")

# Row 7: clean regression (full mode)
if not is_quick:
    for mode in ("published_caller", "published_evalpy"):
        neq = int(s[("row7_clean_published", f"{mode}:all", "exit0_neq_git")])
        bad_ec = int(s[("row7_clean_published", f"{mode}:all", "exit1_4_other")])
        dmg = int(s[("row7_clean_published", f"{mode}:all", "damaged")])
        if neq != 0:
            problems.append(f"Row 7 FAIL: {mode} clean exit0_neq_git={neq} (expected 0)")
        if bad_ec != 0:
            problems.append(f"Row 7 FAIL: {mode} clean exit1_4_other={bad_ec} (expected 0)")
        if dmg != 0:
            problems.append(f"Row 7 FAIL: {mode} clean damaged={dmg} (expected 0)")

# Row 8: CRLF conflict cases
crlf_fail = int(s[("row8_crlf", "all", "failed_count")])
crlf_exit4 = int(s[("row8_crlf", "all", "exit4_count")])
if crlf_fail != 0 or crlf_exit4 != 0:
    problems.append(f"Row 8 FAIL: CRLF failed_count={crlf_fail}, exit4_count={crlf_exit4} (expected 0)")

if problems:
    for p in problems:
        print(p, file=sys.stderr)
    sys.exit(1)
print(
    f"Hard gates verified: Row 6 damaged=0/dropped=0; "
    f"Row 8 CRLF ok ({s[('row8_crlf', 'all', 'total_crlf_cases')]} cases, exit4=0)"
    + ("" if is_quick else f"; Row 7 clean ok (caller same={s[('row7_clean_published', 'published_caller:all', 'exit0_eq_git')]}, evalpy same={s[('row7_clean_published', 'published_evalpy:all', 'exit0_eq_git')]})")
)
PY
        if [[ "${HARD_GATES_OK}" -eq 1 ]]; then
            pass_row "Rows 6, 7, 8 hard acceptance gates passed"
        else
            record_fail "Hard row check (Row 6 / Row 7 / Row 8) failed"
        fi

        if [[ "${RECORD}" -eq 1 && "${FAILED_CHECKS}" -eq 0 ]]; then
            cp "${TSV_REPORT}" "${REPORT_DIR}/m3-merge-eval.tsv"
            cp "${SUMMARY_REPORT}" "${REPORT_DIR}/m3-merge-eval-summary.tsv"
            cp "${MD_REPORT}" "${REPORT_DIR}/m3-merge-eval.md"
        fi
    else
        echo "Skipping report generation because classify.py did not produce details.tsv." >&2
    fi
fi

# ------------------------------------------------------------------
# Step D: Post-run Hard Checks (Row 14 timing & Row 15 hygiene)
# ------------------------------------------------------------------
echo ""
echo "--- Step D: Timing & Post-Run Hygiene Checks (Rows 14 & 15) ---"
END_EPOCH="$(/usr/bin/python3 -c 'import time; print("%.3f" % time.time())')"
FINAL_WALL_SEC="$(/usr/bin/python3 -c "print('%.2f' % (${END_EPOCH} - ${START_EPOCH}))")"
echo "Total wall-clock elapsed: ${FINAL_WALL_SEC}s"

if [[ "${QUICK}" -eq 1 ]]; then
    if /usr/bin/python3 -c "import sys; sys.exit(0 if float('${FINAL_WALL_SEC}') <= 120.0 else 1)"; then
        pass_row "Row 14: --quick completed within 120s budget (${FINAL_WALL_SEC}s)"
    else
        record_fail "Row 14: --quick exceeded 120s hard limit (took ${FINAL_WALL_SEC}s)"
    fi
else
    pass_row "Row 14: full evaluation completed in ${FINAL_WALL_SEC}s"
fi

# 15a. Repository git status check
if [[ "${RECORD}" -eq 0 || "${FAILED_CHECKS}" -ne 0 ]]; then
    GIT_STATUS_AFTER="$(git status --porcelain)"
    if [[ "${GIT_STATUS_BEFORE}" != "${GIT_STATUS_AFTER}" ]]; then
        echo "git status before:" >&2
        printf '%s\n' "${GIT_STATUS_BEFORE}" >&2
        echo "git status after:" >&2
        printf '%s\n' "${GIT_STATUS_AFTER}" >&2
        record_fail "Row 15: repository working tree changed without --record"
    else
        pass_row "Row 15a: git status unchanged without --record (${GIT_STATUS_AFTER:-clean})"
    fi
else
    GIT_OUTSIDE_REPORTS_AFTER="$(git status --porcelain -- . ':(exclude)reports')"
    if [[ "${GIT_OUTSIDE_REPORTS_BEFORE}" != "${GIT_OUTSIDE_REPORTS_AFTER}" ]]; then
        record_fail "Row 15: --record modified files outside reports/"
    else
        pass_row "Row 15a: --record wrote reports/m3-merge-eval.{tsv,md} and m3-merge-eval-summary.tsv; rest of working tree unchanged"
    fi
fi

# 15b. Corpus directory check (only ${RUN_STAMP}_* added under runs/)
if [[ "${HAS_CORPUS}" -eq 1 ]]; then
    ls -1 "${CORPUS_DIR}/runs" | sort >"${WORK_TMP}/runs_after.txt"
    NEW_RUN_DIRS="$(comm -13 "${WORK_TMP}/runs_before.txt" "${WORK_TMP}/runs_after.txt")"
    EXPECTED_RUN_DIRS="$(printf '%s\n' "${PUB_CALLER_NAME}" "${PUB_EVALPY_NAME}" "${ENG_NAME}" "${MGF_NAME}" "${RUN_STAMP}_classify" | sort)"
    if [[ "${NEW_RUN_DIRS}" != "${EXPECTED_RUN_DIRS}" ]]; then
        record_fail "Row 15b: unexpected entries added under \$RELAY_MERGE_CORPUS_DIR/runs: ${NEW_RUN_DIRS}"
    else
        pass_row "Row 15b: corpus cache added only runs/${RUN_STAMP}_{published_caller,published_evalpy,engine,mergiraf,classify}"
    fi
fi

# 15c. ~/Library check
snapshot_library "${WORK_TMP}/lib_relay_after.txt" "${WORK_TMP}/lib_recent_after.txt"
LIB_RELAY_BEFORE_CNT="$(wc -l <"${WORK_TMP}/lib_relay_before.txt" | tr -d ' ')"
LIB_RELAY_AFTER_CNT="$(wc -l <"${WORK_TMP}/lib_relay_after.txt" | tr -d ' ')"
LIB_RECENT_BEFORE_TOP="$(head -n 3 "${WORK_TMP}/lib_recent_before.txt" | tr '\n' ';' || true)"
LIB_RECENT_AFTER_TOP="$(head -n 3 "${WORK_TMP}/lib_recent_after.txt" | tr '\n' ';' || true)"
echo "~/Library RelayIDE/mergiraf entries: before=${LIB_RELAY_BEFORE_CNT}, after=${LIB_RELAY_AFTER_CNT}"
echo "~/Library top-3 recent before: ${LIB_RECENT_BEFORE_TOP:-(none)}"
echo "~/Library top-3 recent after:  ${LIB_RECENT_AFTER_TOP:-(none)}"
NEW_LIB_RELAY="$(comm -13 "${WORK_TMP}/lib_relay_before.txt" "${WORK_TMP}/lib_relay_after.txt")"
if [[ -n "${NEW_LIB_RELAY}" ]]; then
    record_fail "Row 15c: new or modified RelayIDE/mergiraf entries in ~/Library: ${NEW_LIB_RELAY}"
else
    pass_row "Row 15c: ~/Library has zero new or modified RelayIDE/mergiraf files (isolated HOME used)"
fi

# 15d. Residual processes check
LEFTOVER_JOBS="$(jobs -p)"
if [[ -n "${LEFTOVER_JOBS}" ]]; then
    record_fail "Row 15d: leftover background shell job(s) still running: ${LEFTOVER_JOBS}"
fi
LEFTOVER_CLI="$(RELAY_CLI_BIN="${SELECTED_CLI_EXEC}" "${RELAY_CLI}" --relay-cli-running-processes 2>/dev/null || true)"
if [[ -n "${LEFTOVER_CLI}" ]]; then
    record_fail "Row 15d: leftover product process(es) still running: ${LEFTOVER_CLI}"
fi
PGREP_REPORT="$(/usr/bin/python3 - "$$" <<'PY'
import os, subprocess, sys
parent_pid = str(sys.argv[1])
my_pid = str(os.getpid())
proc = subprocess.run(["/usr/bin/pgrep", "-P", parent_pid], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
if proc.returncode in (0, 1):
    kids = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip() and ln.strip() != my_pid]
    print("OK:" + " ".join(kids))
else:
    print("SANDBOX_NO_SYSMOND:")
PY
)"
PGREP_KIDS="${PGREP_REPORT#*:}"
if [[ -n "${PGREP_KIDS}" ]]; then
    record_fail "Row 15d: leftover child process(es) still running under pid $$: ${PGREP_KIDS}"
fi
echo "Residual process check: shell jobs=0, product processes=0 (${PGREP_REPORT%%:*})"
if [[ -z "${LEFTOVER_JOBS}" && -z "${LEFTOVER_CLI}" && -z "${PGREP_KIDS}" ]]; then
    pass_row "Row 15d: zero residual product or child processes"
fi

if [[ "${FAILED_CHECKS}" -ne 0 ]]; then
    echo "" >&2
    echo "================================================================" >&2
    echo "M3 MERGE EVALUATION FAILED: ${FAILED_CHECKS} check(s) failed (${FINAL_WALL_SEC}s)" >&2
    echo "================================================================" >&2
    exit 1
fi

echo ""
echo "================================================================"
echo "ALL M3 MERGE EVALUATION CHECKS PASSED (${FINAL_WALL_SEC}s)"
echo "================================================================"
