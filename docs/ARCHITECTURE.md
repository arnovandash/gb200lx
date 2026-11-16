# GB200LX Technical Architecture & Design Specification

This document describes the internal design of **GB200LX**, an ahead-of-time (AOT) static recompiler targeting 16-bit 80186 MS-DOS on the HP 200LX palmtop.

---

## 1. The 80186 Target Constraints

The HP 200LX runs an **Intel Hornet 80186 ASIC** at 7.91 MHz:
- **16-Bit Real Mode Only:** No 32-bit registers and no 386 protected mode.
- **64 KiB Segment Limit:** Each code/data segment (`CS`, `DS`, `ES`, `SS`) addresses 65,536 bytes; multi-bank Game Boy code must be split across segments.
- **No Traditional Emulator Budget:** Fetching, decoding, and updating virtual registers in software leaves only a handful of FPS at 7.91 MHz.

**Approach:** Static SM83-to-80186 translation, physical register pinning, multi-segment far trampolines, dirty-cached strip rendering to CGA Mode 04h, and 59.73 Hz PIT interrupt pacing.

---

## 2. Register Pinning Strategy

Only four 80186 registers (`AX`, `BX`, `CX`, `DX`) can be split into high/low 8-bit halves, while `SI`, `DI`, `BP`, and `SP` are 16-bit only. Mapping `HL` to `CX` (`CH`/`CL`) avoids bit-shifting on every 8-bit `H`/`L` instruction while keeping `SI` ready for 1-instruction `(HL)` dereferencing (`mov si, cx`):

| SM83 Register | 80186 Register | High Half | Low Half | Purpose |
| :---: | :---: | :---: | :---: | :--- |
| **`A`** | **`AL`** | — | `AL` (`A`) | Accumulator (`AH` is scratch for flags/helpers) |
| **`BC`** | **`BX`** | `BH` (`B`) | `BL` (`C`) | 8-bit counters & 16-bit base |
| **`DE`** | **`DX`** | `DH` (`D`) | `DL` (`E`) | 8-bit data & 16-bit displacement |
| **`HL`** | **`CX`** | `CH` (`H`) | `CL` (`L`) | Fast 8-bit `H`/`L` and 16-bit `HL` ops |
| **`(HL)` / Scratch** | **`SI`** | — | — | Loaded on demand before `[si]` access |
| **`SP`** | **`DI`** | — | — | Game Boy stack inside `DS` (`lea di, [di +/- 2]`) |
| **MMIO / Scratch** | **`BP`** | — | — | Target address for helpers; note `[ds:bp]` required since `[bp]` defaults to `SS` |
| **Hardware `SP`** | **`SP`** | — | — | Strictly reserved for native 80186 `CALL`/`RET` and PC IRQs |
| **Memory Base** | **`DS`** | — | — | Pinned to dedicated 64 KiB Game Boy memory block (`gb_mem_seg`) |

---

## 3. Instruction Lowering & Flag Semantics

In [codegen_80186/recompiler_80186.py](codegen_80186/recompiler_80186.py):
- **Flag Preservation:**
  - `INC`/`DEC rr` preserves `ZF` and `CF`: uses `lea` for `BX`/`DI` and `lahf`/`sahf` for `CX`/`DX`.
  - `PUSH`/`POP rr`, `CALL`, and `RET` update `DI` with `lea di, [di +/- 2]` so hardware flags survive calls and returns.
  - `ADD HL, rr` preserves `ZF` while updating `CF` (`lahf; and ah, 0FEh; add cx, rr; adc ah, 0; sahf`).
  - `BIT b, r` preserves `CF` while updating `ZF` (`lahf; test ...; rcr ah, 1`).
  - CB-prefixed rotates (`RLC`, `RRC`, `RL`, `RR`) update both `CF` and `ZF`.
  - `LDI`/`LDD` advance `HL` via `lea cx, [si +/- 1]` so flags are untouched.
