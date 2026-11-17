# Dynamic Banking (> 64 KiB) Investigation, Findings & Roadmap

This document serves as the comprehensive engineering record of the dynamic bank switching / overlay system in **GB200LX** on the `feat/dynamic-bank-switching` branch. It details the issues reported by users, root causes identified through low-level tracing, what was attempted, what failed, what succeeded, and actionable next steps for future work.

---

## 1. Executive Summary & Status Matrix

| Title / Feature | Initial Behavior | Root Cause | Status | Key Fix / Finding |
| :--- | :--- | :--- | :--- | :--- |
| **Zelda: Link's Awakening (512 KiB)** | In-game, fast, music plays, but **no NPCs (Marin, Tarin), no animals, cannot pick up items/plants**. | Entity dispatch via `03:490A` (`EntityUpdate`) failed static CFG recovery: paired table `03:4000` + `00:3953`, dummy jump-table slot (`03:4D1e: STOP`), unindexed `(HL)` bank switches, and unexposed Pass 2 labels. | **RESOLVED & VERIFIED** | Slot-isolated jump-table validation in `build_rom.py`, paired bank+ptr table seeding, `LD (HL)` bank write tracking, and Pass 2 label exposure. Marin and Tarin visible with full dialogue. |
| **Pokémon Blue (1 MiB)** | Game intro runs; pressing `Start` on title screen **freezes with a continuous audio whine**. | Polling loops in `00:3AD9..00:3AFF` (`HandleMenuInput_`) and `01:5BBA..01:5BCF` lack `HALT`. Interrupts disabled (`IF=0`), starving PIT `INT 08h` frame pacing and hanging the recompiler. | **FREEZE RESOLVED; RENDER BLOCKED** | Back-edge yield via `helper_yield_if_ticks` (`002Eh`/`0028h`) unstuck execution. Menu now runs, but Window text tiles are blank due to deferred VBlank font DMA (`H_VBCOPYDOUBLESIZE`). |
| **Final Fantasy Legend III (256 KiB)** | Menu text invisible until key press; starting New Game **bugs out showing enemies on screen and nothing else**. | 1) Text invisible: BGP palette fade-in or deferred VBlank tile copy. 2) Enemy bug: untyped dynamic dispatch / jump-table miss entering battle/cutscene engine. | **DIAGNOSTIC READY** | Telemetry hooks (`MISSES.BIN`) integrated to capture exact bank, address, and miss tag upon menu start. |
| **Cartridge Battery SRAM Persistence** | In-game saves (`0xA000..0xBFFF`) work during the session via Save States, but **standard game saves do not persist across restarts**. | Cartridge SRAM was emulated in RAM (`sram_seg`) and swapped across banks, but was never written to a `.SAV` file on exit or loaded on startup. | **DESIGNED / READY FOR IMPL** | Architecture specified for `CARTRAM.SAV` read in `crt0_rom.asm` and write in `game_clean_exit` / pause menu for battery cart types. |
| **Default Palette** | `pocket` palette default was not optimal for HP 200LX hardware contrast. | User requested `dark` palette as default for superior LCD legibility. | **RESOLVED & VERIFIED** | Changed default to `dark` in `GB200LX.INI`, `runtime/config_ini.asm`, and documentation. |

---

## 2. Issue 1: Zelda Link's Awakening — Missing NPCs & Entities

### 2.1 The Symptom
The game booted, ran smoothly at 60 FPS with music, and allowed Link to move, enter houses, and open maps. However:
- Marin and Tarin were completely missing from Marin's house.
- No outdoor animals or enemies spawned.
- Link could not interact with objects (e.g. could not pick up pots/bushes).

