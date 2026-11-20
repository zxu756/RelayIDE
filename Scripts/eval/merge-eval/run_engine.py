#!/usr/bin/env python3
"""Corpus & fixed-case runner for RelayIDE's declaration-level ThreeWaySemanticASTMerger (M3 Stage 4).

Invokes the standalone evaluation executable `relay-merge-eval` (from `Scripts/eval/merge-eval/`)
with a per-file wall-clock timeout (default 30s, 4 parallel workers) and writes:
  - `results.tsv` (compatible with `classify.py --tool engine=...` and `--engine-tsv ...`)
  - `outputs/<safe_case_id><ext>` (verbatim merged bytes when `isCleanlyMerged == true`)
  - `timings.tsv` (per-case wall-clock duration in milliseconds)
  - `env.txt` (engine executable path & sha256, repo commit, start/end UTC timestamps, elapsed seconds,
    per-case timing stats, exit-code summary, and timeout count/list)

Python 3.9 compatible, standard library only.
"""
import argparse
from collections import Counter
import concurrent.futures
import csv
from datetime import datetime, timezone
import hashlib
import os
import re
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

import parsers  # noqa: E402

ENV_CORPUS_DIR = "RELAY_MERGE_CORPUS_DIR"
ENV_ENGINE_BIN = "RELAY_MERGE_EVAL_BIN"

RESULTS_FIELDS = [
    "case_id",
    "exit_code",
    "claimed_clean",
    "output_path",
    "reason",
    "strategy",
]

TIMINGS_FIELDS = [
    "case_id",
    "kind",
    "language",
    "exit_code",
    "claimed_clean",
    "elapsed_ms",
]

QUICK_LIMIT_PER_LANG_KIND = 20


class RunnerConfigError(RuntimeError):
    """Raised when required corpus or binary configuration is missing (exit code 2)."""


def _effective_env(env=None):
    return dict(os.environ if env is None else env)


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _safe_case_stem(case_id):
    return case_id.replace("/", "__").replace("\\", "__")


