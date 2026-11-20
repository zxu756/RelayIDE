#!/usr/bin/env python3
"""Unit tests for Scripts/eval/merge-eval/run_engine.py.

Uses a synthetic mini-corpus and a fake executable engine script (Python) in a temporary
directory — never invokes the real Swift engine binary. Covers:
  - Clean merge (exit 0 -> claimed_clean=1, verbatim output saved)
  - Conflict merge (exit 1 -> claimed_clean=0, output_path="")
  - Per-case wall-clock timeout (exit 124 -> claimed_clean=0, reason="timeout")
  - results.tsv column contract & compatibility with classify.load_tool_tsv
  - --quick (20 conflict + 20 clean per language), --languages, --kinds, --append ordering
  - --fixed-cases mode across synthetic merge-cases + syntax-gate-cases
  - env.txt metadata (engine_bin, sha256, repo_commit, timestamps, elapsed_seconds, timeout_count)
  - Missing RELAY_MERGE_CORPUS_DIR / missing engine binary -> exit 2
"""
import csv
import os
import stat
import sys
import tempfile
import textwrap
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
MERGE_CORPUS_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, "../merge-corpus"))
for _p in (SCRIPT_DIR, MERGE_CORPUS_DIR):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import classify  # noqa: E402
import run_engine  # noqa: E402


