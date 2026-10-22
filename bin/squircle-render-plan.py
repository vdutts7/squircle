#!/usr/bin/env python3
"""CSP solver for squircle render — outputs JSON plan for squircle.sh main()."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

MAGICK = os.environ.get("MAGICK", "/opt/homebrew/bin/magick")
if not Path(MAGICK).is_file():
    MAGICK = "/usr/local/bin/magick"

SCRIPT_DIR = Path(__file__).resolve().parent
GET_BG = SCRIPT_DIR / "get-bg-color.sh"
MASK_FILE = Path(os.environ.get("SQUIRCLE_MASK", str(SCRIPT_DIR / "mask.png")))

SIZE = int(os.environ.get("SQUIRCLE_SIZE", "1024"))
LOGO_RATIO = int(os.environ.get("SQUIRCLE_LOGO_RATIO", "824"))
DEFAULT_BG = os.environ.get("SQUIRCLE_DEFAULT_BG", "#FFFFFF")
OPAQUE_MARGIN_MAX_CHROMA = int(os.environ.get("SQUIRCLE_OPAQUE_MARGIN_MAX_CHROMA", "42"))
CLIP_THRESHOLD = float(os.environ.get("SQUIRCLE_CLIP_THRESHOLD", "0.05"))
CLIP_PADDING_FLOOR = int(os.environ.get("SQUIRCLE_CLIP_PADDING_START", "100"))
CLIP_PADDING_STEP = int(os.environ.get("SQUIRCLE_CLIP_PADDING_STEP", "50"))
CLIP_PADDING_MAX_ITER = int(os.environ.get("SQUIRCLE_CLIP_PADDING_MAX_ITER", "6"))
CLIP_CROP_DIVISOR = int(os.environ.get("SQUIRCLE_CLIP_CROP_DIVISOR", "11"))
SCREENSHOT_MIN_PX = int(os.environ.get("SQUIRCLE_SCREENSHOT_MIN_PX", "512"))
PREP_FUZZ = int(os.environ.get("SQUIRCLE_PREP_FUZZ", "8"))


def run_magick(args: list[str]) -> str:
    p = subprocess.run(
        [MAGICK, "-limit", "thread", "1", *args],
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip() or "magick failed")
    return p.stdout.strip()


def alpha_stats(img: Path) -> tuple[float, float]:
    mean = float(
        run_magick([str(img), "-resize", "64x64", "-alpha", "extract", "-format", "%[fx:mean]", "info:"])
        or 0
    )
    center = float(
        run_magick(
            [
                str(img),
                "-resize",
                "64x64",
                "-alpha",
                "extract",
                "-gravity",
                "center",
                "-crop",
                "50%x50%+0+0",
                "+repage",
                "-format",
                "%[fx:mean]",
                "info:",
            ]
        )
        or 0
    )
    return mean, center


def transparent_corner_count(raster: Path) -> int:
    w, h = identify_wh(raster)
    n = 0
    for x, y in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
        a = float(
            run_magick(
                [
                    str(raster),
                    "-alpha",
                    "extract",
                    "-crop",
                    f"1x1+{x}+{y}",
                    "+repage",
                    "-format",
                    "%[fx:mean]",
                    "info:",
                ]
            )
            or 0
        )
        if a < 0.25:
            n += 1
    return n


def get_bg_class(raster: Path) -> str:
    w, h = identify_wh(raster)
    if (
        max(w, h) / max(min(w, h), 1) > 2.2
        and transparent_corner_count(raster) >= 2
    ):
        return "transparent_logo"
    if GET_BG.is_file():
        p = subprocess.run([str(GET_BG), str(raster)], capture_output=True, text=True)
        v = (p.stdout or "").strip()
        if v == "OPAQUE":
            return "opaque_tile"
    w, h = identify_wh(raster)
    mean_a, center_a = alpha_stats(raster)
    # Favicon / app icon: transparent corners, solid center → opaque tile path (margin + padding CSP).
    if max(w, h) <= 512 and (center_a >= 0.32 or mean_a >= 0.38):
        return "opaque_tile"
    # Wide marks / screenshots: mostly opaque raster.
    if mean_a >= 0.55:
        return "opaque_tile"
    return "transparent_logo"


def corner_rgb(img: Path, x: int, y: int) -> tuple[int, int, int]:
    out = run_magick(
        [
            str(img),
            "-resize",
            "64x64",
            "-alpha",
            "on",
            "-background",
            "none",
            "-crop",
            f"16x16+{x}+{y}",
            "+repage",
            "-scale",
            "1x1!",
            "-format",
            "%[fx:round(255*u.r)] %[fx:round(255*u.g)] %[fx:round(255*u.b)]",
            "info:",
        ]
    )
    parts = out.split()
    return int(parts[0]), int(parts[1]), int(parts[2])


def sample_corner_bg_hex(img: Path) -> str:
    corners = [corner_rgb(img, 0, 0), corner_rgb(img, 48, 0), corner_rgb(img, 0, 48), corner_rgb(img, 48, 48)]
    r = sum(c[0] for c in corners) // 4
    g = sum(c[1] for c in corners) // 4
    b = sum(c[2] for c in corners) // 4
    return f"#{r:02X}{g:02X}{b:02X}"


def chroma(hex_s: str) -> int:
    if not re.fullmatch(r"#[0-9A-Fa-f]{6}", hex_s):
        return 999
    r = int(hex_s[1:3], 16)
    g = int(hex_s[3:5], 16)
    b = int(hex_s[5:7], 16)
    return max(r, g, b) - min(r, g, b)


def detect_field_color(img: Path) -> str:
    detect = SCRIPT_DIR / "detect-field-color.sh"
    if detect.is_file():
        p = subprocess.run([str(detect), "-q", str(img)], capture_output=True, text=True)
        hx = (p.stdout or "").strip()
        if re.fullmatch(r"#[0-9A-Fa-f]{6}", hx):
            return hx.upper()
    return sample_corner_bg_hex(img).upper()


def margin_for_opaque(img: Path, pad_mode: int = 1) -> str:
    hx = detect_field_color(img)
    if chroma(hx) > OPAQUE_MARGIN_MAX_CHROMA:
        return DEFAULT_BG
    return hx


def identify_wh(img: Path) -> tuple[int, int]:
    out = run_magick([str(img), "-format", "%w %h", "info:"])
    w, h = out.split()
    return int(w), int(h)


def prep_trim(src: Path, dst: Path) -> bool:
    ow, oh = identify_wh(src)
    oa = ow * oh
    run_magick(
        [
            f"{src}[0]",
            "-coalesce",
            "-fuzz",
            f"{PREP_FUZZ}%",
            "-trim",
            "+repage",
            f"PNG32:{dst}",
        ]
    )
    if not dst.is_file() or dst.stat().st_size == 0:
        return False
    nw, nh = identify_wh(dst)
    na = nw * nh
    aspect = max(ow, oh) / max(min(ow, oh), 1)
    min_area_pct = 4 if aspect > 2.4 else 8
    if oa > 0 and na * 100 < oa * min_area_pct:
        return False
    if nw < 2 or nh < 2:
        return False
    rw = nw * 100 // ow if ow else 100
    rh = nh * 100 // oh if oh else 100
    if min(rw, rh) < 62 and max(rw, rh) > 88:
        return False
    return True


def p_content_from_trim(nw: int, nh: int, size: int) -> int:
    """Min per-side padding from trim bbox + LOGO_RATIO target (CSP: meet_content_inset)."""
    l_target = size * LOGO_RATIO // 1024
    p_target = max(0, (size - l_target) // 2)
    content_max = max(nw, nh, 1)
    # Full-bleed small sources (e.g. 256² favicon): use ratio target inset.
    if content_max <= l_target:
        return p_target
    # Large trim bbox: shrink logo box so scaled art keeps ~8% inset from squircle curve.
    need_l = min(size - 16, int(content_max / 0.88) + 1)
    return max(p_target, (size - need_l) // 2)


def build_mask(size: int, tmp: Path) -> Path:
    mask_out = tmp / "mask.png"
    if MASK_FILE.is_file():
        run_magick([str(MASK_FILE), "-resize", f"{size}x{size}", "-alpha", "extract", "-threshold", "50%", str(mask_out)])
    else:
        r = size // 4
        x2 = size - 1
        run_magick(
            [
                "-size",
                f"{size}x{size}",
                "xc:black",
                "-fill",
                "white",
                "-draw",
                f"roundRectangle 0,0 {x2},{x2} {r},{r}",
                "-alpha",
                "extract",
                "-threshold",
                "50%",
                str(mask_out),
            ]
        )
    return mask_out


def clip_score(
    raster: Path,
    mask: Path,
    size: int,
    padding_px: int,
    margin_hex: str,
    tmp: Path,
) -> float:
    logo_size = size - 2 * padding_px
    if logo_size < 8:
        logo_size = 8
    frame = tmp / "frame.png"
    masked = tmp / "masked.png"
    run_magick(
        [
            "(",
            str(raster),
            "-resize",
            f"{logo_size}x{logo_size}",
            "-gravity",
            "center",
            "-background",
            margin_hex,
            "-extent",
            f"{size}x{size}",
            ")",
            "-strip",
            str(frame),
        ]
    )
    run_magick([str(frame), str(mask), "-alpha", "off", "-compose", "CopyOpacity", "-composite", str(masked)])
    diff_bg = sample_corner_bg_hex(frame)
    flat_f = tmp / "flat_f.png"
    flat_m = tmp / "flat_m.png"
    diff = tmp / "diff.png"
    run_magick([str(frame), "-background", diff_bg, "-alpha", "remove", "-alpha", "off", str(flat_f)])
    run_magick([str(masked), "-background", diff_bg, "-alpha", "remove", "-alpha", "off", str(flat_m)])
    run_magick([str(flat_f), str(flat_m), "-alpha", "off", "-compose", "difference", "-composite", str(diff)])
    crop_px = size // CLIP_CROP_DIVISOR
    crop_px = max(32, min(128, crop_px))
    x = y = size - crop_px
    corners = []
    for geom in [f"{crop_px}x{crop_px}+0+0", f"{crop_px}x{crop_px}+{x}+0", f"{crop_px}x{crop_px}+0+{y}", f"{crop_px}x{crop_px}+{x}+{y}"]:
        m = run_magick([str(diff), "-crop", geom, "+repage", "-format", "%[fx:mean]", "info:"])
        corners.append(float(m or 1.0))
    return sum(corners) / 4.0


def solve(raster: Path, user_bg: str | None, user_padding: int | None) -> dict:
    work_raster = raster
    prep_used = False
    bg_class = get_bg_class(raster)

    with tempfile.TemporaryDirectory(prefix="squircle-plan-") as td:
        tmp = Path(td)
        prep_path = tmp / "prep.png"
        ow, oh = identify_wh(raster)
        prep_out = os.environ.get("SQUIRCLE_PREP_OUT")
        trim_worthy = max(ow, oh) / max(min(ow, oh), 1) > 2.4
        if trim_worthy or (
            bg_class == "opaque_tile"
            and max(ow, oh) >= SCREENSHOT_MIN_PX
            and chroma(detect_field_color(raster)) <= OPAQUE_MARGIN_MAX_CHROMA
        ):
            if prep_trim(raster, prep_path):
                prep_used = True
                if prep_out:
                    Path(prep_out).write_bytes(prep_path.read_bytes())
                    work_raster = Path(prep_out)
                else:
                    work_raster = prep_path
                bg_class = get_bg_class(work_raster)
                nw_p, nh_p = identify_wh(work_raster)
                if (
                    trim_worthy
                    and ow * oh > 0
                    and nw_p * nh_p * 100 < ow * oh * 15
                ):
                    bg_class = "transparent_logo"

        if user_bg:
            margin_hex = user_bg
        elif bg_class == "opaque_tile":
            margin_hex = margin_for_opaque(work_raster, 1)
        else:
            margin_hex = DEFAULT_BG

        nw, nh = identify_wh(work_raster)
        p_target = (SIZE - SIZE * LOGO_RATIO // 1024) // 2
        p_content = p_content_from_trim(nw, nh, SIZE)
        p_min = max(CLIP_PADDING_FLOOR, p_content, p_target // 2)
        p_max = (SIZE - 8) // 2

        if user_padding is not None:
            return {
                "source_class": bg_class,
                "prep": prep_used,
                "work_raster": str(work_raster),
                "margin_hex": margin_hex,
                "padding_px": user_padding,
                "render_mode": "padding",
                "frozen": ["padding"],
            }

        mask = build_mask(SIZE, tmp)
        chosen_p = None
        chosen_s = None
        pad = p_min
        # Plan search uses strict clip threshold (executor padding mode uses ×1.75 in zsh).
        for _ in range(CLIP_PADDING_MAX_ITER + 12):
            if pad > p_max:
                break
            s = clip_score(work_raster, mask, SIZE, pad, margin_hex, tmp)
            if s < CLIP_THRESHOLD:
                chosen_p = pad
                chosen_s = s
                break
            pad += CLIP_PADDING_STEP

        if chosen_p is None:
            chosen_p = min(pad, p_max)
            chosen_s = clip_score(work_raster, mask, SIZE, chosen_p, margin_hex, tmp)

        if bg_class == "transparent_logo":
            return {
                "source_class": bg_class,
                "prep": prep_used,
                "work_raster": str(work_raster) if prep_used else None,
                "margin_hex": margin_hex,
                "padding_px": p_target,
                "render_mode": "composited",
            }

        return {
            "source_class": bg_class,
            "prep": prep_used,
            "work_raster": str(work_raster) if prep_used else None,
            "margin_hex": margin_hex,
            "padding_px": chosen_p,
            "clip_score": round(chosen_s, 5) if chosen_s is not None else None,
            "p_content": p_content,
            "p_target": p_target,
            "render_mode": "padding",
        }


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: squircle-render-plan.py <raster> [--bg HEX] [--padding N]", file=sys.stderr)
        return 2
    raster = Path(sys.argv[1])
    user_bg = None
    user_padding = None
    i = 2
    while i < len(sys.argv):
        if sys.argv[i] == "--bg" and i + 1 < len(sys.argv):
            user_bg = sys.argv[i + 1]
            i += 2
        elif sys.argv[i] == "--padding" and i + 1 < len(sys.argv):
            user_padding = int(sys.argv[i + 1])
            i += 2
        else:
            i += 1
    if os.environ.get("SQUIRCLE_USER_BG"):
        user_bg = os.environ["SQUIRCLE_USER_BG"]
    plan = solve(raster, user_bg, user_padding)
    json.dump(plan, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
