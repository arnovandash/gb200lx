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


def detect_rst_table_dispatchers(disasm: SM83Disassembler) -> Tuple[Set[int], Set[int], Set[int]]:
    """
    Detect RST vectors in Bank 0 (0x00, 0x08, ..., 0x38) that implement:
      1. Inline jump-table dispatchers (POP HL/DE/BC + JP (HL)) -> rst_table_vecs
      2. 1-byte inline-argument handlers (POP HL + LDI A,(HL) / LD A,(HL);INC HL + PUSH HL) -> rst_1b_arg_vecs
    Returns (rst_table_vecs, pop_jp_hl_addrs, rst_1b_arg_vecs).
    """
    rst_vecs: Set[int] = set()
    pop_jp_hl_addrs: Set[int] = set()
    rst_1b_arg_vecs: Set[int] = set()
    for vec in [0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38]:
        cur = vec
        saw_pop = False
        pop_step = -1
        last_pop_hl_step = -10
        saw_read_hl = False
        read_hl_step = -10
        for step in range(24):
            ins = disasm.decode_instr(0, cur)
            m = ins.mnemonic
            if m in ("POP HL", "POP DE", "POP BC") and not saw_pop and step < 6:
                saw_pop = True
                pop_step = step
            if m == "POP HL":
                last_pop_hl_step = step
            if m == "JP (HL)" and saw_pop:
                rst_vecs.add(vec)
                pop_jp_hl_addrs.add(cur)
                break
            if step <= last_pop_hl_step + 3 and m in ("LDI A, (HL)", "LD A, (HL)"):
                saw_read_hl = True
                read_hl_step = step
            elif saw_read_hl and step <= read_hl_step + 2 and m == "PUSH HL":
                rst_1b_arg_vecs.add(vec)
                break
            if ins.is_unconditional_jump and ins.target_addr is not None and m != "JP (HL)":
                cur = ins.target_addr
                continue
            if m in ("RET", "RETI", "NOP") or m.startswith("RST "):
                break
            cur += max(1, ins.length)
    return rst_vecs, pop_jp_hl_addrs, rst_1b_arg_vecs


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


def load_sym_seeds(sym_path: str, num_banks: int = 4) -> Tuple[Set[int], Dict[int, Set[int]]]:
    """
    Parse an RGBDS / mgbdis .sym file for ROM code entry seeds across Banks 0..num_banks-1.
    Ignores mgbdis data/text/image/padding directives and non-ROM addresses (>= 0x8000).
    """
    b0_seeds: Set[int] = set()
    bn_seeds: Dict[int, Set[int]] = {b: set() for b in range(1, num_banks)}
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
            elif 1 <= bank < num_banks and 0x4000 <= addr < 0x8000:
                bn_seeds[bank].add(addr)
    return b0_seeds, bn_seeds