def _detect_repo_commit(repo_root):
    for git_cand in ("/usr/bin/git", "git"):
        try:
            proc = subprocess.run(
                [git_cand, "-C", repo_root, "rev-parse", "HEAD"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                stdin=subprocess.DEVNULL,
                timeout=5.0,
            )
            if proc.returncode == 0:
                val = proc.stdout.decode("utf-8", "replace").strip()
                if val:
                    return val
        except Exception:
            continue
    return "unknown"


def sanitize_stderr_reason(raw_text, extra_temp_dirs=(), extra_home_dirs=()):
    """Produces a single-line reason stripped of temporary directory and home directory paths."""
    if not raw_text:
        return ""
    parts = []
    for raw_line in raw_text.replace("\t", " ").splitlines():
        s = raw_line.strip()
        if not s:
            continue
        if s.startswith("relay-merge-eval:"):
            s = s[len("relay-merge-eval:") :].strip()
        if s:
            parts.append(s)
    cleaned = " | ".join(parts)
    if not cleaned:
        return ""

    temp_prefixes = set()
    sys_tmp = os.path.abspath(tempfile.gettempdir()).rstrip("/")
    if sys_tmp and sys_tmp != "/":
        temp_prefixes.add(sys_tmp)
        temp_prefixes.add("/private" + sys_tmp)
        real_tmp = os.path.realpath(sys_tmp).rstrip("/")
        if real_tmp and real_tmp != "/":
            temp_prefixes.add(real_tmp)
    for td in extra_temp_dirs:
        if td:
            ab = os.path.abspath(td).rstrip("/")
            if ab and ab != "/":
                temp_prefixes.add(ab)
            rp = os.path.realpath(td).rstrip("/")
            if rp and rp != "/":
                temp_prefixes.add(rp)

    for prefix in sorted(temp_prefixes, key=len, reverse=True):
        cleaned = re.sub(re.escape(prefix) + r"(?:/[^\s:,\"')|]+)?", "<temp>", cleaned)

    cleaned = re.sub(r"/private/var/folders/[^\s:,\"')|]+", "<temp>", cleaned)
    cleaned = re.sub(r"/var/folders/[^\s:,\"')|]+", "<temp>", cleaned)
    cleaned = re.sub(r"/private/tmp/[^\s:,\"')|]+", "<temp>", cleaned)
    cleaned = re.sub(r"/tmp/[^\s:,\"')|]+", "<temp>", cleaned)

    home_prefixes = set()
    real_user_home = os.path.expanduser("~").rstrip("/")
    if real_user_home and real_user_home != "/":
        home_prefixes.add(real_user_home)
    for hd in extra_home_dirs:
        if hd:
            ab = os.path.abspath(hd).rstrip("/")
            if ab and ab != "/":
                home_prefixes.add(ab)
            rp = os.path.realpath(hd).rstrip("/")
            if rp and rp != "/":
                home_prefixes.add(rp)

    for hprefix in sorted(home_prefixes, key=len, reverse=True):
        cleaned = cleaned.replace(hprefix, "<home>")

    cleaned = re.sub(r"/Users/[^/\s:,\"')|]+", "<home>", cleaned)
    return cleaned


def select_corpus_cases(cases_tsv, cases_root, kinds=("conflict", "clean"), languages=None, case_ids=None, quick=False):
    """Loads and filters rows from `cases.tsv` preserving file order."""
    wanted_kinds = set(k.strip() for k in kinds if k.strip())
    wanted_langs = set(parsers.canonical_language(x) for x in languages if x.strip()) if languages else None
    wanted_ids = set(x.strip() for x in case_ids if x.strip()) if case_ids else None

    selected = []
    seen_per_lang_kind = Counter()
    all_case_order = []

    with open(cases_tsv, encoding="utf-8") as fh:
        for row in csv.DictReader(fh, delimiter="\t"):
            cid = row["case_id"].strip()
            all_case_order.append(cid)
            kind = row["kind"].strip()
            lang = parsers.canonical_language(row["language"])
            if kind not in wanted_kinds:
                continue
            if wanted_langs is not None and lang not in wanted_langs:
                continue
            if wanted_ids is not None and cid not in wanted_ids:
                continue
            if quick:
                key = (lang, kind)
                if seen_per_lang_kind[key] >= QUICK_LIMIT_PER_LANG_KIND:
                    continue
                seen_per_lang_kind[key] += 1
            ext = parsers.normalize_extension(row["path"])
            cdir = os.path.join(cases_root, cid)
            selected.append(
                {
                    "case_id": cid,
                    "kind": kind,
                    "language": lang,
                    "ext": ext,
                    "rel_path": row["path"].strip(),
                    "p_base": os.path.join(cdir, "base" + ext),
                    "p_left": os.path.join(cdir, "left" + ext),
                    "p_right": os.path.join(cdir, "right" + ext),
                }
            )

    return selected, all_case_order


def select_fixed_cases(merge_cases_dir, syntax_gate_dir, languages=None, case_ids=None):
    """Discovers fixed cases in `Fixtures/merge-cases` and `Fixtures/syntax-gate-cases`."""
    wanted_langs = set(parsers.canonical_language(x) for x in languages if x.strip()) if languages else None
    wanted_ids = set(x.strip() for x in case_ids if x.strip()) if case_ids else None
    suites = [
        ("merge-cases", os.path.abspath(merge_cases_dir)),
        ("syntax-gate-cases", os.path.abspath(syntax_gate_dir)),
    ]
    selected = []
    all_case_order = []
    for suite_prefix, suite_dir in suites:
        if not os.path.isdir(suite_dir):
            raise RunnerConfigError("没跑：找不到固定用例目录 (%s)" % suite_dir)
        for name in sorted(os.listdir(suite_dir)):
            cdir = os.path.join(suite_dir, name)
            if not os.path.isdir(cdir):
                continue
            base_files = [f for f in sorted(os.listdir(cdir)) if f.startswith("base.")]
            if not base_files:
                continue
            cid = "%s/%s" % (suite_prefix, name)
            all_case_order.append(cid)
            ext = parsers.normalize_extension(base_files[0])
            lang = parsers.language_for_extension(ext) or ext.lstrip(".")
            if wanted_langs is not None and lang not in wanted_langs:
                continue
            if wanted_ids is not None and cid not in wanted_ids and name not in wanted_ids:
                continue
            selected.append(
                {
                    "case_id": cid,
                    "kind": "fixed",
                    "language": lang,
                    "ext": ext,
                    "rel_path": "file" + ext,
                    "p_base": os.path.join(cdir, "base" + ext),
                    "p_left": os.path.join(cdir, "left" + ext),
                    "p_right": os.path.join(cdir, "right" + ext),
                }
            )
    return selected, all_case_order


def _validate_run_name(name):
    cleaned = (name or "").strip()
    if not cleaned or "/" in cleaned or "\\" in cleaned or cleaned in (".", "..") or ".." in cleaned:
        raise ValueError("invalid --name %r: must be a single directory name under runs/" % (name,))
    return cleaned


def _load_existing_tsv(path, fields):
    existing = {}
    if not os.path.isfile(path):
        return existing
    with open(path, encoding="utf-8") as fh:
        for row in csv.DictReader(fh, delimiter="\t"):
            cid = row["case_id"].strip()
            existing[cid] = {k: row.get(k, "") for k in fields}
    return existing


def _run_single_case(item, engine_bin, child_env, tmp_root, outputs_dir, timeout_sec, extra_home_dirs):
    cid = item["case_id"]
    ext = item["ext"]
    safe_stem = _safe_case_stem(cid)
    p_base = item["p_base"]
    p_left = item["p_left"]
    p_right = item["p_right"]

    for p in (p_base, p_left, p_right):
        if not os.path.isfile(p):
            raise FileNotFoundError("missing input file: %s" % p)

    tmp_out = os.path.join(tmp_root, safe_stem + ".tmp" + ext)
    final_out = os.path.join(outputs_dir, safe_stem + ext)
    if os.path.isfile(tmp_out):
        os.remove(tmp_out)

    cmd = [engine_bin, "--path", item["rel_path"], "-o", tmp_out, p_base, p_left, p_right]
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
            "language": item["language"],
            "exit_code": "124",
            "claimed_clean": "0",
            "elapsed_ms": "%.3f" % elapsed_ms,
        }
        return res_row, tim_row

    rc_norm = rc if rc >= 0 else (128 - rc)
    if rc_norm == 0 and os.path.isfile(tmp_out):
        shutil.move(tmp_out, final_out)
        res_row = {
            "case_id": cid,
            "exit_code": "0",
            "claimed_clean": "1",
            "output_path": "outputs/" + safe_stem + ext,
            "reason": "",
            "strategy": "declaration-level",
        }
    elif rc_norm == 1:
        if os.path.isfile(tmp_out):
            os.remove(tmp_out)
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
        if os.path.isfile(tmp_out):
            os.remove(tmp_out)
        if os.path.isfile(final_out):
            os.remove(final_out)
        err_text = err_bytes.decode("utf-8", "replace")
        # Map unexpected 3/4 exit codes away from CLI syntax/git-unavailable codes if a crash/script ever emitted them
        recorded_rc = rc_norm if rc_norm not in (3, 4) else 2
        reason = sanitize_stderr_reason(
            err_text,
            extra_temp_dirs=(tmp_root,),
            extra_home_dirs=tuple(extra_home_dirs),
        )
        if not reason:
            reason = "exit=%d" % rc_norm
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
        "language": item["language"],
        "exit_code": res_row["exit_code"],
        "claimed_clean": res_row["claimed_clean"],
        "elapsed_ms": "%.3f" % elapsed_ms,
    }
    return res_row, tim_row


