#!/usr/bin/env python3
"""Fixed syntax parsers for RelayIDE M3 merge evaluation.

Decoupled from the product's LanguageSyntaxValidator:
  - Python (.py): $RELAY_EVAL_PYTHON (>= 3.12) -I -c "ast.parse(...)"
  - Swift (.swift): swiftc -frontend -parse
  - TypeScript (.ts, .tsx): node + $RELAY_EVAL_TYPESCRIPT calling ts.createSourceFile
    and checking parseDiagnostics only (no type checking)
  - JavaScript (.js, .mjs, .cjs): node --no-warnings --check (used for fixed cases)

If a required environment variable or tool is not configured, raises ParserNotConfiguredError
whose message begins with "没跑：".
Python 3.9 compatible, standard library only.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
import shutil
import subprocess
import sys
import tempfile

ENV_PYTHON = "RELAY_EVAL_PYTHON"
ENV_TYPESCRIPT = "RELAY_EVAL_TYPESCRIPT"
ENV_SWIFTC = "RELAY_EVAL_SWIFTC"
ENV_NODE = "RELAY_EVAL_NODE"

_EXT_TO_LANG = {
    ".py": "python",
    ".swift": "swift",
    ".ts": "typescript",
    ".tsx": "typescript",
    ".js": "javascript",
    ".mjs": "javascript",
    ".cjs": "javascript",
}

_LANG_DEFAULT_EXT = {
    "python": ".py",
    "swift": ".swift",
    "typescript": ".ts",
    "javascript": ".js",
}

_PROBE_CACHE = {}

_PY_SINGLE_SNIPPET = (
    "import ast, sys, warnings\n"
    "warnings.simplefilter('ignore')\n"
    "data = open(sys.argv[1], 'rb').read()\n"
    "data.decode('utf-8')\n"
    "ast.parse(data, filename=sys.argv[1])\n"
)

_PY_BATCH_SNIPPET = (
    "import ast, sys, warnings\n"
    "warnings.simplefilter('ignore')\n"
    "payload = sys.stdin.buffer.read()\n"
    "items = payload.split(b'\\0') if payload else []\n"
    "for raw in items:\n"
    "    if not raw:\n"
    "        continue\n"
    "    p = raw.decode('utf-8')\n"
    "    try:\n"
    "        data = open(p, 'rb').read()\n"
    "        data.decode('utf-8')\n"
    "        ast.parse(data, filename=p)\n"
    "        sys.stdout.write('1\\n')\n"
    "    except (SyntaxError, ValueError, UnicodeDecodeError, RecursionError, MemoryError):\n"
    "        sys.stdout.write('0\\n')\n"
)

_TS_BATCH_SNIPPET = r"""
const fs = require("fs");
const path = require("path");
const { TextDecoder } = require("util");
const ts = require(process.argv[1]);
const decoder = new TextDecoder("utf-8", { fatal: true });
const input = fs.readFileSync(0, "utf8");
const lines = input.split("\n");
for (const line of lines) {
  if (!line.trim()) continue;
  const item = JSON.parse(line);
  let ok = false;
  try {
    const raw = fs.readFileSync(item.path);
    const text = decoder.decode(raw);
    const ext = (item.ext || path.extname(item.path) || ".ts").toLowerCase();
    let kind = ts.ScriptKind.TS;
    if (ext === ".tsx") kind = ts.ScriptKind.TSX;
    else if (ext === ".jsx") kind = ts.ScriptKind.JSX;
    else if (ext === ".js" || ext === ".mjs" || ext === ".cjs") kind = ts.ScriptKind.JS;
    const sf = ts.createSourceFile("check" + ext, text, ts.ScriptTarget.Latest, true, kind);
    const diags = sf.parseDiagnostics || [];
    ok = diags.length === 0;
  } catch (_) {
    ok = false;
  }
  process.stdout.write(ok ? "1\n" : "0\n");
}
"""


class ParserNotConfiguredError(RuntimeError):
    """Raised when a required fixed parser is not configured or unavailable."""


def _effective_env(env=None):
    base = dict(os.environ if env is None else env)
    base["PYTHONDONTWRITEBYTECODE"] = "1"
    return base


def normalize_extension(ext_or_path):
    if not ext_or_path:
        return ""
    if "." in os.path.basename(ext_or_path) and not ext_or_path.startswith("."):
        _, ext = os.path.splitext(ext_or_path)
    elif ext_or_path.startswith("."):
        ext = ext_or_path
    else:
        ext = "." + ext_or_path
    return ext.lower()


def language_for_extension(path_or_ext):
    ext = normalize_extension(path_or_ext)
    return _EXT_TO_LANG.get(ext)


def canonical_language(lang):
    if not lang:
        return None
    low = lang.strip().lower()
    aliases = {
        "py": "python",
        "python": "python",
        "swift": "swift",
        "ts": "typescript",
        "tsx": "typescript",
        "typescript": "typescript",
        "js": "javascript",
        "javascript": "javascript",
    }
    return aliases.get(low)


def _resolve_python(eff_env):
    py_bin = eff_env.get(ENV_PYTHON, "").strip()
    if not py_bin:
        raise ParserNotConfiguredError("没跑：未设置 %s" % ENV_PYTHON)
    if not (os.path.isfile(py_bin) and os.access(py_bin, os.X_OK)):
        raise ParserNotConfiguredError("没跑：找不到 %s 指定的解释器 (%s)" % (ENV_PYTHON, py_bin))
    cache_key = ("python", py_bin)
    if cache_key not in _PROBE_CACHE:
        proc = subprocess.run(
            [
                py_bin,
                "-I",
                "-c",
                "import sys; print('%d.%d.%d' % sys.version_info[:3]); sys.exit(0 if sys.version_info >= (3, 12) else 1)",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=eff_env,
        )
        ver = proc.stdout.strip()
        if proc.returncode != 0:
            raise ParserNotConfiguredError(
                "没跑：%s 需要 Python >= 3.12（当前：%s）" % (ENV_PYTHON, ver or "不可用")
            )
        _PROBE_CACHE[cache_key] = {"path": py_bin, "version": ver}
    return _PROBE_CACHE[cache_key]


def _resolve_swift(eff_env):
    swiftc_bin = eff_env.get(ENV_SWIFTC, "").strip()
    if not swiftc_bin:
        swiftc_bin = shutil.which("swiftc", path=eff_env.get("PATH")) or "/usr/bin/swiftc"
    if not (os.path.isfile(swiftc_bin) and os.access(swiftc_bin, os.X_OK)):
        raise ParserNotConfiguredError("没跑：找不到 swiftc")
    cache_key = ("swift", swiftc_bin)
    if cache_key not in _PROBE_CACHE:
        proc = subprocess.run(
            [swiftc_bin, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=eff_env,
        )
        if proc.returncode != 0:
            raise ParserNotConfiguredError("没跑：swiftc --version 失败")
        lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
        ver = " | ".join(lines) if lines else "unknown"
        _PROBE_CACHE[cache_key] = {"path": swiftc_bin, "version": ver}
    return _PROBE_CACHE[cache_key]


def _resolve_node(eff_env):
    node_bin = eff_env.get(ENV_NODE, "").strip()
    if not node_bin:
        node_bin = shutil.which("node", path=eff_env.get("PATH")) or ""
    if not node_bin:
        for candidate in ("/opt/homebrew/bin/node", "/usr/local/bin/node"):
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                node_bin = candidate
                break
    if not (node_bin and os.path.isfile(node_bin) and os.access(node_bin, os.X_OK)):
        raise ParserNotConfiguredError("没跑：找不到 node")
    cache_key = ("node", node_bin)
    if cache_key not in _PROBE_CACHE:
        proc = subprocess.run(
            [node_bin, "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=eff_env,
        )
        if proc.returncode != 0:
            raise ParserNotConfiguredError("没跑：node --version 失败")
        _PROBE_CACHE[cache_key] = {"path": node_bin, "version": proc.stdout.strip()}
    return _PROBE_CACHE[cache_key]


def _resolve_typescript(eff_env):
    ts_mod = eff_env.get(ENV_TYPESCRIPT, "").strip()
    if not ts_mod:
        raise ParserNotConfiguredError("没跑：未设置 %s" % ENV_TYPESCRIPT)
    ts_abs = os.path.abspath(ts_mod)
    if not os.path.exists(ts_abs):
        raise ParserNotConfiguredError("没跑：找不到 %s 指定的路径 (%s)" % (ENV_TYPESCRIPT, ts_mod))
    node_info = _resolve_node(eff_env)
    cache_key = ("typescript", node_info["path"], ts_abs)
    if cache_key not in _PROBE_CACHE:
        probe_js = (
            "const ts = require(process.argv[1]);"
            "if (typeof ts.createSourceFile !== 'function') process.exit(1);"
            "console.log(ts.version || 'unknown');"
        )
        proc = subprocess.run(
            [node_info["path"], "--no-warnings", "-e", probe_js, ts_abs],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=eff_env,
        )
        if proc.returncode != 0:
            raise ParserNotConfiguredError("没跑：无法加载 %s 指定的 typescript 模块" % ENV_TYPESCRIPT)
        _PROBE_CACHE[cache_key] = {
            "path": ts_abs,
            "version": proc.stdout.strip(),
            "node_path": node_info["path"],
            "node_version": node_info["version"],
        }
    return _PROBE_CACHE[cache_key]


def describe_parsers(languages=("python", "swift", "typescript"), env=None):
    eff_env = _effective_env(env)
    info = {}
    for raw_lang in languages:
        lang = canonical_language(raw_lang)
        if lang == "python":
            info["python"] = dict(_resolve_python(eff_env))
        elif lang == "swift":
            info["swift"] = dict(_resolve_swift(eff_env))
        elif lang == "typescript":
            info["typescript"] = dict(_resolve_typescript(eff_env))
        elif lang == "javascript":
            info["javascript"] = dict(_resolve_node(eff_env))
        else:
            raise ValueError("unknown parser language: %r" % (raw_lang,))
    return info


def _read_bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def _parse_swift_one(swiftc_bin, path, eff_env):
    try:
        raw = _read_bytes(path)
        raw.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    tmp_dir = tempfile.mkdtemp(prefix="relay-swift-parse.")
    try:
        chk = os.path.join(tmp_dir, "check.swift")
        with open(chk, "wb") as fh:
            fh.write(raw)
        proc = subprocess.run(
            [swiftc_bin, "-frontend", "-parse", chk],
            cwd=tmp_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=eff_env,
        )
        return proc.returncode == 0
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def _parse_js_one(node_bin, path, ext, eff_env):
    try:
        raw = _read_bytes(path)
        raw.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return False
    tmp_dir = tempfile.mkdtemp(prefix="relay-js-parse.")
    try:
        chk = os.path.join(tmp_dir, "check" + (ext if ext in (".js", ".mjs", ".cjs") else ".js"))
        with open(chk, "wb") as fh:
            fh.write(raw)
        proc = subprocess.run(
            [node_bin, "--no-warnings", "--check", chk],
            cwd=tmp_dir,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=eff_env,
        )
        return proc.returncode == 0
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def parse_file(path, lang=None, ext=None, env=None):
    eff_env = _effective_env(env)
    norm_ext = normalize_extension(ext) if ext else normalize_extension(path)
    resolved_lang = canonical_language(lang) if lang else language_for_extension(norm_ext)
    if resolved_lang is None:
        raise ValueError("unsupported file extension/language for fixed parser: path=%r ext=%r lang=%r" % (path, ext, lang))
    if not norm_ext:
        norm_ext = _LANG_DEFAULT_EXT[resolved_lang]

    if resolved_lang == "python":
        py_info = _resolve_python(eff_env)
        proc = subprocess.run(
            [py_info["path"], "-I", "-c", _PY_SINGLE_SNIPPET, path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=eff_env,
        )
        return proc.returncode == 0

    if resolved_lang == "swift":
        sw_info = _resolve_swift(eff_env)
        return _parse_swift_one(sw_info["path"], path, eff_env)

    if resolved_lang == "typescript":
        ts_info = _resolve_typescript(eff_env)
        payload = json.dumps({"path": os.path.abspath(path), "ext": norm_ext}) + "\n"
        proc = subprocess.run(
            [ts_info["node_path"], "--no-warnings", "-e", _TS_BATCH_SNIPPET, ts_info["path"]],
            input=payload.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=eff_env,
        )
        if proc.returncode != 0:
            raise RuntimeError("TypeScript parser batch failed: %s" % proc.stderr.decode("utf-8", "replace"))
        return proc.stdout.decode("ascii", "replace").strip() == "1"

    if resolved_lang == "javascript":
        node_info = _resolve_node(eff_env)
        return _parse_js_one(node_info["path"], path, norm_ext, eff_env)

    raise ValueError("unhandled language: %r" % (resolved_lang,))


def parse_bytes(data, ext, lang=None, env=None):
    norm_ext = normalize_extension(ext)
    if not norm_ext and lang:
        norm_ext = _LANG_DEFAULT_EXT.get(canonical_language(lang), ".txt")
    tmp_dir = tempfile.mkdtemp(prefix="relay-parse-bytes.")
    try:
        p = os.path.join(tmp_dir, "sample" + norm_ext)
        with open(p, "wb") as fh:
            fh.write(data)
        return parse_file(p, lang=lang, ext=norm_ext, env=env)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def parse_files_batch(items, env=None, max_workers=4):
    """Batch-parses a sequence of (path, ext) pairs and returns a list of booleans in input order."""
    if not items:
        return []
    eff_env = _effective_env(env)
    results = [False] * len(items)
    by_lang = {}
    for idx, item in enumerate(items):
        if isinstance(item, tuple):
            path, ext = item[0], normalize_extension(item[1])
        else:
            path, ext = item, normalize_extension(item)
        lang = language_for_extension(ext)
        if lang is None:
            raise ValueError("unsupported extension %r at index %d" % (ext, idx))
        by_lang.setdefault(lang, []).append((idx, path, ext))

    # Validate all needed parsers upfront before spending time parsing
    describe_parsers(sorted(by_lang.keys()), env=eff_env)

    if "python" in by_lang:
        py_info = _resolve_python(eff_env)
        py_entries = by_lang["python"]
        stdin_bytes = b"\0".join(os.path.abspath(p).encode("utf-8") for _, p, _ in py_entries)
        proc = subprocess.run(
            [py_info["path"], "-I", "-c", _PY_BATCH_SNIPPET],
            input=stdin_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=eff_env,
        )
        if proc.returncode != 0:
            raise RuntimeError("Python batch parser failed: %s" % proc.stderr.decode("utf-8", "replace"))
        verdicts = proc.stdout.decode("ascii").splitlines()
        if len(verdicts) != len(py_entries):
            raise RuntimeError("Python batch parser returned %d results for %d files" % (len(verdicts), len(py_entries)))
        for (idx, _, _), v in zip(py_entries, verdicts):
            results[idx] = v.strip() == "1"

    if "typescript" in by_lang:
        ts_info = _resolve_typescript(eff_env)
        ts_entries = by_lang["typescript"]
        payload = "".join(
            json.dumps({"path": os.path.abspath(p), "ext": ext}) + "\n"
            for _, p, ext in ts_entries
        ).encode("utf-8")
        proc = subprocess.run(
            [ts_info["node_path"], "--no-warnings", "-e", _TS_BATCH_SNIPPET, ts_info["path"]],
            input=payload,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=eff_env,
        )
        if proc.returncode != 0:
            raise RuntimeError("TypeScript batch parser failed: %s" % proc.stderr.decode("utf-8", "replace"))
        verdicts = proc.stdout.decode("ascii").splitlines()
        if len(verdicts) != len(ts_entries):
            raise RuntimeError(
                "TypeScript batch parser returned %d results for %d files" % (len(verdicts), len(ts_entries))
            )
        for (idx, _, _), v in zip(ts_entries, verdicts):
            results[idx] = v.strip() == "1"

    if "swift" in by_lang:
        sw_info = _resolve_swift(eff_env)
        sw_entries = by_lang["swift"]
        workers = max(1, int(max_workers))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            verdicts = list(
                pool.map(lambda entry: _parse_swift_one(sw_info["path"], entry[1], eff_env), sw_entries)
            )
        for (idx, _, _), ok in zip(sw_entries, verdicts):
            results[idx] = ok

    if "javascript" in by_lang:
        node_info = _resolve_node(eff_env)
        for idx, p, ext in by_lang["javascript"]:
            results[idx] = _parse_js_one(node_info["path"], p, ext, eff_env)

    return results


def main(argv=None):
    ap = argparse.ArgumentParser(description="Fixed syntax parsers for RelayIDE M3 evaluation")
    ap.add_argument("--describe", action="store_true", help="print configured parser paths and versions")
    ap.add_argument(
        "--languages",
        default="python,swift,typescript",
        help="comma-separated languages for --describe",
    )
    ap.add_argument("--check", metavar="FILE", help="syntax-check a single file")
    ap.add_argument("--ext", default=None, help="override file extension (e.g. .ts, .tsx, .py, .swift)")
    args = ap.parse_args(argv)

    try:
        if args.describe:
            langs = [x.strip() for x in args.languages.split(",") if x.strip()]
            info = describe_parsers(langs)
            for lang in langs:
                canon = canonical_language(lang)
                entry = info[canon]
                extra = ""
                if "node_version" in entry:
                    extra = "\tnode=%s (%s)" % (entry["node_version"], entry["node_path"])
                print("%s\t%s\t%s%s" % (canon, entry["version"], entry["path"], extra))
            return 0
        if args.check:
            ok = parse_file(args.check, ext=args.ext)
            return 0 if ok else 1
        ap.print_help(sys.stderr)
        return 2
    except ParserNotConfiguredError as exc:
        print(str(exc))
        return 2


if __name__ == "__main__":
    sys.exit(main())
