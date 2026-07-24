#!/usr/bin/env python3
"""Generate SmartCart PNG icons (orange rounded square + white '$') with no deps."""
import struct, zlib, os

# 5x7 'S'; add a full vertical stem at column 2 to form '$'.
S = [
    "01110",
    "10000",
    "10000",
    "01110",
    "00001",
    "00001",
    "01110",
]
ORANGE = (255, 106, 61)
WHITE = (255, 255, 255)


def glyph_on(x, y, size):
    """Return True if pixel (x,y) in an size*size box is part of the '$' glyph."""
    gw, gh = 5, 7
    pad = size * 0.22
    cw = (size - 2 * pad) / gw
    ch = (size - 2 * pad) / gh
    gx = int((x - pad) / cw)
    gy = int((y - pad) / ch)
    if 0 <= gx < gw and 0 <= gy < gh:
        if S[gy][gx] == "1":
            return True
        if gx == 2:  # dollar stem
            return True
    return False


def rounded(x, y, size, r):
    """False if pixel is outside the rounded-corner mask (transparent)."""
    for cx, cy in ((r, r), (size - r, r), (r, size - r), (size - r, size - r)):
        if (x < r and y < r and cx == r and cy == r) or \
           (x >= size - r and y < r and cx == size - r and cy == r) or \
           (x < r and y >= size - r and cx == r and cy == size - r) or \
           (x >= size - r and y >= size - r and cx == size - r and cy == size - r):
            if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
                return False
    return True


def make(size):
    r = max(2, int(size * 0.22))
    rows = bytearray()
    for y in range(size):
        rows.append(0)  # filter byte
        for x in range(size):
            if not rounded(x, y, size, r):
                rows += bytes((0, 0, 0, 0))
            elif glyph_on(x, y, size):
                rows += bytes((*WHITE, 255))
            else:
                rows += bytes((*ORANGE, 255))
    raw = zlib.compress(bytes(rows), 9)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + \
            struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", raw)
    png += chunk(b"IEND", b"")
    return png


here = os.path.dirname(os.path.abspath(__file__))
for s in (16, 32, 48, 128):
    with open(os.path.join(here, f"icon{s}.png"), "wb") as f:
        f.write(make(s))
    print("wrote", f"icon{s}.png")
