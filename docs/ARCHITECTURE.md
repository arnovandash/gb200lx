# GB200LX Technical Architecture & Design Specification

This document details the internal design and architectural decisions of **GB200LX**, an ahead-of-time (AOT) static recompiler targeting 16-bit 80186 MS-DOS on the HP 200LX palmtop.

---

## 1. Problem Formulation: The 80186 Constraint

The HP 200LX palmtop runs an **Intel Hornet 80186 ASIC** clocked at 7.91 MHz.
Key characteristics of this platform include:
- **16-Bit Real Mode Only:** No 32-bit registers (`EAX`, `EBX`, etc.) and no 386 protected mode.
- **Strict 64 KiB Segment Limits:** Code and data segments cannot exceed 65,536 bytes without changing segment registers (`CS`, `DS`, `ES`, `SS`).
- **Clock Budget:** At 7.91 MHz, the CPU delivers approximately 1.5–2.0 MIPS (averaging 4–5 clock cycles per x86 instruction).
- **Game Boy Clock Rate:** The Game Boy SM83 CPU runs at 4.194304 MHz (1.05 M-cycles/second).

An interpreter executing 4–8 x86 instructions to fetch an opcode, update a cycle counter, index a jump table, read memory structs, and compute flags would consume 30–60 clock cycles per Game Boy opcode. At 7.91 MHz, this yields at best 5–10 FPS.

**The Solution:** Ahead-of-time static translation of SM83 instructions into native 16-bit x86 instructions, matching physical registers 1:1, resolving addresses statically, and blitting video frames during VBlank with lookup tables.

---

## 2. Register Pinning Strategy

### The 16-Bit x86 Register Dilemma
The 80186 provides eight general-purpose 16-bit registers:
`AX`, `BX`, `CX`, `DX`, `SI`, `DI`, `BP`, `SP`.

Of these, **only four** can be split into 8-bit high/low halves:
- `AX` -> `AH`, `AL`
- `BX` -> `BH`, `BL`
- `CX` -> `CH`, `CL`
- `DX` -> `DH`, `DL`

Crucially, **`SI`, `DI`, `BP`, and `SP` have no 8-bit halves**.

Game Boy code frequently accesses 8-bit registers (`LD A, H`, `INC L`, `ADD A, C`, `DEC B`). If `H` and `L` were mapped to `SI` (e.g. `SI` as `HL`), every 8-bit read or write to `H` or `L` would require shifting and masking `SI` through a temporary register, costing 8–12 cycles per operation.

### The Unified Mapping Solution

| SM83 Register | 80186 Register | High Half | Low Half | Purpose |
| :---: | :---: | :---: | :---: | :--- |
| **`AF`** | **`AX`** | `AH` (`F`) | `AL` (`A`) | Accumulator & lazy flags |
| **`BC`** | **`BX`** | `BH` (`B`) | `BL` (`C`) | 8-bit counters & 16-bit base |
| **`DE`** | **`DX`** | `DH` (`D`) | `DL` (`E`) | 8-bit data & 16-bit displacement |
| **`HL`** | **`CX`** | `CH` (`H`) | `CL` (`L`) | High-speed 8-bit & 16-bit arithmetic |
| **`(HL)` Pointer** | **`SI`** | — | — | Loaded on demand: `mov si, cx; mov al, [si]` |
| **`SP`** | **`DI`** | — | — | Game Boy stack pointer in GB RAM segment |
| **Hardware `SP`**| **`SP`** | — | — | Reserved strictly for native x86 `CALL`/`RET` and interrupts |
| **Memory Base**  | **`DS`** | — | — | Pinned to dedicated 64 KiB Game Boy memory segment |

By assigning `HL` to `CX`, all 8-bit operations on `H` (`CH`) and `L` (`CL`) execute as single-cycle native instructions (`inc ch`, `mov al, cl`, etc.). Whenever `(HL)` memory dereferencing is required, `mov si, cx` executes in 2 clock cycles before accessing `[si]`.

---

## 3. Memory Routing & Address Virtualization

A dedicated, paragraph-aligned 64 KiB block in conventional RAM is assigned to the Game Boy address space (`0x0000..0xFFFF`), with `DS` permanently pointing to this segment during game execution.

### Memory Map Fast Paths
```
0x0000 - 0x3FFF: ROM Bank 00    -> Read-only; mapped to lower 16 KiB of DS block
0x4000 - 0x7FFF: ROM Bank NN    -> Bank-switched; updated by helper_write_mbc
0x8000 - 0x9FFF: VRAM           -> Direct reads/writes in DS block
0xC000 - 0xDFFF: WRAM           -> Direct reads/writes in DS block
0xE000 - 0xFDFF: Echo RAM       -> Mirrored to WRAM
0xFE00 - 0xFE9F: OAM            -> Direct reads/writes in DS block
0xFF00 - 0xFF7F: MMIO Registers -> Intercepted via helpers (LCDC, LY, DMA, JOYP)
0xFF80 - 0xFFFE: HRAM           -> Direct reads/writes in DS block
0xFFFF         : IE Register    -> Direct access in DS block
```

