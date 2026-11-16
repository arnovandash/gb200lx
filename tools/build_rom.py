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


def detect_rst_table_dispatchers(disasm: SM83Disassembler) -> Tuple[Set[int], Set[int]]:
    """
    Detect RST vectors in Bank 0 (0x00, 0x08, ..., 0x38) that implement an inline
    jump-table dispatcher (popping the caller return address via POP HL/DE/BC and
    tail-jumping via JP (HL), optionally following an initial unconditional JP/JR).
    Returns (rst_table_vecs, pop_ret_jp_hl_addrs).
    """
    rst_vecs: Set[int] = set()
    pop_jp_hl_addrs: Set[int] = set()
    for vec in [0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38]:
        cur = vec
        saw_pop = False
        for step in range(20):
            ins = disasm.decode_instr(0, cur)
            m = ins.mnemonic
            # The return-address POP must occur within the first 6 instructions
            if m in ("POP HL", "POP DE", "POP BC") and step < 6:
                saw_pop = True
            if m == "JP (HL)" and saw_pop:
                rst_vecs.add(vec)
                pop_jp_hl_addrs.add(cur)
                break
            if ins.is_unconditional_jump and ins.target_addr is not None and m != "JP (HL)":
                cur = ins.target_addr
                continue
            if m in ("RET", "RETI", "NOP") or m.startswith("RST "):
                break
            cur += max(1, ins.length)
    return rst_vecs, pop_jp_hl_addrs


def detect_hram_dma_routine(disasm: SM83Disassembler) -> int:
    """
    Locate the ROM source routine in Bank 0 that performs OAM DMA (`LD A, nn; LDH (0x46), A`)
    and is copied into HRAM (`0xFF80..0xFFFE`) at startup.
    """
    for a in range(2, 0x4000 - 2):
        if disasm.read_u8(0, a) == 0xE0 and disasm.read_u8(0, a + 1) == 0x46:
            if disasm.read_u8(0, a - 2) == 0x3E:
                return a - 2
            return a
    return 0x3F92


def read_inline_jump_table(disasm: SM83Disassembler, bank: int, table_addr: int) -> List[int]:
    """
    Read a contiguous array of 16-bit Game Boy target pointers starting at table_addr.
    Stops when reaching the lowest target in the same bank after table_addr, or invalid code.
    """
    limit = 0x4000 if bank == 0 else 0x8000
    cur = table_addr
    targets: List[int] = []
    while cur < limit and len(targets) < 128:
        w = disasm.read_u16(bank, cur)
        if w < 0x0008 or (0x0104 <= w < 0x0150) or w >= 0x8000:
            break
        if table_addr < w < limit and ((bank == 0 and w < 0x4000) or (bank > 0 and w >= 0x4000)):
            limit = w
        targets.append(w)
        cur += 2
    return targets


def load_sym_seeds(sym_path: str) -> Tuple[Set[int], Dict[int, Set[int]]]:
    """
    Parse an RGBDS / mgbdis .sym file for ROM code entry seeds.
    Ignores mgbdis data/text/image/padding directives and non-ROM addresses (>= 0x8000).
    """
    b0_seeds: Set[int] = set()
    bn_seeds: Dict[int, Set[int]] = {1: set(), 2: set(), 3: set()}
    skip_prefixes = (".data:", ".text:", ".image:", ".padding:", ".data", ".text", ".image", ".padding")
    with open(sym_path, "r", encoding="utf-8", errors="ignore") as f:
        for raw in f:
            line = raw.split(";", 1)[0].strip()
            if not line or ":" not in line:
                continue
            parts = line.split()
            loc = parts[0]
            name = parts[1] if len(parts) > 1 else ""
            if any(name.lower().startswith(p) for p in skip_prefixes):
                continue
            try:
                bank_str, addr_str = loc.split(":", 1)
                bank = int(bank_str, 16)
                addr = int(addr_str, 16)
            except ValueError:
                continue
            if bank == 0 and 0x0000 <= addr < 0x4000:
                b0_seeds.add(addr)
            elif bank in (1, 2, 3) and 0x4000 <= addr < 0x8000:
                bn_seeds[bank].add(addr)
    return b0_seeds, bn_seeds


