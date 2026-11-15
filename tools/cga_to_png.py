#!/usr/bin/env python3
"""
cga_to_png.py - Converts raw 16KB CGA mode 04h memory dump to a 320x200 PNG image.
Supports HP 200LX 4-shade grayscale palette mapping.
"""

import sys
import struct
import zlib

def cga_dump_to_png(vram_bin_path: str, png_path: str):
    with open(vram_bin_path, 'rb') as f:
        data = f.read()

    if len(data) < 16000:
        raise ValueError(f"Expected at least 16000 bytes, got {len(data)}")

    even_bank = data[0:8000]
    odd_bank = data[8000:16000]

    width = 320
    height = 200

    # HP 200LX 4-shade grayscale palette (RGB)
    palette = [
        (240, 240, 240), # Shade 0: White
        (170, 170, 170), # Shade 1: Light Gray
        (95, 95, 95),    # Shade 2: Dark Gray
        (20, 20, 20),    # Shade 3: Black
    ]

    # Reconstruct scanlines: 0..199
    raw_rows = []
    for y in range(height):
        row_pixels = []
        if (y % 2) == 0:
            bank = even_bank
            line_offset = (y // 2) * 80
        else:
            bank = odd_bank
            line_offset = ((y - 1) // 2) * 80

        line_bytes = bank[line_offset:line_offset + 80]
        for b in line_bytes:
            p0 = (b >> 6) & 3
            p1 = (b >> 4) & 3
            p2 = (b >> 2) & 3
            p3 = (b >> 0) & 3
            for p in (p0, p1, p2, p3):
                row_pixels.extend(palette[p])

        # PNG row starts with filter byte 0
        raw_rows.append(b'\x00' + bytes(row_pixels))

    uncompressed_data = b''.join(raw_rows)
    compressed_data = zlib.compress(uncompressed_data)

    def make_chunk(chunk_type: bytes, chunk_data: bytes) -> bytes:
        crc = zlib.crc32(chunk_type + chunk_data) & 0xFFFFFFFF
        return struct.pack('>I', len(chunk_data)) + chunk_type + chunk_data + struct.pack('>I', crc)

    png_header = b'\x89PNG\r\n\x1a\n'
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0) # 8-bit RGB
    ihdr_chunk = make_chunk(b'IHDR', ihdr)
    idat_chunk = make_chunk(b'IDAT', compressed_data)
    iend_chunk = make_chunk(b'IEND', b'')

    with open(png_path, 'wb') as f:
        f.write(png_header + ihdr_chunk + idat_chunk + iend_chunk)

    print(f"[cga_to_png] Converted '{vram_bin_path}' -> '{png_path}' ({width}x{height} PNG)")

if __name__ == '__main__':
    src = sys.argv[1] if len(sys.argv) > 1 else 'build/CGA_VRAM.BIN'
    dst = sys.argv[2] if len(sys.argv) > 2 else 'build/cga_test_screen.png'
    cga_dump_to_png(src, dst)
