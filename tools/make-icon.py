#!/usr/bin/env python3
"""生成 iOS App 图标（1024x1024 PNG，纯标准库，不依赖 Pillow）。

    python tools/make-icon.py

输出：Sources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
from __future__ import annotations

import struct
import zlib
from pathlib import Path

SIZE = 1024
SUPERSAMPLE = 3  # 每个像素做 3x3 采样，用于边缘抗锯齿

# 下载箭头：竖杆 + 三角头 + 底部托盘
SHAFT = (464, 252, 560, 556, 48)
HEAD = ((512, 706), (366, 534), (658, 534))
TRAY = (336, 768, 688, 818, 25)

# 背景对角渐变：蓝 -> 靛
BG_TOP = (59, 130, 246)
BG_BOTTOM = (99, 102, 241)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def in_round_rect(x: float, y: float, rect: tuple) -> bool:
    x0, y0, x1, y1, r = rect
    if x < x0 or x > x1 or y < y0 or y > y1:
        return False
    cx = min(max(x, x0 + r), x1 - r)
    cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def _side(px, py, ax, ay, bx, by) -> float:
    return (px - bx) * (ay - by) - (ax - bx) * (py - by)


def in_triangle(x: float, y: float, tri: tuple) -> bool:
    (ax, ay), (bx, by), (cx, cy) = tri
    d1 = _side(x, y, ax, ay, bx, by)
    d2 = _side(x, y, bx, by, cx, cy)
    d3 = _side(x, y, cx, cy, ax, ay)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def in_glyph(x: float, y: float) -> bool:
    return in_round_rect(x, y, SHAFT) or in_triangle(x, y, HEAD) or in_round_rect(x, y, TRAY)


def background(x: float, y: float) -> tuple[float, float, float]:
    t = (x + y) / (2 * SIZE)
    r = lerp(BG_TOP[0], BG_BOTTOM[0], t)
    g = lerp(BG_TOP[1], BG_BOTTOM[1], t)
    b = lerp(BG_TOP[2], BG_BOTTOM[2], t)
    # 左上角加一点高光，避免纯平渐变显得死板
    highlight = max(0.0, 1.0 - ((x / SIZE) ** 2 + (y / SIZE) ** 2) ** 0.5 * 1.6) * 26
    return min(255.0, r + highlight), min(255.0, g + highlight), min(255.0, b + highlight)


def build_rows() -> list[bytearray]:
    step = 1.0 / SUPERSAMPLE
    samples = SUPERSAMPLE * SUPERSAMPLE
    offset = step / 2
    rows: list[bytearray] = []

    for py in range(SIZE):
        row = bytearray()
        for px in range(SIZE):
            r = g = b = 0.0
            glyph_hits = 0
            for sy in range(SUPERSAMPLE):
                y = py + offset + sy * step
                for sx in range(SUPERSAMPLE):
                    x = px + offset + sx * step
                    br, bg, bb = background(x, y)
                    if in_glyph(x, y):
                        glyph_hits += 1
                        # 白色箭头带一点点通透感
                        br, bg, bb = 255.0, 255.0, 255.0
                    r += br
                    g += bg
                    b += bb
            row += bytes((int(r / samples + 0.5), int(g / samples + 0.5), int(b / samples + 0.5)))
        rows.append(row)
    return rows


def write_png(path: Path, rows: list[bytearray]) -> None:
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type 0 (None)
        raw.extend(row)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main() -> int:
    target = (
        Path(__file__).resolve().parent.parent
        / "Sources"
        / "Assets.xcassets"
        / "AppIcon.appiconset"
        / "AppIcon-1024.png"
    )
    print(f"渲染 {SIZE}x{SIZE}（{SUPERSAMPLE}x{SUPERSAMPLE} 超采样）…")
    write_png(target, build_rows())
    print(f"已写出 {target}（{target.stat().st_size / 1024:.1f} KB）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
