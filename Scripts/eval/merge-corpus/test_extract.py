#!/usr/bin/env python3
"""Unit tests for Scripts/eval/merge-corpus/{extract.py,parsers.py}.

Builds synthetic git repositories in tempfile.mkdtemp() covering:
  - missing RELAY_MERGE_CORPUS_DIR / parser env vars -> "没跑..." and exit 2
  - --fetch from a local file:// bare repository without network access
  - only counting merges reachable from the pinned commit (ignoring unmerged refs)
  - 3-parent (octopus) merge skipped and counted
  - 2-base (criss-cross) merge and 0-base (unrelated history) merge skipped and counted
  - candidate file skips: not M/M, missing blob in merge commit, P1==P2, >1 MB, invalid UTF-8,
    duplicate (base,left,right) conflict triple, git-clean files
  - pure-insertion detection (including CRLF), human==left/right, human_parses via fixed parsers
  - --count-only leaves extract directory untouched
  - missing git object fails under GIT_NO_LAZY_FETCH=1
  - two runs produce identical cases.tsv sha256; conservation law holds; --verify checks Rows 1-5
  - Mutation C check: injecting a git-clean case into the conflict set makes --verify Row 5 fail
Python 3.9 compatible, standard library only.
"""
import csv
import hashlib
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
EXTRACT_PY = os.path.join(SCRIPT_DIR, "extract.py")
PARSERS_PY = os.path.join(SCRIPT_DIR, "parsers.py")
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import parsers  # noqa: E402

MIT_TEXT = (
    "The MIT License (MIT)\n\n"
    "Copyright (c) 2026 Example Contributors\n\n"
    "Permission is hereby granted, free of charge, to any person obtaining a copy "
    "of this software and associated documentation files (the \"Software\"), to deal "
    "in the Software without restriction, including without limitation the rights "
    "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell "
    "copies of the Software, and to permit persons to whom the Software is "
    "furnished to do so, subject to the following conditions:\n"
)


def _run_git(cwd, args, env, check=True):
    proc = subprocess.run(
        ["/usr/bin/git", "-C", cwd] + list(args),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            "git %s failed (%d): %s"
            % (" ".join(args), proc.returncode, proc.stderr.decode("utf-8", "replace"))
        )
    return proc


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
            "const vm = require('vm');\n"
            "exports.version = '5.9.3-mock';\n"
            "exports.ScriptTarget = { Latest: 99 };\n"
            "exports.ScriptKind = { JS: 1, JSX: 2, TS: 3, TSX: 4 };\n"
            "exports.createSourceFile = function(name, text, target, setParent, kind) {\n"
            "  if (text.indexOf('SYNTAX_ERROR') !== -1 || text.indexOf('func broken(') !== -1) {\n"
            "    return { parseDiagnostics: [{ messageText: 'Mock syntax error' }] };\n"
            "  }\n"
            "  return { parseDiagnostics: [] };\n"
            "};\n"
        )
    return mock_py, mock_ts_dir


class MergeCorpusExtractorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp_root = tempfile.mkdtemp(prefix="relayide-m3-test.")
        cls.empty_home = os.path.join(cls.tmp_root, "empty-home")
        os.makedirs(cls.empty_home, exist_ok=True)
        cls.mock_py, cls.mock_ts = _make_mock_parsers(cls.tmp_root)
        cls.eval_python = os.environ.get("RELAY_EVAL_PYTHON") or cls.mock_py
        cls.eval_ts = os.environ.get("RELAY_EVAL_TYPESCRIPT") or cls.mock_ts
        cls.upstream_bare, cls.pinned_commit = cls._build_synthetic_upstream()

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp_root, ignore_errors=True)

    @classmethod
    def _git_commit_env(cls, tick):
        ts = "%d +0000" % (1700000000 + tick[0])
        tick[0] += 60
        env = {
            "PATH": "/usr/bin:/bin",
            "HOME": cls.empty_home,
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "Synthetic Builder",
            "GIT_AUTHOR_EMAIL": "builder@example.invalid",
            "GIT_COMMITTER_NAME": "Synthetic Builder",
            "GIT_COMMITTER_EMAIL": "builder@example.invalid",
            "GIT_AUTHOR_DATE": ts,
            "GIT_COMMITTER_DATE": ts,
        }
        return env

    @classmethod
    def _write(cls, repo, rel, content):
        full = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        mode = "wb" if isinstance(content, (bytes, bytearray)) else "w"
        kwargs = {} if mode == "wb" else {"encoding": "utf-8"}
        with open(full, mode, **kwargs) as fh:
            fh.write(content)

    @classmethod
    def _commit_all(cls, repo, msg, tick):
        env = cls._git_commit_env(tick)
        _run_git(repo, ["add", "-A"], env)
        _run_git(repo, ["commit", "-m", msg], env)
        return _run_git(repo, ["rev-parse", "HEAD"], env).stdout.decode("ascii").strip()

    @classmethod
    def _build_synthetic_upstream(cls):
        work = os.path.join(cls.tmp_root, "work")
        os.makedirs(work)
        tick = [1]
        env0 = cls._git_commit_env(tick)
        _run_git(work, ["init", "-b", "main"], env0)
        _run_git(work, ["config", "user.name", "Synthetic Builder"], env0)
        _run_git(work, ["config", "user.email", "builder@example.invalid"], env0)

        # C0: initial commit
        clean_lines = ["let lineTop = 1\n"] + ["let pad%d = %d\n" % (i, i) for i in range(1, 12)] + ["let lineBot = 2\n"]
        cls._write(work, "LICENSE", MIT_TEXT)
        cls._write(work, "conflict_pure.swift", "let header = 1\n")
        cls._write(work, "conflict_crlf.swift", b"let crlfHeader = 1\r\n")
        cls._write(work, "conflict_mod.swift", "let value = 0\n")
        cls._write(work, "clean.swift", "".join(clean_lines))
        cls._write(work, "same_change.swift", "let same = 0\n")
        cls._write(work, "big.swift", "let big = 0\n")
        cls._write(work, "non_utf8.swift", "let txt = 0\n")
        cls._write(work, "deleted_in_merge.swift", "let doomed = 0\n")
        cls._write(work, "notes.md", "base note\n")
        c0 = cls._commit_all(work, "C0 initial", tick)

        # M1: conflicted merge (pure insertion + CRLF pure insertion + modified base line + non-target .md)
        _run_git(work, ["checkout", "-b", "b_conf1"], cls._git_commit_env(tick))
        cls._write(work, "conflict_pure.swift", "let header = 1\nlet rightAdded = 20\n")
        cls._write(work, "conflict_crlf.swift", b"let crlfHeader = 1\r\nlet rightCrlf = 20\r\n")
        cls._write(work, "conflict_mod.swift", "let value = 200\n")
        cls._write(work, "notes.md", "right note\n")
        cls._commit_all(work, "b_conf1 changes", tick)

        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        cls._write(work, "conflict_pure.swift", "let header = 1\nlet leftAdded = 10\n")
        cls._write(work, "conflict_crlf.swift", b"let crlfHeader = 1\r\nlet leftCrlf = 10\r\n")
        cls._write(work, "conflict_mod.swift", "let value = 100\n")
        cls._write(work, "notes.md", "left note\n")
        cls._commit_all(work, "main conf1 changes", tick)

        m1_env = cls._git_commit_env(tick)
        _run_git(work, ["merge", "--no-ff", "--no-commit", "b_conf1"], m1_env, check=False)
        # Resolve conflict_pure -> right, conflict_crlf -> left+right, conflict_mod -> syntax error
        cls._write(work, "conflict_pure.swift", "let header = 1\nlet rightAdded = 20\n")
        cls._write(work, "conflict_crlf.swift", b"let crlfHeader = 1\r\nlet leftCrlf = 10\r\nlet rightCrlf = 20\r\n")
        cls._write(work, "conflict_mod.swift", "func broken( {\n")
        cls._write(work, "notes.md", "merged note\n")
        cls._commit_all(work, "M1 conflicted merge", tick)

        # M2: duplicate (base, left, right) triple matching conflict_pure.swift in M1
        cls._write(work, "dup_pure.swift", "let header = 1\n")
        cls._commit_all(work, "add dup_pure base", tick)
        _run_git(work, ["checkout", "-b", "b_dup"], cls._git_commit_env(tick))
        cls._write(work, "dup_pure.swift", "let header = 1\nlet rightAdded = 20\n")
        cls._commit_all(work, "b_dup change", tick)
        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        cls._write(work, "dup_pure.swift", "let header = 1\nlet leftAdded = 10\n")
        cls._commit_all(work, "main dup change", tick)
        _run_git(work, ["merge", "--no-ff", "--no-commit", "b_dup"], cls._git_commit_env(tick), check=False)
        cls._write(work, "dup_pure.swift", "let header = 1\nlet leftAdded = 10\n")
        cls._commit_all(work, "M2 duplicate triple merge", tick)

        # M3: clean two-sided merge on clean.swift
        _run_git(work, ["checkout", "-b", "b_clean"], cls._git_commit_env(tick))
        right_clean = list(clean_lines)
        right_clean[-1] = "let lineBot = 222\n"
        cls._write(work, "clean.swift", "".join(right_clean))
        cls._commit_all(work, "b_clean bottom edit", tick)
        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        left_clean = list(clean_lines)
        left_clean[0] = "let lineTop = 111\n"
        cls._write(work, "clean.swift", "".join(left_clean))
        cls._commit_all(work, "main top edit", tick)
        _run_git(work, ["merge", "--no-ff", "-m", "M3 clean merge", "b_clean"], cls._git_commit_env(tick))

        # M4: skip categories (not M/M, missing blob in merge, identical sides, >1 MB, invalid UTF-8)
        _run_git(work, ["checkout", "-b", "b_skips"], cls._git_commit_env(tick))
        cls._write(work, "added_both.swift", "let added = 2\n")
        cls._write(work, "deleted_in_merge.swift", "let doomed = 2\n")
        cls._write(work, "same_change.swift", "let same = 42\n")
        cls._write(work, "big.swift", "let big = 2\n" + ("// " + ("x" * 96) + "\n") * 10500)
        cls._write(work, "non_utf8.swift", b"let txt = 2 // \xff\xfe\n")
        cls._commit_all(work, "b_skips edits", tick)

        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        cls._write(work, "added_both.swift", "let added = 1\n")
        cls._write(work, "deleted_in_merge.swift", "let doomed = 1\n")
        cls._write(work, "same_change.swift", "let same = 42\n")
        cls._write(work, "big.swift", "let big = 1\n")
        cls._write(work, "non_utf8.swift", "let txt = 1\n")
        cls._commit_all(work, "main skips edits", tick)

        _run_git(work, ["merge", "--no-ff", "--no-commit", "b_skips"], cls._git_commit_env(tick), check=False)
        cls._write(work, "added_both.swift", "let added = 12\n")
        _run_git(work, ["rm", "-f", "deleted_in_merge.swift"], cls._git_commit_env(tick))
        cls._write(work, "same_change.swift", "let same = 42\n")
        cls._write(work, "big.swift", "let big = 1\n")
        cls._write(work, "non_utf8.swift", "let txt = 1\n")
        cls._commit_all(work, "M4 skip categories merge", tick)

        # M5: 3-parent octopus merge
        _run_git(work, ["checkout", "-b", "oct1"], cls._git_commit_env(tick))
        cls._write(work, "oct1.swift", "let o1 = 1\n")
        cls._commit_all(work, "oct1", tick)
        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        _run_git(work, ["checkout", "-b", "oct2"], cls._git_commit_env(tick))
        cls._write(work, "oct2.swift", "let o2 = 2\n")
        cls._commit_all(work, "oct2", tick)
        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        cls._write(work, "oct0.swift", "let o0 = 0\n")
        cls._commit_all(work, "oct0 on main", tick)
        _run_git(work, ["merge", "--no-ff", "-m", "M5 octopus merge", "oct1", "oct2"], cls._git_commit_env(tick))

        # M6: criss-cross merge (2 merge-bases)
        _run_git(work, ["checkout", "-b", "cc_a"], cls._git_commit_env(tick))
        cls._write(work, "cca.txt", "a\n")
        ca = cls._commit_all(work, "cc_a", tick)
        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        _run_git(work, ["checkout", "-b", "cc_b"], cls._git_commit_env(tick))
        cls._write(work, "ccb.txt", "b\n")
        cb = cls._commit_all(work, "cc_b", tick)

        _run_git(work, ["checkout", "-b", "criss1", ca], cls._git_commit_env(tick))
        _run_git(work, ["merge", "--no-ff", "-m", "criss1 merges cb", cb], cls._git_commit_env(tick))
        cls._write(work, "criss1_only.txt", "1\n")
        m_criss1 = cls._commit_all(work, "criss1 extra", tick)

        _run_git(work, ["checkout", "-b", "criss2", cb], cls._git_commit_env(tick))
        _run_git(work, ["merge", "--no-ff", "-m", "criss2 merges ca", ca], cls._git_commit_env(tick))
        cls._write(work, "criss2_only.txt", "2\n")
        m_criss2 = cls._commit_all(work, "criss2 extra", tick)

        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        _run_git(work, ["reset", "--hard", m_criss1], cls._git_commit_env(tick))
        _run_git(work, ["merge", "--no-ff", "-m", "M6 criss-cross merge", m_criss2], cls._git_commit_env(tick))

        # M7: unrelated history merge (0 merge-bases)
        _run_git(work, ["checkout", "--orphan", "orphan_side"], cls._git_commit_env(tick))
        _run_git(work, ["rm", "-rf", "."], cls._git_commit_env(tick))
        cls._write(work, "orphan.txt", "orphan\n")
        cls._commit_all(work, "orphan root", tick)
        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))
        head_main = _run_git(
            work,
            ["merge", "--allow-unrelated-histories", "--no-ff", "-m", "M7 unrelated merge", "orphan_side"],
            cls._git_commit_env(tick),
        )
        pinned = _run_git(work, ["rev-parse", "main"], cls._git_commit_env(tick)).stdout.decode("ascii").strip()

        # Unmerged side branch with its own conflict (must NOT be counted when walking pinned main commit)
        _run_git(work, ["checkout", "-b", "unmerged_feature", c0], cls._git_commit_env(tick))
        cls._write(work, "conflict_mod.swift", "let sideA = 1\n")
        cls._commit_all(work, "unmerged A", tick)
        _run_git(work, ["checkout", "-b", "unmerged_feature_b", c0], cls._git_commit_env(tick))
        cls._write(work, "conflict_mod.swift", "let sideB = 2\n")
        cls._commit_all(work, "unmerged B", tick)
        _run_git(work, ["merge", "--no-ff", "--no-commit", "unmerged_feature"], cls._git_commit_env(tick), check=False)
        cls._write(work, "conflict_mod.swift", "let sideMerged = 3\n")
        cls._commit_all(work, "unmerged conflict merge", tick)
        _run_git(work, ["checkout", "main"], cls._git_commit_env(tick))

        upstream_bare = os.path.join(cls.tmp_root, "upstream-origin.git")
        _run_git(cls.tmp_root, ["clone", "--bare", "--quiet", work, upstream_bare], cls._git_commit_env(tick))
        return upstream_bare, pinned

    def _base_env(self, corpus_dir=None, include_parsers=True):
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.empty_home,
            "LC_ALL": "C",
        }
        if corpus_dir is not None:
            env["RELAY_MERGE_CORPUS_DIR"] = corpus_dir
        if include_parsers:
            env["RELAY_EVAL_PYTHON"] = self.eval_python
            env["RELAY_EVAL_TYPESCRIPT"] = self.eval_ts
        return env

    def _run_extract(self, args, env):
        return subprocess.run(
            [sys.executable, "-I", EXTRACT_PY] + list(args),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
        )

    def test_missing_corpus_dir_exits_2(self):
        env = self._base_env(corpus_dir=None)
        proc = self._run_extract([], env)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("没跑：没有语料缓存", proc.stdout + proc.stderr)

    def test_missing_python_and_ts_parsers_exit_2(self):
        sub = tempfile.mkdtemp(dir=self.tmp_root)
        py_repos = os.path.join(sub, "py_repos.tsv")
        with open(py_repos, "w", encoding="utf-8") as fh:
            fh.write("language\textensions\turl\tdefault_branch\tcommit\tlicense\n")
            fh.write("python\t.py\tfile://%s\tmain\t%s\tMIT\n" % (self.upstream_bare, self.pinned_commit))

        env_no_py = self._base_env(corpus_dir=sub, include_parsers=False)
        proc_py = self._run_extract(["--repos", py_repos, "--cases-out", os.path.join(sub, "c.tsv")], env_no_py)
        self.assertEqual(proc_py.returncode, 2)
        self.assertIn("没跑", proc_py.stdout + proc_py.stderr)

        ts_repos = os.path.join(sub, "ts_repos.tsv")
        with open(ts_repos, "w", encoding="utf-8") as fh:
            fh.write("language\textensions\turl\tdefault_branch\tcommit\tlicense\n")
            fh.write("typescript\t.ts,.tsx\tfile://%s\tmain\t%s\tMIT\n" % (self.upstream_bare, self.pinned_commit))

        proc_ts = self._run_extract(["--repos", ts_repos, "--cases-out", os.path.join(sub, "c2.tsv")], env_no_py)
        self.assertEqual(proc_ts.returncode, 2)
        self.assertIn("没跑", proc_ts.stdout + proc_ts.stderr)

    def test_parsers_module_accepts_valid_and_rejects_broken(self):
        env = self._base_env(corpus_dir=self.tmp_root, include_parsers=True)
        self.assertTrue(parsers.parse_bytes(b"let ok = 42\n", ".swift", env=env))
        self.assertFalse(parsers.parse_bytes(b"func broken( {\n", ".swift", env=env))

        self.assertTrue(parsers.parse_bytes(b"def f(x):\n    return x + 1\n", ".py", env=env))
        self.assertFalse(parsers.parse_bytes(b"def broken(:\n    pass\n", ".py", env=env))

        self.assertTrue(parsers.parse_bytes(b"export enum Kind { A = 1 }\n", ".ts", env=env))
        self.assertFalse(parsers.parse_bytes(b"export const x = SYNTAX_ERROR (((\n", ".ts", env=env))

    def test_fetch_count_extract_determinism_and_mutation_c(self):
        sub = tempfile.mkdtemp(dir=self.tmp_root)
        corpus_dir = os.path.join(sub, "corpus")
        os.makedirs(corpus_dir)
        repos_tsv = os.path.join(sub, "repos.tsv")
        with open(repos_tsv, "w", encoding="utf-8") as fh:
            fh.write("language\textensions\turl\tdefault_branch\tcommit\tlicense\n")
            fh.write(
                "swift\t.swift\tfile://%s\tmain\t%s\tMIT\n"
                % (self.upstream_bare, self.pinned_commit)
            )
        env = self._base_env(corpus_dir=corpus_dir, include_parsers=True)

        # 1. --fetch clones from local file:// URL into $RELAY_MERGE_CORPUS_DIR/bare/
        p_fetch = self._run_extract(["--repos", repos_tsv, "--fetch"], env)
        self.assertEqual(p_fetch.returncode, 0, msg=p_fetch.stderr)

        # 2. --count-only counts without creating extract/
        p_count = self._run_extract(["--repos", repos_tsv, "--count-only"], env)
        self.assertEqual(p_count.returncode, 0, msg=p_count.stderr)
        self.assertFalse(os.path.exists(os.path.join(corpus_dir, "extract")))

        # 3. Full extraction run #1 and run #2 -> identical cases.tsv sha256
        cases_1 = os.path.join(sub, "cases1.tsv")
        cases_2 = os.path.join(sub, "cases2.tsv")
        p_run1 = self._run_extract(
            ["--repos", repos_tsv, "--cases-out", cases_1, "--extract-subdir", "ext1", "--clean-sample", "5"],
            env,
        )
        self.assertEqual(p_run1.returncode, 0, msg=p_run1.stderr)
        p_run2 = self._run_extract(
            ["--repos", repos_tsv, "--cases-out", cases_2, "--extract-subdir", "ext2", "--clean-sample", "5"],
            env,
        )
        self.assertEqual(p_run2.returncode, 0, msg=p_run2.stderr)

        with open(cases_1, "rb") as fh:
            sha1 = hashlib.sha256(fh.read()).hexdigest()
        with open(cases_2, "rb") as fh:
            sha2 = hashlib.sha256(fh.read()).hexdigest()
        self.assertEqual(sha1, sha2)

        # 4. Inspect stats.tsv for exact merge and skip counts
        stats_path = os.path.join(corpus_dir, "ext1", "stats.tsv")
        with open(stats_path, encoding="utf-8") as fh:
            stats_rows = list(csv.DictReader(fh, delimiter="\t"))
        self.assertEqual(len(stats_rows), 1)
        st = {k: int(v) if v.isdigit() else v for k, v in stats_rows[0].items()}

        # On main: M1, M2, M3, M4, M5(octopus), M_criss1, M_criss2, M6(multi_base), M7(no_base)
        # Unmerged branch merge MUST NOT appear!
        self.assertEqual(st["skip_octopus"], 1)
        self.assertEqual(st["skip_multi_base"], 1)
        self.assertEqual(st["skip_no_base"], 1)
        self.assertEqual(st["two_parent_merges"], 8)  # M1, M2, M3, M4, M_criss1, M_criss2, M6, M7
        self.assertEqual(st["merges_single_base"], 6)  # M1, M2, M3, M4, M_criss1, M_criss2

        # Candidate .swift files: M1(3) + M2(1) + M3(1) + M4(5) = 10
        self.assertEqual(st["candidates"], 10)
        self.assertEqual(st["skip_not_modify_modify"], 1)
        self.assertEqual(st["skip_missing_blob"], 1)
        self.assertEqual(st["skip_sides_identical"], 1)
        self.assertEqual(st["skip_too_big"], 1)
        self.assertEqual(st["skip_not_utf8"], 1)
        self.assertEqual(st["skip_conflict_duplicate"], 1)
        self.assertEqual(st["git_clean_total"], 1)
        self.assertEqual(st["kept_conflict"], 3)  # dup_pure (first seen in rev-list), conflict_crlf, conflict_mod
        self.assertEqual(st["kept_clean"], 1)

        # Conservation check
        total_skips_vs_conflict = (
            st["skip_not_modify_modify"]
            + st["skip_missing_blob"]
            + st["skip_sides_identical"]
            + st["skip_too_big"]
            + st["skip_not_utf8"]
            + st["skip_conflict_duplicate"]
            + st["git_clean_total"]
        )
        self.assertEqual(st["candidates"], st["kept_conflict"] + total_skips_vs_conflict)

        # 5. Inspect cases.tsv rows
        with open(cases_1, encoding="utf-8") as fh:
            rows = list(csv.DictReader(fh, delimiter="\t"))
        self.assertEqual(len(rows), 4)  # 3 conflict + 1 clean
        by_path = {r["path"]: r for r in rows}
        self.assertIn("dup_pure.swift", by_path)
        self.assertNotIn("conflict_pure.swift", by_path)  # deduplicated (M2 is newer than M1 in rev-list)
        self.assertEqual(by_path["dup_pure.swift"]["pure_insertion"], "1")
        self.assertEqual(by_path["dup_pure.swift"]["human_eq"], "left")
        self.assertEqual(by_path["dup_pure.swift"]["human_parses"], "1")

        self.assertEqual(by_path["conflict_crlf.swift"]["pure_insertion"], "1")
        self.assertEqual(by_path["conflict_crlf.swift"]["human_eq"], "none")
        self.assertEqual(by_path["conflict_crlf.swift"]["human_parses"], "1")

        self.assertEqual(by_path["conflict_mod.swift"]["pure_insertion"], "0")
        self.assertEqual(by_path["conflict_mod.swift"]["human_eq"], "none")
        self.assertEqual(by_path["conflict_mod.swift"]["human_parses"], "0")

        self.assertEqual(by_path["clean.swift"]["kind"], "clean")
        self.assertEqual(by_path["clean.swift"]["myers_conflicts"], "0")

        # 6. --verify passes on clean output
        p_ver = self._run_extract(
            [
                "--repos", repos_tsv,
                "--cases-out", cases_1,
                "--extract-subdir", "ext1",
                "--verify",
                "--compare-cases", cases_2,
                "--allow-partial-repos",
                "--min-conflicts", "2",
            ],
            env,
        )
        self.assertEqual(p_ver.returncode, 0, msg=p_ver.stdout + p_ver.stderr)

        # 7. Mutation C simulation: relabel clean.swift as kind=conflict -> --verify Row 5 MUST fail
        mutated_cases = os.path.join(sub, "cases_mut_c.tsv")
        with open(cases_1, encoding="utf-8") as fh_in, open(mutated_cases, "w", encoding="utf-8") as fh_out:
            for line in fh_in:
                fh_out.write(line.replace("\tclean\t", "\tconflict\t"))
        p_mut = self._run_extract(
            [
                "--repos", repos_tsv,
                "--cases-out", mutated_cases,
                "--extract-subdir", "ext1",
                "--verify",
                "--allow-partial-repos",
                "--min-conflicts", "2",
            ],
            env,
        )
        self.assertNotEqual(p_mut.returncode, 0)
        self.assertIn("Row 5", p_mut.stdout + p_mut.stderr)

    def test_missing_git_object_fails_without_lazy_fetch(self):
        sub = tempfile.mkdtemp(dir=self.tmp_root)
        corpus_dir = os.path.join(sub, "corpus-corrupt")
        os.makedirs(corpus_dir)
        repos_tsv = os.path.join(sub, "repos.tsv")
        with open(repos_tsv, "w", encoding="utf-8") as fh:
            fh.write("language\textensions\turl\tdefault_branch\tcommit\tlicense\n")
            fh.write("swift\t.swift\tfile://%s\tmain\t%s\tMIT\n" % (self.upstream_bare, self.pinned_commit))
        env = self._base_env(corpus_dir=corpus_dir, include_parsers=True)
        self.assertEqual(self._run_extract(["--repos", repos_tsv, "--fetch"], env).returncode, 0)

        # Unpack objects into loose objects and delete one blob object to simulate missing object
        bare_dir = os.path.join(corpus_dir, "bare")
        cloned = os.path.join(bare_dir, os.listdir(bare_dir)[0])
        # Find a blob OID referenced at HEAD:clean.swift
        blob_oid = _run_git(cloned, ["rev-parse", "%s:clean.swift" % self.pinned_commit], env).stdout.decode("ascii").strip()
        pack_dir = os.path.join(cloned, "objects", "pack")
        if os.path.isdir(pack_dir):
            for fname in list(os.listdir(pack_dir)):
                if fname.endswith(".pack"):
                    with open(os.path.join(pack_dir, fname), "rb") as pfh:
                        pack_bytes = pfh.read()
                    os.remove(os.path.join(pack_dir, fname))
                    idx_path = os.path.join(pack_dir, fname[:-5] + ".idx")
                    if os.path.exists(idx_path):
                        os.remove(idx_path)
                    subprocess.run(
                        ["/usr/bin/git", "--git-dir=" + cloned, "unpack-objects"],
                        input=pack_bytes,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        check=True,
                        env=env,
                    )
        loose_path = os.path.join(cloned, "objects", blob_oid[:2], blob_oid[2:])
        self.assertTrue(os.path.exists(loose_path))
        os.chmod(loose_path, stat.S_IWUSR | stat.S_IRUSR)
        os.remove(loose_path)

        p_fail = self._run_extract(
            ["--repos", repos_tsv, "--cases-out", os.path.join(sub, "out.tsv")],
            env,
        )
        self.assertNotEqual(p_fail.returncode, 0)


if __name__ == "__main__":
    unittest.main()