CASES_FIELDS = [
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


def _make_executable(path, content):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(content)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class RunEngineTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="relay-test-run-eng.")
        self.work = self._tmp.name
        self.corpus_dir = os.path.join(self.work, "corpus")
        self.cases_root = os.path.join(self.corpus_dir, "extract", "cases")
        os.makedirs(self.cases_root, exist_ok=True)
        self.fake_home = os.path.join(self.work, "fake-home")
        os.makedirs(self.fake_home, exist_ok=True)

        self.fake_engine = os.path.join(self.work, "fake_engine.py")
        _make_executable(
            self.fake_engine,
            textwrap.dedent(
                """\
                #!/usr/bin/python3
                import sys
                import time

                args = sys.argv[1:]
                rel_path = None
                out_path = None
                pos = []
                i = 0
                while i < len(args):
                    if args[i] == "--path" and i + 1 < len(args):
                        rel_path = args[i + 1]
                        i += 2
                    elif args[i] == "-o" and i + 1 < len(args):
                        out_path = args[i + 1]
                        i += 2
                    else:
                        pos.append(args[i])
                        i += 1

                if len(pos) != 3 or not rel_path or not out_path:
                    sys.stderr.write(f"bad args: {args!r}\\n")
                    sys.exit(2)

                marker = open(pos[0], "rb").read()
                if b"MODE:CLEAN" in marker:
                    with open(out_path, "wb") as fh:
                        fh.write(b"def merged():\\r\\n    return 42\\r\\n")
                    sys.exit(0)
                if b"MODE:CONFLICT" in marker:
                    sys.stderr.write("conflict: unresolved=1\\n")
                    sys.exit(1)
                if b"MODE:TIMEOUT" in marker:
                    time.sleep(10.0)
                    sys.exit(0)
                if b"MODE:ERROR" in marker:
                    sys.stderr.write("File /tmp/secret_tmp/in.py bad utf8\\n")
                    sys.exit(2)

                with open(out_path, "wb") as fh:
                    fh.write(b"default_engine_clean\\n")
                sys.exit(0)
                """
            ),
        )
        self.cases_tsv = os.path.join(self.work, "cases.tsv")

    def tearDown(self):
        self._tmp.cleanup()

    def _write_cases(self, specs):
        rows = []
        for cid, kind, lang, rel_path, mode_bytes in specs:
            ext = "." + rel_path.rsplit(".", 1)[1]
            cdir = os.path.join(self.cases_root, cid)
            os.makedirs(cdir, exist_ok=True)
            for role in ("base", "left", "right", "human"):
                with open(os.path.join(cdir, role + ext), "wb") as fh:
                    fh.write(mode_bytes if role == "base" else b"# placeholder\n")
            rows.append(
                {
                    "case_id": cid,
                    "kind": kind,
                    "language": lang,
                    "repo": "org/repo",
                    "merge": "1" * 40,
                    "p1": "2" * 40,
                    "p2": "3" * 40,
                    "base": "4" * 40,
                    "path": rel_path,
                    "blob_base": "a" * 40,
                    "blob_left": "b" * 40,
                    "blob_right": "c" * 40,
                    "blob_human": "d" * 40,
                    "myers_conflicts": "1" if kind == "conflict" else "0",
                    "histogram_conflicts": "1" if kind == "conflict" else "0",
                    "pure_insertion": "0",
                    "human_eq": "none",
                    "human_parses": "1",
                }
            )
        with open(self.cases_tsv, "w", encoding="utf-8", newline="") as fh:
            writer = csv.DictWriter(fh, fieldnames=CASES_FIELDS, delimiter="\t", lineterminator="\n")
            writer.writeheader()
            for r in rows:
                writer.writerow(r)

    def _base_env(self):
        return {
            "PATH": "/usr/bin:/bin",
            "HOME": self.fake_home,
            "RELAY_MERGE_CORPUS_DIR": self.corpus_dir,
        }

    def test_clean_conflict_timeout_columns_and_env_metadata(self):
        self._write_cases(
            [
                ("c00001", "conflict", "python", "pkg/a.py", b"MODE:CLEAN\n"),
                ("c00002", "conflict", "swift", "Sources/B.swift", b"MODE:CONFLICT\n"),
                ("c00003", "conflict", "typescript", "src/slow.ts", b"MODE:TIMEOUT\n"),
                ("k00001", "clean", "python", "pkg/err.py", b"MODE:ERROR\n"),
            ]
        )

        rc = run_engine.main(
            [
                "--name",
                "unit_engine",
                "--cases-tsv",
                self.cases_tsv,
                "--engine-bin",
                self.fake_engine,
                "--workers",
                "4",
                "--timeout",
                "1.5",
            ],
            env=self._base_env(),
        )
        self.assertEqual(rc, 0)

        run_dir = os.path.join(self.corpus_dir, "runs", "unit_engine")
        results_tsv = os.path.join(run_dir, "results.tsv")
        env_txt = os.path.join(run_dir, "env.txt")
        self.assertTrue(os.path.isfile(results_tsv))
        self.assertTrue(os.path.isfile(env_txt))

        with open(results_tsv, encoding="utf-8") as fh:
            reader = csv.DictReader(fh, delimiter="\t")
            self.assertEqual(
                reader.fieldnames,
                ["case_id", "exit_code", "claimed_clean", "output_path", "reason", "strategy"],
            )
            rows = list(reader)

        self.assertEqual([r["case_id"] for r in rows], ["c00001", "c00002", "c00003", "k00001"])
        by_id = {r["case_id"]: r for r in rows}

        # Clean: claimed_clean=1, verbatim CRLF bytes saved
        self.assertEqual(by_id["c00001"]["exit_code"], "0")
        self.assertEqual(by_id["c00001"]["claimed_clean"], "1")
        self.assertEqual(by_id["c00001"]["reason"], "")
        self.assertEqual(by_id["c00001"]["strategy"], "declaration-level")
        out_c1 = os.path.join(run_dir, by_id["c00001"]["output_path"])
        self.assertTrue(os.path.isfile(out_c1))
        with open(out_c1, "rb") as fh:
            self.assertEqual(fh.read(), b"def merged():\r\n    return 42\r\n")

        # Conflict: claimed_clean=0, no output file
        self.assertEqual(by_id["c00002"]["exit_code"], "1")
        self.assertEqual(by_id["c00002"]["claimed_clean"], "0")
        self.assertEqual(by_id["c00002"]["output_path"], "")
        self.assertEqual(by_id["c00002"]["strategy"], "none")

        # Timeout: exit_code=124, claimed_clean=0, reason="timeout"
        self.assertEqual(by_id["c00003"]["exit_code"], "124")
        self.assertEqual(by_id["c00003"]["claimed_clean"], "0")
        self.assertEqual(by_id["c00003"]["output_path"], "")
        self.assertEqual(by_id["c00003"]["reason"], "timeout")
        self.assertEqual(by_id["c00003"]["strategy"], "-")

        # Non-zero error sanitized
        self.assertEqual(by_id["k00001"]["exit_code"], "2")
        self.assertEqual(by_id["k00001"]["claimed_clean"], "0")
        self.assertNotIn("/tmp/secret_tmp", by_id["k00001"]["reason"])

        loaded = classify.load_tool_tsv(results_tsv)
        self.assertEqual(loaded["c00001"]["claimed_clean"], "1")
        self.assertEqual(loaded["c00003"]["exit_code"], 124)

        with open(env_txt, encoding="utf-8") as fh:
            env_content = fh.read()
        self.assertIn("engine_bin:", env_content)
        self.assertIn("engine_bin_sha256:", env_content)
        self.assertIn("repo_commit:", env_content)
        self.assertIn("started_at_utc:", env_content)
        self.assertIn("finished_at_utc:", env_content)
        self.assertIn("elapsed_seconds:", env_content)
        self.assertIn("timeout_count: 1", env_content)
        self.assertIn("c00003", env_content)

    def test_quick_append_fixed_cases_and_missing_env_guards(self):
        specs = []
        for i in range(1, 26):
            specs.append((f"c{i:05d}", "conflict", "python", f"p/c{i}.py", b"MODE:CONFLICT\n"))
        for i in range(1, 26):
            specs.append((f"k{i:05d}", "clean", "python", f"p/k{i}.py", b"MODE:CLEAN\n"))
        specs.append(("c00026", "conflict", "swift", "s/c26.swift", b"MODE:CLEAN\n"))
        self._write_cases(specs)

        # Missing RELAY_MERGE_CORPUS_DIR -> exit 2
        env_no_corpus = dict(self._base_env())
        env_no_corpus.pop("RELAY_MERGE_CORPUS_DIR", None)
        self.assertEqual(
            run_engine.main(
                ["--name", "x", "--cases-tsv", self.cases_tsv, "--engine-bin", self.fake_engine],
                env=env_no_corpus,
            ),
            2,
        )

        # Missing engine binary -> exit 2
        self.assertEqual(
            run_engine.main(
                [
                    "--name",
                    "x",
                    "--cases-tsv",
                    self.cases_tsv,
                    "--engine-bin",
                    os.path.join(self.work, "nonexistent_bin"),
                ],
                env=self._base_env(),
            ),
            2,
        )

        # --quick + --languages python -> 20 conflict + 20 clean = 40 rows
        self.assertEqual(
            run_engine.main(
                [
                    "--name",
                    "quick_py",
                    "--languages",
                    "python",
                    "--quick",
                    "--cases-tsv",
                    self.cases_tsv,
                    "--engine-bin",
                    self.fake_engine,
                ],
                env=self._base_env(),
            ),
            0,
        )
        with open(os.path.join(self.corpus_dir, "runs", "quick_py", "results.tsv"), encoding="utf-8") as fh:
            q_rows = list(csv.DictReader(fh, delimiter="\t"))
        self.assertEqual(len(q_rows), 40)

        # --append across languages preserves canonical cases.tsv order
        self.assertEqual(
            run_engine.main(
                [
                    "--name",
                    "quick_py",
                    "--languages",
                    "swift",
                    "--quick",
                    "--append",
                    "--cases-tsv",
                    self.cases_tsv,
                    "--engine-bin",
                    self.fake_engine,
                ],
                env=self._base_env(),
            ),
            0,
        )
        with open(os.path.join(self.corpus_dir, "runs", "quick_py", "results.tsv"), encoding="utf-8") as fh:
            app_rows = list(csv.DictReader(fh, delimiter="\t"))
        self.assertEqual(len(app_rows), 41)
        self.assertEqual(app_rows[-1]["case_id"], "c00026")

        # --fixed-cases mode
        mc_dir = os.path.join(self.work, "merge-cases")
        sg_dir = os.path.join(self.work, "syntax-gate-cases")
        os.makedirs(os.path.join(mc_dir, "01-py-clean"), exist_ok=True)
        os.makedirs(os.path.join(sg_dir, "py-gate"), exist_ok=True)
        for role in ("base", "left", "right"):
            with open(os.path.join(mc_dir, "01-py-clean", role + ".py"), "wb") as fh:
                fh.write(b"MODE:CLEAN\n")
            with open(os.path.join(sg_dir, "py-gate", role + ".py"), "wb") as fh:
                fh.write(b"MODE:CONFLICT\n")

        fixed_out = os.path.join(self.work, "fixed_out")
        self.assertEqual(
            run_engine.main(
                [
                    "--fixed-cases",
                    "--merge-cases-dir",
                    mc_dir,
                    "--syntax-gate-dir",
                    sg_dir,
                    "--out-dir",
                    fixed_out,
                    "--engine-bin",
                    self.fake_engine,
                ],
                env=env_no_corpus,
            ),
            0,
        )
        loaded_fixed = classify.load_tool_tsv(os.path.join(fixed_out, "results.tsv"))
        self.assertEqual(loaded_fixed["merge-cases/01-py-clean"]["claimed_clean"], "1")
        self.assertEqual(loaded_fixed["syntax-gate-cases/py-gate"]["claimed_clean"], "0")


if __name__ == "__main__":
    unittest.main()