- **Decimal Adjust (`DAA` / `DAS`):** The translator tracks `last_alu_sub` across `ADD`/`ADC`/`INC A` vs. `SUB`/`SBC`/`DEC A`, emitting x86 `das` after subtractions and `daa` after additions.
- **Conservative Flag-Liveness Optimization:** `flags_dead_after()` in [tools/build_rom.py](tools/build_rom.py) scans straight-line instructions ahead (up to 16 instructions, stopping at any branch target, control transfer, or flag reader). If a full flag redefinition (`ADD`, `SUB`, `AND`, `OR`, `XOR`, `CP`, shifts, `POP AF`) is guaranteed before any flag read, the preceding `lahf`/`sahf` or `rcr ah, 1` flag-fixup sequence is omitted.
- **Native `PUSH AF` / `POP AF`:** `helper_push_af` and `helper_pop_af` pack/unpack SM83 flags `Z N H C` (`F` bits 7..4) to/from 80186 `FLAGS`.

---

## 4. Control-Flow Discovery & Multi-Segment Build

[tools/build_rom.py](tools/build_rom.py) performs recursive control-flow recovery across up to 4 × 16 KiB ROM banks before disassembly/emission:
- **Seed Sources:**
  - Cartridge entry (`0x0100`) and interrupt vectors (`0x0040`, `0x0048`, `0x0050`, `0x0058`, `0x0060`) plus reachable `RST` vectors.
  - Optional RGBDS/`mgbdis` `.sym` (`--sym`) and Mesen2 `.cdl` (`--cdl`) seeds (also auto-detected alongside the ROM by stem).
  - Automatic detection of `RST` jump-table dispatchers (e.g., `RST 0x28`), inline `JP (HL)` word tables, synthetic `LD rr, imm16; PUSH rr` return-address idioms, and HRAM OAM-DMA copy routines (re-routed to native `helper_dma_transfer`).
  - Automatic `helper_halt` yield insertion on 3-instruction `LDH/LD A, (RAM); AND/OR A, A; JR Z, start` busy-wait spin loops.
- **Label Resynchronization:** Any instruction that would overlap an interior branch target is split into raw bytes (`db`) so disassembly stays aligned at every discovered entry point.
- **Two-Pass Relocation-Free Segmentation:**
  1. **Bank 0 (`seg0`):** Holds `crt0_rom.asm`, `video_cga.asm`, `config_ini.asm`, `sound_spk.asm`, `savestate.asm`, `pause_menu.asm`, `recomp_helpers.asm`, recompiled Bank 0 code, `b0_helper_table` at fixed offsets `0004h..0020h`, and `b0_entry_table` starting at `0024h`.
  2. **Banks 1–3 (`seg1..seg3`):** Each bank is assembled with `org 0`, starting with a `dispatch_bN` jump table (4 bytes per entry).
  3. **Pass 1 / Pass 2:** Pass 1 measures exact segment paragraph sizes (`SEG1_PARAS_VAL`, `SEG2_PARAS_VAL`, `SEG3_PARAS_VAL`, `SEG_ROM_PARAS_VAL`), then Pass 2 re-assembles with exact segment deltas and packs `build/GAME.BIN` -> `build/GAME.EXE` via [tools/mzpack.py](tools/mzpack.py).

---

## 5. Memory Map & Runtime Routing

`tools/mzpack.py` reserves `gb_ram_paras = 0x1200` (72 KiB) right after the embedded ROM image:
- `gb_mem_seg` (`64 KiB`): Game Boy virtual address space `0x0000..0xFFFF` pinned in `DS`.
- `backbuffer_seg` (`gb_mem_seg + 1000h`, `8 KiB`): Offscreen `160×144` CGA compositing buffer (`5760` bytes used).

```
0x0000 - 0x3FFF : ROM Bank 00
0x4000 - 0x7FFF : Switchable ROM Bank 01..03 (updated via helper_write_mbc)
0x8000 - 0x97FF : VRAM Tile Data (writes through helpers flag tile_dirty[0..383])
0x9800 - 0x9FFF : VRAM Tile Maps
0xA000 - 0xFDFF : External RAM / WRAM / Echo RAM
0xFE00 - 0xFE9F : OAM Sprite Attribute Table
0xFF00 - 0xFF7F : MMIO Registers (JOYP, DIV, LY, DMA, BGP, LCDC, SCY/SCX, etc.)
0xFF80 - 0xFFFE : High RAM (HRAM)
0xFFFF          : Interrupt Enable (IE)
```

