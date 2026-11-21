#!/usr/bin/env python3
"""Independent check that `RelayIDE semantic-merge` and `relay_semantic_merge` have been removed (M3, 2026-11-21).

Verifies via `Scripts/acceptance/relay-cli.sh` that:
  1. `RelayIDE --help` (`--lang en` and `--lang zh`) exits 0 and omits `semantic-merge` and `relay_semantic_merge`.
  2. `RelayIDE mcp` `tools/list` omits `relay_semantic_merge`, and `tools/call` on `relay_semantic_merge` returns
     the same unknown-tool error shape (`isError: True`, `"Unknown tool 'relay_semantic_merge'"`) as any other
     unknown tool.
  3. Invoking `RelayIDE semantic-merge <base> <left> <right> --lang <lang>` on every case in `--cases` (as well as
     with zero file arguments) exits `2` with empty stdout (`0` bytes) and an unknown-subcommand diagnostic on stderr,
     matching any other unknown subcommand.

Python 3.9 compatible, standard library only.
"""
import argparse
import json
import os
import subprocess
import sys


def run(cmd, env=None, stdin=None):
    proc = subprocess.run(cmd, env=env, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return proc.returncode, proc.stdout, proc.stderr


def check_help_and_mcp(cli):
    problems = []

    for help_lang in ("en", "zh"):
        code, out, err = run([cli, "--help", "--lang", help_lang])
        txt = out.decode("utf-8", "replace")
        if code != 0:
            problems.append("--help --lang %s exited %d: %s" % (help_lang, code, err.decode("utf-8", "replace").strip()))
        if "semantic-merge" in txt:
            problems.append("--help --lang %s still mentions semantic-merge" % help_lang)
        if "relay_semantic_merge" in txt:
            problems.append("--help --lang %s still mentions relay_semantic_merge" % help_lang)

    mcp_reqs = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "relay_semantic_merge",
                "arguments": {"path": "a.py", "base": "x = 1\n", "left": "x = 2\n", "right": "x = 1\n"},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "unknown_tool_probe", "arguments": {}},
        },
    ]
    payload = ("\n".join(json.dumps(r) for r in mcp_reqs) + "\n").encode("utf-8")
    code, out, err = run([cli, "mcp"], stdin=payload)
    if code != 0:
        problems.append("mcp exited %d: %s" % (code, err.decode("utf-8", "replace").strip()))
    else:
        replies = {}
        for line in out.decode("utf-8", "replace").splitlines():
            if line.strip():
                msg = json.loads(line)
                replies[msg.get("id")] = msg.get("result", {})
        tools = replies.get(2, {}).get("tools", [])
        names = [t.get("name") for t in tools]
        if "relay_semantic_merge" in names:
            problems.append("MCP tools/list still contains relay_semantic_merge: %r" % (names,))
        r_removed = replies.get(3, {})
        r_unknown = replies.get(4, {})
        if r_removed.get("isError") is not True or r_removed.get("content") != [
            {"type": "text", "text": "Unknown tool 'relay_semantic_merge'"}
        ]:
            problems.append("MCP tools/call relay_semantic_merge unexpected response: %r" % (r_removed,))
        if r_unknown.get("isError") is not True or r_unknown.get("content") != [
            {"type": "text", "text": "Unknown tool 'unknown_tool_probe'"}
        ]:
            problems.append("MCP tools/call unknown_tool_probe unexpected response: %r" % (r_unknown,))

    return problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cli", required=True, help="headless wrapper (Scripts/acceptance/relay-cli.sh)")
    ap.add_argument("--cases", required=True, help="directory with one sub-directory per case")
    ap.add_argument("--lang", default="en", choices=["en", "zh"])
    ap.add_argument(
        "--expect-all-exit",
        type=int,
        default=2,
        help="expected exit code for removed semantic-merge across all cases (default: 2)",
    )
    args = ap.parse_args()
    args.cli = os.path.abspath(args.cli)
    args.cases = os.path.abspath(args.cases)

    failures = check_help_and_mcp(args.cli)
    expected_token = "Unknown subcommand 'semantic-merge'" if args.lang == "en" else "未知子命令 'semantic-merge'"

    # Reference unknown subcommand probe
    probe_rc, probe_out, probe_err = run([args.cli, "semantic-merge", "--lang", args.lang])
    if probe_rc != args.expect_all_exit or probe_out != b"" or expected_token not in probe_err.decode("utf-8", "replace"):
        failures.append(
            "bare semantic-merge (--lang %s): expected exit %d / empty stdout / %r, got exit %d, stdout=%dB, stderr=%r"
            % (args.lang, args.expect_all_exit, expected_token, probe_rc, len(probe_out), probe_err.decode("utf-8", "replace").strip())
        )

    case_names = sorted(d for d in os.listdir(args.cases) if os.path.isdir(os.path.join(args.cases, d)))
    rows = []
    for name in case_names:
        cdir = os.path.join(args.cases, name)
        base_name = next(f for f in sorted(os.listdir(cdir)) if f.startswith("base."))
        ext = base_name.split(".", 1)[1]
        p_base, p_left, p_right = (os.path.join(cdir, "%s.%s" % (n, ext)) for n in ("base", "left", "right"))

        code, out, err = run([args.cli, "semantic-merge", p_base, p_left, p_right, "--lang", args.lang])
        err_txt = err.decode("utf-8", "replace").strip()
        case_problems = []
        if code != args.expect_all_exit:
            case_problems.append("expected exit %d, got %d" % (args.expect_all_exit, code))
        if out != b"":
            case_problems.append("expected empty stdout, got %d bytes" % len(out))
        if expected_token not in err_txt:
            case_problems.append("stderr missing %r: %r" % (expected_token, err_txt))

        rows.append((name, code, len(out), "OK" if not case_problems else "FAIL", err_txt))
        for p in case_problems:
            failures.append("%s: %s" % (name, p))

    print("| case | exit | stdout_bytes | check | stderr |")
    print("|---|---:|---:|---|---|")
    for row in rows:
        print("| %s | %d | %d | %s | %s |" % row)
    print(
        "\nSummary (%s, --lang %s): %d cases checked, all exited 2 as unknown subcommand: %s"
        % (os.path.basename(args.cases), args.lang, len(rows), "YES" if not failures else "NO")
    )
    if failures:
        for f in failures:
            print("FAIL: " + f, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
