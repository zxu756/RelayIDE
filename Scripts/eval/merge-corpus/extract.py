#!/usr/bin/env python3
"""Corpus extractor and verifier for RelayIDE M3 semantic merge evaluation.

Walks two-parent merges reachable from each repository's pinned default-branch commit in
Scripts/eval/merge-corpus/repos.tsv, extracts target-language files modified on both sides
where `git merge-file -p` reports a conflict (deduplicating identical (base,left,right)
triples in git rev-list order), samples 500 git-clean files with a fixed seed
(Python 167, Swift 167, TypeScript 166), checks whether the human merge version parses
under the fixed syntax parsers, and writes Fixtures/merge-corpus/cases.tsv plus case blobs
under $RELAY_MERGE_CORPUS_DIR/extract/.

Only `--fetch` clones repositories; every other mode sets GIT_NO_LAZY_FETCH=1 and fails on
missing git objects without network access.
Python 3.9 compatible, standard library only.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", "..", ".."))
DEFAULT_REPOS_TSV = os.path.join(SCRIPT_DIR, "repos.tsv")
DEFAULT_CASES_TSV = os.path.join(REPO_ROOT, "Fixtures", "merge-corpus", "cases.tsv")

if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import parsers  # noqa: E402

ENV_CORPUS_DIR = "RELAY_MERGE_CORPUS_DIR"
CLEAN_SAMPLE_SEED = 20261119
DEFAULT_CLEAN_QUOTAS = {
    "python": 167,
    "swift": 167,
    "typescript": 166,
}
LANGUAGE_ORDER = ("python", "swift", "typescript")
MAX_FILE_BYTES = 1_000_000
MARKER_CHARS = b"<|=>"

CASES_COLUMNS = (
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
)

STATS_COLUMNS = (
    "language",
    "repo",
    "commit",
    "commits_total",
    "merges_ge2",
    "skip_octopus",
    "two_parent_merges",
    "skip_no_base",
    "skip_multi_base",
    "merges_single_base",
    "merges_with_both_sides",
    "merges_with_both_sides_ext",
    "merges_with_conflict_ext",
    "files_both_sides",
    "candidates",
    "skip_not_modify_modify",
    "skip_missing_blob",
    "skip_sides_identical",
    "skip_too_big",
    "skip_not_utf8",
    "git_clean_total",
    "git_conflict_total",
    "skip_conflict_duplicate",
    "kept_conflict",
    "skip_clean_duplicate",
    "skip_clean_unsampled",
    "kept_clean",
    "histogram_conflict_total",
    "histogram_only_conflict",
    "myers_only_conflict",
    "conflict_pure_insertion",
    "conflict_human_eq_left",
    "conflict_human_eq_right",
    "conflict_human_parses",
    "conflict_human_unparsable",
    "clean_human_parses",
    "clean_human_unparsable",
    "seconds",
)


def repo_slug_and_bare_name(url):
    parsed = urlparse(url)
    raw_path = parsed.path.rstrip("/")
    if raw_path.endswith(".git"):
        raw_path = raw_path[:-4]
    parts = [p for p in raw_path.split("/") if p]
    if parsed.scheme in ("http", "https") and len(parts) >= 2:
        slug = "%s/%s" % (parts[-2], parts[-1])
    elif parts:
        slug = "local/%s" % parts[-1]
    else:
        raise ValueError("cannot derive repository name from url: %r" % (url,))
    bare_name = slug.replace("/", "__") + ".git"
    return slug, bare_name


def load_repos_manifest(path, repo_filters=None):
    rows = []
    with open(path, encoding="utf-8") as fh:
        reader = csv.DictReader(
            (line for line in fh if line.strip() and not line.lstrip().startswith("#")),
            delimiter="\t",
        )
        for raw in reader:
            lang = parsers.canonical_language(raw["language"])
            if lang not in LANGUAGE_ORDER:
                raise ValueError("unsupported language %r in %s" % (raw["language"], path))
            exts = tuple(
                parsers.normalize_extension(tok.strip())
                for tok in raw["extensions"].split(",")
                if tok.strip()
            )
            if not exts:
                raise ValueError("empty extensions for %r" % (raw,))
            url = raw["url"].strip()
            slug, bare_name = repo_slug_and_bare_name(url)
            entry = {
                "language": lang,
                "extensions": exts,
                "url": url,
                "default_branch": raw["default_branch"].strip(),
                "commit": raw["commit"].strip().lower(),
                "license": raw["license"].strip(),
                "slug": slug,
                "bare_name": bare_name,
            }
            if len(entry["commit"]) != 40 or any(c not in "0123456789abcdef" for c in entry["commit"]):
                raise ValueError("invalid 40-hex commit %r for %s" % (entry["commit"], slug))
            rows.append(entry)
    if repo_filters:
        wanted = set(repo_filters)
        rows = [r for r in rows if r["slug"] in wanted or r["url"] in wanted]
        if not rows:
            raise ValueError("no repository in %s matched --repo %r" % (path, repo_filters))
    return rows


def offline_git_env(empty_home):
    return {
        "PATH": "/usr/bin:/bin",
        "HOME": empty_home,
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_NO_LAZY_FETCH": "1",
    }


def run_bare_git(git_bin, bare_repo, args, env, ok=(0,)):
    cmd = [
        git_bin,
        "--no-optional-locks",
        "-c",
        "gc.auto=0",
        "-c",
        "maintenance.auto=false",
        "--git-dir=" + bare_repo,
    ] + list(args)
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if proc.returncode not in ok:
        raise RuntimeError(
            "git %s in %s exited %d: %s"
            % (
                " ".join(args),
                os.path.basename(bare_repo),
                proc.returncode,
                proc.stderr.decode("utf-8", "replace").strip()[:300],
            )
        )
    return proc


def parse_name_status_z(raw_bytes):
    tokens = raw_bytes.split(b"\0")
    result = {}
    i = 0
    n = len(tokens)
    while i + 1 < n:
        st_raw = tokens[i]
        if not st_raw:
            i += 1
            continue
        status = st_raw.decode("ascii", "replace")
        path = tokens[i + 1].decode("utf-8", "surrogateescape")
        if status.startswith(("R", "C")) and i + 2 < n:
            path2 = tokens[i + 2].decode("utf-8", "surrogateescape")
            result[path2] = status[:1]
            i += 3
        else:
            result[path] = status
            i += 2
    return result


def marker_size_for(*blobs):
    longest = 0
    for blob in blobs:
        for line in blob.splitlines(keepends=True):
            if line[:1] and line[:1] in MARKER_CHARS:
                ch = line[:1]
                run_len = len(line) - len(line.lstrip(ch))
                if run_len > longest:
                    longest = run_len
    return max(7, longest + 1)


def is_pure_insertion_diff3(git_bin, env, tmp_dir, left_path, base_path, right_path, vb, vl, vr):
    size = marker_size_for(vb, vl, vr)
    cmd = [
        git_bin,
        "merge-file",
        "-p",
        "--diff3",
        "--marker-size=%d" % size,
        "-L",
        "left",
        "-L",
        "base",
        "-L",
        "right",
        left_path,
        base_path,
        right_path,
    ]
    proc = subprocess.run(cmd, cwd=tmp_dir, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    if proc.returncode < 0 or proc.returncode > 127:
        raise RuntimeError(
            "git merge-file --diff3 failed (%d): %s"
            % (proc.returncode, proc.stderr.decode("utf-8", "replace"))
        )
    left_m = b"<" * size + b" left"
    base_m = b"|" * size + b" base"
    sep_m = b"=" * size
    right_m = b">" * size + b" right"

    state = "stable"
    blocks = 0
    base_lines = 0
    all_base_empty = True
    for raw_line in proc.stdout.splitlines(keepends=True):
        stripped = raw_line.rstrip(b"\r\n")
        if state == "stable":
            if stripped == left_m:
                state = "left"
                blocks += 1
                base_lines = 0
        elif state == "left":
            if stripped == base_m:
                state = "base"
        elif state == "base":
            if stripped == sep_m:
                if base_lines > 0:
                    all_base_empty = False
                state = "right"
            else:
                base_lines += 1
        elif state == "right":
            if stripped == right_m:
                state = "stable"
    if state != "stable" or blocks == 0:
        raise RuntimeError("failed to parse git merge-file --diff3 conflict markers (state=%s, blocks=%d)" % (state, blocks))
    return all_base_empty


class BatchBlobReader:
    def __init__(self, git_bin, bare_repo, env):
        self.git_bin = git_bin
        self.bare_repo = bare_repo
        self.env = env
        self.proc = subprocess.Popen(
            [
                git_bin,
                "--no-optional-locks",
                "-c",
                "gc.auto=0",
                "-c",
                "maintenance.auto=false",
                "--git-dir=" + bare_repo,
                "cat-file",
                "--batch",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )

    def close(self):
        if self.proc is None:
            return
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            if self.proc.stdout:
                self.proc.stdout.close()
            if self.proc.stderr:
                self.proc.stderr.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        finally:
            self.proc = None

    def read_blob(self, commit_oid, rel_path):
        """Returns (blob_oid, data_bytes) or None if path is absent or non-blob in commit's tree.
        Raises RuntimeError if the tree references a blob OID whose object is missing.
        """
        spec_bytes = commit_oid.encode("ascii") + b":" + rel_path.encode("utf-8", "surrogateescape") + b"\n"
        self.proc.stdin.write(spec_bytes)
        self.proc.stdin.flush()
        hdr = self.proc.stdout.readline()
        if not hdr:
            err = self.proc.stderr.read().decode("utf-8", "replace")
            raise RuntimeError("git cat-file --batch terminated unexpectedly: %s" % err)
        if hdr.endswith(b" missing\n") or hdr == b"missing\n":
            # Verify whether `rel_path` is genuinely absent/non-blob in `commit_oid`'s tree vs missing blob object
            ls_proc = run_bare_git(
                self.git_bin,
                self.bare_repo,
                ["ls-tree", "-z", commit_oid, "--", rel_path],
                self.env,
            )
            if ls_proc.stdout:
                for entry in ls_proc.stdout.split(b"\0"):
                    if not entry or b"\t" not in entry:
                        continue
                    meta = entry.split(b"\t", 1)[0].decode("ascii", "replace").split()
                    if len(meta) >= 3 and meta[1] == "blob":
                        raise RuntimeError(
                            "missing git blob object %s for %s:%s (GIT_NO_LAZY_FETCH=1)"
                            % (meta[2], commit_oid, rel_path)
                        )
            return None

        parts = hdr.rstrip(b"\n").split()
        if len(parts) < 3:
            raise RuntimeError("unexpected cat-file header: %r" % (hdr,))
        oid = parts[0].decode("ascii")
        obj_type = parts[1]
        size = int(parts[2])
        data = self.proc.stdout.read(size)
        if len(data) != size:
            raise RuntimeError("short read from cat-file --batch for %s (%d != %d)" % (oid, len(data), size))
        trailing = self.proc.stdout.read(1)
        if trailing != b"\n":
            raise RuntimeError("expected newline after blob %s, got %r" % (oid, trailing))
        if obj_type != b"blob":
            return None
        return oid, data


def triple_digest(vb, vl, vr):
    h = hashlib.sha256()
    for part in (vb, vl, vr):
        h.update(b"%d:" % len(part))
        h.update(part)
        h.update(b"\0")
    return h.hexdigest()


def inspect_merge_worker(args):
    git_bin, bare_repo, env, exts, m, p1, p2 = args
    mb = run_bare_git(git_bin, bare_repo, ["merge-base", "--all", p1, p2], env, ok=(0, 1))
    bases = mb.stdout.decode("ascii").split()
    if len(bases) == 0:
        return ("no_base", m, p1, p2, None, 0, [])
    if len(bases) > 1:
        return ("multi_base", m, p1, p2, None, 0, [])
    base = bases[0]
    d1 = parse_name_status_z(
        run_bare_git(git_bin, bare_repo, ["diff", "--no-renames", "--name-status", "-z", base, p1], env).stdout
    )
    d2 = parse_name_status_z(
        run_bare_git(git_bin, bare_repo, ["diff", "--no-renames", "--name-status", "-z", base, p2], env).stdout
    )
    both = sorted(set(d1.keys()) & set(d2.keys()))
    if not both:
        return ("single_base", m, p1, p2, base, 0, [])
    both_ext = [(f, d1[f], d2[f]) for f in both if f.lower().endswith(exts)]
    return ("single_base", m, p1, p2, base, len(both), both_ext)


def detect_spdx_license(text):
    norm = " ".join(text.split())
    low = norm.lower()
    if "permission is hereby granted, free of charge" in low and "furnished to do so" in low:
        return "MIT"
    if "apache license" in low and "version 2.0" in low:
        return "Apache-2.0"
    if "redistribution and use in source and binary forms" in low:
        if (
            "neither the name" in low
            or "bsd 3-clause" in low
            or "3-clause bsd" in low
            or "endorse or promote products" in low
        ):
            return "BSD-3-Clause"
        return "BSD-2-Clause"
    return "UNKNOWN"


def find_repo_license_at_commit(git_bin, bare_repo, commit_oid, env):
    tree = run_bare_git(git_bin, bare_repo, ["ls-tree", "--name-only", commit_oid], env).stdout.decode(
        "utf-8", "replace"
    )
    names = [n.strip() for n in tree.splitlines() if n.strip()]
    preferred = []
    for n in names:
        up = n.upper()
        if up.startswith("LICENSE") or up.startswith("LICENCE"):
            preferred.append((0, n))
        elif up.startswith("COPYING"):
            preferred.append((1, n))
    preferred.sort()
    if not preferred:
        return None, "NONE"
    for _, fname in preferred:
        blob = run_bare_git(git_bin, bare_repo, ["show", "%s:%s" % (commit_oid, fname)], env).stdout
        spdx = detect_spdx_license(blob.decode("utf-8", "replace"))
        if spdx != "UNKNOWN":
            return fname, spdx
    fname = preferred[0][1]
    blob = run_bare_git(git_bin, bare_repo, ["show", "%s:%s" % (commit_oid, fname)], env).stdout
    return fname, detect_spdx_license(blob.decode("utf-8", "replace"))


def do_fetch(git_bin, corpus_dir, repos):
    bare_root = os.path.join(corpus_dir, "bare")
    os.makedirs(bare_root, exist_ok=True)
    empty_home = tempfile.mkdtemp(prefix="relay-fetch-home.")
    try:
        fetch_env = {
            "PATH": "/usr/bin:/bin",
            "HOME": empty_home,
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
        }
        check_env = offline_git_env(empty_home)
        for repo in repos:
            dest = os.path.join(bare_root, repo["bare_name"])
            if not os.path.isdir(dest):
                t0 = time.time()
                proc = subprocess.run(
                    [git_bin, "-c", "credential.helper=", "clone", "--bare", "--quiet", repo["url"], dest],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=fetch_env,
                )
                if proc.returncode != 0:
                    raise RuntimeError(
                        "clone failed for %s (%d): %s"
                        % (repo["url"], proc.returncode, proc.stderr.decode("utf-8", "replace").strip())
                    )
                print("cloned\t%s\t%.1fs" % (repo["slug"], time.time() - t0))
            run_bare_git(git_bin, dest, ["rev-parse", "--verify", repo["commit"] + "^{commit}"], check_env)
            print("verified\t%s\t%s" % (repo["slug"], repo["commit"]))
    finally:
        shutil.rmtree(empty_home, ignore_errors=True)
    return 0


def init_repo_stats(repo):
    st = {k: 0 for k in STATS_COLUMNS}
    st["language"] = repo["language"]
    st["repo"] = repo["slug"]
    st["commit"] = repo["commit"]
    st["seconds"] = 0.0
    return st


def process_single_repo(
    git_bin,
    bare_repo,
    repo,
    git_env,
    seen_conflict_triples,
    seen_clean_triples,
    conflict_records,
    clean_pool,
    workers,
):
    t0 = time.time()
    st = init_repo_stats(repo)
    commit = repo["commit"]
    exts = repo["extensions"]

    if not os.path.isdir(bare_repo):
        raise RuntimeError("missing bare repository %s (run with --fetch first)" % bare_repo)

    # Verify pinned commit object exists without lazy fetch
    run_bare_git(git_bin, bare_repo, ["rev-parse", "--verify", commit + "^{commit}"], git_env)
    st["commits_total"] = int(
        run_bare_git(git_bin, bare_repo, ["rev-list", "--count", commit], git_env).stdout.decode("ascii").strip()
    )

    rev_lines = (
        run_bare_git(git_bin, bare_repo, ["rev-list", "--parents", "--min-parents=2", commit], git_env)
        .stdout.decode("ascii")
        .splitlines()
    )
    st["merges_ge2"] = len(rev_lines)
    two_parent = []
    for ln in rev_lines:
        parts = ln.split()
        if len(parts) > 3:
            st["skip_octopus"] += 1
        elif len(parts) == 3:
            two_parent.append((parts[0], parts[1], parts[2]))
    st["two_parent_merges"] = len(two_parent)

    work_items = [(git_bin, bare_repo, git_env, exts, m, p1, p2) for (m, p1, p2) in two_parent]
    with ThreadPoolExecutor(max_workers=max(1, int(workers))) as pool:
        inspected = list(pool.map(inspect_merge_worker, work_items))

    tmp_merge_dir = tempfile.mkdtemp(prefix="relay-mergefile.")
    reader = BatchBlobReader(git_bin, bare_repo, git_env)
    try:
        l_file = os.path.join(tmp_merge_dir, "left")
        b_file = os.path.join(tmp_merge_dir, "base")
        r_file = os.path.join(tmp_merge_dir, "right")

        for kind, m, p1, p2, base, n_both_all, both_ext in inspected:
            if kind == "no_base":
                st["skip_no_base"] += 1
                continue
            if kind == "multi_base":
                st["skip_multi_base"] += 1
                continue
            st["merges_single_base"] += 1
            if n_both_all == 0:
                continue
            st["merges_with_both_sides"] += 1
            st["files_both_sides"] += n_both_all
            if not both_ext:
                continue
            st["merges_with_both_sides_ext"] += 1

            had_conflict_in_merge = False
            for path, st1, st2 in both_ext:
                st["candidates"] += 1
                if "\t" in path or "\n" in path or "\r" in path:
                    st["skip_not_utf8"] += 1
                    continue
                try:
                    path.encode("utf-8")
                except UnicodeEncodeError:
                    st["skip_not_utf8"] += 1
                    continue

                if st1 != "M" or st2 != "M":
                    st["skip_not_modify_modify"] += 1
                    continue

                rb = reader.read_blob(base, path)
                rl = reader.read_blob(p1, path)
                rr = reader.read_blob(p2, path)
                rh = reader.read_blob(m, path)
                if rb is None or rl is None or rr is None or rh is None:
                    st["skip_missing_blob"] += 1
                    continue

                oid_b, vb = rb
                oid_l, vl = rl
                oid_r, vr = rr
                oid_h, vh = rh

                if vl == vr:
                    st["skip_sides_identical"] += 1
                    continue

                if max(len(vb), len(vl), len(vr), len(vh)) > MAX_FILE_BYTES:
                    st["skip_too_big"] += 1
                    continue

                try:
                    vb.decode("utf-8")
                    vl.decode("utf-8")
                    vr.decode("utf-8")
                    vh.decode("utf-8")
                except UnicodeDecodeError:
                    st["skip_not_utf8"] += 1
                    continue

                with open(l_file, "wb") as fh:
                    fh.write(vl)
                with open(b_file, "wb") as fh:
                    fh.write(vb)
                with open(r_file, "wb") as fh:
                    fh.write(vr)

                pm = subprocess.run(
                    [git_bin, "merge-file", "-p", l_file, b_file, r_file],
                    cwd=tmp_merge_dir,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=git_env,
                )
                if pm.returncode < 0 or pm.returncode > 127:
                    raise RuntimeError(
                        "git merge-file failed (%d): %s"
                        % (pm.returncode, pm.stderr.decode("utf-8", "replace"))
                    )
                ph = subprocess.run(
                    [git_bin, "merge-file", "-p", "--diff-algorithm=histogram", l_file, b_file, r_file],
                    cwd=tmp_merge_dir,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=git_env,
                )
                if ph.returncode < 0 or ph.returncode > 127:
                    raise RuntimeError(
                        "git merge-file histogram failed (%d): %s"
                        % (ph.returncode, ph.stderr.decode("utf-8", "replace"))
                    )

                myers_rc = pm.returncode
                hist_rc = ph.returncode
                if hist_rc > 0:
                    st["histogram_conflict_total"] += 1
                if hist_rc > 0 and myers_rc == 0:
                    st["histogram_only_conflict"] += 1
                if myers_rc > 0 and hist_rc == 0:
                    st["myers_only_conflict"] += 1

                if vh == vl:
                    human_eq = "left"
                elif vh == vr:
                    human_eq = "right"
                else:
                    human_eq = "none"

                digest = triple_digest(vb, vl, vr)
                ext = parsers.normalize_extension(path)

                if myers_rc == 0:
                    st["git_clean_total"] += 1
                    if digest in seen_clean_triples:
                        st["skip_clean_duplicate"] += 1
                    else:
                        seen_clean_triples.add(digest)
                        clean_pool.append(
                            {
                                "kind": "clean",
                                "language": repo["language"],
                                "repo": repo["slug"],
                                "merge": m,
                                "p1": p1,
                                "p2": p2,
                                "base": base,
                                "path": path,
                                "ext": ext,
                                "blob_base": oid_b,
                                "blob_left": oid_l,
                                "blob_right": oid_r,
                                "blob_human": oid_h,
                                "vb": vb,
                                "vl": vl,
                                "vr": vr,
                                "vh": vh,
                                "myers_conflicts": 0,
                                "histogram_conflicts": hist_rc,
                                "pure_insertion": 0,
                                "human_eq": human_eq,
                            }
                        )
                    continue

                st["git_conflict_total"] += 1
                had_conflict_in_merge = True
                if digest in seen_conflict_triples:
                    st["skip_conflict_duplicate"] += 1
                    continue
                seen_conflict_triples.add(digest)

                pure = 1 if is_pure_insertion_diff3(git_bin, git_env, tmp_merge_dir, l_file, b_file, r_file, vb, vl, vr) else 0
                st["kept_conflict"] += 1
                st["conflict_pure_insertion"] += pure
                if human_eq == "left":
                    st["conflict_human_eq_left"] += 1
                elif human_eq == "right":
                    st["conflict_human_eq_right"] += 1

                conflict_records.append(
                    {
                        "kind": "conflict",
                        "language": repo["language"],
                        "repo": repo["slug"],
                        "merge": m,
                        "p1": p1,
                        "p2": p2,
                        "base": base,
                        "path": path,
                        "ext": ext,
                        "blob_base": oid_b,
                        "blob_left": oid_l,
                        "blob_right": oid_r,
                        "blob_human": oid_h,
                        "vb": vb,
                        "vl": vl,
                        "vr": vr,
                        "vh": vh,
                        "myers_conflicts": myers_rc,
                        "histogram_conflicts": hist_rc,
                        "pure_insertion": pure,
                        "human_eq": human_eq,
                    }
                )

            if had_conflict_in_merge:
                st["merges_with_conflict_ext"] += 1
    finally:
        reader.close()
        shutil.rmtree(tmp_merge_dir, ignore_errors=True)

    st["seconds"] = round(time.time() - t0, 1)
    return st


def sample_clean_records(clean_pools_by_lang, clean_sample_override=None):
    rng = random.Random(CLEAN_SAMPLE_SEED)
    sampled = []
    for lang in LANGUAGE_ORDER:
        pool = clean_pools_by_lang.get(lang, [])
        if not pool:
            continue
        quota = clean_sample_override if clean_sample_override is not None else DEFAULT_CLEAN_QUOTAS[lang]
        take = min(int(quota), len(pool))
        chosen_indices = sorted(rng.sample(range(len(pool)), take))
        for idx in chosen_indices:
            sampled.append(pool[idx])
    return sampled


def print_stats_summary(repo_stats_list):
    print("\t".join(STATS_COLUMNS))
    for st in repo_stats_list:
        print("\t".join(str(st[col]) for col in STATS_COLUMNS))

    # Also print per-language rollups
    by_lang = {}
    for st in repo_stats_list:
        lang = st["language"]
        if lang not in by_lang:
            agg = {col: 0 for col in STATS_COLUMNS}
            agg["language"] = lang
            agg["repo"] = "TOTAL:" + lang
            agg["commit"] = "-"
            agg["seconds"] = 0.0
            by_lang[lang] = agg
        agg = by_lang[lang]
        for col in STATS_COLUMNS:
            if col in ("language", "repo", "commit"):
                continue
            if col == "seconds":
                agg[col] = round(agg[col] + float(st[col]), 1)
            else:
                agg[col] += int(st[col])
    for lang in LANGUAGE_ORDER:
        if lang in by_lang:
            print("\t".join(str(by_lang[lang][col]) for col in STATS_COLUMNS))


def _sha256_file(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def verify_corpus(
    git_bin,
    corpus_dir,
    repos,
    extract_subdir,
    cases_path,
    compare_cases_path=None,
    allow_partial_repos=False,
    min_conflicts=200,
    workers=4,
):
    failures = []
    empty_home = tempfile.mkdtemp(prefix="relay-verify-home.")
    try:
        git_env = offline_git_env(empty_home)
        bare_root = os.path.join(corpus_dir, "bare")

        # Row 1: repos.tsv structure + LICENSE verification at pinned commit
        if not allow_partial_repos:
            for lang in LANGUAGE_ORDER:
                n_lang = sum(1 for r in repos if r["language"] == lang)
                if n_lang != 3:
                    failures.append("Row 1: expected 3 repositories for %s in repos.tsv, got %d" % (lang, n_lang))
        for r in repos:
            bdir = os.path.join(bare_root, r["bare_name"])
            if not os.path.isdir(bdir):
                failures.append("Row 1: missing bare repository %s" % bdir)
                continue
            lic_file, detected = find_repo_license_at_commit(git_bin, bdir, r["commit"], git_env)
            if detected != r["license"]:
                failures.append(
                    "Row 1: %s license mismatch at %s (%s): repos.tsv=%s vs detected=%s"
                    % (r["slug"], r["commit"][:10], lic_file, r["license"], detected)
                )
            else:
                print(
                    "PASS [Row 1]: %s commit=%s license=%s (%s)"
                    % (r["slug"], r["commit"][:10], detected, lic_file)
                )

        # Row 2 (optional sha256 comparison between two runs)
        if not os.path.isfile(cases_path):
            failures.append("Row 2/3/4/5: missing cases.tsv at %s" % cases_path)
            for f in failures:
                print("FAIL: " + f, file=sys.stderr)
            return 1

        cases_sha = _sha256_file(cases_path)
        print("INFO: cases.tsv sha256 = %s" % cases_sha)
        if compare_cases_path:
            other_sha = _sha256_file(compare_cases_path)
            if cases_sha != other_sha:
                failures.append("Row 2: cases.tsv sha256 mismatch (%s != %s)" % (cases_sha, other_sha))
            else:
                print("PASS [Row 2]: identical sha256 across two runs (%s)" % cases_sha)

        with open(cases_path, encoding="utf-8") as fh:
            case_rows = list(csv.DictReader(fh, delimiter="\t"))

        # Row 3: conservation check on stats.tsv & cross-check with cases.tsv
        stats_path = os.path.join(corpus_dir, extract_subdir, "stats.tsv")
        if not os.path.isfile(stats_path):
            failures.append("Row 3: missing stats.tsv at %s" % stats_path)
        else:
            with open(stats_path, encoding="utf-8") as fh:
                stats_rows = list(csv.DictReader(fh, delimiter="\t"))
            for sr in stats_rows:
                slug = sr["repo"]
                m_ge2 = int(sr["merges_ge2"])
                m_sum = int(sr["skip_octopus"]) + int(sr["skip_no_base"]) + int(sr["skip_multi_base"]) + int(sr["merges_single_base"])
                if m_ge2 != m_sum:
                    failures.append("Row 3: merge sum mismatch for %s (%d != %d)" % (slug, m_ge2, m_sum))

                cand = int(sr["candidates"])
                kept_conf = int(sr["kept_conflict"])
                kept_cln = int(sr["kept_clean"])
                skips_conf_view = (
                    int(sr["skip_not_modify_modify"])
                    + int(sr["skip_missing_blob"])
                    + int(sr["skip_sides_identical"])
                    + int(sr["skip_too_big"])
                    + int(sr["skip_not_utf8"])
                    + int(sr["skip_conflict_duplicate"])
                    + int(sr["git_clean_total"])
                )
                skips_all_view = (
                    int(sr["skip_not_modify_modify"])
                    + int(sr["skip_missing_blob"])
                    + int(sr["skip_sides_identical"])
                    + int(sr["skip_too_big"])
                    + int(sr["skip_not_utf8"])
                    + int(sr["skip_conflict_duplicate"])
                    + int(sr["skip_clean_duplicate"])
                    + int(sr["skip_clean_unsampled"])
                )
                if cand != kept_conf + skips_conf_view:
                    failures.append(
                        "Row 3: candidate conservation (conflict view) failed for %s (%d != %d + %d)"
                        % (slug, cand, kept_conf, skips_conf_view)
                    )
                if cand != (kept_conf + kept_cln) + skips_all_view:
                    failures.append(
                        "Row 3: candidate conservation (total kept view) failed for %s (%d != %d + %d)"
                        % (slug, cand, kept_conf + kept_cln, skips_all_view)
                    )
            if not any(f.startswith("Row 3:") for f in failures):
                print("PASS [Row 3]: candidate == kept + sum(skips) holds for all %d repo(s)" % len(stats_rows))

        # Row 4: per-language deduplicated, human-parsable conflict count >= min_conflicts
        active_langs = sorted({r["language"] for r in repos}, key=lambda x: LANGUAGE_ORDER.index(x))
        seen_triples_check = set()
        dup_in_cases = 0
        for cr in case_rows:
            if cr["kind"] == "conflict":
                key = (cr["language"], cr["blob_base"], cr["blob_left"], cr["blob_right"])
                if key in seen_triples_check:
                    dup_in_cases += 1
                seen_triples_check.add(key)
        if dup_in_cases > 0:
            failures.append("Row 4: found %d duplicate (base,left,right) triples in conflict rows" % dup_in_cases)

        for lang in active_langs:
            n_conf_total = sum(1 for cr in case_rows if cr["language"] == lang and cr["kind"] == "conflict")
            n_conf_parsable = sum(
                1
                for cr in case_rows
                if cr["language"] == lang and cr["kind"] == "conflict" and cr["human_parses"] == "1"
            )
            if n_conf_parsable < min_conflicts:
                failures.append(
                    "Row 4: %s deduplicated parsable conflict count %d < %d (total=%d)"
                    % (lang, n_conf_parsable, min_conflicts, n_conf_total)
                )
            else:
                print(
                    "PASS [Row 4]: %s deduplicated parsable conflicts = %d (total=%d, threshold=%d)"
                    % (lang, n_conf_parsable, n_conf_total, min_conflicts)
                )

        # Row 5: independent `/usr/bin/git merge-file -p` check on every extracted case on disk
        cases_root = os.path.join(corpus_dir, extract_subdir, "cases")

        def _check_one_case(cr):
            cid = cr["case_id"]
            ext = parsers.normalize_extension(cr["path"])
            cdir = os.path.join(cases_root, cid)
            lp = os.path.join(cdir, "left" + ext)
            bp = os.path.join(cdir, "base" + ext)
            rp = os.path.join(cdir, "right" + ext)
            if not (os.path.isfile(lp) and os.path.isfile(bp) and os.path.isfile(rp)):
                return (cid, cr["kind"], -999)
            proc = subprocess.run(
                [git_bin, "merge-file", "-p", lp, bp, rp],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=git_env,
            )
            return (cid, cr["kind"], proc.returncode)

        with ThreadPoolExecutor(max_workers=max(1, int(workers))) as pool:
            verdicts = list(pool.map(_check_one_case, case_rows))

        n_conf_rows = 0
        n_conf_still_conflict = 0
        n_clean_rows = 0
        n_clean_still_clean = 0
        bad_examples = []
        for cid, kind, rc in verdicts:
            if kind == "conflict":
                n_conf_rows += 1
                if 1 <= rc <= 127:
                    n_conf_still_conflict += 1
                else:
                    bad_examples.append("%s(kind=conflict,git_rc=%d)" % (cid, rc))
            elif kind == "clean":
                n_clean_rows += 1
                if rc == 0:
                    n_clean_still_clean += 1
                else:
                    bad_examples.append("%s(kind=clean,git_rc=%d)" % (cid, rc))
            else:
                bad_examples.append("%s(unknown_kind=%s)" % (cid, kind))

        if n_conf_rows == 0:
            failures.append("Row 5: 0 conflict rows in cases.tsv")
        elif n_conf_still_conflict != n_conf_rows or n_clean_still_clean != n_clean_rows or bad_examples:
            failures.append(
                "Row 5: git invariant violated: conflict=%d/%d clean=%d/%d examples=%s"
                % (n_conf_still_conflict, n_conf_rows, n_clean_still_clean, n_clean_rows, bad_examples[:5])
            )
        else:
            print(
                "PASS [Row 5]: git merge-file conflict=%d/%d (100%%), clean=%d/%d (100%%)"
                % (n_conf_still_conflict, n_conf_rows, n_clean_still_clean, n_clean_rows)
            )
    finally:
        shutil.rmtree(empty_home, ignore_errors=True)

    if failures:
        for f in failures:
            print("FAIL: " + f, file=sys.stderr)
        return 1
    print("ALL VERIFICATION CHECKS PASSED")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="RelayIDE M3 merge corpus extractor")
    ap.add_argument("--repos", default=DEFAULT_REPOS_TSV, help="path to repos.tsv")
    ap.add_argument("--repo", action="append", default=None, help="only process matching owner/repo")
    ap.add_argument("--extract-subdir", default="extract", help="subdirectory inside $RELAY_MERGE_CORPUS_DIR")
    ap.add_argument("--cases-out", default=DEFAULT_CASES_TSV, help="output path for cases.tsv")
    ap.add_argument("--clean-sample", type=int, default=None, help="override per-language clean sample count")
    ap.add_argument("--git", default="/usr/bin/git", help="git binary path (default /usr/bin/git)")
    ap.add_argument("--workers", type=int, default=4, help="worker count for read-only git inspection and swiftc")
    ap.add_argument("--fetch", action="store_true", help="anonymously bare-clone missing repos in repos.tsv")
    ap.add_argument("--count-only", action="store_true", help="count merges and candidates without writing files")
    ap.add_argument("--verify", action="store_true", help="verify Rows 1-5 on extracted corpus")
    ap.add_argument("--compare-cases", default=None, help="second cases.tsv path for Row 2 sha256 check")
    ap.add_argument("--allow-partial-repos", action="store_true", help="allow <3 repos per language in --verify")
    ap.add_argument("--min-conflicts", type=int, default=200, help="Row 4 minimum parsable conflicts per language")
    args = ap.parse_args(argv)

    corpus_dir = os.environ.get(ENV_CORPUS_DIR, "").strip()
    if not corpus_dir:
        print("没跑：没有语料缓存")
        return 2
    corpus_dir = os.path.abspath(corpus_dir)

    repos = load_repos_manifest(os.path.abspath(args.repos), repo_filters=args.repo)

    if args.fetch:
        return do_fetch(args.git, corpus_dir, repos)

    if args.verify:
        return verify_corpus(
            git_bin=args.git,
            corpus_dir=corpus_dir,
            repos=repos,
            extract_subdir=args.extract_subdir,
            cases_path=os.path.abspath(args.cases_out),
            compare_cases_path=os.path.abspath(args.compare_cases) if args.compare_cases else None,
            allow_partial_repos=args.allow_partial_repos,
            min_conflicts=args.min_conflicts,
            workers=args.workers,
        )

    # Validate fixed parsers upfront when extracting (not needed for --count-only)
    needed_langs = sorted({r["language"] for r in repos}, key=lambda x: LANGUAGE_ORDER.index(x))
    if not args.count_only:
        try:
            parsers.describe_parsers(needed_langs)
        except parsers.ParserNotConfiguredError as exc:
            print(str(exc))
            return 2

    t_start = time.time()
    empty_home = tempfile.mkdtemp(prefix="relay-extract-home.")
    try:
        git_env = offline_git_env(empty_home)
        bare_root = os.path.join(corpus_dir, "bare")

        seen_conflict_by_lang = {lang: set() for lang in LANGUAGE_ORDER}
        seen_clean_by_lang = {lang: set() for lang in LANGUAGE_ORDER}
        conflict_records = []
        clean_pools_by_lang = {lang: [] for lang in LANGUAGE_ORDER}
        repo_stats = []
        stats_by_slug = {}

        for repo in repos:
            lang = repo["language"]
            bare_repo = os.path.join(bare_root, repo["bare_name"])
            st = process_single_repo(
                git_bin=args.git,
                bare_repo=bare_repo,
                repo=repo,
                git_env=git_env,
                seen_conflict_triples=seen_conflict_by_lang[lang],
                seen_clean_triples=seen_clean_by_lang[lang],
                conflict_records=conflict_records,
                clean_pool=clean_pools_by_lang[lang],
                workers=args.workers,
            )
            repo_stats.append(st)
            stats_by_slug[repo["slug"]] = st

        sampled_clean = sample_clean_records(clean_pools_by_lang, clean_sample_override=args.clean_sample)
        for rec in sampled_clean:
            stats_by_slug[rec["repo"]]["kept_clean"] += 1
        for st in repo_stats:
            unique_clean = st["git_clean_total"] - st["skip_clean_duplicate"]
            st["skip_clean_unsampled"] = unique_clean - st["kept_clean"]

        if args.count_only:
            print_stats_summary(repo_stats)
            print("total_seconds\t%.1f" % (time.time() - t_start))
            return 0

        # Materialize extracted files into $RELAY_MERGE_CORPUS_DIR/<extract_subdir>/cases/
        extract_root = os.path.join(corpus_dir, args.extract_subdir)
        if os.path.exists(extract_root):
            shutil.rmtree(extract_root)
        cases_dir = os.path.join(extract_root, "cases")
        os.makedirs(cases_dir, exist_ok=True)

        all_records = []
        for idx, rec in enumerate(conflict_records, start=1):
            rec["case_id"] = "c%05d" % idx
            all_records.append(rec)
        for idx, rec in enumerate(sampled_clean, start=1):
            rec["case_id"] = "k%05d" % idx
            all_records.append(rec)

        human_items = []
        for rec in all_records:
            cdir = os.path.join(cases_dir, rec["case_id"])
            os.makedirs(cdir)
            ext = rec["ext"]
            for role, key in (("base", "vb"), ("left", "vl"), ("right", "vr"), ("human", "vh")):
                with open(os.path.join(cdir, role + ext), "wb") as fh:
                    fh.write(rec[key])
            human_items.append((os.path.join(cdir, "human" + ext), ext))

        try:
            parse_verdicts = parsers.parse_files_batch(human_items, max_workers=args.workers)
        except parsers.ParserNotConfiguredError as exc:
            print(str(exc))
            return 2

        for rec, ok in zip(all_records, parse_verdicts):
            rec["human_parses"] = 1 if ok else 0
            st = stats_by_slug[rec["repo"]]
            if rec["kind"] == "conflict":
                if ok:
                    st["conflict_human_parses"] += 1
                else:
                    st["conflict_human_unparsable"] += 1
            else:
                if ok:
                    st["clean_human_parses"] += 1
                else:
                    st["clean_human_unparsable"] += 1

        # Write stats.tsv in extract_root
        stats_path = os.path.join(extract_root, "stats.tsv")
        with open(stats_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\t".join(STATS_COLUMNS) + "\n")
            for st in repo_stats:
                fh.write("\t".join(str(st[col]) for col in STATS_COLUMNS) + "\n")

        # Write cases.tsv
        cases_out = os.path.abspath(args.cases_out)
        os.makedirs(os.path.dirname(cases_out), exist_ok=True)
        with open(cases_out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\t".join(CASES_COLUMNS) + "\n")
            for rec in all_records:
                fh.write("\t".join(str(rec[col]) for col in CASES_COLUMNS) + "\n")

        print_stats_summary(repo_stats)
        total_elapsed = time.time() - t_start
        cases_sha = _sha256_file(cases_out)
        print("cases_out\t%d\tsha256=%s\ttotal_seconds=%.1f" % (len(all_records), cases_sha, total_elapsed))
        return 0
    finally:
        shutil.rmtree(empty_home, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
