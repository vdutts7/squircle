#!/usr/bin/env bash
# squircle hook: kebab-slug file basenames (self-contained; ships with .hooks for ght sync).
# usage: sluggify-paths.sh [--staged|--tree] [ROOT]
set -euo pipefail

MODE="tree"
ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) MODE="staged"; shift ;;
    --tree) MODE="tree"; shift ;;
    -h|--help) echo "usage: $0 [--staged|--tree] [ROOT]" >&2; exit 0 ;;
    *) ROOT="$1"; shift ;;
  esac
done

ROOT="${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT"

EXCLUDES_JSON="$ROOT/.hooks/scripts/sluggify-paths.excludes.json"
export ROOT EXCLUDES_JSON MODE
python3 - <<'PY'
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

root = Path(os.environ["ROOT"]).resolve()
ex_path = os.environ.get("EXCLUDES_JSON") or ""

dir_prefixes = {".git", ".hooks", "bin"}
exact_files = {
    "image-formats.txt",
    "repo.spine.json",
    "em-dash-whitelist.txt",
}
if ex_path and Path(ex_path).is_file():
    doc = json.loads(Path(ex_path).read_text())
    dir_prefixes = set(doc.get("dir_prefixes") or dir_prefixes)
    exact_files = set(doc.get("exact_files") or exact_files)

UNSAFE = re.compile(r"[\x00-\x1f\x7f]|[/\\]")


def slug_stem(text: str) -> str:
    if not text:
        return "unnamed"
    text = unicodedata.normalize("NFKC", text)
    out = []
    for ch in text:
        if ch.isalnum():
            out.append(ch.lower())
        else:
            out.append("-")
    s = re.sub(r"-{2,}", "-", "".join(out)).strip("-")
    return s or "unnamed"


def split_name(name: str) -> tuple[str, str]:
    if name.startswith(".") and name.count(".") == 1:
        return name, ""
    if "." in name:
        stem, ext = name.rsplit(".", 1)
        if stem:
            return stem, "." + ext.lower()
    return name, ""


def slug_basename(name: str) -> str:
    stem, ext = split_name(name)
    if stem.startswith(".") and not ext:
        return stem
    return slug_stem(stem) + ext


def protected(rel: str) -> bool:
    if rel in exact_files:
        return True
    parts = Path(rel).parts
    if not parts:
        return True
    if parts[0] in dir_prefixes:
        return True
    return False


def git_ls_files() -> list[str]:
    p = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        capture_output=True,
        check=True,
    )
    if not p.stdout:
        return []
    return [x.decode() for x in p.stdout.split(b"\0") if x]


def git_staged_paths() -> list[str]:
    p = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "diff",
            "--cached",
            "--name-only",
            "-z",
            "--diff-filter=ACMR",
        ],
        capture_output=True,
        check=True,
    )
    if not p.stdout:
        return []
    return [x.decode() for x in p.stdout.split(b"\0") if x]


def paths_to_slug() -> list[str]:
    mode = os.environ.get("MODE", "tree")
    if mode == "staged":
        return git_staged_paths()
    return git_ls_files()


def same_inode(a: Path, b: Path) -> bool:
    try:
        return a.exists() and b.exists() and a.samefile(b)
    except OSError:
        return False


def unique_path(src: Path, dest: Path) -> Path:
    if not dest.exists() or same_inode(src, dest):
        return dest
    stem, ext = dest.stem, dest.suffix
    n = 2
    while True:
        cand = dest.with_name(f"{stem}-{n}{ext}")
        if not cand.exists() or same_inode(src, cand):
            return cand
        n += 1


def git_mv(src_rel: str, dst_rel: str) -> None:
    rc = subprocess.run(
        ["git", "-C", str(root), "mv", "-f", src_rel, dst_rel],
        capture_output=True,
    )
    if rc.returncode != 0:
        (root / src_rel).rename(root / dst_rel)
        subprocess.run(
            ["git", "-C", str(root), "add", "-A", "--", src_rel, dst_rel],
            check=False,
        )


renamed = 0
for rel in paths_to_slug():
    if protected(rel):
        continue
    src = root / rel
    if not src.is_file():
        continue
    new_base = slug_basename(src.name)
    if UNSAFE.search(new_base):
        print(f"[sluggify-paths] skip unsafe: {rel}", file=sys.stderr)
        continue
    if new_base == src.name:
        continue

    dest = unique_path(src, src.parent / new_base)
    rel_dest = str(dest.relative_to(root))
    if protected(rel_dest):
        continue

    if same_inode(src, dest) and src.name != new_base:
        tmp_base = f".__slug_{os.getpid()}_{renamed}__{new_base}"
        tmp_rel = str((src.parent / tmp_base).relative_to(root))
        git_mv(rel, tmp_rel)
        git_mv(tmp_rel, rel_dest)
        print(f"[sluggify-paths] {rel} -> {rel_dest} (case)", file=sys.stderr)
        renamed += 1
        continue

    if rel == rel_dest:
        continue

    dest.parent.mkdir(parents=True, exist_ok=True)
    git_mv(rel, rel_dest)
    print(f"[sluggify-paths] {rel} -> {rel_dest}", file=sys.stderr)
    renamed += 1

print(f"[sluggify-paths] renamed={renamed}", file=sys.stderr)
sys.exit(0)
PY
