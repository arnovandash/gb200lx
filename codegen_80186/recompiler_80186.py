#!/usr/bin/env python3
"""
recompiler_80186.py - Ahead-of-Time SM83 to 16-Bit 80186 Static Recompiler
Translates Game Boy DMG ROMs into flat 16-bit NASM assembly for HP 200LX.
"""

import sys
import os
from typing import Dict, Set, List, Tuple, Optional

# Register mapping table
# Game Boy 8-bit:  A,  B,  C,  D,  E,  H,  L
# 80186 8-bit:    AL, BH, BL, DH, DL, CH, CL
REG8_NAME = ['B', 'C', 'D', 'E', 'H', 'L', '(HL)', 'A']
REG8_TO_X86 = {
    'A': 'al',
    'B': 'bh',
    'C': 'bl',
    'D': 'dh',
    'E': 'dl',
    'H': 'ch',
    'L': 'cl',
}

# Game Boy 16-bit: BC, DE, HL, SP
# 80186 16-bit:    BX, DX, CX, DI
REG16_NAME = ['BC', 'DE', 'HL', 'SP']
REG16_TO_X86 = {
    'BC': 'bx',
    'DE': 'dx',
    'HL': 'cx',
    'SP': 'di'
}

class SM83Instruction:
    def __init__(self, bank: int, addr: int, opcode: int, length: int, mnemonic: str, cycles: int = 4):
        self.bank = bank
        self.addr = addr
        self.opcode = opcode
        self.length = length
        self.mnemonic = mnemonic
        self.cycles = cycles
        self.target_addr: Optional[int] = None
        self.is_branch = False
        self.is_call = False
        self.is_ret = False
        self.is_unconditional_jump = False

