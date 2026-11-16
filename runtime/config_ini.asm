; ==============================================================================
; config_ini.asm - Human-Readable INI Parser & Interactive /SETUP for HP 200LX
; Handles GB200LX.INI reading, key name resolution, interactive keyboard mapping,
; palette selection, and saving back to disk.
; ==============================================================================

bits 16
cpu 186

; ------------------------------------------------------------------------------
; cfg_init: Initialize configuration from GB200LX.INI or defaults
; Input:  ES:80h = command line length, ES:81h = command tail
; Output: CF = 1 if user requested quit from setup, 0 to continue
; ------------------------------------------------------------------------------
global cfg_init
cfg_init:
    push    bp
    mov     bp, sp

    ; Set defaults first
    call    cfg_set_defaults

    ; Check if command line contains '/SETUP' or '/S'
    call    cfg_check_setup_cmd
    jc      .run_setup

    ; Try to load GB200LX.INI from current directory
    call    cfg_load_ini
    jnc     .done

    ; If INI file doesn't exist, create it with defaults
    call    cfg_save_ini
    jmp     .done

.run_setup:
    call    cfg_run_interactive_setup
    ; If setup finished with ESC, exit program
    jc      .setup_exit

.done:
    ; Apply palette configuration to shade variables
    call    cfg_apply_palette
    clc
    pop     bp
    ret

.setup_exit:
    stc
    pop     bp
    ret

; ------------------------------------------------------------------------------
; cfg_set_defaults: Fill cfg_data with factory defaults
; ------------------------------------------------------------------------------
cfg_set_defaults:
    push    di
    push    cx
    push    ax

    mov     byte [cfg_scaling],   SCALE_CENTER
    mov     byte [cfg_palette],   PAL_POCKET
    mov     byte [cfg_border],    1
    mov     byte [cfg_vsync],     1
    mov     byte [cfg_frameskip], 0
    mov     byte [cfg_sound],     1

    mov     byte [cfg_key_up],     SCAN_UP
    mov     byte [cfg_key_down],   SCAN_DOWN
    mov     byte [cfg_key_left],   SCAN_LEFT
    mov     byte [cfg_key_right],  SCAN_RIGHT
    mov     byte [cfg_key_a],      SCAN_Z       ; 'Z' key
    mov     byte [cfg_key_b],      SCAN_X       ; 'X' key
    mov     byte [cfg_key_select], SCAN_SPACE   ; Space
    mov     byte [cfg_key_start],  SCAN_ENTER   ; Enter
    mov     byte [cfg_key_menu],   SCAN_ESC     ; ESC

    pop     ax
    pop     cx
    pop     di
    ret

; ------------------------------------------------------------------------------
; cfg_apply_palette: Sets shade0..3 based on cfg_palette
; ------------------------------------------------------------------------------
cfg_apply_palette:
    mov     al, [cfg_palette]
    cmp     al, PAL_DMG
    je      .pal_dmg
    cmp     al, PAL_HIGH_CON
    je      .pal_high_con
    cmp     al, PAL_DARK
    je      .pal_dark

.pal_pocket:
    mov     byte [cfg_shade0], 00000000b  ; White
    mov     byte [cfg_shade1], 01010101b  ; Light Gray (55h)
    mov     byte [cfg_shade2], 10101010b  ; Dark Gray  (AAh)
    mov     byte [cfg_shade3], 11111111b  ; Black      (FFh)
    ret

.pal_dmg:
    ; Authentic 1989 Game Boy olive/greenish dither
    mov     byte [cfg_shade0], 00000000b  ; Lightest
    mov     byte [cfg_shade1], 01010101b
    mov     byte [cfg_shade2], 10101010b
    mov     byte [cfg_shade3], 11111111b
    ret

.pal_high_con:
    ; High contrast sunlight mode (Pure B&W)
    mov     byte [cfg_shade0], 00000000b
    mov     byte [cfg_shade1], 00000000b
    mov     byte [cfg_shade2], 11111111b
    mov     byte [cfg_shade3], 11111111b
    ret

