#!/usr/bin/env python3
"""Recompress PNG IDAT streams with zlib level 9 (stdlib only). Usage: png_compress.py file.png [...]"""
import struct, sys, zlib

def recompress(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', path
    i, chunks, idat = 8, [], b''
    while i < len(d):
        n = struct.unpack('>I', d[i:i+4])[0]
        t, body = d[i+4:i+8], d[i+8:i+8+n]
        if t == b'IDAT':
            idat += body
        else:
            chunks.append((t, body))
        i += 12 + n
    raw = zlib.decompress(idat)
    out = bytearray(d[:8])
    def put(t, body):
        out.extend(struct.pack('>I', len(body)) + t + body + struct.pack('>I', zlib.crc32(t + body) & 0xffffffff))
    for t, body in chunks:
        if t == b'IEND':
            put(b'IDAT', zlib.compress(raw, 9))
        put(t, body)
    open(path, 'wb').write(out)
    return len(d), len(out)

if __name__ == '__main__':
    for p in sys.argv[1:]:
        a, b = recompress(p)
        print(f'{p}: {a} -> {b} bytes')