def load_cdl_seeds(cdl_path: str, rom_size: int) -> Tuple[Set[int], Dict[int, Set[int]]]:
    """
    Parse a Mesen2 / Game Boy Code-Data-Log (.cdl) file.
    Bit 0 (0x01) = executed code byte; Bit 4 (0x10) = jump/call target.
    Seeds jump targets and starts of contiguous code runs in Banks 0..3.
    """
    b0_seeds: Set[int] = set()
    bn_seeds: Dict[int, Set[int]] = {1: set(), 2: set(), 3: set()}
    with open(cdl_path, "rb") as f:
        cdl = f.read()
    limit = min(len(cdl), rom_size, 0x10000)
    prev_code = False
    for offset in range(limit):
        flags = cdl[offset]
        is_code = bool(flags & 0x01)
        is_target = bool(flags & 0x10)
        if is_target or (is_code and not prev_code):
            bank = offset // 0x4000
            addr = (offset % 0x4000) + (0x4000 if bank > 0 else 0)
            if bank == 0:
                b0_seeds.add(addr)
            elif bank in (1, 2, 3):
                bn_seeds[bank].add(addr)
        prev_code = is_code
    return b0_seeds, bn_seeds


def discover_control_flow(
    disasm: SM83Disassembler,
    rst_table_vecs: Set[int],
    hram_dma_addr: int,
    extra_b0_seeds: Set[int] = None,
    extra_bn_seeds: Dict[int, Set[int]] = None,
):
    """
    Perform validated control-flow and jump-table discovery across all banks.
    Never pollutes code labels with interior operand bytes or graphics/level data.
    """
    bank_labels: Dict[int, Set[int]] = {b: set() for b in range(4)}
    jp_hl_targets: Dict[int, Set[int]] = {b: set() for b in range(4)}
    b0_to_bn_set: Set[int] = set()
    bn_to_b0_set: Set[int] = set()

    # 1. Trace Bank 0 from hardware entry vectors + optional .sym/.cdl seeds
    b0_seeds = [0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48, 0x50, 0x58, 0x60, 0x100, 0x150, hram_dma_addr]
    if extra_b0_seeds:
        b0_seeds.extend(sorted(extra_b0_seeds))
    worklist: List[int] = list(b0_seeds)
    for a in b0_seeds:
        bank_labels[0].add(a)

    b0_vis: Set[int] = set()
    b0_interior: Set[int] = set()

    def trace_b0_worklist(wl: List[int]):
        while wl:
            addr = wl.pop()
            if addr in b0_vis or addr in b0_interior or not (0 <= addr < 0x4000):
                continue
            b0_vis.add(addr)

            ins = disasm.decode_instr(0, addr)
            for k in range(1, ins.length):
                b0_interior.add(addr + k)
            m = ins.mnemonic

            if m.startswith("RST "):
                vec = int(m[4:], 16)
                if vec in rst_table_vecs:
                    tbl_targets = read_inline_jump_table(disasm, 0, addr + ins.length)
                    for t in tbl_targets:
                        jp_hl_targets[0].add(t)
                        if t < 0x4000:
                            bank_labels[0].add(t)
                            wl.append(t)
                        elif t < 0x8000:
                            b0_to_bn_set.add(t)
                    continue

            if m == "JP (HL)":
                for back in (6, 10):
                    if addr >= back and disasm.read_u8(0, addr - back) == 0x21 and disasm.read_u8(0, addr - back + 3) == 0xCD:
                        tbl = disasm.read_u16(0, addr - back + 1)
                        if 0x0150 <= tbl < 0x4000:
                            t_start = tbl + 2 if disasm.read_u16(0, tbl) == 0 else tbl
                            for t in read_inline_jump_table(disasm, 0, t_start):
                                jp_hl_targets[0].add(t)
                                if t < 0x4000:
                                    bank_labels[0].add(t)
                                    wl.append(t)
                                elif t < 0x8000:
                                    b0_to_bn_set.add(t)
                continue

            # Detect `LD BC/DE/HL, imm16; PUSH BC/DE/HL` synthetic return-address pushes (e.g. LZ77 loop return)
            if ins.length == 3 and m.startswith(("LD BC, 0x", "LD DE, 0x", "LD HL, 0x")):
                rr = m[3:5]
                imm = int(m.split(", ")[1], 16)
                next_ins = disasm.decode_instr(0, addr + 3)
                if next_ins.mnemonic == f"PUSH {rr}" and 0x0150 <= imm < 0x4000:
                    bank_labels[0].add(imm)
                    wl.append(imm)

            if ins.target_addr is not None:
                t = ins.target_addr
                if t < 0x4000:
                    bank_labels[0].add(t)
                    wl.append(t)
                elif t < 0x8000:
                    b0_to_bn_set.add(t)

            if not ins.is_unconditional_jump and m not in ("RET", "RETI"):
                wl.append(addr + ins.length)

    trace_b0_worklist(worklist)
    bank_labels[0] -= b0_interior

    # 2. Helper to validate and trace a candidate function entry in Bank 1..3
    def trace_bank_subgraph(b: int, start_t: int):
        wl = [start_t]
        vis: Set[int] = set()
        interior: Set[int] = set()
        labels: Set[int] = {start_t}
        b0_refs: Set[int] = set()
        tbl_addrs: Set[int] = set()
        rst_jp_targets: Set[int] = set()

        while wl:
            a = wl.pop()
            if a in vis:
                continue
            if not (0x4000 <= a < 0x8000):
                return None
            vis.add(a)
            ins = disasm.decode_instr(b, a)
            m = ins.mnemonic
            if m.startswith("DB ") or m == "STOP" or m == "RST 0x38" or m.startswith("LD SP"):
                return None
            for k in range(1, ins.length):
                interior.add(a + k)

            if m.startswith("RST "):
                vec = int(m[4:], 16)
                if vec in rst_table_vecs:
                    tbl_targets = read_inline_jump_table(disasm, b, a + ins.length)
                    if not tbl_targets:
                        return None
                    for t in tbl_targets:
                        rst_jp_targets.add(t)
                        if 0x4000 <= t < 0x8000:
                            labels.add(t)
                            wl.append(t)
                        elif 0x0150 <= t < 0x4000 and t not in b0_interior:
                            b0_refs.add(t)
                    continue

            if m == "JP (HL)":
                if disasm.read_u8(b, a - 3) == 0xCD and disasm.read_u8(b, a - 6) == 0x21:
                    tbl = disasm.read_u16(b, a - 5)
                    if 0x4000 <= tbl < 0x8000:
                        tbl_addrs.add(tbl)
                continue

            if ins.target_addr is not None:
                t = ins.target_addr
                if t < 0x4000:
                    if t in b0_interior or (t < 0x0150 and not m.startswith("RST ")):
                        return None
                    b0_refs.add(t)
                elif t < 0x8000:
                    labels.add(t)
                    wl.append(t)
                else:
                    return None

            if not ins.is_unconditional_jump and m not in ("RET", "RETI"):
                wl.append(a + ins.length)

        if (labels & interior) or (vis & interior):
            return None
        return vis, interior, labels, b0_refs, tbl_addrs, rst_jp_targets

    # 3. Trace Banks 1..3 and Bank 0 cross-bank references iteratively to fixed point
    for _round in range(3):
        prev_b0_to_bn = len(b0_to_bn_set)
        prev_bn_to_b0 = len(bn_to_b0_set)
        for b in [1, 2, 3]:
            b_interior: Set[int] = set()
            pending_tables: Set[int] = set()
            candidates = set(b0_to_bn_set)
            if extra_bn_seeds and b in extra_bn_seeds:
                candidates |= extra_bn_seeds[b]
            for t in sorted(candidates):
                bank_labels[b].add(t)
                res = trace_bank_subgraph(b, t)
                if res is not None:
                    vis, interior, labels, b0_refs, tbl_addrs, rst_jp_targets = res
                    b_interior |= interior
                    bank_labels[b] |= labels
                    pending_tables |= tbl_addrs
                    jp_hl_targets[b] |= rst_jp_targets
                    for r in b0_refs:
                        bn_to_b0_set.add(r)
                        bank_labels[0].add(r)

            # Also trace validated JP (HL) table entries in Bank b transitively
            seen_tables: Set[int] = set()
            while pending_tables:
                tbl = min(pending_tables)
                pending_tables.remove(tbl)
                if tbl in seen_tables:
                    continue
                seen_tables.add(tbl)
                for i in range(32):
                    w = disasm.read_u16(b, tbl + i * 2)
                    if not (0x4000 <= w < 0x8000):
                        break
                    res = trace_bank_subgraph(b, w)
                    if res is not None:
                        vis, interior, labels, b0_refs, more_tbls, rst_jp_targets = res
                        b_interior |= interior
                        bank_labels[b] |= labels
                        jp_hl_targets[b].add(w)
                        jp_hl_targets[b] |= rst_jp_targets
                        pending_tables |= (more_tbls - seen_tables)
                        for r in b0_refs:
                            bn_to_b0_set.add(r)
                            bank_labels[0].add(r)
                    else:
                        break

            bank_labels[b] -= b_interior

        # 4. Trace any newly discovered bn_to_b0 entry points in Bank 0
        new_b0 = list(bn_to_b0_set - b0_vis)
        if new_b0:
            trace_b0_worklist(new_b0)
            bank_labels[0] -= b0_interior

        if len(b0_to_bn_set) == prev_b0_to_bn and len(bn_to_b0_set) == prev_bn_to_b0:
            break

    return bank_labels, jp_hl_targets, b0_to_bn_set, bn_to_b0_set


