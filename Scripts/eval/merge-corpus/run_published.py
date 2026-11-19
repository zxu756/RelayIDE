#!/usr/bin/env python3
"""Corpus runner for RelayIDE's published `semantic-merge` CLI subcommand (M3 Stage 3).

Reads `Fixtures/merge-corpus/cases.tsv` and extracted files under `$RELAY_MERGE_CORPUS_DIR/extract/cases/`,
invokes `Scripts/acceptance/relay-cli.sh semantic-merge <base> <left> <right> --lang en` in parallel
(default 4 workers, 60s per-case wall-clock timeout), and writes:
  - `$RELAY_MERGE_CORPUS_DIR/runs/<name>/results.tsv` (compatible with `classify.py --tool <name>=...`)
  - `$RELAY_MERGE_CORPUS_DIR/runs/<name>/outputs/<case_id><ext>` (verbatim stdout when exit_code == 0)
  - `$RELAY_MERGE_CORPUS_DIR/runs/<name>/env.txt` (resolved python3/tsc/node/git paths & versions on child PATH,
    RelayIDE binary path & sha256, start/end timestamps, elapsed seconds, exit-code summary, and timeouts)

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
import subprocess
import sys
import tempfile
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import parsers  # noqa: E402

ENV_CORPUS_DIR = "RELAY_MERGE_CORPUS_DIR"
ENV_EVAL_PYTHON = "RELAY_EVAL_PYTHON"
ENV_CLI_BIN = "RELAY_CLI_BIN"

RESULTS_FIELDS = [
    "case_id",
    "exit_code",
    "claimed_clean",
    "output_path",
    "reason",
    "strategy",
]

VALIDATOR_FALLBACKS = {
    "python3": ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"],
    "tsc": ["/opt/homebrew/bin/tsc", "/usr/local/bin/tsc"],
    "node": ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"],
    "git": [],
}

QUICK_LIMIT_PER_LANG_KIND = 20


class RunnerConfigError(RuntimeError):
    """Raised when required corpus/environment configuration is missing (exit code 2)."""


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


def build_child_path(path_mode, env=None):
    """Constructs the child PATH for `caller` or `eval-python-first` mode."""
    eff = _effective_env(env)
    caller_path = eff.get("PATH", "")
    if path_mode == "caller":
        return caller_path
    if path_mode == "eval-python-first":
        eval_py = eff.get(ENV_EVAL_PYTHON, "").strip()
        if not eval_py:
            raise RunnerConfigError("没跑：未配置 %s（path-mode=eval-python-first 需要固定 Python 路径）" % ENV_EVAL_PYTHON)
        eval_py_abs = os.path.abspath(eval_py)
        if not (os.path.isfile(eval_py_abs) and os.access(eval_py_abs, os.X_OK)):
            raise RunnerConfigError("没跑：%s 不可执行 (%s)" % (ENV_EVAL_PYTHON, eval_py_abs))
        # Keep symlink directory intact so `python3` sibling symlink in uv/venv bin is found first on PATH.
        eval_py_dir = os.path.dirname(eval_py_abs)
        if not caller_path:
            return eval_py_dir
        return eval_py_dir + ":" + caller_path
    raise ValueError("unknown path_mode: %r" % (path_mode,))


def sanitize_stderr_reason(raw_text, extra_temp_dirs=(), extra_home_dirs=()):
    """Produces a single-line reason stripped of temporary directory and home directory paths."""
    if not raw_text:
        return ""
    parts = []
    for raw_line in raw_text.replace("\t", " ").splitlines():
        s = raw_line.strip()
        if not s:
            continue
        if s.startswith("semantic-merge:"):
            s = s[len("semantic-merge:") :].strip()
        if s:
            parts.append(s)
    cleaned = " | ".join(parts)
    if not cleaned:
        return ""

    # Strip explicit temporary roots first (longest first, raw + realpath)
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


def extract_strategy(exit_code, stderr_bytes):
    """Extracts `strategy=<token>` from `semantic-merge` stderr."""
    text = stderr_bytes.decode("utf-8", "replace")
    m = re.search(r"\[strategy=([A-Za-z0-9_-]+)\]", text)
    if not m:
        m = re.search(r"\bstrategy=([A-Za-z0-9_-]+)", text)
    if m:
        return m.group(1)
    if exit_code in (3, 4, 124):
        return "-"
    if exit_code == 1:
        return "none"
    return "?"


def probe_child_tools(child_path, scratch_home):
    """Probes python3, tsc, node, and git on `child_path` and records paths and `--version` outputs."""
    probe_env = {
        "PATH": child_path,
        "HOME": scratch_home,
        "CFFIXED_USER_HOME": scratch_home,
        "LC_ALL": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    info = {}
    for tool in ("python3", "tsc", "node", "git"):
        on_path = shutil.which(tool, path=child_path)
        effective = on_path
        if effective is None:
            for cand in VALIDATOR_FALLBACKS.get(tool, ()):
                if os.path.isfile(cand) and os.access(cand, os.X_OK):
                    effective = cand + " (fallback-outside-PATH)"
                    break
        version_str = "not-found"
        exe_to_run = on_path
        if exe_to_run is None and effective is not None:
            exe_to_run = effective.split(" ", 1)[0]
        if exe_to_run:
            try:
                proc = subprocess.run(
                    [exe_to_run, "--version"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    stdin=subprocess.DEVNULL,
                    env=probe_env,
                    cwd=scratch_home,
                    timeout=10.0,
                )
                combined = (proc.stdout + b"\n" + proc.stderr).decode("utf-8", "replace")
                lines = [ln.strip() for ln in combined.splitlines() if ln.strip()]
                version_str = lines[0] if lines else ("exit=%d" % proc.returncode)
            except Exception as exc:  # pragma: no cover - defensive
                version_str = "error: %s" % exc
        info[tool] = {
            "path_lookup": on_path or "not-in-PATH",
            "effective": effective or "not-found",
            "version": version_str,
        }
    return info


def select_cases(cases_tsv, kinds=("conflict", "clean"), languages=None, case_ids=None, quick=False):
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
            r = dict(row)
            r["language"] = lang
            selected.append(r)

    return selected, all_case_order


def _run_single_case(
    row,
    cases_root,
    cli_wrapper,
    cli_bin,
    child_path,
    base_env,
    tmp_root,
    outputs_dir,
    conflict_outputs_dir,
    timeout_sec,
    extra_home_dirs,
):
    cid = row["case_id"].strip()
    ext = parsers.normalize_extension(row["path"])
    cdir = os.path.join(cases_root, cid)
    p_base = os.path.join(cdir, "base" + ext)
    p_left = os.path.join(cdir, "left" + ext)
    p_right = os.path.join(cdir, "right" + ext)

    for p in (p_base, p_left, p_right):
        if not os.path.isfile(p):
            raise FileNotFoundError("missing extracted input file: %s" % p)

    case_home = os.path.join(tmp_root, "homes", cid)
    os.makedirs(case_home, exist_ok=True)

    child_env = dict(base_env)
    child_env["RELAY_CLI_HOME"] = case_home
    if cli_bin:
        child_env["RELAY_CLI_BIN"] = cli_bin
    else:
        child_env.pop("RELAY_CLI_BIN", None)
    child_env["RELAY_CLI_CHILD_PATH"] = child_path
    child_env["PATH"] = child_path
    child_env["PYTHONDONTWRITEBYTECODE"] = "1"

    cmd = [cli_wrapper, "semantic-merge", p_base, p_left, p_right, "--lang", "en"]
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
    finally:
        shutil.rmtree(case_home, ignore_errors=True)

    if timed_out:
        return {
            "case_id": cid,
            "exit_code": "124",
            "claimed_clean": "0",
            "output_path": "",
            "reason": "timeout",
            "strategy": "-",
        }

    claimed_clean = "1" if rc == 0 else "0"
    rel_out_path = ""
    if rc == 0:
        out_file = os.path.join(outputs_dir, cid + ext)
        with open(out_file, "wb") as fh:
            fh.write(out_bytes)
        rel_out_path = "outputs/" + cid + ext
    elif rc == 1 and conflict_outputs_dir is not None:
        c_file = os.path.join(conflict_outputs_dir, cid + ext)
        with open(c_file, "wb") as fh:
            fh.write(out_bytes)

    strategy = extract_strategy(rc, err_bytes)
    reason = ""
    if rc in (3, 4) or rc not in (0, 1):
        err_text = err_bytes.decode("utf-8", "replace")
        reason = sanitize_stderr_reason(
            err_text,
            extra_temp_dirs=(tmp_root, case_home),
            extra_home_dirs=tuple(extra_home_dirs) + (case_home,),
        )
        if not reason:
            reason = "exit=%d" % rc

    return {
        "case_id": cid,
        "exit_code": str(rc),
        "claimed_clean": claimed_clean,
        "output_path": rel_out_path,
        "reason": reason,
        "strategy": strategy,
    }


def _validate_run_name(name):
    cleaned = (name or "").strip()
    if not cleaned or "/" in cleaned or "\\" in cleaned or cleaned in (".", "..") or ".." in cleaned:
        raise ValueError("invalid --name %r: must be a single directory name under runs/" % (name,))
    return cleaned


def _load_existing_rows(results_tsv):
    existing = {}
    if not os.path.isfile(results_tsv):
        return existing
    with open(results_tsv, encoding="utf-8") as fh:
        for row in csv.DictReader(fh, delimiter="\t"):
            cid = row["case_id"].strip()
            existing[cid] = {k: row.get(k, "") for k in RESULTS_FIELDS}
    return existing


def run_corpus(
    name,
    path_mode="caller",
    cases_tsv=None,
    corpus_dir=None,
    extract_subdir="extract",
    cli_path=None,
    cli_bin=None,
    languages=None,
    kinds=("conflict", "clean"),
    case_ids=None,
    quick=False,
    workers=4,
    timeout_sec=60.0,
    append=False,
    save_conflict_outputs=False,
    env=None,
):
    eff_env = _effective_env(env)
    run_name = _validate_run_name(name)

    resolved_corpus = (corpus_dir or eff_env.get(ENV_CORPUS_DIR, "")).strip()
    if not resolved_corpus:
        raise RunnerConfigError("没跑：没有语料缓存")
    resolved_corpus = os.path.abspath(resolved_corpus)
    cases_root = os.path.join(resolved_corpus, extract_subdir, "cases")
    if not os.path.isdir(cases_root):
        raise RunnerConfigError("没跑：找不到语料抽取目录 (%s)" % cases_root)

    resolved_cases_tsv = os.path.abspath(cases_tsv or os.path.join(REPO_ROOT, "Fixtures/merge-corpus/cases.tsv"))
    if not os.path.isfile(resolved_cases_tsv):
        raise RunnerConfigError("没跑：找不到语料清单 (%s)" % resolved_cases_tsv)

    resolved_cli = os.path.abspath(cli_path or os.path.join(REPO_ROOT, "Scripts/acceptance/relay-cli.sh"))
    if not (os.path.isfile(resolved_cli) and os.access(resolved_cli, os.X_OK)):
        raise RunnerConfigError("没跑：找不到可执行入口脚本 (%s)" % resolved_cli)

    raw_bin = (cli_bin or eff_env.get(ENV_CLI_BIN, "")).strip()
    if raw_bin:
        resolved_bin = os.path.abspath(raw_bin)
        if not (os.path.isfile(resolved_bin) and os.access(resolved_bin, os.X_OK)):
            raise RunnerConfigError("没跑：找不到产品二进制 (%s)" % resolved_bin)
    else:
        resolved_bin = None

    child_path = build_child_path(path_mode, env=eff_env)

    selected_rows, all_case_order = select_cases(
        resolved_cases_tsv,
        kinds=kinds,
        languages=languages,
        case_ids=case_ids,
        quick=quick,
    )

    run_dir = os.path.join(resolved_corpus, "runs", run_name)
    outputs_dir = os.path.join(run_dir, "outputs")
    conflict_outputs_dir = os.path.join(run_dir, "conflict_outputs") if save_conflict_outputs else None
    results_tsv = os.path.join(run_dir, "results.tsv")
    env_txt = os.path.join(run_dir, "env.txt")

    if not append and os.path.isdir(run_dir):
        if os.path.isdir(outputs_dir):
            shutil.rmtree(outputs_dir)
        if conflict_outputs_dir and os.path.isdir(conflict_outputs_dir):
            shutil.rmtree(conflict_outputs_dir)
        if os.path.isfile(results_tsv):
            os.remove(results_tsv)
        if os.path.isfile(env_txt):
            os.remove(env_txt)

    os.makedirs(outputs_dir, exist_ok=True)
    if conflict_outputs_dir is not None:
        os.makedirs(conflict_outputs_dir, exist_ok=True)

    existing_by_id = _load_existing_rows(results_tsv) if append else {}

    extra_homes = []
    if eff_env.get("HOME"):
        extra_homes.append(eff_env["HOME"])

    tmp_root = tempfile.mkdtemp(prefix="relay-run-published.")
    started_utc = datetime.now(timezone.utc)
    t0 = time.monotonic()
    try:
        probe_home = os.path.join(tmp_root, "probe-home")
        os.makedirs(probe_home, exist_ok=True)
        tool_info = probe_child_tools(child_path, probe_home)
        bin_sha256 = _sha256_file(resolved_bin) if resolved_bin else _sha256_file(resolved_cli)

        results_by_id = dict(existing_by_id)
        max_workers = max(1, int(workers))

        with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
            future_map = {
                pool.submit(
                    _run_single_case,
                    row,
                    cases_root,
                    resolved_cli,
                    resolved_bin,
                    child_path,
                    eff_env,
                    tmp_root,
                    outputs_dir,
                    conflict_outputs_dir,
                    float(timeout_sec),
                    extra_homes,
                ): row["case_id"].strip()
                for row in selected_rows
            }
            for fut in concurrent.futures.as_completed(future_map):
                rec = fut.result()
                results_by_id[rec["case_id"]] = rec
    finally:
        shutil.rmtree(tmp_root, ignore_errors=True)

    elapsed = time.monotonic() - t0
    finished_utc = datetime.now(timezone.utc)

    ordered_rows = []
    seen_ids = set()
    for cid in all_case_order:
        if cid in results_by_id:
            ordered_rows.append(results_by_id[cid])
            seen_ids.add(cid)
    for cid in sorted(results_by_id):
        if cid not in seen_ids:
            ordered_rows.append(results_by_id[cid])

    with open(results_tsv, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=RESULTS_FIELDS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for r in ordered_rows:
            writer.writerow(r)

    batch_counts = Counter(int(results_by_id[r["case_id"].strip()]["exit_code"]) for r in selected_rows)
    total_counts = Counter(int(r["exit_code"]) for r in ordered_rows)
    timeouts = [r["case_id"] for r in ordered_rows if r["exit_code"] == "124"]

    env_lines = [
        "=== run_published ===",
        "name: %s" % run_name,
        "append: %s" % ("true" if append else "false"),
        "path_mode: %s" % path_mode,
        "child_PATH: %s" % child_path,
        "cli_wrapper: %s" % resolved_cli,
        "cli_bin: %s" % (resolved_bin or "(delegated to relay-cli.sh)"),
        "cli_bin_sha256: %s" % bin_sha256,
    ]
    for tool in ("python3", "tsc", "node", "git"):
        ti = tool_info[tool]
        env_lines.append("%s_path: %s" % (tool, ti["path_lookup"]))
        env_lines.append("%s_effective: %s" % (tool, ti["effective"]))
        env_lines.append("%s_version: %s" % (tool, ti["version"]))
    env_lines.extend(
        [
            "languages_filter: %s" % (",".join(languages) if languages else "all"),
            "kinds_filter: %s" % ",".join(kinds),
            "quick: %s" % ("true" if quick else "false"),
            "workers: %d" % max(1, int(workers)),
            "timeout_sec: %.1f" % float(timeout_sec),
            "batch_cases: %d" % len(selected_rows),
            "total_results_rows: %d" % len(ordered_rows),
            "started_at_utc: %s" % started_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "finished_at_utc: %s" % finished_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "elapsed_seconds: %.2f" % elapsed,
            "batch_exit_counts: exit_0=%d exit_1=%d exit_3=%d exit_4=%d exit_124=%d other=%d"
            % (
                batch_counts.get(0, 0),
                batch_counts.get(1, 0),
                batch_counts.get(3, 0),
                batch_counts.get(4, 0),
                batch_counts.get(124, 0),
                sum(v for k, v in batch_counts.items() if k not in (0, 1, 3, 4, 124)),
            ),
            "total_exit_counts: exit_0=%d exit_1=%d exit_3=%d exit_4=%d exit_124=%d other=%d"
            % (
                total_counts.get(0, 0),
                total_counts.get(1, 0),
                total_counts.get(3, 0),
                total_counts.get(4, 0),
                total_counts.get(124, 0),
                sum(v for k, v in total_counts.items() if k not in (0, 1, 3, 4, 124)),
            ),
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
        "env_txt": env_txt,
        "batch_cases": len(selected_rows),
        "total_rows": len(ordered_rows),
        "elapsed_seconds": elapsed,
        "batch_exit_counts": dict(batch_counts),
        "total_exit_counts": dict(total_counts),
        "timeout_cases": timeouts,
    }


def main(argv=None, env=None):
    ap = argparse.ArgumentParser(description="Run RelayIDE semantic-merge over the extracted M3 merge corpus")
    ap.add_argument("--name", required=True, help="output directory name under $RELAY_MERGE_CORPUS_DIR/runs/<name>/")
    ap.add_argument(
        "--path-mode",
        default="caller",
        choices=["caller", "eval-python-first"],
        help="child PATH mode: caller inherits PATH; eval-python-first prepends dirname($RELAY_EVAL_PYTHON)",
    )
    ap.add_argument(
        "--cases-tsv",
        default=os.path.join(REPO_ROOT, "Fixtures/merge-corpus/cases.tsv"),
        help="path to Fixtures/merge-corpus/cases.tsv",
    )
    ap.add_argument("--corpus-dir", default=None, help="override $RELAY_MERGE_CORPUS_DIR")
    ap.add_argument("--extract-subdir", default="extract", help="extraction subdirectory under corpus-dir")
    ap.add_argument(
        "--cli",
        default=os.path.join(REPO_ROOT, "Scripts/acceptance/relay-cli.sh"),
        help="path to Scripts/acceptance/relay-cli.sh",
    )
    ap.add_argument("--cli-bin", default=None, help="override $RELAY_CLI_BIN")
    ap.add_argument("--languages", default=None, help="comma-separated language filter (python,swift,typescript)")
    ap.add_argument("--kinds", default="conflict,clean", help="comma-separated case kinds (default: conflict,clean)")
    ap.add_argument("--case-ids", default=None, help="optional comma-separated list of specific case_ids to run")
    ap.add_argument(
        "--quick",
        action="store_true",
        help="run only the first 20 conflict and first 20 clean cases per language",
    )
    ap.add_argument("--workers", type=int, default=4, help="parallel worker count (default: 4)")
    ap.add_argument("--timeout", type=float, default=60.0, help="per-case timeout in seconds (default: 60)")
    ap.add_argument(
        "--append",
        action="store_true",
        help="merge newly executed rows into existing results.tsv (for splitting runs by --languages)",
    )
    ap.add_argument(
        "--save-conflict-outputs",
        action="store_true",
        help="also save exit-1 conflict stdout under conflict_outputs/<case_id><ext> for byte-level inspection",
    )
    args = ap.parse_args(argv)

    langs = [x.strip() for x in args.languages.split(",") if x.strip()] if args.languages else None
    kinds = tuple(x.strip() for x in args.kinds.split(",") if x.strip())
    case_ids = [x.strip() for x in args.case_ids.split(",") if x.strip()] if args.case_ids else None

    try:
        summary = run_corpus(
            name=args.name,
            path_mode=args.path_mode,
            cases_tsv=args.cases_tsv,
            corpus_dir=args.corpus_dir,
            extract_subdir=args.extract_subdir,
            cli_path=args.cli,
            cli_bin=args.cli_bin,
            languages=langs,
            kinds=kinds,
            case_ids=case_ids,
            quick=args.quick,
            workers=args.workers,
            timeout_sec=args.timeout,
            append=args.append,
            save_conflict_outputs=args.save_conflict_outputs,
            env=env,
        )
    except RunnerConfigError as exc:
        print(str(exc))
        return 2

    print(
        "run_published: name=%s batch=%d total_rows=%d elapsed=%.2fs timeouts=%d results=%s"
        % (
            args.name,
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