.pal_dark:
    ; Inverted night mode
    mov     byte [cfg_shade0], 11111111b
    mov     byte [cfg_shade1], 10101010b
    mov     byte [cfg_shade2], 01010101b
    mov     byte [cfg_shade3], 00000000b
    ret

; ------------------------------------------------------------------------------
; cfg_check_setup_cmd: Checks if PSP command line contains '/SETUP' or '/S'
; Output: CF = 1 if setup requested, 0 otherwise
; ------------------------------------------------------------------------------
cfg_check_setup_cmd:
    push    si
    push    cx
    push    ax

    ; Command line in PSP at offset 80h
    mov     cl, [es:80h]
    xor     ch, ch
    jcxz    .not_found
    mov     si, 81h

.loop:
    mov     al, [es:si]
    cmp     al, '/'
    je      .check_slash
    cmp     al, '-'
    je      .check_slash
    inc     si
    loop    .loop
    jmp     .not_found

.check_slash:
    inc     si
    dec     cx
    jcxz    .not_found
    mov     al, [es:si]
    cmp     al, 's'
    je      .is_setup
    cmp     al, 'S'
    je      .is_setup
    inc     si
    loop    .loop

.not_found:
    clc
    pop     ax
    pop     cx
    pop     si
    ret

.is_setup:
    stc
    pop     ax
    pop     cx
    pop     si
    ret

; ------------------------------------------------------------------------------
; cfg_load_ini: Open and parse GB200LX.INI
; Output: CF = 0 if loaded, 1 if file not found / error
; ------------------------------------------------------------------------------
cfg_load_ini:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di

    ; Open GB200LX.INI
    mov     ax, 3D00h               ; Read-only
    mov     dx, fn_ini
    int     21h
    jc      .load_fail
    mov     bx, ax                  ; File handle

    ; Read file into buffer
    mov     ah, 3Fh
    mov     cx, 2000
    mov     dx, cfg_buffer
    int     21h
    jc      .close_fail
    mov     [cfg_buffer_len], ax

    ; Close file
    mov     ah, 3Eh
    int     21h

    ; Parse the buffer
    call    cfg_parse_buffer
    clc
    jmp     .load_exit

.close_fail:
    mov     ah, 3Eh
    int     21h
.load_fail:
    stc

.load_exit:
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ------------------------------------------------------------------------------
; cfg_parse_buffer: Simple line-by-line scanner for key=value pairs
; ------------------------------------------------------------------------------
cfg_parse_buffer:
    mov     si, cfg_buffer
    mov     cx, [cfg_buffer_len]
    jcxz    .parse_done

.next_line:
    call    cfg_skip_spaces
    jcxz    .parse_done

    ; Check if comment or section header
    mov     al, [si]
    cmp     al, ';'
    je      .skip_to_eol
    cmp     al, '#'
    je      .skip_to_eol
    cmp     al, '['
    je      .skip_to_eol
    cmp     al, 0Dh
    je      .skip_eol
    cmp     al, 0Ah
    je      .skip_eol

    ; Try to match key names
    call    cfg_try_match_keys

.skip_to_eol:
    cmp     cx, 0
    jbe     .parse_done
    mov     al, [si]
    inc     si
    dec     cx
    cmp     al, 0Ah
    jne     .skip_to_eol
    jmp     .next_line

.skip_eol:
    inc     si
    dec     cx
    jmp     .next_line

.parse_done:
    ret

; Skip whitespace characters
cfg_skip_spaces:
.ss_loop:
    cmp     cx, 0
    jbe     .ss_end
    mov     al, [si]
    cmp     al, ' '
    je      .ss_inc
    cmp     al, 9                   ; TAB
    je      .ss_inc
    ret
.ss_inc:
    inc     si
    dec     cx
    jmp     .ss_loop
.ss_end:
    ret