def load_cdl_seeds(cdl_path: str, rom_size: int) -> Tuple[Set[int], Dict[int, Set[int]]]:
    """
    Parse a Mesen2 / Game Boy Code-Data-Log (.cdl) file.
    Bit 0 (0x01) = executed code byte; Bit 4 (0x10) = jump/call target.
    Seeds jump targets and starts of contiguous code runs in all ROM banks.
    """
    num_banks = max(4, rom_size // 0x4000)
    b0_seeds: Set[int] = set()
    bn_seeds: Dict[int, Set[int]] = {b: set() for b in range(1, num_banks)}
    with open(cdl_path, "rb") as f:
        cdl = f.read()
    limit = min(len(cdl), rom_size)
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
            elif 1 <= bank < num_banks:
                bn_seeds[bank].add(addr)
        prev_code = is_code
    return b0_seeds, bn_seeds


# SM83 mnemonics (prefixes) that read the current flags
_FLAG_READERS = ("ADC ", "SBC ", "RLA", "RRA", "RL ", "RR ", "DAA", "CCF", "PUSH AF", "BIT ", "DB ")
# Mnemonics whose translation redefines every flag a later reader can use (ZF, CF, AF)
_FLAG_KILLERS = ("ADD A, ", "SUB A, ", "AND A, ", "OR A, ", "XOR A, ", "CP A, ",
                 "SLA ", "SRA ", "SRL ", "SWAP ", "RLC ", "RRC ", "POP AF")
# Control transfers / yields: flags may be observed elsewhere, so treat as live
_FLAG_BARRIERS = ("JR", "JP", "CALL", "RET", "RST", "HALT", "STOP")


def flags_dead_after(disasm: SM83Disassembler, bank: int, addr: int, end_addr: int,
                     lbl_set: Set[int], window: int = 16) -> bool:
    """Conservative straight-line flag liveness: True only if, starting at `addr`,
    an instruction that fully redefines the flags is reached before any flag reader,
    control transfer, branch-target label, or the end of the scan window."""
    for _ in range(window):
        if addr >= end_addr or addr in lbl_set:
            return False
        ins = disasm.decode_instr(bank, addr)
        if ins.length < 1 or any(k in lbl_set for k in range(addr + 1, addr + ins.length)):
            return False
        m = ins.mnemonic
        if ins.is_branch or ins.is_call or ins.is_ret or m.startswith(_FLAG_BARRIERS):
            return False
        if m.startswith(_FLAG_READERS):
            return False
        if m.startswith(_FLAG_KILLERS):
            return True
        addr += ins.length
    return False


def is_inline_table_helper(disasm: SM83Disassembler, entry: int) -> bool:
    """Return True if Bank 0 routine at `entry` implements `POP HL; ...; JP (HL)`."""
    if not (0x0150 <= entry < 0x4000) or disasm.read_u8(0, entry) != 0xE1:
        return False
    cur = entry + 1
    for _ in range(12):
        ins = disasm.decode_instr(0, cur)
        m = ins.mnemonic
        if m == "JP (HL)":
            return True
        if m in ("RET", "RETI", "NOP") or (ins.is_unconditional_jump and ins.target_addr is None):
            return False
        cur += max(1, ins.length)
    return False


def read_ptr_table(
    disasm: SM83Disassembler,
    bank: int,
    table_addr: int,
    code_addrs: Set[int] = None,
    max_entries: int = 128,
) -> List[int]:
    """
    Read a contiguous 16-bit code-pointer table at `table_addr` in `bank`.
    Bank 0 tables constrain targets to `0x0150..0x3FFF`; Bank >0 tables allow
    `0x4000..0x7FFF` (same bank) plus `0x0150..0x3FFF` (shared Bank 0 trampolines).
    Stops if reading into decoded instructions or past the lowest forward target.
    """
    lo_min, hi_max = (0x0150, 0x4000) if bank == 0 else (0x0150, 0x8000)
    limit = 0x4000 if bank == 0 else 0x8000
    cur = table_addr
    targets: List[int] = []
    while cur + 1 < limit and len(targets) < max_entries:
        if code_addrs and (cur in code_addrs or (cur + 1) in code_addrs):
            break
        w = disasm.read_u16(bank, cur)
        if not (lo_min <= w < hi_max) or (0x0100 <= w < 0x0150):
            break
        t_bk = 0 if w < 0x4000 else bank
        ins = disasm.decode_instr(t_bk, w)
        if ins.mnemonic.startswith("DB ") or ins.mnemonic in ("STOP", "RST 0x38"):
            break
        if table_addr < w < limit and ((bank == 0 and w < 0x4000) or (bank > 0 and w >= 0x4000)):
            limit = w
        targets.append(w)
        cur += 2
    return targets


def is_b0_tbl_jp_helper(disasm: SM83Disassembler, entry: int) -> bool:
    """
    Return True if Bank 0 routine `entry` indexes a 16-bit pointer table via HL
    (directly or via a tiny leaf indexing helper) and jumps via `JP (HL)`
    (e.g. FFA `00:2B70: CALL 0x2B63; JP (HL)`).
    """
    if not (0x0150 <= entry < 0x4000) or disasm.read_u8(0, entry) == 0xE1:
        return False

    def has_tbl_read(fn: int, depth: int) -> bool:
        c = fn
        for _ in range(12):
            if not (0x0150 <= c < 0x4000):
                return False
            ins = disasm.decode_instr(0, c)
            m = ins.mnemonic
            if m in ("LDI A, (HL)", "LD A, (HL)"):
                return True
            if depth > 0 and ins.is_call and ins.target_addr is not None and ins.target_addr < 0x4000:
                if has_tbl_read(ins.target_addr, depth - 1):
                    return True
            if m in ("RET", "RETI") or ins.is_unconditional_jump:
                return False
            c += max(1, ins.length)
        return False

    cur = entry
    saw_read = False
    for _ in range(8):
        if not (0x0150 <= cur < 0x4000):
            return False
        ins = disasm.decode_instr(0, cur)
        m = ins.mnemonic
        if m == "JP (HL)":
            return saw_read
        if m in ("LDI A, (HL)", "LD A, (HL)"):
            saw_read = True
        elif ins.is_call and ins.target_addr is not None and ins.target_addr < 0x4000:
            if has_tbl_read(ins.target_addr, 1):
                saw_read = True
        if m in ("RET", "RETI") or (ins.is_unconditional_jump and ins.target_addr is None):
            return False
        cur += max(1, ins.length)
    return False


def discover_control_flow(
    disasm: SM83Disassembler,
    rst_table_vecs: Set[int],
    rst_1b_arg_vecs: Set[int],
    hram_dma_addr: int,
    num_banks: int = 4,
    extra_b0_seeds: Set[int] = None,
    extra_bn_seeds: Dict[int, Set[int]] = None,
):
    """
    Perform validated control-flow and jump-table discovery across all banks.
    Never pollutes code labels with interior operand bytes or graphics/level data.
    """
    bank_labels: Dict[int, Set[int]] = {b: set() for b in range(num_banks)}
    bank_vis: Dict[int, Set[int]] = {b: set() for b in range(num_banks)}
    jp_hl_targets: Dict[int, Set[int]] = {b: set() for b in range(num_banks)}
    exact_bn_seeds: Dict[int, Set[int]] = {b: set() for b in range(1, num_banks)}
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
    ptr_setter_cache: Dict[Tuple[int, str], bool] = {}

    def is_ptr_setter(fn_addr: int, rr: str) -> bool:
        """Detect short acyclic helpers that store a 16-bit register pair into RAM
        as a function pointer (e.g. VBlank callback registration) without dereferencing it."""
        key = (fn_addr, rr)
        if key in ptr_setter_cache:
            return ptr_setter_cache[key]
        lo, hi = {"DE": ("E", "D"), "BC": ("C", "B"), "HL": ("L", "H")}[rr]
        c = fn_addr
        stored_lo = stored_hi = False
        a_src = None
        res = False
        for _ in range(18):
            if not (0 <= c < 0x4000):
                break
            ins2 = disasm.decode_instr(0, c)
            m2 = ins2.mnemonic
            if m2.startswith(("JR ", "JP ", "CALL ")) and ins2.target_addr is not None and ins2.target_addr <= c:
                break
            if m2 in (f"LD A, ({rr})", f"LDI A, ({rr})", f"LDD A, ({rr})"):
                break
            if m2 == f"LD A, {lo}":
                a_src = "lo"
            elif m2 == f"LD A, {hi}":
                a_src = "hi"
            elif m2.startswith("LD (") and m2.endswith(f", {lo}"):
                stored_lo = True
            elif m2.startswith("LD (") and m2.endswith(f", {hi}"):
                stored_hi = True
            elif a_src == "lo" and m2.startswith(("LD (", "LDH (")) and m2.endswith(", A"):
                stored_lo = True
            elif a_src == "hi" and m2.startswith(("LD (", "LDH (")) and m2.endswith(", A"):
                stored_hi = True
            elif m2.startswith(("LD A, ", "XOR A", "POP ", "DEC ", "INC ")) and not m2.startswith(f"INC {rr}"):
                if "A" in m2.split(",")[0]:
                    a_src = None
            if m2 in ("RET", "RETI"):
                res = stored_lo and stored_hi
                break
            if ins2.is_unconditional_jump:
                break
            c += ins2.length
        ptr_setter_cache[key] = res
        return res

    # Detect packed 1-byte inline-arg RST bank/addr tables (e.g. FFL3 RST 0x18 @ 0x378A)
    packed_rst_info: Dict[int, Tuple[int, int, int]] = {}  # vec -> (bank_tbl, ptr_tbl, b0_tbl)
    inline_8tbl_slots: Dict[int, Set[int]] = {}
    for vec in rst_1b_arg_vecs:
        cur = vec
        lds: List[int] = []
        for _ in range(60):
            if not (0 <= cur < 0x4000):
                break
            ins_r = disasm.decode_instr(0, cur)
            if ins_r.is_unconditional_jump and ins_r.target_addr is not None and ins_r.target_addr < 0x4000 and len(lds) == 0:
                cur = ins_r.target_addr
                continue
            if ins_r.mnemonic.startswith("LD HL, 0x"):
                lds.append(int(ins_r.mnemonic.split(", ")[1], 16))
            cur += max(1, ins_r.length)
        # Look for packed pattern: b0_tbl (<=0x3FFF), ptr_tbl (word table), bank_tbl (4 banks)
        for idx_l in range(len(lds) - 1):
            t_ptr = lds[idx_l]
            t_bk = lds[idx_l + 1]
            if 0x0150 <= t_bk < t_ptr < 0x4000 and t_ptr - t_bk <= 16:
                b0_tbl = 0
                for cand in reversed(lds[:idx_l]):
                    if 0x0150 <= cand < 0x4000 and cand != t_bk and cand != t_ptr and not (cand <= t_bk < cand + 16):
                        words = [disasm.read_u16(0, cand + 2 * s) for s in range(8)]
                        if all(0x0150 <= w < 0x4000 and not disasm.decode_instr(0, w).mnemonic.startswith("DB ") for w in words):
                            b0_tbl = cand
                            break
                packed_rst_info[vec] = (t_bk, t_ptr, b0_tbl)
                if b0_tbl:
                    slots: Set[int] = set()
                    for slot in range(8):
                        h_addr = disasm.read_u16(0, b0_tbl + 2 * slot)
                        if 0x0150 <= h_addr < 0x4000:
                            jp_hl_targets[0].add(h_addr)
                            bank_labels[0].add(h_addr)
                            worklist.append(h_addr)
                            hc = h_addr
                            for _ in range(36):
                                if not (0x0150 <= hc < 0x4000):
                                    break
                                hi2 = disasm.decode_instr(0, hc)
                                if (hi2.is_call or hi2.is_unconditional_jump) and hi2.target_addr is not None and is_inline_table_helper(disasm, hi2.target_addr):
                                    slots.add(slot)
                                    break
                                if hi2.mnemonic.startswith("RST ") and int(hi2.mnemonic[4:], 16) == vec:
                                    hc += 2
                                    continue
                                if hi2.mnemonic in ("RET", "RETI") or hi2.is_unconditional_jump:
                                    break
                                hc += max(1, hi2.length)
                    if slots:
                        inline_8tbl_slots[vec] = slots
                break

    def read_inline_8_ptrs(bank: int, tbl_addr: int) -> List[int]:
        limit = 0x4000 if bank == 0 else 0x8000
        if tbl_addr + 16 > limit:
            return []
        ptrs: List[int] = []
        for i in range(8):
            w = disasm.read_u16(bank, tbl_addr + 2 * i)
            if not (0x0150 <= w < 0x8000):
                return []
            t_bk = 0 if w < 0x4000 else bank
            if disasm.decode_instr(t_bk, w).mnemonic.startswith("DB "):
                return []
            ptrs.append(w)
        return ptrs

    def decode_packed_rst_arg(vec: int, arg: int):
        if vec not in packed_rst_info:
            return
        t_bk, t_ptr, _ = packed_rst_info[vec]
        if not (arg & 0x08):
            # Also seed Bank 0 helper table referenced near t_ptr
            b_sel = (arg >> 4) & 0x0F
            return
        idx = (arg & 0xF0) | ((arg & 7) * 2)
        hl = t_ptr + idx
        if 0x0150 <= hl < 0x4000:
            hi = disasm.read_u8(0, hl)
            lo = disasm.read_u8(0, hl - 1)
            bank = disasm.read_u8(0, t_bk + ((hi & 0xC0) >> 6))
            addr = (((hi & 0x3F) | 0x40) << 8) | lo
            if 1 <= bank < num_banks and 0x4000 <= addr < 0x8000:
                exact_bn_seeds[bank].add(addr)

    call_table_helpers: Set[int] = set()
    checked_call_helpers: Set[int] = set()

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
                if vec in rst_1b_arg_vecs:
                    arg_addr = addr + ins.length
                    if arg_addr < 0x4000:
                        b0_interior.add(arg_addr)
                        arg_byte = disasm.read_u8(0, arg_addr)
                        if vec in inline_8tbl_slots and not (arg_byte & 0x08) and (arg_byte & 7) in inline_8tbl_slots[vec]:
                            ptrs = read_inline_8_ptrs(0, arg_addr + 1)
                            if ptrs:
                                for k in range(1, 17):
                                    b0_interior.add(arg_addr + k)
                                for pt in ptrs:
                                    jp_hl_targets[0].add(pt)
                                    if pt < 0x4000:
                                        bank_labels[0].add(pt)
                                        wl.append(pt)
                                    elif pt < 0x8000:
                                        b0_to_bn_set.add(pt)
                                continue
                        decode_packed_rst_arg(vec, arg_byte)
                        wl.append(arg_addr + 1)
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

            # Detect `LD BC/DE/HL, imm16; PUSH BC/DE/HL` synthetic return-address pushes
            # or `LD BC/DE/HL, imm16; CALL/JP setter_fn` callback pointer registrations.
            if ins.length == 3 and m.startswith(("LD BC, 0x", "LD DE, 0x", "LD HL, 0x")):
                rr = m[3:5]
                imm = int(m.split(", ")[1], 16)
                next_ins = disasm.decode_instr(0, addr + 3)
                if next_ins.mnemonic == f"PUSH {rr}" and 0x0150 <= imm < 0x4000:
                    bank_labels[0].add(imm)
                    wl.append(imm)
                elif ((next_ins.is_call or next_ins.is_unconditional_jump)
                      and next_ins.target_addr is not None
                      and next_ins.target_addr < 0x4000
                      and is_ptr_setter(next_ins.target_addr, rr)):
                    if 0x0150 <= imm < 0x4000:
                        jp_hl_targets[0].add(imm)
                        bank_labels[0].add(imm)
                        wl.append(imm)
                    elif 0x4000 <= imm < 0x8000:
                        jp_hl_targets[0].add(imm)
                        b0_to_bn_set.add(imm)
                    elif imm >= 0xFF80:
                        jp_hl_targets[0].add(imm)
                elif rr == "HL" and 0x0150 <= imm < 0x4000 and disasm.read_u8(0, imm) == 0xC3:
                    # Detect `LD HL, jp_stub; LD DE, ram_vec; CALL copy` (e.g. FFL3 0x1DDE -> 0x1E43 -> JP 0x1EFA)
                    nxt2 = disasm.decode_instr(0, addr + 3)
                    if nxt2.mnemonic.startswith("LD DE, 0x") and nxt2.length == 3:
                        ram_dst = int(nxt2.mnemonic.split(", ")[1], 16)
                        nxt3 = disasm.decode_instr(0, addr + 6)
                        if ram_dst >= 0xC000 and nxt3.is_call:
                            jp_t = disasm.read_u16(0, imm + 1)
                            if 0x0150 <= jp_t < 0x4000:
                                jp_hl_targets[0].add(jp_t)
                                bank_labels[0].add(jp_t)
                                wl.append(jp_t)

            if ins.is_call and ins.target_addr is not None and ins.target_addr < 0x4000:
                ct = ins.target_addr
                if ct not in checked_call_helpers:
                    checked_call_helpers.add(ct)
                    if is_inline_table_helper(disasm, ct):
                        call_table_helpers.add(ct)
                if ct in call_table_helpers:
                    bank_labels[0].add(ct)
                    wl.append(ct)
                    for t in read_inline_jump_table(disasm, 0, addr + ins.length):
                        jp_hl_targets[0].add(t)
                        if t < 0x4000:
                            bank_labels[0].add(t)
                            wl.append(t)
                        elif t < 0x8000:
                            b0_to_bn_set.add(t)
                    continue

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

    # Seed any packed RST 0x18 Bank 0 subtable entries (e.g. FFL3 0x38C4)
    if packed_rst_info:
        for vec in packed_rst_info:
            for a_tbl in range(0x0150, 0x3FF0):
                pass
        # Check Bank 0 short word table referenced just before 0x37EB if present (FFL3 0x38C4)
        for a in sorted(b0_vis):
            ins = disasm.decode_instr(0, a)
            if ins.mnemonic.startswith("LD HL, 0x") and (a + 3) in b0_vis:
                nins = disasm.decode_instr(0, a + 3)
                if nins.mnemonic == "ADD A, L":
                    tbl = int(ins.mnemonic.split(", ")[1], 16)
                    if 0x0150 <= tbl < 0x4000 and tbl not in b0_vis:
                        for w in read_inline_jump_table(disasm, 0, tbl)[:16]:
                            if 0x0150 <= w < 0x4000 and w not in b0_interior:
                                bank_labels[0].add(w)
                                jp_hl_targets[0].add(w)
                                trace_b0_worklist([w])
                        bank_labels[0] -= b0_interior

    # Detect Bank 0 bank-switch setters and farcall trampolines (e.g. PokemonBlue 0x35D6, FFL3 0x38D4)
    bank_setters: Set[int] = set()
    far_callers: Set[int] = set()
    for entry in sorted(bank_labels[0]):
        c = entry
        writes_mbc = False
        jumps_hl_or_ram = False
        for _ in range(28):
            if not (0 <= c < 0x4000):
                break
            ins2 = disasm.decode_instr(0, c)
            m2 = ins2.mnemonic
            if m2.startswith(("LD (0x2", "LD (0x3")) and m2.endswith(", A"):
                writes_mbc = True
            if m2 == "JP (HL)" or (ins2.target_addr is not None and ins2.target_addr >= 0x8000):
                jumps_hl_or_ram = True
            if m2 in ("RET", "RETI") or ins2.is_unconditional_jump:
                break
            c += max(1, ins2.length)
        if writes_mbc:
            if jumps_hl_or_ram:
                far_callers.add(entry)
            else:
                bank_setters.add(entry)
    # Include RSTs whose vector jumps to a bank_setter or far_caller (e.g. FFL3 RST 0x20 / RST 0x30)
    for vec in [0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38]:
        if vec in b0_vis:
            ins_v = disasm.decode_instr(0, vec)
            if ins_v.target_addr in bank_setters:
                bank_setters.add(vec)
            elif ins_v.target_addr in far_callers:
                far_callers.add(vec)
            elif ins_v.mnemonic.startswith("LD (0x2"):
                bank_setters.add(vec)

    # Detect Bank 0 table-jump helpers (e.g. FFA 0x2B70: LD HL, tbl; CALL 0x2B70)
    b0_tbl_jp_helpers: Set[int] = {
        entry for entry in bank_labels[0] if is_b0_tbl_jp_helper(disasm, entry)
    }

    def scan_block_tables(src_bank: int, vis_set: Set[int], lbl_set: Set[int]):
        """
        Scan straight-line blocks in `vis_set` for indirect pointer tables:
          - `LD HL, tbl; ...; CALL b0_tbl_jp_helper`
          - `LD HL/DE/BC, tbl; ...; JP (HL)`
          - `LD HL/DE/BC, tbl; ...; LDI A, (HL); LD H, (HL); LD L, A; ...; PUSH HL; ...; RET`
            (plus fallback `LD HL, default; CP N; JR NC` in the same block)
        """
        sorted_v = sorted(vis_set)
        recent_lds: List[Tuple[str, int, int]] = []  # (reg_pair, imm16, addr)
        recent_cp: int = 0
        saw_tbl_deref = False
        prev_end = -1

        def seed_table(tbl_addr: int, tbl_bank: int, cap: int, via_helper: bool):
            code_addrs = b0_vis if tbl_bank == 0 else None
            entries = read_ptr_table(disasm, tbl_bank, tbl_addr, code_addrs=code_addrs, max_entries=cap)
            min_len = 2 if cap < 128 or via_helper else 3
            if len(entries) < min_len:
                return
            for w in entries:
                if tbl_bank == 0 or w < 0x4000:
                    if w not in b0_interior:
                        jp_hl_targets[0].add(w)
                        bank_labels[0].add(w)
                        bn_to_b0_set.add(w)
                else:
                    exact_bn_seeds[tbl_bank].add(w)
                    jp_hl_targets[tbl_bank].add(w)

        for idx_v, a in enumerate(sorted_v):
            if a in lbl_set or a != prev_end:
                # Preserve only if consecutive flow without label? Safe reset on label/gap except
                # allow `LD HL, fallback; CP N; JR NC, +...` bridging within 32 bytes when table_deref follows
                if a != prev_end:
                    recent_lds = []
                    recent_cp = 0
                    saw_tbl_deref = False
                elif idx_v > 0 and (a - recent_lds[-1][2] if recent_lds else 999) > 32:
                    recent_lds = []
                    recent_cp = 0
                    saw_tbl_deref = False
            ins = disasm.decode_instr(src_bank, a)
            prev_end = a + max(1, ins.length)
            m = ins.mnemonic
            if ins.length == 3 and m.startswith(("LD HL, 0x", "LD DE, 0x", "LD BC, 0x")):
                rr = m[3:5]
                imm = int(m.split(", ")[1], 16)
                recent_lds.append((rr, imm, a))
                if len(recent_lds) > 6:
                    recent_lds.pop(0)
            elif m.startswith("CP A, 0x") and not m.startswith("CP A, ("):
                val = int(m.split(", ")[1], 16)
                if 2 <= val <= 128:
                    recent_cp = val
            elif (m == "LDI A, (HL)"
                  and (a + 1) in vis_set
                  and disasm.decode_instr(src_bank, a + 1).mnemonic == "LD H, (HL)"
                  and (a + 2) in vis_set
                  and disasm.decode_instr(src_bank, a + 2).mnemonic == "LD L, A"):
                saw_tbl_deref = True
            elif ins.is_call and ins.target_addr in b0_tbl_jp_helpers:
                for rr, imm, _pos in reversed(recent_lds):
                    if rr == "HL":
                        cap = recent_cp if recent_cp else 128
                        if src_bank == 0 and 0x0150 <= imm < 0x4000:
                            seed_table(imm, 0, cap, via_helper=True)
                        elif src_bank > 0 and 0x4000 <= imm < 0x8000:
                            seed_table(imm, src_bank, cap, via_helper=True)
                        elif src_bank > 0 and 0x0150 <= imm < 0x4000:
                            seed_table(imm, 0, cap, via_helper=True)
                        break
            elif m == "JP (HL)" and saw_tbl_deref:
                cap = recent_cp if recent_cp else 128
                for rr, imm, _pos in reversed(recent_lds):
                    if src_bank == 0 and 0x0150 <= imm < 0x4000:
                        seed_table(imm, 0, cap, via_helper=False)
                    elif src_bank > 0 and 0x4000 <= imm < 0x8000:
                        seed_table(imm, src_bank, cap, via_helper=False)
                    elif src_bank > 0 and 0x0150 <= imm < 0x4000:
                        seed_table(imm, 0, cap, via_helper=False)
            elif m == "PUSH HL" and saw_tbl_deref:
                # Check if PUSH HL is followed shortly by RET (avoiding synthetic call pushes)
                nxt = a + ins.length
                ends_with_ret = False
                for _ in range(5):
                    if nxt >= (0x4000 if src_bank == 0 else 0x8000):
                        break
                    ni = disasm.decode_instr(src_bank, nxt)
                    if ni.mnemonic in ("RET", "RETI"):
                        ends_with_ret = True
                        break
                    if ni.is_call or ni.is_branch:
                        break
                    nxt += max(1, ni.length)
                if ends_with_ret:
                    cap = recent_cp if recent_cp else 128
                    seeded_any = False
                    for rr, imm, _pos in reversed(recent_lds):
                        if src_bank == 0 and 0x0150 <= imm < 0x4000:
                            prev_n = len(bank_labels[0])
                            seed_table(imm, 0, cap, via_helper=True)
                            if len(bank_labels[0]) > prev_n:
                                seeded_any = True
                            elif seeded_any and rr == "HL" and recent_cp and imm not in b0_interior:
                                # Fallback handler `LD HL, default; CP N; JR NC, push_ret` (e.g. FFL3 00:308C)
                                if not disasm.decode_instr(0, imm).mnemonic.startswith("DB "):
                                    bank_labels[0].add(imm)
                                    bn_to_b0_set.add(imm)
                        elif src_bank > 0 and 0x4000 <= imm < 0x8000:
                            seed_table(imm, src_bank, cap, via_helper=True)
                        elif src_bank > 0 and 0x0150 <= imm < 0x4000:
                            seed_table(imm, 0, cap, via_helper=True)

    scan_block_tables(0, b0_vis, bank_labels[0])
    new_b0_tbl = list(bank_labels[0] - b0_vis)
    if new_b0_tbl:
        trace_b0_worklist(new_b0_tbl)
        bank_labels[0] -= b0_interior

    def harvest_exact_bank_calls(src_bank: int, vis_set: Set[int], lbl_set: Set[int]):
        """Linearly scan straight-line blocks in vis_set for (bank, addr) pairs before
        LD (2xxx), A + CALL 0x4000..0x7FFF or CALL/JP/RST far_caller."""
        sorted_v = sorted(vis_set)
        recent_a = None
        recent_b = None
        recent_hl = None
        active_bk = None
        prev_end = -1
        for a in sorted_v:
            if a in lbl_set or a != prev_end:
                recent_a = None
                recent_b = None
                recent_hl = None
                active_bk = None
            ins = disasm.decode_instr(src_bank, a)
            prev_end = a + max(1, ins.length)
            m = ins.mnemonic
            if m.startswith("LD A, 0x"):
                recent_a = int(m.split(", ")[1], 16)
            elif m == "XOR A, A":
                recent_a = 0
            elif m.startswith("LD B, 0x"):
                recent_b = int(m.split(", ")[1], 16)
            elif m.startswith("LD HL, 0x"):
                recent_hl = int(m.split(", ")[1], 16)
            elif m == "ADD A, A" and (a + 1) in vis_set and recent_hl is not None:
                nins = disasm.decode_instr(src_bank, a + 1)
                if nins.mnemonic in ("ADD A, E", "ADD A, L"):
                    tbl = recent_hl
                    if (src_bank == 0 and 0x0150 <= tbl < 0x4000) or (src_bank > 0 and 0x4000 <= tbl < 0x8000):
                        entries_3b = []
                        cur = tbl
                        limit = 0x4000 if src_bank == 0 else 0x8000
                        while cur + 3 <= limit and len(entries_3b) < 128:
                            bk = disasm.read_u8(src_bank, cur)
                            w = disasm.read_u16(src_bank, cur + 1)
                            if bk >= num_banks or w >= 0x8000 or w < 0x0150:
                                break
                            entries_3b.append((bk, w))
                            cur += 3
                        if len(entries_3b) >= 4:
                            for bk, w in entries_3b:
                                if w < 0x4000:
                                    bn_to_b0_set.add(w)
                                    jp_hl_targets[0].add(w)
                                    bank_labels[0].add(w)
                                elif 1 <= bk < num_banks:
                                    exact_bn_seeds[bk].add(w)
            elif m.startswith(("LD (0x2", "LD (0x3")) and m.endswith(", A") and recent_a is not None:
                active_bk = (recent_a if recent_a != 0 else 1) % num_banks
            elif (ins.is_call or ins.is_branch or m.startswith("RST ")) and ins.target_addr is not None:
                t = ins.target_addr
                if t in bank_setters and recent_a is not None:
                    active_bk = (recent_a if recent_a != 0 else 1) % num_banks
                elif t in far_callers and recent_hl is not None and 0x4000 <= recent_hl < 0x8000:
                    bk = recent_b if recent_b is not None else recent_a
                    if bk is not None and 1 <= (bk % num_banks) < num_banks:
                        exact_bn_seeds[max(1, bk % num_banks)].add(recent_hl)
                elif 0x4000 <= t < 0x8000 and active_bk is not None and 1 <= active_bk < num_banks:
                    exact_bn_seeds[active_bk].add(t)
                if ins.is_unconditional_jump or m in ("RET", "RETI"):
                    active_bk = None

    harvest_exact_bank_calls(0, b0_vis, bank_labels[0])

    # Detect per-bank 0x4000 pointer tables where Bank 0 loads `LD H, 0x40` + `LDI A, (HL)` (e.g. FFA 0x1ED7/1F06/1F35...)
    sorted_b0 = sorted(b0_vis)
    for idx_a, a in enumerate(sorted_b0):
        ins = disasm.decode_instr(0, a)
        if ins.mnemonic == "LD H, 0x40" and (a + 2) in b0_vis:
            if disasm.decode_instr(0, a + 2).mnemonic == "LDI A, (HL)":
                target_bk = 1
                for prev_i in range(idx_a - 1, max(-1, idx_a - 10), -1):
                    pa = sorted_b0[prev_i]
                    if a - pa > 24:
                        break
                    pins = disasm.decode_instr(0, pa)
                    if pins.mnemonic.startswith("LD A, 0x"):
                        target_bk = max(1, int(pins.mnemonic.split(", ")[1], 16) % num_banks)
                        break
                if 1 <= target_bk < num_banks:
                    for w in read_inline_jump_table(disasm, target_bk, 0x4000):
                        if 0x4000 <= w < 0x8000:
                            exact_bn_seeds[target_bk].add(w)

    # 2. Helper to validate and trace a candidate function entry in Bank 1..N-1
    def trace_bank_subgraph(b: int, start_t: int, strict_min_insns: int = 1, speculative: bool = False):
        wl = [start_t]
        vis: Set[int] = set()
        interior: Set[int] = set()
        labels: Set[int] = {start_t}
        b0_refs: Set[int] = set()
        tbl_addrs: Set[int] = set()
        rst_jp_targets: Set[int] = set()
        rst_1b_args: Set[int] = set()
        has_clean_exit = False

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
                b0_refs.add(vec)
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
                if vec in rst_1b_arg_vecs:
                    arg_addr = a + ins.length
                    if arg_addr < 0x8000:
                        interior.add(arg_addr)
                        rst_1b_args.add(arg_addr)
                        arg_byte = disasm.read_u8(b, arg_addr)
                        if vec in inline_8tbl_slots and not (arg_byte & 0x08) and (arg_byte & 7) in inline_8tbl_slots[vec]:
                            ptrs = read_inline_8_ptrs(b, arg_addr + 1)
                            if ptrs:
                                has_clean_exit = True
                                for k in range(1, 17):
                                    interior.add(arg_addr + k)
                                for pt in ptrs:
                                    rst_jp_targets.add(pt)
                                    if 0x4000 <= pt < 0x8000:
                                        labels.add(pt)
                                        wl.append(pt)
                                    elif 0x0150 <= pt < 0x4000 and pt not in b0_interior:
                                        b0_refs.add(pt)
                                        jp_hl_targets[0].add(pt)
                                continue
                        decode_packed_rst_arg(vec, arg_byte)
                        wl.append(arg_addr + 1)
                    continue

            if m == "JP (HL)":
                has_clean_exit = True
                if disasm.read_u8(b, a - 3) == 0xCD and disasm.read_u8(b, a - 6) == 0x21:
                    tbl = disasm.read_u16(b, a - 5)
                    if 0x4000 <= tbl < 0x8000:
                        tbl_addrs.add(tbl)
                continue

            if m in ("RET", "RETI") or m.startswith("RET "):
                has_clean_exit = True

            if ins.target_addr is not None:
                t = ins.target_addr
                if ins.is_call and t < 0x4000:
                    if t not in checked_call_helpers:
                        checked_call_helpers.add(t)
                        if is_inline_table_helper(disasm, t):
                            call_table_helpers.add(t)
                    if t in call_table_helpers:
                        b0_refs.add(t)
                        tbl_targets = read_inline_jump_table(disasm, b, a + ins.length)
                        if not tbl_targets:
                            return None
                        for tt in tbl_targets:
                            rst_jp_targets.add(tt)
                            if 0x4000 <= tt < 0x8000:
                                labels.add(tt)
                                wl.append(tt)
                            elif 0x0150 <= tt < 0x4000 and tt not in b0_interior:
                                b0_refs.add(tt)
                        continue
                if t < 0x4000:
                    if t in b0_interior or (0x0100 <= t < 0x0150) or (t < 0x0040 and t not in (0x0000, 0x0008, 0x0010, 0x0018, 0x0020, 0x0028, 0x0030, 0x0038)):
                        return None
                    b0_refs.add(t)
                elif t < 0x8000:
                    labels.add(t)
                    wl.append(t)
                else:
                    # Reject speculative untyped entrypoints that conditionally branch into RAM (>= 0x8000)
                    if speculative and ins.is_branch and not ins.is_unconditional_jump:
                        return None

            if not ins.is_unconditional_jump and m not in ("RET", "RETI"):
                wl.append(a + ins.length)

        if (labels & interior) or (vis & interior):
            return None
        if len(vis) < strict_min_insns and not has_clean_exit:
            return None
        return vis, interior, labels, b0_refs, tbl_addrs, rst_jp_targets, rst_1b_args

    # 3. Trace Banks 1..N-1 and Bank 0 cross-bank references iteratively to fixed point
    checked_tbl_helpers: Set[int] = set(bank_labels[0])
    max_rounds = 6 if num_banks > 4 else 3
    for _round in range(max_rounds):
        prev_b0_to_bn = len(b0_to_bn_set)
        prev_bn_to_b0 = len(bn_to_b0_set)
        prev_b0_labels = len(bank_labels[0])
        prev_exact = sum(len(exact_bn_seeds[b]) for b in range(1, num_banks))
        for entry in list(bank_labels[0] - checked_tbl_helpers):
            checked_tbl_helpers.add(entry)
            if is_b0_tbl_jp_helper(disasm, entry):
                b0_tbl_jp_helpers.add(entry)
        resolved_untyped: Set[int] = set()
        for bk in range(1, num_banks):
            resolved_untyped |= exact_bn_seeds[bk]

        for b in range(1, num_banks):
            b_interior: Set[int] = set()
            b_vis: Set[int] = set()
            pending_tables: Set[int] = set()

            exact_cands = set(exact_bn_seeds[b]) | {t for t in jp_hl_targets[b] if 0x4000 <= t < 0x8000}
            if num_banks <= 4:
                exact_cands |= b0_to_bn_set
            if extra_bn_seeds and b in extra_bn_seeds:
                exact_cands |= extra_bn_seeds[b]

            # Pass 1: Trace exact/known entrypoints first so they are never clobbered
            for t in sorted(exact_cands):
                if t in b_interior:
                    continue
                res = trace_bank_subgraph(b, t, strict_min_insns=1, speculative=False)
                if res is not None:
                    vis, interior, labels, b0_refs, tbl_addrs, rst_jp_targets, _ = res
                    bank_labels[b].add(t)
                    b_vis |= vis
                    b_interior |= interior
                    bank_labels[b] |= labels
                    pending_tables |= tbl_addrs
                    jp_hl_targets[b] |= rst_jp_targets
                    for r in b0_refs:
                        bn_to_b0_set.add(r)
                        bank_labels[0].add(r)

            # Trace validated JP (HL) table entries in Bank b transitively
            seen_tables: Set[int] = set()
            while pending_tables:
                tbl = min(pending_tables)
                pending_tables.remove(tbl)
                if tbl in seen_tables:
                    continue
                seen_tables.add(tbl)
                for i in range(64):
                    w = disasm.read_u16(b, tbl + i * 2)
                    if not (0x4000 <= w < 0x8000):
                        break
                    res = trace_bank_subgraph(b, w)
                    if res is not None:
                        vis, interior, labels, b0_refs, more_tbls, rst_jp_targets, _ = res
                        b_vis |= vis
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
            bank_vis[b] |= (b_vis - b_interior)

            # Pass 2 (OVL_MODE): Speculative untyped targets must never overlap known code or labels
            if num_banks > 4:
                spec_cands = (b0_to_bn_set - resolved_untyped) - exact_cands
                for t in sorted(spec_cands):
                    if t in b_interior or t in bank_vis[b] or t in bank_labels[b]:
                        continue
                    res = trace_bank_subgraph(b, t, strict_min_insns=2, speculative=True)
                    if res is not None:
                        vis, interior, labels, b0_refs, tbl_addrs, rst_jp_targets, _ = res
                        if (interior & bank_labels[b]) or (interior & bank_vis[b]) or (vis & b_interior):
                            continue
                        bank_labels[b].add(t)
                        b_vis |= vis
                        b_interior |= interior
                        bank_labels[b] |= labels
                        bank_vis[b] |= (vis - b_interior)
                        jp_hl_targets[b] |= rst_jp_targets
                        for r in b0_refs:
                            bn_to_b0_set.add(r)
                            bank_labels[0].add(r)

            if bank_vis[b]:
                harvest_exact_bank_calls(b, bank_vis[b], bank_labels[b])
                scan_block_tables(b, bank_vis[b], bank_labels[b])

        # 4. Trace any newly discovered bn_to_b0 entry points in Bank 0
        new_b0 = list((bn_to_b0_set | bank_labels[0]) - b0_vis)
        if new_b0:
            trace_b0_worklist(new_b0)
            bank_labels[0] -= b0_interior
            for entry in list(bank_labels[0] - checked_tbl_helpers):
                checked_tbl_helpers.add(entry)
                if is_b0_tbl_jp_helper(disasm, entry):
                    b0_tbl_jp_helpers.add(entry)
            harvest_exact_bank_calls(0, b0_vis, bank_labels[0])
            scan_block_tables(0, b0_vis, bank_labels[0])

        cur_exact = sum(len(exact_bn_seeds[b]) for b in range(1, num_banks))
        if (len(b0_to_bn_set) == prev_b0_to_bn and len(bn_to_b0_set) == prev_bn_to_b0
                and len(bank_labels[0]) == prev_b0_labels and cur_exact == prev_exact):
            break

    bank_vis[0] = b0_vis - b0_interior
    return bank_labels, bank_vis, jp_hl_targets, b0_to_bn_set, bn_to_b0_set, exact_bn_seeds


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

    # Pad 32 KiB ROMs to 64 KiB so <= 64 KiB ROMs keep the 4-segment layout
    if len(rom_bytes) < 0x10000:
        rom_bytes = rom_bytes + b'\xFF' * (0x10000 - len(rom_bytes))

    num_banks = len(rom_bytes) // 0x4000
    if len(rom_bytes) % 0x4000 != 0:
        num_banks += 1
        rom_bytes = rom_bytes + b'\xFF' * (num_banks * 0x4000 - len(rom_bytes))
    ovl_mode = (num_banks > 4)

    cart_type = rom_bytes[0x0147]
    if cart_type == 0x00:
        mapper_type = 0
    elif cart_type in (0x01, 0x02, 0x03):
        mapper_type = 1
    elif cart_type in (0x05, 0x06):
        mapper_type = 2
    elif cart_type in (0x0F, 0x10, 0x11, 0x12, 0x13):
        mapper_type = 3
    else:
        mapper_type = 3

    ram_code = rom_bytes[0x0149]
    sram_banks = {3: 4, 4: 16, 5: 8}.get(ram_code, 0)
    sram_paras = sram_banks * 0x0200
    sram_bank_mask = max(0, sram_banks - 1)
    rom_bank_mask = min(0xFF, num_banks - 1)

    print(f"[gb200lx] Loaded ROM: {rom_path} ({len(rom_bytes)} bytes, {num_banks} banks, mapper={mapper_type}, sram={sram_banks * 8} KiB)")

    disasm = SM83Disassembler(rom_bytes)

    # 1. Detect inline RST dispatchers, HRAM DMA, optional .sym/.cdl seeds, & run control-flow discovery
    extra_b0_seeds: Set[int] = set()
    extra_bn_seeds: Dict[int, Set[int]] = {b: set() for b in range(1, num_banks)}

    rom_stem = os.path.splitext(rom_path)[0]
    sym_path = args.sym or (rom_stem + ".sym" if os.path.exists(rom_stem + ".sym") else None)
    cdl_path = args.cdl or (rom_stem + ".cdl" if os.path.exists(rom_stem + ".cdl") else None)

    if sym_path and os.path.exists(sym_path):
        s_b0, s_bn = load_sym_seeds(sym_path, num_banks)
        extra_b0_seeds |= s_b0
        for bk in range(1, num_banks):
            extra_bn_seeds[bk] |= s_bn[bk]
        print(f"[gb200lx] Loaded .sym seeds from {sym_path}: B0={len(s_b0)}, BN={sum(len(s_bn[k]) for k in range(1, num_banks))}")

    if cdl_path and os.path.exists(cdl_path):
        c_b0, c_bn = load_cdl_seeds(cdl_path, len(rom_bytes))
        extra_b0_seeds |= c_b0
        for bk in range(1, num_banks):
            extra_bn_seeds[bk] |= c_bn[bk]
        print(f"[gb200lx] Loaded .cdl seeds from {cdl_path}: B0={len(c_b0)}, BN={sum(len(c_bn[k]) for k in range(1, num_banks))}")

    rst_table_vecs, pop_jp_hl_addrs, rst_1b_arg_vecs = detect_rst_table_dispatchers(disasm)
    hram_dma_addr = detect_hram_dma_routine(disasm)
    print(f"[gb200lx] Detected inline jump-table RST vectors: {[hex(v) for v in sorted(rst_table_vecs)]}")
    if rst_1b_arg_vecs:
        print(f"[gb200lx] Detected 1-byte inline-arg RST vectors: {[hex(v) for v in sorted(rst_1b_arg_vecs)]}")
    print(f"[gb200lx] Detected HRAM OAM DMA source routine at: 0x{hram_dma_addr:04x}")

    bank_labels, bank_vis, jp_hl_targets, b0_to_bn_set, bn_to_b0_set, exact_bn_seeds = discover_control_flow(
        disasm, rst_table_vecs, rst_1b_arg_vecs, hram_dma_addr, num_banks, extra_b0_seeds, extra_bn_seeds
    )

    b0_to_bn = sorted(list(b0_to_bn_set))
    b0_to_bn_idx = {t: i for i, t in enumerate(b0_to_bn)}

    bn_to_b0 = sorted(t for t in bn_to_b0_set if t in bank_labels[0])
    bn_to_b0_idx = {t: i for i, t in enumerate(bn_to_b0)}

    def can_unwind_func(bk: int, start: int) -> bool:
        """Return True if a subroutine can POP caller stack frames (SP net > 0) without LD SP, HL."""
        lo = 0 if bk == 0 else 0x4000
        hi = 0x4000 if bk == 0 else 0x8000
        seen: Dict[int, int] = {}
        stk = [(start, 0)]
        steps = 0
        while stk and steps < 250:
            addr, bal = stk.pop()
            steps += 1
            if addr in seen and seen[addr] >= bal:
                continue
            seen[addr] = bal
            if not (lo <= addr < hi):
                continue
            ins = disasm.decode_instr(bk, addr)
            m = ins.mnemonic
            if m.startswith("DB ") or m in ("RET", "RETI", "LD SP, HL"):
                continue
            if m.startswith("PUSH "):
                bal -= 2
            elif m.startswith("POP "):
                bal += 2
                if bal > 0:
                    return True
            elif ins.is_unconditional_jump:
                if ins.target_addr is not None:
                    stk.append((ins.target_addr, bal))
                continue
            elif ins.is_branch and ins.target_addr is not None:
                stk.append((ins.target_addr, bal))
            stk.append((addr + ins.length, bal))
        return False

    call_targets_seen: Set[Tuple[int, int]] = set()
    for b in range(num_banks):
        for a in bank_vis[b]:
            ins = disasm.decode_instr(b, a)
            if ins.is_call and ins.target_addr is not None and ins.target_addr < 0x8000:
                t_bk = 0 if ins.target_addr < 0x4000 else b
                call_targets_seen.add((t_bk, ins.target_addr))
    unwinding_funcs: Set[Tuple[int, int]] = {
        (tb, ta) for (tb, ta) in call_targets_seen if can_unwind_func(tb, ta)
    }

    def emit_di_guard(out_lines: List[str], tag: str, unwind_jcc: str, cont_insn: Optional[str]) -> None:
        """Emit compact post-call DI stack-unwind check preserving AX, BP, and FLAGS."""
        helper = "helper_di_chk_ne" if unwind_jcc == "jne" else "helper_di_chk_gt"
        out_lines.append(f"    call near {helper}")
        if cont_insn:
            out_lines.append(f"    {cont_insn}")

    # Detect `PUSH rr; ...; RET/RETI` computed jumps across reachable blocks in each bank
    push_ret_addrs: Dict[int, Set[int]] = {b: set() for b in range(num_banks)}
    for b in range(num_banks):
        lbl_b = bank_labels[b]
        push_stack: List[str] = []
        prev_end = -1
        for a in sorted(bank_vis[b]):
            if a in lbl_b or a != prev_end:
                push_stack = []
            ins = disasm.decode_instr(b, a)
            prev_end = a + max(1, ins.length)
            m = ins.mnemonic
            if m in ("PUSH HL", "PUSH DE", "PUSH BC", "PUSH AF"):
                # Skip synthetic return-address pushes (`LD rr, imm16; PUSH rr` where next ins is normal)
                if a >= 3:
                    p3 = disasm.decode_instr(b, a - 3)
                    rr = m[5:]
                    if p3.length == 3 and p3.mnemonic.startswith(f"LD {rr}, 0x"):
                        imm = int(p3.mnemonic.split(", ")[1], 16)
                        if imm in lbl_b:
                            continue
                push_stack.append(m)
            elif m.startswith("POP "):
                if push_stack:
                    push_stack.pop()
            elif m in ("RET", "RETI"):
                if push_stack and push_stack[-1] in ("PUSH HL", "PUSH DE", "PUSH BC"):
                    push_ret_addrs[b].add(a)
                push_stack = []
            elif ins.is_call or ins.is_unconditional_jump or m.startswith("RST "):
                push_stack = []

    print(f"[gb200lx] Cross-bank entry points: B0->BN untyped={len(b0_to_bn)}, exact={sum(len(exact_bn_seeds[b]) for b in range(1, num_banks))}, BN->B0={len(bn_to_b0)}")
    if not ovl_mode:
        for b in range(4):
            print(f"[gb200lx] Bank {b} JP (HL) targets: {len(jp_hl_targets[b])}")

    # 2. Generate Bank Jump Tables & Dispatches
    helper_names = [
        "helper_write_mbc",
        "helper_write_mmio",
        "helper_read_joyp",
        "helper_read_div",
        "helper_read_ly",
        "helper_update_bgp",
        "helper_halt",
        "helper_mark_tile_dirty",
        "helper_read_stat",
    ]
    if ovl_mode:
        helper_names.append("helper_dispatch_any_bp")

    b0_helper_lines = [
        "bits 16", "cpu 186", "",
        "; Fixed-offset far-callable runtime helper bridges at 0004h..",
        "global b0_helper_table",
        "b0_helper_table:",
    ]
    for hname in helper_names:
        b0_helper_lines.append(f"    call near {hname}")
        b0_helper_lines.append("    retf")
    if ovl_mode:
        # Fixed offset 002Ch (= 4 + 10*4): segment base of active 0x4000..0x7FFF ROM data bank (-0x0400 paras)
        b0_helper_lines.append("global rom_bank_seg")
        b0_helper_lines.append("rom_bank_seg:")
        b0_helper_lines.append("    dw 0")
    b0_entry_off = 4 + len(helper_names) * 4 + (2 if ovl_mode else 0)

    disp_b0_lines = list(b0_helper_lines) + [
        "",
        f"; Table of wrappers in Bank 0 called from Banks 1..N (starts at exact offset {b0_entry_off})",
        "global b0_entry_table",
        "b0_entry_table:",
    ]
    for t in bn_to_b0:
        disp_b0_lines.append(f"    call near loc_00_{t:04x}")
        disp_b0_lines.append("    retf")

    if ovl_mode:
        b0_all_jp = sorted(
            set(bn_to_b0)
            | {t for t in jp_hl_targets[0] if t < 0x4000 and t in bank_labels[0]}
            | {t for t in bank_labels[0] if 0x0040 <= t < 0x4000}
        )
        disp_b0_lines.extend([
            "",
            "; Runtime Bank 0 target dispatcher (used by RAM/computed jumps < 0x4000)",
            "global ovl_dispatch_b0_bp",
            "ovl_dispatch_b0_bp:",
        ])
        if b0_all_jp:
            disp_b0_lines.extend([
                "    sub     sp, 2",
                "    pushf",
                "    push    ax",
                "    push    bx",
                "    push    cx",
                "    push    si",
                "    xor     bx, bx",
                f"    mov     cx, {len(b0_all_jp) - 1}",
                ".b0_bs:",
                "    cmp     bx, cx",
                "    ja      short .b0_miss",
                "    mov     ax, bx",
                "    add     ax, cx",
                "    shr     ax, 1",
                "    mov     si, ax",
                "    shl     si, 1",
                "    cmp     [cs:b0_disp_gb + si], bp",
                "    je      short .b0_hit",
                "    jb      short .b0_right",
                "    or      ax, ax",
                "    jz      short .b0_miss",
                "    dec     ax",
                "    mov     cx, ax",
                "    jmp     short .b0_bs",
                ".b0_right:",
                "    inc     ax",
                "    mov     bx, ax",
                "    jmp     short .b0_bs",
                ".b0_hit:",
                "    mov     ax, [cs:b0_disp_off + si]",
                "    mov     si, sp",
                "    mov     [ss:si + 10], ax",
                "    pop     si",
                "    pop     cx",
                "    pop     bx",
                "    pop     ax",
                "    popf",
                "    ret",
                ".b0_miss:",
                "    pop     si",
                "    pop     cx",
                "    pop     bx",
                "    pop     ax",
                "    popf",
                "    add     sp, 2",
                "    lea     di, [di + 2]",
                "    ret",
                "b0_disp_gb:",
            ])
            for t in b0_all_jp:
                disp_b0_lines.append(f"    dw 0{t:04X}h")
            disp_b0_lines.append("b0_disp_off:")
            for t in b0_all_jp:
                disp_b0_lines.append(f"    dw loc_00_{t:04x}")
        else:
            disp_b0_lines.extend(["    lea di, [di + 2]", "    ret"])

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
        if t < 0x4000:
            if t in bank_labels[0]:
                disp_b0_lines.append(f"    cmp cx, 0{t:04X}h")
                disp_b0_lines.append(f"    je  near loc_00_{t:04x}")
        elif not ovl_mode:
            disp_b0_lines.append(f"    cmp cx, 0{t:04X}h")
            if t >= 0xFF80:
                disp_b0_lines.append(f"    je  near loc_00_{hram_dma_addr:04x}")
            else:
                disp_b0_lines.append(f"    je  near dispatch_call_{t:04x}")
    if ovl_mode:
        disp_b0_lines.extend([
            "    cmp cx, 04000h",
            "    jb  short .jp_b0_miss",
            "    mov bp, cx",
            "    cmp cx, 08000h",
            "    jae near helper_dispatch_ram_bp",
            "    jmp near ovl_call_bp",
            ".jp_b0_miss:",
        ])
    else:
        if 0xFF80 not in jp_hl_targets[0]:
            disp_b0_lines.append("    cmp cx, 0FF80h")
            disp_b0_lines.append(f"    je  near loc_00_{hram_dma_addr:04x}")
    disp_b0_lines.extend([
        "    lea di, [di + 2]",
        "    ret",
    ])
    disp_b0_lines.append("")

    if not ovl_mode:
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
    else:
        # In OVL_MODE, ovl_dir (filled after banks 1..N-1 assemble) lives in dispatch_b0_ovl.asm
        disp_b0_lines.append("%include \"" + OUT_DIR + "/ovl_dir.asm\"")

    with open(f"{OUT_DIR}/dispatch_b0.asm", "w") as f:
        f.write("\n".join(disp_b0_lines) + "\n")

    # Determine per-bank entry tables for Banks 1..N-1
    bank_entries: Dict[int, List[int]] = {}
    b0_jp_hi = {t for t in jp_hl_targets[0] if 0x4000 <= t < 0x8000}
    for b in range(1, num_banks):
        if not ovl_mode:
            bank_entries[b] = b0_to_bn
        else:
            cand = (exact_bn_seeds[b] | b0_to_bn_set | b0_jp_hi |
                    {t for t in jp_hl_targets[b] if 0x4000 <= t < 0x8000} |
                    (extra_bn_seeds[b] if b in extra_bn_seeds else set()))
            bank_entries[b] = sorted(t for t in cand if 0x4000 <= t < 0x8000 and t in bank_labels[b])

    # Banks 1..N-1: Jump table
    for b in range(1, num_banks):
        entries_b = bank_entries[b]
        disp_bn_lines = ["bits 16", "cpu 186", ""]
        if ovl_mode:
            disp_bn_lines.extend([
                f"; Bank {b} Overlay Header (+00 seg0_base, +02 count, +04 sorted GB addrs)",
                "ovl_seg0_base:  dw 0",
                f"ovl_entry_cnt:  dw {len(entries_b)}",
                "ovl_gb_addrs:",
            ])
            for t in entries_b:
                disp_bn_lines.append(f"    dw 0{t:04X}h")
            disp_bn_lines.append("")
        disp_bn_lines.extend([
            f"; Bank {b} Entry Jump Table",
            f"global b{b}_entry_table",
            f"b{b}_entry_table:",
        ])
        for t in entries_b:
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

        disp_bn_lines.append(f"\n; Far call helpers for calling Bank 0 (b0_entry_table starts at offset {b0_entry_off})")
        for t in bn_to_b0:
            idx = bn_to_b0_idx[t]
            disp_bn_lines.append(f"global call_bank0_{t:04x}")
            disp_bn_lines.append(f"call_bank0_{t:04x}:")
            disp_bn_lines.append("    push bp")
            if ovl_mode:
                disp_bn_lines.append("    mov bp, [cs:0000h]")
            else:
                disp_bn_lines.append("    mov bp, cs")
                disp_bn_lines.append("    sub bp, SEG_PARAS_VAL")
            disp_bn_lines.append("    push bp")
            disp_bn_lines.append(f"    push word ({b0_entry_off} + {idx * 4})")
            disp_bn_lines.append("    mov bp, sp")
            disp_bn_lines.append("    call far [bp]")
            disp_bn_lines.append("    pop bp")
            disp_bn_lines.append("    pop bp")
            disp_bn_lines.append("    pop bp")
            disp_bn_lines.append("    ret")

        with open(f"{OUT_DIR}/dispatch_b{b}.asm", "w") as f:
            f.write("\n".join(disp_bn_lines) + "\n")

    # 3. Emit Recompiled Code for Bank 0..N-1
    for b in range(num_banks):
        start_addr = 0x0000 if b == 0 else 0x4000
        end_addr = 0x4000 if b == 0 else 0x8000
        cg = CodeGenerator80186(disasm, ovl_mode=ovl_mode)

        for l_addr in bank_labels[b]:
            cg.labels.add((b, l_addr))

        all_lbl_addrs = sorted(addr for (bk, addr) in cg.labels if bk == b and start_addr <= addr < end_addr)
        lbl_set = set(all_lbl_addrs)

        lines = [
            f"; Bank {b:02X} Recompiled Code",
            "bits 16", "cpu 186", "",
        ]

        # In OVL_MODE, emit only discovered reachable basic blocks (keeps Seg 0 & code slots compact!).
        # In standalone <= 4-bank mode, keep linear sweep so existing 32-64 KiB ROMs stay untouched.
        emit_addrs = sorted(bank_vis[b]) if ovl_mode else None
        emit_idx = 0
        curr = start_addr

        while (emit_idx < len(emit_addrs)) if ovl_mode else (curr < end_addr):
            if ovl_mode:
                curr = emit_addrs[emit_idx]
                emit_idx += 1

            if curr in lbl_set:
                lbl = cg.label_name(b, curr)
                lines.append(f"global {lbl}")
                lines.append(f"{lbl}:")

            instr = disasm.decode_instr(b, curr)
            next_c = curr + max(1, instr.length)

            # Synchronize if linear sweep steps over a label (or in OVL_MODE skip interior check)
            if not ovl_mode:
                stepped_over = None
                for k in range(curr + 1, next_c):
                    if k in lbl_set:
                        stepped_over = k
                        break
                if stepped_over is not None:
                    for k in range(curr, stepped_over):
                        bval = disasm.read_u8(b, k)
                        lines.append(f"    db 0{bval:02X}h")
                    curr = stepped_over
                    continue

            # Special handling for JP (HL) inside an inline RST jump-table dispatcher
            if b == 0 and curr in pop_jp_hl_addrs and instr.mnemonic == "JP (HL)":
                lines.append("    add sp, 2")
                lines.append("    mov si, cx")
                lines.append("    jmp near helper_dispatch_jp_hl")
                curr = next_c
                continue

            # 1-byte inline-arg RST call (e.g. FFL3 RST 0x18; db arg)
            if instr.mnemonic.startswith("RST ") and int(instr.mnemonic[4:], 16) in rst_1b_arg_vecs:
                vec = int(instr.mnemonic[4:], 16)
                arg_byte = disasm.read_u8(b, next_c)
                lbl_after = f".after_r1b_{curr:04x}"
                lines.append("    lea di, [di - 2]")
                lines.append(f"    mov word [di], 0{next_c:04X}h")
                if b > 0 and vec in bn_to_b0_idx:
                    lines.append(f"    call near call_bank0_{vec:04x}")
                else:
                    lines.append(f"    call near {cg.label_name(0, vec)}")
                lines.append(f"    jmp short {lbl_after}")
                lines.append(f"    db 0{arg_byte:02X}h")
                lines.append(f"{lbl_after}:")
                curr = next_c + 1
                continue

            # Computed jump via `PUSH rr; ...; RET / RETI`
            if curr in push_ret_addrs[b]:
                if instr.mnemonic == "RETI":
                    lines.append("    mov byte [cs:gb_ime], 1")
                lines.append("    mov bp, [di]")
                lines.append("    lea di, [di + 2]")
                if ovl_mode:
                    lines.append("    jmp near helper_dispatch_any_bp")
                else:
                    lines.append("    mov cx, bp")
                    lines.append("    mov si, cx")
                    lines.append("    jmp near helper_dispatch_jp_hl")
                curr = next_c
                continue

            # Synthetic return-address push: `LD BC/DE/HL, imm16; PUSH BC/DE/HL`
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
                    lines.append("    push di")
                    lines.append(f"    call near {lbl_cont}")
                    emit_di_guard(lines, f"pr_{curr:04x}", "jne", f"jmp near {cg.label_name(b, imm)}")
                    lines.append(f"{lbl_cont}:")
                    if ovl_mode:
                        # Skip PUSH rr inside emit_addrs since we consumed both instructions
                        while emit_idx < len(emit_addrs) and emit_addrs[emit_idx] < curr + 4:
                            emit_idx += 1
                    curr = curr + 4
                    continue

            # Inline RST jump-table call
            if instr.mnemonic.startswith("RST ") and int(instr.mnemonic[4:], 16) in rst_table_vecs:
                lines.append(f"    mov cx, 0{next_c:04X}h")
                lines.append("    add al, al")
                lines.append("    mov dl, al")
                lines.append("    mov dh, 000h")
                lines.append("    add cx, dx")
                lines.append("    mov si, cx")
                if ovl_mode and next_c >= 0x4000:
                    lines.append("    mov es, [cs:0000h]")
                    lines.append("    mov es, [es:002Ch]")
                    lines.append("    mov dl, [es:si]")
                    lines.append("    inc cx")
                    lines.append("    mov si, cx")
                    lines.append("    mov dh, [es:si]")
                else:
                    lines.append("    mov dl, [si]")
                    lines.append("    inc cx")
                    lines.append("    mov si, cx")
                    lines.append("    mov dh, [si]")
                lines.append("    mov cx, dx")
                lines.append("    mov si, cx")
                lines.append("    jmp near helper_dispatch_jp_hl")
                curr = next_c
                continue

            # Generic interrupt-driven spin-loop yield
            if instr.mnemonic.startswith(("JR Z, ", "JR NZ, ")) and instr.target_addr is not None and 0 < curr - instr.target_addr <= 24:
                t_spin = instr.target_addr
                is_spin = False
                if instr.mnemonic.startswith("JR Z, ") and curr - 4 <= t_spin <= curr - 3:
                    i0 = disasm.decode_instr(b, t_spin)
                    i1 = disasm.decode_instr(b, t_spin + i0.length)
                    if (t_spin + i0.length + i1.length == curr
                            and (i0.mnemonic.startswith("LDH A, (0x") or i0.mnemonic.startswith("LD A, (0xC") or i0.mnemonic.startswith("LD A, (0xD"))
                            and i1.mnemonic in ("AND A, A", "OR A, A")):
                        is_spin = True
                if not is_spin:
                    # Pure WRAM/HRAM polling loop (no stores, calls, counters, or MMIO reads)
                    p_sp = t_spin
                    body_insns = []
                    while p_sp < curr:
                        ins_sp = disasm.decode_instr(b, p_sp)
                        body_insns.append(ins_sp)
                        p_sp += max(1, ins_sp.length)
                    if p_sp == curr and body_insns:
                        hl_fixed = False
                        has_ram_rd = False
                        ok_sp = True
                        for ins_sp in body_insns:
                            ms = ins_sp.mnemonic
                            if ins_sp.is_call or ins_sp.is_branch or ms.startswith(("PUSH ", "POP ", "RST ", "DEC ", "INC B", "INC C", "INC D", "INC E")):
                                ok_sp = False
                                break
                            if ms.startswith("LD HL, 0x"):
                                imm_hl = int(ms.split(", ")[1], 16)
                                if not (0xC000 <= imm_hl < 0xFE00 or 0xFF80 <= imm_hl <= 0xFFFE):
                                    ok_sp = False
                                    break
                                hl_fixed = True
                            elif ms in ("INC HL", "DEC HL"):
                                if not hl_fixed:
                                    ok_sp = False
                                    break
                            elif ms in ("XOR A, A", "AND A, A", "OR A, A") or ms.startswith(("CP A, 0x", "BIT ")):
                                if "(HL)" in ms:
                                    if not hl_fixed:
                                        ok_sp = False
                                        break
                                    has_ram_rd = True
                            elif ms in ("OR A, (HL)", "AND A, (HL)", "LD A, (HL)"):
                                if not hl_fixed:
                                    ok_sp = False
                                    break
                                has_ram_rd = True
                            elif ms.startswith("LDH A, (0x"):
                                if int(ms.split("(0x")[1].split(")")[0], 16) < 0x80:
                                    ok_sp = False
                                    break
                                has_ram_rd = True
                            elif ms.startswith("LD A, (0x"):
                                a_rd = int(ms.split("(0x")[1].split(")")[0], 16)
                                if not (0xC000 <= a_rd < 0xFE00 or 0xFF80 <= a_rd <= 0xFFFE):
                                    ok_sp = False
                                    break
                                has_ram_rd = True
                            else:
                                ok_sp = False
                                break
                        is_spin = ok_sp and has_ram_rd
                if is_spin:
                    cg.labels.add((b, t_spin))
                    lbl_done = f".spin_exit_{curr:04x}"
                    neg_spin = "jnz" if instr.mnemonic.startswith("JR Z, ") else "jz"
                    lines.append(f"    {neg_spin} short {lbl_done}")
                    lines.append("    call helper_halt")
                    lines.append(f"    jmp near {cg.label_name(b, t_spin)}")
                    lines.append(f"{lbl_done}:")
                    curr = next_c
                    continue

            # Route cross-bank and RAM CALL / JP
            if (instr.is_call or instr.is_branch) and instr.target_addr is not None:
                t = instr.target_addr
                m = instr.mnemonic
                next_addr = f"0{next_c:04X}h"

                cross_call_lines = None
                if b == 0 and t >= 0x4000:
                    if t >= 0x8000:
                        if ovl_mode:
                            cross_call_lines = [f"mov bp, 0{t:04X}h", "call near helper_dispatch_ram_bp"]
                        elif t >= 0xFF80:
                            cross_call_lines = [f"call near loc_00_{hram_dma_addr:04x}"]
                        else:
                            curr = next_c
                            continue
                    elif ovl_mode:
                        cross_call_lines = [f"mov bp, 0{t:04X}h", "call near ovl_call_bp"]
                    elif t in b0_to_bn_idx:
                        cross_call_lines = [f"call near dispatch_call_{t:04x}"]
                    else:
                        curr = next_c
                        continue
                elif b > 0 and t < 0x4000:
                    if t in bn_to_b0_idx:
                        cross_call_lines = [f"call near call_bank0_{t:04x}"]
                    else:
                        curr = next_c
                        continue
                elif b > 0 and t >= 0x8000:
                    if ovl_mode:
                        cross_call_lines = [f"mov bp, 0{t:04X}h", "call near helper_dispatch_any_bp"]
                    else:
                        curr = next_c
                        continue

                if cross_call_lines is not None:
                    parts = m.split(None, 1)[1].split(", ")
                    is_cond = len(parts) > 1
                    cond = parts[0] if is_cond else None
                    neg_jcc = {"Z": "jnz", "NZ": "jz", "C": "jnc", "NC": "jc"}.get(cond, "jmp")

                    if instr.is_call:
                        t_bk = 0 if t < 0x4000 else b
                        use_guard = (t_bk, t) in unwinding_funcs
                        if is_cond:
                            lbl_skip = f".skip_cc_{curr:04x}"
                            jmp_sz = "near" if use_guard else "short"
                            lines.append(f"    {neg_jcc} {jmp_sz} {lbl_skip}")
                            lines.append("    lea di, [di - 2]")
                            lines.append(f"    mov word [di], {next_addr}")
                            if use_guard:
                                lines.append("    push di")
                            for cl in cross_call_lines:
                                lines.append(f"    {cl}")
                            if use_guard:
                                emit_di_guard(lines, f"uw_{curr:04x}", "ja", None)
                            lines.append(f"{lbl_skip}:")
                        else:
                            lines.append("    lea di, [di - 2]")
                            lines.append(f"    mov word [di], {next_addr}")
                            if use_guard:
                                lines.append("    push di")
                            for cl in cross_call_lines:
                                lines.append(f"    {cl}")
                            if use_guard:
                                emit_di_guard(lines, f"uw_{curr:04x}", "ja", None)
                    else:
                        if is_cond:
                            lbl_skip = f".skip_cj_{curr:04x}"
                            lines.append(f"    {neg_jcc} short {lbl_skip}")
                            for cl in cross_call_lines:
                                lines.append(f"    {cl}")
                            lines.append("    ret")
                            lines.append(f"{lbl_skip}:")
                        else:
                            for cl in cross_call_lines:
                                lines.append(f"    {cl}")
                            lines.append("    ret")
                    curr = next_c
                    continue

                if instr.is_call and (0 if t < 0x4000 else b, t) in unwinding_funcs:
                    t_bk = 0 if t < 0x4000 else b
                    cg.labels.add((t_bk, t))
                    parts = m.split(None, 1)[1].split(", ")
                    is_cond = len(parts) > 1
                    cond = parts[0] if is_cond else None
                    neg_jcc = {"Z": "jnz", "NZ": "jz", "C": "jnc", "NC": "jc"}.get(cond, "jmp")
                    lbl_skip = f".skip_cuw_{curr:04x}"
                    if is_cond:
                        lines.append(f"    {neg_jcc} near {lbl_skip}")
                    lines.append("    lea di, [di - 2]")
                    lines.append(f"    mov word [di], {next_addr}")
                    lines.append("    push di")
                    lines.append(f"    call near {cg.label_name(b, t)}")
                    emit_di_guard(lines, f"uw_{curr:04x}", "ja", None)
                    if is_cond:
                        lines.append(f"{lbl_skip}:")
                    curr = next_c
                    continue

            cg.flags_dead = flags_dead_after(disasm, b, next_c, end_addr, lbl_set)
            cg.inline_writes = False
            x86_ops = cg.translate_instruction(instr)
            if x86_ops:
                lines.append(f"    {x86_ops[0]}")
                for extra in x86_ops[1:]:
                    lines.append(f"    {extra}")

            curr = next_c

        with open(f"{OUT_DIR}/code_b{b}.asm", "w") as f:
            f.write("\n".join(lines) + "\n")
        if not ovl_mode or b == 0 or len(bank_vis[b]) > 0:
            print(f"[gb200lx] Emitted code for Bank {b} ({len(bank_vis[b])} reachable insns)")

    # 4. Generate Stubs for Any Remaining Unresolved Internal Branch Targets
    for b in range(num_banks):
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
        if not ovl_mode or b == 0 or len(defined) > 0:
            print(f"[gb200lx] Bank {b}: {len(defined)} defined, {len(missing)} stubs")

    def pad16(data: bytes) -> bytes:
        rem = len(data) % 16
        return data + (b'\x00' * (16 - rem) if rem != 0 else b'')

    bin_path = f"{BUILD_DIR}/{bin_name}"
    exe_path = f"{BUILD_DIR}/{exe_name}"

    if not ovl_mode:
        # --- STANDALONE MODE (<= 4 banks / <= 64 KiB) ---
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

        seg0_header_pass2 = seg0_header.replace("01111h", f"0{seg1_paras:04X}h") \
                                       .replace("02222h", f"0{seg2_paras:04X}h") \
                                       .replace("03333h", f"0{seg3_paras:04X}h") \
                                       .replace("04444h", f"0{seg_rom_paras:04X}h")
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

        full_image = seg0_pad + seg1_pad + seg2_pad + seg3_pad + rom_bytes
        with open(bin_path, "wb") as f:
            f.write(full_image)
        print(f"[gb200lx] Combined binary: {bin_path} ({len(full_image)} bytes)")

        subprocess.run(["python3", "tools/mzpack.py", bin_path, exe_path, "--min-extra", "0x2000"], check=True)
        print(f"[gb200lx] SUCCESS: Built standalone executable: {exe_path}")

    else:
        # --- OVERLAY MODE (> 4 banks / > 64 KiB) -> GAME.EXE + GAME.OVL ---
        seg_bins: Dict[int, bytes] = {}
        print(f"[gb200lx] Assembling {num_banks - 1} overlay bank segments...")
        for b in range(1, num_banks):
            seg_asm = f"""
bits 16
cpu 186
org 0

%define OVL_MODE 1

%include "{OUT_DIR}/dispatch_b{b}.asm"
%include "{OUT_DIR}/stubs_b{b}.asm"
%include "{OUT_DIR}/code_b{b}.asm"
%include "runtime/recomp_helpers.asm"
"""
            with open(f"{OUT_DIR}/seg{b}.asm", "w") as f:
                f.write(seg_asm)
            subprocess.run(["nasm", "-f", "bin", "-I./", "-o", f"{OUT_DIR}/seg{b}.bin", f"{OUT_DIR}/seg{b}.asm"], check=True)
            with open(f"{OUT_DIR}/seg{b}.bin", "rb") as f:
                data_b = pad16(f.read())
            if len(data_b) > 0x10000:
                raise RuntimeError(f"Bank {b} recompiled code ({len(data_b)} bytes) exceeds 64 KiB segment limit!")
            seg_bins[b] = data_b

        max_code_bytes = max(len(d) for d in seg_bins.values())
        max_code_paras = max_code_bytes // 16
        total_code_paras = sum(len(d) // 16 for d in seg_bins.values())

        # Build GAME.OVL = raw ROM bytes + packed switchable code banks 1..N-1
        ovl_path = f"{BUILD_DIR}/GAME.OVL"
        ovl_dir_entries = [(0, 0)]  # Bank 0 unused for code paging
        cur_off = len(rom_bytes)
        with open(ovl_path, "wb") as f_ovl:
            f_ovl.write(rom_bytes)
            for b in range(1, num_banks):
                d = seg_bins[b]
                ovl_dir_entries.append((cur_off, len(d)))
                f_ovl.write(d)
                cur_off += len(d)

        ovl_dir_lines = ["ovl_dir:"]
        for off_b, len_b in ovl_dir_entries:
            ovl_dir_lines.append(f"    dd 0{off_b:08X}h")
            ovl_dir_lines.append(f"    dw 0{len_b:04X}h")
        with open(f"{OUT_DIR}/ovl_dir.asm", "w") as f:
            f.write("\n".join(ovl_dir_lines) + "\n")

        def write_seg0_ovl(seg_rom_p: int):
            seg0_ovl = f"""
bits 16
cpu 186
org 0

%define SEG_IS_BANK0 1
%define OVL_MODE 1
%define NUM_ROM_BANKS {num_banks}
%define ROM_BANK_MASK_VAL 0{rom_bank_mask:02X}h
%define MAPPER_TYPE_VAL {mapper_type}
%define SRAM_PARAS_VAL 0{sram_paras:04X}h
%define SRAM_BANK_MASK_VAL 0{sram_bank_mask:02X}h
%define MAX_CODE_PARAS 0{max_code_paras:04X}h
%define TOTAL_CODE_PARAS 0{min(0xFFFF, total_code_paras):04X}h
%define SEG_ROM_PARAS_VAL 0{seg_rom_p:04X}h

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
                f.write(seg0_ovl)

        write_seg0_ovl(0x1111)
        print("[gb200lx] Pass 1: Assembling Overlay Segment 0...")
        subprocess.run(["nasm", "-f", "bin", "-I./", "-o", f"{OUT_DIR}/seg0.bin", f"{OUT_DIR}/seg0.asm"], check=True)
        with open(f"{OUT_DIR}/seg0.bin", "rb") as f:
            seg0_pad = pad16(f.read())
        if len(seg0_pad) > 0x10000:
            raise RuntimeError(f"Bank 0 Segment ({len(seg0_pad)} bytes) exceeds 64 KiB limit!")

        seg_rom_paras = len(seg0_pad) // 16
        write_seg0_ovl(seg_rom_paras)
        print("[gb200lx] Pass 2: Re-assembling Overlay Segment 0...")
        subprocess.run(["nasm", "-f", "bin", "-I./", "-o", f"{OUT_DIR}/seg0.bin", f"{OUT_DIR}/seg0.asm"], check=True)
        with open(f"{OUT_DIR}/seg0.bin", "rb") as f:
            seg0_pad = pad16(f.read())

        # Minimum DOS headroom: 64 KiB GB RAM + 8 KiB backbuffer + 32 KiB stack = 0x1A00 paras;
        # ovl_init dynamically claims all remaining conventional DOS RAM up to psp_mem_top.
        min_extra = 0x1A00
        min_cache_kb = (total_code_paras * 16) // 1024
        print(f"[gb200lx] Overlay Layout: seg0={len(seg0_pad)}B, max_bank={max_code_bytes}B, "
              f"total_code={min_cache_kb}KiB, sram={sram_paras*16//1024}KiB (dynamic cache up to PSP top)")
        print(f"[gb200lx] Overlay archive: {ovl_path} ({cur_off} bytes)")

        with open(bin_path, "wb") as f:
            f.write(seg0_pad)
        subprocess.run(["python3", "tools/mzpack.py", bin_path, exe_path, "--min-extra", f"0x{min_extra:X}"], check=True)
        print(f"[gb200lx] SUCCESS: Built overlay executable: {exe_path} + {ovl_path}")

    # Copy INI file to build dir
    subprocess.run(["cp", "GB200LX.INI", f"{BUILD_DIR}/GB200LX.INI"], check=True)
    print(f"[gb200lx] Copied GB200LX.INI -> {BUILD_DIR}/GB200LX.INI")


if __name__ == "__main__":
    main()