def main():
    parser = argparse.ArgumentParser(
        description="GB200LX: Static Game Boy (DMG) to 16-Bit 80186 DOS Recompiler for HP 200LX"
    )
    parser.add_argument("rom", nargs="?", help="Path to input Game Boy (.gb) ROM file")
    parser.add_argument("-o", "--output", default="GAME.EXE", help="Output DOS executable name (default: GAME.EXE)")
    parser.add_argument("--sym", help="Optional RGBDS/mgbdis .sym file for additional code entry seeds")
    parser.add_argument("--cdl", help="Optional Mesen2/emulator .cdl Code-Data-Log file for code entry seeds")
    args = parser.parse_args()

    rom_path = args.rom
    if not rom_path:
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

    # 1. Detect inline RST jump-table dispatchers, HRAM DMA, optional .sym/.cdl seeds, & run control-flow discovery
    extra_b0_seeds: Set[int] = set()
    extra_bn_seeds: Dict[int, Set[int]] = {1: set(), 2: set(), 3: set()}

    rom_stem = os.path.splitext(rom_path)[0]
    sym_path = args.sym or (rom_stem + ".sym" if os.path.exists(rom_stem + ".sym") else None)
    cdl_path = args.cdl or (rom_stem + ".cdl" if os.path.exists(rom_stem + ".cdl") else None)

    if sym_path and os.path.exists(sym_path):
        s_b0, s_bn = load_sym_seeds(sym_path)
        extra_b0_seeds |= s_b0
        for bk in (1, 2, 3):
            extra_bn_seeds[bk] |= s_bn[bk]
        print(f"[gb200lx] Loaded .sym seeds from {sym_path}: B0={len(s_b0)}, B1..3={[len(s_bn[k]) for k in (1, 2, 3)]}")

    if cdl_path and os.path.exists(cdl_path):
        c_b0, c_bn = load_cdl_seeds(cdl_path, len(rom_bytes))
        extra_b0_seeds |= c_b0
        for bk in (1, 2, 3):
            extra_bn_seeds[bk] |= c_bn[bk]
        print(f"[gb200lx] Loaded .cdl seeds from {cdl_path}: B0={len(c_b0)}, B1..3={[len(c_bn[k]) for k in (1, 2, 3)]}")

    rst_table_vecs, pop_jp_hl_addrs = detect_rst_table_dispatchers(disasm)
    hram_dma_addr = detect_hram_dma_routine(disasm)
    print(f"[gb200lx] Detected inline jump-table RST vectors: {[hex(v) for v in sorted(rst_table_vecs)]}")
    print(f"[gb200lx] Detected HRAM OAM DMA source routine at: 0x{hram_dma_addr:04x}")

    bank_labels, jp_hl_targets, b0_to_bn_set, bn_to_b0_set = discover_control_flow(
        disasm, rst_table_vecs, hram_dma_addr, extra_b0_seeds, extra_bn_seeds
    )

    b0_to_bn = sorted(list(b0_to_bn_set))
    b0_to_bn_idx = {t: i for i, t in enumerate(b0_to_bn)}

    bn_to_b0 = sorted(list(bn_to_b0_set))
    bn_to_b0_idx = {t: i for i, t in enumerate(bn_to_b0)}

    print(f"[gb200lx] Cross-bank entry points: Bank 0 -> Banks 1..3: {len(b0_to_bn)} targets")
    print(f"[gb200lx] Cross-bank entry points: Banks 1..3 -> Bank 0: {len(bn_to_b0)} targets")
    for b in range(4):
        print(f"[gb200lx] Bank {b} JP (HL) targets: {len(jp_hl_targets[b])}")

    # 2. Generate Bank Jump Tables & Dispatches
    # Bank 0 layout starting at offset 4:
    #   0004h..001Fh: 7 far-callable runtime helper bridges (7 * 4 = 28 bytes)
    #   0020h..     : b0_entry_table (bn_to_b0 wrappers, 4 bytes each)
    disp_b0_lines = [
        "bits 16", "cpu 186", "",
        "; Fixed-offset far-callable runtime helper bridges at 0004h..001Ch",
        "global b0_helper_table",
        "b0_helper_table:",
        "    call near helper_write_mbc",
        "    retf",
        "    call near helper_write_mmio",
        "    retf",
        "    call near helper_read_joyp",
        "    retf",
        "    call near helper_read_div",
        "    retf",
        "    call near helper_read_ly",
        "    retf",
        "    call near helper_update_bgp",
        "    retf",
        "    call near helper_halt",
        "    retf",
        "",
        "; Table of wrappers in Bank 0 called from Banks 1..3 (starts at exact offset 0020h = 32)",
        "global b0_entry_table",
        "b0_entry_table:",
    ]
    for t in bn_to_b0:
        disp_b0_lines.append(f"    call near loc_00_{t:04x}")
        disp_b0_lines.append("    retf")

    disp_b0_lines.extend([
        "",
        "; Far dispatch helper for Bank 0 (preserves CPU flags across far return)",
        "global do_far_dispatch",
        "do_far_dispatch:",
        "    mov     bp, sp",
        "    call    far [bp]",
        "    pop     bp",
        "    pop     bp",
        "    ret",
        "",
        "; Indirect jump dispatcher JP (HL) for Bank 0",
        "global helper_dispatch_jp_hl",
        "helper_dispatch_jp_hl:",
    ])
    for t in sorted(jp_hl_targets[0]):
        disp_b0_lines.append(f"    cmp cx, 0{t:04X}h")
        if t < 0x4000:
            disp_b0_lines.append(f"    je  near loc_00_{t:04x}")
        else:
            disp_b0_lines.append(f"    je  near dispatch_call_{t:04x}")
    disp_b0_lines.append("    lea di, [di + 2]")
    disp_b0_lines.append("    ret")
    disp_b0_lines.append("")
    disp_b0_lines.append("; Dispatchers for Bank 0 calling Banks 1..3")

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

    # Banks 1, 2, 3: Jump table at exact offset 0 (B0 -> BN entry points)
    for b in [1, 2, 3]:
        disp_bn_lines = [
            "bits 16", "cpu 186", "",
            f"; Bank {b} Entry Jump Table (starts at exact offset 0)",
            f"global b{b}_entry_table",
            f"b{b}_entry_table:",
        ]
        for t in b0_to_bn:
            disp_bn_lines.append(f"    call near loc_{b:02x}_{t:04x}")
            disp_bn_lines.append("    retf")

        disp_bn_lines.extend([
            "",
            f"; Indirect jump dispatcher JP (HL) for Bank {b}",
            "global helper_dispatch_jp_hl",
            "helper_dispatch_jp_hl:",
        ])
        for t in sorted(jp_hl_targets[b]):
            disp_bn_lines.append(f"    cmp cx, 0{t:04X}h")
            if t >= 0x4000:
                disp_bn_lines.append(f"    je  near loc_{b:02x}_{t:04x}")
            elif t in bn_to_b0_idx:
                disp_bn_lines.append(f"    je  near .jp_b0_{t:04x}")
        disp_bn_lines.append("    lea di, [di + 2]")
        disp_bn_lines.append("    ret")
        for t in sorted(jp_hl_targets[b]):
            if t < 0x4000 and t in bn_to_b0_idx:
                disp_bn_lines.append(f".jp_b0_{t:04x}:")
                disp_bn_lines.append(f"    call near call_bank0_{t:04x}")
                disp_bn_lines.append("    ret")

        disp_bn_lines.append("\n; Far call helpers for calling Bank 0 (b0_entry_table starts at offset 32)")
        for t in bn_to_b0:
            idx = bn_to_b0_idx[t]
            disp_bn_lines.append(f"global call_bank0_{t:04x}")
            disp_bn_lines.append(f"call_bank0_{t:04x}:")
            disp_bn_lines.append("    push bp")
            disp_bn_lines.append("    mov bp, cs")
            disp_bn_lines.append("    sub bp, SEG_PARAS_VAL")
            disp_bn_lines.append("    push bp")
            disp_bn_lines.append(f"    push word (32 + {idx * 4})")
            disp_bn_lines.append("    mov bp, sp")
            disp_bn_lines.append("    call far [bp]")
            disp_bn_lines.append("    pop bp")
            disp_bn_lines.append("    pop bp")
            disp_bn_lines.append("    pop bp")
            disp_bn_lines.append("    ret")

        with open(f"{OUT_DIR}/dispatch_b{b}.asm", "w") as f:
            f.write("\n".join(disp_bn_lines) + "\n")

    # 3. Emit Recompiled Code for Bank 0..3 with Label-Resynchronized Disassembly
    for b in range(4):
        start_addr = 0x0000 if b == 0 else 0x4000
        end_addr = 0x4000 if b == 0 else 0x8000
        cg = CodeGenerator80186(disasm)

        # Pre-populate cg.labels with discovered control-flow labels
        for l_addr in bank_labels[b]:
            cg.labels.add((b, l_addr))

        # Now disassemble with label-resynchronization at ALL known labels in cg.labels
        all_lbl_addrs = sorted(addr for (bk, addr) in cg.labels if bk == b and start_addr <= addr < end_addr)
        lbl_set = set(all_lbl_addrs)

        lines = [
            f"; Bank {b:02X} Recompiled Code",
            "bits 16", "cpu 186", "",
        ]

        curr = start_addr
        while curr < end_addr:
            if curr in lbl_set:
                lbl = cg.label_name(b, curr)
                lines.append(f"global {lbl}")
                lines.append(f"{lbl}:")

            instr = disasm.decode_instr(b, curr)
            next_c = curr + max(1, instr.length)

            # Check if this instruction would step over a known label!
            stepped_over = None
            for k in range(curr + 1, next_c):
                if k in lbl_set:
                    stepped_over = k
                    break
            if stepped_over is not None:
                # Emit raw bytes up to the label so disassembly stays 100% synchronized!
                for k in range(curr, stepped_over):
                    bval = disasm.read_u8(b, k)
                    lines.append(f"    db 0{bval:02X}h")
                curr = stepped_over
                continue

            # Special handling for JP (HL) inside an inline RST jump-table dispatcher (e.g. 0x0033 in Bank 0):
            # Pop the native return address pushed by `call near loc_00_0028` before jumping!
            if b == 0 and curr in pop_jp_hl_addrs and instr.mnemonic == "JP (HL)":
                lines.append("    add sp, 2")
                lines.append("    mov si, cx")
                lines.append("    jmp near helper_dispatch_jp_hl")
                curr = next_c
                continue

            # Synthetic return-address push: `LD BC/DE/HL, imm16; PUSH BC/DE/HL` where imm16 is a known code label
            if (instr.length == 3
                    and instr.mnemonic.startswith(("LD BC, 0x", "LD DE, 0x", "LD HL, 0x"))
                    and (curr + 3) not in lbl_set):
                rr = instr.mnemonic[3:5]
                imm = int(instr.mnemonic.split(", ")[1], 16)
                next_ins = disasm.decode_instr(b, curr + 3)
                if next_ins.mnemonic == f"PUSH {rr}" and imm in lbl_set:
                    xreg = {"BC": "bx", "DE": "dx", "HL": "cx"}[rr]
                    lbl_cont = f".push_ret_{curr:04x}"
                    lines.append(f"    mov {xreg}, 0{imm:04X}h")
                    lines.append("    lea di, [di - 2]")
                    lines.append(f"    mov [di], {xreg}")
                    lines.append(f"    call near {lbl_cont}")
                    lines.append(f"    jmp near {cg.label_name(b, imm)}")
                    lines.append(f"{lbl_cont}:")
                    curr = curr + 4
                    continue

            # Inline RST jump-table call (e.g. RST 0x28 or RST 0x00) in any bank 0..3:
            # Computes target = word [next_c + A * 2] and dispatches via current bank's helper_dispatch_jp_hl!
            if instr.mnemonic.startswith("RST ") and int(instr.mnemonic[4:], 16) in rst_table_vecs:
                lines.append(f"    mov cx, 0{next_c:04X}h")
                lines.append("    add al, al")
                lines.append("    mov dl, al")
                lines.append("    mov dh, 000h")
                lines.append("    add cx, dx")
                lines.append("    mov si, cx")
                lines.append("    mov dl, [si]")
                lines.append("    inc cx")
                lines.append("    mov si, cx")
                lines.append("    mov dh, [si]")
                lines.append("    mov cx, dx")
                lines.append("    mov si, cx")
                lines.append("    jmp near helper_dispatch_jp_hl")
                curr = next_c
                continue

            # Generic interrupt-driven spin-loop yield:
            # A 3-instruction loop `LDH/LD A, (RAM) -> AND/OR A, A -> JR Z, loop_start` modifies no memory or
            # registers and can only exit when an ISR (VBlank/Timer) updates the polled RAM byte.
            if instr.mnemonic.startswith("JR Z, ") and instr.target_addr is not None and curr - 4 <= instr.target_addr <= curr - 3:
                t_spin = instr.target_addr
                i0 = disasm.decode_instr(b, t_spin)
                i1 = disasm.decode_instr(b, t_spin + i0.length)
                if (t_spin + i0.length + i1.length == curr
                        and (i0.mnemonic.startswith("LDH A, (0x") or i0.mnemonic.startswith("LD A, (0xC") or i0.mnemonic.startswith("LD A, (0xD"))
                        and i1.mnemonic in ("AND A, A", "OR A, A")):
                    cg.labels.add((b, t_spin))
                    lbl_done = f".spin_exit_{curr:04x}"
                    lines.append(f"    jnz short {lbl_done}")
                    lines.append("    call helper_halt")
                    lines.append(f"    jmp near {cg.label_name(b, t_spin)}")
                    lines.append(f"{lbl_done}:")
                    curr = next_c
                    continue

            # Route cross-bank CALL and cross-bank JP (including conditional CALL cc / JP cc)
            if (instr.is_call or instr.is_branch) and instr.target_addr is not None:
                t = instr.target_addr
                m = instr.mnemonic
                next_addr = f"0{next_c:04X}h"

                # Determine if cross-bank
                cross_call_line = None
                if b == 0 and t >= 0x4000:
                    if t in b0_to_bn_idx:
                        cross_call_line = f"call near dispatch_call_{t:04x}"
                    elif t >= 0xFF80:
                        cross_call_line = f"call near loc_00_{hram_dma_addr:04x}"
                    else:
                        curr = next_c
                        continue
                elif b > 0 and t < 0x4000:
                    if t in bn_to_b0_idx:
                        cross_call_line = f"call near call_bank0_{t:04x}"
                    else:
                        curr = next_c
                        continue

                if cross_call_line is not None:
                    parts = m.split()[1].split(", ")
                    is_cond = len(parts) > 1
                    cond = parts[0] if is_cond else None
                    neg_jcc = {"Z": "jnz", "NZ": "jz", "C": "jnc", "NC": "jc"}.get(cond, "jmp")

                    if instr.is_call:
                        if is_cond:
                            lbl_skip = f".skip_cc_{curr:04x}"
                            lines.append(f"    {neg_jcc} short {lbl_skip}")
                            lines.append("    lea di, [di - 2]")
                            lines.append(f"    mov word [di], {next_addr}")
                            lines.append(f"    {cross_call_line}")
                            lines.append(f"{lbl_skip}:")
                        else:
                            lines.append("    lea di, [di - 2]")
                            lines.append(f"    mov word [di], {next_addr}")
                            lines.append(f"    {cross_call_line}")
                    else:
                        # Cross-bank JP / JP cc (tail jump: target will execute lea di, [di + 2]; ret)
                        if is_cond:
                            lbl_skip = f".skip_cj_{curr:04x}"
                            lines.append(f"    {neg_jcc} short {lbl_skip}")
                            lines.append(f"    {cross_call_line}")
                            lines.append("    ret")
                            lines.append(f"{lbl_skip}:")
                        else:
                            lines.append(f"    {cross_call_line}")
                            lines.append("    ret")
                    curr = next_c
                    continue

            x86_ops = cg.translate_instruction(instr)
            if x86_ops:
                lines.append(f"    {x86_ops[0]}")
                for extra in x86_ops[1:]:
                    lines.append(f"    {extra}")

            curr = next_c

        with open(f"{OUT_DIR}/code_b{b}.asm", "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"[gb200lx] Emitted code for Bank {b}")

    # 4. Generate Stubs for Any Remaining Unresolved Internal Branch Targets
    for b in range(4):
        defined = set()
        called = set()
        files_to_scan = [f"{OUT_DIR}/code_b{b}.asm", f"{OUT_DIR}/dispatch_b{b}.asm"]
        if b == 0:
            files_to_scan.append("runtime/crt0_rom.asm")
            files_to_scan.append("runtime/recomp_helpers.asm")
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
                f.write(f"global {m}\n{m}:\n    lea di, [di + 2]\n    ret\n")
        print(f"[gb200lx] Bank {b}: {len(defined)} defined, {len(missing)} stubs")

    # 5. Assemble Pass 1 to get exact segment paragraph sizes
    seg0_header = f"""
bits 16
cpu 186
org 0

%define SEG_IS_BANK0 1
%define SEG1_PARAS_VAL 01111h
%define SEG2_PARAS_VAL 02222h
%define SEG3_PARAS_VAL 03333h
%define SEG_ROM_PARAS_VAL 04444h

entry_trampoline:
    jmp near entry
    nop                         ; Align b0_helper_table to exact offset 4!

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

    # Segments 1..3 Pass 1 (b{b}_entry_table at exact offset 0!)
    for b in [1, 2, 3]:
        seg_asm = f"""
bits 16
cpu 186
org 0

%define SEG_PARAS_VAL 01111h

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

%define SEG_PARAS_VAL 0{para_val:04X}h

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