### 2.2 Deep Dive & Root Cause
Link's Awakening handles NPC and object logic through `03:490A` (`EntityUpdate`) in Bank 03:
1. **Paired Bank + Pointer Table:**
   - Entity types index into a 256-byte table at `03:4000` holding ROM bank numbers for each entity.
   - Pointers to the entity handlers reside in a paired table in Bank 0 at `00:3953`.
   - The original static CFG harvester only recognized single contiguous pointer tables within the active bank; it did not associate a Bank 03 bank ID table with a Bank 00 pointer table.
2. **Jump-Table Poisoning from Dummy/Data Slots:**
   - Bank 03 entity handlers use inline jump tables.
   - One entry (`03:4D1E`) pointed to raw non-code data (`STOP` instruction / illegal bytes).
   - In `tools/build_rom.py`, `trace_bank_subgraph` had an "all-or-nothing" rule: if *any* table target failed validation, the entire table and function were rejected, causing `03:490A` (and all 126 entity subroutines) to be completely dropped from the recompiled bank!
3. **Indirect Bank-Switching Idioms (`LD (HL), A` / `LD (HL), imm`):**
   - Bank 0 helper functions switch banks via `LD HL, 0x2xxx; LD (HL), 0xNN` (e.g. `00:3E8A` -> `02:61E7`, `00:3E95` -> `03:6497`).
   - The recompiler's CFG analysis only tracked direct `LD (0x2xxx), A` writes, missing indirect bank switches through `HL`.
4. **Pass 2 Label Export Omission:**
   - Targets such as `02:780F` were visited during traversal (`bank_vis[2]`), but were not formally added to `bank_labels[2]`, resulting in unresolved dynamic overlay calls.

### 2.3 What Was Attempted That Didn't Work
- **Pure speculative code harvesting across all banks:** Disassembling every 2-byte aligned address in Bank 03 produced massive bloat (>100 KiB of phantom code per bank), exceeding the 64 KiB conventional memory cache limit and crashing `overlay.asm` with memory allocation exhaustion.
- **Naively ignoring jump-table failures:** Allowing bad jump-table slots to emit recompiled code caused invalid x86 instructions to be generated, crashing DOSBox-X with CPU faults.

### 2.4 What Worked (The Permanent Solution)
In `tools/build_rom.py`:
1. **Per-Slot Table Validation:**
   In `trace_bank_subgraph` and `pending_tables`, table targets are evaluated per-slot `(tbl_start, True)`. A dummy or invalid slot is skipped without invalidating the parent function or the rest of the jump table.
2. **Paired Bank+Pointer Table Seeding:**
   In `harvest_exact_bank_calls`:
   ```python
   # Detect paired (bank_table_in_active_bk, ptr_table_in_b0)
   # e.g., Zelda 03:4000 (banks) paired with 00:3953 (RST 28 pointers)
   ```
   Matches bank entries in `03:4000..03:40FF` with pointers in `00:3953..00:3A52`, validating each target and registering it directly into `exact_bn_seeds[b]`.
3. **Indirect Bank-Switch Detection:**
   Tracked `LD HL, 0x2xxx` followed by `LD (HL), imm8` or `LD (HL), A` to correctly associate bank-switching wrappers in Bank 00 with caller banks (`b0_caller_bks`).
4. **Pass 2 Speculative Candidate Export:**
   If a target `t` is already in `bank_vis[b]`, ensure it is explicitly added to `bank_labels[b]`.

### 2.5 Verification
- Recompiled `Legend of Zelda, The - Link's Awakening (USA, Europe).gb`.
- Ran headless automated test past Marin's house dialog.
- Inspected framebuffer capture (`/tmp/z_fixed2.png`):
  - **Link, Marin, and Tarin are all rendered on screen simultaneously.**
  - **Tarin's dialog window ("What a relief! I thought you'd...") displays crisp text and full border graphics.**
  - Label verification confirmed `03:490A`, `02:61E7`, and `03:6497` all resolved cleanly as defined labels with zero runtime misses.

---

## 3. Issue 2: Pokémon Blue — Start Freeze & Blank Menu Screen

