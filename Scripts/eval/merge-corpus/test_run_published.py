#!/usr/bin/env python3
"""Unit tests for Scripts/eval/merge-corpus/run_published.py.

Uses a synthetic mini-corpus and a fake executable relay-cli script in a temporary
directory (never invokes the real RelayIDE binary). Covers:
  - Exit codes 0, 1, 3, 4
  - Per-case timeout -> exit_code 124, reason="timeout"
  - Both --path-mode values (`caller` and `eval-python-first`) and actual child PATH resolution
  - results.tsv columns/compatibility with classify.load_tool_tsv, output file saving on exit 0 only,
    reason sanitization (stripping temp and home paths), strategy extraction, --quick, and env.txt metadata.
"""
import csv
import os
import stat
import sys
import tempfile
import textwrap
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import classify  # noqa: E402
import run_published  # noqa: E402


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


class RunPublishedTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory(prefix="relay-test-run-pub.")
        self.work = self._tmp.name
        self.corpus_dir = os.path.join(self.work, "corpus")
        self.cases_root = os.path.join(self.corpus_dir, "extract", "cases")
        os.makedirs(self.cases_root, exist_ok=True)
        self.fake_home = os.path.join(self.work, "fake-user-home")
        os.makedirs(self.fake_home, exist_ok=True)

        # Create two fake tool bin directories to verify PATH ordering
        self.caller_bin = os.path.join(self.work, "caller-bin")
        self.eval_py_bin = os.path.join(self.work, "eval-py-bin")
        os.makedirs(self.caller_bin, exist_ok=True)
        os.makedirs(self.eval_py_bin, exist_ok=True)

        for tool_name, ver in [
            ("python3", "Python 3.9.6-fake-caller"),
            ("node", "v22.0.0-fake"),
            ("tsc", "Version 5.9.3-fake"),
            ("git", "git version 2.54.0-fake"),
        ]:
            _make_executable(
                os.path.join(self.caller_bin, tool_name),
                "#!/bin/sh\necho '%s'\nexit 0\n" % ver,
            )

        self.eval_python_exe = os.path.join(self.eval_py_bin, "python3.14")
        _make_executable(
            self.eval_python_exe,
            "#!/bin/sh\necho 'Python 3.14.9-fake-eval'\nexit 0\n",
        )
        _make_executable(
            os.path.join(self.eval_py_bin, "python3"),
            "#!/bin/sh\necho 'Python 3.14.9-fake-eval'\nexit 0\n",
        )

        # Fake binary file (for sha256 recording) and fake relay-cli wrapper (Python script)
        self.fake_bin = os.path.join(self.work, "FakeRelayIDE")
        with open(self.fake_bin, "wb") as fh:
            fh.write(b"FAKE-RELAYIDE-BINARY-BYTES\n")
        os.chmod(self.fake_bin, 0o755)

        self.fake_cli = os.path.join(self.work, "fake-relay-cli.py")
        _make_executable(
            self.fake_cli,
            textwrap.dedent(
                """\
                #!/usr/bin/python3
                import os
                import shutil
                import subprocess
                import sys
                import time

                # Expect: semantic-merge <base> <left> <right> --lang en
                args = sys.argv[1:]
                if len(args) < 6 or args[0] != "semantic-merge" or args[4:] != ["--lang", "en"]:
                    sys.stderr.write(f"bad args: {args!r}\\n")
                    sys.exit(64)

                child_path = os.environ.get("RELAY_CLI_CHILD_PATH") or os.environ.get("PATH", "")
                cli_home = os.environ.get("RELAY_CLI_HOME", "")
                if not cli_home or not os.path.isdir(cli_home):
                    sys.stderr.write("missing RELAY_CLI_HOME\\n")
                    sys.exit(65)

                base_path = args[1]
                marker = open(base_path, "rb").read()

                # Query which python3 is first on child_path
                py_exe = shutil.which("python3", path=child_path)
                py_ver = ""
                if py_exe:
                    py_ver = subprocess.check_output([py_exe, "--version"], text=True).strip()

                if b"MODE:CLEAN_DECL" in marker:
                    sys.stdout.buffer.write(b"merged_clean_decl\\r\\nline2\\r\\n")
                    sys.stderr.write("semantic-merge: [strategy=declaration-level] clean: resolved 1 block\\n")
                    sys.exit(0)
                if b"MODE:CLEAN_PATH_SENSITIVE" in marker:
                    if "3.14.9-fake-eval" in py_ver:
                        sys.stdout.buffer.write(b"match x:\\n    case 1:\\n        pass\\n")
                        sys.stderr.write("semantic-merge: [strategy=line-level] clean: syntax check passed (python3 -m py_compile)\\n")
                        sys.exit(0)
                    fake_home = os.environ.get("FAKE_USER_HOME_FOR_TEST", "/Users/alice")
                    sys.stderr.write(
                        f"semantic-merge: Merged output failed syntax check (python3 -m py_compile): "
                        f"File \\"/tmp/relay-syntax-check-1234/merged_check.py\\", home={fake_home}/secret.py, SyntaxError\\n"
                    )
                    sys.exit(3)
                if b"MODE:CONFLICT" in marker:
                    sys.stdout.buffer.write(b"<<<<<<< left\\nL\\n=======\\nR\\n>>>>>>> right\\n")
                    sys.stderr.write(
                        "semantic-merge: 3-Way Semantic AST Merge stopped with 1 unresolved conflict(s)\\n"
                        "semantic-merge: [strategy=none] the output is the conflict-marked git merge-file result: conflict block 1 of 1\\n"
                    )
                    sys.exit(1)
                if b"MODE:EXIT3" in marker:
                    sys.stderr.write(
                        f"semantic-merge: Merged output failed syntax check (swiftc -parse): "
                        f"{cli_home}/work/MergedCheck.swift:1:1: error: bad token\\n"
                    )
                    sys.exit(3)
                if b"MODE:EXIT4" in marker:
                    sys.stderr.write(
                        "semantic-merge: 3-Way Semantic AST Merge failed: git is unavailable or `git merge-file` failed "
                        "(/private/tmp/relay-line-merge-9999/plain-left: boom). Refusing to merge without the line-level reference\\n"
                    )
                    sys.exit(4)
                if b"MODE:TIMEOUT" in marker:
                    time.sleep(10.0)
                    sys.exit(0)

                sys.stdout.buffer.write(b"default_clean\\n")
                sys.stderr.write("semantic-merge: [strategy=line-level] clean\\n")
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
            "PATH": self.caller_bin + ":/usr/bin:/bin",
            "HOME": self.fake_home,
            "FAKE_USER_HOME_FOR_TEST": self.fake_home,
            "RELAY_MERGE_CORPUS_DIR": self.corpus_dir,
            "RELAY_EVAL_PYTHON": self.eval_python_exe,
            "RELAY_CLI_BIN": self.fake_bin,
        }

    def test_exit_codes_timeout_columns_and_sanitization(self):
        self._write_cases(
            [
                ("c00001", "conflict", "python", "pkg/a.py", b"MODE:CLEAN_DECL\n"),
                ("c00002", "conflict", "swift", "Sources/B.swift", b"MODE:CONFLICT\n"),
                ("c00003", "conflict", "typescript", "src/c.ts", b"MODE:EXIT4\n"),
                ("c00004", "conflict", "python", "pkg/slow.py", b"MODE:TIMEOUT\n"),
                ("k00001", "clean", "swift", "Sources/Clean.swift", b"MODE:EXIT3\n"),
                ("k00002", "clean", "python", "pkg/match_stmt.py", b"MODE:CLEAN_PATH_SENSITIVE\n"),
            ]
        )

        rc = run_published.main(
            [
                "--name",
                "unit_caller",
                "--path-mode",
                "caller",
                "--cases-tsv",
                self.cases_tsv,
                "--cli",
                self.fake_cli,
                "--workers",
                "4",
                "--timeout",
                "2.0",
            ],
            env=self._base_env(),
        )
        self.assertEqual(rc, 0)

        run_dir = os.path.join(self.corpus_dir, "runs", "unit_caller")
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

        # Order must match cases.tsv even under 4-worker concurrency
        self.assertEqual([r["case_id"] for r in rows], ["c00001", "c00002", "c00003", "c00004", "k00001", "k00002"])
        by_id = {r["case_id"]: r for r in rows}

        # Exit 0: claimed_clean=1, output saved verbatim (CRLF preserved), strategy=declaration-level, reason=""
        self.assertEqual(by_id["c00001"]["exit_code"], "0")
        self.assertEqual(by_id["c00001"]["claimed_clean"], "1")
        self.assertEqual(by_id["c00001"]["strategy"], "declaration-level")
        self.assertEqual(by_id["c00001"]["reason"], "")
        out_c1 = os.path.join(run_dir, by_id["c00001"]["output_path"])
        self.assertTrue(os.path.isfile(out_c1))
        with open(out_c1, "rb") as fh:
            self.assertEqual(fh.read(), b"merged_clean_decl\r\nline2\r\n")

        # Exit 1: claimed_clean=0, output_path="", reason="", strategy=none
        self.assertEqual(by_id["c00002"]["exit_code"], "1")
        self.assertEqual(by_id["c00002"]["claimed_clean"], "0")
        self.assertEqual(by_id["c00002"]["output_path"], "")
        self.assertEqual(by_id["c00002"]["reason"], "")
        self.assertEqual(by_id["c00002"]["strategy"], "none")

        # Exit 4: claimed_clean=0, output_path="", sanitized reason without /private/tmp/..., strategy=-
        self.assertEqual(by_id["c00003"]["exit_code"], "4")
        self.assertEqual(by_id["c00003"]["claimed_clean"], "0")
        self.assertEqual(by_id["c00003"]["output_path"], "")
        self.assertIn("git is unavailable", by_id["c00003"]["reason"])
        self.assertNotIn("/private/tmp/relay-line-merge-9999", by_id["c00003"]["reason"])
        self.assertEqual(by_id["c00003"]["strategy"], "-")

        # Timeout: exit_code=124, claimed_clean=0, reason=timeout, strategy=-
        self.assertEqual(by_id["c00004"]["exit_code"], "124")
        self.assertEqual(by_id["c00004"]["claimed_clean"], "0")
        self.assertEqual(by_id["c00004"]["output_path"], "")
        self.assertEqual(by_id["c00004"]["reason"], "timeout")
        self.assertEqual(by_id["c00004"]["strategy"], "-")

        # Exit 3: claimed_clean=0, sanitized reason (neither RELAY_CLI_HOME nor user home nor /tmp leaked)
        self.assertEqual(by_id["k00001"]["exit_code"], "3")
        self.assertEqual(by_id["k00001"]["claimed_clean"], "0")
        self.assertEqual(by_id["k00001"]["output_path"], "")
        self.assertIn("swiftc -parse", by_id["k00001"]["reason"])
        self.assertNotIn(self.work, by_id["k00001"]["reason"])
        self.assertEqual(by_id["k00001"]["strategy"], "-")

        # Under caller PATH, k00002 hits Python 3.9.6-fake-caller -> exit 3, home & /tmp stripped
        self.assertEqual(by_id["k00002"]["exit_code"], "3")
        self.assertNotIn(self.fake_home, by_id["k00002"]["reason"])
        self.assertNotIn("/tmp/relay-syntax-check-1234", by_id["k00002"]["reason"])

        # Compatibility with classify.load_tool_tsv
        loaded = classify.load_tool_tsv(results_tsv)
        self.assertEqual(set(loaded.keys()), {"c00001", "c00002", "c00003", "c00004", "k00001", "k00002"})
        self.assertEqual(loaded["c00001"]["exit_code"], 0)
        self.assertEqual(loaded["c00004"]["exit_code"], 124)

        # Check env.txt records python3, tsc, node, git, binary path & sha256, start/end/elapsed
        with open(env_txt, encoding="utf-8") as fh:
            env_content = fh.read()
        self.assertIn("Python 3.9.6-fake-caller", env_content)
        self.assertIn("v22.0.0-fake", env_content)
        self.assertIn("Version 5.9.3-fake", env_content)
        self.assertIn("git version 2.54.0-fake", env_content)
        self.assertIn("cli_bin_sha256:", env_content)
        self.assertIn("elapsed_seconds:", env_content)

    def test_path_mode_eval_python_first_and_filters_and_quick(self):
        # Generate 25 python conflicts + 25 python cleans + 5 swift conflicts to test --quick & --path-mode eval-python-first
        specs = []
        for i in range(1, 26):
            specs.append((f"c{i:05d}", "conflict", "python", f"p/c{i}.py", b"MODE:CONFLICT\n"))
        for i in range(1, 26):
            mode = b"MODE:CLEAN_PATH_SENSITIVE\n" if i == 1 else b"MODE:DEFAULT\n"
            specs.append((f"k{i:05d}", "clean", "python", f"p/k{i}.py", mode))
        for i in range(26, 31):
            specs.append((f"c{i:05d}", "conflict", "swift", f"s/c{i}.swift", b"MODE:CONFLICT\n"))
        self._write_cases(specs)

        rc = run_published.main(
            [
                "--name",
                "unit_evalpy_quick",
                "--path-mode",
                "eval-python-first",
                "--languages",
                "python",
                "--kinds",
                "conflict,clean",
                "--quick",
                "--cases-tsv",
                self.cases_tsv,
                "--cli",
                self.fake_cli,
                "--workers",
                "4",
            ],
            env=self._base_env(),
        )
        self.assertEqual(rc, 0)

        run_dir = os.path.join(self.corpus_dir, "runs", "unit_evalpy_quick")
        with open(os.path.join(run_dir, "results.tsv"), encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh, delimiter="\t"))

        # --quick caps at 20 conflict + 20 clean per language, and --languages python excludes swift
        self.assertEqual(len(rows), 40)
        by_id = {r["case_id"]: r for r in rows}
        self.assertNotIn("c00021", by_id)
        self.assertNotIn("k00021", by_id)
        self.assertNotIn("c00026", by_id)

        # Under eval-python-first, k00001 sees Python 3.14.9-fake-eval first on PATH -> exit 0!
        self.assertEqual(by_id["k00001"]["exit_code"], "0")
        self.assertEqual(by_id["k00001"]["claimed_clean"], "1")
        self.assertEqual(by_id["k00001"]["strategy"], "line-level")

        with open(os.path.join(run_dir, "env.txt"), encoding="utf-8") as fh:
            env_content = fh.read()
        self.assertIn("Python 3.14.9-fake-eval", env_content)

    def test_append_across_languages_and_missing_env_guards(self):
        self._write_cases(
            [
                ("c00001", "conflict", "python", "p/a.py", b"MODE:CLEAN_DECL\n"),
                ("c00002", "conflict", "swift", "s/b.swift", b"MODE:CONFLICT\n"),
                ("k00001", "clean", "typescript", "t/c.ts", b"MODE:DEFAULT\n"),
            ]
        )
        # Missing RELAY_MERGE_CORPUS_DIR -> exit 2
        env_no_corpus = dict(self._base_env())
        env_no_corpus.pop("RELAY_MERGE_CORPUS_DIR", None)
        self.assertEqual(
            run_published.main(["--name", "x", "--cases-tsv", self.cases_tsv, "--cli", self.fake_cli], env=env_no_corpus),
            2,
        )
        # Missing RELAY_EVAL_PYTHON in eval-python-first -> exit 2
        env_no_eval = dict(self._base_env())
        env_no_eval.pop("RELAY_EVAL_PYTHON", None)
        self.assertEqual(
            run_published.main(
                ["--name", "x", "--path-mode", "eval-python-first", "--cases-tsv", self.cases_tsv, "--cli", self.fake_cli],
                env=env_no_eval,
            ),
            2,
        )

        # Split execution by --languages with --append preserves canonical cases.tsv order
        for idx, lang in enumerate(["swift", "python", "typescript"]):
            argv = [
                "--name",
                "split_run",
                "--languages",
                lang,
                "--cases-tsv",
                self.cases_tsv,
                "--cli",
                self.fake_cli,
            ]
            if idx > 0:
                argv.append("--append")
            self.assertEqual(run_published.main(argv, env=self._base_env()), 0)

        results_tsv = os.path.join(self.corpus_dir, "runs", "split_run", "results.tsv")
        with open(results_tsv, encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh, delimiter="\t"))
        self.assertEqual([r["case_id"] for r in rows], ["c00001", "c00002", "k00001"])


if __name__ == "__main__":
    unittest.main()