class SM83Disassembler:
    def __init__(self, rom_bytes: bytes):
        self.rom = rom_bytes
        self.size = len(rom_bytes)
        self.bank_count = max(1, self.size // 0x4000)

    def read_u8(self, bank: int, addr: int) -> int:
        offset = self.get_offset(bank, addr)
        if offset < self.size:
            return self.rom[offset]
        return 0

    def read_u16(self, bank: int, addr: int) -> int:
        lo = self.read_u8(bank, addr)
        hi = self.read_u8(bank, addr + 1)
        return (hi << 8) | lo

    def read_s8(self, bank: int, addr: int) -> int:
        val = self.read_u8(bank, addr)
        return val - 256 if val >= 128 else val

    def get_offset(self, bank: int, addr: int) -> int:
        if addr < 0x4000:
            return addr
        return bank * 0x4000 + (addr - 0x4000)

    def decode_instr(self, bank: int, addr: int) -> SM83Instruction:
        op = self.read_u8(bank, addr)
        
        # 0xCB Prefix
        if op == 0xCB:
            cb_op = self.read_u8(bank, addr + 1)
            reg_idx = cb_op & 0x07
            reg_name = REG8_NAME[reg_idx]
            bit = (cb_op >> 3) & 0x07
            
            if cb_op < 0x40:
                ops = ["RLC", "RRC", "RL", "RR", "SLA", "SRA", "SWAP", "SRL"]
                op_name = ops[(cb_op >> 3) & 0x07]
                return SM83Instruction(bank, addr, (op << 8) | cb_op, 2, f"{op_name} {reg_name}", 8)
            elif cb_op < 0x80:
                return SM83Instruction(bank, addr, (op << 8) | cb_op, 2, f"BIT {bit}, {reg_name}", 8)
            elif cb_op < 0xC0:
                return SM83Instruction(bank, addr, (op << 8) | cb_op, 2, f"RES {bit}, {reg_name}", 8)
            else:
                return SM83Instruction(bank, addr, (op << 8) | cb_op, 2, f"SET {bit}, {reg_name}", 8)

        # Standard Instructions
        if op == 0x00:
            return SM83Instruction(bank, addr, op, 1, "NOP", 4)
        elif op == 0x10:
            return SM83Instruction(bank, addr, op, 2, "STOP", 4)
        elif op == 0x76:
            return SM83Instruction(bank, addr, op, 1, "HALT", 4)
        elif op == 0xF3:
            return SM83Instruction(bank, addr, op, 1, "DI", 4)
        elif op == 0xFB:
            return SM83Instruction(bank, addr, op, 1, "EI", 4)
        elif op == 0x27:
            return SM83Instruction(bank, addr, op, 1, "DAA", 4)
        elif op == 0x2F:
            return SM83Instruction(bank, addr, op, 1, "CPL", 4)
        elif op == 0x37:
            return SM83Instruction(bank, addr, op, 1, "SCF", 4)
        elif op == 0x3F:
            return SM83Instruction(bank, addr, op, 1, "CCF", 4)
        elif op == 0x07:
            return SM83Instruction(bank, addr, op, 1, "RLCA", 4)
        elif op == 0x0F:
            return SM83Instruction(bank, addr, op, 1, "RRCA", 4)
        elif op == 0x17:
            return SM83Instruction(bank, addr, op, 1, "RLA", 4)
        elif op == 0x1F:
            return SM83Instruction(bank, addr, op, 1, "RRA", 4)

        # LD r, n (8-bit immediate)
        if (op & 0xC7) == 0x06:
            r = REG8_NAME[(op >> 3) & 0x07]
            imm = self.read_u8(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 2, f"LD {r}, 0x{imm:02X}", 8)

        # LD r, r' (8-bit register load)
        if 0x40 <= op <= 0x7F and op != 0x76:
            dst = REG8_NAME[(op >> 3) & 0x07]
            src = REG8_NAME[op & 0x07]
            return SM83Instruction(bank, addr, op, 1, f"LD {dst}, {src}", 4 if src != '(HL)' and dst != '(HL)' else 8)

        # 8-bit ALU A, r
        if 0x80 <= op <= 0xBF:
            ops = ["ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP"]
            op_name = ops[(op >> 3) & 0x07]
            src = REG8_NAME[op & 0x07]
            return SM83Instruction(bank, addr, op, 1, f"{op_name} A, {src}", 4 if src != '(HL)' else 8)

        # 8-bit ALU A, imm8
        if (op & 0xC7) == 0xC6:
            ops = ["ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP"]
            op_name = ops[(op >> 3) & 0x07]
            imm = self.read_u8(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 2, f"{op_name} A, 0x{imm:02X}", 8)

        # INC / DEC r
        if (op & 0xC7) == 0x04:
            r = REG8_NAME[(op >> 3) & 0x07]
            return SM83Instruction(bank, addr, op, 1, f"INC {r}", 4 if r != '(HL)' else 12)
        if (op & 0xC7) == 0x05:
            r = REG8_NAME[(op >> 3) & 0x07]
            return SM83Instruction(bank, addr, op, 1, f"DEC {r}", 4 if r != '(HL)' else 12)

        # 16-bit LD rr, nn
        if (op & 0xCF) == 0x01:
            rr = REG16_NAME[(op >> 4) & 0x03]
            nn = self.read_u16(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 3, f"LD {rr}, 0x{nn:04X}", 12)

        # 16-bit INC / DEC rr
        if (op & 0xCF) == 0x03:
            rr = REG16_NAME[(op >> 4) & 0x03]
            return SM83Instruction(bank, addr, op, 1, f"INC {rr}", 8)
        if (op & 0xCF) == 0x0B:
            rr = REG16_NAME[(op >> 4) & 0x03]
            return SM83Instruction(bank, addr, op, 1, f"DEC {rr}", 8)

        # ADD HL, rr
        if (op & 0xCF) == 0x09:
            rr = REG16_NAME[(op >> 4) & 0x03]
            return SM83Instruction(bank, addr, op, 1, f"ADD HL, {rr}", 8)

        # PUSH / POP
        if (op & 0xCF) == 0xC5:
            rr = ['BC', 'DE', 'HL', 'AF'][(op >> 4) & 0x03]
            return SM83Instruction(bank, addr, op, 1, f"PUSH {rr}", 16)
        if (op & 0xCF) == 0xC1:
            rr = ['BC', 'DE', 'HL', 'AF'][(op >> 4) & 0x03]
            return SM83Instruction(bank, addr, op, 1, f"POP {rr}", 12)

        # Memory Special Loads
        if op == 0x02:
            return SM83Instruction(bank, addr, op, 1, "LD (BC), A", 8)
        elif op == 0x12:
            return SM83Instruction(bank, addr, op, 1, "LD (DE), A", 8)
        elif op == 0x0A:
            return SM83Instruction(bank, addr, op, 1, "LD A, (BC)", 8)
        elif op == 0x1A:
            return SM83Instruction(bank, addr, op, 1, "LD A, (DE)", 8)
        elif op == 0x22:
            return SM83Instruction(bank, addr, op, 1, "LDI (HL), A", 8)
        elif op == 0x2A:
            return SM83Instruction(bank, addr, op, 1, "LDI A, (HL)", 8)
        elif op == 0x32:
            return SM83Instruction(bank, addr, op, 1, "LDD (HL), A", 8)
        elif op == 0x3A:
            return SM83Instruction(bank, addr, op, 1, "LDD A, (HL)", 8)

        # Direct absolute loads
        if op == 0xEA:
            nn = self.read_u16(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 3, f"LD (0x{nn:04X}), A", 16)
        if op == 0xFA:
            nn = self.read_u16(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 3, f"LD A, (0x{nn:04X})", 16)

        # LDH (HRAM / MMIO)
        if op == 0xE0:
            n = self.read_u8(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 2, f"LDH (0x{n:02X}), A", 12)
        if op == 0xF0:
            n = self.read_u8(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 2, f"LDH A, (0x{n:02X})", 12)

        if op == 0xE2:
            return SM83Instruction(bank, addr, op, 1, "LD (C), A", 8)
        if op == 0xF2:
            return SM83Instruction(bank, addr, op, 1, "LD A, (C)", 8)

        # Stack specials
        if op == 0xF9:
            return SM83Instruction(bank, addr, op, 1, "LD SP, HL", 8)
        if op == 0x08:
            nn = self.read_u16(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 3, f"LD (0x{nn:04X}), SP", 20)
        if op == 0xE8:
            e = self.read_s8(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 2, f"ADD SP, {e}", 16)
        if op == 0xF8:
            e = self.read_s8(bank, addr + 1)
            return SM83Instruction(bank, addr, op, 2, f"LD HL, SP+{e}", 12)

        # Control Flow: JR
        if op == 0x18:
            rel = self.read_s8(bank, addr + 1)
            target = addr + 2 + rel
            instr = SM83Instruction(bank, addr, op, 2, f"JR 0x{target:04X}", 12)
            instr.target_addr = target
            instr.is_branch = True
            instr.is_unconditional_jump = True
            return instr

        # JR cc, rel
        if (op & 0xE7) == 0x20:
            cond = ["NZ", "Z", "NC", "C"][(op >> 3) & 0x03]
            rel = self.read_s8(bank, addr + 1)
            target = addr + 2 + rel
            instr = SM83Instruction(bank, addr, op, 2, f"JR {cond}, 0x{target:04X}", 8)
            instr.target_addr = target
            instr.is_branch = True
            return instr

        # JP nn
        if op == 0xC3:
            target = self.read_u16(bank, addr + 1)
            instr = SM83Instruction(bank, addr, op, 3, f"JP 0x{target:04X}", 16)
            instr.target_addr = target
            instr.is_branch = True
            instr.is_unconditional_jump = True
            return instr

        # JP cc, nn
        if (op & 0xC7) == 0xC2:
            cond = ["NZ", "Z", "NC", "C"][(op >> 3) & 0x03]
            target = self.read_u16(bank, addr + 1)
            instr = SM83Instruction(bank, addr, op, 3, f"JP {cond}, 0x{target:04X}", 12)
            instr.target_addr = target
            instr.is_branch = True
            return instr

        # JP (HL)
        if op == 0xE9:
            instr = SM83Instruction(bank, addr, op, 1, "JP (HL)", 4)
            instr.is_branch = True
            instr.is_unconditional_jump = True
            return instr

        # CALL nn
        if op == 0xCD:
            target = self.read_u16(bank, addr + 1)
            instr = SM83Instruction(bank, addr, op, 3, f"CALL 0x{target:04X}", 24)
            instr.target_addr = target
            instr.is_call = True
            return instr

        # CALL cc, nn
        if (op & 0xC7) == 0xC4:
            cond = ["NZ", "Z", "NC", "C"][(op >> 3) & 0x03]
            target = self.read_u16(bank, addr + 1)
            instr = SM83Instruction(bank, addr, op, 3, f"CALL {cond}, 0x{target:04X}", 12)
            instr.target_addr = target
            instr.is_call = True
            return instr

        # RET / RETI / RET cc
        if op == 0xC9:
            instr = SM83Instruction(bank, addr, op, 1, "RET", 16)
            instr.is_ret = True
            return instr
        if op == 0xD9:
            instr = SM83Instruction(bank, addr, op, 1, "RETI", 16)
            instr.is_ret = True
            return instr
        if (op & 0xC7) == 0xC0:
            cond = ["NZ", "Z", "NC", "C"][(op >> 3) & 0x03]
            instr = SM83Instruction(bank, addr, op, 1, f"RET {cond}", 8)
            instr.is_ret = True
            return instr

        # RST n
        if (op & 0xC7) == 0xC7:
            vec = op & 0x38
            instr = SM83Instruction(bank, addr, op, 1, f"RST 0x{vec:02X}", 16)
            instr.target_addr = vec
            instr.is_call = True
            return instr

        # Fallback for undefined opcodes / data
        return SM83Instruction(bank, addr, op, 1, f"DB 0x{op:02X}", 4)


class CodeGenerator80186:
    def __init__(self, disasm: SM83Disassembler):
        self.disasm = disasm
        self.labels: Set[Tuple[int, int]] = set()

    def label_name(self, bank: int, addr: int) -> str:
        # Bank 0 is always in segment 0
        if addr < 0x4000:
            return f"loc_00_{addr:04x}"
        return f"loc_{bank:02x}_{addr:04x}"

    def translate_instruction(self, instr: SM83Instruction) -> List[str]:
        m = instr.mnemonic
        bank = instr.bank
        addr = instr.addr
        next_addr = addr + instr.length

        # 1. System & Control
        if m == "NOP":
            return ["nop"]
        if m == "STOP":
            return ["call helper_stop"]
        if m == "HALT":
            return ["call helper_halt"]
        if m == "DI":
            return ["mov byte [cs:gb_ime], 0"]
        if m == "EI":
            return ["mov byte [cs:gb_ime], 1"]
        if m == "CPL":
            return ["not al"]
        if m == "SCF":
            return ["stc"]
        if m == "CCF":
            return ["cmc"]
        if m == "DAA":
            return ["daa"]

        # Rotates on A
        if m == "RLCA":
            return ["rol al, 1"]
        if m == "RRCA":
            return ["ror al, 1"]
        if m == "RLA":
            return ["rcl al, 1"]
        if m == "RRA":
            return ["rcr al, 1"]

        # 2. 8-Bit Loads
        if m.startswith("LD "):
            parts = m[3:].split(", ")
            dst, src = parts[0], parts[1]

            # Redundant
            if dst == src:
                return []

            # LD (HL), A
            if dst == "(HL)" and src == "A":
                return ["mov si, cx", "call helper_write_hl"]
            # LD (HL), r
            if dst == "(HL)":
                if src.startswith("0x"):
                    imm = src.replace("0x", "0") + "h"
                    return ["push ax", f"mov al, {imm}", "mov si, cx", "call helper_write_hl", "pop ax"]
                xsrc = REG8_TO_X86.get(src, 'al')
                return ["push ax", f"mov al, {xsrc}", "mov si, cx", "call helper_write_hl", "pop ax"]
            # LD r, (HL)
            if src == "(HL)":
                xdst = REG8_TO_X86.get(dst, 'al')
                return ["mov si, cx", f"mov {xdst}, [si]"]

            # LD r, r'
            if dst in REG8_TO_X86 and src in REG8_TO_X86:
                return [f"mov {REG8_TO_X86[dst]}, {REG8_TO_X86[src]}"]

            # LD r, imm8
            if dst in REG8_TO_X86 and src.startswith("0x"):
                imm = src.replace("0x", "0") + "h"
                return [f"mov {REG8_TO_X86[dst]}, {imm}"]

            # 16-bit loads: LD rr, imm16
            if dst in REG16_TO_X86 and src.startswith("0x"):
                imm = src.replace("0x", "0") + "h"
                return [f"mov {REG16_TO_X86[dst]}, {imm}"]

            # LD SP, HL
            if dst == "SP" and src == "HL":
                return ["mov di, cx"]

            # LD (0xNNNN), SP
            if dst.startswith("(0x") and src == "SP":
                target = int(dst[3:7], 16)
                return [f"mov [0{target:04X}h], di"]

            # LD HL, SP+e
            if dst == "HL" and src.startswith("SP+"):
                e = int(src[3:])
                if e >= 0:
                    return ["mov cx, di", f"add cx, {e}"]
                else:
                    return ["mov cx, di", f"sub cx, {-e}"]

            # Direct absolute: LD (0xNNNN), A
            if dst.startswith("(0x") and src == "A":
                target = int(dst[3:7], 16)
                if target < 0x8000:
                    return [f"mov bp, 0{target:04X}h", "call helper_write_mbc"]
                elif target == 0xFF46:
                    return ["call helper_dma_transfer"]
                elif target == 0xFF47:
                    return ["mov [0FF47h], al", "call helper_update_bgp"]
                elif 0xFF00 <= target <= 0xFF7F:
                    return [f"mov [0{target:04X}h], al", f"mov bp, 0{target:04X}h", "call helper_write_mmio"]
                else:
                    return [f"mov [0{target:04X}h], al"]

            # Direct absolute: LD A, (0xNNNN)
            if dst == "A" and src.startswith("(0x"):
                target = int(src[3:7], 16)
                if target == 0xFF00:
                    return ["call helper_read_joyp"]
                elif target == 0xFF04:
                    return ["call helper_read_div"]
                elif target == 0xFF44:
                    return ["call helper_read_ly"]
                else:
                    return [f"mov al, [0{target:04X}h]"]

        # LDH (n), A  -> [0xFF00 + n]
        if m.startswith("LDH ("):
            n_val = int(m.split("(")[1].split(")")[0], 16)
            full_addr = 0xFF00 + n_val
            if n_val == 0x46:
                return ["call helper_dma_transfer"]
            elif n_val == 0x47:
                return ["mov [0FF47h], al", "call helper_update_bgp"]
            elif n_val <= 0x7F:
                return [f"mov [0{full_addr:04X}h], al", f"mov bp, 0{full_addr:04X}h", "call helper_write_mmio"]
            else:
                return [f"mov [0{full_addr:04X}h], al"]

        # LDH A, (n)
        if m.startswith("LDH A, ("):
            n_val = int(m.split("(")[1].split(")")[0], 16)
            full_addr = 0xFF00 + n_val
            if n_val == 0x00:
                return ["call helper_read_joyp"]
            elif n_val == 0x04:
                return ["call helper_read_div"]
            elif n_val == 0x44:
                return ["call helper_read_ly"]
            else:
                return [f"mov al, [0{full_addr:04X}h]"]

        # LD (C), A / LD A, (C)
        if m == "LD (C), A":
            return ["call helper_write_c"]
        if m == "LD A, (C)":
            return ["call helper_read_c"]

        # Indirect (BC) / (DE)
        if m == "LD (BC), A":
            return ["call helper_write_bc"]
        if m == "LD A, (BC)":
            return ["mov al, [bx]"]
        if m == "LD (DE), A":
            return ["call helper_write_de"]
        if m == "LD A, (DE)":
            return ["mov bp, dx", "mov al, [ds:bp]"]

        # LDI / LDD
        if m == "LDI (HL), A":
            return ["mov si, cx", "call helper_write_hl", "inc cx"]
        if m == "LDI A, (HL)":
            return ["mov si, cx", "mov al, [si]", "inc cx"]
        if m == "LDD (HL), A":
            return ["mov si, cx", "call helper_write_hl", "dec cx"]
        if m == "LDD A, (HL)":
            return ["mov si, cx", "mov al, [si]", "dec cx"]

        # 3. ALU 8-bit
        alu_ops = {
            "ADD": "add", "ADC": "adc", "SUB": "sub", "SBC": "sbb",
            "AND": "and", "XOR": "xor", "OR": "or", "CP": "cmp"
        }
        for gb_alu, x86_alu in alu_ops.items():
            if m.startswith(f"{gb_alu} A, "):
                src = m.split(", ")[1]
                if src == "A" and gb_alu == "XOR":
                    return ["xor al, al"]
                if src in REG8_TO_X86:
                    return [f"{x86_alu} al, {REG8_TO_X86[src]}"]
                elif src == "(HL)":
                    return ["mov si, cx", f"{x86_alu} al, [si]"]
                elif src.startswith("0x"):
                    imm = src.replace("0x", "0") + "h"
                    return [f"{x86_alu} al, {imm}"]

        # 4. INC / DEC 8-bit & 16-bit
        if m.startswith("INC "):
            r = m[4:]
            if r in REG8_TO_X86:
                return [f"inc {REG8_TO_X86[r]}"]
            elif r == "(HL)":
                return ["mov si, cx", "inc byte [si]"]
            elif r in REG16_TO_X86:
                return [f"inc {REG16_TO_X86[r]}"]

        if m.startswith("DEC "):
            r = m[4:]
            if r in REG8_TO_X86:
                return [f"dec {REG8_TO_X86[r]}"]
            elif r == "(HL)":
                return ["mov si, cx", "dec byte [si]"]
            elif r in REG16_TO_X86:
                return [f"dec {REG16_TO_X86[r]}"]

        # ADD HL, rr
        if m.startswith("ADD HL, "):
            rr = m[8:]
            if rr in REG16_TO_X86:
                return [f"add cx, {REG16_TO_X86[rr]}"]

        # ADD SP, e
        if m.startswith("ADD SP, "):
            e = int(m[8:])
            if e >= 0:
                return [f"add di, {e}"]
            else:
                return [f"sub di, {-e}"]

        # 5. PUSH / POP
        if m.startswith("PUSH "):
            rr = m[5:]
            if rr == "AF":
                return ["call helper_push_af"]
            elif rr in REG16_TO_X86:
                xreg = REG16_TO_X86[rr]
                return ["sub di, 2", f"mov [di], {xreg}"]

        if m.startswith("POP "):
            rr = m[4:]
            if rr == "AF":
                return ["call helper_pop_af"]
            elif rr in REG16_TO_X86:
                xreg = REG16_TO_X86[rr]
                return [f"mov {xreg}, [di]", "add di, 2"]

        # 6. CB-prefix operations
        if m.startswith("BIT "):
            parts = m[4:].split(", ")
            bit = int(parts[0])
            r = parts[1]
            mask = f"0{(1 << bit):02X}h"
            if r in REG8_TO_X86:
                return [f"test {REG8_TO_X86[r]}, {mask}"]
            elif r == "(HL)":
                return ["mov si, cx", f"test byte [si], {mask}"]

        if m.startswith("SET "):
            parts = m[4:].split(", ")
            bit = int(parts[0])
            r = parts[1]
            mask = f"0{(1 << bit):02X}h"
            if r in REG8_TO_X86:
                return [f"or {REG8_TO_X86[r]}, {mask}"]
            elif r == "(HL)":
                return ["mov si, cx", f"or byte [si], {mask}"]

        if m.startswith("RES "):
            parts = m[4:].split(", ")
            bit = int(parts[0])
            r = parts[1]
            mask = f"0{(~(1 << bit) & 0xFF):02X}h"
            if r in REG8_TO_X86:
                return [f"and {REG8_TO_X86[r]}, {mask}"]
            elif r == "(HL)":
                return ["mov si, cx", f"and byte [si], {mask}"]

        if m.startswith("SWAP "):
            r = m.split()[1]
            if r in REG8_TO_X86:
                xr = REG8_TO_X86[r]
                return [f"rol {xr}, 4", f"test {xr}, {xr}"]
            elif r == "(HL)":
                return ["mov si, cx", "rol byte [si], 4", "test byte [si], 0FFh"]

        cb_rotates = {
            "SLA":  "shl {r}, 1",
            "SRA":  "sar {r}, 1",
            "SRL":  "shr {r}, 1",
            "RL":   "rcl {r}, 1",
            "RR":   "rcr {r}, 1",
            "RLC":  "rol {r}, 1",
            "RRC":  "ror {r}, 1",
        }
        for cb_name, template in cb_rotates.items():
            if m.startswith(f"{cb_name} "):
                r = m.split()[1]
                if r in REG8_TO_X86:
                    return [template.format(r=REG8_TO_X86[r])]
                elif r == "(HL)":
                    return ["mov si, cx", template.format(r="byte [si]")]

        # 7. Control Flow: JR / JP
        if m.startswith("JR "):
            parts = m[3:].split(", ")
            if len(parts) == 1:
                target = int(parts[0], 16)
                self.labels.add((bank, target))
                return [f"jmp near {self.label_name(bank, target)}"]
            else:
                cond, target_str = parts[0], parts[1]
                target = int(target_str, 16)
                self.labels.add((bank, target))
                jcc_map = {"Z": "jz", "NZ": "jnz", "C": "jc", "NC": "jnc"}
                jcc = jcc_map.get(cond, "jmp")
                return [f"{jcc} near {self.label_name(bank, target)}"]

        if m.startswith("JP "):
            parts = m[3:].split(", ")
            if len(parts) == 1:
                if parts[0] == "(HL)":
                    return ["mov si, cx", "jmp near helper_dispatch_jp_hl"]
                target = int(parts[0], 16)
                self.labels.add((bank, target))
                return [f"jmp near {self.label_name(bank, target)}"]
            else:
                cond, target_str = parts[0], parts[1]
                target = int(target_str, 16)
                self.labels.add((bank, target))
                jcc_map = {"Z": "jz", "NZ": "jnz", "C": "jc", "NC": "jnc"}
                jcc = jcc_map.get(cond, "jmp")
                return [f"{jcc} near {self.label_name(bank, target)}"]

        # 8. CALL / RET / RST
        if m.startswith("CALL "):
            parts = m[5:].split(", ")
            if len(parts) == 1:
                target = int(parts[0], 16)
                self.labels.add((bank if target >= 0x4000 else 0, target))
                ret_addr = f"0{next_addr:04X}h"
                return [
                    "sub di, 2",
                    f"mov word [di], {ret_addr}",
                    f"call near {self.label_name(bank, target)}"
                ]
            else:
                cond, target_str = parts[0], parts[1]
                target = int(target_str, 16)
                self.labels.add((bank if target >= 0x4000 else 0, target))
                lbl_skip = f".skip_c_{addr:04x}"
                neg_jcc = {"Z": "jnz", "NZ": "jz", "C": "jnc", "NC": "jc"}.get(cond, "jmp")
                ret_addr = f"0{next_addr:04X}h"
                return [
                    f"{neg_jcc} short {lbl_skip}",
                    "sub di, 2",
                    f"mov word [di], {ret_addr}",
                    f"call near {self.label_name(bank, target)}",
                    f"{lbl_skip}:"
                ]

        if m == "RET":
            return ["add di, 2", "ret"]
        if m == "RETI":
            return ["mov byte [cs:gb_ime], 1", "add di, 2", "ret"]
        if m.startswith("RET "):
            cond = m[4:]
            lbl_skip = f".skip_r_{addr:04x}"
            neg_jcc = {"Z": "jnz", "NZ": "jz", "C": "jnc", "NC": "jc"}.get(cond, "ret")
            return [
                f"{neg_jcc} short {lbl_skip}",
                "add di, 2",
                "ret",
                f"{lbl_skip}:"
            ]

        if m.startswith("RST "):
            vec = int(m[4:], 16)
            self.labels.add((0, vec))
            ret_addr = f"0{next_addr:04X}h"
            return [
                "sub di, 2",
                f"mov word [di], {ret_addr}",
                f"call near {self.label_name(0, vec)}"
            ]

        # 9. Fallback for data / DB
        if m.startswith("DB "):
            val = m[3:]
            return [f"db {val.replace('0x', '0')}h"]

        return [f"; {m}"]


def generate_bank_asm(disasm: SM83Disassembler, bank_id: int, output_file: str):
    codegen = CodeGenerator80186(disasm)
    
    start_addr = 0x0000 if bank_id == 0 else 0x4000
    end_addr = 0x4000 if bank_id == 0 else 0x8000
    
    lines = [
        f"; ==============================================================================",
        f"; Bank {bank_id:02X} - Generated Native 80186 Assembly",
        f"; ==============================================================================",
        f"bits 16",
        f"cpu 186",
        f"",
    ]
    
    # Linear sweep disassembly of the bank
    curr_addr = start_addr
    instructions = []
    while curr_addr < end_addr:
        instr = disasm.decode_instr(bank_id, curr_addr)
        instructions.append(instr)
        curr_addr += max(1, instr.length)
        if instr.target_addr is not None and start_addr <= instr.target_addr < end_addr:
            codegen.labels.add((bank_id, instr.target_addr))
            
    # Add known entry points
    if bank_id == 0:
        for vec in [0x00, 0x08, 0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48, 0x50, 0x58, 0x60, 0x100, 0x150]:
            codegen.labels.add((0, vec))

    # Emit assembly with labels
    for instr in instructions:
        if (bank_id, instr.addr) in codegen.labels or (bank_id == 0 and instr.addr in [0x00, 0x40, 0x100, 0x150]):
            lbl = codegen.label_name(bank_id, instr.addr)
            lines.append(f"global {lbl}")
            lines.append(f"{lbl}:")
        
        x86_ops = codegen.translate_instruction(instr)
        if x86_ops:
            comment = f" ; {instr.addr:04X}: {instr.mnemonic}"
            lines.append(f"    {x86_ops[0]:<36}{comment}")
            for extra in x86_ops[1:]:
                lines.append(f"    {extra}")

    with open(output_file, "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"[recompiler] Emitted Bank {bank_id} -> {output_file} ({len(instructions)} instructions)")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 codegen_80186/recompiler_80186.py <path/to/rom.gb> [output_dir]")
        sys.exit(1)
    rom_path = sys.argv[1]
    out_dir = sys.argv[2] if len(sys.argv) > 2 else "build/rom"
    os.makedirs(out_dir, exist_ok=True)
    
    with open(rom_path, "rb") as f:
        rom_data = f.read()
        
    disasm = SM83Disassembler(rom_data)
    print(f"[recompiler] Loading ROM: {rom_path} ({len(rom_data)} bytes, {disasm.bank_count} banks)")
    
    # Emit Bank 0..N
    for b in range(disasm.bank_count):
        out_asm = os.path.join(out_dir, f"bank_{b:02X}.asm")
        generate_bank_asm(disasm, b, out_asm)

if __name__ == "__main__":
    main()