### 3.1 The Symptom
- The Game Freak intro star and Nidorino vs. Gengar battle run with full audio and animation.
- The title screen ("Pokémon Blue Version", "PRESS START") displays correctly.
- Pressing `Start` immediately froze the emulator with a continuous stuck speaker tone.

### 3.2 Deep Dive & Root Cause: The Freeze
Using the `MISSES.BIN` diagnostic telemetry and watchdog aborts:
1. **Interrupt Starvation in Polling Loops:**
   - Pressing `Start` enters Bank 01 `loc_01_5b5f` -> `loc_01_5bba` (`MainMenu`), which calls `00:3AD9..00:3AFF` (`HandleMenuInput_`).
   - `HandleMenuInput_` loops reading `Joypad` (`00:019A` -> Bank 03 `03:4000`).
   - **Crucially: these loops contain zero `HALT` instructions.**
   - In native Game Boy hardware, interrupts fire asynchronously during tight loops. In GB200LX, execution only yields to frame pacing, keyboard handling, and ISR dispatch inside `helper_halt`.
   - Without `HALT`, execution spun in an infinite tight loop. Because x86 `IF = 0` (interrupts disabled) occurred during certain flag-heavy helper routines, the PIT `INT 08h` timer stopped accumulating `frame_ticks`, freezing the game forever while the PC speaker tone remained latched on PIT Ch2.
2. **Loop Detector Limitations:**
   - The recompiler already had an automatic `helper_halt` inserter for pure-WRAM spin-wait loops (`JR Z`, `JR NZ`).
   - However, that detector was restricted to loops `len <= 24` bytes that made no calls and accessed only WRAM/HRAM. `HandleMenuInput_` is 38 bytes and calls subroutines, so it was completely ignored.

### 3.3 What Was Attempted That Didn't Work (Freeze)
- **Increasing `MAX_FRAME_BACKLOG`:** Did not help because `frame_ticks` was never being incremented; the timer IRQ itself was blocked by the tight spin loop.
- **Inserting `helper_halt` into all backwards jumps:** Caused devastating performance degradation (~5 FPS) because tight data-copy loops (e.g. `memcpy`, tile clearing) yielded on every iteration.

### 3.4 What Worked: `helper_yield_if_ticks`
1. **Lightweight Back-Edge Yield Check:**
   Created `helper_yield_if_ticks` in `runtime/recomp_helpers.asm`:
   ```asm
   global helper_yield_if_ticks
   helper_yield_if_ticks:
       sti
       pushf
       cmp     word [cs:frame_ticks], 2    ; Only yield if >= 2 ticks behind schedule (~33 ms)
       jb      short .hy_no
       cmp     byte [cs:in_halt_isr], 0    ; Guard against re-entrant ISR recursion
       jne     short .hy_no
       popf
       jmp     near helper_halt
   .hy_no:
       popf
       ret
   ```
2. **Fixed Bridge Offset in Segment 0:**
   Exposed `helper_yield_if_ticks` at fixed offset `002Eh` (overlay mode) / `0028h` (non-overlay) in Segment 0, so any recompiled bank can call it without far-call overhead.
3. **Compiler Emission Rule:**
   In `tools/build_rom.py`, any backwards branch where `0 < curr - target <= 64` that contains **no `HALT` instruction** automatically emits `call helper_yield_if_ticks`.
   - Fast loops (under 33 ms) execute with zero latency (a simple `cmp` + `jb`).
   - Polling loops that stall for multiple frames immediately yield to `helper_halt`, dispatch VBlank/Timer ISRs, poll keys, and pace the display.
4. **Result:** The freeze was completely eliminated! Pokémon Blue advanced past the Start screen, running 1650+ frames at full 60 FPS without hanging.

---

### 3.5 Deep Dive: The Subsequent Blank Menu Screen
Once the freeze was resolved, pressing `Start` caused the screen to clear to black with a white dialog border box (`/tmp/pkmn_sti3.png`), but the menu text (`NEW GAME`, `OPTION`) was not visible.

