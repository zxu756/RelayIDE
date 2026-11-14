#!/usr/bin/env python3
"""Independent check of `RelayIDE semantic-merge` on every case in Fixtures/merge-cases.

This file shares no code with the Swift implementation. For each case it runs the command, runs plain
`git merge-file -p` itself, and verifies with difflib and its own reading of `git merge-file --diff3`:

  exit 0  - git merges cleanly      -> stdout is git's text, byte for byte
          - git reports conflicts   -> every conflict block has an empty base side and stdout is git's text with
                                       each block replaced by left's lines followed by right's lines (or the reverse)
          - every line a side added (relative to base) is in stdout; every line neither side touched is in stdout,
            in order, byte-identical (blank lines included); stdout contains no line that neither side has
          - the language's own parser accepts stdout (py / swift / js / ts)
  exit 1  - git reports conflicts and stdout is git's conflict-marked text, byte for byte
  exit 3  - stdout is empty, git merged cleanly and the language's parser rejects git's text ("stricter")

Anything else fails. A case where git merges cleanly but the command reports a conflict is reported as "worse".
The expected exit code and strategy of each case are read from EXPECTED.tsv in the cases directory.
Python 3.9 compatible, standard library only.
"""
import argparse
import difflib
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

MARKER_BYTES = b"<|=>"


def run(cmd, env=None, cwd=None, stdin=None):
    proc = subprocess.run(cmd, env=env, cwd=cwd, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.returncode, proc.stdout, proc.stderr


def git_env(scratch):
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": scratch,
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
    }


def git_merge_file(scratch, left, base, right, extra=()):
    cmd = ["git", "merge-file", "-p", *extra, "-L", "left", "-L", "base", "-L", "right", left, base, right]
    code, out, err = run(cmd, env=git_env(scratch), cwd=scratch)
    if code < 0 or code > 127:
        raise RuntimeError("git merge-file failed (%d): %s" % (code, err.decode("utf-8", "replace")))
    return code, out


def lines_of(data):
    return data.splitlines(keepends=True)


def marker_size_for(*blobs):
    longest = 0
    for blob in blobs:
        for line in lines_of(blob):
            if line[:1] and line[:1] in MARKER_BYTES:
                first = line[:1]
                run_len = len(line) - len(line.lstrip(first))
                longest = max(longest, run_len)
    return max(7, longest + 1)


def parse_diff3(data, size):
    """Returns a list of ('stable', bytes) and ('conflict', left, base, right) or raises ValueError."""
    left_marker = b"<" * size + b" left\n"
    base_marker = b"|" * size + b" base\n"
    separator = b"=" * size + b"\n"
    right_marker = b">" * size + b" right\n"
    segments, state = [], "stable"
    stable, left, base, right = [], [], [], []
    for line in lines_of(data):
        if state == "stable":
            if line == left_marker:
                if stable:
                    segments.append(("stable", b"".join(stable)))
                    stable = []
                state = "left"
            elif line in (base_marker, separator, right_marker):
                raise ValueError("marker outside a conflict block")
            else:
                stable.append(line)
        elif state == "left":
            if line == base_marker:
                state = "base"
            elif line in (left_marker, separator, right_marker):
                raise ValueError("unexpected marker in left side")
            else:
                left.append(line)
        elif state == "base":
            if line == separator:
                state = "right"
            elif line in (left_marker, base_marker, right_marker):
                raise ValueError("unexpected marker in base side")
            else:
                base.append(line)
        else:
            if line == right_marker:
                segments.append(("conflict", b"".join(left), b"".join(base), b"".join(right)))
                left, base, right = [], [], []
                state = "stable"
            elif line in (left_marker, base_marker, separator):
                raise ValueError("unexpected marker in right side")
            else:
                right.append(line)
    if state != "stable":
        raise ValueError("unterminated conflict block")
    if stable:
        segments.append(("stable", b"".join(stable)))
    return segments


def keep_both_candidates_match(scratch, base, left, right, out):
    """True when `out` is git's --diff3 result with every (base-empty) conflict block replaced by left+right or right+left."""
    blobs = {"base": base, "left": left, "right": right}
    terminated = [b == b"" or b.endswith(b"\n") for b in blobs.values()]
    strip_final_newline = False
    if all(terminated):
        pass
    elif not any(terminated):
        blobs = {k: v + b"\n" for k, v in blobs.items()}
        strip_final_newline = True
    else:
        return False, "the three versions disagree about the final newline"
    paths = {}
    for name, blob in blobs.items():
        paths[name] = os.path.join(scratch, "d3-" + name)
        with open(paths[name], "wb") as fh:
            fh.write(blob)
    size = marker_size_for(*blobs.values())
    _, d3 = git_merge_file(scratch, paths["left"], paths["base"], paths["right"], ("--diff3", "--marker-size=%d" % size))
    try:
        segments = parse_diff3(d3, size)
    except ValueError as exc:
        return False, "cannot read --diff3 output: %s" % exc
    blocks = [s for s in segments if s[0] == "conflict"]
    if not blocks:
        return False, "no conflict block in --diff3 output"
    expected_out = out + b"\n" if strip_final_newline else out
    cursor = 0
    for seg in segments:
        if seg[0] == "stable":
            if not expected_out.startswith(seg[1], cursor):
                return False, "a part git merged without conflict is not byte-identical in the output"
            cursor += len(seg[1])
        else:
            _, l, b, r = seg
            if b:
                return False, "a conflict block with a non-empty base side was resolved"
            if expected_out.startswith(l + r, cursor) or expected_out.startswith(r + l, cursor):
                cursor += len(l) + len(r)
            else:
                return False, "a conflict block is not exactly left's lines plus right's lines"
    if cursor != len(expected_out):
        return False, "the output has extra bytes after the last part"
    return True, "%d conflict block(s), each both-sides insertion, both kept verbatim" % len(blocks)


