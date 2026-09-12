#!/usr/bin/env python3
"""Prints PNGSTATS for an image: size, grey mean, grey std and the black fraction, all in
[0,1]. A shot harness proves a frame was saved; this proves it holds a picture."""
import struct, sys, zlib

def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a png'
    pos, idat, w, h, ctype = 8, b'', 0, 0, 0
    while pos < len(data):
        n = struct.unpack('>I', data[pos:pos+4])[0]
        tag = data[pos+4:pos+8]
        body = data[pos+8:pos+8+n]
        if tag == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
            assert depth == 8, 'only 8-bit'
        elif tag == b'IDAT':
            idat += body
        pos += 12 + n
    ch = {2: 3, 6: 4, 0: 1, 4: 2}[ctype]
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray(w * h * ch)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p+stride]); p += stride
        for i in range(stride):
            a = line[i-ch] if i >= ch else 0
            b = prev[i]
            c = prev[i-ch] if i >= ch else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        out[y*stride:(y+1)*stride] = line
        prev = line
    return w, h, ch, out

def main(path):
    w, h, ch, px = read_png(path)
    n = w * h
    # Sample every 4th pixel: this is a sanity check, not a histogram.
    greys = []
    for i in range(0, n, 4):
        o = i * ch
        greys.append((px[o] * 0.299 + px[o+1] * 0.587 + px[o+2] * 0.114) / 255.0 if ch >= 3 else px[o] / 255.0)
    m = sum(greys) / len(greys)
    var = sum((g - m) ** 2 for g in greys) / len(greys)
    black = sum(1 for g in greys if g < 0.02) / len(greys)
    # Speckle: mean |difference| between horizontal neighbours, on every 8th row, lit pixels only.
    hf, cnt = 0.0, 0
    for y in range(0, h, 8):
        for x in range(0, w - 1, 2):
            o = (y * w + x) * ch
            if ch >= 3:
                a = px[o] * 0.299 + px[o+1] * 0.587 + px[o+2] * 0.114
                b = px[o+ch] * 0.299 + px[o+ch+1] * 0.587 + px[o+ch+2] * 0.114
            else:
                a, b = px[o], px[o+ch]
            if a > 8 and b > 8:
                hf += abs(a - b) / 255.0
                cnt += 1
    print("PNGSTATS %s w=%d h=%d mean=%.3f std=%.3f black=%.2f hf=%.4f" % (path, w, h, m, var ** 0.5, black, hf / max(cnt, 1)))

if __name__ == '__main__':
    main(sys.argv[1])
