# GB200LX Configuration & User Guide

This guide describes how to configure video scaling, palettes, and controls for recompiled games targeting the HP 200LX.

---

## 1. Overview

GB200LX provides two convenient ways to customize settings:
1. **Directly editing `GB200LX.INI`:** A standard ASCII configuration file placed alongside the executable.
2. **Interactive `/SETUP` Wizard:** A built-in, full-screen MS-DOS text mode configurator designed for the HP 200LX palmtop keyboard.

---

## 2. Configuration File Specification (`GB200LX.INI`)

If `GB200LX.INI` is absent when the game is launched, it is automatically created with factory defaults.

```ini
[video]
scaling = center
palette = pocket
vsync = 1

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

| Parameter | Options | Default | Description |
| :--- | :--- | :--- | :--- |
| **`scaling`** | `center`, `wide` | `center` | `center`: Displays the native 160×144 viewport with a border at screen coordinates `(80, 28)`.<br>`wide`: Horizontally stretches pixels across 320 columns. |
| **`palette`** | `pocket`, `dmg`, `high_con`, `dark` | `pocket` | Selects the 4-shade grayscale mapping for the HP 200LX LCD. |

#### Palette Presets

| Palette | Shade 0 (Lightest) | Shade 1 (Light) | Shade 2 (Dark) | Shade 3 (Darkest) | Notes |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **`pocket`** | White | Light Gray | Dark Gray | Black | Clear, crisp Game Boy Pocket look (Recommended for HP 200LX) |
| **`dmg`** | Light Gray | White | Dark Gray | Black | Classic DMG greenish-gray mapping |
| **`high_con`**| White | White | Black | Black | Maximum contrast 2-shade style; highly visible under poor lighting |
| **`dark`** | Dark Gray | Black | Light Gray | White | Inverted night mode |

---

### Input Section (`[input]`)

Controls can be assigned using human-readable key names.

| Setting | Function | Default | Typical HP 200LX Recommendation |
| :--- | :--- | :--- | :--- |
| **`key_up`** | D-Pad Up | `UP` | Arrow Up |
| **`key_down`** | D-Pad Down | `DOWN` | Arrow Down |
| **`key_left`** | D-Pad Left | `LEFT` | Arrow Left |
| **`key_right`**| D-Pad Right | `RIGHT` | Arrow Right |
| **`key_a`** | Game Boy A Button | `Z` | `Z` or `SPACE` |
| **`key_b`** | Game Boy B Button | `X` | `X` or `ENTER` |
| **`key_start`**| Start Button | `ENTER` | `ENTER` or `S` |
| **`key_select`**| Select Button | `SPACE` | `SPACE` or `D` |
| **`key_menu`**| Exit to DOS | `ESC` | `ESC` |

#### Supported Key Names
- **Letters:** `A` through `Z`
- **Numbers:** `0` through `9`
- **Arrow Keys:** `UP`, `DOWN`, `LEFT`, `RIGHT`
- **Special Keys:** `SPACE`, `ENTER`, `ESC`, `TAB`, `LSHIFT`, `RSHIFT`, `LCTRL`, `LALT`
- **Raw Hex Codes:** `0x48`, `0x50`, `0x4B`, `0x4D`, etc.

---

## 3. Interactive Setup Mode (`/SETUP`)

You can launch the configuration screen on your palmtop or in DOSBox at any time:

```dos
C:\GAMES> GAME.EXE /SETUP
```

### Features
1. **Interactive Key Capturing:** Select any action and press the desired key on the keyboard. The scancode is detected and registered immediately.
2. **Palette Toggle:** Cycle through available palettes to preview shade contrast on your physical LCD display.
3. **Save and Exit:** Press `ENTER` to save modifications directly to `GB200LX.INI` and start the game, or press `ESC` to cancel and return to DOS.