def line_bookkeeping(base, left, right, out):
    """difflib-based, language-independent. Returns a list of problems (empty when all hold)."""
    problems = []
    bl, ll, rl, ol = lines_of(base), lines_of(left), lines_of(right), lines_of(out)
    cb, cl, cr, co = Counter(bl), Counter(ll), Counter(rl), Counter(ol)
    for name, table in (("left", cl), ("right", cr)):
        for line, count in table.items():
            added = count - cb.get(line, 0)
            if added > 0 and co.get(line, 0) < added:
                problems.append("line added by %s missing: %r" % (name, line))
    for line, count in co.items():
        if count > cl.get(line, 0) + cr.get(line, 0):
            problems.append("line in output that neither side has: %r" % line)

    def kept(side):
        matcher = difflib.SequenceMatcher(None, bl, side, autojunk=False)
        indices = set()
        for block in matcher.get_matching_blocks():
            indices.update(range(block.a, block.a + block.size))
        return indices

    untouched = [bl[i] for i in sorted(kept(ll) & kept(rl))]
    position = 0
    for line in untouched:
        try:
            position = ol.index(line, position) + 1
        except ValueError:
            problems.append("untouched base line missing or out of order: %r" % line)
            break
    return problems, len(untouched)


def parser_accepts(scratch, ext, data):
    """Returns (verdict, parser) where verdict is True / False / None (no parser for this extension)."""
    path = os.path.join(scratch, "syntax-check." + ext)
    with open(path, "wb") as fh:
        fh.write(data)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    if ext == "py":
        code, _, _ = run(["/usr/bin/python3", "-c", "import ast,sys; ast.parse(open(sys.argv[1],'rb').read())", path], env=env)
        return code == 0, "python3 ast.parse"
    if ext == "swift":
        code, _, _ = run(["/usr/bin/xcrun", "swiftc", "-parse", path], env=env)
        return code == 0, "swiftc -parse"
    if ext in ("js", "mjs", "cjs"):
        code, _, _ = run(["node", "--no-warnings", "--check", path], env=env)
        return code == 0, "node --check"
    if ext in ("ts", "tsx"):
        stripped = os.path.join(scratch, "syntax-check-stripped.js")
        script = ('const fs=require("fs"),m=require("module");'
                  'fs.writeFileSync(process.argv[2], m.stripTypeScriptTypes(fs.readFileSync(process.argv[1],"utf8")));')
        code, _, _ = run(["node", "--no-warnings", "-e", script, path, stripped], env=env)
        if code != 0:
            return False, "node stripTypeScriptTypes"
        code, _, _ = run(["node", "--no-warnings", "--check", stripped], env=env)
        return code == 0, "node stripTypeScriptTypes + --check"
    return None, "none"