- **Direct Static Writes:** Constant writes to WRAM/HRAM compile directly to `mov [0NNNNh], al`; constant MMIO writes call `helper_write_mmio`, `helper_update_bgp`, `helper_dma_transfer`, or `helper_write_mbc`.
- **Dynamic Pointer Writes (`helper_write_hl/bc/de`):** A fast path checks `(addr - 0xA000) < 0x5E00` using `lahf`/`sahf` (no `pushf`/`popf`) and writes straight to RAM (`0xA000..0xFDFF`), falling back to MBC/VRAM-dirty/MMIO handling only outside that range.

---

## 6. CGA Mode 04h PPU Pipeline

Implemented in [runtime/video_cga.asm](runtime/video_cga.asm):
1. **Nibble Palette LUT & Dirty Tile Cache:**
   - On `BGP` (`0xFF47`) changes, `helper_update_bgp` rebuilds `dmg_cga_nibble_table` (256 bytes) and marks all 384 VRAM tiles dirty.
   - `update_cga_tile_cache` scans `tile_dirty[384]` (`repe scasb`) and pre-decodes only modified tiles into `CS:cga_tile_cache` (6,144 bytes = 384 × 8 rows × 2 CGA bytes).
2. **8-Line Strip Rendering & `STAT` `LYC` Split:**
   - Precomputes `render_split_limit` (`LYC + 1` when `IE` bit 1 and `0 < LYC < 144` are enabled) to preserve split-scroll HUDs (using `hud_scy`/`hud_scx` captured right after VBlank).
   - Processes Background in strips of `1..8` scanlines that never cross a tile row (`(Y + SCY) & 7`) or `render_split_limit`.
   - When `SCX & 7 == 0`, `render_aligned_strip` looks up each tile once per strip and copies all strip rows straight into `backbuffer_seg`.
   - When `SCX & 7 != 0`, 21 tiles × strip height are written into `CS:cga_strip_buf` (stride 44) once per strip, then fast-copied (`rep movsw` for `fine_x == 4`) or shifted with `DS = CS` (`lodsb`/`lodsw`/`stosw`).
3. **Window Layer:** Uses `render_aligned_strip` with `cga_tile_cache` from `WY`/`WX` downward.
4. **OAM Sprites (40 entries, 8×8 or 8×16):**
   - Rendered back-to-front (`39 -> 0`) with precomputed 3-shade palette per visible sprite, immediate empty-row skipping (`test ax, ax; jz`), `shl`/`shr` + `adc` pixel extraction, table-driven CGA masking, and OAM attribute bit 7 (OBJ-behind-BG-colors-1..3).
5. **Backbuffer Blit & Palette Sync:** Optionally polls `0x03DA` bit 3 (`cfg_vsync = 1`, bounded 4,000-iteration timeout), then copies the 144 composited 40-byte scanlines from `backbuffer_seg` to interleaved CGA VRAM `0xB800` via `cga_scanline_offsets`—either 1:1 `rep movsw` (`SCALE_CENTER`, `160×144`) or 2× horizontally stretched via the 512-byte `cga_wide_table` (`SCALE_WIDE`, `320×144`). `cga_sync_hw_palette` programs BIOS `INT 10h AH=0Bh` (CGA Palette `0` for `pocket`/`dmg` vs Palette `1` for `high_con`/`dark`), and `cga_clear_screen` clears surrounding borders to `cfg_shade0`.

---

## 7. Frame Pacing & Keyboard Input

- **59.73 Hz Frame Clock (`runtime/crt0_rom.asm` & `runtime/recomp_helpers.asm`):**
  - `hook_int08` reprograms PIT channel 0 to divisor `19977` (`1193182 / 19977 ≈ 59.73 Hz`), incrementing `frame_ticks` on each tick and chaining the original BIOS `INT 08h` handler at the average 18.2 Hz overflow rate so the DOS clock stays accurate. Original PIT divisor and `INT 08h` vector are restored on exit.
  - `helper_halt` sleeps with `sti; hlt` when ahead of schedule, enforces `1` Game Boy logic frame + VBlank/STAT/Timer ISR dispatch per tick, and skips `cga_render_gb_frame` when `frame_ticks > 0` up to `MAX_FRAME_SKIP` (`3`) consecutive frames (dropping excess ticks past `MAX_FRAME_BACKLOG = 6`).
