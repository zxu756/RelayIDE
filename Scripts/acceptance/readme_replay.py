#!/usr/bin/env python3
"""Replays the commands that README.md and README.zh-CN.md actually contain.

The commands are taken from the ```bash blocks of the two files, not from a copy kept in this script:
  * the two READMEs must contain the same commands, block by block (only `--lang <x>` may differ);
  * every command is classified, and a command this script cannot classify is an error, so a new README
    command can never go unverified silently;
  * commands that are safe to run are run verbatim, one bash process per block, from the repository root,
    with HOME, CFFIXED_USER_HOME and TMPDIR pointing into a scratch directory that is removed afterwards.

Classification:
  RUN             executed as written
  SKIP-AGENTS     `RelayIDE run ...` (launches coding agents via agent-relay; covered with stub agents by m1-run.sh and m2-merge.sh)
  SKIP-GUI        would open the desktop window (app bundle path, or a RelayIDE invocation whose first argument
                  is not a headless subcommand); never executed, the default UI state is covered by headless tests
  SKIP-RECURSIVE  ./Scripts/test.sh ... (this replay is itself part of that script)
  SKIP-PACKAGING  ./Scripts/build-app.sh (release build and code signing); executed only with --with-packaging

Usage:
  readme_replay.py --list README.md README.zh-CN.md        print the classification, execute nothing
  readme_replay.py --run  README.md README.zh-CN.md        compare, classify and execute
Python 3.9 compatible, standard library only.
"""
import argparse
import os
import shlex
import shutil
import subprocess
import sys
import tempfile

HEADLESS_SUBCOMMANDS = {
    "init", "status", "lanes", "dag-waves", "semantic-merge", "audit-plugins", "export-html", "mcp",
    "help", "--help", "-h", "version", "--version",
}
SHELL_OPERATORS = {"|", "||", "&&", ";", ">", ">>", "<", "2>", "2>&1", "&"}


def bash_blocks(path):
    """Returns a list of blocks; each block is a list of (line_number, text) for every line inside a ```bash fence."""
    blocks, current, inside = [], None, False
    with open(path, encoding="utf-8") as fh:
        for number, raw in enumerate(fh, start=1):
            line = raw.rstrip("\n")
            stripped = line.strip()
            if not inside and stripped.startswith("```"):
                info = stripped[3:].strip().lower()
                inside = True
                current = [] if info in ("bash", "sh", "shell", "zsh") else None
                continue
            if inside and stripped.startswith("```"):
                if current is not None:
                    blocks.append(current)
                inside, current = False, None
                continue
            if inside and current is not None:
                current.append((number, line))
    return blocks


def commands_of(block):
    """Drops blank lines and comment lines; joins backslash continuations."""
    commands, pending, pending_number = [], "", None
    for number, line in block:
        text = line.strip()
        if pending:
            pending += " " + text.rstrip("\\").strip()
            if not text.endswith("\\"):
                commands.append((pending_number, pending))
                pending, pending_number = "", None
            continue
        if not text or text.startswith("#"):
            continue
        if text.endswith("\\"):
            pending, pending_number = text.rstrip("\\").strip(), number
            continue
        commands.append((number, text))
    if pending:
        commands.append((pending_number, pending))
    return commands


def tokens_of(command):
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    return list(lexer)


def normalized(command):
    """Token list with `--lang <x>` / `--lang=<x>` removed, used only to compare the two READMEs."""
    out, skip = [], False
    for token in tokens_of(command):
        if skip:
            skip = False
            continue
        if token == "--lang":
            skip = True
            continue
        if token.startswith("--lang="):
            continue
        out.append(token)
    return out


def is_relay_executable(token):
    return os.path.basename(token) in ("RelayIDE", "relayide")


def classify(command):
    tokens = tokens_of(command)
    if not tokens:
        return "UNKNOWN", "empty command"
    relay_positions = [i for i, token in enumerate(tokens) if is_relay_executable(token)]
    if relay_positions:
        saw_skip_agents = None
        for position in relay_positions:
            executable = tokens[position]
            if ".app/Contents/MacOS/" in executable:
                return "SKIP-GUI", "application bundle executable"
            subcommand, skip = None, False
            for token in tokens[position + 1:]:
                if skip:
                    skip = False
                    continue
                if token in SHELL_OPERATORS:
                    break
                if token == "--lang":
                    skip = True
                    continue
                if token.startswith("--lang="):
                    continue
                subcommand = token
                break
            for token in tokens[position + 1:]:
                if token == "--export-screenshots" or token.startswith("--export-screenshots="):
                    return "SKIP-GUI", "--export-screenshots renders the desktop UI"
            if subcommand == "run":
                saw_skip_agents = "launches coding agents via agent-relay (covered with stub agents by m1-run.sh and m2-merge.sh)"
                continue
            if subcommand not in HEADLESS_SUBCOMMANDS:
                return "SKIP-GUI", "first argument %r is not a headless subcommand" % (subcommand,)
        if saw_skip_agents is not None:
            return "SKIP-AGENTS", saw_skip_agents
        return "RUN", "headless RelayIDE subcommand"
    head = tokens[0]
    if head in ("./Scripts/test.sh", "Scripts/test.sh"):
        return "SKIP-RECURSIVE", "this replay is part of Scripts/test.sh"
    if head in ("./Scripts/build-app.sh", "Scripts/build-app.sh"):
        return "SKIP-PACKAGING", "release build and code signing (use --with-packaging)"
    if tokens[:2] == ["swift", "build"]:
        return "RUN", "build"
    if "=" in head and head.split("=", 1)[0].isidentifier():
        return "RUN", "shell variable assignment"
    return "UNKNOWN", "no rule for %r" % head