### Direct vs. Range-Checked Memory Access
1. **Statically Resolved Addresses:**
   When the target address is known at translation time:
   - WRAM (`0xC000..0xFDFF`): `mov [0C120h], al` (direct native write, 0 overhead).
   - HRAM (`0xFF80..0xFFFE`): `mov [0FF85h], al` (direct native write).
   - MMIO Registers: `mov [0FF40h], al; mov bp, 0FF40h; call helper_write_mmio`.
2. **Dynamic Pointer Writes (`LD (HL), A`):**
   ```nasm
   mov     si, cx
   call    helper_write_hl
   ```
   Inside `helper_write_hl`:
   ```nasm
   helper_write_hl:
       cmp     si, 08000h
       jb      short .hl_mbc       ; Writes < 0x8000 trigger MBC bank switching
       cmp     si, 0FE00h
       jae     short .hl_mmio      ; Writes >= 0xFE00 check OAM/MMIO side-effects
       mov     [si], al            ; Fast path: WRAM/VRAM write directly inline
       ret
   ```

---

## 4. Multi-Segment Architecture & Cross-Bank Dispatch

Game Boy titles with bank switching (MBC1) contain multiple 16 KiB ROM banks. Super Mario Land contains 4 banks (64 KiB total).

### Contiguous Segment Offsets
Each 16 KiB bank is translated as an independent code segment assembled with `org 0`. During pass 1 of the build pipeline, segment sizes are measured and padded to 16-byte paragraph boundaries:
- Segment 0: `CS + 0`
- Segment 1: `CS + SEG1_PARAS_VAL`
- Segment 2: `CS + SEG2_PARAS_VAL`
- Segment 3: `CS + SEG3_PARAS_VAL`
- Raw ROM Data: `CS + SEG_ROM_PARAS_VAL`

Because segment bases are contiguous relative to the program's initial code segment `CS`, any segment can compute the segment base of another at runtime without link-time relocations:
```nasm
; From Bank 1, call Bank 0 wrapper:
mov     ax, cs
sub     ax, SEG1_PARAS_VAL          ; AX = Segment 0 base
push    ax                          ; Push far segment
push    word (4 + target_idx * 4)   ; Push far offset
mov     bp, sp
call    far [bp]                    ; Execute far call
add     sp, 4
ret
```

### Relocation-Free Jump Tables
- **Bank 0 -> Bank N:** Target wrappers in Bank N are positioned at fixed offsets: $k \times 4$.
- **Bank N -> Bank 0:** Bank 0 provides an aligned entry jump table starting at offset 4 (immediately after the 3-byte entry trampoline `jmp near entry; nop`).

---

## 5. CGA Mode 04h Grayscale Pipeline

### Planar to Packed Nibble Conversion
The Game Boy PPU stores 2-bit pixels in planar format (two bytes per 8-pixel row):
- Byte 0: `p7_0 p6_0 p5_0 p4_0 p3_0 p2_0 p1_0 p0_0` (Bitplane 0)
- Byte 1: `p7_1 p6_1 p5_1 p4_1 p3_1 p2_1 p1_1 p0_1` (Bitplane 1)

CGA Mode 04h requires packed pixels: 4 pixels per byte:
- Byte: `p0:p1:p2:p3` (each pixel is 2 bits).

GB200LX implements an ultra-fast 256-byte lookup table (`dmg_cga_nibble_table`). For any 4-pixel nybble formed by combining 4 bits of Bitplane 0 and 4 bits of Bitplane 1 into an index, the table directly returns the 8-bit packed CGA representation.

An entire 8-pixel row is converted using:
1. Low nibbles combined -> Table lookup -> Left CGA byte.
2. High nibbles combined -> Table lookup -> Right CGA byte.

Rendering all 144 scanlines requires less than 72,000 CPU cycles per frame, leaving **>98% of Hornet CPU bandwidth** dedicated to running game logic.

---

## 6. Interrupt & Frame Pacing

1. **VBlank Synchronization:**
   When the Game Boy code executes `HALT`, the CPU sleeps waiting for the VBlank interrupt. In GB200LX, `helper_halt` intercepts this call, renders the CGA frame, checks input/exit flags, and dispatches the Game Boy VBlank ISR vector at `loc_00_0040`.
2. **Keyboard Interception:**
   `INT 09h` (Keyboard Hardware IRQ1) is hooked at startup. Scancodes are matched against the user's keymappings loaded from `GB200LX.INI` and update the active Game Boy joypad register state in real time. Upon exit, the original BIOS vector is cleanly restored.
