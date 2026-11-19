#!/usr/bin/env python3
"""Classifier and fixed-parser evaluator for RelayIDE M3 merge evaluation.

Classifies merge tool outputs into five mutually exclusive categories (03-relayide.md §M3 item 5):
  - same            : tool claims clean, output has no conflict markers, passes fixed parser,
                      and is byte-for-byte identical to the reference (human / expected / git_clean)
  - clean_different : tool claims clean, output has no conflict markers, passes fixed parser,
                      and differs from the reference; separately tracks:
                        * clean_different_ws_equal (identical after dropping blank lines and
                          trailing whitespace — NEVER counted in 'same')
                        * human_eq = left | right | none (on corpus conflict cases)
  - conflict        : tool does not claim clean and did not exit with rejection codes 3 or 4
  - rejected        : tool exited with code 3 or 4 (listed individually with reason)
  - damaged         : tool claims clean, but output fails the fixed parser, contains conflict
                      markers, is invalid UTF-8, or is missing

Corpus denominator rule (03-relayide.md §M3 item 3 & decision 10):
  - Computed separately per language (python, swift, typescript).
  - Cases whose human version fails the fixed parser (parsers.py) are excluded from that
    language's denominator and counted in `excluded_human_unparsable`.
  - The `git` (git merge-file) row is computed directly by classify.py as a self-check:
    conflict cases must be 100% `conflict`, clean cases must be 100% clean (`same` vs git).

Tool input TSV format (`--tool <name>=<path>`, `--cli-tsv`, `--engine-tsv`):
  UTF-8 tab-separated file (blank lines and `#` comments ignored; optional header row starting
  with `case_id` is skipped) with columns:
    1. case_id       : case identifier (`c00001`, `k00001`, or `merge-cases/<dir>` / `syntax-gate-cases/<dir>`)
    2. exit_code     : integer process exit status (`0`, `1`, `3`, `4`, ...)
    3. claimed_clean : `1` (`true`/`yes`) if tool claims clean merge, `0` (`false`/`no`) otherwise,
                       or `skip` if tool explicitly skips an unsupported language
    4. output_path   : file containing raw output bytes when `claimed_clean == 1` (may be empty or `-`
                       when `claimed_clean != 1`; relative paths resolve against the TSV's directory)
    5. reason        : (optional) single-line diagnostic/reason, recorded for `rejected` (exit 3/4)
    6. strategy      : (optional) CLI strategy tag (`line-level`, `declaration-level`, `none`, `-`)

Python 3.9 compatible, standard library only.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import csv
import os
import re
import shutil
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import parsers  # noqa: E402

ENV_CORPUS_DIR = "RELAY_MERGE_CORPUS_DIR"

CATEGORIES = ("same", "clean_different", "conflict", "rejected", "damaged")
CATEGORY_LABELS_ZH = {
    "same": "相同",
    "clean_different": "干净但不同",
    "conflict": "仍报冲突",
    "rejected": "拒绝",
    "damaged": "输出损坏",
}
CANONICAL_LANGUAGES = ("python", "swift", "typescript")

SUMMARY_FIELDS = [
    "kind",
    "language",
    "tool",
    "total_cases",
    "excluded_human_unparsable",
    "denominator",
    "same",
    "clean_different",
    "clean_different_ws_equal",
    "clean_different_human_eq_left",
    "clean_different_human_eq_right",
    "clean_different_human_eq_none",
    "conflict",
    "rejected",
    "damaged",
    "skipped_unsupported",
    "git_eq_human",
]

DETAIL_FIELDS = [
    "case_id",
    "kind",
    "language",
    "tool",
    "exit_code",
    "claimed_clean",
    "category",
    "ws_equal",
    "human_eq",
    "git_parses",
    "reason",
]

REJECTED_FIELDS = [
    "case_id",
    "kind",
    "language",
    "tool",
    "exit_code",
    "git_parses",
    "reason",
]

FIXED_CLASSIFIED_FIELDS = [
    "case_id",
    "ext",
    "reference",
    "git",
    "cli_exit",
    "cli_strategy",
    "cli",
    "cli_reason",
    "engine",
]


class CorpusNotConfiguredError(RuntimeError):
    """Raised when RELAY_MERGE_CORPUS_DIR is unset or missing."""


def normalize_ws(data):
    """Drops blank/whitespace-only lines and strips trailing whitespace on remaining lines."""
    return b"\n".join(line.rstrip() for line in data.splitlines() if line.strip())


def has_conflict_markers(data):
    """Returns True when `data` contains standard or extended git conflict markers (`<<<<<<<` / `>>>>>>>`).

    Does NOT treat standalone `=======` lines (e.g. Python RST docstring underlines) or `>>>`
    doctest prompts as conflict markers.
    """
    for line in data.splitlines():
        s = line.rstrip(b"\r\n")
        if s.startswith(b"<<<<<<<"):
            n = len(s) - len(s.lstrip(b"<"))
            if n >= 7 and (len(s) == n or s[n : n + 1] == b" "):
                return True
        elif s.startswith(b">>>>>>>"):
            n = len(s) - len(s.lstrip(b">"))
            if n >= 7 and (len(s) == n or s[n : n + 1] == b" "):
                return True
    return False


def is_same_as_reference(output_bytes, reference_bytes):
    """True iff `output_bytes` is byte-for-byte identical to `reference_bytes`."""
    if reference_bytes is None:
        return False
    return output_bytes == reference_bytes


def run_fixed_parsers(items, env=None, max_workers=4):
    """Runs the decoupled fixed parsers (`parsers.py`) on `(path, ext)` pairs."""
    return parsers.parse_files_batch(items, env=env, max_workers=max_workers)


def _effective_env(env=None):
    return dict(os.environ if env is None else env)


def _read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def _is_valid_utf8(data):
    try:
        data.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


def _sanitize_reason(text):
    if not text:
        return ""
    cleaned = " | ".join(part.strip() for part in text.replace("\t", " ").splitlines() if part.strip())
    # Strip ephemeral temp paths / home paths so outputs remain portable and deterministic
    tmp_dir = os.path.abspath(tempfile.gettempdir()).rstrip("/")
    if tmp_dir and tmp_dir != "/":
        cleaned = re.sub(re.escape("/private" + tmp_dir) + r"/[^\s:|]+", "<temp>", cleaned)
        cleaned = re.sub(re.escape(tmp_dir) + r"/[^\s:|]+", "<temp>", cleaned)
    cleaned = re.sub(r"/tmp/[^\s:|]+", "<temp>", cleaned)
    home_dir = os.path.expanduser("~").rstrip("/")
    if home_dir and home_dir != "/":
        cleaned = cleaned.replace(home_dir, "<home>")
    return cleaned


def extract_cli_rejection_reason(exit_code, stderr_bytes):
    """Extracts a deterministic, path-free rejection reason from `semantic-merge` stderr."""
    raw = stderr_bytes.decode("utf-8", "replace")
    if exit_code == 3:
        m = re.search(r"Merged output failed syntax check \(([^)]+)\)", raw)
        if m:
            return "exit=3: syntax_check_failed (%s)" % m.group(1).strip()
        m_zh = re.search(r"合并结果未通过语法检查（([^）]+)）", raw)
        if m_zh:
            return "exit=3: syntax_check_failed (%s)" % m_zh.group(1).strip()
        return "exit=3: syntax_check_failed"
    if exit_code == 4:
        m = re.search(r"git is unavailable or `git merge-file` failed \((.+)\)\. Refusing", raw)
        if m:
            return "exit=4: line_merge_unavailable (%s)" % _sanitize_reason(m.group(1))
        return "exit=4: line_merge_unavailable (%s)" % _sanitize_reason(raw)
    return _sanitize_reason(raw)


def _extract_cli_strategy(exit_code, stderr_bytes):
    if exit_code == 3 or exit_code == 4:
        return "-"
    text = stderr_bytes.decode("utf-8", "replace")
    for token in ("line-level", "declaration-level", "none"):
        if "[strategy=%s]" % token in text:
            return token
    return "?"


def _parse_claimed_clean(raw_val, line_no, path):
    val = raw_val.strip().lower()
    if val in ("1", "true", "yes"):
        return "1"
    if val in ("0", "false", "no"):
        return "0"
    if val in ("skip", "skipped"):
        return "skip"
    raise ValueError("%s:%d: invalid claimed_clean value %r (expected 1, 0, or skip)" % (path, line_no, raw_val))


def load_tool_tsv(path, default_base_dir=None):
    """Loads a per-tool result TSV into `{case_id: dict}`."""
    abs_path = os.path.abspath(path)
    base_dir = os.path.abspath(default_base_dir) if default_base_dir else os.path.dirname(abs_path)
    records = {}
    saw_first_row = False
    with open(abs_path, encoding="utf-8") as fh:
        for line_no, raw in enumerate(fh, start=1):
            stripped = raw.rstrip("\r\n")
            if not stripped.strip() or stripped.lstrip().startswith("#"):
                continue
            cols = stripped.split("\t")
            if not saw_first_row:
                saw_first_row = True
                if cols[0].strip() == "case_id":
                    continue
            if len(cols) < 4:
                raise ValueError("%s:%d: expected >= 4 tab-separated columns, got %d" % (path, line_no, len(cols)))
            case_id = cols[0].strip()
            if not case_id:
                raise ValueError("%s:%d: empty case_id" % (path, line_no))
            if case_id in records:
                raise ValueError("%s:%d: duplicate case_id %r" % (path, line_no, case_id))
            try:
                exit_code = int(cols[1].strip())
            except ValueError as exc:
                raise ValueError("%s:%d: invalid exit_code %r" % (path, line_no, cols[1])) from exc
            claimed_clean = _parse_claimed_clean(cols[2], line_no, path)
            raw_out = cols[3].strip()
            if not raw_out or raw_out == "-":
                out_path = ""
            elif os.path.isabs(raw_out):
                out_path = raw_out
            else:
                out_path = os.path.join(base_dir, raw_out)
            reason = _sanitize_reason(cols[4]) if len(cols) >= 5 else ""
            strategy = cols[5].strip() if len(cols) >= 6 else ""
            records[case_id] = {
                "case_id": case_id,
                "exit_code": exit_code,
                "claimed_clean": claimed_clean,
                "output_path": out_path,
                "reason": reason,
                "strategy": strategy,
            }
    return records


def _classify_one(
    tool_name,
    exit_code,
    claimed_clean,
    output_bytes,
    output_utf8_ok,
    output_has_markers,
    output_parses,
    reference_bytes,
):
    """Classifies one non-excluded `(case, tool)` pair into `(category, ws_equal)`."""
    if claimed_clean == "skip":
        return "skipped", False

    if claimed_clean == "0":
        if tool_name not in ("git", "git-merge-file") and exit_code in (3, 4):
            return "rejected", False
        return "conflict", False

    # Tool claims clean (`claimed_clean == "1"`): check corruption BEFORE byte-equality!
    if output_bytes is None or not output_utf8_ok:
        return "damaged", False
    if output_has_markers:
        return "damaged", False
    if output_parses is False:
        return "damaged", False

    if is_same_as_reference(output_bytes, reference_bytes):
        return "same", False

    ws_eq = (reference_bytes is not None) and (normalize_ws(output_bytes) == normalize_ws(reference_bytes))
    return "clean_different", ws_eq


def _git_merge_file_bytes(scratch_dir, left_path, base_path, right_path):
    git_env = {
        "PATH": "/usr/bin:/bin",
        "HOME": scratch_dir,
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }
    proc = subprocess.run(
        ["/usr/bin/git", "merge-file", "-p", "-L", "left", "-L", "base", "-L", "right", left_path, base_path, right_path],
        cwd=scratch_dir,
        env=git_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode < 0 or proc.returncode > 127:
        raise RuntimeError(
            "git merge-file failed (%d): %s" % (proc.returncode, proc.stderr.decode("utf-8", "replace").strip())
        )
    return proc.returncode, proc.stdout


def _empty_summary_bucket(kind, language, tool):
    return {
        "kind": kind,
        "language": language,
        "tool": tool,
        "total_cases": 0,
        "excluded_human_unparsable": 0,
        "denominator": 0,
        "same": 0,
        "clean_different": 0,
        "clean_different_ws_equal": 0,
        "clean_different_human_eq_left": 0,
        "clean_different_human_eq_right": 0,
        "clean_different_human_eq_none": 0,
        "conflict": 0,
        "rejected": 0,
        "damaged": 0,
        "skipped_unsupported": 0,
        "git_eq_human": 0,
    }


def _sum_summary_buckets(kind, tool, buckets):
    total = _empty_summary_bucket(kind, "all", tool)
    numeric_keys = [k for k in SUMMARY_FIELDS if k not in ("kind", "language", "tool")]
    for b in buckets:
        for k in numeric_keys:
            total[k] += b[k]
    return total


def classify_corpus(
    cases_tsv,
    corpus_dir=None,
    tool_specs=(),
    extract_subdir="extract",
    kinds=("conflict", "clean"),
    languages=None,
    max_conflicts_per_lang=None,
    allow_partial_tool=False,
    env=None,
    max_workers=4,
):
    """Classifies `git` (self-check) and any external `tool_specs` on `cases.tsv`."""
    eff_env = _effective_env(env)
    resolved_corpus = (corpus_dir or eff_env.get(ENV_CORPUS_DIR, "")).strip()
    if not resolved_corpus:
        raise CorpusNotConfiguredError("没跑：没有语料缓存")
    resolved_corpus = os.path.abspath(resolved_corpus)
    cases_root = os.path.join(resolved_corpus, extract_subdir, "cases")
    if not os.path.isdir(cases_root):
        raise CorpusNotConfiguredError("没跑：找不到语料抽取目录 (%s)" % cases_root)

    wanted_kinds = tuple(k.strip() for k in kinds if k.strip())
    wanted_langs = None
    if languages is not None:
        wanted_langs = set(parsers.canonical_language(x) for x in languages if x.strip())

    all_rows = []
    conflict_seen_per_lang = Counter()
    with open(cases_tsv, encoding="utf-8") as fh:
        for row in csv.DictReader(fh, delimiter="\t"):
            kind = row["kind"].strip()
            lang = parsers.canonical_language(row["language"])
            if kind not in wanted_kinds:
                continue
            if wanted_langs is not None and lang not in wanted_langs:
                continue
            if kind == "conflict" and max_conflicts_per_lang is not None:
                if conflict_seen_per_lang[lang] >= max_conflicts_per_lang:
                    continue
                conflict_seen_per_lang[lang] += 1
            row = dict(row)
            row["language"] = lang
            all_rows.append(row)

    present_langs = sorted(set(r["language"] for r in all_rows))
    if present_langs:
        # Always validate fixed-parser availability upfront (raises ParserNotConfiguredError -> exit 2)
        parsers.describe_parsers(present_langs, env=eff_env)

    loaded_tools = []
    for tool_name, tsv_path in tool_specs:
        if tool_name in ("git", "git-merge-file"):
            raise ValueError("tool name %r is reserved for classify.py's built-in git self-check" % (tool_name,))
        loaded_tools.append((tool_name, load_tool_tsv(tsv_path)))

    scratch_dir = tempfile.mkdtemp(prefix="relay-classify-corpus.")
    try:
        # 1. Inspect extracted case files and batch-parse all human versions
        case_infos = []
        human_parse_items = []
        for row in all_rows:
            cid = row["case_id"]
            ext = parsers.normalize_extension(row["path"])
            if parsers.language_for_extension(ext) is None:
                raise ValueError("unsupported file extension %r in cases.tsv (%s)" % (ext, cid))
            cdir = os.path.join(cases_root, cid)
            p_base = os.path.join(cdir, "base" + ext)
            p_left = os.path.join(cdir, "left" + ext)
            p_right = os.path.join(cdir, "right" + ext)
            p_human = os.path.join(cdir, "human" + ext)
            for req_p in (p_base, p_left, p_right, p_human):
                if not os.path.isfile(req_p):
                    raise RuntimeError("missing extracted file for %s: %s" % (cid, req_p))
            left_bytes = _read_bytes(p_left)
            right_bytes = _read_bytes(p_right)
            human_bytes = _read_bytes(p_human)
            if human_bytes == left_bytes:
                human_eq = "left"
            elif human_bytes == right_bytes:
                human_eq = "right"
            else:
                human_eq = "none"
            info = {
                "row": row,
                "case_id": cid,
                "kind": row["kind"],
                "language": row["language"],
                "ext": ext,
                "p_base": p_base,
                "p_left": p_left,
                "p_right": p_right,
                "p_human": p_human,
                "human_bytes": human_bytes,
                "human_eq": human_eq,
                "myers_conflicts": int(row["myers_conflicts"]),
                "git_rc": None,
                "git_out": None,
                "git_parses": None,
            }
            case_infos.append(info)
            human_parse_items.append((p_human, ext))

        human_verdicts = run_fixed_parsers(human_parse_items, env=eff_env, max_workers=max_workers) if human_parse_items else []
        for info, h_ok in zip(case_infos, human_verdicts):
            info["human_parses_ok"] = bool(h_ok)

        # 2. For clean cases, compute git merge-file output & batch-parse git outputs
        clean_infos = [info for info in case_infos if info["kind"] == "clean"]
        if clean_infos:
            git_scratch = os.path.join(scratch_dir, "git_clean")
            os.makedirs(git_scratch, exist_ok=True)
            workers = max(1, int(max_workers))
            with ThreadPoolExecutor(max_workers=workers) as pool:
                git_runs = list(
                    pool.map(
                        lambda inf: _git_merge_file_bytes(git_scratch, inf["p_left"], inf["p_base"], inf["p_right"]),
                        clean_infos,
                    )
                )
            git_parse_items = []
            for inf, (g_rc, g_out) in zip(clean_infos, git_runs):
                inf["git_rc"] = g_rc
                inf["git_out"] = g_out
                g_path = os.path.join(git_scratch, inf["case_id"] + inf["ext"])
                with open(g_path, "wb") as fh:
                    fh.write(g_out)
                git_parse_items.append((g_path, inf["ext"]))
            git_parse_verdicts = run_fixed_parsers(git_parse_items, env=eff_env, max_workers=max_workers)
            for inf, g_ok in zip(clean_infos, git_parse_verdicts):
                inf["git_parses"] = bool(g_ok)

        # 3. Built-in git merge-file self-check across all selected rows
        git_selfcheck_errors = []
        for inf in case_infos:
            cid = inf["case_id"]
            if inf["kind"] == "conflict":
                if inf["myers_conflicts"] <= 0:
                    git_selfcheck_errors.append(
                        "%s: kind=conflict has myers_conflicts=%d (expected >= 1)" % (cid, inf["myers_conflicts"])
                    )
            elif inf["kind"] == "clean":
                if inf["myers_conflicts"] != 0:
                    git_selfcheck_errors.append(
                        "%s: kind=clean has myers_conflicts=%d (expected 0)" % (cid, inf["myers_conflicts"])
                    )
                elif inf["git_rc"] != 0:
                    git_selfcheck_errors.append(
                        "%s: kind=clean git merge-file exited with %d (expected 0)" % (cid, inf["git_rc"])
                    )
                elif inf["human_parses_ok"]:
                    if has_conflict_markers(inf["git_out"]):
                        git_selfcheck_errors.append("%s: kind=clean git output contains conflict markers" % cid)
                    elif not inf["git_parses"]:
                        git_selfcheck_errors.append("%s: kind=clean git output failed fixed parser" % cid)

        # 4. Prepare and batch-parse all claimed_clean==1 outputs across external tools
        tool_eval_entries = []  # (tool_name, info, rec, out_bytes, utf8_ok, markers, parse_slot_or_none)
        batch_parse_items = []
        for tool_name, records in loaded_tools:
            for inf in case_infos:
                if not inf["human_parses_ok"]:
                    continue
                cid = inf["case_id"]
                rec = records.get(cid)
                if rec is None:
                    if allow_partial_tool:
                        continue
                    raise ValueError("tool %r TSV is missing non-excluded case_id %r" % (tool_name, cid))
                out_bytes = None
                utf8_ok = False
                markers = False
                parse_slot = None
                if rec["claimed_clean"] == "1":
                    op = rec["output_path"]
                    if op and os.path.isfile(op):
                        out_bytes = _read_bytes(op)
                        utf8_ok = _is_valid_utf8(out_bytes)
                        if utf8_ok:
                            markers = has_conflict_markers(out_bytes)
                            if not markers:
                                parse_slot = len(batch_parse_items)
                                batch_parse_items.append((op, inf["ext"]))
                tool_eval_entries.append((tool_name, inf, rec, out_bytes, utf8_ok, markers, parse_slot))

        batch_verdicts = (
            run_fixed_parsers(batch_parse_items, env=eff_env, max_workers=max_workers) if batch_parse_items else []
        )

        # 5. Aggregate summary buckets, detail rows, and individual rejected rows
        active_langs = present_langs if present_langs else list(CANONICAL_LANGUAGES)
        all_tool_names = ["git"] + [t_name for t_name, _ in loaded_tools]
        buckets = {}
        for k in wanted_kinds:
            for lang in active_langs:
                for t_name in all_tool_names:
                    buckets[(k, lang, t_name)] = _empty_summary_bucket(k, lang, t_name)

        detail_rows = []
        rejected_rows = []

        # Populate denominator & git row
        for inf in case_infos:
            k = inf["kind"]
            lang = inf["language"]
            for t_name in all_tool_names:
                buckets[(k, lang, t_name)]["total_cases"] += 1
                if not inf["human_parses_ok"]:
                    buckets[(k, lang, t_name)]["excluded_human_unparsable"] += 1
                else:
                    buckets[(k, lang, t_name)]["denominator"] += 1

            if not inf["human_parses_ok"]:
                continue

            git_b = buckets[(k, lang, "git")]
            if k == "conflict":
                git_cat = "conflict" if inf["myers_conflicts"] >= 1 else "same"
                git_b[git_cat] += 1
                detail_rows.append(
                    {
                        "case_id": inf["case_id"],
                        "kind": k,
                        "language": lang,
                        "tool": "git",
                        "exit_code": inf["myers_conflicts"],
                        "claimed_clean": "0" if inf["myers_conflicts"] >= 1 else "1",
                        "category": git_cat,
                        "ws_equal": "0",
                        "human_eq": inf["human_eq"],
                        "git_parses": "-",
                        "reason": "",
                    }
                )
            else:
                g_out = inf["git_out"]
                g_utf8 = _is_valid_utf8(g_out)
                g_markers = has_conflict_markers(g_out) if g_utf8 else False
                git_cat, git_ws = _classify_one(
                    "git",
                    inf["git_rc"],
                    "1" if inf["git_rc"] == 0 else "0",
                    g_out,
                    g_utf8,
                    g_markers,
                    inf["git_parses"],
                    g_out,
                )
                git_b[git_cat] += 1
                if g_out == inf["human_bytes"]:
                    git_b["git_eq_human"] += 1
                detail_rows.append(
                    {
                        "case_id": inf["case_id"],
                        "kind": k,
                        "language": lang,
                        "tool": "git",
                        "exit_code": inf["git_rc"],
                        "claimed_clean": "1" if inf["git_rc"] == 0 else "0",
                        "category": git_cat,
                        "ws_equal": "1" if git_ws else "0",
                        "human_eq": inf["human_eq"],
                        "git_parses": "1" if inf["git_parses"] else "0",
                        "reason": "",
                    }
                )

        # Populate external tool rows
        for tool_name, inf, rec, out_bytes, utf8_ok, markers, parse_slot in tool_eval_entries:
            k = inf["kind"]
            lang = inf["language"]
            b = buckets[(k, lang, tool_name)]
            out_parses = batch_verdicts[parse_slot] if parse_slot is not None else False
            ref_bytes = inf["human_bytes"] if k == "conflict" else inf["git_out"]
            cat, ws_eq = _classify_one(
                tool_name,
                rec["exit_code"],
                rec["claimed_clean"],
                out_bytes,
                utf8_ok,
                markers,
                out_parses,
                ref_bytes,
            )
            if cat == "skipped":
                b["skipped_unsupported"] += 1
            else:
                b[cat] += 1
                if cat == "clean_different":
                    if ws_eq:
                        b["clean_different_ws_equal"] += 1
                    if inf["human_eq"] == "left":
                        b["clean_different_human_eq_left"] += 1
                    elif inf["human_eq"] == "right":
                        b["clean_different_human_eq_right"] += 1
                    else:
                        b["clean_different_human_eq_none"] += 1
                if k == "clean" and cat in ("same", "clean_different") and out_bytes == inf["human_bytes"]:
                    b["git_eq_human"] += 1

            git_parses_flag = ("1" if inf["git_parses"] else "0") if k == "clean" else "-"
            reason_str = rec["reason"]
            if cat == "rejected" and not reason_str:
                reason_str = "exit=%d" % rec["exit_code"]
            if cat == "rejected":
                rejected_rows.append(
                    {
                        "case_id": inf["case_id"],
                        "kind": k,
                        "language": lang,
                        "tool": tool_name,
                        "exit_code": rec["exit_code"],
                        "git_parses": git_parses_flag,
                        "reason": reason_str,
                    }
                )
            detail_rows.append(
                {
                    "case_id": inf["case_id"],
                    "kind": k,
                    "language": lang,
                    "tool": tool_name,
                    "exit_code": rec["exit_code"],
                    "claimed_clean": rec["claimed_clean"],
                    "category": cat,
                    "ws_equal": "1" if ws_eq else "0",
                    "human_eq": inf["human_eq"],
                    "git_parses": git_parses_flag,
                    "reason": reason_str,
                }
            )

        summary_rows = []
        for k in wanted_kinds:
            for t_name in all_tool_names:
                per_lang = [buckets[(k, lang, t_name)] for lang in active_langs]
                summary_rows.extend(per_lang)
                if len(active_langs) > 1:
                    summary_rows.append(_sum_summary_buckets(k, t_name, per_lang))

        return {
            "summary_rows": summary_rows,
            "detail_rows": detail_rows,
            "rejected_rows": rejected_rows,
            "git_selfcheck_ok": len(git_selfcheck_errors) == 0,
            "git_selfcheck_errors": git_selfcheck_errors,
        }
    finally:
        shutil.rmtree(scratch_dir, ignore_errors=True)


def _lookup_fixed_record(records, full_id, short_name):
    if full_id in records:
        return records[full_id]
    if short_name in records:
        return records[short_name]
    return None


def classify_fixed_cases(
    merge_cases_dir,
    syntax_gate_dir,
    cli_path=None,
    cli_tsv=None,
    engine_tsv=None,
    env=None,
    max_workers=4,
):
    """Classifies the 35 merge-cases + 4 syntax-gate-cases (03-relayide.md §M3 item 7)."""
    eff_env = _effective_env(env)
    suites = [
        ("merge-cases", os.path.abspath(merge_cases_dir)),
        ("syntax-gate-cases", os.path.abspath(syntax_gate_dir)),
    ]

    discovered = []
    needed_langs = set()
    for suite_prefix, suite_dir in suites:
        if not os.path.isdir(suite_dir):
            raise RuntimeError("fixed cases directory not found: %s" % suite_dir)
        for name in sorted(os.listdir(suite_dir)):
            cdir = os.path.join(suite_dir, name)
            if not os.path.isdir(cdir):
                continue
            base_files = [f for f in sorted(os.listdir(cdir)) if f.startswith("base.")]
            if not base_files:
                raise RuntimeError("no base.* file in %s" % cdir)
            ext = parsers.normalize_extension(base_files[0])
            lang = parsers.language_for_extension(ext)
            if lang is not None:
                needed_langs.add(lang)
            discovered.append(
                {
                    "case_id": "%s/%s" % (suite_prefix, name),
                    "short_name": name,
                    "cdir": cdir,
                    "ext": ext,
                    "lang": lang,
                    "p_base": os.path.join(cdir, "base" + ext),
                    "p_left": os.path.join(cdir, "left" + ext),
                    "p_right": os.path.join(cdir, "right" + ext),
                    "p_expected": os.path.join(cdir, "expected" + ext),
                }
            )

    if needed_langs:
        parsers.describe_parsers(sorted(needed_langs), env=eff_env)

    cli_records = load_tool_tsv(cli_tsv) if cli_tsv else None
    eng_records = load_tool_tsv(engine_tsv) if engine_tsv else None
    resolved_cli = os.path.abspath(cli_path or os.path.join(REPO_ROOT, "Scripts/acceptance/relay-cli.sh"))

    scratch_dir = tempfile.mkdtemp(prefix="relay-classify-fixed.")
    cli_home = os.path.join(scratch_dir, "cli-home")
    os.makedirs(cli_home, exist_ok=True)
    out_store = os.path.join(scratch_dir, "outputs")
    os.makedirs(out_store, exist_ok=True)

    try:
        batch_parse_items = []
        # Step 1: Run git merge-file, determine reference, and collect CLI / optional engine outputs
        for idx, item in enumerate(discovered):
            cid = item["case_id"]
            ext = item["ext"]
            has_parser = item["lang"] is not None

            git_rc, git_out = _git_merge_file_bytes(scratch_dir, item["p_left"], item["p_base"], item["p_right"])
            item["git_rc"] = git_rc
            item["git_out"] = git_out

            if os.path.isfile(item["p_expected"]):
                item["reference_kind"] = "expected"
                item["reference_bytes"] = _read_bytes(item["p_expected"])
            elif git_rc == 0:
                item["reference_kind"] = "git_clean"
                item["reference_bytes"] = git_out
            else:
                item["reference_kind"] = "true_conflict"
                item["reference_bytes"] = None

            # Queue git clean output for fixed parser if applicable
            item["git_utf8_ok"] = _is_valid_utf8(git_out) if git_rc == 0 else False
            item["git_markers"] = has_conflict_markers(git_out) if (git_rc == 0 and item["git_utf8_ok"]) else False
            item["git_parse_slot"] = None
            if git_rc == 0 and item["git_utf8_ok"] and not item["git_markers"] and has_parser:
                gp = os.path.join(out_store, "git_%d%s" % (idx, ext))
                with open(gp, "wb") as fh:
                    fh.write(git_out)
                item["git_parse_slot"] = len(batch_parse_items)
                batch_parse_items.append((gp, ext))

            # Run or load published CLI (`semantic-merge`)
            if cli_records is not None:
                crec = _lookup_fixed_record(cli_records, cid, item["short_name"])
                if crec is None:
                    raise ValueError("--cli-tsv is missing fixed case %r" % cid)
                cli_rc = crec["exit_code"]
                cli_claimed = crec["claimed_clean"]
                cli_out = _read_bytes(crec["output_path"]) if (cli_claimed == "1" and crec["output_path"] and os.path.isfile(crec["output_path"])) else (b"" if cli_claimed != "1" else None)
                cli_strategy = crec["strategy"] or ("-" if cli_rc in (3, 4) else ("none" if cli_rc == 1 else "line-level"))
                cli_reason = crec["reason"] if cli_rc in (3, 4) else ""
                if cli_rc in (3, 4) and not cli_reason:
                    cli_reason = "exit=%d" % cli_rc
            else:
                cli_env = dict(eff_env)
                cli_env["RELAY_CLI_HOME"] = cli_home
                proc = subprocess.run(
                    [resolved_cli, "semantic-merge", item["p_base"], item["p_left"], item["p_right"], "--lang", "en"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=cli_env,
                )
                cli_rc = proc.returncode
                cli_claimed = "1" if cli_rc == 0 else "0"
                cli_out = proc.stdout
                cli_strategy = _extract_cli_strategy(cli_rc, proc.stderr)
                cli_reason = extract_cli_rejection_reason(cli_rc, proc.stderr) if cli_rc in (3, 4) else ""

            item["cli_rc"] = cli_rc
            item["cli_claimed"] = cli_claimed
            item["cli_out"] = cli_out
            item["cli_strategy"] = cli_strategy
            item["cli_reason"] = cli_reason
            item["cli_utf8_ok"] = _is_valid_utf8(cli_out) if (cli_claimed == "1" and cli_out is not None) else False
            item["cli_markers"] = (
                has_conflict_markers(cli_out) if (cli_claimed == "1" and item["cli_utf8_ok"]) else False
            )
            item["cli_parse_slot"] = None
            if cli_claimed == "1" and item["cli_utf8_ok"] and not item["cli_markers"] and has_parser:
                cp = os.path.join(out_store, "cli_%d%s" % (idx, ext))
                with open(cp, "wb") as fh:
                    fh.write(cli_out)
                item["cli_parse_slot"] = len(batch_parse_items)
                batch_parse_items.append((cp, ext))

            # Optional declaration-level engine TSV (Stage 4)
            if eng_records is not None:
                erec = _lookup_fixed_record(eng_records, cid, item["short_name"])
                if erec is None:
                    raise ValueError("--engine-tsv is missing fixed case %r" % cid)
                eng_rc = erec["exit_code"]
                eng_claimed = erec["claimed_clean"]
                eng_out = (
                    _read_bytes(erec["output_path"])
                    if (eng_claimed == "1" and erec["output_path"] and os.path.isfile(erec["output_path"]))
                    else None
                )
                item["eng_rc"] = eng_rc
                item["eng_claimed"] = eng_claimed
                item["eng_out"] = eng_out
                item["eng_utf8_ok"] = _is_valid_utf8(eng_out) if (eng_claimed == "1" and eng_out is not None) else False
                item["eng_markers"] = (
                    has_conflict_markers(eng_out) if (eng_claimed == "1" and item["eng_utf8_ok"]) else False
                )
                item["eng_parse_slot"] = None
                if eng_claimed == "1" and item["eng_utf8_ok"] and not item["eng_markers"] and has_parser:
                    ep = os.path.join(out_store, "eng_%d%s" % (idx, ext))
                    with open(ep, "wb") as fh:
                        fh.write(eng_out)
                    item["eng_parse_slot"] = len(batch_parse_items)
                    batch_parse_items.append((ep, ext))

        batch_verdicts = (
            run_fixed_parsers(batch_parse_items, env=eff_env, max_workers=max_workers) if batch_parse_items else []
        )

        out_rows = []
        rejected_rows = []
        summary = {
            "git": Counter(),
            "cli": Counter(),
        }
        if eng_records is not None:
            summary["engine"] = Counter()

        for item in discovered:
            has_parser = item["lang"] is not None
            ref_b = item["reference_bytes"]

            git_parses = (
                batch_verdicts[item["git_parse_slot"]]
                if item["git_parse_slot"] is not None
                else (None if not has_parser else False)
            )
            git_cat, git_ws = _classify_one(
                "git",
                item["git_rc"],
                "1" if item["git_rc"] == 0 else "0",
                item["git_out"] if item["git_rc"] == 0 else b"",
                item["git_utf8_ok"],
                item["git_markers"],
                git_parses,
                ref_b,
            )
            summary["git"][git_cat] += 1
            if git_ws:
                summary["git"]["clean_different_ws_equal"] += 1

            cli_parses = (
                batch_verdicts[item["cli_parse_slot"]]
                if item["cli_parse_slot"] is not None
                else (None if not has_parser else False)
            )
            cli_cat, cli_ws = _classify_one(
                "cli",
                item["cli_rc"],
                item["cli_claimed"],
                item["cli_out"],
                item["cli_utf8_ok"],
                item["cli_markers"],
                cli_parses,
                ref_b,
            )
            summary["cli"][cli_cat] += 1
            if cli_ws:
                summary["cli"]["clean_different_ws_equal"] += 1
            if cli_cat == "rejected":
                rejected_rows.append(
                    {
                        "case_id": item["case_id"],
                        "kind": "fixed",
                        "language": item["lang"] or item["ext"].lstrip("."),
                        "tool": "cli",
                        "exit_code": item["cli_rc"],
                        "git_parses": ("1" if git_parses else "0") if git_parses is not None else "-",
                        "reason": item["cli_reason"],
                    }
                )

            eng_cat = ""
            if eng_records is not None:
                eng_parses = (
                    batch_verdicts[item["eng_parse_slot"]]
                    if item["eng_parse_slot"] is not None
                    else (None if not has_parser else False)
                )
                eng_cat, eng_ws = _classify_one(
                    "engine",
                    item["eng_rc"],
                    item["eng_claimed"],
                    item["eng_out"],
                    item["eng_utf8_ok"],
                    item["eng_markers"],
                    eng_parses,
                    ref_b,
                )
                summary["engine"][eng_cat] += 1
                if eng_ws:
                    summary["engine"]["clean_different_ws_equal"] += 1

            out_rows.append(
                {
                    "case_id": item["case_id"],
                    "ext": item["ext"],
                    "reference": item["reference_kind"],
                    "git": git_cat,
                    "cli_exit": str(item["cli_rc"]),
                    "cli_strategy": item["cli_strategy"],
                    "cli": cli_cat,
                    "cli_reason": item["cli_reason"] if cli_cat == "rejected" else "",
                    "engine": eng_cat,
                }
            )

        return {
            "rows": out_rows,
            "summary": summary,
            "rejected_rows": rejected_rows,
        }
    finally:
        shutil.rmtree(scratch_dir, ignore_errors=True)


def _write_tsv(path, fieldnames, rows):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for r in rows:
            writer.writerow(r)


def _check_classified_tsv(expected_path, actual_rows, has_engine_tsv):
    with open(expected_path, encoding="utf-8") as fh:
        expected_rows = list(csv.DictReader(fh, delimiter="\t"))

    problems = []
    if len(expected_rows) != len(actual_rows):
        problems.append(
            "row count mismatch: expected %d rows in %s, got %d"
            % (len(expected_rows), expected_path, len(actual_rows))
        )

    exp_by_id = {r["case_id"]: r for r in expected_rows}
    act_by_id = {r["case_id"]: r for r in actual_rows}

    for cid in sorted(set(exp_by_id) | set(act_by_id)):
        if cid not in exp_by_id:
            problems.append("unexpected case_id %r not in %s" % (cid, expected_path))
            continue
        if cid not in act_by_id:
            problems.append("missing case_id %r expected by %s" % (cid, expected_path))
            continue
        er = exp_by_id[cid]
        ar = act_by_id[cid]
        for col in FIXED_CLASSIFIED_FIELDS:
            if col == "engine" and not has_engine_tsv and er.get("engine", "") != "":
                problems.append(
                    "%s: %s has engine=%r but --engine-tsv was not provided" % (cid, expected_path, er.get("engine"))
                )
                continue
            ev = er.get(col, "")
            av = ar.get(col, "")
            if ev != av:
                problems.append("%s column %s: expected %r, got %r" % (cid, col, ev, av))
    return problems


def _print_corpus_report(res):
    writer = csv.DictWriter(sys.stdout, fieldnames=SUMMARY_FIELDS, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    for r in res["summary_rows"]:
        writer.writerow(r)

    if res["rejected_rows"]:
        sys.stdout.write("\n# rejected_cases\n")
        rwriter = csv.DictWriter(sys.stdout, fieldnames=REJECTED_FIELDS, delimiter="\t", lineterminator="\n")
        rwriter.writeheader()
        for r in res["rejected_rows"]:
            rwriter.writerow(r)

    if res["git_selfcheck_ok"]:
        sys.stdout.write("\nPASS: git merge-file self-check holds (conflict=100% conflict, clean=100% clean)\n")
    else:
        for err in res["git_selfcheck_errors"][:20]:
            sys.stdout.write("FAIL: git self-check: %s\n" % err)


def _print_fixed_report(res):
    sys.stdout.write("tool\ttotal\tsame\tclean_different\tclean_different_ws_equal\tconflict\trejected\tdamaged\n")
    total = len(res["rows"])
    for tool_name, cnt in res["summary"].items():
        sys.stdout.write(
            "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n"
            % (
                tool_name,
                total,
                cnt.get("same", 0),
                cnt.get("clean_different", 0),
                cnt.get("clean_different_ws_equal", 0),
                cnt.get("conflict", 0),
                cnt.get("rejected", 0),
                cnt.get("damaged", 0),
            )
        )
    if res["rejected_rows"]:
        sys.stdout.write("\n# rejected_cases\n")
        rwriter = csv.DictWriter(sys.stdout, fieldnames=REJECTED_FIELDS, delimiter="\t", lineterminator="\n")
        rwriter.writeheader()
        for r in res["rejected_rows"]:
            rwriter.writerow(r)


def _parse_tool_spec(spec):
    if "=" not in spec:
        raise argparse.ArgumentTypeError("expected NAME=TSV_PATH for --tool, got %r" % (spec,))
    name, path = spec.split("=", 1)
    name = name.strip()
    path = path.strip()
    if not name or not path:
        raise argparse.ArgumentTypeError("empty tool name or path in %r" % (spec,))
    return name, path


def main(argv=None):
    ap = argparse.ArgumentParser(description="RelayIDE M3 merge output classifier and fixed-parser evaluator")
    ap.add_argument(
        "--cases-tsv",
        default=os.path.join(REPO_ROOT, "Fixtures/merge-corpus/cases.tsv"),
        help="path to Fixtures/merge-corpus/cases.tsv",
    )
    ap.add_argument("--corpus-dir", default=None, help="override $RELAY_MERGE_CORPUS_DIR")
    ap.add_argument("--extract-subdir", default="extract", help="extraction subdirectory under corpus-dir (default: extract)")
    ap.add_argument(
        "--tool",
        action="append",
        default=[],
        type=_parse_tool_spec,
        metavar="NAME=TSV",
        help="tool result TSV to classify (repeatable)",
    )
    ap.add_argument("--kinds", default="conflict,clean", help="comma-separated case kinds (default: conflict,clean)")
    ap.add_argument("--languages", default=None, help="comma-separated language filter (python,swift,typescript)")
    ap.add_argument("--max-conflicts-per-lang", type=int, default=None, help="cap conflict cases per language (for --quick)")
    ap.add_argument("--allow-partial-tool", action="store_true", help="allow tool TSV to omit cases")
    ap.add_argument("--summary-out", default=None, help="write summary TSV to path")
    ap.add_argument("--details-out", default=None, help="write per-case per-tool classification TSV to path")
    ap.add_argument("--rejected-out", default=None, help="write individual rejected cases TSV to path")
    ap.add_argument("--workers", type=int, default=4, help="max parallel workers for Swift/git checks (default: 4)")

    ap.add_argument("--fixed-cases", action="store_true", help="classify the 39 fixed merge + syntax-gate cases")
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
        "--cli",
        default=os.path.join(REPO_ROOT, "Scripts/acceptance/relay-cli.sh"),
        help="path to Scripts/acceptance/relay-cli.sh",
    )
    ap.add_argument("--cli-tsv", default=None, help="optional pre-recorded CLI result TSV for fixed cases")
    ap.add_argument("--engine-tsv", default=None, help="optional declaration-level engine TSV for fixed cases (Stage 4)")
    ap.add_argument("--write-classified", default=None, help="write CLASSIFIED.tsv for fixed cases")
    ap.add_argument("--check-classified", default=None, help="verify fixed-case results match existing CLASSIFIED.tsv")

    args = ap.parse_args(argv)

    try:
        if args.fixed_cases:
            res = classify_fixed_cases(
                merge_cases_dir=args.merge_cases_dir,
                syntax_gate_dir=args.syntax_gate_dir,
                cli_path=args.cli,
                cli_tsv=args.cli_tsv,
                engine_tsv=args.engine_tsv,
                max_workers=args.workers,
            )
            if args.write_classified:
                _write_tsv(args.write_classified, FIXED_CLASSIFIED_FIELDS, res["rows"])
            if args.rejected_out:
                _write_tsv(args.rejected_out, REJECTED_FIELDS, res["rejected_rows"])
            _print_fixed_report(res)
            if args.check_classified:
                problems = _check_classified_tsv(args.check_classified, res["rows"], bool(args.engine_tsv))
                if problems:
                    for p in problems:
                        sys.stdout.write("FAIL: %s\n" % p)
                    return 1
                sys.stdout.write("PASS: fixed-case classification matches %s\n" % os.path.basename(args.check_classified))
            return 0

        kinds = tuple(x.strip() for x in args.kinds.split(",") if x.strip())
        langs = [x.strip() for x in args.languages.split(",") if x.strip()] if args.languages else None
        res = classify_corpus(
            cases_tsv=args.cases_tsv,
            corpus_dir=args.corpus_dir,
            tool_specs=args.tool,
            extract_subdir=args.extract_subdir,
            kinds=kinds,
            languages=langs,
            max_conflicts_per_lang=args.max_conflicts_per_lang,
            allow_partial_tool=args.allow_partial_tool,
            max_workers=args.workers,
        )
        if args.summary_out:
            _write_tsv(args.summary_out, SUMMARY_FIELDS, res["summary_rows"])
        if args.details_out:
            _write_tsv(args.details_out, DETAIL_FIELDS, res["detail_rows"])
        if args.rejected_out:
            _write_tsv(args.rejected_out, REJECTED_FIELDS, res["rejected_rows"])
        _print_corpus_report(res)
        return 0 if res["git_selfcheck_ok"] else 1
    except (CorpusNotConfiguredError, parsers.ParserNotConfiguredError) as exc:
        print(str(exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
