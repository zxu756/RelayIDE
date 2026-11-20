#!/usr/bin/env python3
"""Unit tests for `Scripts/eval/merge-corpus/report.py` (M3 Stage 5).

Covers:
  1. End-to-end report generation (`m3-merge-eval.tsv`, `m3-merge-eval-summary.tsv`, `m3-merge-eval.md`)
     and independent `summary` recomputation from `m3-merge-eval.tsv`.
  2. `--check` verification detecting a modified number in `m3-merge-eval.md`, a modified value in
     `m3-merge-eval-summary.tsv`, or a modified row in `m3-merge-eval.tsv`.
  3. Boundary conditions for every row (Rules 1..5) of the keep/drop decision table, including exact
     20% (`20/100`) passing threshold and `mergiraf` Swift `"没跑"` handling, plus verifying `"建议删"` /
     `"建议留"` never appear in the conclusion section.
  4. `difflib`-based check for `"退出 0 却丢了一边新增的行"` (`check_dropped_added_lines`), both when all
     added lines are preserved and when one side's added line is dropped.
  5. Sanitization of home-directory paths and email addresses in generated report files.

Python 3.9 compatible, standard library only.
"""
import contextlib
import csv
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import report  # noqa: E402


def _write_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write(text)


def _write_bytes(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def _write_tsv(path, fields, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for r in rows:
            writer.writerow(r)


def _git_merge_bytes(scratch, left_path, base_path, right_path):
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": scratch,
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }
    proc = subprocess.run(
        ["/usr/bin/git", "merge-file", "-p", "-L", "left", "-L", "base", "-L", "right", left_path, base_path, right_path],
        cwd=scratch,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return proc.returncode, proc.stdout


class MergeReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="relay-test-report.")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _build_mini_fixture(self, drop_right_line_in_c1=False):
        """Constructs a self-contained mini evaluation workspace in `self.tmp`."""
        root = self.tmp
        repos_tsv = os.path.join(root, "repos.tsv")
        cases_tsv = os.path.join(root, "cases.tsv")
        corpus_dir = os.path.join(root, "corpus")
        extract_cases = os.path.join(corpus_dir, "extract", "cases")
        stats_tsv = os.path.join(corpus_dir, "extract", "stats.tsv")

        _write_tsv(
            repos_tsv,
            ["language", "extensions", "url", "default_branch", "commit", "license"],
            [
                {
                    "language": "python",
                    "extensions": ".py",
                    "url": "https://example.invalid/py.git",
                    "default_branch": "main",
                    "commit": "1" * 40,
                    "license": "MIT",
                },
                {
                    "language": "swift",
                    "extensions": ".swift",
                    "url": "https://example.invalid/sw.git",
                    "default_branch": "main",
                    "commit": "2" * 40,
                    "license": "MIT",
                },
                {
                    "language": "typescript",
                    "extensions": ".ts,.tsx",
                    "url": "https://example.invalid/ts.git",
                    "default_branch": "main",
                    "commit": "3" * 40,
                    "license": "MIT",
                },
            ],
        )

        # Cases:
        #   c00001 (python, conflict, pure insertion, published_caller & evalpy exit 0 -> same)
        #   c00002 (python, conflict, CRLF conflict -> exit 1, byte-equal to git)
        #   c00003 (swift, conflict, human_parses=0 -> excluded from denominator)
        #   c00004 (swift, conflict, human_parses=1 -> conflict in published, clean_different ws_equal=1 in engine, skipped in mergiraf)
        #   c00005 (typescript, conflict, human_parses=1 -> conflict in published, damaged in engine, same in mergiraf)
        #   k00001 (python, clean, human_parses=1 -> caller exit 3 rejected git_parses=1, evalpy exit 0 same -> PATH diff!)
        #   k00002 (swift, clean, human_parses=0 -> excluded clean exit 3)
        #   k00003 (typescript, clean, human_parses=1 -> exit 0 same in all)
        c1_base = b"def base_fn():\n    return 0\n"
        c1_left = b"def base_fn():\n    return 0\n\ndef left_fn():\n    return 1\n"
        c1_right = b"def base_fn():\n    return 0\n\ndef right_fn():\n    return 2\n"
        c1_human = b"def base_fn():\n    return 0\n\ndef left_fn():\n    return 1\n\ndef right_fn():\n    return 2\n"
        c1_pub_out = (
            b"def base_fn():\n    return 0\n\ndef left_fn():\n    return 1\n"
            if drop_right_line_in_c1
            else c1_human
        )

        c2_base = b"x = 1\r\ny = 2\r\n"
        c2_left = b"x = 10\r\ny = 2\r\n"
        c2_right = b"x = 20\r\ny = 2\r\n"
        c2_human = b"x = 10\r\ny = 2\r\n"

        c3_base = b"func f() { let a = 1 }\n"
        c3_left = b"func f() { let a = 2 }\n"
        c3_right = b"func f() { let a = 3 }\n"
        c3_human = b"if let a = opt where a > 0 {}\n"

        c4_base = b"struct S {\n    let a = 1\n}\n"
        c4_left = b"struct S {\n    let a = 2\n}\n"
        c4_right = b"struct S {\n    let a = 3\n}\n"
        c4_human = b"struct S {\n    let a = 23\n}\n"
        c4_eng_out = b"struct S {\n    let a = 23\n\n}\n"

        c5_base = b"export const v = 1;\n"
        c5_left = b"export const v = 2;\n"
        c5_right = b"export const v = 3;\n"
        c5_human = b"export const v = 3;\n"
        c5_eng_out = b"export const v = ;\n"

        k1_base = b"a = 1\nb = 2\n"
        k1_left = b"a = 10\nb = 2\n"
        k1_right = b"a = 1\nb = 20\n"
        k1_git = b"a = 10\nb = 20\n"

        k2_base = b"let x = 1\nlet y = 2\n"
        k2_left = b"let x = 10\nlet y = 2\n"
        k2_right = b"let x = 1\nlet y = 20\n"
        k2_git = b"let x = 10\nlet y = 20\n"

        k3_base = b"const a = 1;\nconst b = 2;\n"
        k3_left = b"const a = 10;\nconst b = 2;\n"
        k3_right = b"const a = 1;\nconst b = 20;\n"
        k3_git = b"const a = 10;\nconst b = 20;\n"

        case_blobs = {
            ("c00001", ".py"): (c1_base, c1_left, c1_right, c1_human),
            ("c00002", ".py"): (c2_base, c2_left, c2_right, c2_human),
            ("c00003", ".swift"): (c3_base, c3_left, c3_right, c3_human),
            ("c00004", ".swift"): (c4_base, c4_left, c4_right, c4_human),
            ("c00005", ".ts"): (c5_base, c5_left, c5_right, c5_human),
            ("k00001", ".py"): (k1_base, k1_left, k1_right, k1_git),
            ("k00002", ".swift"): (k2_base, k2_left, k2_right, k2_git),
            ("k00003", ".ts"): (k3_base, k3_left, k3_right, k3_git),
        }
        for (cid, ext), (b_b, l_b, r_b, h_b) in case_blobs.items():
            cdir = os.path.join(extract_cases, cid)
            _write_bytes(os.path.join(cdir, "base" + ext), b_b)
            _write_bytes(os.path.join(cdir, "left" + ext), l_b)
            _write_bytes(os.path.join(cdir, "right" + ext), r_b)
            _write_bytes(os.path.join(cdir, "human" + ext), h_b)

        cases_fields = [
            "case_id", "kind", "language", "repo", "merge", "p1", "p2", "base", "path",
            "blob_base", "blob_left", "blob_right", "blob_human",
            "myers_conflicts", "histogram_conflicts", "pure_insertion", "human_eq", "human_parses",
        ]
        _write_tsv(
            cases_tsv,
            cases_fields,
            [
                {
                    "case_id": "c00001", "kind": "conflict", "language": "python", "repo": "org/py",
                    "merge": "m1", "p1": "p1", "p2": "p2", "base": "b1", "path": "mod/a.py",
                    "blob_base": "1", "blob_left": "2", "blob_right": "3", "blob_human": "4",
                    "myers_conflicts": "1", "histogram_conflicts": "1", "pure_insertion": "1",
                    "human_eq": "none", "human_parses": "1",
                },
                {
                    "case_id": "c00002", "kind": "conflict", "language": "python", "repo": "org/py",
                    "merge": "m2", "p1": "p1", "p2": "p2", "base": "b2", "path": "mod/crlf.py",
                    "blob_base": "1", "blob_left": "2", "blob_right": "3", "blob_human": "2",
                    "myers_conflicts": "1", "histogram_conflicts": "1", "pure_insertion": "0",
                    "human_eq": "left", "human_parses": "1",
                },
                {
                    "case_id": "c00003", "kind": "conflict", "language": "swift", "repo": "org/sw",
                    "merge": "m3", "p1": "p1", "p2": "p2", "base": "b3", "path": "Sources/Old.swift",
                    "blob_base": "1", "blob_left": "2", "blob_right": "3", "blob_human": "4",
                    "myers_conflicts": "1", "histogram_conflicts": "1", "pure_insertion": "0",
                    "human_eq": "none", "human_parses": "0",
                },
                {
                    "case_id": "c00004", "kind": "conflict", "language": "swift", "repo": "org/sw",
                    "merge": "m4", "p1": "p1", "p2": "p2", "base": "b4", "path": "Sources/S.swift",
                    "blob_base": "1", "blob_left": "2", "blob_right": "3", "blob_human": "4",
                    "myers_conflicts": "1", "histogram_conflicts": "1", "pure_insertion": "0",
                    "human_eq": "none", "human_parses": "1",
                },
                {
                    "case_id": "c00005", "kind": "conflict", "language": "typescript", "repo": "org/ts",
                    "merge": "m5", "p1": "p1", "p2": "p2", "base": "b5", "path": "src/v.ts",
                    "blob_base": "1", "blob_left": "2", "blob_right": "3", "blob_human": "3",
                    "myers_conflicts": "1", "histogram_conflicts": "1", "pure_insertion": "0",
                    "human_eq": "right", "human_parses": "1",
                },
                {
                    "case_id": "k00001", "kind": "clean", "language": "python", "repo": "org/py",
                    "merge": "m6", "p1": "p1", "p2": "p2", "base": "b6", "path": "mod/clean.py",
                    "blob_base": "1", "blob_left": "2", "blob_right": "3", "blob_human": "4",
                    "myers_conflicts": "0", "histogram_conflicts": "0", "pure_insertion": "0",
                    "human_eq": "none", "human_parses": "1",
                },
                {
                    "case_id": "k00002", "kind": "clean", "language": "swift", "repo": "org/sw",
                    "merge": "m7", "p1": "p1", "p2": "p2", "base": "b7", "path": "Sources/CleanOld.swift",
                    "blob_base": "1", "blob_left": "2", "blob_right": "3", "blob_human": "4",
                    "myers_conflicts": "0", "histogram_conflicts": "0", "pure_insertion": "0",
                    "human_eq": "none", "human_parses": "0",
                },
                {
                    "case_id": "k00003", "kind": "clean", "language": "typescript", "repo": "org/ts",
                    "merge": "m8", "p1": "p1", "p2": "p2", "base": "b8", "path": "src/clean.ts",
                    "blob_base": "1", "blob_left": "2", "blob_right": "3", "blob_human": "4",
                    "myers_conflicts": "0", "histogram_conflicts": "0", "pure_insertion": "0",
                    "human_eq": "none", "human_parses": "1",
                },
            ],
        )

        # Compute exact git conflict bytes for c00002 (CRLF) and fixed case 36
        git_scratch = os.path.join(root, "git_scratch")
        os.makedirs(git_scratch, exist_ok=True)
        _, c2_git_conflict = _git_merge_bytes(
            git_scratch,
            os.path.join(extract_cases, "c00002/left.py"),
            os.path.join(extract_cases, "c00002/base.py"),
            os.path.join(extract_cases, "c00002/right.py"),
        )

        # Fixed cases mini directory (includes 09, 14, 19, 36 + 1 syntax-gate)
        merge_cases_dir = os.path.join(root, "Fixtures/merge-cases")
        syntax_gate_dir = os.path.join(root, "Fixtures/syntax-gate-cases")
        f36_dir = os.path.join(merge_cases_dir, "36-py-crlf-true-conflict")
        _write_bytes(os.path.join(f36_dir, "base.py"), c2_base)
        _write_bytes(os.path.join(f36_dir, "left.py"), c2_left)
        _write_bytes(os.path.join(f36_dir, "right.py"), c2_right)
        _, f36_git_conflict = _git_merge_bytes(
            git_scratch,
            os.path.join(f36_dir, "left.py"),
            os.path.join(f36_dir, "base.py"),
            os.path.join(f36_dir, "right.py"),
        )
        for dname, ext in [
            ("09-py-triplequote", ".py"),
            ("14-py-control-triplequote-nodef", ".py"),
            ("19-py-both-add-toplevel", ".py"),
        ]:
            dd = os.path.join(merge_cases_dir, dname)
            _write_bytes(os.path.join(dd, "base" + ext), b"x = 1\n")
            _write_bytes(os.path.join(dd, "left" + ext), b"x = 1\n")
            _write_bytes(os.path.join(dd, "right" + ext), b"x = 1\n")
        sg_dir = os.path.join(syntax_gate_dir, "python-string-delimiters")
        _write_bytes(os.path.join(sg_dir, "base.py"), b"x = 1\n")
        _write_bytes(os.path.join(sg_dir, "left.py"), b"x = 1\n")
        _write_bytes(os.path.join(sg_dir, "right.py"), b"x = 1\n")

        fixed_classified_tsv = os.path.join(merge_cases_dir, "CLASSIFIED.tsv")
        _write_tsv(
            fixed_classified_tsv,
            ["case_id", "ext", "reference", "git", "cli_exit", "cli_strategy", "cli", "cli_reason", "engine"],
            [
                {
                    "case_id": "merge-cases/09-py-triplequote", "ext": ".py", "reference": "git_clean",
                    "git": "same", "cli_exit": "0", "cli_strategy": "line-level", "cli": "same",
                    "cli_reason": "", "engine": "damaged",
                },
                {
                    "case_id": "merge-cases/14-py-control-triplequote-nodef", "ext": ".py", "reference": "git_clean",
                    "git": "same", "cli_exit": "0", "cli_strategy": "line-level", "cli": "same",
                    "cli_reason": "", "engine": "damaged",
                },
                {
                    "case_id": "merge-cases/19-py-both-add-toplevel", "ext": ".py", "reference": "expected",
                    "git": "conflict", "cli_exit": "0", "cli_strategy": "declaration-level", "cli": "same",
                    "cli_reason": "", "engine": "clean_different",
                },
                {
                    "case_id": "merge-cases/36-py-crlf-true-conflict", "ext": ".py", "reference": "true_conflict",
                    "git": "conflict", "cli_exit": "1", "cli_strategy": "none", "cli": "conflict",
                    "cli_reason": "", "engine": "conflict",
                },
                {
                    "case_id": "syntax-gate-cases/python-string-delimiters", "ext": ".py", "reference": "git_clean",
                    "git": "damaged", "cli_exit": "3", "cli_strategy": "-", "cli": "rejected",
                    "cli_reason": "exit=3: syntax_check_failed (python3 -m py_compile)", "engine": "clean_different",
                },
            ],
        )

        # Tool run directories
        runs_dir = os.path.join(corpus_dir, "runs", "unit_run")
        pub_caller_dir = os.path.join(runs_dir, "published_caller")
        pub_evalpy_dir = os.path.join(runs_dir, "published_evalpy")
        engine_dir = os.path.join(runs_dir, "engine")
        mergiraf_dir = os.path.join(runs_dir, "mergiraf")
        classify_dir = os.path.join(runs_dir, "classify")

        fake_home = os.path.expanduser("~")
        fake_email = "dev.person" + "@" + "example.org"

        # published_caller outputs & results
        _write_bytes(os.path.join(pub_caller_dir, "outputs/c00001.py"), c1_pub_out)
        _write_bytes(os.path.join(pub_caller_dir, "outputs/k00003.ts"), k3_git)
        _write_bytes(os.path.join(pub_caller_dir, "conflict_outputs/c00002.py"), c2_git_conflict)
        _write_bytes(os.path.join(pub_caller_dir, "fixed_crlf_36.py"), f36_git_conflict)
        res_fields = ["case_id", "exit_code", "claimed_clean", "output_path", "reason", "strategy"]
        _write_tsv(
            os.path.join(pub_caller_dir, "results.tsv"),
            res_fields,
            [
                {"case_id": "c00001", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/c00001.py", "reason": "", "strategy": "declaration-level"},
                {"case_id": "c00002", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "c00003", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "c00004", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "c00005", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "k00001", "exit_code": "3", "claimed_clean": "0", "output_path": "", "reason": "SyntaxError from " + fake_home + "/proj by " + fake_email, "strategy": "-"},
                {"case_id": "k00002", "exit_code": "3", "claimed_clean": "0", "output_path": "", "reason": "Swift 2 syntax rejected", "strategy": "-"},
                {"case_id": "k00003", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/k00003.ts", "reason": "", "strategy": "line-level"},
            ],
        )
        _write_text(
            os.path.join(pub_caller_dir, "env.txt"),
            "\n".join([
                "=== run_published ===",
                "path_mode: caller",
                "cli_wrapper: " + root + "/Scripts/acceptance/relay-cli.sh",
                "cli_bin: " + fake_home + "/custom_bin_dir/app_exec",
                "cli_bin_sha256: " + ("a" * 64),
                "python3_path: /usr/bin/python3",
                "python3_effective: /usr/bin/python3",
                "python3_version: Python 3.9.6",
                "tsc_path: not-in-PATH",
                "tsc_effective: not-found",
                "tsc_version: not-found",
                "node_path: /opt/homebrew/bin/node",
                "node_effective: /opt/homebrew/bin/node",
                "node_version: v22.23.4",
                "git_path: /opt/homebrew/bin/git",
                "git_effective: /opt/homebrew/bin/git",
                "git_version: git version 2.56.0",
                "elapsed_seconds: 12.50",
                "",
            ]),
        )

        # published_evalpy outputs & results (k00001 becomes exit 0!)
        _write_bytes(os.path.join(pub_evalpy_dir, "outputs/c00001.py"), c1_pub_out)
        _write_bytes(os.path.join(pub_evalpy_dir, "outputs/k00001.py"), k1_git)
        _write_bytes(os.path.join(pub_evalpy_dir, "outputs/k00003.ts"), k3_git)
        _write_bytes(os.path.join(pub_evalpy_dir, "conflict_outputs/c00002.py"), c2_git_conflict)
        _write_tsv(
            os.path.join(pub_evalpy_dir, "results.tsv"),
            res_fields,
            [
                {"case_id": "c00001", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/c00001.py", "reason": "", "strategy": "declaration-level"},
                {"case_id": "c00002", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "c00003", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "c00004", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "c00005", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "k00001", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/k00001.py", "reason": "", "strategy": "line-level"},
                {"case_id": "k00002", "exit_code": "3", "claimed_clean": "0", "output_path": "", "reason": "Swift 2 syntax rejected", "strategy": "-"},
                {"case_id": "k00003", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/k00003.ts", "reason": "", "strategy": "line-level"},
            ],
        )
        _write_text(
            os.path.join(pub_evalpy_dir, "env.txt"),
            "\n".join([
                "=== run_published ===",
                "path_mode: eval-python-first",
                "cli_wrapper: " + root + "/Scripts/acceptance/relay-cli.sh",
                "cli_bin: " + fake_home + "/custom_bin_dir/app_exec",
                "cli_bin_sha256: " + ("a" * 64),
                "python3_path: " + fake_home + "/.local/share/uv/python3",
                "python3_effective: " + fake_home + "/.local/share/uv/python3",
                "python3_version: Python 3.14.9",
                "tsc_path: not-in-PATH",
                "tsc_effective: not-found",
                "tsc_version: not-found",
                "node_path: /opt/homebrew/bin/node",
                "node_effective: /opt/homebrew/bin/node",
                "node_version: v22.23.4",
                "git_path: /opt/homebrew/bin/git",
                "git_effective: /opt/homebrew/bin/git",
                "git_version: git version 2.56.0",
                "elapsed_seconds: 9.25",
                "",
            ]),
        )

        # engine outputs, timings & results
        _write_bytes(os.path.join(engine_dir, "outputs/c00004.swift"), c4_eng_out)
        _write_bytes(os.path.join(engine_dir, "outputs/c00005.ts"), c5_eng_out)
        _write_bytes(os.path.join(engine_dir, "outputs/k00003.ts"), k3_git)
        _write_tsv(
            os.path.join(engine_dir, "results.tsv"),
            res_fields,
            [
                {"case_id": "c00001", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "-"},
                {"case_id": "c00002", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "-"},
                {"case_id": "c00003", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "-"},
                {"case_id": "c00004", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/c00004.swift", "reason": "", "strategy": "declaration-level"},
                {"case_id": "c00005", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/c00005.ts", "reason": "", "strategy": "declaration-level"},
                {"case_id": "k00001", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "-"},
                {"case_id": "k00002", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "-"},
                {"case_id": "k00003", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/k00003.ts", "reason": "", "strategy": "declaration-level"},
            ],
        )
        timings_fields = ["case_id", "kind", "language", "exit_code", "claimed_clean", "elapsed_ms"]
        _write_tsv(
            os.path.join(engine_dir, "timings.tsv"),
            timings_fields,
            [
                {"case_id": "c00001", "kind": "conflict", "language": "python", "exit_code": "1", "claimed_clean": "0", "elapsed_ms": "10.000"},
                {"case_id": "c00002", "kind": "conflict", "language": "python", "exit_code": "1", "claimed_clean": "0", "elapsed_ms": "20.000"},
                {"case_id": "c00003", "kind": "conflict", "language": "swift", "exit_code": "1", "claimed_clean": "0", "elapsed_ms": "15.000"},
                {"case_id": "c00004", "kind": "conflict", "language": "swift", "exit_code": "0", "claimed_clean": "1", "elapsed_ms": "30.000"},
                {"case_id": "c00005", "kind": "conflict", "language": "typescript", "exit_code": "0", "claimed_clean": "1", "elapsed_ms": "25.000"},
                {"case_id": "k00001", "kind": "clean", "language": "python", "exit_code": "1", "claimed_clean": "0", "elapsed_ms": "12.000"},
                {"case_id": "k00002", "kind": "clean", "language": "swift", "exit_code": "1", "claimed_clean": "0", "elapsed_ms": "14.000"},
                {"case_id": "k00003", "kind": "clean", "language": "typescript", "exit_code": "0", "claimed_clean": "1", "elapsed_ms": "18.000"},
            ],
        )
        _write_text(
            os.path.join(engine_dir, "env.txt"),
            "\n".join([
                "=== run_engine ===",
                "engine_bin: " + root + "/Scripts/eval/merge-eval/.build/release/relay-merge-eval",
                "engine_bin_sha256: " + ("b" * 64),
                "repo_commit: " + ("c" * 40),
                "elapsed_seconds: 4.50",
                "",
            ]),
        )

        # mergiraf outputs, timings & results (Swift skipped!)
        _write_bytes(os.path.join(mergiraf_dir, "outputs/c00001.py"), c1_human)
        _write_bytes(os.path.join(mergiraf_dir, "outputs/c00005.ts"), c5_human)
        _write_bytes(os.path.join(mergiraf_dir, "outputs/k00001.py"), k1_git)
        _write_bytes(os.path.join(mergiraf_dir, "outputs/k00003.ts"), k3_git)
        _write_tsv(
            os.path.join(mergiraf_dir, "results.tsv"),
            res_fields,
            [
                {"case_id": "c00001", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/c00001.py", "reason": "", "strategy": "mergiraf"},
                {"case_id": "c00002", "exit_code": "1", "claimed_clean": "0", "output_path": "", "reason": "", "strategy": "none"},
                {"case_id": "c00003", "exit_code": "0", "claimed_clean": "skip", "output_path": "", "reason": "unsupported_language:swift", "strategy": "-"},
                {"case_id": "c00004", "exit_code": "0", "claimed_clean": "skip", "output_path": "", "reason": "unsupported_language:swift", "strategy": "-"},
                {"case_id": "c00005", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/c00005.ts", "reason": "", "strategy": "mergiraf"},
                {"case_id": "k00001", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/k00001.py", "reason": "", "strategy": "mergiraf"},
                {"case_id": "k00002", "exit_code": "0", "claimed_clean": "skip", "output_path": "", "reason": "unsupported_language:swift", "strategy": "-"},
                {"case_id": "k00003", "exit_code": "0", "claimed_clean": "1", "output_path": "outputs/k00003.ts", "reason": "", "strategy": "mergiraf"},
            ],
        )
        _write_tsv(
            os.path.join(mergiraf_dir, "timings.tsv"),
            timings_fields,
            [
                {"case_id": "c00001", "kind": "conflict", "language": "python", "exit_code": "0", "claimed_clean": "1", "elapsed_ms": "40.000"},
                {"case_id": "c00002", "kind": "conflict", "language": "python", "exit_code": "1", "claimed_clean": "0", "elapsed_ms": "60.000"},
                {"case_id": "c00003", "kind": "conflict", "language": "swift", "exit_code": "0", "claimed_clean": "skip", "elapsed_ms": "-"},
                {"case_id": "c00004", "kind": "conflict", "language": "swift", "exit_code": "0", "claimed_clean": "skip", "elapsed_ms": "-"},
                {"case_id": "c00005", "kind": "conflict", "language": "typescript", "exit_code": "0", "claimed_clean": "1", "elapsed_ms": "50.000"},
                {"case_id": "k00001", "kind": "clean", "language": "python", "exit_code": "0", "claimed_clean": "1", "elapsed_ms": "30.000"},
                {"case_id": "k00002", "kind": "clean", "language": "swift", "exit_code": "0", "claimed_clean": "skip", "elapsed_ms": "-"},
                {"case_id": "k00003", "kind": "clean", "language": "typescript", "exit_code": "0", "claimed_clean": "1", "elapsed_ms": "80.000"},
            ],
        )
        _write_text(
            os.path.join(mergiraf_dir, "env.txt"),
            "\n".join([
                "=== run_mergiraf ===",
                "mergiraf_bin: /opt/homebrew/bin/mergiraf",
                "mergiraf_bin_sha256: " + ("d" * 64),
                "mergiraf_version: mergiraf 0.20.0",
                "elapsed_seconds: 6.75",
                "",
            ]),
        )

        # classify details.tsv & rejected.tsv (matching classify.py schema for in-denominator cases)
        detail_fields = [
            "case_id", "kind", "language", "tool", "exit_code", "claimed_clean",
            "category", "ws_equal", "human_eq", "git_parses", "reason",
        ]
        c1_cat = "clean_different" if drop_right_line_in_c1 else "same"
        _write_tsv(
            os.path.join(classify_dir, "details.tsv"),
            detail_fields,
            [
                # git
                {"case_id": "c00001", "kind": "conflict", "language": "python", "tool": "git", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00002", "kind": "conflict", "language": "python", "tool": "git", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "left", "git_parses": "-", "reason": ""},
                {"case_id": "c00004", "kind": "conflict", "language": "swift", "tool": "git", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00005", "kind": "conflict", "language": "typescript", "tool": "git", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "right", "git_parses": "-", "reason": ""},
                {"case_id": "k00001", "kind": "clean", "language": "python", "tool": "git", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "1", "reason": ""},
                {"case_id": "k00003", "kind": "clean", "language": "typescript", "tool": "git", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "1", "reason": ""},
                # published_caller
                {"case_id": "c00001", "kind": "conflict", "language": "python", "tool": "published_caller", "exit_code": "0", "claimed_clean": "1", "category": c1_cat, "ws_equal": "0" if drop_right_line_in_c1 else "1", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00002", "kind": "conflict", "language": "python", "tool": "published_caller", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "left", "git_parses": "-", "reason": ""},
                {"case_id": "c00004", "kind": "conflict", "language": "swift", "tool": "published_caller", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00005", "kind": "conflict", "language": "typescript", "tool": "published_caller", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "right", "git_parses": "-", "reason": ""},
                {"case_id": "k00001", "kind": "clean", "language": "python", "tool": "published_caller", "exit_code": "3", "claimed_clean": "0", "category": "rejected", "ws_equal": "0", "human_eq": "none", "git_parses": "1", "reason": "SyntaxError from " + fake_home + "/proj by " + fake_email},
                {"case_id": "k00003", "kind": "clean", "language": "typescript", "tool": "published_caller", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "1", "reason": ""},
                # published_evalpy
                {"case_id": "c00001", "kind": "conflict", "language": "python", "tool": "published_evalpy", "exit_code": "0", "claimed_clean": "1", "category": c1_cat, "ws_equal": "0" if drop_right_line_in_c1 else "1", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00002", "kind": "conflict", "language": "python", "tool": "published_evalpy", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "left", "git_parses": "-", "reason": ""},
                {"case_id": "c00004", "kind": "conflict", "language": "swift", "tool": "published_evalpy", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00005", "kind": "conflict", "language": "typescript", "tool": "published_evalpy", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "right", "git_parses": "-", "reason": ""},
                {"case_id": "k00001", "kind": "clean", "language": "python", "tool": "published_evalpy", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "1", "reason": ""},
                {"case_id": "k00003", "kind": "clean", "language": "typescript", "tool": "published_evalpy", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "1", "reason": ""},
                # engine
                {"case_id": "c00001", "kind": "conflict", "language": "python", "tool": "engine", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00002", "kind": "conflict", "language": "python", "tool": "engine", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "left", "git_parses": "-", "reason": ""},
                {"case_id": "c00004", "kind": "conflict", "language": "swift", "tool": "engine", "exit_code": "0", "claimed_clean": "1", "category": "clean_different", "ws_equal": "1", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00005", "kind": "conflict", "language": "typescript", "tool": "engine", "exit_code": "0", "claimed_clean": "1", "category": "damaged", "ws_equal": "0", "human_eq": "right", "git_parses": "-", "reason": ""},
                {"case_id": "k00001", "kind": "clean", "language": "python", "tool": "engine", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "none", "git_parses": "1", "reason": ""},
                {"case_id": "k00003", "kind": "clean", "language": "typescript", "tool": "engine", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "1", "reason": ""},
                # mergiraf
                {"case_id": "c00001", "kind": "conflict", "language": "python", "tool": "mergiraf", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "-", "reason": ""},
                {"case_id": "c00002", "kind": "conflict", "language": "python", "tool": "mergiraf", "exit_code": "1", "claimed_clean": "0", "category": "conflict", "ws_equal": "0", "human_eq": "left", "git_parses": "-", "reason": ""},
                {"case_id": "c00004", "kind": "conflict", "language": "swift", "tool": "mergiraf", "exit_code": "0", "claimed_clean": "skip", "category": "skipped", "ws_equal": "0", "human_eq": "none", "git_parses": "-", "reason": "unsupported_language:swift"},
                {"case_id": "c00005", "kind": "conflict", "language": "typescript", "tool": "mergiraf", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "right", "git_parses": "-", "reason": ""},
                {"case_id": "k00001", "kind": "clean", "language": "python", "tool": "mergiraf", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "1", "reason": ""},
                {"case_id": "k00003", "kind": "clean", "language": "typescript", "tool": "mergiraf", "exit_code": "0", "claimed_clean": "1", "category": "same", "ws_equal": "1", "human_eq": "none", "git_parses": "1", "reason": ""},
            ],
        )

        out_dir = os.path.join(root, "reports")
        os.makedirs(out_dir, exist_ok=True)
        _write_tsv(stats_tsv, ["language", "repo", "candidates", "kept_conflict", "kept_clean"], [])

        return {
            "root": root,
            "repos_tsv": repos_tsv,
            "cases_tsv": cases_tsv,
            "corpus_dir": corpus_dir,
            "pub_caller_dir": pub_caller_dir,
            "pub_evalpy_dir": pub_evalpy_dir,
            "engine_dir": engine_dir,
            "mergiraf_dir": mergiraf_dir,
            "classify_dir": classify_dir,
            "fixed_classified_tsv": fixed_classified_tsv,
            "merge_cases_dir": merge_cases_dir,
            "syntax_gate_dir": syntax_gate_dir,
            "fixed_crlf_36_stdout": os.path.join(pub_caller_dir, "fixed_crlf_36.py"),
            "out_dir": out_dir,
            "tsv": os.path.join(out_dir, "m3-merge-eval.tsv"),
            "summary_tsv": os.path.join(out_dir, "m3-merge-eval-summary.tsv"),
            "md": os.path.join(out_dir, "m3-merge-eval.md"),
            "fake_home": fake_home,
            "fake_email": fake_email,
        }

    def _run_generate(self, fx):
        argv = [
            "--repo-root", fx["root"],
            "--corpus-dir", fx["corpus_dir"],
            "--repos-tsv", fx["repos_tsv"],
            "--cases-tsv", fx["cases_tsv"],
            "--published-caller-dir", fx["pub_caller_dir"],
            "--published-evalpy-dir", fx["pub_evalpy_dir"],
            "--engine-dir", fx["engine_dir"],
            "--mergiraf-dir", fx["mergiraf_dir"],
            "--classify-details-tsv", os.path.join(fx["classify_dir"], "details.tsv"),
            "--fixed-classified-tsv", fx["fixed_classified_tsv"],
            "--merge-cases-dir", fx["merge_cases_dir"],
            "--syntax-gate-dir", fx["syntax_gate_dir"],
            "--fixed-case36-caller-out", fx["fixed_crlf_36_stdout"],
            "--fixed-case36-evalpy-out", fx["fixed_crlf_36_stdout"],
            "--eval-python-info", os.path.expanduser("~") + "/.local/share/uv/python3.14 (Python 3.14.9)",
            "--eval-ts-info", fx["corpus_dir"] + "/node/node_modules/typescript (typescript 5.9.3)",
            "--swiftc-info", "/usr/bin/swiftc (Apple Swift version 6.4.2)",
            "--machine-info", "macOS 27.0; Apple M4 (10 cores)",
            "--load-start", "4.12 3.85 3.50",
            "--elapsed-fixed", "2.10",
            "--elapsed-classify", "3.40",
            "--elapsed-total", "38.50",
            "--tsv", fx["tsv"],
            "--summary-tsv", fx["summary_tsv"],
            "--md", fx["md"],
        ]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = report.main(argv)
        return rc, buf.getvalue()

    def test_recompute_summary_and_check_detects_tampered_md_and_summary(self):
        fx = self._build_mini_fixture(drop_right_line_in_c1=False)
        rc, _ = self._run_generate(fx)
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.isfile(fx["tsv"]))
        self.assertTrue(os.path.isfile(fx["summary_tsv"]))
        self.assertTrue(os.path.isfile(fx["md"]))

        # Verify summary recomputation from m3-merge-eval.tsv
        _, s_map, _ = report.compute_summary_from_eval_tsv(fx["tsv"])
        self.assertEqual(s_map[("row6_conflict_published", "published_caller:python", "denominator")], "2")
        self.assertEqual(s_map[("row6_conflict_published", "published_caller:python", "same")], "1")
        self.assertEqual(s_map[("row6_conflict_published", "published_caller:swift", "excluded_human_unparsable")], "1")
        self.assertEqual(s_map[("row6_conflict_published", "published_caller:swift", "denominator")], "1")
        self.assertEqual(s_map[("row7_clean_published", "published_caller:python", "rejected_in_denom")], "1")
        self.assertEqual(s_map[("row7_clean_published", "published_evalpy:python", "rejected_in_denom")], "0")
        self.assertEqual(s_map[("row7_clean_published", "published_caller:swift", "exit3_excluded")], "1")
        self.assertEqual(s_map[("row8_crlf", "all", "total_crlf_cases")], "2")
        self.assertEqual(s_map[("row8_crlf", "all", "caller_exit1_eq_git")], "2")
        self.assertEqual(s_map[("row9_engine_conflict", "typescript", "damaged")], "1")
        self.assertEqual(s_map[("row9_engine_conflict", "swift", "clean_different_ws_equal")], "1")
        self.assertEqual(s_map[("row10_mergiraf_conflict", "swift", "skipped_total")], "2")
        self.assertEqual(s_map[("row10_mergiraf_conflict", "swift", "skipped_in_denom")], "1")
        # mergiraf executed ms: [40, 60, 50, 30, 80] -> median 50.000, max 80.000
        self.assertEqual(s_map[("row10_mergiraf_timing", "all", "median_ms")], "50.000")
        self.assertEqual(s_map[("row10_mergiraf_timing", "all", "max_ms")], "80.000")
        self.assertEqual(s_map[("row11_path_diff", "all", "diff_total")], "1")
        self.assertEqual(s_map[("row12_fixed_summary", "engine", "damaged")], "2")

        # Clean --check passes
        check_args = [
            "--check",
            "--tsv", fx["tsv"],
            "--summary-tsv", fx["summary_tsv"],
            "--md", fx["md"],
            "--repos-tsv", fx["repos_tsv"],
            "--cases-tsv", fx["cases_tsv"],
        ]
        out_ok = io.StringIO()
        with contextlib.redirect_stdout(out_ok):
            rc_ok = report.main(check_args)
        self.assertEqual(rc_ok, 0, out_ok.getvalue())

        # Privacy check: neither fake_home nor fake_email leaked into any report file
        for p in (fx["tsv"], fx["summary_tsv"], fx["md"]):
            with open(p, encoding="utf-8") as fh:
                txt = fh.read()
            if fx["fake_home"] and fx["fake_home"] != "/":
                self.assertNotIn(fx["fake_home"], txt)
            self.assertNotIn(fx["fake_email"], txt)

        # Tamper 1: change ONE number in m3-merge-eval.md -> --check MUST fail (exit 1)
        with open(fx["md"], encoding="utf-8") as fh:
            orig_md = fh.read()
        self.assertIn("50.000", orig_md)
        _write_text(fx["md"], orig_md.replace("50.000", "51.000", 1))
        out_bad_md = io.StringIO()
        with contextlib.redirect_stdout(out_bad_md):
            rc_bad_md = report.main(check_args)
        self.assertEqual(rc_bad_md, 1)
        self.assertIn("50.000", out_bad_md.getvalue())
        self.assertIn("51.000", out_bad_md.getvalue())
        _write_text(fx["md"], orig_md)

        # Tamper 2: change ONE value in m3-merge-eval-summary.tsv -> --check MUST fail (exit 1)
        with open(fx["summary_tsv"], encoding="utf-8") as fh:
            orig_sum = fh.read()
        target_line = "row11_path_diff\tall\tdiff_total\t1\n"
        self.assertIn(target_line, orig_sum)
        _write_text(fx["summary_tsv"], orig_sum.replace(target_line, "row11_path_diff\tall\tdiff_total\t2\n", 1))
        out_bad_sum = io.StringIO()
        with contextlib.redirect_stdout(out_bad_sum):
            rc_bad_sum = report.main(check_args)
        self.assertEqual(rc_bad_sum, 1)
        self.assertIn("row11_path_diff", out_bad_sum.getvalue())
        _write_text(fx["summary_tsv"], orig_sum)

        # Tamper 3: change ONE row in m3-merge-eval.tsv without regenerating -> --check MUST fail (exit 1)
        with open(fx["tsv"], encoding="utf-8") as fh:
            orig_tsv = fh.read()
        _write_text(fx["tsv"], orig_tsv.replace("\tdamaged\t", "\tclean_different\t", 1))
        out_bad_tsv = io.StringIO()
        with contextlib.redirect_stdout(out_bad_tsv):
            rc_bad_tsv = report.main(check_args)
        self.assertEqual(rc_bad_tsv, 1)
        _write_text(fx["tsv"], orig_tsv)

        # Restore check -> passes again
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(report.main(check_args), 0)

    def test_dropped_added_lines_check_and_rule1_trigger(self):
        # 1. Direct unit checks on check_dropped_added_lines
        base = b"import math\n\ndef keep():\n    return None\n"
        left = b"import os\nimport math\n\ndef keep():\n    return None\n\ndef f_left():\n    return 10\n"
        right = b"import os\nimport math\n\ndef keep():\n    return None\n\ndef f_right():\n    return None\n"
        good_out = (
            b"import os\nimport math\n\ndef keep():\n    return None\n\n"
            b"def f_left():\n    return 10\n\ndef f_right():\n    return None\n"
        )
        res_ok = report.check_dropped_added_lines(base, left, right, good_out)
        self.assertTrue(res_ok["ok"], res_ok)
        self.assertEqual(res_ok["dropped_count"], 0)

        # Drop right's added function (note `return None` already existed in base once, right added a second!)
        dropped_right_out = (
            b"import os\nimport math\n\ndef keep():\n    return None\n\n"
            b"def f_left():\n    return 10\n"
        )
        res_bad = report.check_dropped_added_lines(base, left, right, dropped_right_out)
        self.assertFalse(res_bad["ok"])
        self.assertGreater(res_bad["dropped_count"], 0)
        self.assertTrue(any("f_right" in ln for ln in res_bad["missing_right"]))

        # 2. End-to-end fixture where c00001 exit-0 output drops right's added line -> Rule 1 triggers!
        fx = self._build_mini_fixture(drop_right_line_in_c1=True)
        rc, _ = self._run_generate(fx)
        self.assertEqual(rc, 0)
        _, s_map, _ = report.compute_summary_from_eval_tsv(fx["tsv"])
        self.assertGreater(int(s_map[("row16_rule1_added_lines", "published_caller:python", "dropped_cases")]), 0)
        rules = report.evaluate_decision_rules(s_map)
        r1 = [r for r in rules if r["rule_id"] == 1][0]
        self.assertTrue(r1["triggered"])
        self.assertEqual(r1["status_label"], "触发")

    def test_decision_rules_boundaries_all_five_rows(self):
        def make_summary_map(
            pub_same,
            denom=(100, 100, 100),
            pub_damaged=(0, 0, 0),
            pub_dropped=(0, 0, 0),
            mgf_same=(25, 25, 25),
            mgf_damaged=(0, 0, 0),
            mgf_skipped=(0, 0, 0),
            eng_same=(0, 2, 5),
            eng_damaged=(51, 49, 202),
        ):
            langs = ("python", "swift", "typescript")
            m = {}
            for idx, lg in enumerate(langs):
                for mode in ("published_caller", "published_evalpy"):
                    m[("row6_conflict_published", "%s:%s" % (mode, lg), "denominator")] = str(denom[idx])
                    m[("row6_conflict_published", "%s:%s" % (mode, lg), "same")] = str(pub_same[idx])
                    m[("row6_conflict_published", "%s:%s" % (mode, lg), "damaged")] = str(pub_damaged[idx])
                    m[("row16_rule1_added_lines", "%s:%s" % (mode, lg), "exit0_checked")] = str(pub_same[idx])
                    m[("row16_rule1_added_lines", "%s:%s" % (mode, lg), "dropped_cases")] = str(pub_dropped[idx])
                m[("row10_mergiraf_conflict", lg, "denominator")] = str(denom[idx])
                m[("row10_mergiraf_conflict", lg, "skipped_in_denom")] = str(mgf_skipped[idx])
                m[("row10_mergiraf_conflict", lg, "same")] = str(mgf_same[idx])
                m[("row10_mergiraf_conflict", lg, "damaged")] = str(mgf_damaged[idx])
                m[("row9_engine_conflict", lg, "denominator")] = str(denom[idx])
                m[("row9_engine_conflict", lg, "same")] = str(eng_same[idx])
                m[("row9_engine_conflict", lg, "damaged")] = str(eng_damaged[idx])
            return m

        # Case A: Exact 20% (20/100) on all 3 languages, 0 damaged/dropped, mergiraf worse (10/100)
        # -> Rule 1 NOT triggered, Rule 2 NOT triggered (20% passes!), Rule 3 NOT triggered, Rule 4 TRIGGERED, Rule 5 TRIGGERED
        m_exact20 = make_summary_map(pub_same=(20, 20, 20), mgf_same=(10, 10, 10))
        rules_a = {r["rule_id"]: r for r in report.evaluate_decision_rules(m_exact20)}
        self.assertFalse(rules_a[1]["triggered"])
        self.assertFalse(rules_a[2]["triggered"])
        self.assertFalse(rules_a[3]["triggered"])
        self.assertTrue(rules_a[4]["triggered"])
        self.assertTrue(rules_a[5]["triggered"])

        # Case B: One language just under 20% (19/100 on TS, 20/100 on Py & Swift)
        # -> Rule 2 TRIGGERED, Rule 4 NOT triggered
        m_under20 = make_summary_map(pub_same=(20, 20, 19), mgf_same=(10, 10, 10))
        rules_b = {r["rule_id"]: r for r in report.evaluate_decision_rules(m_under20)}
        self.assertTrue(rules_b[2]["triggered"])
        self.assertFalse(rules_b[4]["triggered"])

        # Case C: Rule 3 with Swift skipped (real-world mergiraf 0.20.0 behavior)
        # -> Swift cell must contain "没跑", Rule 3 NOT triggered
        m_swift_skip = make_summary_map(
            pub_same=(1, 0, 0),
            denom=(330, 377, 611),
            mgf_same=(63, 0, 139),
            mgf_skipped=(0, 377, 0),
        )
        rules_c = {r["rule_id"]: r for r in report.evaluate_decision_rules(m_swift_skip)}
        self.assertFalse(rules_c[1]["triggered"])
        self.assertTrue(rules_c[2]["triggered"])
        self.assertFalse(rules_c[3]["triggered"])
        self.assertIn("没跑", rules_c[3]["per_lang"]["swift"])
        self.assertFalse(rules_c[4]["triggered"])
        self.assertTrue(rules_c[5]["triggered"])

        # Case D: All 3 languages supported by mergiraf, mergiraf >= published on all 3 and damaged=0
        # -> Rule 3 TRIGGERED, Rule 4 NOT triggered (even when published >= 20%)
        m_mgf_wins = make_summary_map(pub_same=(20, 20, 20), mgf_same=(20, 25, 30), mgf_damaged=(0, 0, 0))
        rules_d = {r["rule_id"]: r for r in report.evaluate_decision_rules(m_mgf_wins)}
        self.assertTrue(rules_d[3]["triggered"])
        self.assertFalse(rules_d[4]["triggered"])

        # Case E: Mergiraf has damaged > 0 -> Rule 3 NOT triggered
        m_mgf_dmg = make_summary_map(pub_same=(20, 20, 20), mgf_same=(30, 30, 30), mgf_damaged=(0, 1, 0))
        rules_e = {r["rule_id"]: r for r in report.evaluate_decision_rules(m_mgf_dmg)}
        self.assertFalse(rules_e[3]["triggered"])
        self.assertTrue(rules_e[4]["triggered"])

        # Case F: Published has damaged=1 -> Rule 1 TRIGGERED, Rule 4 NOT triggered
        m_pub_dmg = make_summary_map(pub_same=(25, 25, 25), pub_damaged=(1, 0, 0), mgf_same=(10, 10, 10))
        rules_f = {r["rule_id"]: r for r in report.evaluate_decision_rules(m_pub_dmg)}
        self.assertTrue(rules_f[1]["triggered"])
        self.assertFalse(rules_f[4]["triggered"])

        # Also verify rendered conclusion section in mini fixture never prescribes "建议删" or "建议留"
        fx = self._build_mini_fixture(drop_right_line_in_c1=False)
        self._run_generate(fx)
        with open(fx["md"], encoding="utf-8") as fh:
            md_text = fh.read()
        self.assertIn("## 去留结论", md_text)
        conclusion_sec = md_text.split("## 去留结论", 1)[1]
        self.assertNotIn("建议删", conclusion_sec)
        self.assertNotIn("建议留", conclusion_sec)


if __name__ == "__main__":
    unittest.main()
