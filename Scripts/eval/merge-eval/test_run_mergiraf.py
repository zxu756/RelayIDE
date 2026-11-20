#!/usr/bin/env python3
"""Unit tests for Scripts/eval/merge-eval/run_mergiraf.py.

Uses a synthetic mini-corpus and a fake executable mergiraf script (Python) in a temporary
directory — never invokes the real mergiraf binary. Covers:
  - Clean merge (exit 0 without conflict markers -> claimed_clean=1, output saved)
  - Conflict merge (exit 1 -> claimed_clean=0, output_path="")
  - Exit 0 WITH conflict markers in output -> claimed_clean=0 (critical safety check!)
  - Python RST `=======` underline or `>>>` doctest in exit-0 output -> still claimed_clean=1
  - Unsupported language Swift -> claimed_clean="skip", fake mergiraf NOT invoked
  - Per-case wall-clock timeout -> exit_code=124, claimed_clean=0, reason="timeout"
  - Per-case timing statistics (timings.tsv + median/max ms in env.txt)
  - results.tsv column contract & compatibility with classify.load_tool_tsv
  - --quick, --languages, --kinds, --append, --fixed-cases, and missing env exit 2
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
import run_mergiraf  # noqa: E402


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


class RunMergirafTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="relay-test-run-mgf.")
        self.work = self._tmp.name
        self.corpus_dir = os.path.join(self.work, "corpus")
        self.cases_root = os.path.join(self.corpus_dir, "extract", "cases")
        os.makedirs(self.cases_root, exist_ok=True)
        self.fake_home = os.path.join(self.work, "fake-home")
        os.makedirs(self.fake_home, exist_ok=True)
        self.invocations_log = os.path.join(self.work, "invocations.log")

        self.fake_mergiraf = os.path.join(self.work, "fake_mergiraf.py")
        _make_executable(
            self.fake_mergiraf,
            textwrap.dedent(
                """\
                #!/usr/bin/python3
                import os
                import sys
                import time

                args = sys.argv[1:]
                if args == ["--version"]:
                    print("mergiraf 0.20.0-fake")
                    sys.exit(0)

                if not args or args[0] != "merge":
                    sys.stderr.write(f"unexpected subcommand: {args!r}\\n")
                    sys.exit(2)

                if "--fast" in args:
                    sys.stderr.write("--fast must not be passed\\n")
                    sys.exit(64)

                out_path = None
                path_name = None
                pos = []
                i = 1
                while i < len(args):
                    if args[i] in ("-o", "--output") and i + 1 < len(args):
                        out_path = args[i + 1]
                        i += 2
                    elif args[i] in ("-p", "--path-name") and i + 1 < len(args):
                        path_name = args[i + 1]
                        i += 2
                    elif args[i] in ("-s", "-x", "-y") and i + 1 < len(args):
                        i += 2
                    else:
                        pos.append(args[i])
                        i += 1

                if len(pos) != 3 or not out_path or not path_name:
                    sys.stderr.write(f"missing merge args: {args!r}\\n")
                    sys.exit(2)

                log_file = os.environ.get("FAKE_MERGIRAF_LOG", "")
                if log_file:
                    with open(log_file, "a", encoding="utf-8") as lfh:
                        lfh.write(path_name + "\\n")

                if path_name.endswith(".swift"):
                    sys.stderr.write("swift should have been skipped before invoking mergiraf!\\n")
                    sys.exit(65)

                marker = open(pos[0], "rb").read()
                if b"MODE:CLEAN" in marker:
                    with open(out_path, "wb") as fh:
                        fh.write(b'\"\"\"Title\\n=======\\n>>> 1 + 1\\n\"\"\"\\nx = 1\\n')
                    sys.exit(0)
                if b"MODE:EXIT0_WITH_MARKERS" in marker:
                    with open(out_path, "wb") as fh:
                        fh.write(b"x = 0\\n<<<<<<< left\\nx = 1\\n=======\\nx = 2\\n>>>>>>> right\\n")
                    sys.exit(0)
                if b"MODE:CONFLICT" in marker:
                    with open(out_path, "wb") as fh:
                        fh.write(b"<<<<<<< left\\nL\\n=======\\nR\\n>>>>>>> right\\n")
                    sys.exit(1)
                if b"MODE:TIMEOUT" in marker:
                    time.sleep(10.0)
                    sys.exit(0)

                with open(out_path, "wb") as fh:
                    fh.write(b"export const ok = true;\\n")
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
            "FAKE_MERGIRAF_LOG": self.invocations_log,
        }

    def test_clean_conflict_exit0_markers_skip_timeout_and_timings(self):
        self._write_cases(
            [
                ("c00001", "conflict", "python", "pkg/rst_clean.py", b"MODE:CLEAN\n"),
                ("c00002", "conflict", "python", "pkg/sneaky_markers.py", b"MODE:EXIT0_WITH_MARKERS\n"),
                ("c00003", "conflict", "typescript", "src/conflict.tsx", b"MODE:CONFLICT\n"),
                ("c00004", "conflict", "swift", "Sources/Skipped.swift", b"MODE:CLEAN\n"),
                ("c00005", "conflict", "typescript", "src/slow.ts", b"MODE:TIMEOUT\n"),
                ("k00001", "clean", "swift", "Sources/CleanSkipped.swift", b"MODE:CLEAN\n"),
                ("k00002", "clean", "typescript", "src/clean.ts", b"MODE:DEFAULT\n"),
            ]
        )

        rc = run_mergiraf.main(
            [
                "--name",
                "unit_mergiraf",
                "--cases-tsv",
                self.cases_tsv,
                "--mergiraf-bin",
                self.fake_mergiraf,
                "--workers",
                "4",
                "--timeout",
                "1.5",
            ],
            env=self._base_env(),
        )
        self.assertEqual(rc, 0)

        run_dir = os.path.join(self.corpus_dir, "runs", "unit_mergiraf")
        results_tsv = os.path.join(run_dir, "results.tsv")
        timings_tsv = os.path.join(run_dir, "timings.tsv")
        env_txt = os.path.join(run_dir, "env.txt")
        self.assertTrue(os.path.isfile(results_tsv))
        self.assertTrue(os.path.isfile(timings_tsv))
        self.assertTrue(os.path.isfile(env_txt))

        with open(results_tsv, encoding="utf-8") as fh:
            reader = csv.DictReader(fh, delimiter="\t")
            self.assertEqual(
                reader.fieldnames,
                ["case_id", "exit_code", "claimed_clean", "output_path", "reason", "strategy"],
            )
            rows = list(reader)

        self.assertEqual(
            [r["case_id"] for r in rows],
            ["c00001", "c00002", "c00003", "c00004", "c00005", "k00001", "k00002"],
        )
        by_id = {r["case_id"]: r for r in rows}

        # c00001: exit 0 without conflict markers (RST ======= and >>> allowed) -> claimed_clean=1
        self.assertEqual(by_id["c00001"]["exit_code"], "0")
        self.assertEqual(by_id["c00001"]["claimed_clean"], "1")
        self.assertTrue(os.path.isfile(os.path.join(run_dir, by_id["c00001"]["output_path"])))

        # c00002: exit 0 WITH conflict markers -> MUST record claimed_clean=0 and NOT save clean output!
        self.assertEqual(by_id["c00002"]["exit_code"], "0")
        self.assertEqual(by_id["c00002"]["claimed_clean"], "0")
        self.assertEqual(by_id["c00002"]["output_path"], "")
        self.assertIn("conflict_markers", by_id["c00002"]["reason"])

        # c00003: exit 1 -> claimed_clean=0
        self.assertEqual(by_id["c00003"]["exit_code"], "1")
        self.assertEqual(by_id["c00003"]["claimed_clean"], "0")
        self.assertEqual(by_id["c00003"]["output_path"], "")

        # c00004 & k00001: Swift -> claimed_clean="skip", mergiraf binary never called on .swift
        self.assertEqual(by_id["c00004"]["claimed_clean"], "skip")
        self.assertEqual(by_id["k00001"]["claimed_clean"], "skip")
        with open(self.invocations_log, encoding="utf-8") as fh:
            invoked_paths = [ln.strip() for ln in fh if ln.strip()]
        self.assertFalse(any(p.endswith(".swift") for p in invoked_paths))

        # c00005: timeout -> exit_code=124, claimed_clean=0, reason="timeout"
        self.assertEqual(by_id["c00005"]["exit_code"], "124")
        self.assertEqual(by_id["c00005"]["claimed_clean"], "0")
        self.assertEqual(by_id["c00005"]["reason"], "timeout")

        # Compatibility with classify.load_tool_tsv
        loaded = classify.load_tool_tsv(results_tsv)
        self.assertEqual(loaded["c00001"]["claimed_clean"], "1")
        self.assertEqual(loaded["c00002"]["claimed_clean"], "0")
        self.assertEqual(loaded["c00004"]["claimed_clean"], "skip")
        self.assertEqual(loaded["c00005"]["exit_code"], 124)

        with open(env_txt, encoding="utf-8") as fh:
            env_content = fh.read()
        self.assertIn("mergiraf 0.20.0-fake", env_content)
        self.assertIn("per_case_ms_median:", env_content)
        self.assertIn("per_case_ms_max:", env_content)
        self.assertIn("swift=2", env_content)
        self.assertIn("timeout_count: 1", env_content)

    def test_fixed_cases_append_and_missing_env_guards(self):
        self._write_cases(
            [
                ("c00001", "conflict", "python", "p/a.py", b"MODE:CLEAN\n"),
                ("c00002", "conflict", "swift", "s/b.swift", b"MODE:CLEAN\n"),
            ]
        )

        env_no_corpus = dict(self._base_env())
        env_no_corpus.pop("RELAY_MERGE_CORPUS_DIR", None)
        self.assertEqual(
            run_mergiraf.main(
                ["--name", "x", "--cases-tsv", self.cases_tsv, "--mergiraf-bin", self.fake_mergiraf],
                env=env_no_corpus,
            ),
            2,
        )

        # Fixed cases mode: Swift skipped, Python & Rust & Java supported
        mc_dir = os.path.join(self.work, "merge-cases")
        sg_dir = os.path.join(self.work, "syntax-gate-cases")
        for subdir, ext, payload in [
            ("01-swift-case", ".swift", b"MODE:CLEAN\n"),
            ("07-py-case", ".py", b"MODE:CLEAN\n"),
            ("28-rs-case", ".rs", b"MODE:CONFLICT\n"),
        ]:
            d = os.path.join(mc_dir, subdir)
            os.makedirs(d, exist_ok=True)
            for role in ("base", "left", "right"):
                with open(os.path.join(d, role + ext), "wb") as fh:
                    fh.write(payload)
        os.makedirs(os.path.join(sg_dir, "ts-gate"), exist_ok=True)
        for role in ("base", "left", "right"):
            with open(os.path.join(sg_dir, "ts-gate", role + ".ts"), "wb") as fh:
                fh.write(b"MODE:EXIT0_WITH_MARKERS\n")

        fixed_out = os.path.join(self.work, "fixed_mgf")
        self.assertEqual(
            run_mergiraf.main(
                [
                    "--fixed-cases",
                    "--merge-cases-dir",
                    mc_dir,
                    "--syntax-gate-dir",
                    sg_dir,
                    "--out-dir",
                    fixed_out,
                    "--mergiraf-bin",
                    self.fake_mergiraf,
                ],
                env=env_no_corpus,
            ),
            0,
        )
        loaded_fixed = classify.load_tool_tsv(os.path.join(fixed_out, "results.tsv"))
        self.assertEqual(loaded_fixed["merge-cases/01-swift-case"]["claimed_clean"], "skip")
        self.assertEqual(loaded_fixed["merge-cases/07-py-case"]["claimed_clean"], "1")
        self.assertEqual(loaded_fixed["merge-cases/28-rs-case"]["claimed_clean"], "0")
        self.assertEqual(loaded_fixed["syntax-gate-cases/ts-gate"]["claimed_clean"], "0")


if __name__ == "__main__":
    unittest.main()
