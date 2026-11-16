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
| **`palette`** | `pocket`, `dmg`, `high_con`, `dark` | `pocket` | Selects the 4-shade CGA grayscale mapping (`cfg_shade0..3`). |
| **`scaling`** | `center`, `wide` | `center` | Stored in INI and `/SETUP` (`center` = 160×144 viewport centered at `(80, 28)`). |
| **`vsync`** | `1`, `0` | `1` | Kept for INI compatibility; frame pacing is governed by the 59.73 Hz PIT `INT 08h` clock. |
| **`sound`** | `1`, `0` | `1` | Enables (`1`) or mutes (`0`) PC speaker APU synthesis on PIT Channel 2. |

#### Palette Presets

| Palette | Shade 0 | Shade 1 | Shade 2 | Shade 3 | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **`pocket`** | White (`00b`) | Light Gray (`01b`) | Dark Gray (`10b`) | Black (`11b`) | Crisp 4-shade mapping (default) |
| **`dmg`** | White (`00b`) | Light Gray (`01b`) | Dark Gray (`10b`) | Black (`11b`) | Classic 4-shade mapping |
| **`high_con`** | White (`00b`) | White (`00b`) | Black (`11b`) | Black (`11b`) | Maximum 2-shade contrast for dim lighting |
| **`dark`** | Black (`11b`) | Dark Gray (`10b`) | Light Gray (`01b`) | White (`00b`) | Inverted mode |

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
| **`key_menu`** | Exit to DOS | `ESC` | Restores PIT timer, `INT 08h`/`09h`, and text mode |

### Supported Key Names
- **Letters:** `A` through `Z`
- **Numbers:** `0` through `9`
- **Arrow Keys:** `UP`, `DOWN`, `LEFT`, `RIGHT`
- **Special Keys:** `SPACE`, `ENTER`, `ESC`, `TAB`, `LSHIFT`, `RSHIFT`, `LCTRL`, `LALT`
- **Raw Hex Scancodes:** `0x48`, `0x50`, `0x4B`, `0x4D`, etc.

---

## 4. Interactive Setup Mode (`/SETUP`) & Test Mode (`/t`)

Launch `/SETUP` directly on the HP 200LX or via `make setup` in DOSBox-X:
```dos
C:\GAMES> GAME.EXE /SETUP
```
- Select an action and press the desired key to capture its hardware scancode.
- Toggle palettes and save directly back to `GB200LX.INI` (press `ENTER` to save and start, or `ESC` to cancel).

For automated verification, passing `/t` (used by `make test`) runs 120 frames, dumps CGA VRAM (`0xB800`) to `CGA_VRAM.BIN`, and exits cleanly to DOS.
