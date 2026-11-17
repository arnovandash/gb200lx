#!/usr/bin/env python3
"""
mzpack.py - Minimal MS-DOS MZ Executable Packager
Wraps flat 16-bit binary code (assembled with org 0) into a standard MS-DOS MZ .EXE.
"""

import sys
import struct
import argparse

def pack_mz(input_bin: str, output_exe: str, min_extra: int = 0x1000, max_extra: int = 0xFFFF, stack_size: int = 0):
    with open(input_bin, 'rb') as f:
        image = bytearray(f.read())

    # Align image to 16-byte paragraph
    pad = (16 - (len(image) % 16)) % 16
    image.extend(b'\x00' * pad)

    header_paras = 2 # 32 bytes (0x20)
    header_size = header_paras * 16

    total_file_size = header_size + len(image)
    blocks = (total_file_size + 511) // 512
    last_block = total_file_size % 512

    # Initial CPU state:
    # CS:IP = 0000:0000 (starts at beginning of image)
    # Paragraph layout:
    # 0 .. image_paras: Code and ROM image
    # image_paras .. image_paras + 0x1000: Game Boy 64 KiB RAM block
    # image_paras + 0x1000 .. image_paras + 0x1200: 8 KiB CGA backbuffer segment
    # image_paras + 0x1200 .. image_paras + 0x1A00: Hardware Stack (32 KiB)
    image_paras = len(image) // 16
    gb_ram_paras = 0x1200 # 64 KiB GB RAM + 8 KiB CGA backbuffer
    stack_paras = 0x0800  # 32 KiB
    actual_min_extra = max(min_extra, gb_ram_paras + stack_paras)

    ss = image_paras + actual_min_extra - stack_paras
    sp = stack_paras * 16 # 0x8000 (32 KiB)
    ip = 0
    cs = 0

    header = bytearray(32)
    struct.pack_into('<2sHHHHHHHHHHHHH', header, 0,
        b'MZ',          # e_magic
        last_block,     # e_cblp
        blocks,         # e_cp
        0,              # e_crlc
        header_paras,   # e_cparhdr
        actual_min_extra, # e_minalloc (paragraphs)
        max_extra,      # e_maxalloc (paragraphs)
        ss,             # e_ss
        sp,             # e_sp
        0,              # e_csum
        ip,             # e_ip
        cs,             # e_cs
        0x1C,           # e_lfarlc
        0               # e_ovno
    )

    with open(output_exe, 'wb') as f:
        f.write(header)
        f.write(image)

    print(f"[mzpack] Packed '{input_bin}' ({len(image)} bytes) -> '{output_exe}' ({total_file_size} bytes)")

def main():
    parser = argparse.ArgumentParser(description="Pack 16-bit binary into MS-DOS MZ executable")
    parser.add_argument("input", help="Input flat binary (.bin)")
    parser.add_argument("output", help="Output MZ executable (.exe)")
    parser.add_argument("--min-extra", type=lambda x: int(x, 0), default=0x1000,
                        help="Minimum extra paragraphs (default 0x1000 = 64KB for GB RAM)")
    parser.add_argument("--max-extra", type=lambda x: int(x, 0), default=0xFFFF,
                        help="Maximum extra paragraphs (default 0xFFFF)")
    parser.add_argument("--stack", type=lambda x: int(x, 0), default=0,
                        help="Extra stack bytes to append to image")

    args = parser.parse_args()
    pack_mz(args.input, args.output, args.min_extra, args.max_extra, args.stack)

if __name__ == "__main__":
    main()