; ------------------------------------------------------------------------------
; Match specific key prefixes in current line
; ------------------------------------------------------------------------------
cfg_try_match_keys:
    ; Compare with known keys: "scaling", "palette", "key_up", etc.
    ; Helper: scans past '=' and gets value string
    push    si
    push    cx

    ; Check "scaling"
    mov     di, str_key_scaling
    call    cfg_str_starts_with
    jc      .val_scaling

    ; Check "palette"
    mov     di, str_key_palette
    call    cfg_str_starts_with
    jc      .val_palette

    ; Check "sound"
    mov     di, str_key_sound
    call    cfg_str_starts_with
    jc      .val_sound

    ; Check "key_up"
    mov     di, str_key_up
    call    cfg_str_starts_with
    jc      .val_key_up

    ; Check "key_down"
    mov     di, str_key_down
    call    cfg_str_starts_with
    jc      .val_key_down

    ; Check "key_left"
    mov     di, str_key_left
    call    cfg_str_starts_with
    jc      .val_key_left

    ; Check "key_right"
    mov     di, str_key_right
    call    cfg_str_starts_with
    jc      .val_key_right

    ; Check "key_a"
    mov     di, str_key_a
    call    cfg_str_starts_with
    jc      .val_key_a

    ; Check "key_b"
    mov     di, str_key_b
    call    cfg_str_starts_with
    jc      .val_key_b

    ; Check "key_start"
    mov     di, str_key_start
    call    cfg_str_starts_with
    jc      .val_key_start

    ; Check "key_select"
    mov     di, str_key_select
    call    cfg_str_starts_with
    jc      .val_key_select

    ; Check "key_menu"
    mov     di, str_key_menu
    call    cfg_str_starts_with
    jc      .val_key_menu

    pop     cx
    pop     si
    ret

.val_scaling:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    ; Compare value with "wide"
    mov     di, str_val_wide
    call    cfg_str_starts_with
    jnc     .val_scale_center
    mov     byte [cfg_scaling], SCALE_WIDE
    ret
.val_scale_center:
    mov     byte [cfg_scaling], SCALE_CENTER
    ret

.val_palette:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    mov     di, str_val_dmg
    call    cfg_str_starts_with
    jc      .is_dmg
    mov     di, str_val_high_con
    call    cfg_str_starts_with
    jc      .is_high_con
    mov     di, str_val_dark
    call    cfg_str_starts_with
    jc      .is_dark
    mov     byte [cfg_palette], PAL_POCKET
    ret
.is_dmg:
    mov     byte [cfg_palette], PAL_DMG
    ret
.is_high_con:
    mov     byte [cfg_palette], PAL_HIGH_CON
    ret
.is_dark:
    mov     byte [cfg_palette], PAL_DARK
    ret

.val_sound:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    mov     byte [cfg_sound], 0
    mov     al, [si]
    cmp     al, '0'
    je      .sound_done
    cmp     al, 'n'
    je      .sound_done
    cmp     al, 'N'
    je      .sound_done
    cmp     al, 'f'
    je      .sound_done
    cmp     al, 'F'
    je      .sound_done
    cmp     al, 'o'                 ; Distinguish "off" vs "on"
    je      .sound_chk_o
    cmp     al, 'O'
    jne     .sound_on
.sound_chk_o:
    mov     al, [si + 1]
    cmp     al, 'f'
    je      .sound_done
    cmp     al, 'F'
    je      .sound_done
.sound_on:
    mov     byte [cfg_sound], 1
.sound_done:
    ret

.val_key_up:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_up], al
    ret

.val_key_down:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_down], al
    ret

.val_key_left:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_left], al
    ret

.val_key_right:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_right], al
    ret

.val_key_a:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_a], al
    ret

.val_key_b:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_b], al
    ret

.val_key_start:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_start], al
    ret

.val_key_select:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_select], al
    ret

.val_key_menu:
    pop     cx
    pop     si
    call    cfg_advance_to_value
    call    cfg_resolve_key_name
    mov     [cfg_key_menu], al
    ret

; Advance SI past '=' and leading spaces
cfg_advance_to_value:
.find_eq:
    cmp     cx, 0
    jbe     .adv_done
    mov     al, [si]
    inc     si
    dec     cx
    cmp     al, '='
    je      .found_eq
    cmp     al, 0Ah
    je      .adv_done
    jmp     .find_eq