- **Low-Latency Input (`int09_handler` & `helper_read_joyp`):**
  - Intercepts IRQ1 scancodes (`in al, 60h`), acknowledges `0xE0` extended prefixes cleanly so arrow keys work reliably, triggers `F5`/`F9` save-state flags and `ESC`/`cfg_key_menu` pause requests, and updates live `joypad_dir`/`joypad_act` bitmasks plus per-frame `joypad_dir_latch`/`joypad_act_latch` bytes (reset in `helper_halt`). While `menu_active = 1`, IRQ1 chains directly to `old_int09` so BIOS `INT 16h` serves the pause menu natively.

---

## 8. PC Speaker APU Synthesis

Implemented in [runtime/sound_spk.asm](runtime/sound_spk.asm):
- **Register Hook (`apu_write_reg`):** `helper_write_mmio` forwards writes in `0xFF10..0xFF26` to track triggers, length counters, DAC enables, frequency updates, and `NR52` master mute.
- **Per-Frame Sequencer (`apu_frame_tick`):** Runs once per 59.73 Hz frame at the end of `helper_halt` (after VBlank/Timer sound drivers finish), stepping 256 Hz length counters (4 ticks/frame), 64 Hz volume envelopes (1 tick/frame), and Ch1 128 Hz frequency sweep (2 ticks/frame, including overflow mute).
- **Voice Arbitration & Glitch-Free PIT Output:** Picks the active voice among Ch1 and Ch2 (higher volume, breaking ties by most recently triggered channel), falling back to Ch3 Wave when both square channels are silent. Converts the 11-bit Game Boy period via `((2048 - F) * 2330) >> 8` (doubled for Ch3) and programs PIT Channel 2 (`0x42`/`0x43`/`0x61`), skipping mode resets when the divisor is unchanged and muting cleanly in `game_clean_exit`.

---

## 9. Save States & In-Game Pause Menu

- **Save States ([runtime/savestate.asm](runtime/savestate.asm)):**
  - `savestate_save` (and `savestate_save_from_pause`, using `halt_sp_base` captured in `helper_halt`) writes `GBSTATE0.SAV` via DOS `INT 21h`: a 64-byte header (`GB200ST1` magic, `0x014E..0x014F` ROM checksum, `CS`, `SP`, stack byte length, `gb_ime`, `current_rom_bank`, `emulated_ly`, `div_counter`, `hud_scy`/`hud_scx`, and APU state `apu_state_start..apu_state_end`), the active hardware stack slice `SS:[halt_sp..8000h)`, and all 64 KiB of `gb_mem_seg`.
  - `savestate_load` validates the magic, ROM checksum, and stack bounds via `savestate_open_valid`, reloads stack and `gb_mem_seg`, relocates any `CS`/`seg_bank*`/`gb_mem_seg`/`backbuffer_seg` words on the restored stack if DOS loaded at a different paragraph, resets `last_bgp` and all 384 `tile_dirty` entries, and jumps to `helper_halt.do_render`.
- **ESC Pause Menu ([runtime/pause_menu.asm](runtime/pause_menu.asm)):**
  - Triggered from `helper_halt` when `menu_requested == 1`, muting PIT Ch2 and drawing a centered CGA Mode `04h` overlay (`y=23..176`, covering the Game Boy viewport) using BIOS `INT 10h` text output (`Resume Game`, `Save State`, `Load State`, `Options`, `Quit`).
  - The **Options** submenu adjusts every `[video]` (`scaling`, `palette`, `vsync`, `sound`) and `[input]` (`key_up`..`key_menu`) setting in place, persists changes via `cfg_save_ini` in [runtime/config_ini.asm](runtime/config_ini.asm), and reapplies CGA palette, border, and tile-cache state cleanly on resume.
