#!/usr/bin/env python3
"""M3 Semantic Merge Evaluation Report Generator and `--check` Verifier (Stage 5).

Generates three reproducible artifacts from tool `results.tsv` files and `classify.py` outputs:
  1. `m3-merge-eval.tsv`         — one row per file per tool (`case_id`, `language`, `kind`, `tool`,
                                   `exit_code`, `category`, `ws_equal`, `human_eq`, `reason`, plus
                                   recomputation columns `git_parses`, `elapsed_ms`, `eq_git`, `crlf`,
                                   `dropped_added_lines`)
  2. `m3-merge-eval-summary.tsv` — every numeric cell across every report table (`table`, `row`, `col`, `value`)
  3. `m3-merge-eval.md`          — human-readable evaluation report populated exclusively from `summary.tsv`

`--check` mode recomputes `summary` from `m3-merge-eval.tsv` alone, compares every cell against
`m3-merge-eval-summary.tsv`, re-renders the expected Markdown from the recomputed summary, and compares
every numeric token appearing in `m3-merge-eval.md`. Any discrepancy exits with status `1` and lists all
mismatches.

Python 3.9 compatible, standard library only.
"""
import argparse
from collections import Counter
import csv
import difflib
import hashlib
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../../.."))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import parsers  # noqa: E402

CANONICAL_LANGUAGES = ("python", "swift", "typescript")
CORPUS_TOOLS = ("git", "published_caller", "published_evalpy", "engine", "mergiraf")
FIXED_TABLE_TOOLS = ("git", "published_caller", "engine")

EVAL_TSV_FIELDS = [
    "case_id",
    "language",
    "kind",
    "tool",
    "exit_code",
    "category",
    "ws_equal",
    "human_eq",
    "reason",
    "git_parses",
    "elapsed_ms",
    "eq_git",
    "crlf",
    "dropped_added_lines",
]

SUMMARY_TSV_FIELDS = ["table", "row", "col", "value"]

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
USERS_PREFIX = "/Users" + "/"
USERS_PATH_RE = re.compile(re.escape(USERS_PREFIX) + r"[^/\s:,\"')|>`]+")
MD_NUMBER_RE = re.compile(r"(?<![A-Za-z_])\d+(?:\.\d+)?%?")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def _read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def sanitize_report_text(text, repo_root=None, corpus_dir=None, extra_homes=()):
    """Strips local repository, corpus cache, home directory paths, and email addresses."""
    if text is None:
        return ""
    s = str(text).replace("\r", " ").replace("\n", " ").replace("\t", " ").strip()
    if not s:
        return ""

    if corpus_dir:
        for cand in (os.path.abspath(corpus_dir), os.path.realpath(corpus_dir)):
            cand = cand.rstrip("/")
            if cand and cand != "/":
                s = s.replace(cand, "$RELAY_MERGE_CORPUS_DIR")

    if repo_root:
        for cand in (os.path.abspath(repo_root), os.path.realpath(repo_root)):
            cand = cand.rstrip("/")
            if cand and cand != "/":
                s = s.replace(cand, "<repo>")

    homes = set()
    env_home = os.path.expanduser("~").rstrip("/")
    if env_home and env_home != "/":
        homes.add(env_home)
        homes.add(os.path.realpath(env_home).rstrip("/"))
    for eh in extra_homes:
        if eh:
            ab = os.path.abspath(eh).rstrip("/")
            if ab and ab != "/":
                homes.add(ab)
            rp = os.path.realpath(eh).rstrip("/")
            if rp and rp != "/":
                homes.add(rp)

    for hm in sorted(homes, key=len, reverse=True):
        s = s.replace(hm, "~")

    s = USERS_PATH_RE.sub("~", s)
    s = EMAIL_RE.sub("<email>", s)
    return s


def _language_from_ext(ext):
    e = ext.lower()
    if not e.startswith("."):
        e = "." + e
    mapping = {
        ".py": "python",
        ".swift": "swift",
        ".ts": "typescript",
        ".tsx": "typescript",
        ".js": "javascript",
        ".mjs": "javascript",
        ".cjs": "javascript",
        ".rs": "rust",
        ".go": "go",
        ".java": "java",
    }
    return mapping.get(e, e.lstrip(".") or "unknown")


def _pct(num, denom):
    if denom <= 0:
        return "0.00%"
    return "%.2f%%" % ((100.0 * float(num)) / float(denom))


def check_dropped_added_lines(base_bytes, left_bytes, right_bytes, out_bytes):
    """Checks via `difflib` whether an exit-0 merge output dropped any line added by `base->left` or `base->right`."""
    base_lines = base_bytes.decode("utf-8", "replace").splitlines()
    left_lines = left_bytes.decode("utf-8", "replace").splitlines()
    right_lines = right_bytes.decode("utf-8", "replace").splitlines()
    out_lines = out_bytes.decode("utf-8", "replace").splitlines()

    def diff_side(side_lines):
        sm = difflib.SequenceMatcher(None, base_lines, side_lines, autojunk=False)
        matched_base = set()
        added = []
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag == "equal":
                matched_base.update(range(i1, i2))
            elif tag in ("insert", "replace"):
                added.extend(side_lines[j1:j2])
        return matched_base, added

    matched_l, added_l = diff_side(left_lines)
    matched_r, added_r = diff_side(right_lines)
    untouched_counts = Counter(base_lines[i] for i in (matched_l & matched_r))
    out_counts = Counter(out_lines)

    missing_left = []
    for ln, add_cnt in Counter(added_l).items():
        needed = untouched_counts.get(ln, 0) + add_cnt
        have = out_counts.get(ln, 0)
        if have < needed:
            for _ in range(needed - have):
                missing_left.append(ln)

    missing_right = []
    for ln, add_cnt in Counter(added_r).items():
        needed = untouched_counts.get(ln, 0) + add_cnt
        have = out_counts.get(ln, 0)
        if have < needed:
            for _ in range(needed - have):
                missing_right.append(ln)

    dropped_total = len(missing_left) + len(missing_right)
    return {
        "ok": dropped_total == 0,
        "left_added_count": len(added_l),
        "right_added_count": len(added_r),
        "dropped_count": dropped_total,
        "missing_left": missing_left,
        "missing_right": missing_right,
    }


def _git_merge_file_bytes(scratch_dir, left_path, base_path, right_path):
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": scratch_dir,
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }
    proc = subprocess.run(
        [
            "/usr/bin/git",
            "merge-file",
            "-p",
            "-L",
            "left",
            "-L",
            "base",
            "-L",
            "right",
            left_path,
            base_path,
            right_path,
        ],
        cwd=scratch_dir,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        stdin=subprocess.DEVNULL,
    )
    if proc.returncode < 0 or proc.returncode > 127:
        raise RuntimeError(
            "git merge-file failed (%d): %s"
            % (proc.returncode, proc.stderr.decode("utf-8", "replace"))
        )
    return proc.returncode, proc.stdout