Using VRAM and register dumps at frame 1650:
- `FF40 = 0xE3` (LCD ON, BG ON, OBJ ON, Window ON, Unsigned Tile Data at `0x8000`, BG map at `0x9800`, Window map at `0x9C00`).
- `FF47 = 0xE4` (BGP = `11 10 01 00b`, normal DMG palette).
- `FF4A = 0x00, FF4B = 0x07` (`WY = 0, WX = 7`, meaning the Window layer covers the entire 160×144 screen).
- `0x9C42 = 0x848D` (The Window tilemap *does* contain the correct text tile indices: `0x84`, `0x8D`, etc.).
- `0x88D0 = 0x0000` (The VRAM tile pattern data for font tiles at `0x8800..0x97FF` is completely zeroed out!).

#### Root Cause of Empty Font VRAM:
1. In Pokémon Blue, `LoadFontTilePatterns` (`00:3680`) loads font graphics into VRAM.
2. Because the LCD is turned on (`FF40 bit 7 = 1`), `00:3680` takes branch `00:3694` (`CopyVideoDataDouble`).
3. `CopyVideoDataDouble` does **not** copy font tiles synchronously! Instead, it sets `[0FFCBh]` (`H_VBCOPYDOUBLESIZE`) and waits for VBlank interrupts to copy 8 tiles per frame during `00:1E02`.
4. In `runtime/recomp_helpers.asm`, VBlank ISR (`00:0040`) is triggered by `helper_halt` only when `[0FFFFh] & [0FF0Fh] & 1` is true.
5. In addition, `00:18A2` calls `00:20AF` (`DelayFrame`), which spins waiting for `0FFBAh` (`hVBlankOccurred`).
6. Because `0FFBAh` was not being updated correctly or interrupt flags were cleared out of sequence during `helper_halt`, the deferred VBlank DMA transfer either starved or terminated prematurely, leaving the VRAM font tile area empty (`0x0000`).

---

## 4. Issue 3: Final Fantasy Legend III — Invisible Text & Enemy Screen

### 4.1 The Symptoms
1. **Title Menu Text:** The menu appears, but all text labels are invisible until a key is pressed.
2. **New Game Bug:** Starting a new game transitions to a corrupted screen showing random enemy sprites and freezes or fails to start gameplay.

### 4.2 Hypothesized Root Causes
1. **Palette Fade-In vs. VBlank Timing:**
   Many Square titles (FFL2, FFL3, FFA) implement fade-in effects by modifying `BGP` (`0xFF47`) inside the VBlank interrupt handler. In GB200LX, `helper_update_bgp` is only called when an explicit write to `0xFF47` is intercepted. If the game modifies the palette in RAM and writes it to `0xFF47` via `(HL)` or expects a VBlank interrupt that has not fired yet, the screen remains at shade 0 (all white) or shade 3 (all black) until user input forces a redraw.
2. **Jump-Table / Cross-Bank Dispatch Miss:**
   Starting a new game executes a major bank switch into the intro cutscene and battle engine. If an entry point was reached via `JP (HL)` or `RST` where the destination was not in `bank_labels` or `exact_bn_seeds`, execution falls through to `.b0_miss` or `.ocb_miss`.
3. **Telemetry Integration:**
   `crt0_rom.asm` and `overlay.asm` now log any dispatch miss directly into `MISSES.BIN` (tags `0x01` = `ocb_miss`, `0x02` = `b0_miss`, `0x03` = `jp_b0_miss`). Running FFL3 under test mode will pinpoint the exact bank and target address responsible.

---

## 5. Issue 4: Battery-Backed Cartridge SRAM Persistence (`.SAV`)

### 5.1 The Requirement
Games with battery-backed RAM (Zelda, Pokémon Blue, FFA) allow saving progress to cartridge SRAM (`0xA000..0xBFFF`). While GB200LX supports Save States (`F5`/`F9`), in-game saves are lost when quitting to DOS.