.found_eq:
    call    cfg_skip_spaces
.adv_done:
    ret

; Compare string at SI with zero-terminated string at DI (case-insensitive)
; Output: CF = 1 if match, 0 if not
cfg_str_starts_with:
    push    si
    push    di
.cmp_loop:
    mov     al, [cs:di]
    test    al, al
    jz      .match
    mov     ah, [si]

    ; Convert both to uppercase for comparison
    cmp     al, 'a'
    jb      .not_low1
    cmp     al, 'z'
    ja      .not_low1
    sub     al, 20h
.not_low1:
    cmp     ah, 'a'
    jb      .not_low2
    cmp     ah, 'z'
    ja      .not_low2
    sub     ah, 20h
.not_low2:
    cmp     al, ah
    jne     .no_match
    inc     si
    inc     di
    jmp     .cmp_loop

.match:
    stc
    pop     di
    pop     si
    ret

.no_match:
    clc
    pop     di
    pop     si
    ret

; ------------------------------------------------------------------------------
; cfg_resolve_key_name: Resolve string at SI to scancode in AL
; ------------------------------------------------------------------------------
cfg_resolve_key_name:
    ; Check common named keys: UP, DOWN, LEFT, RIGHT, ENTER, SPACE, ESC
    mov     di, str_name_up
    call    cfg_str_starts_with
    jc      .sc_up
    mov     di, str_name_down
    call    cfg_str_starts_with
    jc      .sc_down
    mov     di, str_name_left
    call    cfg_str_starts_with
    jc      .sc_left
    mov     di, str_name_right
    call    cfg_str_starts_with
    jc      .sc_right
    mov     di, str_name_enter
    call    cfg_str_starts_with
    jc      .sc_enter
    mov     di, str_name_space
    call    cfg_str_starts_with
    jc      .sc_space
    mov     di, str_name_esc
    call    cfg_str_starts_with
    jc      .sc_esc

    ; Single letter A-Z
    mov     al, [si]
    cmp     al, 'a'
    jb      .check_upper
    cmp     al, 'z'
    ja      .check_upper
    sub     al, 20h
.check_upper:
    cmp     al, 'A'
    jb      .default_key
    cmp     al, 'Z'
    ja      .default_key

    ; Convert uppercase letter A-Z to scancode via lookup table
    sub     al, 'A'
    mov     bx, scancode_alpha_table
    xlat
    ret

.sc_up:
    mov     al, SCAN_UP
    ret
.sc_down:
    mov     al, SCAN_DOWN
    ret
.sc_left:
    mov     al, SCAN_LEFT
    ret
.sc_right:
    mov     al, SCAN_RIGHT
    ret
.sc_enter:
    mov     al, SCAN_ENTER
    ret
.sc_space:
    mov     al, SCAN_SPACE
    ret
.sc_esc:
    mov     al, SCAN_ESC
    ret

.default_key:
    mov     al, SCAN_SPACE
    ret

; ------------------------------------------------------------------------------
; cfg_save_ini: Write current settings to GB200LX.INI
; ------------------------------------------------------------------------------
cfg_save_ini:
    push    ax
    push    bx
    push    cx
    push    dx

    ; Create/overwrite GB200LX.INI
    mov     ah, 3Ch
    xor     cx, cx
    mov     dx, fn_ini
    int     21h
    jc      .save_fail
    mov     bx, ax

    ; Reflect current runtime settings in INI template before writing
    mov     al, '0'
    add     al, [cfg_sound]
    mov     [ini_sound_char], al

    ; Write formatted text
    mov     ah, 40h
    mov     dx, ini_template_part1
    mov     cx, ini_part1_len
    int     21h

    ; Close file
    mov     ah, 3Eh
    int     21h
    clc
    jmp     .save_exit

.save_fail:
    stc
