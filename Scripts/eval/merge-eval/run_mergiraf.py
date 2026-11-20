#!/usr/bin/env python3
"""Corpus & fixed-case runner for `mergiraf` (M3 Stage 4).

Invokes `mergiraf merge <base> <left> <right> -p <path> -s base -x left -y right -o <out>`
(never passing `--fast`) with a per-file wall-clock timeout (default 30s, 4 parallel workers):
  - Unsupported languages (notably Swift `.swift`, absent from `mergiraf languages`) are counted
    and recorded with `claimed_clean=skip` without invoking `mergiraf`.
  - Exit 0 WITHOUT conflict markers in the `-o` output -> `claimed_clean=1`, output saved verbatim.
  - Non-zero exit OR exit 0 WITH conflict markers in the `-o` output -> `claimed_clean=0`.
  - Timeout -> `exit_code=124`, `claimed_clean=0`, `reason=timeout`.
  - Writes `results.tsv`, `timings.tsv` (per-file elapsed milliseconds), and `env.txt`
    (version, binary path & sha256, repo commit, skipped counts by language, median & max per-file ms,
    start/end UTC timestamps, elapsed seconds, and timeout count).

Python 3.9 compatible, standard library only.
"""
import argparse
from collections import Counter
import concurrent.futures
import csv
from datetime import datetime, timezone
import hashlib
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MERGE_CORPUS_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../merge-corpus"))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))
for _p in (SCRIPT_DIR, MERGE_CORPUS_DIR):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import classify  # noqa: E402
import parsers  # noqa: E402
import run_engine  # noqa: E402

ENV_CORPUS_DIR = "RELAY_MERGE_CORPUS_DIR"
ENV_MERGIRAF_BIN = "RELAY_MERGIRAF_BIN"

DEFAULT_MERGIRAF_CANDIDATES = (
    "/opt/homebrew/bin/mergiraf",
    "/usr/local/bin/mergiraf",
)

# Extensions supported by `mergiraf 0.20.0` (`mergiraf languages`), excluding Swift (`.swift`).
MERGIRAF_SUPPORTED_EXTENSIONS = frozenset(
    {
        ".java",
        ".properties",
        ".kt",
        ".kts",
        ".rs",
        ".go",
        ".ini",
        ".js",
        ".jsx",
        ".mjs",
        ".cjs",
        ".json",
        ".yml",
        ".yaml",
        ".toml",
        ".html",
        ".htm",
        ".xhtml",
        ".xml",
        ".c",
        ".h",
        ".cc",
        ".hh",
        ".cpp",
        ".hpp",
        ".cxx",
        ".hxx",
        ".c++",
        ".h++",
        ".mpp",
        ".cppm",
        ".ixx",
        ".tcc",
        ".cs",
        ".dart",
        ".dts",
        ".scala",
        ".sbt",
        ".scm",
        ".ts",
        ".mts",
        ".cts",
        ".tsx",
        ".py",
        ".php",
        ".phtml",
        ".php3",
        ".php4",
        ".php5",
        ".phps",
        ".phpt",
        ".sol",
        ".lua",
        ".rb",
        ".ex",
        ".exs",
        ".nix",
        ".sv",
        ".svh",
        ".md",
        ".hcl",
        ".tf",
        ".tfvars",
        ".ml",
        ".mli",
        ".hs",
        ".mk",
        ".bzl",
        ".bxl",
        ".bazel",
        ".star",
        ".sky",
        ".cmake",
        ".f",
        ".for",
        ".f90",
        ".r",
        ".sh",
        ".bash",
        ".gleam",
        ".erl",
        ".hrl",
        ".escript",
        ".m",
        ".qml",
    }
)

RESULTS_FIELDS = run_engine.RESULTS_FIELDS
TIMINGS_FIELDS = run_engine.TIMINGS_FIELDS


class RunnerConfigError(RuntimeError):
    """Raised when required corpus or mergiraf binary configuration is missing (exit code 2)."""