### 5.2 Technical Specification & Design

#### Cartridge Detection (`tools/build_rom.py`):
- Cartridge types with battery:
  - `0x03` (MBC1+RAM+BATTERY)
  - `0x06` (MBC2+BATTERY)
  - `0x09` (ROM+RAM+BATTERY)
  - `0x0D` (MMM01+RAM+BATTERY)
  - `0x0F` (MBC3+TIMER+BATTERY)
  - `0x10` (MBC3+TIMER+RAM+BATTERY)
  - `0x13` (MBC3+RAM+BATTERY)
  - `0x1B` (MBC5+RAM+BATTERY)
  - `0x1E` (MBC5+RUMBLE+RAM+BATTERY)
- RAM sizes from cartridge header byte `0x0149`:
  - `0x00`: None (or 512×4 bits for MBC2 = 256 bytes)
  - `0x01`: 2 KiB (1 bank)
  - `0x02`: 8 KiB (1 bank)
  - `0x03`: 32 KiB (4 banks of 8 KiB)
  - `0x04`: 128 KiB (16 banks of 8 KiB)
- `build_rom.py` emits:
  ```asm
  %define BATTERY_SAV 1
  %define CART_SAV_BYTES 32768
  ```

#### Memory Layout:
- In overlay mode, `sram_seg` already holds all cartridge RAM banks in conventional DOS memory.
- Active SRAM bank is mapped at `gb_mem_seg:0xA000..0xBFFF`.

#### File Persistence (`runtime/crt0_rom.asm` & `runtime/overlay.asm`):
1. **Startup (`init_sram`):**
   - Check if `CARTRAM.SAV` exists in current directory via DOS `INT 21h AH=3Dh` (Open File).
   - If present: read `CART_SAV_BYTES` directly into `sram_seg:0000h`, then copy bank 0 into `gb_mem_seg:0xA000..0xBFFF`.
   - If missing: fill `sram_seg` and `gb_mem_seg:0xA000..0xBFFF` with `00h`.
2. **Clean Exit (`game_clean_exit`) & Pause Menu ("Quit" / "Save State"):**
   - Copy active `gb_mem_seg:0xA000..0xBFFF` back to the current bank offset in `sram_seg`.
   - Write `CART_SAV_BYTES` from `sram_seg:0000h` to `CARTRAM.SAV` via DOS `INT 21h AH=3Ch` (Create/Truncate) + `AH=40h` (Write).

---

## 6. Issue 5: Default Palette Changed to `dark`

### 6.1 Rationale
The HP 200LX uses a transflective 320×200 CGA LCD without a built-in backlight. On this display, bright white backgrounds tend to wash out, whereas dark-mode palettes (black background with light gray/white text and sprites) offer vastly superior contrast and readability under ambient light.

### 6.2 Code Changes Applied
1. **`GB200LX.INI`:** Set `palette = dark`.
2. **`runtime/config_ini.asm`:**
   - Line 61 (`cfg_set_defaults`): `mov byte [cfg_palette], PAL_DARK`.
   - Line 1056: `cfg_palette: db PAL_DARK`.
3. **`docs/CONFIGURATION.md` & `README.md`:** Documented `dark` as the factory default preset.

---

## 7. Diagnostic & Telemetry Infrastructure

To prevent future sessions from running blind, the following diagnostic facilities are permanently in place:

### 7.1 `MISSES.BIN` Telemetry Buffer
`runtime/crt0_rom.asm` and `runtime/overlay.asm` record up to 64 entries of dynamic misses and runtime snapshots into `MISSES.BIN` upon exit:
- `tag = 0x01`: `ocb_miss` in `overlay.asm` (`addr = target`, `extra = caller`).
- `tag = 0x02`: `.b0_miss` in `build_rom.py` (Bank 0 entry-point miss).
- `tag = 0x03`: `.jp_b0_miss` / `helper_jp_hl_miss_abort` in `build_rom.py` (`JP (HL)` miss in Bank 0 or Bank `b`: `addr = target CX`, `extra = [di]`).
- `tag = 0x06`: `int06_handler` in `crt0_rom.asm` (CPU Invalid Opcode exception: `0600h|bank` logs `IP, CS`; `0601h` logs `[CS:IP]` opcode word and `DI`).
- `tag = 0xFA`: Snapshot of `(FF40, FF47)` (LCDC, BGP).
- `tag = 0xFB`: Snapshot of `(FF42, FFBA)` (SCY, hVBlankOccurred).
- `tag = 0xFC`: Snapshot of `(9842h, C3E2h)` (BG tile, WRAM state).
- `tag = 0xFD`: Snapshot of `(last_ovl_bk, last_ovl_bp)` (last executed overlay bank & address).
- `tag = 0xFE`: Snapshot of `(FF4Ah, 97F0h)` (WY, VRAM font sample).
- `tag = 0xFF`: Snapshot of `(88D0h, cga_tile_cache[08D0h])`.

### 7.2 Headless Test Harness (`runtest.py`)
Located at `<appDataDir>/brain/<conversation-id>/scratch/runtest.py`:
- Launches DOSBox-X with `--cga`, executes `GAME.EXE /t`, monitors execution with a timeout, dumps CGA VRAM, generates a PNG image, and inspects `MISSES.BIN`.
- Can be invoked from terminal:
  ```bash
  python3 <appDataDir>/brain/<id>/scratch/runtest.py /tmp/output.png 30
  ```

---

## 8. Actionable Next Steps (Roadmap)

When picking up this work, execute these steps in order:

### Step 1: Pokémon Blue VBlank Font Tile DMA Transfer
1. Inspect `build/rom/code_b0.asm` at `loc_00_1e02` (VBlank tile copy) and `loc_00_20af` (`DelayFrame`).
2. Verify why `0FFCBh` (`H_VBCOPYDOUBLESIZE`) is not draining font tiles into `0x8800..0x97FF`:
   - Check if `helper_halt` properly sets `[0FFBAh] = 1` during VBlank dispatch.
   - Check if `loc_00_0040` (VBlank vector) is called when `0FFCBh != 0`.
3. Once font tiles are populated in `0x8800`, verify that `/tmp/pkmn_menu_ok.png` displays `CONTINUE / NEW GAME / OPTION` with full text.

### Step 2: Final Fantasy Legend III Menu Text & Intro Bug
1. Rebuild FFL3 with test mode enabled:
   ```bash
   make ROM="/Users/arnovan/Downloads/HP 200lx/GB/Final Fantasy Legend III (USA).gb"
   ```
2. Run `runtest.py` and inspect `MISSES.BIN`.
3. If `tag = 0x01` (`ocb_miss`) or `tag = 0x02` (`b0_miss`) appears, locate the missing target address and add it to `discover_control_flow` in `tools/build_rom.py`.
4. Check if palette fade-in writes directly to `[0FF47h]` without invoking `helper_update_bgp`.

### Step 3: Implement Battery-Backed Cartridge `.SAV` File I/O
1. In `tools/build_rom.py`, write `BATTERY_SAV` and `CART_SAV_BYTES` into `build/rom/config.inc`.
2. In `runtime/crt0_rom.asm`:
   - In `init_sram`, add DOS `INT 21h AH=3Dh` to load `CARTRAM.SAV` into `sram_seg`.
   - In `game_clean_exit`, add DOS `INT 21h AH=3Ch/40h` to save `sram_seg` to `CARTRAM.SAV`.
3. In `runtime/pause_menu.asm`, ensure quitting from the menu also flushes `sram_seg`.
4. Test with Zelda: create a save file in slot 1 -> exit -> restart -> verify file persists.

