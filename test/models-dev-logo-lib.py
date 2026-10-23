"""Shared helpers for models.dev logo fetch + verify (squircle repo SSOT)."""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = REPO_ROOT / "data/logo-sources/policy.json"


def load_policy() -> dict:
    return json.loads(POLICY_PATH.read_text())


def squircle_sh() -> Path:
    env = os.environ.get("SQUIRCLE_SH")
    if env:
        return Path(env)
    cur = Path.home() / ".cursor/tools/squircle/squircle.sh"
    if cur.is_file():
        return cur
    return REPO_ROOT / "bin/squircle.sh"


def webp_dir() -> Path:
    return Path(os.environ.get("SQUIRCLE_WEBP", REPO_ROOT / "webp"))


def models_dev_repo() -> Path:
    return Path(os.environ.get("MODELS_DEV_REPO", load_policy()["defaults"]["models_dev_repo"]))


def labs_md() -> Path:
    if os.environ.get("MODELS_DEV_LABS_MD"):
        return Path(os.environ["MODELS_DEV_LABS_MD"])
    return Path.home() / ".cursor/projects/Users-vdog-wire/uploads/labs-0.md"


def artifact_root() -> Path:
    return Path(os.environ.get("LOGO_SOURCES_ARTIFACT", load_policy()["defaults"]["artifact_root"]))


def md5_file(p: Path) -> str:
    return hashlib.md5(p.read_bytes()).hexdigest()


def is_variant(slug: str, policy: dict) -> bool:
    if slug in policy.get("variant_slugs", []):
        return True
    low = slug.lower()
    return any(m in low for m in policy.get("variant_markers", []))


def lab_slugs() -> list[str]:
    p = labs_md()
    if not p.is_file():
        return []
    return sorted(set(re.findall(r"/labs/([a-z0-9-]+)\)", p.read_text(errors="ignore"))))


def target_slugs(policy: dict) -> list[str]:
    slugs: set[str] = set(lab_slugs())
    root = models_dev_repo()
    if root.is_dir():
        slugs |= {p.name for p in (root / "models").iterdir() if p.is_dir()}
        slugs |= {p.name for p in (root / "labs").iterdir() if p.is_dir()}
        for p in (root / "providers").iterdir():
            if p.is_dir() and not is_variant(p.name, policy):
                slugs.add(p.name)
    return sorted(slugs)


def provider_ids_for_slug(slug: str, policy: dict) -> list[str]:
    ids = [slug]
    alt = policy.get("lab_to_provider", {}).get(slug)
    if alt:
        ids.insert(0, alt)
    out: list[str] = []
    seen: set[str] = set()
    for i in ids:
        if i and i not in seen:
            seen.add(i)
            out.append(i)
    return out


def good_svg(p: Path, policy: dict) -> bool:
    if not p.is_file() or p.stat().st_size < 80:
        return False
    return md5_file(p) != policy["sparkle_svg_md5"]


def svg_style(svg: Path) -> str:
    text = svg.read_text(errors="ignore")
    if "currentColor" in text and "fill=" not in text.replace("fill='none'", ""):
        return "monochrome"
    return "light"


def squircle_cmd(src: Path, out: Path, policy: dict, style: str | None = None) -> list[str]:
    sh = str(squircle_sh())
    cmd = [sh, "-q", str(src), "--out", str(out)]
    if style == "monochrome":
        m = policy["squircle_monochrome_svg"]
        cmd += ["--bg", m["bg"], "--icon-color", m["icon_color"]]
    elif style == "light":
        m = policy["squircle_light_svg"]
        cmd += ["--bg", m["bg"], "--icon-color", m["icon_color"]]
    return cmd


def run_squircle(cmd: list[str]) -> bool:
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=120)
        out = Path(cmd[cmd.index("--out") + 1])
        return out.is_file() and out.stat().st_size > 400
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
        return False


def github_logins(slug: str, policy: dict) -> list[str]:
    overrides = policy.get("github_login_overrides", {})
    if slug in overrides:
        return [overrides[slug]]
    return [slug]


def github_avatar_png(login: str, dest: Path, policy: dict) -> bool:
    gh = policy["github"]
    url = f"https://github.com/{login}.png?size={gh['avatar_size']}"
    req = urllib.request.Request(url, headers={"User-Agent": gh["user_agent"]})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            if resp.status != 200:
                return False
            data = resp.read()
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        return False
    if len(data) < 1200:
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    return True


def phash_hex(path: Path) -> str | None:
    try:
        import imagehash
        from PIL import Image
    except ImportError:
        return None
    try:
        with Image.open(path) as im:
            return str(imagehash.phash(im))
    except OSError:
        return None


def hamming(a: str, b: str) -> int:
    import imagehash

    return imagehash.hex_to_hash(a) - imagehash.hex_to_hash(b)
