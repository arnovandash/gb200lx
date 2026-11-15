# GB200LX: Static Game Boy AOT Recompiler for HP 200LX (80186 MS-DOS)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Target: 80186 MS-DOS](https://img.shields.io/badge/Target-80186%20MS--DOS-green.svg)](#hardware-target)
[![Platform: HP 200LX](https://img.shields.io/badge/Palmtop-HP%20200LX%20%2F%20100LX-orange.svg)](#hp-200lx-hardware-overview)

**GB200LX** is an ahead-of-time (AOT) static binary recompiler that translates original Game Boy (Sharp SM83 / LR35902) ROMs directly into native 16-bit x86 assembly (`bits 16`, `cpu 186`), producing standalone, self-contained MS-DOS `.EXE` binaries. It is specifically tailored to run at full speed (60 FPS) on the vintage **HP 200LX palmtop PC** powered by an Intel Hornet 80186 ASIC at 7.91 MHz with 636 KiB of conventional RAM and a 320×200 4-shade grayscale CGA display.

---

## Why Static Recompilation?

Emulating a 4.19 MHz Game Boy CPU instruction-by-instruction via a traditional software interpreter requires fetching, decoding, updating register structs, evaluating flag arithmetic, and polling hardware timers on every instruction. On an Intel 80186 clocked at 7.91 MHz, software emulation achieves less than 5–10 FPS—far too slow for playable gaming.

**GB200LX takes a completely different path:**
- **Zero Interpretation Overhead:** Each SM83 instruction is lifted ahead of time into 1–3 native 16-bit x86 instructions.
- **Physical Register Pinning:** All Game Boy CPU registers remain permanently mapped to physical 80186 CPU registers across basic blocks. No RAM load/store overhead per instruction.
- **Micro-Optimized CGA Conversion:** Converts DMG 2bpp planar tilemaps into CGA Mode 04h 2bpp packed words using an ultra-fast 256-byte nibble lookup table, consuming **less than 1%** of Hornet CPU time (~72,000 cycles/frame at 7.91 MHz).
- **Relocation-Free Segmentation:** Multi-bank ROMs (such as 64 KiB MBC1 titles like *Super Mario Land*) are split into discrete 16-bit code segments with precomputed far-call dispatch trampolines, overcoming the MS-DOS 64 KiB segment limit without needing 386 protected mode or EMS drivers.

---

## HP 200LX Hardware Overview

| Specification | HP 200LX Palmtop | Recompiler Adaptation |
| :--- | :--- | :--- |
| **CPU** | Intel Hornet 80186 ASIC @ 7.91 MHz | Native 16-bit 80186 instructions only (`bits 16`, `cpu 186`) |
| **RAM** | 636 KiB Conventional MS-DOS RAM | Entire game + RAM fits in ~292 KiB conventional memory |
| **Display** | 320×200 4-shade grayscale LCD (CGA Mode 04h) | Centered 160×144 viewport with 4-level grayscale palette mapping |
| **Video Memory** | `B800:0000` / `BA00:0000` (Interleaved lines) | Lookup-table accelerated scanline rendering during VBlank |
| **Audio** | Internal piezoelectric buzzer (PIT Ch 2, Port 0x42) | Configurable PC speaker square wave tone driver |
| **OS** | ROM-based MS-DOS 5.0 | Standalone MZ `.EXE` requiring no drivers or TSRs |

---

## Architectural Highlights

### 1. Pinned Hardware Register Mapping

SM83 registers are pinned 1:1 into physical 80186 registers:

| Game Boy (SM83) | 16-Bit x86 Register | High Half | Low Half | Notes |
| :---: | :---: | :---: | :---: | :--- |
| **AF** (`A`, `F`) | **`AX`** | `AL` (`A`) | `AH` (`F`) | Flags `Z N H C` packed lazily on flag-read instructions |
| **BC** (`B`, `C`) | **`BX`** | `BH` (`B`) | `BL` (`C`) | Full 8-bit and 16-bit access |
| **DE** (`D`, `E`) | **`DX`** | `DH` (`D`) | `DL` (`E`) | Full 8-bit and 16-bit access |
| **HL** (`H`, `L`) | **`CX`** | `CH` (`H`) | `CL` (`L`) | Enables native 8-bit `CH`/`CL` and 16-bit `CX` arithmetic |
| **(HL) Dereference** | **`SI`** | — | — | Loaded on demand: `mov si, cx; mov al, [si]` |
| **SP** | **`DI`** | — | — | Game Boy stack in RAM block; hardware `SP` reserved for interrupts |
| **Memory Space** | **`DS`** | — | — | Segment register pointing to dedicated 64 KiB Game Boy block |

> [!NOTE]
> On 16-bit x86, `SI` and `DI` cannot be split into 8-bit byte registers (`sih`/`sil` do not exist). Mapping `H` -> `CH`, `L` -> `CL`, `HL` -> `CX`, and using `SI` strictly as an address pointer provides instantaneous single-cycle 8-bit manipulation for the thousands of `H` and `L` operations in Game Boy code.

### 2. Multi-Segment Memory Layout

To support Game Boy games up to 64 KiB and beyond without EMS drivers:
```
+--------------------------------------------------------------+ 0000:0000
| Segment 0: Bank 00 Code + CRT0 + Video + Config + Helpers    | (~44 KiB)
+--------------------------------------------------------------+ CS + seg1_paras
| Segment 1: Bank 01 Recompiled Code Unit                      | (~37 KiB)
+--------------------------------------------------------------+ CS + seg2_paras
| Segment 2: Bank 02 Recompiled Code Unit                      | (~38 KiB)
+--------------------------------------------------------------+ CS + seg3_paras
| Segment 3: Bank 03 Recompiled Code Unit                      | (~37 KiB)
+--------------------------------------------------------------+ CS + seg_rom_paras
| Embedded Raw ROM Data (0x0000 - 0xFFFF)                      | (64 KiB)
+--------------------------------------------------------------+ gb_mem_seg
| Game Boy 64 KiB Virtual Address Space (WRAM, VRAM, OAM, HRAM)| (64 KiB)
+--------------------------------------------------------------+ SS
| Hardware Stack Space (Allocated via DOS MZ e_minalloc)       | (32 KiB)
+--------------------------------------------------------------+
```

### 3. CGA Mode 04h Grayscale Pipeline

The HP 200LX LCD controller maps CGA Mode 04h 2-bit pixels (`00b`, `01b`, `10b`, `11b`) to four physical shades of gray:
- **Game Boy 2bpp Planar:** Stored in VRAM across two separate byte planes (Plane 0 at byte offset $2k$, Plane 1 at byte offset $2k+1$).
- **CGA 2bpp Packed:** Each byte contains 4 adjacent pixels packed in pairs: `p0:p1:p2:p3`.
- **Nibble LUT Technique:** A precalculated 256-byte table transforms an 8-pixel Game Boy slice into a 16-bit CGA word in just two memory lookups. The full $160 \times 144$ frame renders in under 1 ms.

---

## Configuration & Keymapping

GB200LX provides two configuration methods:

### 1. Human-Readable INI File (`GB200LX.INI`)
Place `GB200LX.INI` in the same directory as the executable:
```ini
[video]
scaling = center          ; center (160x144 centered) or wide
palette = pocket          ; pocket, dmg, high_con, dark
vsync = 1

[input]
key_up     = UP
key_down   = DOWN
key_left   = LEFT
key_right  = RIGHT
key_a      = Z
key_b      = X
key_select = SPACE
key_start  = ENTER
key_menu   = ESC
```

### 2. Interactive Palmtop Setup Mode (`/SETUP`)
Launch the recompiled game with `/SETUP` on the HP 200LX:
```dos
C:\GAMES> GAME.EXE /SETUP
```
Opens a lightweight, full-screen text-mode configuration utility allowing you to press any key on the palmtop keyboard to remap controls, toggle palettes, test responsiveness, and persist settings directly back to `GB200LX.INI`.

---

## Getting Started (Bring Your Own ROM)

### Prerequisites
- **Python 3.8+** (for offline disassembler and code generator)
- **NASM 2.15+** (Netwide Assembler)
- **DOSBox-X** (for desktop testing and verification)

### Building a ROM
```bash
# Clone the repository
git clone https://github.com/your-username/gb200lx.git
cd gb200lx

# Build standalone DOS .EXE from your own Game Boy ROM
make ROM="/path/to/your_game.gb"

# Or specify a custom 8.3 DOS executable name:
make ROM="/path/to/your_game.gb" EXE="SML.EXE"

# Run automated 60-frame headless test (renders frame to build/screen.png)
make test

# Launch interactively in DOSBox-X (configured for 80186 CGA)
make run

# Launch interactive setup wizard
make setup
```

The resulting `build/GAME.EXE` and `GB200LX.INI` can be copied directly to your HP 200LX CompactFlash card or RAM disk (`A:\` or `C:\`) and launched natively under MS-DOS.

---

## Repository Structure

```
gb200lx/
├── codegen_80186/          # Offline SM83 to 80186 recompiler
│   └── recompiler_80186.py # Disassembler, CFG analysis, x86-16 emitter
├── runtime/                # 16-bit NASM runtime routines
│   ├── crt0_rom.asm        # Standalone ROM harness, frame scheduler & INT 09h hook
│   ├── crt0.asm            # Generic bring-up skeleton
│   ├── video_cga.asm       # CGA Mode 04h driver & PPU dirty frame blitter
│   ├── video_cga.inc       # Video constants and macros
│   ├── config_ini.asm      # INI parser and text-mode /SETUP wizard
│   ├── config_ini.inc      # Configuration structure definitions
│   └── recomp_helpers.asm  # Bank switching, DMA, and memory routing helpers
├── tools/                  # Build automation & diagnostics
│   ├── build_rom.py        # Generic multi-segment AOT compiler & linker
│   ├── mzpack.py           # MS-DOS MZ header synthesis tool
│   └── cga_to_png.py       # CGA Mode 04h VRAM dump to PNG converter
├── docs/                   # In-depth architectural documentation
│   ├── ARCHITECTURE.md     # Register pinning, segmentation & memory routing
│   └── CONFIGURATION.md    # Key codes, palette presets & INI guide
├── dosbox-x.conf           # 80186 + CGA test configuration
├── Makefile                # Bring-your-own-ROM build and test orchestration
├── GB200LX.INI             # Default user configuration
└── README.md
```

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details. Game Boy is a registered trademark of Nintendo Co., Ltd. This project is an independent engineering effort and is not affiliated with or endorsed by Nintendo.