def strategy_from(stderr):
    text = stderr.decode("utf-8", "replace")
    for token in ("line-level", "declaration-level", "none"):
        if "[strategy=%s]" % token in text:
            return token
    return "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True, help="headless wrapper (Scripts/acceptance/relay-cli.sh)")
    ap.add_argument("--cases", required=True, help="directory with one sub-directory per case")
    ap.add_argument("--lang", default="en", choices=["en", "zh"])
    ap.add_argument("--expect-all-exit", type=int, default=None,
                    help="ignore EXPECTED.tsv and require this exit code for every case (used for syntax-gate cases)")
    args = ap.parse_args()
    args.cli = os.path.abspath(args.cli)
    args.cases = os.path.abspath(args.cases)

    expected = {}
    manifest = os.path.join(args.cases, "EXPECTED.tsv")
    if args.expect_all_exit is None:
        with open(manifest, encoding="utf-8") as fh:
            for raw in fh:
                raw = raw.rstrip("\n")
                if not raw or raw.startswith("#"):
                    continue
                name, code, strategy = raw.split("\t")[:3]
                expected[name] = (int(code), strategy)

    case_names = sorted(d for d in os.listdir(args.cases) if os.path.isdir(os.path.join(args.cases, d)))
    if args.expect_all_exit is None and sorted(expected) != case_names:
        print("FAIL: EXPECTED.tsv does not list exactly the case directories", file=sys.stderr)
        return 1

    rows, failures = [], []
    scratch_root = tempfile.mkdtemp(prefix="relayide-merge-check.")
    try:
        for name in case_names:
            cdir = os.path.join(args.cases, name)
            base_name = next(f for f in sorted(os.listdir(cdir)) if f.startswith("base."))
            ext = base_name.split(".", 1)[1]
            p_base, p_left, p_right = (os.path.join(cdir, "%s.%s" % (n, ext)) for n in ("base", "left", "right"))
            base, left, right = (open(p, "rb").read() for p in (p_base, p_left, p_right))
            scratch = os.path.join(scratch_root, name)
            os.makedirs(scratch)

            code, out, err = run([args.cli, "semantic-merge", p_base, p_left, p_right, "--lang", args.lang])
            strategy = strategy_from(err)
            git_conflicts, git_out = git_merge_file(scratch, p_left, p_base, p_right)
            problems, notes = [], []

            if code == 0:
                book, untouched_count = line_bookkeeping(base, left, right, out)
                problems.extend(book)
                notes.append("added lines kept; %d untouched line(s) identical" % untouched_count)
                if git_conflicts == 0:
                    if out != git_out:
                        problems.append("git merges cleanly but the output is not git's text")
                    if strategy != "line-level":
                        problems.append("strategy reported as %s, expected line-level" % strategy)
                    versus = "same"
                else:
                    ok, why = keep_both_candidates_match(scratch, base, left, right, out)
                    notes.append(why)
                    if not ok:
                        problems.append(why)
                    if strategy != "declaration-level":
                        problems.append("strategy reported as %s, expected declaration-level" % strategy)
                    golden = os.path.join(cdir, "expected." + ext)
                    if not os.path.exists(golden):
                        problems.append("no hand-written expected.%s for a case git cannot merge" % ext)
                    elif open(golden, "rb").read() != out:
                        problems.append("output differs from the hand-written expected.%s" % ext)
                    versus = "better"
                verdict, parser = parser_accepts(scratch, ext, out)
                if verdict is False:
                    problems.append("exit 0 but %s rejects the output" % parser)
                notes.append("parser: %s" % (parser if verdict is not None else "none for .%s" % ext))
            elif code == 1:
                if git_conflicts == 0:
                    problems.append("exit 1 although git merges this cleanly")
                    versus = "worse"
                else:
                    versus = "same"
                if out != git_out:
                    problems.append("exit 1 but stdout is not git's conflict-marked text")
                if strategy != "none":
                    problems.append("strategy reported as %s, expected none" % strategy)
            elif code == 3:
                strategy = "-"
                versus = "stricter" if git_conflicts == 0 else "same"
                if out != b"":
                    problems.append("exit 3 but stdout is not empty (%d bytes)" % len(out))
                if git_conflicts != 0:
                    problems.append("exit 3 although git reports conflicts")
                else:
                    verdict, parser = parser_accepts(scratch, ext, git_out)
                    if verdict is not False:
                        problems.append("exit 3 but %s does not reject git's merged text" % parser)
                    notes.append("git's clean merge rejected by %s" % parser)
            else:
                versus = "?"
                problems.append("unexpected exit code %d: %s" % (code, err.decode("utf-8", "replace").strip()))

            if args.expect_all_exit is not None:
                if code != args.expect_all_exit:
                    problems.append("expected exit %d, got %d" % (args.expect_all_exit, code))
            else:
                exp_code, exp_strategy = expected[name]
                if (code, strategy) != (exp_code, exp_strategy):
                    problems.append("EXPECTED.tsv says exit %d / %s, got exit %d / %s" % (exp_code, exp_strategy, code, strategy))

            rows.append((name, code, strategy, "clean" if git_conflicts == 0 else "%d conflict(s)" % git_conflicts, versus,
                         "OK" if not problems else "FAIL", "; ".join(notes)))
            for problem in problems:
                failures.append("%s: %s" % (name, problem))
    finally:
        shutil.rmtree(scratch_root, ignore_errors=True)

    print("| case | exit | result used | git merge-file | vs git | check | notes |")
    print("|---|---|---|---|---|---|---|")
    for row in rows:
        print("| %s | %d | %s | %s | %s | %s | %s |" % row)
    codes = Counter(r[1] for r in rows)
    strategies = Counter(r[2] for r in rows if r[1] == 0)
    versus = Counter(r[4] for r in rows)
    print("")
    print("cases: %d; exit 0: %d (line-level %d, declaration-level %d); exit 1: %d; exit 3: %d; other: %d" % (
        len(rows), codes.get(0, 0), strategies.get("line-level", 0), strategies.get("declaration-level", 0),
        codes.get(1, 0), codes.get(3, 0), sum(v for k, v in codes.items() if k not in (0, 1, 3))))
    print("vs git merge-file: better %d, same %d, worse %d, stricter (git's clean text does not parse, nothing printed) %d" % (
        versus.get("better", 0), versus.get("same", 0), versus.get("worse", 0), versus.get("stricter", 0)))
    if failures:
        print("")
        for failure in failures:
            print("FAIL: " + failure)
        return 1
    print("all checks hold for every case (--lang %s)" % args.lang)
    return 0


if __name__ == "__main__":
    sys.exit(main())