def remove_block_work_dir(note_path):
    """Removes the directory a README block created with mktemp -d, if it is a direct child of a temp directory."""
    try:
        with open(note_path, encoding="utf-8") as fh:
            work = fh.read().strip()
        os.remove(note_path)
    except OSError:
        return
    if not work or not os.path.isdir(work) or os.path.islink(work):
        return
    temp_roots = {os.path.realpath(tempfile.gettempdir()), os.path.realpath("/tmp")}
    try:
        darwin_temp = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL).stdout.decode().strip()
        if darwin_temp:
            temp_roots.add(os.path.realpath(darwin_temp))
    except OSError:
        pass
    real = os.path.realpath(work)
    if os.path.dirname(real) in temp_roots and os.path.basename(real).startswith("tmp."):
        shutil.rmtree(real, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true")
    mode.add_argument("--run", action="store_true")
    ap.add_argument("--with-packaging", action="store_true")
    ap.add_argument("--repo-root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
    ap.add_argument("readmes", nargs="+")
    args = ap.parse_args()

    parsed = []
    for readme in args.readmes:
        blocks = [commands_of(block) for block in bash_blocks(readme)]
        parsed.append((readme, blocks))
        if not any(blocks):
            print("FAIL: %s contains no ```bash commands" % readme)
            return 1

    # 1. The READMEs must agree, block by block and command by command (language flag aside).
    reference_name, reference_blocks = parsed[0]
    agree = True
    for name, blocks in parsed[1:]:
        if len(blocks) != len(reference_blocks):
            print("FAIL: %s has %d bash blocks, %s has %d" % (reference_name, len(reference_blocks), name, len(blocks)))
            agree = False
            continue
        for index, (ref_block, block) in enumerate(zip(reference_blocks, blocks), start=1):
            ref_norm = sorted(normalized(c) for _, c in ref_block)
            norm = sorted(normalized(c) for _, c in block)
            if ref_norm != norm:
                agree = False
                print("FAIL: bash block %d differs between %s and %s" % (index, reference_name, name))
                for tokens in ref_norm:
                    if tokens not in norm:
                        print("  only in %s: %s" % (reference_name, " ".join(tokens)))
                for tokens in norm:
                    if tokens not in ref_norm:
                        print("  only in %s: %s" % (name, " ".join(tokens)))
    if not agree:
        return 1
    print("README command sets agree: %s (%d bash blocks, %d commands each)" % (
        ", ".join(name for name, _ in parsed), len(reference_blocks), sum(len(b) for b in reference_blocks)))

    # 2. Classify everything; refuse unknown commands.
    unknown = False
    plan = []
    for name, blocks in parsed:
        for index, block in enumerate(blocks, start=1):
            entries = []
            for number, command in block:
                kind, reason = classify(command)
                if kind == "SKIP-PACKAGING" and args.with_packaging:
                    kind, reason = "RUN", "packaging requested"
                if kind == "UNKNOWN":
                    unknown = True
                entries.append((number, command, kind, reason))
                print("%-14s %s:%d: %s%s" % (kind, os.path.basename(name), number, command,
                                               "" if kind == "RUN" else "   [" + reason + "]"))
            plan.append((name, index, entries))
    if unknown:
        print("FAIL: the README contains commands this replay cannot classify (see UNKNOWN above)")
        return 1
    if args.list:
        return 0

    # 3. Execute. One bash process per block so that shell variables set in the block stay visible.
    scratch = tempfile.mkdtemp(prefix="relayide-readme-replay.")
    home = os.path.join(scratch, "home")
    tmpdir = os.path.join(scratch, "tmp")
    os.makedirs(home)
    os.makedirs(tmpdir)
    env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home, TMPDIR=tmpdir)
    failed = False
    try:
        for name, index, entries in plan:
            runnable = [command for _, command, kind, _ in entries if kind == "RUN"]
            if not runnable:
                print("--- %s bash block %d: nothing to execute" % (os.path.basename(name), index))
                continue
            print("--- %s bash block %d: executing %d command(s) verbatim" % (os.path.basename(name), index, len(runnable)))
            sys.stdout.flush()
            # The README examples keep their files in WORK="$(mktemp -d)". macOS mktemp ignores TMPDIR, so the block
            # reports the directory it ended up with and it is removed below (only if it really is a temp directory).
            work_note = os.path.join(scratch, "work-dir-of-block")
            block_env = dict(env, RELAY_REPLAY_WORK_NOTE=work_note)
            script = ("set -euo pipefail\n"
                      "trap 'printf %s \"${WORK:-}\" > \"$RELAY_REPLAY_WORK_NOTE\"' EXIT\n"
                      "set -x\n" + "\n".join(runnable) + "\n")
            proc = subprocess.run(["/bin/bash", "-c", script], cwd=args.repo_root, env=block_env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            sys.stdout.write(proc.stdout.decode("utf-8", "replace"))
            sys.stdout.flush()
            remove_block_work_dir(work_note)
            if proc.returncode != 0:
                failed = True
                print("FAIL: %s bash block %d exited %d" % (os.path.basename(name), index, proc.returncode))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if failed:
        return 1
    print("every runnable README command exited 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