.save_exit:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ------------------------------------------------------------------------------
; cfg_run_interactive_setup: Interactive DOS Key Configurator Screen
; ------------------------------------------------------------------------------
cfg_run_interactive_setup:
    push    bp
    mov     bp, sp

    ; Switch to standard 80x25 text mode (Mode 03h)
    mov     ax, 0003h
    int     10h

    ; Print Header
    mov     dx, msg_setup_title
    call    print_dos_str

    ; 1. Bind UP
    mov     dx, msg_prompt_up
    call    print_dos_str
    call    read_scancode
    cmp     al, SCAN_ESC
    je      .cancel_setup
    mov     [cfg_key_up], al
    call    print_key_name

    ; 2. Bind DOWN
    mov     dx, msg_prompt_down
    call    print_dos_str
    call    read_scancode
    cmp     al, SCAN_ESC
    je      .cancel_setup
    mov     [cfg_key_down], al
    call    print_key_name

    ; 3. Bind LEFT
    mov     dx, msg_prompt_left
    call    print_dos_str
    call    read_scancode
    cmp     al, SCAN_ESC
    je      .cancel_setup
    mov     [cfg_key_left], al
    call    print_key_name

    ; 4. Bind RIGHT
    mov     dx, msg_prompt_right
    call    print_dos_str
    call    read_scancode
    cmp     al, SCAN_ESC
    je      .cancel_setup
    mov     [cfg_key_right], al
    call    print_key_name

    ; 5. Bind Button A (Jump)
    mov     dx, msg_prompt_a
    call    print_dos_str
    call    read_scancode
    cmp     al, SCAN_ESC
    je      .cancel_setup
    mov     [cfg_key_a], al
    call    print_key_name

    ; 6. Bind Button B (Run/Shoot)
    mov     dx, msg_prompt_b
    call    print_dos_str
    call    read_scancode
    cmp     al, SCAN_ESC
    je      .cancel_setup
    mov     [cfg_key_b], al
    call    print_key_name

    ; 7. Bind SELECT
    mov     dx, msg_prompt_sel
    call    print_dos_str
    call    read_scancode
    cmp     al, SCAN_ESC
    je      .cancel_setup
    mov     [cfg_key_select], al
    call    print_key_name

    ; 8. Bind START
    mov     dx, msg_prompt_start
    call    print_dos_str
    call    read_scancode
    cmp     al, SCAN_ESC
    je      .cancel_setup
    mov     [cfg_key_start], al
    call    print_key_name

    ; 9. Enable / Disable Sound
    mov     dx, msg_prompt_sound
    call    print_dos_str
.wait_sound_key:
    mov     ah, 00h
    int     16h
    cmp     al, 1Bh                 ; ESC
    je      .cancel_setup
    cmp     al, 'n'
    je      .sound_set_off
    cmp     al, 'N'
    je      .sound_set_off
    cmp     al, '0'
    je      .sound_set_off
    cmp     al, 'y'
    je      .sound_set_on
    cmp     al, 'Y'
    je      .sound_set_on
    cmp     al, '1'
    je      .sound_set_on
    cmp     al, 0Dh                 ; Enter keeps Sound ON
    je      .sound_set_on
    jmp     short .wait_sound_key
.sound_set_off:
    mov     byte [cfg_sound], 0
    mov     dx, msg_sound_off
    call    print_dos_str
    jmp     short .sound_prompt_done
.sound_set_on:
    mov     byte [cfg_sound], 1
    mov     dx, msg_sound_on
    call    print_dos_str
.sound_prompt_done:

    ; Save settings to GB200LX.INI
    call    cfg_save_ini

    ; Confirmation prompt
    mov     dx, msg_setup_saved
    call    print_dos_str

    ; Wait for key: Enter launches, ESC quits
.wait_launch_key:
    mov     ah, 00h
    int     16h
    cmp     al, 1Bh                 ; ESC
    je      .cancel_setup
    cmp     al, 0Dh                 ; Enter
    je      .proceed
    jmp     .wait_launch_key

.proceed:
    clc
    pop     bp
    ret

