#!/usr/bin/env python3
"""Unit tests for Scripts/eval/merge-corpus/classify.py.

Covers:
  - All five classification categories:
      1. same (byte-identical to human/reference, passes fixed parser, no conflict markers)
      2. clean_different (passes fixed parser, differs from human; tracks human_eq=left|right|none)
         + whitespace-insensitive subcount (clean_different_ws_equal) NOT counted in 'same'
      3. conflict (unclean exit / claimed_clean=0, non-3/4)
      4. rejected (exit code 3 or 4, listed individually with reason)
      5. damaged (claimed_clean=1, but fails fixed parser OR contains conflict markers, even inside comments/docstrings)
  - RST underline (======= without <<<<<<< / >>>>>>>) is NOT treated as a conflict marker
  - Per-language denominator exclusion when human version fails fixed parser (excluded_human_unparsable)
  - Missing RELAY_MERGE_CORPUS_DIR / RELAY_EVAL_PYTHON / RELAY_EVAL_TYPESCRIPT -> prints "没跑：..." and exits 2
  - git merge-file self-check: 100% conflict on conflict set, 100% clean on clean set; fails if violated
  - Clean regression set classification (compared against git merge-file output, records git_parses on exit 3)
  - Fixed cases (merge-cases + syntax-gate-cases): reference selection (expected.*, git_clean, true_conflict),
    CLASSIFIED.tsv writing and --check-classified verification, empty engine column in Stage 2 and
    populated engine column when --engine-tsv is provided (including case-19 blank-line diff and case-09 syntax damage)
Python 3.9 compatible, standard library only.
"""
import csv
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CLASSIFY_PY = os.path.join(SCRIPT_DIR, "classify.py")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import classify  # noqa: E402

CASES_HEADER = [
    "case_id",
    "kind",
    "language",
    "repo",
    "merge",
    "p1",
    "p2",
    "base",
    "path",
    "blob_base",
    "blob_left",
    "blob_right",
    "blob_human",
    "myers_conflicts",
    "histogram_conflicts",
    "pure_insertion",
    "human_eq",
    "human_parses",
]


def _make_mock_parsers(root):
    """Creates portable mock Python >=3.12 and TypeScript modules in `root` when env vars are unset."""
    mock_py = os.path.join(root, "mock-python314.sh")
    with open(mock_py, "w", encoding="utf-8") as fh:
        fh.write(
            "#!/bin/sh\n"
            "for arg in \"$@\"; do\n"
            "  case \"$arg\" in\n"
            "    *version_info*)\n"
            "      echo '3.14.0'\n"
            "      exit 0\n"
            "      ;;\n"
            "  esac\n"
            "done\n"
            "exec /usr/bin/python3 \"$@\"\n"
        )
    os.chmod(mock_py, stat.S_IRWXU)

    mock_ts_dir = os.path.join(root, "mock_ts")
    os.makedirs(mock_ts_dir, exist_ok=True)
    with open(os.path.join(mock_ts_dir, "index.js"), "w", encoding="utf-8") as fh:
        fh.write(
            "exports.version = '5.9.3-mock';\n"
            "exports.ScriptTarget = { Latest: 99 };\n"
            "exports.ScriptKind = { JS: 1, JSX: 2, TS: 3, TSX: 4 };\n"
            "exports.createSourceFile = function(name, text, target, setParent, kind) {\n"
            "  if (text.indexOf('SYNTAX_ERROR') !== -1 || text.indexOf('function broken(') !== -1) {\n"
            "    return { parseDiagnostics: [{ messageText: 'Mock TS syntax error' }] };\n"
            "  }\n"
            "  return { parseDiagnostics: [] };\n"
            "};\n"
        )
    return mock_py, mock_ts_dir


def _write_bytes(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(data)


def _make_case_row(
    case_id,
    kind,
    language,
    rel_path,
    myers_conflicts,
    human_eq="none",
    human_parses="1",
    pure_insertion="0",
):
    return {
        "case_id": case_id,
        "kind": kind,
        "language": language,
        "repo": "example/repo",
        "merge": "1" * 40,
        "p1": "2" * 40,
        "p2": "3" * 40,
        "base": "4" * 40,
        "path": rel_path,
        "blob_base": "a" * 40,
        "blob_left": "b" * 40,
        "blob_right": "c" * 40,
        "blob_human": "d" * 40,
        "myers_conflicts": str(myers_conflicts),
        "histogram_conflicts": str(myers_conflicts),
        "pure_insertion": str(pure_insertion),
        "human_eq": human_eq,
        "human_parses": str(human_parses),
    }


def _write_cases_tsv(path, rows):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=CASES_HEADER, delimiter="\t", lineterminator="\n")
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


class MergeCorpusClassifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp_root = tempfile.mkdtemp(prefix="relayide-m3-classify-test.")
        cls.mock_py, cls.mock_ts = _make_mock_parsers(cls.tmp_root)
        cls.eval_python = os.environ.get("RELAY_EVAL_PYTHON") or cls.mock_py
        cls.eval_ts = os.environ.get("RELAY_EVAL_TYPESCRIPT") or cls.mock_ts

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp_root, ignore_errors=True)

    def _parser_env(self, corpus_dir=None):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.tmp_root,
            "RELAY_EVAL_PYTHON": self.eval_python,
            "RELAY_EVAL_TYPESCRIPT": self.eval_ts,
        }
        if corpus_dir is not None:
            env["RELAY_MERGE_CORPUS_DIR"] = corpus_dir
        return env

    def test_helpers_ws_and_conflict_markers(self):
        # Whitespace normalization strips blank lines and trailing spaces/tabs/CR
        a = b"def f():  \r\n\r\n    return 1\t\r\n\n"
        b = b"def f():\n    return 1\n"
        self.assertEqual(classify.normalize_ws(a), classify.normalize_ws(b))
        self.assertFalse(classify.is_same_as_reference(a, b))
        self.assertTrue(classify.is_same_as_reference(b, b))
        self.assertFalse(classify.is_same_as_reference(b, None))

        # RST docstring underline ======= alone is NOT a conflict marker
        rst_doc = b'"""\nTitle\n=======\n\nBody.\n"""\ndef ok():\n    return 1\n'
        self.assertFalse(classify.has_conflict_markers(rst_doc))

        # Python doctest >>> is NOT a conflict marker
        doctest_doc = b'"""\n>>> 1 + 1\n2\n"""\n'
        self.assertFalse(classify.has_conflict_markers(doctest_doc))

        # Standard LF and CRLF and >7-char conflict markers ARE detected even inside comments/docstrings
        lf_marker = b'"""\n<<<<<<< left\nfoo\n=======\nbar\n>>>>>>> right\n"""\nx = 1\n'
        crlf_marker = b"<<<<<<< left\r\nx = 1\r\n=======\r\nx = 2\r\n>>>>>>> right\r\n"
        long_marker = b"<<<<<<<<<< HEAD\nx = 1\n==========\nx = 2\n>>>>>>>>>> branch\n"
        self.assertTrue(classify.has_conflict_markers(lf_marker))
        self.assertTrue(classify.has_conflict_markers(crlf_marker))
        self.assertTrue(classify.has_conflict_markers(long_marker))

    def test_missing_env_vars_exit_2_without_fallback(self):
        work = tempfile.mkdtemp(dir=self.tmp_root)
        cases_tsv = os.path.join(work, "cases.tsv")
        _write_cases_tsv(cases_tsv, [_make_case_row("c00001", "conflict", "python", "a.py", 1)])
        _write_bytes(os.path.join(work, "corpus/extract/cases/c00001/base.py"), b"x = 0\n")
        _write_bytes(os.path.join(work, "corpus/extract/cases/c00001/left.py"), b"x = 1\n")
        _write_bytes(os.path.join(work, "corpus/extract/cases/c00001/right.py"), b"x = 2\n")
        _write_bytes(os.path.join(work, "corpus/extract/cases/c00001/human.py"), b"x = 1\n")

        # 1. Missing RELAY_MERGE_CORPUS_DIR -> exit 2 with "没跑"
        env_no_corpus = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.tmp_root,
            "RELAY_EVAL_PYTHON": self.eval_python,
            "RELAY_EVAL_TYPESCRIPT": self.eval_ts,
        }
        p1 = subprocess.run(
            ["/usr/bin/python3", "-I", CLASSIFY_PY, "--cases-tsv", cases_tsv],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env_no_corpus,
        )
        self.assertEqual(p1.returncode, 2)
        self.assertIn("没跑", p1.stdout + p1.stderr)

        # 2. Missing RELAY_EVAL_PYTHON -> exit 2 with "没跑" (must not fall back to PATH python3)
        env_no_py = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.tmp_root,
            "RELAY_MERGE_CORPUS_DIR": os.path.join(work, "corpus"),
            "RELAY_EVAL_TYPESCRIPT": self.eval_ts,
        }
        p2 = subprocess.run(
            ["/usr/bin/python3", "-I", CLASSIFY_PY, "--cases-tsv", cases_tsv],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env_no_py,
        )
        self.assertEqual(p2.returncode, 2)
        self.assertIn("没跑", p2.stdout + p2.stderr)

        # 3. Missing RELAY_EVAL_TYPESCRIPT when TS case present -> exit 2 with "没跑"
        cases_ts = os.path.join(work, "cases_ts.tsv")
        _write_cases_tsv(cases_ts, [_make_case_row("c00002", "conflict", "typescript", "a.ts", 1)])
        _write_bytes(os.path.join(work, "corpus/extract/cases/c00002/base.ts"), b"export const x = 0;\n")
        _write_bytes(os.path.join(work, "corpus/extract/cases/c00002/left.ts"), b"export const x = 1;\n")
        _write_bytes(os.path.join(work, "corpus/extract/cases/c00002/right.ts"), b"export const x = 2;\n")
        _write_bytes(os.path.join(work, "corpus/extract/cases/c00002/human.ts"), b"export const x = 1;\n")
        env_no_ts = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.tmp_root,
            "RELAY_MERGE_CORPUS_DIR": os.path.join(work, "corpus"),
            "RELAY_EVAL_PYTHON": self.eval_python,
        }
        p3 = subprocess.run(
            ["/usr/bin/python3", "-I", CLASSIFY_PY, "--cases-tsv", cases_ts],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env_no_ts,
        )
        self.assertEqual(p3.returncode, 2)
        self.assertIn("没跑", p3.stdout + p3.stderr)

    def test_five_categories_subcounts_and_denominator_exclusion(self):
        work = tempfile.mkdtemp(dir=self.tmp_root)
        corpus_dir = os.path.join(work, "corpus")
        out_dir = os.path.join(work, "tool_out")
        os.makedirs(out_dir, exist_ok=True)

        rows = []

        def add_conflict_case(cid, lang, ext, base_b, left_b, right_b, human_b, human_eq="none", human_parses="1"):
            cdir = os.path.join(corpus_dir, "extract/cases", cid)
            _write_bytes(os.path.join(cdir, "base" + ext), base_b)
            _write_bytes(os.path.join(cdir, "left" + ext), left_b)
            _write_bytes(os.path.join(cdir, "right" + ext), right_b)
            _write_bytes(os.path.join(cdir, "human" + ext), human_b)
            rows.append(_make_case_row(cid, "conflict", lang, "src/" + cid + ext, 1, human_eq=human_eq, human_parses=human_parses))

        # c00001 (Python): SAME — byte-identical to human (also contains RST ======= underline, must not be flagged damaged)
        human_1 = b'"""\nHeader\n=======\n"""\ndef alpha():\n    return 1\n\n\ndef beta():\n    return 2\n'
        add_conflict_case(
            "c00001", "python", ".py",
            b"def base():\n    return 0\n",
            b"def alpha():\n    return 1\n",
            b"def beta():\n    return 2\n",
            human_1,
        )
        _write_bytes(os.path.join(out_dir, "c00001.py"), human_1)

        # c00002 (Python): CLEAN_DIFFERENT (ws_equal=1, human_eq=right) — differs ONLY by blank lines & trailing space!
        # Must NOT be counted in 'same'! (Mutation D targets this exact assertion!)
        human_2 = b"def a():\n    return 1\n\n\ndef b():\n    return 2\n"
        out_2_ws_only = b"def a():   \n    return 1\n\ndef b():\n    return 2\n"
        add_conflict_case(
            "c00002", "python", ".py",
            b"def a():\n    return 0\n",
            b"def a():\n    return 10\n",
            human_2,
            human_2,
            human_eq="right",
        )
        _write_bytes(os.path.join(out_dir, "c00002.py"), out_2_ws_only)

        # c00003 (Python): CLEAN_DIFFERENT (ws_equal=0, human_eq=left) — valid Python, semantically different from human
        left_3 = b"def f():\n    return 'left'\n"
        add_conflict_case(
            "c00003", "python", ".py",
            b"def f():\n    return 'base'\n",
            left_3,
            b"def f():\n    return 'right'\n",
            left_3,
            human_eq="left",
        )
        _write_bytes(os.path.join(out_dir, "c00003.py"), b"def f():\n    return 'both'\n")

        # c00004 (Python): CONFLICT — tool exits 1, claimed_clean=0
        add_conflict_case(
            "c00004", "python", ".py",
            b"x = 0\n", b"x = 1\n", b"x = 2\n", b"x = 3\n",
        )

        # c00005 (Python): REJECTED (exit 3) — single-listed with reason
        add_conflict_case(
            "c00005", "python", ".py",
            b"y = 0\n", b"y = 1\n", b"y = 2\n", b"y = 3\n",
        )

        # c00006 (TypeScript): REJECTED (exit 4) — single-listed with reason
        add_conflict_case(
            "c00006", "typescript", ".ts",
            b"export const z = 0;\r\n",
            b"export const z = 1;\r\n",
            b"export const z = 2;\r\n",
            b"export const z = 1;\r\n",
            human_eq="left",
        )

        # c00007 (Python): DAMAGED (syntax error) — claimed_clean=1, fails fixed parser, differs from human
        # (Mutation E targets this exact assertion: would flip from 'damaged' to 'clean_different'!)
        add_conflict_case(
            "c00007", "python", ".py",
            b"k = 0\n", b"k = 1\n", b"k = 2\n", b"k = 3\n",
        )
        _write_bytes(os.path.join(out_dir, "c00007.py"), b"def broken(:\n    pass\n")

        # c00008 (TypeScript): DAMAGED (conflict markers inside JSDoc comment!) — passes TS parser, has markers!
        add_conflict_case(
            "c00008", "typescript", ".ts",
            b"export const m = 0;\n",
            b"export const m = 1;\n",
            b"export const m = 2;\n",
            b"export const m = 3;\n",
        )
        _write_bytes(
            os.path.join(out_dir, "c00008.ts"),
            b"/**\n<<<<<<< left\n * left doc\n=======\n * right doc\n>>>>>>> right\n */\nexport const m = 3;\n",
        )

        # c00009 (Python): EXCLUDED — human.py has legacy Python 2 syntax (print "legacy") that fails Python 3 parser!
        add_conflict_case(
            "c00009", "python", ".py",
            b"a = 0\n", b"a = 1\n", b"a = 2\n", b'def legacy(:\n    pass\n',
            human_parses="0",
        )
        _write_bytes(os.path.join(out_dir, "c00009.py"), b"a = 1\n")

        # c00010 (Swift): EXCLUDED — human.swift fails swiftc -frontend -parse, plus c00011 (Swift): SAME
        add_conflict_case(
            "c00010", "swift", ".swift",
            b"let s = 0\n", b"let s = 1\n", b"let s = 2\n", b"func broken_swift( {\n",
            human_parses="0",
        )
        add_conflict_case(
            "c00011", "swift", ".swift",
            b"let s = 0\n", b"let s = 1\n", b"let s = 2\n", b"let s = 1\nlet t = 2\n",
        )
        _write_bytes(os.path.join(out_dir, "c00011.swift"), b"let s = 1\nlet t = 2\n")

        cases_tsv = os.path.join(work, "cases.tsv")
        _write_cases_tsv(cases_tsv, rows)

        tool_tsv = os.path.join(work, "sample_tool.tsv")
        with open(tool_tsv, "w", encoding="utf-8") as fh:
            fh.write("case_id\texit_code\tclaimed_clean\toutput_path\treason\n")
            fh.write(f"c00001\t0\t1\t{os.path.join(out_dir, 'c00001.py')}\tstrategy=declaration-level\n")
            fh.write(f"c00002\t0\t1\t{os.path.join(out_dir, 'c00002.py')}\tstrategy=declaration-level\n")
            fh.write(f"c00003\t0\t1\t{os.path.join(out_dir, 'c00003.py')}\tstrategy=declaration-level\n")
            fh.write("c00004\t1\t0\t\tunresolved conflict\n")
            fh.write("c00005\t3\t0\t\texit=3: syntax_check_failed (python3 -m py_compile)\n")
            fh.write("c00006\t4\t0\t\texit=4: line_merge_unavailable (CRLF conflict markers)\n")
            fh.write(f"c00007\t0\t1\t{os.path.join(out_dir, 'c00007.py')}\tclaimed clean\n")
            fh.write(f"c00008\t0\t1\t{os.path.join(out_dir, 'c00008.ts')}\tclaimed clean\n")
            fh.write(f"c00009\t0\t1\t{os.path.join(out_dir, 'c00009.py')}\tclaimed clean\n")
            fh.write("c00010\t1\t0\t\tconflict\n")
            fh.write(f"c00011\t0\t1\t{os.path.join(out_dir, 'c00011.swift')}\tstrategy=declaration-level\n")

        env = self._parser_env(corpus_dir=corpus_dir)
        res = classify.classify_corpus(
            cases_tsv=cases_tsv,
            corpus_dir=corpus_dir,
            tool_specs=[("sample_tool", tool_tsv)],
            kinds=("conflict",),
            env=env,
        )
        self.assertTrue(res["git_selfcheck_ok"], msg=str(res.get("git_selfcheck_errors")))

        by_key = {(r["kind"], r["language"], r["tool"]): r for r in res["summary_rows"]}

        # Check git self-check row: 100% conflict on every language's denominator
        self.assertEqual(by_key[("conflict", "python", "git")]["denominator"], 6)
        self.assertEqual(by_key[("conflict", "python", "git")]["excluded_human_unparsable"], 1)
        self.assertEqual(by_key[("conflict", "python", "git")]["conflict"], 6)
        self.assertEqual(by_key[("conflict", "swift", "git")]["denominator"], 1)
        self.assertEqual(by_key[("conflict", "swift", "git")]["excluded_human_unparsable"], 1)
        self.assertEqual(by_key[("conflict", "swift", "git")]["conflict"], 1)
        self.assertEqual(by_key[("conflict", "typescript", "git")]["denominator"], 2)
        self.assertEqual(by_key[("conflict", "typescript", "git")]["excluded_human_unparsable"], 0)
        self.assertEqual(by_key[("conflict", "typescript", "git")]["conflict"], 2)

        # Check Python sample_tool counts (6 in denominator, 1 excluded):
        # c00001=same, c00002=clean_different (ws_equal, human_eq=right), c00003=clean_different (human_eq=left),
        # c00004=conflict, c00005=rejected, c00007=damaged
        py = by_key[("conflict", "python", "sample_tool")]
        self.assertEqual(py["total_cases"], 7)
        self.assertEqual(py["excluded_human_unparsable"], 1)
        self.assertEqual(py["denominator"], 6)
        self.assertEqual(py["same"], 1)
        self.assertEqual(py["clean_different"], 2)
        self.assertEqual(py["clean_different_ws_equal"], 1)
        self.assertEqual(py["clean_different_human_eq_left"], 1)
        self.assertEqual(py["clean_different_human_eq_right"], 1)
        self.assertEqual(py["clean_different_human_eq_none"], 0)
        self.assertEqual(py["conflict"], 1)
        self.assertEqual(py["rejected"], 1)
        self.assertEqual(py["damaged"], 1)

        # Check TypeScript sample_tool counts: c00006=rejected (exit 4), c00008=damaged (conflict markers in JSDoc)
        ts = by_key[("conflict", "typescript", "sample_tool")]
        self.assertEqual(ts["denominator"], 2)
        self.assertEqual(ts["same"], 0)
        self.assertEqual(ts["clean_different"], 0)
        self.assertEqual(ts["rejected"], 1)
        self.assertEqual(ts["damaged"], 1)

        # Check Swift sample_tool counts: c00010 excluded, c00011=same
        sw = by_key[("conflict", "swift", "sample_tool")]
        self.assertEqual(sw["total_cases"], 2)
        self.assertEqual(sw["excluded_human_unparsable"], 1)
        self.assertEqual(sw["denominator"], 1)
        self.assertEqual(sw["same"], 1)

        # Check individual rejected list ("拒绝单列并写明原因")
        rej = res["rejected_rows"]
        self.assertEqual(len(rej), 2)
        rej_by_id = {r["case_id"]: r for r in rej}
        self.assertEqual(int(rej_by_id["c00005"]["exit_code"]), 3)
        self.assertIn("syntax_check_failed", rej_by_id["c00005"]["reason"])
        self.assertEqual(int(rej_by_id["c00006"]["exit_code"]), 4)
        self.assertIn("CRLF", rej_by_id["c00006"]["reason"])

        # Also verify CLI writes summary, details, and rejected TSV files cleanly
        summary_out = os.path.join(work, "summary.tsv")
        details_out = os.path.join(work, "details.tsv")
        rejected_out = os.path.join(work, "rejected.tsv")
        proc = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                CLASSIFY_PY,
                "--cases-tsv",
                cases_tsv,
                "--kinds",
                "conflict",
                "--tool",
                "sample_tool=" + tool_tsv,
                "--summary-out",
                summary_out,
                "--details-out",
                details_out,
                "--rejected-out",
                rejected_out,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0, msg=proc.stderr + "\n" + proc.stdout)
        self.assertTrue(os.path.isfile(summary_out))
        self.assertTrue(os.path.isfile(details_out))
        self.assertTrue(os.path.isfile(rejected_out))
        with open(rejected_out, encoding="utf-8") as fh:
            rej_csv = list(csv.DictReader(fh, delimiter="\t"))
        self.assertEqual([r["case_id"] for r in rej_csv], ["c00005", "c00006"])

    def test_git_selfcheck_and_clean_regression(self):
        work = tempfile.mkdtemp(dir=self.tmp_root)
        corpus_dir = os.path.join(work, "corpus")
        out_dir = os.path.join(work, "out")
        os.makedirs(out_dir, exist_ok=True)

        # k00001: git clean merge (left edits line 1, right edits line 3); human tweaked a comment so git != human
        base_k1 = b"a = 1\nb = 2\nc = 3\n"
        left_k1 = b"a = 10\nb = 2\nc = 3\n"
        right_k1 = b"a = 1\nb = 2\nc = 30\n"
        git_k1 = b"a = 10\nb = 2\nc = 30\n"
        human_k1 = b"# human note\na = 10\nb = 2\nc = 30\n"

        # k00002: git clean merge where git == human
        base_k2 = b"x = 1\ny = 2\nz = 3\n"
        left_k2 = b"x = 11\ny = 2\nz = 3\n"
        right_k2 = b"x = 1\ny = 2\nz = 33\n"
        git_k2 = b"x = 11\ny = 2\nz = 33\n"

        for cid, b_b, l_b, r_b, h_b in (
            ("k00001", base_k1, left_k1, right_k1, human_k1),
            ("k00002", base_k2, left_k2, right_k2, git_k2),
        ):
            cdir = os.path.join(corpus_dir, "extract/cases", cid)
            _write_bytes(os.path.join(cdir, "base.py"), b_b)
            _write_bytes(os.path.join(cdir, "left.py"), l_b)
            _write_bytes(os.path.join(cdir, "right.py"), r_b)
            _write_bytes(os.path.join(cdir, "human.py"), h_b)

        cases_tsv = os.path.join(work, "cases.tsv")
        _write_cases_tsv(
            cases_tsv,
            [
                _make_case_row("k00001", "clean", "python", "k1.py", 0),
                _make_case_row("k00002", "clean", "python", "k2.py", 0),
            ],
        )

        # Tool matches git on k00001, rejects with exit 3 on k00002 (false rejection since git_k2 parses!)
        _write_bytes(os.path.join(out_dir, "k00001.py"), git_k1)
        tool_tsv = os.path.join(work, "cli.tsv")
        with open(tool_tsv, "w", encoding="utf-8") as fh:
            fh.write("case_id\texit_code\tclaimed_clean\toutput_path\treason\n")
            fh.write(f"k00001\t0\t1\t{os.path.join(out_dir, 'k00001.py')}\tline-level\n")
            fh.write("k00002\t3\t0\t\texit=3: syntax_check_failed (python3.9)\n")

        env = self._parser_env(corpus_dir=corpus_dir)
        res = classify.classify_corpus(
            cases_tsv=cases_tsv,
            corpus_dir=corpus_dir,
            tool_specs=[("cli", tool_tsv)],
            kinds=("clean",),
            env=env,
        )
        self.assertTrue(res["git_selfcheck_ok"])
        by_key = {(r["kind"], r["language"], r["tool"]): r for r in res["summary_rows"]}
        self.assertEqual(by_key[("clean", "python", "git")]["same"], 2)
        self.assertEqual(by_key[("clean", "python", "git")]["git_eq_human"], 1)
        self.assertEqual(by_key[("clean", "python", "cli")]["same"], 1)
        self.assertEqual(by_key[("clean", "python", "cli")]["rejected"], 1)
        self.assertEqual(res["rejected_rows"][0]["case_id"], "k00002")
        self.assertEqual(res["rejected_rows"][0]["git_parses"], "1")

        # Violating git self-check: marking a git-clean case as kind='conflict' with myers_conflicts=0 must fail!
        bad_cases_tsv = os.path.join(work, "bad_cases.tsv")
        _write_cases_tsv(
            bad_cases_tsv,
            [_make_case_row("k00001", "conflict", "python", "k1.py", 0)],
        )
        p_bad = subprocess.run(
            ["/usr/bin/python3", "-I", CLASSIFY_PY, "--cases-tsv", bad_cases_tsv, "--kinds", "conflict"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        self.assertEqual(p_bad.returncode, 1)
        self.assertIn("FAIL", p_bad.stdout + p_bad.stderr)

    def test_fixed_cases_and_engine_column(self):
        work = tempfile.mkdtemp(dir=self.tmp_root)
        mc_dir = os.path.join(work, "merge-cases")
        sg_dir = os.path.join(work, "syntax-gate-cases")
        eng_out_dir = os.path.join(work, "eng-out")
        os.makedirs(eng_out_dir, exist_ok=True)

        # 1) 09-like git-clean case: git=same, cli=same, engine=damaged (unparsable output!)
        c09 = os.path.join(mc_dir, "09-py-triplequote")
        _write_bytes(os.path.join(c09, "base.py"), b'DOC = """\nline1\nline2\n"""\nx = 1\n')
        _write_bytes(os.path.join(c09, "left.py"), b'DOC = """\nline1_left\nline2\n"""\nx = 1\n')
        _write_bytes(os.path.join(c09, "right.py"), b'DOC = """\nline1\nline2\n"""\nx = 2\n')
        git_09 = b'DOC = """\nline1_left\nline2\n"""\nx = 2\n'

        # 2) 19-like expected.* case: git=conflict, cli=same, engine=clean_different (missing blank line!)
        c19 = os.path.join(mc_dir, "19-py-both-add-toplevel")
        _write_bytes(os.path.join(c19, "base.py"), b"def a():\n    return 1\n")
        _write_bytes(os.path.join(c19, "left.py"), b"def a():\n    return 1\n\n\ndef from_left():\n    return 10\n")
        _write_bytes(os.path.join(c19, "right.py"), b"def a():\n    return 1\n\n\ndef from_right():\n    return 20\n")
        exp_19 = b"def a():\n    return 1\n\n\ndef from_left():\n    return 10\n\n\ndef from_right():\n    return 20\n"
        _write_bytes(os.path.join(c19, "expected.py"), exp_19)

        # 3) 12-like true_conflict case (no expected.*): git=conflict, cli=conflict, engine=clean_different if it claims clean
        c12 = os.path.join(mc_dir, "12-py-true-conflict")
        _write_bytes(os.path.join(c12, "base.py"), b"v = 0\n")
        _write_bytes(os.path.join(c12, "left.py"), b"v = 1\n")
        _write_bytes(os.path.join(c12, "right.py"), b"v = 2\n")

        # 4) syntax-gate case: git merges cleanly into invalid syntax -> git=damaged, cli=rejected (exit 3)
        csg = os.path.join(sg_dir, "python-string-delimiters")
        _write_bytes(os.path.join(csg, "base.py"), b"ALPHA = 1\nBETA = 2\nGAMMA = 3\nDELTA = 4\nEPSILON = 5\n")
        _write_bytes(os.path.join(csg, "left.py"), b'ALPHA = 1\nNOTES = """\nBETA = 2\nGAMMA = 3\nDELTA = 4\n"""\nEPSILON = 5\n')
        _write_bytes(os.path.join(csg, "right.py"), b'ALPHA = 1\nBETA = 2\nGAMMA = """three"""\nDELTA = 4\nEPSILON = 5\n')

        # Pre-recorded CLI outputs for fast synthetic test
        cli_out_dir = os.path.join(work, "cli-out")
        _write_bytes(os.path.join(cli_out_dir, "09.py"), git_09)
        _write_bytes(os.path.join(cli_out_dir, "19.py"), exp_19)
        cli_tsv = os.path.join(work, "cli_fixed.tsv")
        with open(cli_tsv, "w", encoding="utf-8") as fh:
            fh.write("case_id\texit_code\tclaimed_clean\toutput_path\treason\tstrategy\n")
            fh.write(f"merge-cases/09-py-triplequote\t0\t1\t{os.path.join(cli_out_dir, '09.py')}\t\tline-level\n")
            fh.write("merge-cases/12-py-true-conflict\t1\t0\t\t\tnone\n")
            fh.write(f"merge-cases/19-py-both-add-toplevel\t0\t1\t{os.path.join(cli_out_dir, '19.py')}\t\tdeclaration-level\n")
            fh.write("syntax-gate-cases/python-string-delimiters\t3\t0\t\texit=3: syntax_check_failed (python3 -m py_compile)\t-\n")

        env = self._parser_env()
        classified_path = os.path.join(work, "CLASSIFIED.tsv")

        # Stage 2 mode (no engine_tsv): engine column is empty ""
        p_write = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                CLASSIFY_PY,
                "--fixed-cases",
                "--merge-cases-dir",
                mc_dir,
                "--syntax-gate-dir",
                sg_dir,
                "--cli-tsv",
                cli_tsv,
                "--write-classified",
                classified_path,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        self.assertEqual(p_write.returncode, 0, msg=p_write.stderr + "\n" + p_write.stdout)

        with open(classified_path, encoding="utf-8") as fh:
            cls_rows = {r["case_id"]: r for r in csv.DictReader(fh, delimiter="\t")}
        self.assertEqual(len(cls_rows), 4)
        self.assertEqual(cls_rows["merge-cases/09-py-triplequote"]["git"], "same")
        self.assertEqual(cls_rows["merge-cases/09-py-triplequote"]["cli"], "same")
        self.assertEqual(cls_rows["merge-cases/09-py-triplequote"]["engine"], "")
        self.assertEqual(cls_rows["merge-cases/19-py-both-add-toplevel"]["git"], "conflict")
        self.assertEqual(cls_rows["merge-cases/19-py-both-add-toplevel"]["cli"], "same")
        self.assertEqual(cls_rows["merge-cases/12-py-true-conflict"]["reference"], "true_conflict")
        self.assertEqual(cls_rows["merge-cases/12-py-true-conflict"]["cli"], "conflict")
        self.assertEqual(cls_rows["syntax-gate-cases/python-string-delimiters"]["git"], "damaged")
        self.assertEqual(cls_rows["syntax-gate-cases/python-string-delimiters"]["cli"], "rejected")

        # --check-classified passes when unchanged
        p_chk_ok = subprocess.run(
            [
                "/usr/bin/python3",
                "-I",
                CLASSIFY_PY,
                "--fixed-cases",
                "--merge-cases-dir",
                mc_dir,
                "--syntax-gate-dir",
                sg_dir,
                "--cli-tsv",
                cli_tsv,
                "--check-classified",
                classified_path,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )
        self.assertEqual(p_chk_ok.returncode, 0, msg=p_chk_ok.stderr + "\n" + p_chk_ok.stdout)

        # Stage 4 mode (with engine_tsv): 09 -> damaged, 19 -> clean_different (only blank lines differ!)
        _write_bytes(os.path.join(eng_out_dir, "09.py"), b'DOC = """\nunterminated\nx = 2\n')
        _write_bytes(
            os.path.join(eng_out_dir, "19.py"),
            b"def a():\n    return 1\n\ndef from_left():\n    return 10\n\ndef from_right():\n    return 20\n",
        )
        eng_tsv = os.path.join(work, "engine_fixed.tsv")
        with open(eng_tsv, "w", encoding="utf-8") as fh:
            fh.write("case_id\texit_code\tclaimed_clean\toutput_path\n")
            fh.write(f"merge-cases/09-py-triplequote\t0\t1\t{os.path.join(eng_out_dir, '09.py')}\n")
            fh.write("merge-cases/12-py-true-conflict\t1\t0\t\n")
            fh.write(f"merge-cases/19-py-both-add-toplevel\t0\t1\t{os.path.join(eng_out_dir, '19.py')}\n")
            fh.write("syntax-gate-cases/python-string-delimiters\t1\t0\t\n")

        res_eng = classify.classify_fixed_cases(
            merge_cases_dir=mc_dir,
            syntax_gate_dir=sg_dir,
            cli_tsv=cli_tsv,
            engine_tsv=eng_tsv,
            env=env,
        )
        eng_rows = {r["case_id"]: r for r in res_eng["rows"]}
        self.assertEqual(eng_rows["merge-cases/09-py-triplequote"]["engine"], "damaged")
        self.assertEqual(eng_rows["merge-cases/19-py-both-add-toplevel"]["engine"], "clean_different")
        self.assertEqual(eng_rows["merge-cases/12-py-true-conflict"]["engine"], "conflict")

    def test_ws_only_diff_is_clean_different_not_same(self):
        """Dedicated check for Mutation D: blank-line/trailing-space difference stays 'clean_different', never 'same'."""
        work = tempfile.mkdtemp(dir=self.tmp_root)
        corpus_dir = os.path.join(work, "corpus")
        cdir = os.path.join(corpus_dir, "extract/cases/c00001")
        human_b = b"def a():\n    return 1\n\n\ndef b():\n    return 2\n"
        ws_diff_b = b"def a():\n    return 1\n\ndef b():\n    return 2\n"
        _write_bytes(os.path.join(cdir, "base.py"), b"def a():\n    return 0\n")
        _write_bytes(os.path.join(cdir, "left.py"), b"def a():\n    return 1\n")
        _write_bytes(os.path.join(cdir, "right.py"), b"def b():\n    return 2\n")
        _write_bytes(os.path.join(cdir, "human.py"), human_b)

        cases_tsv = os.path.join(work, "cases.tsv")
        _write_cases_tsv(cases_tsv, [_make_case_row("c00001", "conflict", "python", "m.py", 1)])
        out_p = os.path.join(work, "out.py")
        _write_bytes(out_p, ws_diff_b)
        tool_tsv = os.path.join(work, "tool.tsv")
        with open(tool_tsv, "w", encoding="utf-8") as fh:
            fh.write(f"c00001\t0\t1\t{out_p}\t\n")

        res = classify.classify_corpus(
            cases_tsv=cases_tsv,
            corpus_dir=corpus_dir,
            tool_specs=[("probe", tool_tsv)],
            kinds=("conflict",),
            env=self._parser_env(corpus_dir=corpus_dir),
        )
        probe_detail = [r for r in res["detail_rows"] if r["tool"] == "probe"][0]
        self.assertEqual(probe_detail["category"], "clean_different")
        self.assertEqual(probe_detail["ws_equal"], "1")

    def test_unparsable_output_is_damaged_not_clean_different(self):
        """Dedicated check for Mutation E: unparsable claimed-clean output stays 'damaged', never 'clean_different'."""
        work = tempfile.mkdtemp(dir=self.tmp_root)
        corpus_dir = os.path.join(work, "corpus")
        cdir = os.path.join(corpus_dir, "extract/cases/c00001")
        _write_bytes(os.path.join(cdir, "base.py"), b"x = 0\n")
        _write_bytes(os.path.join(cdir, "left.py"), b"x = 1\n")
        _write_bytes(os.path.join(cdir, "right.py"), b"x = 2\n")
        _write_bytes(os.path.join(cdir, "human.py"), b"x = 3\n")

        cases_tsv = os.path.join(work, "cases.tsv")
        _write_cases_tsv(cases_tsv, [_make_case_row("c00001", "conflict", "python", "m.py", 1)])
        out_p = os.path.join(work, "broken.py")
        _write_bytes(out_p, b"def broken(:\n    pass\n")
        tool_tsv = os.path.join(work, "tool.tsv")
        with open(tool_tsv, "w", encoding="utf-8") as fh:
            fh.write(f"c00001\t0\t1\t{out_p}\t\n")

        res = classify.classify_corpus(
            cases_tsv=cases_tsv,
            corpus_dir=corpus_dir,
            tool_specs=[("probe", tool_tsv)],
            kinds=("conflict",),
            env=self._parser_env(corpus_dir=corpus_dir),
        )
        probe_detail = [r for r in res["detail_rows"] if r["tool"] == "probe"][0]
        self.assertEqual(probe_detail["category"], "damaged")


if __name__ == "__main__":
    unittest.main()
