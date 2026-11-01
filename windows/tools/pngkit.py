#!/usr/bin/env python3
"""3D 量尺用的 PNG 小工具（11-01 P0；只用 Python 標準庫，不裝 Pillow）。

  python3 windows/tools/pngkit.py sbs <左.png> <右.png> <輸出.png> [--labels Mac,JS]
      左右並排（中間 8 px 白線）；尺寸不同時以左圖為準裁切／補黑。
  python3 windows/tools/pngkit.py probe <mac-kit.json> <mac.png> <js.png> [--js-json js-kit.json]
      照 Mac dump 的 probes（世界點投影到畫面的像素）讀兩張圖 5×5 的平均 RGB，印對照表與差值。
      有給 --js-json 就同時比兩邊算出來的畫面座標（驗證鏡頭一樣）。
  python3 windows/tools/pngkit.py diff <a.png> <b.png>
      整張逐像素比：平均絕對差、> 8 的像素比例。
"""
import json
import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path} 不是 PNG"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, typ = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        pos += 12 + n
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and inter == 0, f"{path}：只支援 8 位元、非交錯（{depth}, {inter}）"
            ch = {2: 3, 6: 4, 0: 1, 4: 2}[ctype]
        elif typ == b"IDAT":
            idat += body
        elif typ == b"IEND":
            break
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray(h * stride)
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        f = raw[i]; i += 1
        line = bytearray(raw[i:i + stride]); i += stride
        if f == 1:
            for x in range(ch, stride): line[x] = (line[x] + line[x - ch]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride): line[x] = (line[x] + ((line[x - ch] if x >= ch else 0) + prev[x]) // 2) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - ch] if x >= ch else 0; b = prev[x]; c = prev[x - ch] if x >= ch else 0
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out[y * stride:(y + 1) * stride] = line
        prev = line
    # 一律轉成 RGB
    if ch == 3:
        rgb = bytes(out)
    else:
        rgb = bytearray(w * h * 3)
        for p in range(w * h):
            if ch == 4: rgb[p * 3:p * 3 + 3] = out[p * 4:p * 4 + 3]
            elif ch == 1: rgb[p * 3:p * 3 + 3] = bytes([out[p]] * 3)
            else: rgb[p * 3:p * 3 + 3] = bytes([out[p * 2]] * 3)
        rgb = bytes(rgb)
    return w, h, rgb


def write_png(path, w, h, rgb):
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


# 5×7 點陣字（標籤用：只有英數）
FONT = {
    "M": ["10001", "11011", "10101", "10001", "10001", "10001", "10001"], "a": ["00000", "00000", "01110", "00001", "01111", "10001", "01111"],
    "c": ["00000", "00000", "01110", "10000", "10000", "10001", "01110"], "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
}


def draw_label(buf, w, x0, y0, text, scale=4):
    for k, chs in enumerate(text):
        g = FONT.get(chs)
        if not g: continue
        for gy, row in enumerate(g):
            for gx, bit in enumerate(row):
                if bit != "1": continue
                for dy in range(scale):
                    for dx in range(scale):
                        x = x0 + (k * 6 + gx) * scale + dx; y = y0 + gy * scale + dy
                        i = (y * w + x) * 3
                        buf[i:i + 3] = b"\xff\x30\x30"


def sbs(a, b, out, labels=("Mac", "JS")):
    wa, ha, A = read_png(a)
    wb, hb, B = read_png(b)
    h, gap = ha, 8
    W = wa + gap + wa
    buf = bytearray(b"\xff" * (W * h * 3))
    for y in range(h):
        buf[y * W * 3:(y * W + wa) * 3] = A[y * wa * 3:(y + 1) * wa * 3]
        if y < hb:
            row = B[y * wb * 3:(y * wb + min(wb, wa)) * 3]
            s = (y * W + wa + gap) * 3
            buf[s:s + len(row)] = row
    draw_label(buf, W, 16, 16, labels[0])
    draw_label(buf, W, wa + gap + 16, 16, labels[1])
    write_png(out, W, h, bytes(buf))
    print("sbs", out)


def avg(img, x, y, r=2):
    w, h, px = img
    acc, n = [0, 0, 0], 0
    for yy in range(int(y) - r, int(y) + r + 1):
        for xx in range(int(x) - r, int(x) + r + 1):
            if 0 <= xx < w and 0 <= yy < h:
                i = (yy * w + xx) * 3
                for c in range(3): acc[c] += px[i + c]
                n += 1
    return [round(v / max(n, 1), 1) for v in acc]


def probe(mac_json, mac_png, js_png, js_json=None):
    d = json.load(open(mac_json))
    M, J = read_png(mac_png), read_png(js_png)
    jp = {p["name"]: p["px"] for p in json.load(open(js_json))["probes"]} if js_json else {}
    print(f"{'probe':16} {'px':>14} {'Mac RGB':>22} {'JS RGB':>22} {'差(JS−Mac)':>20}" + ("  畫面座標差" if jp else ""))
    worst = 0
    for p in d["probes"]:
        x, y = p["px"]
        a, b = avg(M, x, y), avg(J, x, y)
        dd = [round(b[i] - a[i], 1) for i in range(3)]
        worst = max(worst, max(abs(v) for v in dd))
        extra = ""
        if p["name"] in jp:
            q = jp[p["name"]]; extra = f"  ({q[0] - x:+.1f}, {q[1] - y:+.1f})"
        print(f"{p['name']:16} {f'{x:.0f},{y:.0f}':>14} {str(a):>22} {str(b):>22} {str(dd):>20}{extra}")
    print("最大差", worst)


def diff(a, b):
    wa, ha, A = read_png(a)
    wb, hb, B = read_png(b)
    assert (wa, ha) == (wb, hb), "尺寸不同"
    tot, big = 0, 0
    for i in range(0, len(A), 3):
        d = max(abs(A[i] - B[i]), abs(A[i + 1] - B[i + 1]), abs(A[i + 2] - B[i + 2]))
        tot += d; big += d > 8
    n = len(A) // 3
    print(f"平均最大通道差 {tot / n:.2f}，>8 的像素 {big / n * 100:.1f}%")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a: print(__doc__); sys.exit(2)
    if a[0] == "sbs":
        lab = ("Mac", "JS")
        if "--labels" in a: lab = tuple(a[a.index("--labels") + 1].split(","))
        sbs(a[1], a[2], a[3], lab)
    elif a[0] == "probe":
        probe(a[1], a[2], a[3], a[a.index("--js-json") + 1] if "--js-json" in a else None)
    elif a[0] == "diff":
        diff(a[1], a[2])
    else:
        print(__doc__); sys.exit(2)