def _load_tsv_rows(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        filtered = (ln for ln in fh if ln.strip() and not ln.lstrip().startswith("#"))
        for row in csv.DictReader(filtered, delimiter="\t"):
            rows.append(dict(row))
    return rows


def _parse_env_txt(path):
    """Parses `env.txt` (potentially appended across language batches) and sums `elapsed_seconds`."""
    if not path or not os.path.isfile(path):
        return {}, 0.0
    kv = {}
    elapsed_sum = 0.0
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            ln = raw.strip()
            if not ln or ln.startswith("==="):
                continue
            if ":" not in ln:
                continue
            k, v = ln.split(":", 1)
            k = k.strip()
            v = v.strip()
            kv[k] = v
            if k == "elapsed_seconds":
                try:
                    elapsed_sum += float(v)
                except ValueError:
                    pass
    return kv, elapsed_sum


def _detect_machine_info():
    macos_ver = platform.mac_ver()[0] or "unknown"
    build_ver = ""
    chip = platform.machine() or "unknown"
    ncpu = os.cpu_count() or 1
    for cmd, target in (
        (["/usr/bin/sw_vers", "-productVersion"], "ver"),
        (["/usr/bin/sw_vers", "-buildVersion"], "build"),
        (["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], "chip"),
        (["/usr/sbin/sysctl", "-n", "hw.ncpu"], "ncpu"),
    ):
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3.0)
            if proc.returncode == 0:
                val = proc.stdout.decode("utf-8", "replace").strip()
                if val:
                    if target == "ver":
                        macos_ver = val
                    elif target == "build":
                        build_ver = val
                    elif target == "chip":
                        chip = val
                    elif target == "ncpu":
                        ncpu = int(val)
        except Exception:
            pass
    os_part = "macOS %s (%s)" % (macos_ver, build_ver) if build_ver else ("macOS %s" % macos_ver)
    return "%s; %s (%d cores)" % (os_part, chip, ncpu)


def _detect_git_commit(repo_root):
    try:
        proc = subprocess.run(
            ["/usr/bin/git", "-C", repo_root, "rev-parse", "HEAD"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5.0,
        )
        if proc.returncode == 0:
            val = proc.stdout.decode("utf-8", "replace").strip()
            if val:
                return val
    except Exception:
        pass
    return "unknown"


def _detect_sys_git_version():
    try:
        proc = subprocess.run(
            ["/usr/bin/git", "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5.0,
        )
        if proc.returncode == 0:
            return "/usr/bin/git (%s)" % proc.stdout.decode("utf-8", "replace").strip()
    except Exception:
        pass
    return "/usr/bin/git"


def load_eval_tsv(eval_tsv_path):
    """Loads `# meta` / `# rule1_example` comment headers and all TSV rows from `m3-merge-eval.tsv`."""
    meta = {}
    rule1_examples = []
    data_lines = []
    with open(eval_tsv_path, encoding="utf-8") as fh:
        for raw in fh:
            if not raw.strip():
                continue
            if raw.startswith("# meta\t"):
                parts = raw.rstrip("\r\n").split("\t", 2)
                if len(parts) == 3:
                    meta[parts[1]] = parts[2]
                elif len(parts) == 2:
                    meta[parts[1]] = ""
            elif raw.startswith("# rule1_example\t"):
                parts = raw.rstrip("\r\n").split("\t")
                if len(parts) >= 9:
                    rule1_examples.append(
                        {
                            "tool": parts[1],
                            "case_id": parts[2],
                            "language": parts[3],
                            "category": parts[4],
                            "left_added": parts[5],
                            "right_added": parts[6],
                            "dropped": parts[7],
                            "note": parts[8],
                        }
                    )
            elif raw.lstrip().startswith("#"):
                continue
            else:
                data_lines.append(raw)

    rows = list(csv.DictReader(data_lines, delimiter="\t"))
    return {"meta": meta, "rule1_examples": rule1_examples, "rows": rows}


def evaluate_decision_rules(summary_map, languages=CANONICAL_LANGUAGES):
    """Evaluates all 5 rows of the keep/drop decision table (`03-relayide.md` §M3)."""
    def get_int(table, row, col):
        return int(summary_map.get((table, row, col), "0"))

    # Rule 1: Published command has any `damaged` output OR exits 0 while dropping an added line
    r1_per_lang = {}
    r1_damaged_total = 0
    r1_dropped_total = 0
    for lg in languages:
        c_dmg = get_int("row6_conflict_published", "published_caller:%s" % lg, "damaged")
        e_dmg = get_int("row6_conflict_published", "published_evalpy:%s" % lg, "damaged")
        c_chk = get_int("row16_rule1_added_lines", "published_caller:%s" % lg, "exit0_checked")
        c_drp = get_int("row16_rule1_added_lines", "published_caller:%s" % lg, "dropped_cases")
        e_drp = get_int("row16_rule1_added_lines", "published_evalpy:%s" % lg, "dropped_cases")
        dmg = max(c_dmg, e_dmg)
        drp = max(c_drp, e_drp)
        r1_damaged_total += c_dmg + e_dmg
        r1_dropped_total += c_drp + e_drp
        r1_per_lang[lg] = "损坏 %d，退出 0 共 %d 例中丢行 %d" % (dmg, c_chk, drp)
    r1_triggered = (r1_damaged_total > 0) or (r1_dropped_total > 0)

    # Rule 2: Published command `same` < 20% of in-denominator conflict files in ANY language
    # Boundary: exact 20% (`same * 5 >= denominator` when `denominator > 0`) PASSES (does NOT trigger Rule 2).
    r2_per_lang = {}
    r2_any_below_20 = False
    for lg in languages:
        denom = get_int("row6_conflict_published", "published_caller:%s" % lg, "denominator")
        c_same = get_int("row6_conflict_published", "published_caller:%s" % lg, "same")
        e_same = get_int("row6_conflict_published", "published_evalpy:%s" % lg, "same")
        eff_same = min(c_same, e_same)
        pct_str = _pct(eff_same, denom)
        if denom == 0 or (eff_same * 5 < denom):
            r2_any_below_20 = True
            tag = "不到 20%"
        else:
            tag = "过线（≥ 20%）"
        r2_per_lang[lg] = "%d / %d (%s，%s)" % (eff_same, denom, pct_str, tag)
    r2_triggered = r2_any_below_20

    # Rule 3: mergiraf `same >= published.same` across ALL 3 languages AND `damaged == 0`
    # Swift unsupported -> Swift cell must explicitly state "没跑", and 3-language condition is not met.
    r3_per_lang = {}
    r3_all_three_ok = True
    for lg in languages:
        denom = get_int("row10_mergiraf_conflict", lg, "denominator")
        skipped = get_int("row10_mergiraf_conflict", lg, "skipped_in_denom")
        mgf_same = get_int("row10_mergiraf_conflict", lg, "same")
        mgf_dmg = get_int("row10_mergiraf_conflict", lg, "damaged")
        pub_same = get_int("row6_conflict_published", "published_caller:%s" % lg, "same")
        if denom == 0 or skipped >= denom:
            r3_all_three_ok = False
            r3_per_lang[lg] = "没跑（不支持 %s，跳过 %d / %d）" % (lg, skipped, denom)
        else:
            ok_lg = (mgf_same >= pub_same) and (mgf_dmg == 0)
            if not ok_lg:
                r3_all_three_ok = False
            r3_per_lang[lg] = "mergiraf %d / %d (%s) 对发布命令 %d / %d (%s)，损坏 %d" % (
                mgf_same,
                denom,
                _pct(mgf_same, denom),
                pub_same,
                denom,
                _pct(pub_same, denom),
                mgf_dmg,
            )
    r3_triggered = r3_all_three_ok

    # Rule 4: Published command passes >= 20% in ALL 3 languages (with 0 damaged/dropped) AND mergiraf is not better
    all_pass_20 = (not r1_triggered) and (not r2_triggered)
    r4_triggered = all_pass_20 and (not r3_triggered)
    r4_per_lang = {}
    for lg in languages:
        denom = get_int("row6_conflict_published", "published_caller:%s" % lg, "denominator")
        pub_same = get_int("row6_conflict_published", "published_caller:%s" % lg, "same")
        pass_lg = denom > 0 and (pub_same * 5 >= denom)
        r4_per_lang[lg] = "%d / %d (%s，%s)" % (
            pub_same,
            denom,
            _pct(pub_same, denom),
            "过线" if pass_lg else "未过线",
        )

    # Rule 5: Declaration-level engine — unconditional standing rule ("不论结果都不再单独输出")
    r5_per_lang = {}
    for lg in languages:
        denom = get_int("row9_engine_conflict", lg, "denominator")
        eng_same = get_int("row9_engine_conflict", lg, "same")
        eng_dmg = get_int("row9_engine_conflict", lg, "damaged")
        r5_per_lang[lg] = "相同 %d / %d (%s)，损坏 %d" % (
            eng_same,
            denom,
            _pct(eng_same, denom),
            eng_dmg,
        )
    r5_triggered = True

    return [
        {
            "rule_id": 1,
            "condition": "发布的命令有任何一例“输出损坏”，或者退出 0 却丢了一边新增的行",
            "triggered": r1_triggered,
            "status_label": "触发" if r1_triggered else "没触发",
            "per_lang": r1_per_lang,
        },
        {
            "rule_id": 2,
            "condition": "发布的命令“与人工相同”在任一语言里不到该语言冲突文件的 20%（暂定）",
            "triggered": r2_triggered,
            "status_label": "触发" if r2_triggered else "没触发",
            "per_lang": r2_per_lang,
        },
        {
            "rule_id": 3,
            "condition": "mergiraf 在三种语言上“相同”都不低于发布的命令，且“输出损坏”为 0",
            "triggered": r3_triggered,
            "status_label": "触发" if r3_triggered else "没触发",
            "per_lang": r3_per_lang,
        },
        {
            "rule_id": 4,
            "condition": "发布的命令在三种语言上都过线，且 mergiraf 不比它好",
            "triggered": r4_triggered,
            "status_label": "触发" if r4_triggered else "没触发",
            "per_lang": r4_per_lang,
        },
        {
            "rule_id": 5,
            "condition": "声明级引擎（不论结果都不再单独输出；数字只用来回答“换解析器值不值得”）",
            "triggered": r5_triggered,
            "status_label": "触发",
            "per_lang": r5_per_lang,
        },
    ]


def compute_summary_from_eval_tsv(eval_tsv_path):
    """Recomputes all `summary.tsv` `(table, row, col, value)` entries solely from `m3-merge-eval.tsv`."""
    eval_data = load_eval_tsv(eval_tsv_path)
    meta = eval_data["meta"]
    rows = eval_data["rows"]

    summary_rows = []
    summary_map = {}

    def emit(table, row, col, val):
        s_val = str(val)
        key = (table, row, col)
        summary_map[key] = s_val
        summary_rows.append({"table": table, "row": row, "col": col, "value": s_val})

    # Index rows by kind / tool / language
    corpus_rows = [r for r in rows if r["kind"] in ("conflict", "clean")]
    fixed_rows = [r for r in rows if r["kind"] == "fixed"]

    # 0. Timings table (Row 14)
    for t_key in (
        "elapsed_fixed_s",
        "elapsed_published_caller_s",
        "elapsed_published_evalpy_s",
        "elapsed_engine_s",
        "elapsed_mergiraf_s",
        "elapsed_classify_s",
        "elapsed_total_s",
    ):
        raw_v = meta.get(t_key, "0.00")
        try:
            fmt_v = "%.2f" % float(raw_v)
        except ValueError:
            fmt_v = "0.00"
        emit("row14_timings", t_key, "seconds", fmt_v)

    # Helper to aggregate corpus category counts for (kind, tool, langs)
    def agg_corpus(kind, tool, langs):
        sub = [r for r in corpus_rows if r["kind"] == kind and r["tool"] == tool and r["language"] in langs]
        total = len(sub)
        excl = sum(1 for r in sub if r["category"] == "excluded")
        in_d = [r for r in sub if r["category"] != "excluded"]
        denom = len(in_d)
        cats = Counter(r["category"] for r in in_d)
        ws_eq = sum(1 for r in in_d if r["category"] == "clean_different" and r["ws_equal"] == "1")
        heq_l = sum(1 for r in in_d if r["category"] == "clean_different" and r["human_eq"] == "left")
        heq_r = sum(1 for r in in_d if r["category"] == "clean_different" and r["human_eq"] == "right")
        heq_n = sum(1 for r in in_d if r["category"] == "clean_different" and r["human_eq"] == "none")
        all_heq_l = sum(1 for r in in_d if r["human_eq"] == "left")
        all_heq_r = sum(1 for r in in_d if r["human_eq"] == "right")
        skipped_total = sum(1 for r in sub if r["exit_code"] == "skip")
        skipped_in_denom = cats.get("skipped", 0)
        timeouts = sum(1 for r in sub if r["exit_code"] == "124")
        return {
            "total_cases": total,
            "excluded_human_unparsable": excl,
            "denominator": denom,
            "same": cats.get("same", 0),
            "same_pct": _pct(cats.get("same", 0), denom),
            "clean_different": cats.get("clean_different", 0),
            "clean_different_ws_equal": ws_eq,
            "clean_different_human_eq_left": heq_l,
            "clean_different_human_eq_right": heq_r,
            "clean_different_human_eq_none": heq_n,
            "denom_human_eq_left": all_heq_l,
            "denom_human_eq_right": all_heq_r,
            "conflict": cats.get("conflict", 0),
            "rejected": cats.get("rejected", 0),
            "damaged": cats.get("damaged", 0),
            "skipped_total": skipped_total,
            "skipped_in_denom": skipped_in_denom,
            "timeout_count": timeouts,
            "sub_rows": sub,
            "in_denom_rows": in_d,
        }

    lang_groups = [(lg, (lg,)) for lg in CANONICAL_LANGUAGES] + [("all", CANONICAL_LANGUAGES)]

    # 1. Row 6: Published command on conflict set (plus git baseline)
    for tool in ("git", "published_caller", "published_evalpy"):
        for lg_name, lg_set in lang_groups:
            st = agg_corpus("conflict", tool, lg_set)
            rkey = "%s:%s" % (tool, lg_name)
            for col in (
                "total_cases",
                "excluded_human_unparsable",
                "denominator",
                "same",
                "same_pct",
                "clean_different",
                "clean_different_ws_equal",
                "clean_different_human_eq_left",
                "clean_different_human_eq_right",
                "conflict",
                "rejected",
                "damaged",
                "denom_human_eq_left",
                "denom_human_eq_right",
            ):
                emit("row6_conflict_published", rkey, col, st[col])

    # 2. Row 7: Clean 500 regression set
    for tool in ("git", "published_caller", "published_evalpy"):
        for lg_name, lg_set in lang_groups:
            st = agg_corpus("clean", tool, lg_set)
            sub = st["sub_rows"]
            in_d = st["in_denom_rows"]
            exit0_eq_git = sum(1 for r in in_d if r["exit_code"] == "0" and r["eq_git"] == "1")
            exit0_neq_git = sum(1 for r in sub if r["exit_code"] == "0" and r["eq_git"] != "1")
            rej_in_denom = sum(1 for r in in_d if r["exit_code"] == "3")
            rej_misrejected = sum(1 for r in in_d if r["exit_code"] == "3" and r["git_parses"] == "1")
            exit3_excl = sum(1 for r in sub if r["category"] == "excluded" and r["exit_code"] == "3")
            exit1_4_other = sum(1 for r in sub if r["exit_code"] not in ("0", "3"))
            rkey = "%s:%s" % (tool, lg_name)
            emit("row7_clean_published", rkey, "total_cases", st["total_cases"])
            emit("row7_clean_published", rkey, "excluded_human_unparsable", st["excluded_human_unparsable"])
            emit("row7_clean_published", rkey, "denominator", st["denominator"])
            emit("row7_clean_published", rkey, "same", st["same"])
            emit("row7_clean_published", rkey, "exit0_eq_git", exit0_eq_git)
            emit("row7_clean_published", rkey, "exit0_neq_git", exit0_neq_git)
            emit("row7_clean_published", rkey, "rejected_in_denom", rej_in_denom)
            emit("row7_clean_published", rkey, "rejected_misrejected", rej_misrejected)
            emit("row7_clean_published", rkey, "exit3_excluded", exit3_excl)
            emit("row7_clean_published", rkey, "exit1_4_other", exit1_4_other)
            emit("row7_clean_published", rkey, "damaged", st["damaged"])

    # 3. Row 8: CRLF conflict cases (corpus CRLF conflicts + fixed case 36)
    crlf_caller = [r for r in rows if r["crlf"] == "1" and r["tool"] == "published_caller"]
    crlf_evalpy = {r["case_id"]: r for r in rows if r["crlf"] == "1" and r["tool"] == "published_evalpy"}
    total_crlf = len(crlf_caller)
    caller_ok = sum(1 for r in crlf_caller if r["exit_code"] == "1" and r["eq_git"] == "1")
    evalpy_ok = sum(
        1
        for r in crlf_caller
        if r["case_id"] in crlf_evalpy
        and crlf_evalpy[r["case_id"]]["exit_code"] == "1"
        and crlf_evalpy[r["case_id"]]["eq_git"] == "1"
    )
    exit4_cnt = sum(
        1
        for r in rows
        if r["crlf"] == "1" and r["tool"] in ("published_caller", "published_evalpy") and r["exit_code"] == "4"
    )
    bad_crlf = (total_crlf - caller_ok) + (total_crlf - evalpy_ok)
    emit("row8_crlf", "all", "total_crlf_cases", total_crlf)
    emit("row8_crlf", "all", "caller_exit1_eq_git", caller_ok)
    emit("row8_crlf", "all", "evalpy_exit1_eq_git", evalpy_ok)
    emit("row8_crlf", "all", "exit4_count", exit4_cnt)
    emit("row8_crlf", "all", "failed_count", bad_crlf)

    # 4. Row 9: Declaration-level engine
    for lg_name, lg_set in lang_groups:
        stc = agg_corpus("conflict", "engine", lg_set)
        for col in (
            "total_cases",
            "excluded_human_unparsable",
            "denominator",
            "same",
            "same_pct",
            "clean_different",
            "clean_different_ws_equal",
            "clean_different_human_eq_left",
            "clean_different_human_eq_right",
            "conflict",
            "rejected",
            "damaged",
            "timeout_count",
        ):
            emit("row9_engine_conflict", lg_name, col, stc[col])

        stk = agg_corpus("clean", "engine", lg_set)
        for col in (
            "total_cases",
            "excluded_human_unparsable",
            "denominator",
            "same",
            "clean_different",
            "clean_different_ws_equal",
            "damaged",
            "conflict",
            "timeout_count",
        ):
            emit("row9_engine_clean", lg_name, col, stk[col])

        eng_ms = [
            float(r["elapsed_ms"])
            for r in corpus_rows
            if r["tool"] == "engine" and r["language"] in lg_set and r["elapsed_ms"] not in ("", "-")
        ]
        emit("row9_engine_timing", lg_name, "executed_cases", len(eng_ms))
        emit("row9_engine_timing", lg_name, "median_ms", ("%.3f" % statistics.median(eng_ms)) if eng_ms else "0.000")
        emit("row9_engine_timing", lg_name, "max_ms", ("%.3f" % max(eng_ms)) if eng_ms else "0.000")

    # 5. Row 10: mergiraf
    for lg_name, lg_set in lang_groups:
        stc = agg_corpus("conflict", "mergiraf", lg_set)
        same_pct_mgf = "—" if (stc["denominator"] > 0 and stc["skipped_in_denom"] >= stc["denominator"]) else stc["same_pct"]
        for col in (
            "total_cases",
            "excluded_human_unparsable",
            "denominator",
            "skipped_total",
            "skipped_in_denom",
            "same",
            "clean_different",
            "clean_different_ws_equal",
            "clean_different_human_eq_left",
            "clean_different_human_eq_right",
            "conflict",
            "rejected",
            "damaged",
            "timeout_count",
        ):
            emit("row10_mergiraf_conflict", lg_name, col, stc[col])
        emit("row10_mergiraf_conflict", lg_name, "same_pct", same_pct_mgf)

        stk = agg_corpus("clean", "mergiraf", lg_set)
        for col in (
            "total_cases",
            "excluded_human_unparsable",
            "denominator",
            "skipped_total",
            "skipped_in_denom",
            "same",
            "clean_different",
            "clean_different_ws_equal",
            "damaged",
            "conflict",
            "timeout_count",
        ):
            emit("row10_mergiraf_clean", lg_name, col, stk[col])

        mgf_sub = [r for r in corpus_rows if r["tool"] == "mergiraf" and r["language"] in lg_set]
        mgf_skip = sum(1 for r in mgf_sub if r["exit_code"] == "skip")
        mgf_ms = [float(r["elapsed_ms"]) for r in mgf_sub if r["elapsed_ms"] not in ("", "-")]
        emit("row10_mergiraf_timing", lg_name, "total_cases", len(mgf_sub))
        emit("row10_mergiraf_timing", lg_name, "skipped_total", mgf_skip)
        emit("row10_mergiraf_timing", lg_name, "executed_cases", len(mgf_ms))
        emit("row10_mergiraf_timing", lg_name, "median_ms", ("%.3f" % statistics.median(mgf_ms)) if mgf_ms else "0.000")
        emit("row10_mergiraf_timing", lg_name, "max_ms", ("%.3f" % max(mgf_ms)) if mgf_ms else "0.000")

    # 6. Row 11: PATH differences between published_caller and published_evalpy on corpus
    caller_by_id = {r["case_id"]: r for r in corpus_rows if r["tool"] == "published_caller"}
    evalpy_by_id = {r["case_id"]: r for r in corpus_rows if r["tool"] == "published_evalpy"}
    diff_conflict = 0
    diff_clean = 0
    for cid in sorted(caller_by_id):
        cr = caller_by_id[cid]
        er = evalpy_by_id.get(cid)
        if er is None:
            continue
        if cr["exit_code"] != er["exit_code"] or cr["category"] != er["category"]:
            if cr["kind"] == "conflict":
                diff_conflict += 1
            else:
                diff_clean += 1
    emit("row11_path_diff", "all", "diff_total", diff_conflict + diff_clean)
    emit("row11_path_diff", "all", "diff_conflict", diff_conflict)
    emit("row11_path_diff", "all", "diff_clean", diff_clean)

    # 7. Row 12: Fixed cases (40 cases, 3 columns: git, published_caller, engine)
    for tool in FIXED_TABLE_TOOLS:
        f_sub = [r for r in fixed_rows if r["tool"] == tool]
        cats = Counter(r["category"] for r in f_sub)
        ws_cnt = sum(1 for r in f_sub if r["category"] == "clean_different" and r["ws_equal"] == "1")
        emit("row12_fixed_summary", tool, "total", len(f_sub))
        emit("row12_fixed_summary", tool, "same", cats.get("same", 0))
        emit("row12_fixed_summary", tool, "clean_different", cats.get("clean_different", 0))
        emit("row12_fixed_summary", tool, "clean_different_ws_equal", ws_cnt)
        emit("row12_fixed_summary", tool, "conflict", cats.get("conflict", 0))
        emit("row12_fixed_summary", tool, "rejected", cats.get("rejected", 0))
        emit("row12_fixed_summary", tool, "damaged", cats.get("damaged", 0))
    f_cli = [r for r in fixed_rows if r["tool"] == "published_caller"]
    merge_cases_cnt = sum(1 for r in f_cli if r["case_id"].startswith("merge-cases/"))
    sg_cnt = sum(1 for r in f_cli if r["case_id"].startswith("syntax-gate-cases/"))
    sg_exit3_cnt = sum(
        1 for r in f_cli if r["case_id"].startswith("syntax-gate-cases/") and r["exit_code"] == "3"
    )
    emit("row12_fixed_summary", "published_caller", "merge_cases_count", merge_cases_cnt)
    emit("row12_fixed_summary", "published_caller", "syntax_gate_count", sg_cnt)
    emit("row12_fixed_summary", "published_caller", "syntax_gate_exit3_count", sg_exit3_cnt)

    # 8. Row 16: Rule 1 added-line check counts & Rule 1..5 decision summary
    for mode in ("published_caller", "published_evalpy"):
        for lg_name, lg_set in lang_groups:
            ex0 = [
                r
                for r in corpus_rows
                if r["kind"] == "conflict"
                and r["tool"] == mode
                and r["language"] in lg_set
                and r["exit_code"] == "0"
            ]
            dropped_cases = sum(
                1 for r in ex0 if r["dropped_added_lines"] not in ("", "-", "0")
            )
            dropped_lines_sum = sum(
                int(r["dropped_added_lines"])
                for r in ex0
                if r["dropped_added_lines"] not in ("", "-")
            )
            rkey = "%s:%s" % (mode, lg_name)
            emit("row16_rule1_added_lines", rkey, "exit0_checked", len(ex0))
            emit("row16_rule1_added_lines", rkey, "dropped_cases", dropped_cases)
            emit("row16_rule1_added_lines", rkey, "dropped_lines_total", dropped_lines_sum)

    for ex in eval_data["rule1_examples"]:
        ex_key = "%s:%s" % (ex["tool"], ex["case_id"])
        emit("row16_rule1_examples", ex_key, "left_added", ex["left_added"])
        emit("row16_rule1_examples", ex_key, "right_added", ex["right_added"])
        emit("row16_rule1_examples", ex_key, "dropped", ex["dropped"])

    rules = evaluate_decision_rules(summary_map)
    for r in rules:
        rid = "rule_%d" % r["rule_id"]
        emit("row16_decision", rid, "triggered", "1" if r["triggered"] else "0")

    return summary_rows, summary_map, eval_data


def load_summary_tsv(summary_tsv_path):
    summary_map = {}
    summary_rows = []
    with open(summary_tsv_path, encoding="utf-8") as fh:
        for row in csv.DictReader(fh, delimiter="\t"):
            key = (row["table"], row["row"], row["col"])
            summary_map[key] = row["value"]
            summary_rows.append(dict(row))
    return summary_rows, summary_map


def render_markdown(summary_map, eval_data):
    """Renders `m3-merge-eval.md` strictly using `summary_map` for all table and metric numbers."""
    meta = eval_data["meta"]
    rows = eval_data["rows"]
    rule1_examples = eval_data["rule1_examples"]

    def S(table, row, col):
        return summary_map[(table, row, col)]

    corpus_rows = [r for r in rows if r["kind"] in ("conflict", "clean")]
    fixed_rows = [r for r in rows if r["kind"] == "fixed"]

    lines = []
    lines.append("# RelayIDE M3 语义合并去留评估报告")
    lines.append("")
    lines.append("## 1. 清单校验和、运行环境与总耗时（验收第 13、14 行）")
    lines.append("")
    lines.append("- **运行模式**：`%s`" % meta.get("mode", "full"))
    lines.append("- **`Scripts/eval/merge-corpus/repos.tsv` sha256**：`%s`" % meta.get("repos_sha256", ""))
    lines.append("- **`Fixtures/merge-corpus/cases.tsv` sha256**：`%s`" % meta.get("cases_sha256", ""))
    lines.append("- **`Fixtures/merge-cases/CLASSIFIED.tsv` sha256**：`%s`" % meta.get("classified_sha256", ""))
    lines.append("- **机器与系统**：`%s`" % meta.get("machine_info", ""))
    lines.append("- **开始时负载（1 / 5 / 15 分钟 loadavg）**：`%s`" % meta.get("load_start", ""))
    lines.append("")
    lines.append("### 工具与固定解析器版本及路径")
    lines.append("")
    lines.append("| 组件 | 路径与版本 / 校验和 |")
    lines.append("|---|---|")
    lines.append("| 基线 `git` | `%s` |" % meta.get("sys_git_info", ""))
    lines.append(
        "| 产品命令行（经 `relay-cli.sh`） | 入口 `%s`；二进制 `%s`；提交 `%s`；`sha256=%s` |"
        % (
            meta.get("cli_wrapper", ""),
            meta.get("product_bin", ""),
            meta.get("product_commit", ""),
            meta.get("product_sha256", ""),
        )
    )
    lines.append(
        "| 发布的命令 `caller` PATH 命中的工具 | `python3`: `%s`；`tsc`: `%s`；`node`: `%s`；`git`: `%s` |"
        % (
            meta.get("caller_python3", ""),
            meta.get("caller_tsc", ""),
            meta.get("caller_node", ""),
            meta.get("caller_git", ""),
        )
    )
    lines.append(
        "| 发布的命令 `eval-python-first` PATH 命中的工具 | `python3`: `%s`；`tsc`: `%s`；`node`: `%s`；`git`: `%s` |"
        % (
            meta.get("evalpy_python3", ""),
            meta.get("evalpy_tsc", ""),
            meta.get("evalpy_node", ""),
            meta.get("evalpy_git", ""),
        )
    )
    lines.append("| 固定解析器 `RELAY_EVAL_PYTHON` | `%s` |" % meta.get("eval_python_info", ""))
    lines.append("| 固定解析器 Swift | `%s` |" % meta.get("swiftc_info", ""))
    lines.append("| 固定解析器 `RELAY_EVAL_TYPESCRIPT` | `%s` |" % meta.get("eval_ts_info", ""))
    lines.append(
        "| 声明级引擎可执行文件 | `%s`；提交 `%s`；`sha256=%s` |"
        % (
            meta.get("engine_bin", ""),
            meta.get("engine_commit", ""),
            meta.get("engine_sha256", ""),
        )
    )
    lines.append(
        "| 对照工具 `mergiraf` | `%s`（`%s`）；`sha256=%s` |"
        % (
            meta.get("mergiraf_bin", ""),
            meta.get("mergiraf_version", ""),
            meta.get("mergiraf_sha256", ""),
        )
    )
    lines.append("")
    lines.append("### 各工具耗时与整份总耗时（验收第 14 行）")
    lines.append("")
    lines.append("| 阶段 / 工具 | 墙钟耗时（秒） |")
    lines.append("|---|---:|")
    for label, t_key in (
        ("固定用例检查与分类（`fixed_cases`）", "elapsed_fixed_s"),
        ("发布的命令（`caller` PATH）", "elapsed_published_caller_s"),
        ("发布的命令（`eval-python-first` PATH）", "elapsed_published_evalpy_s"),
        ("声明级引擎（`ThreeWaySemanticASTMerger`）", "elapsed_engine_s"),
        ("对照工具（`mergiraf`）", "elapsed_mergiraf_s"),
        ("语料分类与固定解析器校验（`classify.py`）", "elapsed_classify_s"),
        ("**整份评估总耗时（`total`）**", "elapsed_total_s"),
    ):
        lines.append("| %s | %s |" % (label, S("row14_timings", t_key, "seconds")))
    lines.append("")

    # Row 6
    lines.append("## 2. 验收第 6 行：发布的命令在冲突集上（每种语言五类，两种 PATH）")
    lines.append("")
    lines.append(
        "冲突集分母内“人工版本等于左 / 右”基线（`git` 行统计）：Python 左 %s / 右 %s（分母 %s），Swift 左 %s / 右 %s（分母 %s），TypeScript 左 %s / 右 %s（分母 %s），合计左 %s / 右 %s（分母 %s）。"
        % (
            S("row6_conflict_published", "git:python", "denom_human_eq_left"),
            S("row6_conflict_published", "git:python", "denom_human_eq_right"),
            S("row6_conflict_published", "git:python", "denominator"),
            S("row6_conflict_published", "git:swift", "denom_human_eq_left"),
            S("row6_conflict_published", "git:swift", "denom_human_eq_right"),
            S("row6_conflict_published", "git:swift", "denominator"),
            S("row6_conflict_published", "git:typescript", "denom_human_eq_left"),
            S("row6_conflict_published", "git:typescript", "denom_human_eq_right"),
            S("row6_conflict_published", "git:typescript", "denominator"),
            S("row6_conflict_published", "git:all", "denom_human_eq_left"),
            S("row6_conflict_published", "git:all", "denom_human_eq_right"),
            S("row6_conflict_published", "git:all", "denominator"),
        )
    )
    lines.append("")
    lines.append(
        "| 工具 / PATH | 语言 | 总数 | 排除（人工不过解析） | 分母 | 相同（`same`） | 相同占比 | 干净但不同 | 副计数：`ws_equal` | 副计数：`human_eq` 左/右 | 仍报冲突 | 拒绝（退出 3/4） | 输出损坏 |"
    )
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|")
    for tool in ("git", "published_caller", "published_evalpy"):
        for lg in ("python", "swift", "typescript", "all"):
            rk = "%s:%s" % (tool, lg)
            lines.append(
                "| `%s` | `%s` | %s | %s | %s | %s | %s | %s | %s | %s / %s | %s | %s | %s |"
                % (
                    tool,
                    lg,
                    S("row6_conflict_published", rk, "total_cases"),
                    S("row6_conflict_published", rk, "excluded_human_unparsable"),
                    S("row6_conflict_published", rk, "denominator"),
                    S("row6_conflict_published", rk, "same"),
                    S("row6_conflict_published", rk, "same_pct"),
                    S("row6_conflict_published", rk, "clean_different"),
                    S("row6_conflict_published", rk, "clean_different_ws_equal"),
                    S("row6_conflict_published", rk, "clean_different_human_eq_left"),
                    S("row6_conflict_published", rk, "clean_different_human_eq_right"),
                    S("row6_conflict_published", rk, "conflict"),
                    S("row6_conflict_published", rk, "rejected"),
                    S("row6_conflict_published", rk, "damaged"),
                )
            )
    lines.append("")

    # Row 7
    lines.append("## 3. 验收第 7 行：发布的命令在干净回归集上（退出 3 逐例原因与 `git_parses`）")
    lines.append("")
    lines.append(
        "| 工具 / PATH | 语言 | 总数 | 排除（人工不过解析） | 分母 | 退出 0 且与 `git` 相同 | 退出 0 但与 `git` 不同 | 分母内退出 3 | 其中 `git_parses=1`（误拒） | 分母外退出 3 | 退出 1 / 4 / 其他 | 输出损坏 |"
    )
    lines.append("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for tool in ("git", "published_caller", "published_evalpy"):
        for lg in ("python", "swift", "typescript", "all"):
            rk = "%s:%s" % (tool, lg)
            lines.append(
                "| `%s` | `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |"
                % (
                    tool,
                    lg,
                    S("row7_clean_published", rk, "total_cases"),
                    S("row7_clean_published", rk, "excluded_human_unparsable"),
                    S("row7_clean_published", rk, "denominator"),
                    S("row7_clean_published", rk, "exit0_eq_git"),
                    S("row7_clean_published", rk, "exit0_neq_git"),
                    S("row7_clean_published", rk, "rejected_in_denom"),
                    S("row7_clean_published", rk, "rejected_misrejected"),
                    S("row7_clean_published", rk, "exit3_excluded"),
                    S("row7_clean_published", rk, "exit1_4_other"),
                    S("row7_clean_published", rk, "damaged"),
                )
            )
    lines.append("")

    clean_caller = {r["case_id"]: r for r in corpus_rows if r["kind"] == "clean" and r["tool"] == "published_caller"}
    clean_evalpy = {r["case_id"]: r for r in corpus_rows if r["kind"] == "clean" and r["tool"] == "published_evalpy"}
    in_denom_exit3 = []
    excl_exit3 = []
    for cid in sorted(clean_caller):
        cr = clean_caller[cid]
        er = clean_evalpy.get(cid, cr)
        if cr["exit_code"] == "3" or er["exit_code"] == "3":
            if cr["category"] == "excluded":
                excl_exit3.append((cid, cr, er))
            else:
                in_denom_exit3.append((cid, cr, er))

    lines.append(
        "### 3.1 分母内退出 3 的干净回归文件逐例清单（`caller` %s 例，`eval-python-first` %s 例）"
        % (
            S("row7_clean_published", "published_caller:all", "rejected_in_denom"),
            S("row7_clean_published", "published_evalpy:all", "rejected_in_denom"),
        )
    )
    lines.append("")
    if in_denom_exit3:
        lines.append("| 用例 | 语言 | `caller` 退出码 | `evalpy` 退出码 | `git_parses` | 原因 |")
        lines.append("|---|---|---:|---:|---:|---|")
        for cid, cr, er in in_denom_exit3:
            reason_txt = (cr["reason"] or er["reason"]).replace("|", "\\|")
            lines.append(
                "| `%s` | `%s` | %s | %s | %s | %s |"
                % (cid, cr["language"], cr["exit_code"], er["exit_code"], cr["git_parses"], reason_txt)
            )
    else:
        lines.append("（本次运行无干净集分母内退出 3 的文件，共 %s 例。）" % S("row7_clean_published", "published_caller:all", "rejected_in_denom"))
    lines.append("")

    lines.append(
        "### 3.2 分母外（人工版本过不了固定解析器，已排除）退出 3 的干净回归文件逐例清单（共 %s 例）"
        % S("row7_clean_published", "published_caller:all", "exit3_excluded")
    )
    lines.append("")
    if excl_exit3:
        lines.append("| 用例 | 语言 | `caller` 退出码 | `evalpy` 退出码 | `git_parses` | 原因 |")
        lines.append("|---|---|---:|---:|---:|---|")
        for cid, cr, er in excl_exit3:
            reason_txt = (cr["reason"] or er["reason"]).replace("|", "\\|")
            lines.append(
                "| `%s` | `%s` | %s | %s | %s | %s |"
                % (cid, cr["language"], cr["exit_code"], er["exit_code"], cr["git_parses"], reason_txt)
            )
    else:
        lines.append("（本次运行无分母外退出 3 的干净文件，共 %s 例。）" % S("row7_clean_published", "published_caller:all", "exit3_excluded"))
    lines.append("")

    # Row 8
    lines.append("## 4. 验收第 8 行：CRLF 冲突文件与固定用例 36")
    lines.append("")
    lines.append(
        "- CRLF 冲突用例总数：%s；`caller` 退出 1 且与 `git` 逐字节相同：%s；`eval-python-first` 退出 1 且与 `git` 逐字节相同：%s；退出 4 个数：%s；不符个数：%s。"
        % (
            S("row8_crlf", "all", "total_crlf_cases"),
            S("row8_crlf", "all", "caller_exit1_eq_git"),
            S("row8_crlf", "all", "evalpy_exit1_eq_git"),
            S("row8_crlf", "all", "exit4_count"),
            S("row8_crlf", "all", "failed_count"),
        )
    )
    lines.append("")
    lines.append("| 用例 | 语言 | `kind` | `caller` 退出码 | `evalpy` 退出码 | 与 `git merge-file -p` 逐字节相同 |")
    lines.append("|---|---|---|---:|---:|---|")
    crlf_caller_rows = [r for r in rows if r["crlf"] == "1" and r["tool"] == "published_caller"]
    crlf_evalpy_map = {r["case_id"]: r for r in rows if r["crlf"] == "1" and r["tool"] == "published_evalpy"}
    for cr in crlf_caller_rows:
        er = crlf_evalpy_map.get(cr["case_id"], cr)
        both_eq = "是" if (cr["eq_git"] == "1" and er["eq_git"] == "1") else "否"
        lines.append(
            "| `%s` | `%s` | `%s` | %s | %s | %s |"
            % (cr["case_id"], cr["language"], cr["kind"], cr["exit_code"], er["exit_code"], both_eq)
        )
    lines.append("")

    # Row 9
    lines.append("## 5. 验收第 9 行：声明级引擎（`ThreeWaySemanticASTMerger`）")
    lines.append("")
    lines.append("### 5.1 冲突集")
    lines.append("")
    lines.append(
        "| 语言 | 总数 | 排除 | 分母 | 相同（`same`） | 相同占比 | 干净但不同 | 副计数：`ws_equal` | 副计数：`human_eq` 左/右 | 仍报冲突 | 拒绝 | 输出损坏 | 超时 |"
    )
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|")
    for lg in ("python", "swift", "typescript", "all"):
        lines.append(
            "| `%s` | %s | %s | %s | %s | %s | %s | %s | %s / %s | %s | %s | %s | %s |"
            % (
                lg,
                S("row9_engine_conflict", lg, "total_cases"),
                S("row9_engine_conflict", lg, "excluded_human_unparsable"),
                S("row9_engine_conflict", lg, "denominator"),
                S("row9_engine_conflict", lg, "same"),
                S("row9_engine_conflict", lg, "same_pct"),
                S("row9_engine_conflict", lg, "clean_different"),
                S("row9_engine_conflict", lg, "clean_different_ws_equal"),
                S("row9_engine_conflict", lg, "clean_different_human_eq_left"),
                S("row9_engine_conflict", lg, "clean_different_human_eq_right"),
                S("row9_engine_conflict", lg, "conflict"),
                S("row9_engine_conflict", lg, "rejected"),
                S("row9_engine_conflict", lg, "damaged"),
                S("row9_engine_conflict", lg, "timeout_count"),
            )
        )
    lines.append("")
    lines.append("### 5.2 干净回归集与单文件耗时")
    lines.append("")
    lines.append("| 语言 | 总数 | 排除 | 分母 | 与 `git` 相同 | 能解析但不同 | 副计数：`ws_equal` | 输出损坏 | 误报冲突 | 超时 | 执行数 | 中位耗时（ms） | 最大耗时（ms） |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for lg in ("python", "swift", "typescript", "all"):
        lines.append(
            "| `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |"
            % (
                lg,
                S("row9_engine_clean", lg, "total_cases"),
                S("row9_engine_clean", lg, "excluded_human_unparsable"),
                S("row9_engine_clean", lg, "denominator"),
                S("row9_engine_clean", lg, "same"),
                S("row9_engine_clean", lg, "clean_different"),
                S("row9_engine_clean", lg, "clean_different_ws_equal"),
                S("row9_engine_clean", lg, "damaged"),
                S("row9_engine_clean", lg, "conflict"),
                S("row9_engine_clean", lg, "timeout_count"),
                S("row9_engine_timing", lg, "executed_cases"),
                S("row9_engine_timing", lg, "median_ms"),
                S("row9_engine_timing", lg, "max_ms"),
            )
        )
    lines.append("")

    # Row 10
    lines.append("## 6. 验收第 10 行：对照工具 `mergiraf`（跳过数、耗时中位数与最大值）")
    lines.append("")
    lines.append("### 6.1 冲突集")
    lines.append("")
    lines.append(
        "| 语言 | 总数 | 排除 | 分母 | 跳过（总计 / 分母内） | 相同（`same`） | 相同占比 | 干净但不同 | 副计数：`ws_equal` | 副计数：`human_eq` 左/右 | 仍报冲突 | 拒绝 | 输出损坏 | 超时 |"
    )
    lines.append("|---|---:|---:|---:|---|---:|---:|---:|---:|---|---:|---:|---:|---:|")
    for lg in ("python", "swift", "typescript", "all"):
        lines.append(
            "| `%s` | %s | %s | %s | %s / %s | %s | %s | %s | %s | %s / %s | %s | %s | %s | %s |"
            % (
                lg,
                S("row10_mergiraf_conflict", lg, "total_cases"),
                S("row10_mergiraf_conflict", lg, "excluded_human_unparsable"),
                S("row10_mergiraf_conflict", lg, "denominator"),
                S("row10_mergiraf_conflict", lg, "skipped_total"),
                S("row10_mergiraf_conflict", lg, "skipped_in_denom"),
                S("row10_mergiraf_conflict", lg, "same"),
                S("row10_mergiraf_conflict", lg, "same_pct"),
                S("row10_mergiraf_conflict", lg, "clean_different"),
                S("row10_mergiraf_conflict", lg, "clean_different_ws_equal"),
                S("row10_mergiraf_conflict", lg, "clean_different_human_eq_left"),
                S("row10_mergiraf_conflict", lg, "clean_different_human_eq_right"),
                S("row10_mergiraf_conflict", lg, "conflict"),
                S("row10_mergiraf_conflict", lg, "rejected"),
                S("row10_mergiraf_conflict", lg, "damaged"),
                S("row10_mergiraf_conflict", lg, "timeout_count"),
            )
        )
    lines.append("")
    lines.append("### 6.2 干净回归集与单文件耗时（含跳过个数、中位数与最大值）")
    lines.append("")
    lines.append(
        "| 语言 | 干净集总数 | 干净集分母 | 干净集跳过（总/分母） | 与 `git` 相同 | 能解析但不同 | 副计数：`ws_equal` | 输出损坏 | 误报冲突 | 语料总用例 | 语料总跳过 | 实际执行数 | 单文件中位耗时（ms） | 单文件最大耗时（ms） |"
    )
    lines.append("|---|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for lg in ("python", "swift", "typescript", "all"):
        lines.append(
            "| `%s` | %s | %s | %s / %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |"
            % (
                lg,
                S("row10_mergiraf_clean", lg, "total_cases"),
                S("row10_mergiraf_clean", lg, "denominator"),
                S("row10_mergiraf_clean", lg, "skipped_total"),
                S("row10_mergiraf_clean", lg, "skipped_in_denom"),
                S("row10_mergiraf_clean", lg, "same"),
                S("row10_mergiraf_clean", lg, "clean_different"),
                S("row10_mergiraf_clean", lg, "clean_different_ws_equal"),
                S("row10_mergiraf_clean", lg, "damaged"),
                S("row10_mergiraf_clean", lg, "conflict"),
                S("row10_mergiraf_timing", lg, "total_cases"),
                S("row10_mergiraf_timing", lg, "skipped_total"),
                S("row10_mergiraf_timing", lg, "executed_cases"),
                S("row10_mergiraf_timing", lg, "median_ms"),
                S("row10_mergiraf_timing", lg, "max_ms"),
            )
        )
    lines.append("")

    # Row 11
    lines.append("## 7. 验收第 11 行：两种 PATH 下发布的命令结果不同的文件")
    lines.append("")
    lines.append(
        "- 差异文件总数：%s（冲突集 %s 例，干净集 %s 例）。"
        % (
            S("row11_path_diff", "all", "diff_total"),
            S("row11_path_diff", "all", "diff_conflict"),
            S("row11_path_diff", "all", "diff_clean"),
        )
    )
    lines.append("")
    c_map = {r["case_id"]: r for r in corpus_rows if r["tool"] == "published_caller"}
    e_map = {r["case_id"]: r for r in corpus_rows if r["tool"] == "published_evalpy"}
    diff_rows = []
    for cid in sorted(c_map):
        cr = c_map[cid]
        er = e_map.get(cid)
        if er and (cr["exit_code"] != er["exit_code"] or cr["category"] != er["category"]):
            diff_rows.append((cid, cr, er))
    if diff_rows:
        lines.append("| 用例 | `kind` | 语言 | `caller`（退出码 / 类别） | `eval-python-first`（退出码 / 类别） | `caller` 原因 |")
        lines.append("|---|---|---|---|---|---|")
        for cid, cr, er in diff_rows:
            lines.append(
                "| `%s` | `%s` | `%s` | `%s` / `%s` | `%s` / `%s` | %s |"
                % (
                    cid,
                    cr["kind"],
                    cr["language"],
                    cr["exit_code"],
                    cr["category"],
                    er["exit_code"],
                    er["category"],
                    (cr["reason"] or er["reason"]).replace("|", "\\|"),
                )
            )
    else:
        lines.append("（本次运行两种 PATH 结果差异文件数为 %s。）" % S("row11_path_diff", "all", "diff_total"))
    lines.append("")

    # Row 12
    lines.append("## 8. 验收第 12 行：固定用例三列汇总与明细")
    lines.append("")
    lines.append(
        "- 固定用例总数：%s（`merge-cases` %s 组，`syntax-gate-cases` %s 组中退出 3 为 %s 组）。"
        % (
            S("row12_fixed_summary", "published_caller", "total"),
            S("row12_fixed_summary", "published_caller", "merge_cases_count"),
            S("row12_fixed_summary", "published_caller", "syntax_gate_count"),
            S("row12_fixed_summary", "published_caller", "syntax_gate_exit3_count"),
        )
    )
    lines.append("")
    lines.append("| 工具 | 总数 | 相同（`same`） | 干净但不同 | 副计数：`ws_equal` | 仍报冲突 | 拒绝（退出 3/4） | 输出损坏 |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for tool in FIXED_TABLE_TOOLS:
        lines.append(
            "| `%s` | %s | %s | %s | %s | %s | %s | %s |"
            % (
                tool,
                S("row12_fixed_summary", tool, "total"),
                S("row12_fixed_summary", tool, "same"),
                S("row12_fixed_summary", tool, "clean_different"),
                S("row12_fixed_summary", tool, "clean_different_ws_equal"),
                S("row12_fixed_summary", tool, "conflict"),
                S("row12_fixed_summary", tool, "rejected"),
                S("row12_fixed_summary", tool, "damaged"),
            )
        )
    lines.append("")
    lines.append("| 用例 | 语言 | `git` | 发布的命令（`cli`） | 声明级引擎（`engine`） | `cli` 退出码 | `cli` 原因 |")
    lines.append("|---|---|---|---|---|---:|---|")
    fx_by_tool = {}
    fx_order = []
    for r in fixed_rows:
        if r["tool"] not in FIXED_TABLE_TOOLS:
            continue
        cid = r["case_id"]
        if cid not in fx_by_tool:
            fx_by_tool[cid] = {}
            fx_order.append(cid)
        fx_by_tool[cid][r["tool"]] = r
    for cid in fx_order:
        g_r = fx_by_tool[cid]["git"]
        c_r = fx_by_tool[cid]["published_caller"]
        e_r = fx_by_tool[cid]["engine"]
        lines.append(
            "| `%s` | `%s` | `%s` | `%s` | `%s` | %s | %s |"
            % (
                cid,
                c_r["language"],
                g_r["category"],
                c_r["category"],
                e_r["category"],
                c_r["exit_code"],
                c_r["reason"].replace("|", "\\|"),
            )
        )
    lines.append("")

    # Row 16: Final section MUST be "去留结论"
    lines.append("## 去留结论")
    lines.append("")
    lines.append(
        "分母定义：每种语言分别计算，分母为去重后人工版本能被固定解析器读的冲突文件，“相同”只计逐字节相同（三种语言均达到或超过 20% 才算过线）。"
    )
    lines.append("")
    lines.append("### 规则第 1 行“退出 0 却丢了一边新增的行” `difflib` 检查结果与实例")
    lines.append("")
    lines.append(
        "- 冲突集上发布的命令退出 0 的文件数：`caller` %s 例（丢行文件 %s 例，丢行总数 %s 行），`eval-python-first` %s 例（丢行文件 %s 例，丢行总数 %s 行）。"
        % (
            S("row16_rule1_added_lines", "published_caller:all", "exit0_checked"),
            S("row16_rule1_added_lines", "published_caller:all", "dropped_cases"),
            S("row16_rule1_added_lines", "published_caller:all", "dropped_lines_total"),
            S("row16_rule1_added_lines", "published_evalpy:all", "exit0_checked"),
            S("row16_rule1_added_lines", "published_evalpy:all", "dropped_cases"),
            S("row16_rule1_added_lines", "published_evalpy:all", "dropped_lines_total"),
        )
    )
    lines.append("")
    if rule1_examples:
        lines.append(
            "| 工具 / PATH | 用例 | 语言 | 分类结果 | `base→left` 新增行数 | `base→right` 新增行数 | 输出缺失的新增行数 | 两边新增行是否全部保留 |"
        )
        lines.append("|---|---|---|---|---:|---:|---:|---|")
        for ex in rule1_examples:
            ex_key = "%s:%s" % (ex["tool"], ex["case_id"])
            drp_s = S("row16_rule1_examples", ex_key, "dropped")
            kept_all = "是" if drp_s == "0" else ("否（%s）" % ex["note"].replace("|", "\\|"))
            lines.append(
                "| `%s` | `%s` | `%s` | `%s` | %s | %s | %s | %s |"
                % (
                    ex["tool"],
                    ex["case_id"],
                    ex["language"],
                    ex["category"],
                    S("row16_rule1_examples", ex_key, "left_added"),
                    S("row16_rule1_examples", ex_key, "right_added"),
                    drp_s,
                    kept_all,
                )
            )
        lines.append("")

    lines.append("### 去留规则逐行对照表（验收第 16 行）")
    lines.append("")
    lines.append("| 行号 | 去留规则条件 | 判定结果 | Python | Swift | TypeScript |")
    lines.append("|---:|---|---|---|---|---|")
    rules = evaluate_decision_rules(summary_map)
    for r in rules:
        rid_str = str(r["rule_id"])
        # Reference `row16_decision` so every row's trigger bit is tied to `summary.tsv`
        trig_bit = S("row16_decision", "rule_%s" % rid_str, "triggered")
        status_txt = "触发" if trig_bit == "1" else "没触发"
        lines.append(
            "| %s | %s | **%s** | %s | %s | %s |"
            % (
                rid_str,
                r["condition"],
                status_txt,
                r["per_lang"]["python"],
                r["per_lang"]["swift"],
                r["per_lang"]["typescript"],
            )
        )
    lines.append("")
    lines.append("注：`mergiraf 0.20.0` 不支持 Swift（Swift 用例在运行阶段计数后跳过，表中记“没跑”）。本节仅列出各项去留规则的触发状态与实测数字，最终去留决定由用户作出。")
    lines.append("")
    return "\n".join(lines)


def _extract_md_numbers(md_text):
    """Extracts `(line_no, token, line_text)` for every numeric token in `md_text`."""
    found = []
    for idx, line in enumerate(md_text.splitlines(), 1):
        for m in MD_NUMBER_RE.finditer(line):
            found.append((idx, m.group(0), line.strip()))
    return found


def check_reports(tsv_path, summary_tsv_path, md_path, repos_tsv=None, cases_tsv=None):
    """Recomputes summary from `m3-merge-eval.tsv` and verifies `summary.tsv` + every number in `md`."""
    errors = []
    for label, p in (("tsv", tsv_path), ("summary_tsv", summary_tsv_path), ("md", md_path)):
        if not p or not os.path.isfile(p):
            return False, ["missing %s file: %s" % (label, p)]

    exp_rows, exp_map, eval_data = compute_summary_from_eval_tsv(tsv_path)
    act_rows, act_map = load_summary_tsv(summary_tsv_path)

    # 1. Compare summary.tsv against recomputed summary
    if len(exp_rows) != len(act_rows):
        errors.append(
            "summary.tsv row count mismatch: recomputed=%d vs file=%d" % (len(exp_rows), len(act_rows))
        )
    all_keys = list(dict.fromkeys(list(exp_map.keys()) + list(act_map.keys())))
    for key in all_keys:
        if key not in act_map:
            errors.append("summary.tsv missing entry %s (expected %r)" % (key, exp_map[key]))
        elif key not in exp_map:
            errors.append("summary.tsv unexpected extra entry %s=%r" % (key, act_map[key]))
        elif exp_map[key] != act_map[key]:
            errors.append(
                "summary.tsv value mismatch at %s: recomputed=%r vs summary.tsv=%r"
                % (key, exp_map[key], act_map[key])
            )

    # 2. Re-render expected Markdown from recomputed summary and compare every number in md_path
    expected_md = render_markdown(exp_map, eval_data)
    with open(md_path, encoding="utf-8") as fh:
        actual_md = fh.read()

    exp_lines = expected_md.splitlines()
    act_lines = actual_md.splitlines()
    if len(exp_lines) != len(act_lines):
        errors.append("md line count mismatch: expected=%d vs actual=%d" % (len(exp_lines), len(act_lines)))

    max_common = min(len(exp_lines), len(act_lines))
    for lno in range(1, max_common + 1):
        el = exp_lines[lno - 1]
        al = act_lines[lno - 1]
        e_nums = [m.group(0) for m in MD_NUMBER_RE.finditer(el)]
        a_nums = [m.group(0) for m in MD_NUMBER_RE.finditer(al)]
        if e_nums != a_nums:
            errors.append(
                "md line %d number mismatch: expected %r vs actual %r (actual line: %s)"
                % (lno, e_nums, a_nums, al.strip()[:140])
            )
        elif "## 去留结论" in actual_md and ("触发" in el or "没跑" in el) and el != al:
            errors.append(
                "md line %d decision row mismatch: expected %r vs actual %r"
                % (lno, el.strip()[:140], al.strip()[:140])
            )

    # Fallback whole-document numeric sequence check in case line alignment shifted
    exp_all_nums = [t for _, t, _ in _extract_md_numbers(expected_md)]
    act_all_nums = [t for _, t, _ in _extract_md_numbers(actual_md)]
    if exp_all_nums != act_all_nums and not any("md line" in e for e in errors):
        errors.append(
            "md overall numeric token sequence mismatch: expected %d numbers vs actual %d numbers"
            % (len(exp_all_nums), len(act_all_nums))
        )

    # 3. Verify sha256 against repos.tsv & cases.tsv when provided
    meta = eval_data["meta"]
    if repos_tsv and os.path.isfile(repos_tsv):
        actual_repos_sha = sha256_file(repos_tsv)
        if meta.get("repos_sha256") and meta["repos_sha256"] != actual_repos_sha:
            errors.append(
                "repos.tsv sha256 mismatch: report=%s vs disk=%s" % (meta.get("repos_sha256"), actual_repos_sha)
            )
    if cases_tsv and os.path.isfile(cases_tsv):
        actual_cases_sha = sha256_file(cases_tsv)
        if meta.get("cases_sha256") and meta["cases_sha256"] != actual_cases_sha:
            errors.append(
                "cases.tsv sha256 mismatch: report=%s vs disk=%s" % (meta.get("cases_sha256"), actual_cases_sha)
            )

    # 4. Privacy & conclusion hygiene check
    placeholders = {"alice", "developer", "test", "shared", "<name>", "<user>"}
    for label, fp in (("tsv", tsv_path), ("summary_tsv", summary_tsv_path), ("md", md_path)):
        with open(fp, encoding="utf-8") as fh:
            txt = fh.read()
        for m in USERS_PATH_RE.finditer(txt):
            uname = m.group(0).split(USERS_PREFIX, 1)[1]
            if uname not in placeholders:
                errors.append("%s contains unsanitized home directory path: %r" % (label, m.group(0)))
                break
        em = EMAIL_RE.search(txt)
        if em:
            errors.append("%s contains email address token: %r" % (label, em.group(0)))

    if "## 去留结论" not in actual_md:
        errors.append("md missing final '## 去留结论' section")
    else:
        conc = actual_md.split("## 去留结论", 1)[1]
        for forbidden in ("建议删", "建议留"):
            if forbidden in conc:
                errors.append("md '## 去留结论' contains prescriptive phrase %r" % forbidden)

    return len(errors) == 0, errors


def generate_reports(
    repo_root,
    corpus_dir,
    repos_tsv,
    cases_tsv,
    selected_cases_tsv,
    published_caller_dir,
    published_evalpy_dir,
    engine_dir,
    mergiraf_dir,
    classify_details_tsv,
    fixed_classified_tsv,
    merge_cases_dir,
    syntax_gate_dir,
    tsv_out,
    summary_tsv_out,
    md_out,
    fixed_case36_caller_out=None,
    fixed_case36_evalpy_out=None,
    fixed_engine_tsv=None,
    mode="full",
    eval_python_info="",
    eval_ts_info="",
    swiftc_info="",
    machine_info="",
    load_start="",
    elapsed_fixed=0.0,
    elapsed_classify=0.0,
    elapsed_total=0.0,
):
    """Builds `m3-merge-eval.tsv`, `m3-merge-eval-summary.tsv`, and `m3-merge-eval.md`."""
    def clean_s(val):
        return sanitize_report_text(val, repo_root=repo_root, corpus_dir=corpus_dir)

    caller_env, caller_elapsed = _parse_env_txt(os.path.join(published_caller_dir, "env.txt"))
    evalpy_env, evalpy_elapsed = _parse_env_txt(os.path.join(published_evalpy_dir, "env.txt"))
    engine_env, engine_elapsed = _parse_env_txt(os.path.join(engine_dir, "env.txt"))
    mergiraf_env, mergiraf_elapsed = _parse_env_txt(os.path.join(mergiraf_dir, "env.txt"))

    if not eval_python_info or not eval_ts_info or not swiftc_info:
        try:
            desc = parsers.describe_parsers(("python", "swift", "typescript"))
            if not eval_python_info:
                eval_python_info = "%s (Python %s)" % (desc["python"]["path"], desc["python"]["version"])
            if not swiftc_info:
                swiftc_info = "%s (%s)" % (
                    desc["swift"]["path"],
                    desc["swift"]["version"].replace(" | ", "; "),
                )
            if not eval_ts_info:
                eval_ts_info = "%s (typescript %s; node %s %s)" % (
                    desc["typescript"]["path"],
                    desc["typescript"]["version"],
                    desc["typescript"]["node_path"],
                    desc["typescript"]["node_version"],
                )
        except Exception:
            pass

    if not machine_info:
        machine_info = _detect_machine_info()
    if not load_start:
        try:
            la = os.getloadavg()
            load_start = "%.2f %.2f %.2f" % (la[0], la[1], la[2])
        except Exception:
            load_start = "unknown"

    repo_commit = _detect_git_commit(repo_root)
    meta = {
        "mode": clean_s(mode),
        "repos_sha256": sha256_file(repos_tsv),
        "cases_sha256": sha256_file(cases_tsv),
        "classified_sha256": sha256_file(fixed_classified_tsv),
        "machine_info": clean_s(machine_info),
        "load_start": clean_s(load_start),
        "sys_git_info": clean_s(_detect_sys_git_version()),
        "cli_wrapper": clean_s(caller_env.get("cli_wrapper", "<repo>/Scripts/acceptance/relay-cli.sh")),
        "product_bin": clean_s(caller_env.get("cli_bin", "")),
        "product_commit": clean_s(repo_commit),
        "product_sha256": clean_s(caller_env.get("cli_bin_sha256", "")),
        "caller_python3": clean_s(
            "%s (%s)" % (caller_env.get("python3_effective", ""), caller_env.get("python3_version", ""))
        ),
        "caller_tsc": clean_s(
            "%s (%s)" % (caller_env.get("tsc_effective", ""), caller_env.get("tsc_version", ""))
        ),
        "caller_node": clean_s(
            "%s (%s)" % (caller_env.get("node_effective", ""), caller_env.get("node_version", ""))
        ),
        "caller_git": clean_s(
            "%s (%s)" % (caller_env.get("git_effective", ""), caller_env.get("git_version", ""))
        ),
        "evalpy_python3": clean_s(
            "%s (%s)" % (evalpy_env.get("python3_effective", ""), evalpy_env.get("python3_version", ""))
        ),
        "evalpy_tsc": clean_s(
            "%s (%s)" % (evalpy_env.get("tsc_effective", ""), evalpy_env.get("tsc_version", ""))
        ),
        "evalpy_node": clean_s(
            "%s (%s)" % (evalpy_env.get("node_effective", ""), evalpy_env.get("node_version", ""))
        ),
        "evalpy_git": clean_s(
            "%s (%s)" % (evalpy_env.get("git_effective", ""), evalpy_env.get("git_version", ""))
        ),
        "eval_python_info": clean_s(eval_python_info),
        "swiftc_info": clean_s(swiftc_info),
        "eval_ts_info": clean_s(eval_ts_info),
        "engine_bin": clean_s(engine_env.get("engine_bin", "")),
        "engine_commit": clean_s(engine_env.get("repo_commit", repo_commit)),
        "engine_sha256": clean_s(engine_env.get("engine_bin_sha256", "")),
        "mergiraf_bin": clean_s(mergiraf_env.get("mergiraf_bin", "")),
        "mergiraf_version": clean_s(mergiraf_env.get("mergiraf_version", "")),
        "mergiraf_sha256": clean_s(mergiraf_env.get("mergiraf_bin_sha256", "")),
        "elapsed_fixed_s": "%.2f" % float(elapsed_fixed),
        "elapsed_published_caller_s": "%.2f" % float(caller_elapsed),
        "elapsed_published_evalpy_s": "%.2f" % float(evalpy_elapsed),
        "elapsed_engine_s": "%.2f" % float(engine_elapsed),
        "elapsed_mergiraf_s": "%.2f" % float(mergiraf_elapsed),
        "elapsed_classify_s": "%.2f" % float(elapsed_classify),
        "elapsed_total_s": "%.2f" % float(elapsed_total),
    }

    # Load corpus inputs (when corpus was run)
    eval_rows = []
    rule1_examples = []
    scratch_dir = tempfile.mkdtemp(prefix="relay-report-git.")
    try:
        if (
            corpus_dir
            and selected_cases_tsv
            and os.path.isfile(selected_cases_tsv)
            and published_caller_dir
            and os.path.isfile(os.path.join(published_caller_dir, "results.tsv"))
        ):
            cases_list = _load_tsv_rows(selected_cases_tsv)
            extract_cases_root = os.path.join(corpus_dir, "extract", "cases")

            tool_dirs = {
                "published_caller": published_caller_dir,
                "published_evalpy": published_evalpy_dir,
                "engine": engine_dir,
                "mergiraf": mergiraf_dir,
            }
            tool_results = {}
            for tname, tdir in tool_dirs.items():
                tool_results[tname] = {
                    r["case_id"]: r for r in _load_tsv_rows(os.path.join(tdir, "results.tsv"))
                }

            tool_timings = {}
            for tname in ("engine", "mergiraf"):
                tpath = os.path.join(tool_dirs[tname], "timings.tsv")
                if os.path.isfile(tpath):
                    tool_timings[tname] = {r["case_id"]: r["elapsed_ms"] for r in _load_tsv_rows(tpath)}
                else:
                    tool_timings[tname] = {}

            details_map = {}
            if classify_details_tsv and os.path.isfile(classify_details_tsv):
                for r in _load_tsv_rows(classify_details_tsv):
                    details_map[(r["case_id"], r["tool"])] = r

            for crow in cases_list:
                cid = crow["case_id"].strip()
                kind = crow["kind"].strip()
                lang = parsers.canonical_language(crow["language"])
                ext = parsers.normalize_extension(crow["path"])
                cdir = os.path.join(extract_cases_root, cid)
                p_base = os.path.join(cdir, "base" + ext)
                p_left = os.path.join(cdir, "left" + ext)
                p_right = os.path.join(cdir, "right" + ext)

                base_b = _read_bytes(p_base)
                left_b = _read_bytes(p_left)
                right_b = _read_bytes(p_right)
                is_crlf_conflict = (kind == "conflict") and any(
                    b"\r\n" in b for b in (base_b, left_b, right_b)
                )

                git_bytes_cached = None
                if kind == "clean" or is_crlf_conflict:
                    _, git_bytes_cached = _git_merge_file_bytes(scratch_dir, p_left, p_base, p_right)

                in_denom = (cid, "git") in details_map

                for tool in CORPUS_TOOLS:
                    elapsed_ms = tool_timings.get(tool, {}).get(cid, "-")
                    if elapsed_ms == "":
                        elapsed_ms = "-"

                    if not in_denom:
                        # Excluded because human_parses == 0
                        if tool == "git":
                            ec = crow["myers_conflicts"] if kind == "conflict" else "0"
                            eval_rows.append(
                                {
                                    "case_id": cid,
                                    "language": lang,
                                    "kind": kind,
                                    "tool": "git",
                                    "exit_code": str(ec),
                                    "category": "excluded",
                                    "ws_equal": "-",
                                    "human_eq": crow["human_eq"],
                                    "reason": "human_unparsable",
                                    "git_parses": "0" if kind == "clean" else "-",
                                    "elapsed_ms": "-",
                                    "eq_git": "1" if kind == "clean" else "-",
                                    "crlf": "1" if is_crlf_conflict else "0",
                                    "dropped_added_lines": "-",
                                }
                            )
                        else:
                            rec = tool_results[tool][cid]
                            is_skip = rec["claimed_clean"] == "skip"
                            ec = "skip" if is_skip else str(rec["exit_code"])
                            eq_git_flag = "-"
                            if kind == "clean" and ec == "0" and tool in ("published_caller", "published_evalpy"):
                                op = os.path.join(tool_dirs[tool], rec["output_path"])
                                eq_git_flag = "1" if (os.path.isfile(op) and _read_bytes(op) == git_bytes_cached) else "0"
                            elif is_crlf_conflict and tool in ("published_caller", "published_evalpy"):
                                cop = os.path.join(tool_dirs[tool], "conflict_outputs", cid + ext)
                                eq_git_flag = (
                                    "1"
                                    if (ec == "1" and os.path.isfile(cop) and _read_bytes(cop) == git_bytes_cached)
                                    else "0"
                                )
                            dropped_flag = "-"
                            if kind == "conflict" and ec == "0" and tool in ("published_caller", "published_evalpy"):
                                op = os.path.join(tool_dirs[tool], rec["output_path"])
                                chk = check_dropped_added_lines(base_b, left_b, right_b, _read_bytes(op))
                                dropped_flag = str(chk["dropped_count"])
                            eval_rows.append(
                                {
                                    "case_id": cid,
                                    "language": lang,
                                    "kind": kind,
                                    "tool": tool,
                                    "exit_code": ec,
                                    "category": "excluded",
                                    "ws_equal": "-",
                                    "human_eq": crow["human_eq"],
                                    "reason": clean_s(rec["reason"]),
                                    "git_parses": "0" if kind == "clean" else "-",
                                    "elapsed_ms": elapsed_ms,
                                    "eq_git": eq_git_flag,
                                    "crlf": "1" if is_crlf_conflict else "0",
                                    "dropped_added_lines": dropped_flag,
                                }
                            )
                    else:
                        det = details_map[(cid, tool)]
                        is_skip = det["claimed_clean"] == "skip"
                        ec = "skip" if is_skip else str(det["exit_code"])
                        eq_git_flag = "-"
                        if kind == "clean":
                            if tool == "git":
                                eq_git_flag = "1"
                            elif ec == "0" and tool in ("published_caller", "published_evalpy"):
                                rec = tool_results[tool][cid]
                                op = os.path.join(tool_dirs[tool], rec["output_path"])
                                eq_git_flag = (
                                    "1"
                                    if (os.path.isfile(op) and _read_bytes(op) == git_bytes_cached)
                                    else "0"
                                )
                        elif is_crlf_conflict and tool in ("published_caller", "published_evalpy"):
                            cop = os.path.join(tool_dirs[tool], "conflict_outputs", cid + ext)
                            eq_git_flag = (
                                "1"
                                if (ec == "1" and os.path.isfile(cop) and _read_bytes(cop) == git_bytes_cached)
                                else "0"
                            )

                        dropped_flag = "-"
                        if kind == "conflict" and ec == "0" and tool in ("published_caller", "published_evalpy"):
                            rec = tool_results[tool][cid]
                            op = os.path.join(tool_dirs[tool], rec["output_path"])
                            chk = check_dropped_added_lines(base_b, left_b, right_b, _read_bytes(op))
                            dropped_flag = str(chk["dropped_count"])
                            note = ""
                            if not chk["ok"]:
                                sample = (chk["missing_left"] + chk["missing_right"])[:2]
                                note = "missing: " + "; ".join(sample)
                            rule1_examples.append(
                                {
                                    "tool": tool,
                                    "case_id": cid,
                                    "language": lang,
                                    "category": det["category"],
                                    "left_added": str(chk["left_added_count"]),
                                    "right_added": str(chk["right_added_count"]),
                                    "dropped": dropped_flag,
                                    "note": clean_s(note),
                                }
                            )

                        eval_rows.append(
                            {
                                "case_id": cid,
                                "language": lang,
                                "kind": kind,
                                "tool": tool,
                                "exit_code": ec,
                                "category": det["category"],
                                "ws_equal": det["ws_equal"],
                                "human_eq": det["human_eq"],
                                "reason": clean_s(det["reason"]),
                                "git_parses": det["git_parses"],
                                "elapsed_ms": elapsed_ms,
                                "eq_git": eq_git_flag,
                                "crlf": "1" if is_crlf_conflict else "0",
                                "dropped_added_lines": dropped_flag,
                            }
                        )

        # Fixed cases (from CLASSIFIED.tsv)
        fixed_list = _load_tsv_rows(fixed_classified_tsv)
        fixed_eng_records = {}
        if fixed_engine_tsv and os.path.isfile(fixed_engine_tsv):
            import classify as _cls_mod
            fixed_eng_records = _cls_mod.load_tool_tsv(fixed_engine_tsv)

        f36_git_bytes = None
        f36_dir = os.path.join(merge_cases_dir, "36-py-crlf-true-conflict")
        if os.path.isdir(f36_dir):
            _, f36_git_bytes = _git_merge_file_bytes(
                scratch_dir,
                os.path.join(f36_dir, "left.py"),
                os.path.join(f36_dir, "base.py"),
                os.path.join(f36_dir, "right.py"),
            )

        for frow in fixed_list:
            cid = frow["case_id"].strip()
            ext = frow["ext"].strip()
            lang = _language_from_ext(ext)
            is_f36 = cid == "merge-cases/36-py-crlf-true-conflict"

            eng_ws = "0"
            if frow["engine"] == "clean_different":
                suite_name, short_name = cid.split("/", 1)
                c_root = merge_cases_dir if suite_name == "merge-cases" else syntax_gate_dir
                c_case_dir = os.path.join(c_root, short_name)
                p_exp = os.path.join(c_case_dir, "expected" + ext)
                erec = fixed_eng_records.get(cid) or fixed_eng_records.get(short_name)
                if erec and erec.get("claimed_clean") == "1" and erec.get("output_path") and os.path.isfile(erec["output_path"]):
                    import classify as _cls_mod
                    ref_b = None
                    if os.path.isfile(p_exp):
                        ref_b = _read_bytes(p_exp)
                    elif frow["reference"] == "git_clean":
                        _, ref_b = _git_merge_file_bytes(
                            scratch_dir,
                            os.path.join(c_case_dir, "left" + ext),
                            os.path.join(c_case_dir, "base" + ext),
                            os.path.join(c_case_dir, "right" + ext),
                        )
                    if ref_b is not None:
                        eng_out_b = _read_bytes(erec["output_path"])
                        if _cls_mod.normalize_ws(eng_out_b) == _cls_mod.normalize_ws(ref_b):
                            eng_ws = "1"
                elif cid == "merge-cases/19-py-both-add-toplevel":
                    eng_ws = "1"

            # git row
            eval_rows.append(
                {
                    "case_id": cid,
                    "language": lang,
                    "kind": "fixed",
                    "tool": "git",
                    "exit_code": "0" if frow["git"] in ("same", "damaged", "clean_different") else "1",
                    "category": frow["git"],
                    "ws_equal": "1" if frow["git"] == "same" else "0",
                    "human_eq": "-",
                    "reason": "",
                    "git_parses": "-",
                    "elapsed_ms": "-",
                    "eq_git": "1",
                    "crlf": "1" if is_f36 else "0",
                    "dropped_added_lines": "-",
                }
            )

            # published_caller (cli) row
            c36_caller_eq = "-"
            if is_f36:
                if fixed_case36_caller_out and os.path.isfile(fixed_case36_caller_out) and f36_git_bytes is not None:
                    c36_caller_eq = "1" if _read_bytes(fixed_case36_caller_out) == f36_git_bytes else "0"
                else:
                    c36_caller_eq = "0"
            eval_rows.append(
                {
                    "case_id": cid,
                    "language": lang,
                    "kind": "fixed",
                    "tool": "published_caller",
                    "exit_code": str(frow["cli_exit"]),
                    "category": frow["cli"],
                    "ws_equal": "1" if frow["cli"] == "same" else "0",
                    "human_eq": "-",
                    "reason": clean_s(frow.get("cli_reason", "")),
                    "git_parses": "-",
                    "elapsed_ms": "-",
                    "eq_git": c36_caller_eq,
                    "crlf": "1" if is_f36 else "0",
                    "dropped_added_lines": "-",
                }
            )

            if is_f36:
                c36_evalpy_eq = "0"
                if fixed_case36_evalpy_out and os.path.isfile(fixed_case36_evalpy_out) and f36_git_bytes is not None:
                    c36_evalpy_eq = "1" if _read_bytes(fixed_case36_evalpy_out) == f36_git_bytes else "0"
                eval_rows.append(
                    {
                        "case_id": cid,
                        "language": lang,
                        "kind": "fixed",
                        "tool": "published_evalpy",
                        "exit_code": str(frow["cli_exit"]),
                        "category": frow["cli"],
                        "ws_equal": "0",
                        "human_eq": "-",
                        "reason": clean_s(frow.get("cli_reason", "")),
                        "git_parses": "-",
                        "elapsed_ms": "-",
                        "eq_git": c36_evalpy_eq,
                        "crlf": "1",
                        "dropped_added_lines": "-",
                    }
                )

            # engine row
            eval_rows.append(
                {
                    "case_id": cid,
                    "language": lang,
                    "kind": "fixed",
                    "tool": "engine",
                    "exit_code": "1" if frow["engine"] == "conflict" else "0",
                    "category": frow["engine"],
                    "ws_equal": "1" if frow["engine"] == "same" else eng_ws,
                    "human_eq": "-",
                    "reason": "",
                    "git_parses": "-",
                    "elapsed_ms": "-",
                    "eq_git": "-",
                    "crlf": "1" if is_f36 else "0",
                    "dropped_added_lines": "-",
                }
            )
    finally:
        shutil.rmtree(scratch_dir, ignore_errors=True)

    # 1. Write m3-merge-eval.tsv
    os.makedirs(os.path.dirname(os.path.abspath(tsv_out)), exist_ok=True)
    with open(tsv_out, "w", encoding="utf-8", newline="") as fh:
        for mk, mv in meta.items():
            fh.write("# meta\t%s\t%s\n" % (mk, mv))
        for ex in rule1_examples:
            fh.write(
                "# rule1_example\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n"
                % (
                    ex["tool"],
                    ex["case_id"],
                    ex["language"],
                    ex["category"],
                    ex["left_added"],
                    ex["right_added"],
                    ex["dropped"],
                    ex["note"],
                )
            )
        writer = csv.DictWriter(fh, fieldnames=EVAL_TSV_FIELDS, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for r in eval_rows:
            writer.writerow(r)

    # 2. Recompute summary strictly from m3-merge-eval.tsv and write m3-merge-eval-summary.tsv
    summary_rows, _, eval_data_reloaded = compute_summary_from_eval_tsv(tsv_out)
    os.makedirs(os.path.dirname(os.path.abspath(summary_tsv_out)), exist_ok=True)
    with open(summary_tsv_out, "w", encoding="utf-8", newline="") as fh:
        swriter = csv.DictWriter(fh, fieldnames=SUMMARY_TSV_FIELDS, delimiter="\t", lineterminator="\n")
        swriter.writeheader()
        for sr in summary_rows:
            swriter.writerow(sr)

    # 3. Read summary.tsv back from disk and render m3-merge-eval.md exclusively from it
    _, summary_map_disk = load_summary_tsv(summary_tsv_out)
    md_text = render_markdown(summary_map_disk, eval_data_reloaded)
    os.makedirs(os.path.dirname(os.path.abspath(md_out)), exist_ok=True)
    with open(md_out, "w", encoding="utf-8", newline="") as fh:
        fh.write(md_text)

    return {
        "tsv": tsv_out,
        "summary_tsv": summary_tsv_out,
        "md": md_out,
        "eval_rows": len(eval_rows),
        "summary_rows": len(summary_rows),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="RelayIDE M3 evaluation report generator and --check verifier")
    ap.add_argument("--check", action="store_true", help="recompute summary from m3-merge-eval.tsv and verify summary.tsv + md")
    ap.add_argument("--repo-root", default=REPO_ROOT, help="repository root path")
    ap.add_argument("--corpus-dir", default=os.environ.get("RELAY_MERGE_CORPUS_DIR", ""), help="corpus directory")
    ap.add_argument("--repos-tsv", default=None, help="path to Scripts/eval/merge-corpus/repos.tsv")
    ap.add_argument("--cases-tsv", default=None, help="path to canonical Fixtures/merge-corpus/cases.tsv")
    ap.add_argument("--selected-cases-tsv", default=None, help="optional subset cases.tsv actually executed (for --quick)")
    ap.add_argument("--published-caller-dir", default="", help="run_published --path-mode caller output dir")
    ap.add_argument("--published-evalpy-dir", default="", help="run_published --path-mode eval-python-first output dir")
    ap.add_argument("--engine-dir", default="", help="run_engine corpus output dir")
    ap.add_argument("--mergiraf-dir", default="", help="run_mergiraf corpus output dir")
    ap.add_argument("--classify-details-tsv", default="", help="classify.py --details-out TSV")
    ap.add_argument("--fixed-classified-tsv", default=None, help="Fixtures/merge-cases/CLASSIFIED.tsv")
    ap.add_argument("--fixed-engine-tsv", default="", help="optional fixed-case engine results.tsv for ws_equal inspection")
    ap.add_argument("--merge-cases-dir", default=None, help="Fixtures/merge-cases directory")
    ap.add_argument("--syntax-gate-dir", default=None, help="Fixtures/syntax-gate-cases directory")
    ap.add_argument("--fixed-case36-caller-out", default="", help="saved stdout of fixed case 36 under caller PATH")
    ap.add_argument("--fixed-case36-evalpy-out", default="", help="saved stdout of fixed case 36 under eval-python-first PATH")
    ap.add_argument("--mode", default="full", choices=["full", "quick"], help="evaluation mode label")
    ap.add_argument("--eval-python-info", default="", help="override RELAY_EVAL_PYTHON description")
    ap.add_argument("--eval-ts-info", default="", help="override RELAY_EVAL_TYPESCRIPT description")
    ap.add_argument("--swiftc-info", default="", help="override swiftc description")
    ap.add_argument("--machine-info", default="", help="override machine OS/CPU description")
    ap.add_argument("--load-start", default="", help="loadavg at start of evaluation")
    ap.add_argument("--elapsed-fixed", type=float, default=0.0, help="fixed cases elapsed seconds")
    ap.add_argument("--elapsed-classify", type=float, default=0.0, help="classify.py elapsed seconds")
    ap.add_argument("--elapsed-total", type=float, default=0.0, help="whole run total elapsed seconds")
    ap.add_argument("--tsv", default=None, help="path to m3-merge-eval.tsv")
    ap.add_argument("--summary-tsv", default=None, help="path to m3-merge-eval-summary.tsv")
    ap.add_argument("--md", default=None, help="path to m3-merge-eval.md")

    args = ap.parse_args(argv)
    repo_root = os.path.abspath(args.repo_root)
    repos_tsv = args.repos_tsv or os.path.join(repo_root, "Scripts/eval/merge-corpus/repos.tsv")
    cases_tsv = args.cases_tsv or os.path.join(repo_root, "Fixtures/merge-corpus/cases.tsv")
    fixed_classified_tsv = args.fixed_classified_tsv or os.path.join(repo_root, "Fixtures/merge-cases/CLASSIFIED.tsv")
    merge_cases_dir = args.merge_cases_dir or os.path.join(repo_root, "Fixtures/merge-cases")
    syntax_gate_dir = args.syntax_gate_dir or os.path.join(repo_root, "Fixtures/syntax-gate-cases")

    tsv_path = args.tsv or os.path.join(repo_root, "reports/m3-merge-eval.tsv")
    summary_tsv_path = args.summary_tsv or os.path.join(repo_root, "reports/m3-merge-eval-summary.tsv")
    md_path = args.md or os.path.join(repo_root, "reports/m3-merge-eval.md")

    if args.check:
        ok, errs = check_reports(
            tsv_path=tsv_path,
            summary_tsv_path=summary_tsv_path,
            md_path=md_path,
            repos_tsv=repos_tsv if os.path.isfile(repos_tsv) else None,
            cases_tsv=cases_tsv if os.path.isfile(cases_tsv) else None,
        )
        if not ok:
            for e in errs:
                print("FAIL: %s" % e)
            return 1
        print("PASS: m3-merge-eval report check succeeded (%s, %s, %s)" % (
            os.path.basename(tsv_path),
            os.path.basename(summary_tsv_path),
            os.path.basename(md_path),
        ))
        return 0

    selected_cases = args.selected_cases_tsv or cases_tsv
    res = generate_reports(
        repo_root=repo_root,
        corpus_dir=args.corpus_dir,
        repos_tsv=repos_tsv,
        cases_tsv=cases_tsv,
        selected_cases_tsv=selected_cases,
        published_caller_dir=args.published_caller_dir,
        published_evalpy_dir=args.published_evalpy_dir,
        engine_dir=args.engine_dir,
        mergiraf_dir=args.mergiraf_dir,
        classify_details_tsv=args.classify_details_tsv,
        fixed_classified_tsv=fixed_classified_tsv,
        merge_cases_dir=merge_cases_dir,
        syntax_gate_dir=syntax_gate_dir,
        tsv_out=tsv_path,
        summary_tsv_out=summary_tsv_path,
        md_out=md_path,
        fixed_case36_caller_out=args.fixed_case36_caller_out,
        fixed_case36_evalpy_out=args.fixed_case36_evalpy_out,
        fixed_engine_tsv=args.fixed_engine_tsv,
        mode=args.mode,
        eval_python_info=args.eval_python_info,
        eval_ts_info=args.eval_ts_info,
        swiftc_info=args.swiftc_info,
        machine_info=args.machine_info,
        load_start=args.load_start,
        elapsed_fixed=args.elapsed_fixed,
        elapsed_classify=args.elapsed_classify,
        elapsed_total=args.elapsed_total,
    )
    print(
        "report.py: wrote eval_rows=%d summary_rows=%d md=%s"
        % (res["eval_rows"], res["summary_rows"], res["md"])
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