### Step 4: Bubble Ghost Candle Blow-Out (`INT 06h` / `JP (HL)` Investigation)
1. **Symptoms Observed:**
   - Running `Bubble Ghost (USA, Europe).gb` (32 KiB ROM-only, padded to 4 banks, standalone non-overlay mode) and blowing out the candle crashed DOSBox-X with `LOG: ERROR CPU:Illegal Unhandled Interrupt Called 6` (x86 Invalid Opcode exception).
2. **Root Causes Found:**
   - **Missing `INT 06h` Handler:** `runtime/crt0_rom.asm` did not hook `INT 06h`, so any invalid-opcode fault terminated DOSBox-X without diagnostics.
   - **Unsafe `helper_dispatch_jp_hl` Fallthrough (`tools/build_rom.py`):** `JP (HL)` is emitted as `jmp near helper_dispatch_jp_hl` (a jump, not a call), yet both Bank 0 and Bank `b` `helper_dispatch_jp_hl` ended with `lea di, [di + 2]; ret`. Any unmatched `CX` executed `ret` on an unpushed x86 stack, jumping into arbitrary memory and triggering `INT 06h`.
   - **Control-Flow / Indirect Jump Sites in Bubble Ghost:**
     - `0x055D`: `RST 0x00` inline jump-table dispatcher (`POP HL; ...; JP (HL)`).
     - `0x242D`: Object handler dispatcher via `Table 0x23DF` (slots 1..17, including candle handler `0x25C3` at slot 15) using `LD BC, 0x242E; PUSH BC; JP (HL)`.
     - `0x322C`: Room state handler via `Table 0x31D3` (slots 0..5: `0x322D..0x32ED`).
     - `0x34DE`: Sub-state handler via `Table 0x34C8`.
     - `0x0357`: RAM function-pointer dispatch reading `(0xC0E8..0xC0E9)` into `HL` with `LD DE, 0x0365; PUSH DE; JP (HL)`.
3. **Fixes Already Applied & Verified Building:**
   - **`runtime/crt0_rom.asm`:** Added `hook_int06`, `unhook_int06`, and `int06_handler` to catch CPU Exception 6, log `0600h|bank` + `0601h` (faulting `CS:IP`, opcode word, and `DI`) to `MISSES.BIN`, restore text mode, mute PC speaker, print `CRASH: Invalid Opcode (INT 06h) at CS:IP = XXXX:XXXX`, and exit cleanly with code `06h`.
   - **`tools/build_rom.py`:** Added `helper_jp_hl_miss_abort` (and a fixed-offset far bridge in `b0_helper_table`) and replaced the `lea di, [di + 2]; ret` fallthrough in both Bank 0 and Bank `b` `helper_dispatch_jp_hl` so unmatched `CX` values log tag `0x03` to `MISSES.BIN` and abort via `wdog_abort` instead of corrupting `SS:SP`.
   - Verified clean build + 120-frame `make test` for both `Bubble Ghost` (standalone) and `Legend of Zelda` (overlay mode).
4. **Remaining Verification & Next Steps:**
   - Run `Bubble Ghost` interactively (`make run ROM="/Users/arnovan/Downloads/HP 200lx/GB/Bubble Ghost (USA, Europe).gb"`), blow out the candle, and check if it now triggers `MISSES.BIN` tag `0x03` (`JP (HL)` miss, e.g., from `0x0357` reading `0xC0E8..0xC0E9`) or `0x06` (`INT 06h`).
   - If `0x03` triggers with a valid target address, ensure `discover_control_flow` / `jp_hl_targets[0]` captures that target (such as pointers stored into `0xC0E8..0xC0E9`).
   - Also audit `stubs_b*.asm` (`lea di, [di + 2]; ret`) in `tools/build_rom.py`: if any `jmp` or `jcc` in reachable code targets an emitted stub rather than a `call`, it can similarly corrupt the stack on return.

---
*Document created: November 2026 for the GB200LX Project.*