def run_engine_eval(
    name=None,
    out_dir=None,
    fixed_cases=False,
    merge_cases_dir=None,
    syntax_gate_dir=None,
    cases_tsv=None,
    corpus_dir=None,
    extract_subdir="extract",
    engine_bin=None,
    languages=None,
    kinds=("conflict", "clean"),
    case_ids=None,
    quick=False,
    workers=4,
    timeout_sec=30.0,
    append=False,
    env=None,
):
    eff_env = _effective_env(env)

    if out_dir:
        run_dir = os.path.abspath(out_dir)
        run_name = name or os.path.basename(run_dir)
    else:
        if not name:
            raise RunnerConfigError("没跑：必须指定 --name 或 --out-dir")
        run_name = _validate_run_name(name)
        resolved_corpus = (corpus_dir or eff_env.get(ENV_CORPUS_DIR, "")).strip()
        if not resolved_corpus:
            raise RunnerConfigError("没跑：没有语料缓存")
        run_dir = os.path.join(os.path.abspath(resolved_corpus), "runs", run_name)

    default_engine = os.path.join(SCRIPT_DIR, ".build/release/relay-merge-eval")
    raw_engine = (engine_bin or eff_env.get(ENV_ENGINE_BIN, "") or default_engine).strip()
    resolved_engine = os.path.abspath(raw_engine)
    if not (os.path.isfile(resolved_engine) and os.access(resolved_engine, os.X_OK)):
        raise RunnerConfigError("没跑：找不到可执行引擎 (%s)" % resolved_engine)

    if fixed_cases:
        mc_dir = os.path.abspath(merge_cases_dir or os.path.join(REPO_ROOT, "Fixtures/merge-cases"))
        sg_dir = os.path.abspath(syntax_gate_dir or os.path.join(REPO_ROOT, "Fixtures/syntax-gate-cases"))
        selected_items, all_case_order = select_fixed_cases(
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
        selected_items, all_case_order = select_corpus_cases(
            resolved_cases_tsv,
            cases_root,
            kinds=kinds,
            languages=languages,
            case_ids=case_ids,
            quick=quick,
        )

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
    existing_res = _load_existing_tsv(results_tsv, RESULTS_FIELDS) if append else {}
    existing_tim = _load_existing_tsv(timings_tsv, TIMINGS_FIELDS) if append else {}

    extra_homes = []
    if eff_env.get("HOME"):
        extra_homes.append(eff_env["HOME"])

    tmp_root = tempfile.mkdtemp(prefix="relay-run-engine.")
    child_env = {
        "PATH": eff_env.get("PATH", "/usr/bin:/bin"),
        "HOME": tmp_root,
        "CFFIXED_USER_HOME": tmp_root,
        "LC_ALL": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
    }

    started_utc = datetime.now(timezone.utc)
    t0 = time.monotonic()
    try:
        eng_sha256 = _sha256_file(resolved_engine)
        repo_commit = _detect_repo_commit(REPO_ROOT)

        results_by_id = dict(existing_res)
        timings_by_id = dict(existing_tim)
        max_workers = max(1, int(workers))

        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
            future_map = {
                pool.submit(
                    _run_single_case,
                    item,
                    resolved_engine,
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

    ms_values = [float(t["elapsed_ms"]) for t in ordered_timings if t.get("elapsed_ms") not in ("", "-")]
    median_ms = statistics.median(ms_values) if ms_values else 0.0
    max_ms = max(ms_values) if ms_values else 0.0

    env_lines = [
        "=== run_engine ===",
        "name: %s" % run_name,
        "mode: %s" % ("fixed-cases" if fixed_cases else "corpus"),
        "append: %s" % ("true" if append else "false"),
        "engine_bin: %s" % resolved_engine,
        "engine_bin_sha256: %s" % eng_sha256,
        "repo_commit: %s" % repo_commit,
        "languages_filter: %s" % (",".join(languages) if languages else "all"),
        "kinds_filter: %s" % ("fixed" if fixed_cases else ",".join(kinds)),
        "quick: %s" % ("true" if quick else "false"),
        "workers: %d" % max(1, int(workers)),
        "timeout_sec: %.1f" % float(timeout_sec),
        "batch_cases: %d" % len(selected_items),
        "total_results_rows: %d" % len(ordered_rows),
        "started_at_utc: %s" % started_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "finished_at_utc: %s" % finished_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "elapsed_seconds: %.2f" % elapsed,
        "per_case_ms_median: %.3f" % median_ms,
        "per_case_ms_max: %.3f" % max_ms,
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
    ap = argparse.ArgumentParser(description="Run ThreeWaySemanticASTMerger over the M3 corpus or fixed cases")
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
    ap.add_argument(
        "--engine-bin",
        default=None,
        help="path to relay-merge-eval executable (default: Scripts/eval/merge-eval/.build/release/relay-merge-eval)",
    )
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
        summary = run_engine_eval(
            name=args.name,
            out_dir=args.out_dir,
            fixed_cases=args.fixed_cases,
            merge_cases_dir=args.merge_cases_dir,
            syntax_gate_dir=args.syntax_gate_dir,
            cases_tsv=args.cases_tsv,
            corpus_dir=args.corpus_dir,
            extract_subdir=args.extract_subdir,
            engine_bin=args.engine_bin,
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
        "run_engine: batch=%d total_rows=%d elapsed=%.2fs timeouts=%d results=%s"
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