def _resolve_mergiraf_bin(mergiraf_bin, eff_env):
    explicit = (mergiraf_bin or eff_env.get(ENV_MERGIRAF_BIN, "")).strip()
    if explicit:
        ab = os.path.abspath(explicit)
        if not (os.path.isfile(ab) and os.access(ab, os.X_OK)):
            raise RunnerConfigError("没跑：找不到可执行 mergiraf (%s)" % ab)
        return ab

    on_path = shutil.which("mergiraf", path=eff_env.get("PATH", ""))
    if on_path:
        return os.path.abspath(on_path)

    for cand in DEFAULT_MERGIRAF_CANDIDATES:
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand

    raise RunnerConfigError("没跑：找不到可执行 mergiraf")


def _probe_mergiraf_version(mergiraf_bin, scratch_dir):
    try:
        proc = subprocess.run(
            [mergiraf_bin, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.DEVNULL,
            cwd=scratch_dir,
            env={"PATH": "/usr/bin:/bin", "HOME": scratch_dir, "LC_ALL": "C"},
            timeout=10.0,
        )
        combined = (proc.stdout + b"\n" + proc.stderr).decode("utf-8", "replace")
        lines = [ln.strip() for ln in combined.splitlines() if ln.strip()]
        return lines[0] if lines else ("exit=%d" % proc.returncode)
    except Exception as exc:
        return "error: %s" % exc


def is_mergiraf_supported(ext, language):
    if (language or "").lower() == "swift" or (ext or "").lower() == ".swift":
        return False
    return (ext or "").lower() in MERGIRAF_SUPPORTED_EXTENSIONS


def _run_single_case(item, mergiraf_bin, child_env, tmp_root, outputs_dir, timeout_sec, extra_home_dirs):
    cid = item["case_id"]
    ext = item["ext"]
    lang = item["language"]
    safe_stem = run_engine._safe_case_stem(cid)
    final_out = os.path.join(outputs_dir, safe_stem + ext)

    if not is_mergiraf_supported(ext, lang):
        if os.path.isfile(final_out):
            os.remove(final_out)
        res_row = {
            "case_id": cid,
            "exit_code": "0",
            "claimed_clean": "skip",
            "output_path": "",
            "reason": "unsupported_language:%s" % lang,
            "strategy": "-",
        }
        tim_row = {
            "case_id": cid,
            "kind": item["kind"],
            "language": lang,
            "exit_code": "0",
            "claimed_clean": "skip",
            "elapsed_ms": "-",
        }
        return res_row, tim_row

    p_base = item["p_base"]
    p_left = item["p_left"]
    p_right = item["p_right"]
    for p in (p_base, p_left, p_right):
        if not os.path.isfile(p):
            raise FileNotFoundError("missing input file: %s" % p)

    tmp_out = os.path.join(tmp_root, safe_stem + ".tmp" + ext)
    if os.path.isfile(tmp_out):
        os.remove(tmp_out)

    cmd = [
        mergiraf_bin,
        "merge",
        p_base,
        p_left,
        p_right,
        "-p",
        item["rel_path"],
        "-s",
        "base",
        "-x",
        "left",
        "-y",
        "right",
        "-o",
        tmp_out,
    ]
    t0 = time.monotonic()
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
        cwd=tmp_root,
        env=child_env,
        start_new_session=True,
    )
    timed_out = False
    try:
        out_bytes, err_bytes = proc.communicate(timeout=timeout_sec)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            out_bytes, err_bytes = proc.communicate(timeout=1.5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            out_bytes, err_bytes = proc.communicate()
        rc = 124
    elapsed_ms = (time.monotonic() - t0) * 1000.0

    if timed_out:
        if os.path.isfile(tmp_out):
            os.remove(tmp_out)
        if os.path.isfile(final_out):
            os.remove(final_out)
        res_row = {
            "case_id": cid,
            "exit_code": "124",
            "claimed_clean": "0",
            "output_path": "",
            "reason": "timeout",
            "strategy": "-",
        }
        tim_row = {
            "case_id": cid,
            "kind": item["kind"],
            "language": lang,
            "exit_code": "124",
            "claimed_clean": "0",
            "elapsed_ms": "%.3f" % elapsed_ms,
        }
        return res_row, tim_row

    rc_norm = rc if rc >= 0 else (128 - rc)
    merged_bytes = None
    if os.path.isfile(tmp_out):
        with open(tmp_out, "rb") as fh:
            merged_bytes = fh.read()
        os.remove(tmp_out)

    if rc_norm == 0 and merged_bytes is not None:
        if classify.has_conflict_markers(merged_bytes):
            if os.path.isfile(final_out):
                os.remove(final_out)
            res_row = {
                "case_id": cid,
                "exit_code": "0",
                "claimed_clean": "0",
                "output_path": "",
                "reason": "conflict_markers_in_output",
                "strategy": "none",
            }
        else:
            with open(final_out, "wb") as fh:
                fh.write(merged_bytes)
            res_row = {
                "case_id": cid,
                "exit_code": "0",
                "claimed_clean": "1",
                "output_path": "outputs/" + safe_stem + ext,
                "reason": "",
                "strategy": "structured",
            }
    elif rc_norm == 1:
        if os.path.isfile(final_out):
            os.remove(final_out)
        res_row = {
            "case_id": cid,
            "exit_code": "1",
            "claimed_clean": "0",
            "output_path": "",
            "reason": "",
            "strategy": "none",
        }
    else:
        if os.path.isfile(final_out):
            os.remove(final_out)
        err_text = err_bytes.decode("utf-8", "replace")
        recorded_rc = rc_norm if rc_norm not in (3, 4) else 2
        reason = run_engine.sanitize_stderr_reason(
            err_text,
            extra_temp_dirs=(tmp_root,),
            extra_home_dirs=tuple(extra_home_dirs),
        )
        if not reason:
            reason = "missing_output_file" if (rc_norm == 0 and merged_bytes is None) else ("exit=%d" % rc_norm)
        res_row = {
            "case_id": cid,
            "exit_code": str(recorded_rc),
            "claimed_clean": "0",
            "output_path": "",
            "reason": reason,
            "strategy": "-",
        }

    tim_row = {
        "case_id": cid,
        "kind": item["kind"],
        "language": lang,
        "exit_code": res_row["exit_code"],
        "claimed_clean": res_row["claimed_clean"],
        "elapsed_ms": "%.3f" % elapsed_ms,
    }
    return res_row, tim_row


def run_mergiraf_eval(
    name=None,
    out_dir=None,
    fixed_cases=False,
    merge_cases_dir=None,
    syntax_gate_dir=None,
    cases_tsv=None,
    corpus_dir=None,
    extract_subdir="extract",
    mergiraf_bin=None,
    languages=None,
    kinds=("conflict", "clean"),
    case_ids=None,
    quick=False,
    workers=4,
    timeout_sec=30.0,
    append=False,
    env=None,
):
    eff_env = run_engine._effective_env(env)

    if out_dir:
        run_dir = os.path.abspath(out_dir)
        run_name = name or os.path.basename(run_dir)
    else:
        if not name:
            raise RunnerConfigError("没跑：必须指定 --name 或 --out-dir")
        run_name = run_engine._validate_run_name(name)
        resolved_corpus = (corpus_dir or eff_env.get(ENV_CORPUS_DIR, "")).strip()
        if not resolved_corpus:
            raise RunnerConfigError("没跑：没有语料缓存")
        run_dir = os.path.join(os.path.abspath(resolved_corpus), "runs", run_name)

    resolved_mergiraf = _resolve_mergiraf_bin(mergiraf_bin, eff_env)

    try:
        if fixed_cases:
            mc_dir = os.path.abspath(merge_cases_dir or os.path.join(REPO_ROOT, "Fixtures/merge-cases"))
            sg_dir = os.path.abspath(syntax_gate_dir or os.path.join(REPO_ROOT, "Fixtures/syntax-gate-cases"))
            selected_items, all_case_order = run_engine.select_fixed_cases(
                mc_dir,
                sg_dir,
                languages=languages,
                case_ids=case_ids,
            )
        else:
            resolved_corpus = (corpus_dir or eff_env.get(ENV_CORPUS_DIR, "")).strip()
            if not resolved_corpus:
                raise RunnerConfigError("没跑：没有语料缓存")
            cases_root = os.path.join(os.path.abspath(resolved_corpus), extract_subdir, "cases")
            if not os.path.isdir(cases_root):
                raise RunnerConfigError("没跑：找不到语料抽取目录 (%s)" % cases_root)
            resolved_cases_tsv = os.path.abspath(cases_tsv or os.path.join(REPO_ROOT, "Fixtures/merge-corpus/cases.tsv"))
            if not os.path.isfile(resolved_cases_tsv):
                raise RunnerConfigError("没跑：找不到语料清单 (%s)" % resolved_cases_tsv)
            selected_items, all_case_order = run_engine.select_corpus_cases(
                resolved_cases_tsv,
                cases_root,
                kinds=kinds,
                languages=languages,
                case_ids=case_ids,
                quick=quick,
            )
    except run_engine.RunnerConfigError as exc:
        raise RunnerConfigError(str(exc)) from exc

    outputs_dir = os.path.join(run_dir, "outputs")
    results_tsv = os.path.join(run_dir, "results.tsv")
    timings_tsv = os.path.join(run_dir, "timings.tsv")
    env_txt = os.path.join(run_dir, "env.txt")

    if not append and os.path.isdir(run_dir):
        if os.path.isdir(outputs_dir):
            shutil.rmtree(outputs_dir)
        for fp in (results_tsv, timings_tsv, env_txt):
            if os.path.isfile(fp):
                os.remove(fp)

    os.makedirs(outputs_dir, exist_ok=True)
    existing_res = run_engine._load_existing_tsv(results_tsv, RESULTS_FIELDS) if append else {}
    existing_tim = run_engine._load_existing_tsv(timings_tsv, TIMINGS_FIELDS) if append else {}

    extra_homes = []
    if eff_env.get("HOME"):
        extra_homes.append(eff_env["HOME"])

    tmp_root = tempfile.mkdtemp(prefix="relay-run-mergiraf.")
    child_env = {
        "PATH": eff_env.get("PATH", "/usr/bin:/bin"),
        "HOME": tmp_root,
        "CFFIXED_USER_HOME": tmp_root,
        "LC_ALL": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    if eff_env.get("FAKE_MERGIRAF_LOG"):
        child_env["FAKE_MERGIRAF_LOG"] = eff_env["FAKE_MERGIRAF_LOG"]

    started_utc = datetime.now(timezone.utc)
    t0 = time.monotonic()
    try:
        mgf_sha256 = run_engine._sha256_file(resolved_mergiraf)
        mgf_version = _probe_mergiraf_version(resolved_mergiraf, tmp_root)
        repo_commit = run_engine._detect_repo_commit(REPO_ROOT)

        results_by_id = dict(existing_res)
        timings_by_id = dict(existing_tim)
        max_workers = max(1, int(workers))

        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
            future_map = {
                pool.submit(
                    _run_single_case,
                    item,
                    resolved_mergiraf,
                    child_env,
                    tmp_root,
                    outputs_dir,
                    float(timeout_sec),
                    extra_homes,
                ): item["case_id"]
                for item in selected_items
            }
            for fut in concurrent.futures.as_completed(future_map):
                r_row, t_row = fut.result()
                results_by_id[r_row["case_id"]] = r_row
                timings_by_id[t_row["case_id"]] = t_row
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)

    elapsed = time.monotonic() - t0
    finished_utc = datetime.now(timezone.utc)

    ordered_ids = []
    seen_ids = set()
    for cid in all_case_order:
        if cid in results_by_id:
            ordered_ids.append(cid)
            seen_ids.add(cid)
    for cid in sorted(results_by_id):
        if cid not in seen_ids:
            ordered_ids.append(cid)

    ordered_rows = [results_by_id[cid] for cid in ordered_ids]
    ordered_timings = [timings_by_id[cid] for cid in ordered_ids if cid in timings_by_id]

    with open(results_tsv, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=RESULTS_FIELDS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for r in ordered_rows:
            writer.writerow(r)

    with open(timings_tsv, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=TIMINGS_FIELDS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for t in ordered_timings:
            writer.writerow(t)

    batch_counts = Counter(int(results_by_id[it["case_id"]]["exit_code"]) for it in selected_items)
    total_counts = Counter(int(r["exit_code"]) for r in ordered_rows)
    timeouts = [r["case_id"] for r in ordered_rows if r["exit_code"] == "124"]

    skipped_by_lang = Counter()
    ms_all = []
    ms_by_lang = {}
    for t in ordered_timings:
        lg = t["language"]
        if t["claimed_clean"] == "skip":
            skipped_by_lang[lg] += 1
        elif t.get("elapsed_ms") not in ("", "-"):
            val = float(t["elapsed_ms"])
            ms_all.append(val)
            ms_by_lang.setdefault(lg, []).append(val)

    median_ms = statistics.median(ms_all) if ms_all else 0.0
    max_ms = max(ms_all) if ms_all else 0.0
    skipped_summary = " ".join(
        "%s=%d" % (lg, skipped_by_lang.get(lg, 0))
        for lg in sorted(set(["python", "swift", "typescript"]) | set(skipped_by_lang.keys()))
    )
    per_lang_timing_lines = []
    for lg in sorted(ms_by_lang):
        vals = ms_by_lang[lg]
        per_lang_timing_lines.append(
            "per_case_ms_%s: count=%d median=%.3f max=%.3f"
            % (lg, len(vals), statistics.median(vals), max(vals))
        )

    env_lines = [
        "=== run_mergiraf ===",
        "name: %s" % run_name,
        "mode: %s" % ("fixed-cases" if fixed_cases else "corpus"),
        "append: %s" % ("true" if append else "false"),
        "mergiraf_bin: %s" % resolved_mergiraf,
        "mergiraf_bin_sha256: %s" % mgf_sha256,
        "mergiraf_version: %s" % mgf_version,
        "mergiraf_args_template: merge <base> <left> <right> -p <rel_path> -s base -x left -y right -o <output>",
        "repo_commit: %s" % repo_commit,
        "languages_filter: %s" % (",".join(languages) if languages else "all"),
        "kinds_filter: %s" % ("fixed" if fixed_cases else ",".join(kinds)),
        "quick: %s" % ("true" if quick else "false"),
        "workers: %d" % max(1, int(workers)),
        "timeout_sec: %.1f" % float(timeout_sec),
        "batch_cases: %d" % len(selected_items),
        "total_results_rows: %d" % len(ordered_rows),
        "skipped_by_language: %s" % skipped_summary,
        "started_at_utc: %s" % started_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "finished_at_utc: %s" % finished_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "elapsed_seconds: %.2f" % elapsed,
        "executed_non_skipped_cases: %d" % len(ms_all),
        "per_case_ms_median: %.3f" % median_ms,
        "per_case_ms_max: %.3f" % max_ms,
    ]
    env_lines.extend(per_lang_timing_lines)
    env_lines.extend(
        [
            "batch_exit_counts: exit_0=%d exit_1=%d exit_124=%d other=%d"
            % (
                batch_counts.get(0, 0),
                batch_counts.get(1, 0),
                batch_counts.get(124, 0),
                sum(v for k, v in batch_counts.items() if k not in (0, 1, 124)),
            ),
            "total_exit_counts: exit_0=%d exit_1=%d exit_124=%d other=%d"
            % (
                total_counts.get(0, 0),
                total_counts.get(1, 0),
                total_counts.get(124, 0),
                sum(v for k, v in total_counts.items() if k not in (0, 1, 124)),
            ),
            "timeout_count: %d" % len(timeouts),
            "timeout_cases: %s" % (",".join(timeouts) if timeouts else "none"),
            "",
        ]
    )

    mode = "a" if (append and os.path.isfile(env_txt)) else "w"
    with open(env_txt, mode, encoding="utf-8") as fh:
        fh.write("\n".join(env_lines))

    return {
        "run_dir": run_dir,
        "results_tsv": results_tsv,
        "timings_tsv": timings_tsv,
        "env_txt": env_txt,
        "batch_cases": len(selected_items),
        "total_rows": len(ordered_rows),
        "elapsed_seconds": elapsed,
        "timeout_cases": timeouts,
    }


def main(argv=None, env=None):
    ap = argparse.ArgumentParser(description="Run mergiraf over the M3 merge corpus or fixed cases")
    ap.add_argument("--name", default=None, help="output directory name under $RELAY_MERGE_CORPUS_DIR/runs/<name>/")
    ap.add_argument("--out-dir", default=None, help="explicit output directory (overrides runs/<name>/)")
    ap.add_argument("--fixed-cases", action="store_true", help="run on Fixtures/merge-cases + Fixtures/syntax-gate-cases")
    ap.add_argument(
        "--merge-cases-dir",
        default=os.path.join(REPO_ROOT, "Fixtures/merge-cases"),
        help="path to Fixtures/merge-cases",
    )
    ap.add_argument(
        "--syntax-gate-dir",
        default=os.path.join(REPO_ROOT, "Fixtures/syntax-gate-cases"),
        help="path to Fixtures/syntax-gate-cases",
    )
    ap.add_argument(
        "--cases-tsv",
        default=os.path.join(REPO_ROOT, "Fixtures/merge-corpus/cases.tsv"),
        help="path to Fixtures/merge-corpus/cases.tsv",
    )
    ap.add_argument("--corpus-dir", default=None, help="override $RELAY_MERGE_CORPUS_DIR")
    ap.add_argument("--extract-subdir", default="extract", help="extraction subdirectory under corpus-dir")
    ap.add_argument("--mergiraf-bin", default=None, help="path to mergiraf executable")
    ap.add_argument("--languages", default=None, help="comma-separated language filter (python,swift,typescript)")
    ap.add_argument("--kinds", default="conflict,clean", help="comma-separated case kinds (default: conflict,clean)")
    ap.add_argument("--case-ids", default=None, help="optional comma-separated list of specific case_ids to run")
    ap.add_argument(
        "--quick",
        action="store_true",
        help="run only the first 20 conflict and first 20 clean cases per language",
    )
    ap.add_argument("--workers", type=int, default=4, help="parallel worker count (default: 4)")
    ap.add_argument("--timeout", type=float, default=30.0, help="per-case timeout in seconds (default: 30)")
    ap.add_argument(
        "--append",
        action="store_true",
        help="merge newly executed rows into existing results.tsv (for splitting runs by --languages)",
    )
    args = ap.parse_args(argv)

    langs = [x.strip() for x in args.languages.split(",") if x.strip()] if args.languages else None
    kinds = tuple(x.strip() for x in args.kinds.split(",") if x.strip())
    case_ids = [x.strip() for x in args.case_ids.split(",") if x.strip()] if args.case_ids else None

    try:
        summary = run_mergiraf_eval(
            name=args.name,
            out_dir=args.out_dir,
            fixed_cases=args.fixed_cases,
            merge_cases_dir=args.merge_cases_dir,
            syntax_gate_dir=args.syntax_gate_dir,
            cases_tsv=args.cases_tsv,
            corpus_dir=args.corpus_dir,
            extract_subdir=args.extract_subdir,
            mergiraf_bin=args.mergiraf_bin,
            languages=langs,
            kinds=kinds,
            case_ids=case_ids,
            quick=args.quick,
            workers=args.workers,
            timeout_sec=args.timeout,
            append=args.append,
            env=env,
        )
    except RunnerConfigError as exc:
        print(str(exc))
        return 2

    print(
        "run_mergiraf: batch=%d total_rows=%d elapsed=%.2fs timeouts=%d results=%s"
        % (
            summary["batch_cases"],
            summary["total_rows"],
            summary["elapsed_seconds"],
            len(summary["timeout_cases"]),
            summary["results_tsv"],
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
