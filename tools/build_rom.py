#!/usr/bin/env python3
"""
build_rom.py - Generic End-to-End Build Pipeline for Game Boy (DMG) ROMs (80186 HP 200LX)
Recompiles a user-supplied Game Boy ROM into multi-segment native 16-bit 80186 assembly
and packages a standalone MS-DOS MZ .EXE executable.
"""

import sys
import os
import argparse
import subprocess
from typing import Dict, Set, List, Tuple

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from codegen_80186.recompiler_80186 import SM83Disassembler, CodeGenerator80186

OUT_DIR = "build/rom"
BUILD_DIR = "build"

def main():
    parser = argparse.ArgumentParser(
        description="GB200LX: Static Game Boy (DMG) to 16-Bit 80186 DOS Recompiler for HP 200LX"
    )
    parser.add_argument("rom", nargs="?", help="Path to input Game Boy (.gb) ROM file")
    parser.add_argument("-o", "--output", default="GAME.EXE", help="Output DOS executable name (default: GAME.EXE)")
    args = parser.parse_args()

    rom_path = args.rom
    if not rom_path:
        # Look for a local .gb file in current directory or roms/ directory
        candidates = [f for f in os.listdir(".") if f.lower().endswith(".gb")]
        if not candidates and os.path.isdir("roms"):
            candidates = [os.path.join("roms", f) for f in os.listdir("roms") if f.lower().endswith(".gb")]
        if candidates:
            rom_path = candidates[0]
        else:
            print("Error: No Game Boy ROM specified!")
            print("Usage: make ROM=\"path/to/game.gb\"  or  python3 tools/build_rom.py <path/to/game.gb>")
            sys.exit(1)

    if not os.path.exists(rom_path):
        print(f"Error: ROM file '{rom_path}' not found!")
        sys.exit(1)

    exe_name = os.path.basename(args.output)
    if not exe_name.upper().endswith(".EXE"):
        exe_name += ".EXE"
    exe_name = exe_name.upper()
    bin_name = exe_name[:-4] + ".BIN"

    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(BUILD_DIR, exist_ok=True)

    with open(rom_path, "rb") as f:
        rom_bytes = f.read()

    # Pad 32 KiB ROMs to 64 KiB so the 4-segment layout works uniformly for 32KB & 64KB ROMs
    if len(rom_bytes) < 0x10000:
        rom_bytes = rom_bytes + b'\xFF' * (0x10000 - len(rom_bytes))

    print(f"[gb200lx] Loaded ROM: {rom_path} ({len(rom_bytes)} bytes)")

    disasm = SM83Disassembler(rom_bytes)

    # 1. Identify Cross-Bank Entry Points
    # Targets in 0x4000..0x7FFF called from Bank 0
    b0_to_bn = sorted(list(set(
        disasm.decode_instr(0, a).target_addr
        for a in range(0, 0x4000)
        if disasm.decode_instr(0, a).is_call and disasm.decode_instr(0, a).target_addr is not None and 0x4000 <= disasm.decode_instr(0, a).target_addr < 0x8000
    )))
    b0_to_bn_idx = {t: i for i, t in enumerate(b0_to_bn)}

    # Targets in 0x0000..0x3FFF called from Banks 1..3
    bn_to_b0 = sorted(list(set(
        disasm.decode_instr(b, a).target_addr
        for b in [1, 2, 3]
        for a in range(0x4000, 0x8000)
        if disasm.decode_instr(b, a).is_call and disasm.decode_instr(b, a).target_addr is not None and disasm.decode_instr(b, a).target_addr < 0x4000
    )))
    bn_to_b0_idx = {t: i for i, t in enumerate(bn_to_b0)}

    print(f"[gb200lx] Cross-bank calls: Bank 0 -> Banks 1..3: {len(b0_to_bn)} targets")
    print(f"[gb200lx] Cross-bank calls: Banks 1..3 -> Bank 0: {len(bn_to_b0)} targets")

    # 2. Generate Bank Jump Tables & Dispatches
    # Bank 0: Jump table at offset 4 (after jmp near entry + nop)
    disp_b0_lines = [
        "bits 16", "cpu 186", "",
        "; Table of wrappers in Bank 0 called from Banks 1..3 (starts at offset 4)",
        "align 4",
        "global b0_entry_table",
        "b0_entry_table:",
    ]
    for t in bn_to_b0:
        disp_b0_lines.append(f"    call near loc_00_{t:04x}")
        disp_b0_lines.append("    retf")

    disp_b0_lines.extend([
        "",
        "; Far dispatch helper for Bank 0",
        "global do_far_dispatch",
        "do_far_dispatch:",
        "    mov     bp, sp",
        "    call    far [bp]",
        "    add     sp, 4",
        "    ret",
        "",
        "; Dispatchers for Bank 0 calling Banks 1..3"
    ])
    for t in b0_to_bn:
        idx = b0_to_bn_idx[t]
        disp_b0_lines.append(f"global dispatch_call_{t:04x}")
        disp_b0_lines.append(f"dispatch_call_{t:04x}:")
        disp_b0_lines.append("    cmp byte [cs:current_rom_bank], 2")
        disp_b0_lines.append(f"    jb  short .call_b1_{t:04x}")
        disp_b0_lines.append(f"    je  short .call_b2_{t:04x}")
        disp_b0_lines.append("    push word [cs:seg_bank3]")
        disp_b0_lines.append(f"    push word {idx * 4}")
        disp_b0_lines.append("    jmp near do_far_dispatch")
        disp_b0_lines.append(f".call_b1_{t:04x}:")
        disp_b0_lines.append("    push word [cs:seg_bank1]")
        disp_b0_lines.append(f"    push word {idx * 4}")
        disp_b0_lines.append("    jmp near do_far_dispatch")
        disp_b0_lines.append(f".call_b2_{t:04x}:")
        disp_b0_lines.append("    push word [cs:seg_bank2]")
        disp_b0_lines.append(f"    push word {idx * 4}")
        disp_b0_lines.append("    jmp near do_far_dispatch")

    with open(f"{OUT_DIR}/dispatch_b0.asm", "w") as f:
        f.write("\n".join(disp_b0_lines) + "\n")

    # Banks 1, 2, 3: Jump table at offset 0 (B0 -> BN entry points)
    for b in [1, 2, 3]:
        disp_bn_lines = [
            "bits 16", "cpu 186", "org 0", "",
            f"; Bank {b} Entry Jump Table (offset 0)",
            f"global b{b}_entry_table",
            f"b{b}_entry_table:",
        ]
        for t in b0_to_bn:
            disp_bn_lines.append(f"    call near loc_{b:02x}_{t:04x}")
            disp_bn_lines.append("    retf")

        disp_bn_lines.append("\n; Far call helpers for calling Bank 0")
        for t in bn_to_b0:
            idx = bn_to_b0_idx[t]
            disp_bn_lines.append(f"global call_bank0_{t:04x}")
            disp_bn_lines.append(f"call_bank0_{t:04x}:")
            disp_bn_lines.append(f"    mov ax, cs")
            disp_bn_lines.append(f"    sub ax, SEG{b}_PARAS_VAL")
            disp_bn_lines.append(f"    push ax")
            disp_bn_lines.append(f"    push word (4 + {idx * 4})")
            disp_bn_lines.append(f"    mov bp, sp")
            disp_bn_lines.append(f"    call far [bp]")
            disp_bn_lines.append(f"    add sp, 4")
            disp_bn_lines.append(f"    ret")

        with open(f"{OUT_DIR}/dispatch_b{b}.asm", "w") as f:
            f.write("\n".join(disp_bn_lines) + "\n")

    # 3. Emit Recompiled Code for Bank 0..3
    for b in range(4):
        start_addr = 0x0000 if b == 0 else 0x4000
        end_addr = 0x4000 if b == 0 else 0x8000
        cg = CodeGenerator80186(disasm)

        lines = [
            f"; Bank {b:02X} Recompiled Code",
            "bits 16", "cpu 186", "",
        ]

        curr = start_addr
        instructions = []
        while curr < end_addr:
            instr = disasm.decode_instr(b, curr)
            instructions.append(instr)
            curr += max(1, instr.length)
            if instr.target_addr is not None and start_addr <= instr.target_addr < end_addr:
                cg.labels.add((b, instr.target_addr))

        if b == 0:
            for vec in [0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48, 0x50, 0x58, 0x60, 0x100, 0x150, 0x3F92]:
                cg.labels.add((0, vec))
            for t in bn_to_b0:
                cg.labels.add((0, t))
        else:
            for t in b0_to_bn:
                cg.labels.add((b, t))

        for instr in instructions:
            if (b, instr.addr) in cg.labels:
                lbl = cg.label_name(b, instr.addr)
                lines.append(f"global {lbl}")
                lines.append(f"{lbl}:")

            # Route cross-bank calls
            if instr.is_call and instr.target_addr is not None:
                t = instr.target_addr
                next_addr = f"0{(instr.addr + instr.length):04X}h"
                if b == 0 and t >= 0x4000:
                    if t in b0_to_bn_idx:
                        call_line = f"call near dispatch_call_{t:04x}"
                    elif t >= 0xFF80:
                        # HRAM OAM DMA routine call
                        call_line = "call near loc_00_3f92"
                    else:
                        continue
                    lines.append(f"    sub di, 2")
                    lines.append(f"    mov word [di], {next_addr}")
                    lines.append(f"    {call_line}")
                    continue
                elif b > 0 and t < 0x4000:
                    if t in bn_to_b0_idx:
                        call_line = f"call near call_bank0_{t:04x}"
                    else:
                        continue
                    lines.append(f"    sub di, 2")
                    lines.append(f"    mov word [di], {next_addr}")
                    lines.append(f"    {call_line}")
                    continue

            x86_ops = cg.translate_instruction(instr)
            if x86_ops:
                lines.append(f"    {x86_ops[0]}")
                for extra in x86_ops[1:]:
                    lines.append(f"    {extra}")

        with open(f"{OUT_DIR}/code_b{b}.asm", "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"[gb200lx] Emitted code for Bank {b}")

    # 4. Generate Stubs for Unresolved Internal Branch Targets
    for b in range(4):
        defined = set()
        called = set()
        files_to_scan = [f"{OUT_DIR}/code_b{b}.asm", f"{OUT_DIR}/dispatch_b{b}.asm"]
        if b == 0:
            files_to_scan.append("runtime/crt0_rom.asm")
        for fn in files_to_scan:
            if not os.path.exists(fn):
                continue
            with open(fn) as f:
                for line in f:
                    line_clean = line.strip()
                    if line_clean.startswith("loc_") and ":" in line_clean:
                        defined.add(line_clean.split(":")[0].strip())
                    for word in line.split():
                        w = word.strip(":,()[]")
                        if w.startswith("loc_"):
                            called.add(w)
        missing = called - defined
        with open(f"{OUT_DIR}/stubs_b{b}.asm", "w") as f:
            f.write("bits 16\ncpu 186\n\n")
            for m in sorted(missing):
                f.write(f"global {m}\n{m}:\n    ret\n")
        print(f"[gb200lx] Bank {b}: {len(defined)} defined, {len(missing)} stubs")

    # 5. Assemble Dummy Segment 0 to get initial sizes
    seg0_header = f"""
bits 16
cpu 186
org 0

%define SEG_IS_BANK0 1

entry_trampoline:
    jmp near entry
    nop                         ; Align b0_entry_table to exactly offset 4!

%include "{OUT_DIR}/dispatch_b0.asm"
%include "runtime/crt0_rom.asm"
%include "runtime/video_cga.asm"
%include "runtime/config_ini.asm"
%include "runtime/recomp_helpers.asm"
%include "{OUT_DIR}/stubs_b0.asm"
%include "{OUT_DIR}/code_b0.asm"

    align 16
image_end:
"""
    with open(f"{OUT_DIR}/seg0.asm", "w") as f:
        f.write(seg0_header)

    print("[gb200lx] Pass 1: Assembling Segment 0...")
    subprocess.run(["nasm", "-f", "bin", "-I./", "-o", f"{OUT_DIR}/seg0.bin", f"{OUT_DIR}/seg0.asm"], check=True)

    # Segments 1..3 Pass 1
    for b in [1, 2, 3]:
        seg_asm = f"""
bits 16
cpu 186
org 0

%define SEG{b}_PARAS_VAL 0
seg_rom_data: dw 0
gb_mem_seg: dw 0

%include "{OUT_DIR}/dispatch_b{b}.asm"
%include "{OUT_DIR}/stubs_b{b}.asm"
%include "{OUT_DIR}/code_b{b}.asm"
%include "runtime/recomp_helpers.asm"
"""
        with open(f"{OUT_DIR}/seg{b}.asm", "w") as f:
            f.write(seg_asm)
        print(f"[gb200lx] Pass 1: Assembling Segment {b}...")
        subprocess.run(["nasm", "-f", "bin", "-I./", "-o", f"{OUT_DIR}/seg{b}.bin", f"{OUT_DIR}/seg{b}.asm"], check=True)

    # 6. Read Binaries & Compute Paragraph Alignments
    def pad16(data: bytes) -> bytes:
        rem = len(data) % 16
        if rem != 0:
            return data + b'\x00' * (16 - rem)
        return data

    with open(f"{OUT_DIR}/seg0.bin", "rb") as f:
        seg0_pad = pad16(f.read())
    with open(f"{OUT_DIR}/seg1.bin", "rb") as f:
        seg1_pad = pad16(f.read())
    with open(f"{OUT_DIR}/seg2.bin", "rb") as f:
        seg2_pad = pad16(f.read())
    with open(f"{OUT_DIR}/seg3.bin", "rb") as f:
        seg3_pad = pad16(f.read())

    seg1_paras = len(seg0_pad) // 16
    seg2_paras = seg1_paras + len(seg1_pad) // 16
    seg3_paras = seg2_paras + len(seg2_pad) // 16
    seg_rom_paras = seg3_paras + len(seg3_pad) // 16

    print(f"[gb200lx] Calculated Paragraph Offsets:")
    print(f"  Bank 0: 0x0000 ({len(seg0_pad)} bytes)")
    print(f"  Bank 1: +0x{seg1_paras:04X} ({len(seg1_pad)} bytes)")
    print(f"  Bank 2: +0x{seg2_paras:04X} ({len(seg2_pad)} bytes)")
    print(f"  Bank 3: +0x{seg3_paras:04X} ({len(seg3_pad)} bytes)")
    print(f"  ROM Data: +0x{seg_rom_paras:04X} ({len(rom_bytes)} bytes)")

    # 7. Pass 2: Re-assemble Segments with Exact Paragraph Offsets
    seg0_header_pass2 = f"""
bits 16
cpu 186
org 0

%define SEG_IS_BANK0 1
%define SEG1_PARAS_VAL 0{seg1_paras:04X}h
%define SEG2_PARAS_VAL 0{seg2_paras:04X}h
%define SEG3_PARAS_VAL 0{seg3_paras:04X}h
%define SEG_ROM_PARAS_VAL 0{seg_rom_paras:04X}h

entry_trampoline:
    jmp near entry
    nop

%include "{OUT_DIR}/dispatch_b0.asm"
%include "runtime/crt0_rom.asm"
%include "runtime/video_cga.asm"
%include "runtime/config_ini.asm"
%include "runtime/recomp_helpers.asm"
%include "{OUT_DIR}/stubs_b0.asm"
%include "{OUT_DIR}/code_b0.asm"

    align 16
image_end:
"""
    with open(f"{OUT_DIR}/seg0.asm", "w") as f:
        f.write(seg0_header_pass2)

    print("[gb200lx] Pass 2: Re-assembling Segment 0...")
    subprocess.run(["nasm", "-f", "bin", "-I./", "-o", f"{OUT_DIR}/seg0.bin", f"{OUT_DIR}/seg0.asm"], check=True)

    for b in [1, 2, 3]:
        para_val = [0, seg1_paras, seg2_paras, seg3_paras][b]
        seg_asm_pass2 = f"""
bits 16
cpu 186
org 0

%define SEG{b}_PARAS_VAL 0
seg_rom_data: dw 0
gb_mem_seg: dw 0{para_val:04X}h

%include "{OUT_DIR}/dispatch_b{b}.asm"
%include "{OUT_DIR}/stubs_b{b}.asm"
%include "{OUT_DIR}/code_b{b}.asm"
%include "runtime/recomp_helpers.asm"
"""
        with open(f"{OUT_DIR}/seg{b}.asm", "w") as f:
            f.write(seg_asm_pass2)
        print(f"[gb200lx] Pass 2: Re-assembling Segment {b}...")
        subprocess.run(["nasm", "-f", "bin", "-I./", "-o", f"{OUT_DIR}/seg{b}.bin", f"{OUT_DIR}/seg{b}.asm"], check=True)

    with open(f"{OUT_DIR}/seg0.bin", "rb") as f:
        seg0_pad = pad16(f.read())
    with open(f"{OUT_DIR}/seg1.bin", "rb") as f:
        seg1_pad = pad16(f.read())
    with open(f"{OUT_DIR}/seg2.bin", "rb") as f:
        seg2_pad = pad16(f.read())
    with open(f"{OUT_DIR}/seg3.bin", "rb") as f:
        seg3_pad = pad16(f.read())

    # 8. Concatenate Full Executable Image
    full_image = seg0_pad + seg1_pad + seg2_pad + seg3_pad + rom_bytes
    bin_path = f"{BUILD_DIR}/{bin_name}"
    exe_path = f"{BUILD_DIR}/{exe_name}"

    with open(bin_path, "wb") as f:
        f.write(full_image)
    print(f"[gb200lx] Combined binary: {bin_path} ({len(full_image)} bytes)")

    # 9. Prepend MZ Header
    subprocess.run(["python3", "tools/mzpack.py", bin_path, exe_path, "--min-extra", "0x2000"], check=True)
    print(f"[gb200lx] SUCCESS: Built standalone executable: {exe_path}")

    # Copy INI file to build dir
    subprocess.run(["cp", "GB200LX.INI", f"{BUILD_DIR}/GB200LX.INI"], check=True)
    print(f"[gb200lx] Copied GB200LX.INI -> {BUILD_DIR}/GB200LX.INI")

if __name__ == "__main__":
    main()