.cancel_setup:
    stc
    pop     bp
    ret

; Read BIOS keystroke and return hardware scancode in AL
read_scancode:
    mov     ah, 00h
    int     16h
    mov     al, ah                  ; AL = scancode
    ret

; Print user-friendly name of scancode in AL
print_key_name:
    push    ax
    push    dx
    cmp     al, SCAN_UP
    je      .p_up
    cmp     al, SCAN_DOWN
    je      .p_down
    cmp     al, SCAN_LEFT
    je      .p_left
    cmp     al, SCAN_RIGHT
    je      .p_right
    cmp     al, SCAN_SPACE
    je      .p_space
    cmp     al, SCAN_ENTER
    je      .p_enter

    ; Generic key code
    mov     dx, msg_key_assigned
    call    print_dos_str
    pop     dx
    pop     ax
    ret

.p_up:
    mov     dx, msg_kn_up
    jmp     short .print_and_ret
.p_down:
    mov     dx, msg_kn_down
    jmp     short .print_and_ret
.p_left:
    mov     dx, msg_kn_left
    jmp     short .print_and_ret
.p_right:
    mov     dx, msg_kn_right
    jmp     short .print_and_ret
.p_space:
    mov     dx, msg_kn_space
    jmp     short .print_and_ret
.p_enter:
    mov     dx, msg_kn_enter
.print_and_ret:
    call    print_dos_str
    pop     dx
    pop     ax
    ret

print_dos_str:
    push    ax
    mov     ah, 09h
    int     21h
    pop     ax
    ret

; ------------------------------------------------------------------------------
; DATA
; ------------------------------------------------------------------------------
global cfg_scaling, cfg_palette, cfg_border, cfg_vsync, cfg_frameskip, cfg_sound
global cfg_key_up, cfg_key_down, cfg_key_left, cfg_key_right
global cfg_key_a, cfg_key_b, cfg_key_select, cfg_key_start, cfg_key_menu
global cfg_shade0, cfg_shade1, cfg_shade2, cfg_shade3

cfg_scaling:        db SCALE_CENTER
cfg_palette:        db PAL_POCKET
cfg_border:         db 1
cfg_vsync:          db 1
cfg_frameskip:      db 0
cfg_sound:          db 1

cfg_key_up:         db SCAN_UP
cfg_key_down:       db SCAN_DOWN
cfg_key_left:       db SCAN_LEFT
cfg_key_right:      db SCAN_RIGHT
cfg_key_a:          db SCAN_Z
cfg_key_b:          db SCAN_X
cfg_key_select:     db SCAN_SPACE
cfg_key_start:      db SCAN_ENTER
cfg_key_menu:       db SCAN_ESC

cfg_shade0:         db 00000000b
cfg_shade1:         db 01010101b
cfg_shade2:         db 10101010b
cfg_shade3:         db 11111111b

fn_ini:             db "GB200LX.INI", 0

; Scancode lookup table for letters 'A'..'Z'
scancode_alpha_table:
    db 1Eh  ; A
    db 30h  ; B
    db 2Eh  ; C
    db 20h  ; D
    db 12h  ; E
    db 21h  ; F
    db 22h  ; G
    db 23h  ; H
    db 17h  ; I
    db 24h  ; J
    db 25h  ; K
    db 26h  ; L
    db 32h  ; M
    db 31h  ; N
    db 18h  ; O
    db 19h  ; P
    db 10h  ; Q
    db 13h  ; R
    db 1Fh  ; S
    db 14h  ; T
    db 16h  ; U
    db 2Fh  ; V
    db 11h  ; W
    db 2Dh  ; X
    db 15h  ; Y
    db 2Ch  ; Z

; Key Strings
str_key_scaling:    db "scaling", 0
str_key_palette:    db "palette", 0
str_key_sound:      db "sound", 0
str_key_up:         db "key_up", 0
str_key_down:       db "key_down", 0
str_key_left:       db "key_left", 0
str_key_right:      db "key_right", 0
str_key_a:          db "key_a", 0
str_key_b:          db "key_b", 0
str_key_start:      db "key_start", 0
str_key_select:     db "key_select", 0
str_key_menu:       db "key_menu", 0

