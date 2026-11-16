# GB200LX Configuration & User Guide

This guide describes how to configure palettes, viewport options, and keyboard mappings for recompiled games targeting the HP 200LX and DOSBox-X.

---

## 1. Overview

GB200LX provides two ways to customize runtime settings:
1. **Editing `GB200LX.INI`:** An ASCII configuration file placed in the same directory as the `.EXE`.
2. **Interactive `/SETUP` Wizard:** A built-in MS-DOS text-mode configurator designed for the HP 200LX keyboard.

---

## 2. Configuration File Specification (`GB200LX.INI`)

If `GB200LX.INI` is missing when the executable starts, it is automatically created with factory defaults:

```ini
[video]
scaling = center
palette = pocket
vsync = 1
sound = 1

[input]
key_up = UP
key_down = DOWN
key_left = LEFT
key_right = RIGHT
key_a = Z
key_b = X
key_select = SPACE
key_start = ENTER
key_menu = ESC
```

### Video Section (`[video]`)

| Parameter | Options | Default | Notes |
| :--- | :--- | :--- | :--- |
| **`palette`** | `pocket`, `dmg`, `high_con`, `dark` | `pocket` | Selects the 4-shade CGA grayscale mapping (`cfg_shade0..3`) and BIOS CGA palette. |
| **`scaling`** | `center`, `wide` | `center` | `center` = 160×144 centered at `(80, 28)`; `wide` = 2× horizontal stretch (`320×144`). |
| **`vsync`** | `1`, `0` | `1` | Waits for CGA vertical retrace (`0x03DA` bit 3) before blitting when `1`. |
| **`sound`** | `1`, `0` | `1` | Enables (`1`) or mutes (`0`) PC speaker APU synthesis on PIT Channel 2. |

#### Palette Presets

| Palette | Shade 0 | Shade 1 | Shade 2 | Shade 3 | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **`pocket`** | White (`00b`) | Light Gray (`01b`) | Dark Gray (`10b`) | Black (`11b`) | Crisp 4-shade mapping + CGA Palette 0 (default) |
| **`dmg`** | White (`00b`) | Light Gray (`01b`) | Black (`11b`) | Black (`11b`) | Bold DMG contrast + CGA Palette 0 green BG |
| **`high_con`** | White (`00b`) | White (`00b`) | Black (`11b`) | Black (`11b`) | Maximum 2-shade B&W contrast + CGA Palette 1 |
| **`dark`** | Black (`11b`) | Dark Gray (`10b`) | Light Gray (`01b`) | White (`00b`) | Inverted dark-background mode + CGA Palette 1 |

---

## 3. Input Section (`[input]`)

| Setting | Game Boy Button | Default | Notes |
| :--- | :--- | :--- | :--- |
| **`key_up`** | D-Pad Up | `UP` | Extended `0xE0` arrow prefixes are handled automatically |
| **`key_down`** | D-Pad Down | `DOWN` | |
| **`key_left`** | D-Pad Left | `LEFT` | |
| **`key_right`** | D-Pad Right | `RIGHT` | |
| **`key_a`** | A Button | `Z` | |
| **`key_b`** | B Button | `X` | |
| **`key_select`** | Select | `SPACE` | |
| **`key_start`** | Start | `ENTER` | |
| **`key_menu`** | Pause Menu | `ESC` | Opens the in-game pause menu (`Resume`, `Save State`, `Load State`, `Options`, `Quit`). |

### Supported Key Names
- **Letters:** `A` through `Z`
- **Arrow Keys:** `UP`, `DOWN`, `LEFT`, `RIGHT`
- **Special Keys:** `SPACE`, `ENTER`, `ESC`

---

## 4. In-Game Pause Menu & Save States

Press **`ESC`** (or the configured `key_menu`) during gameplay to pause emulation, mute audio, and open the CGA pause overlay:
- **Resume Game:** Clears the overlay and resumes execution immediately.
- **Save State:** Writes the current 64 KiB Game Boy memory space, active 80186 hardware stack, ROM bank, timer/PPU state, and APU state to `GBSTATE0.SAV` (guarded by the ROM header checksum).
- **Load State:** Validates `GBSTATE0.SAV` against the running ROM and restores gameplay cleanly.
- **Options:** Adjust any video (`scaling`, `palette`, `vsync`, `sound`) or input (`key_up`..`key_menu`) setting in `GB200LX.INI`; changes to `palette` and `sound` apply immediately and persist to `GB200LX.INI` when leaving Options.
- **Quit:** Restores PIT timer, `INT 08h`/`09h`, and MS-DOS text mode (`Mode 03h`) before exiting.

Direct hotkeys **`F5`** (Quick Save) and **`F9`** (Quick Load) also read and write `GBSTATE0.SAV` without opening the menu.

---

## 5. Interactive Setup Mode (`/SETUP`) & Test Mode (`/t`)

Launch `/SETUP` directly on the HP 200LX or via `make setup` in DOSBox-X:
```dos
C:\GAMES> GAME.EXE /SETUP
```
- Select an action and press the desired key to capture its hardware scancode.
- Answer `[9/9] PC Speaker Sound (Y/N)` (`Y`/`1`/`Enter` = On, `N`/`0` = Off) to enable or disable sound.
- Press `ENTER` to save settings directly to `GB200LX.INI` and start the game, or `ESC` to cancel.

For automated verification, passing `/t` (used by `make test`) runs 120 frames, dumps CGA VRAM (`0xB800`) to `CGA_VRAM.BIN`, and exits cleanly to DOS.