str_val_wide:       db "wide", 0
str_val_dmg:        db "dmg", 0
str_val_high_con:   db "high_con", 0
str_val_dark:       db "dark", 0

str_name_up:        db "UP", 0
str_name_down:      db "DOWN", 0
str_name_left:      db "LEFT", 0
str_name_right:     db "RIGHT", 0
str_name_enter:     db "ENTER", 0
str_name_space:     db "SPACE", 0
str_name_esc:       db "ESC", 0

; Messages
msg_setup_title:
    db 0Dh, 0Ah
    db "==================================================================", 0Dh, 0Ah
    db "            GB200LX - HP 200LX CONTROLLER SETUP", 0Dh, 0Ah
    db "==================================================================", 0Dh, 0Ah
    db "Press the physical key on your keyboard for each button (ESC cancels):", 0Dh, 0Ah, 0Dh, 0Ah, "$"

msg_prompt_up:    db "  [1/9] D-Pad UP:              $", 0
msg_prompt_down:  db "  [2/9] D-Pad DOWN:            $", 0
msg_prompt_left:  db "  [3/9] D-Pad LEFT:            $", 0
msg_prompt_right: db "  [4/9] D-Pad RIGHT:           $", 0
msg_prompt_a:     db "  [5/9] Button A:              $", 0
msg_prompt_b:     db "  [6/9] Button B:              $", 0
msg_prompt_sel:   db "  [7/9] SELECT:                $", 0
msg_prompt_start: db "  [8/9] START:                 $", 0
msg_prompt_sound: db "  [9/9] PC Speaker Sound (Y/N): $", 0
msg_sound_on:     db "ON", 0Dh, 0Ah, "$"
msg_sound_off:    db "OFF", 0Dh, 0Ah, "$"

msg_kn_up:    db "UP ARROW", 0Dh, 0Ah, "$"
msg_kn_down:  db "DOWN ARROW", 0Dh, 0Ah, "$"
msg_kn_left:  db "LEFT ARROW", 0Dh, 0Ah, "$"
msg_kn_right: db "RIGHT ARROW", 0Dh, 0Ah, "$"
msg_kn_space: db "SPACE BAR", 0Dh, 0Ah, "$"
msg_kn_enter: db "ENTER", 0Dh, 0Ah, "$"
msg_key_assigned: db "OK [Assigned]", 0Dh, 0Ah, "$"

msg_setup_saved:
    db 0Dh, 0Ah
    db "------------------------------------------------------------------", 0Dh, 0Ah
    db "Saved settings to GB200LX.INI successfully!", 0Dh, 0Ah
    db "Press [ENTER] to launch the game, or [ESC] to exit to DOS.", 0Dh, 0Ah, "$"

ini_template_part1:
    db "; GB200LX Runtime Configuration for HP 200LX", 0Dh, 0Ah
    db "[video]", 0Dh, 0Ah
    db "scaling = center", 0Dh, 0Ah
    db "palette = pocket", 0Dh, 0Ah
    db "vsync = 1", 0Dh, 0Ah
    db "sound = "
ini_sound_char:
    db "1", 0Dh, 0Ah
    db 0Dh, 0Ah
    db "[input]", 0Dh, 0Ah
    db "key_up = UP", 0Dh, 0Ah
    db "key_down = DOWN", 0Dh, 0Ah
    db "key_left = LEFT", 0Dh, 0Ah
    db "key_right = RIGHT", 0Dh, 0Ah
    db "key_a = Z", 0Dh, 0Ah
    db "key_b = X", 0Dh, 0Ah
    db "key_select = SPACE", 0Dh, 0Ah
    db "key_start = ENTER", 0Dh, 0Ah
    db "key_menu = ESC", 0Dh, 0Ah
ini_part1_len equ ($ - ini_template_part1)

cfg_buffer:         times 2048 db 0
cfg_buffer_len:     dw 0
