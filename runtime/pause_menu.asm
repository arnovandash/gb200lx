; ==============================================================================
; pause_menu.asm - In-Game ESC Pause Menu & Live Options Editor
; Invoked from helper_halt when menu_requested == 1. Draws a CGA Mode 04h overlay
; dialog using BIOS INT 10h text output, handles Resume / Save State / Load State /
; Options (all GB200LX.INI settings) / Quit, and cleanly restores gameplay.
; ==============================================================================

bits 16
cpu 186

PM_ITEM_COUNT       equ 5
OPT_ITEM_COUNT      equ 14

OPT_TYPE_SCALE      equ 0
OPT_TYPE_PAL        equ 1
OPT_TYPE_BOOL       equ 2
OPT_TYPE_KEY        equ 3
OPT_TYPE_BACK       equ 4

; ------------------------------------------------------------------------------
; pause_menu_run: Main entry called from helper_halt when ESC / menu pressed.
; Expects [cs:halt_sp_base] already captured inside helper_halt.
; Outputs via flags: exit_requested=1 (Quit), load_requested=1 (Load), else Resume.
; ------------------------------------------------------------------------------
global pause_menu_run
pause_menu_run:
    pushf
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    ds
    push    es
    push    bp

    mov     ax, cs
    mov     ds, ax
    mov     es, ax

    call    spk_mute
    mov     byte [menu_requested], 0
    mov     byte [menu_active], 1
    call    pm_drain_keys
    sti

    mov     byte [pm_sel], 0
    mov     word [pm_status_ptr], 0

.pm_redraw:
    call    pm_draw_box

    mov     dx, 040Ch               ; Row 4, Col 12
    mov     si, str_pm_title
    call    pm_print_at

    ; Draw 5 menu items at rows 7, 9, 11, 13, 15
    xor     bx, bx
.pm_item_loop:
    mov     dh, bl
    shl     dh, 1
    add     dh, 7
    mov     dl, 10                  ; Col 10
    mov     si, bx
    shl     si, 1
    mov     si, [pm_item_ptrs + si]
    call    pm_print_at
    cmp     bl, [pm_sel]
    jne     .pm_next_item
    mov     al, dh
    call    pm_invert_row
.pm_next_item:
    inc     bx
    cmp     bx, PM_ITEM_COUNT
    jb      .pm_item_loop

    ; Status message (row 18, col 8)
    mov     si, [pm_status_ptr]
    test    si, si
    jz      .pm_no_status
    mov     dx, 1208h
    call    pm_print_at
.pm_no_status:
    ; Footer hint (row 20, col 7)
    mov     dx, 1407h
    mov     si, str_pm_hint
    call    pm_print_at

.pm_wait_key:
    xor     ah, ah
    int     16h
    mov     word [pm_status_ptr], 0

    cmp     al, 1Bh                 ; ESC -> Resume
    je      near .pm_resume
    cmp     ah, 48h                 ; Up arrow
    je      .pm_up
    cmp     ah, 50h                 ; Down arrow
    je      .pm_down
    cmp     al, 0Dh                 ; Enter
    je      .pm_activate
    cmp     al, ' '                 ; Space
    je      .pm_activate
    jmp     short .pm_wait_key

.pm_up:
    mov     al, [pm_sel]
    or      al, al
    jnz     .pm_up_ok
    mov     al, PM_ITEM_COUNT
.pm_up_ok:
    dec     al
    mov     [pm_sel], al
    jmp     .pm_redraw

.pm_down:
    mov     al, [pm_sel]
    inc     al
    cmp     al, PM_ITEM_COUNT
    jb      .pm_dn_ok
    xor     al, al
.pm_dn_ok:
    mov     [pm_sel], al
    jmp     .pm_redraw

.pm_activate:
    mov     al, [pm_sel]
    cmp     al, 0                   ; 0: Resume Game
    je      short .pm_resume
    cmp     al, 1                   ; 1: Save State
    je      short .pm_save
    cmp     al, 2                   ; 2: Load State
    je      short .pm_load
    cmp     al, 3                   ; 3: Options
    je      short .pm_options
    ; 4: Quit
    mov     byte [exit_requested], 1
    jmp     short .pm_exit_menu

.pm_save:
    call    savestate_save_from_pause
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     word [pm_status_ptr], str_msg_saved
    cmp     byte [save_ok], 1
    je      .pm_redraw
    mov     word [pm_status_ptr], str_msg_save_err
    jmp     .pm_redraw

.pm_load:
    call    savestate_validate
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    jc      .pm_no_state
    mov     byte [load_requested], 1
    jmp     short .pm_restore_screen
.pm_no_state:
    mov     word [pm_status_ptr], str_msg_no_state
    jmp     .pm_redraw

.pm_options:
    call    pause_options_run
    jmp     .pm_redraw

.pm_resume:
.pm_restore_screen:
    ; Clear screen, sync CGA hardware palette, & redraw border for active config
    call    cga_sync_hw_palette
    call    cga_clear_screen
    call    cga_draw_border
    ; Force full palette + tile cache refresh on next frame render
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     byte [last_bgp], 0FFh
    mov     di, tile_dirty
    mov     ax, 0101h
    mov     cx, 192
    cld
    rep     stosw

.pm_exit_menu:
    call    pm_drain_keys
    mov     byte [joypad_dir], 0Fh
    mov     byte [joypad_act], 0Fh
    mov     byte [joypad_dir_latch], 0FFh
    mov     byte [joypad_act_latch], 0FFh
    mov     byte [skip_run], 0
    mov     byte [menu_requested], 0
    mov     byte [menu_active], 0
    cli
    mov     word [frame_ticks], 1
    sti

    pop     bp
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    popf
    ret

; ------------------------------------------------------------------------------
; pause_options_run: Adjust all GB200LX.INI options & persist via cfg_save_ini
; ------------------------------------------------------------------------------
pause_options_run:
    mov     byte [opt_sel], 0

.opt_redraw:
    call    pm_draw_box
    mov     dx, 040Dh               ; Row 4, Col 13
    mov     si, str_opt_title
    call    pm_print_at

    ; Draw 14 items on rows 6..19
    xor     bx, bx                  ; BX = item index (0..13)
.opt_row_loop:
    mov     ax, bx
    imul    ax, 5
    mov     di, opt_table
    add     di, ax                  ; DS:DI -> (type, label_ptr, var_ptr)

    mov     dh, bl
    add     dh, 6                   ; Screen row = 6 + idx
    mov     dl, 8                   ; Col 8
    mov     si, [di + 1]            ; Label pointer
    call    pm_print_at

    mov     al, [di]                ; Option type
    cmp     al, OPT_TYPE_BACK
    je      .opt_row_hl

    ; Print value at col 19
    mov     dl, 19
    mov     si, [di + 3]            ; var_ptr
    cmp     al, OPT_TYPE_SCALE
    je      .val_scale
    cmp     al, OPT_TYPE_PAL
    je      .val_pal
    cmp     al, OPT_TYPE_BOOL
    je      .val_bool

    ; OPT_TYPE_KEY
    mov     al, [si]
    push    bx
    call    cfg_scancode_to_name
    pop     bx
    jmp     short .print_val

.val_scale:
    mov     al, [si]
    mov     si, str_val_center
    cmp     al, SCALE_WIDE
    jne     .print_val
    mov     si, str_val_wide
    jmp     short .print_val

.val_pal:
    mov     al, [si]
    and     ax, 03h
    shl     ax, 1
    push    bx
    mov     bx, ax
    mov     si, [palette_str_tab + bx]
    pop     bx
    jmp     short .print_val

.val_bool:
    mov     al, [si]
    mov     si, str_val_off
    test    al, al
    jz      .print_val
    mov     si, str_val_on

.print_val:
    call    pm_print_at

.opt_row_hl:
    cmp     bl, [opt_sel]
    jne     .opt_next_row
    mov     al, dh
    call    pm_invert_row
.opt_next_row:
    inc     bx
    cmp     bx, OPT_ITEM_COUNT
    jb      .opt_row_loop

    mov     dx, 1407h               ; Row 20, Col 7
    mov     si, str_opt_hint
    call    pm_print_at

.opt_wait_key:
    xor     ah, ah
    int     16h

    cmp     al, 1Bh                 ; ESC -> Save & Back
    je      near .opt_save_exit
    cmp     ah, 48h                 ; Up
    je      .opt_up
    cmp     ah, 50h                 ; Down
    je      .opt_down
    cmp     ah, 4Bh                 ; Left arrow
    je      .opt_dec
    cmp     ah, 4Dh                 ; Right arrow
    je      .opt_inc
    cmp     al, 0Dh                 ; Enter
    je      .opt_inc
    cmp     al, ' '                 ; Space
    je      .opt_inc
    jmp     short .opt_wait_key

.opt_up:
    mov     al, [opt_sel]
    or      al, al
    jnz     .ou_ok
    mov     al, OPT_ITEM_COUNT
.ou_ok:
    dec     al
    mov     [opt_sel], al
    jmp     .opt_redraw

.opt_down:
    mov     al, [opt_sel]
    inc     al
    cmp     al, OPT_ITEM_COUNT
    jb      .od_ok
    xor     al, al
.od_ok:
    mov     [opt_sel], al
    jmp     .opt_redraw

.opt_dec:
    mov     cx, -1
    jmp     short .opt_edit
.opt_inc:
    mov     cx, 1
.opt_edit:
    mov     al, [opt_sel]
    xor     ah, ah
    imul    ax, 5
    mov     di, opt_table
    add     di, ax
    mov     al, [di]
    mov     si, [di + 3]

    cmp     al, OPT_TYPE_BACK
    je      .opt_save_exit
    cmp     al, OPT_TYPE_KEY
    je      .opt_rebind_key
    cmp     al, OPT_TYPE_PAL
    je      .opt_edit_pal

    ; OPT_TYPE_SCALE or OPT_TYPE_BOOL: toggle 0 <-> 1
    xor     byte [si], 1
    cmp     si, cfg_sound
    jne     .opt_redraw
    cmp     byte [cfg_sound], 0
    jne     .opt_redraw
    call    spk_mute
    jmp     .opt_redraw

.opt_edit_pal:
    mov     al, [si]
    add     al, cl
    and     al, 03h
    mov     [si], al
    call    cfg_apply_palette
    jmp     .opt_redraw

.opt_rebind_key:
    ; Show "Press key..." prompt on the selected value column
    mov     dh, [opt_sel]
    add     dh, 6
    mov     al, dh
    call    pm_invert_row           ; Un-invert briefly so prompt text is readable
    mov     dl, 19
    push    si
    mov     si, str_press_key
    call    pm_print_at
    pop     si

    xor     ah, ah
    int     16h
    cmp     ah, SCAN_ESC
    je      .opt_redraw
    mov     al, ah
    push    si
    push    ax
    call    cfg_scancode_to_name
    pop     ax
    pop     si
    jc      .opt_redraw             ; Ignore unsupported modifier/F-keys
    mov     [si], al
    jmp     .opt_redraw

.opt_save_exit:
    call    cfg_save_ini
    call    cfg_apply_palette
    ret

; ------------------------------------------------------------------------------
; Drawing & Keyboard Helpers (CGA Mode 04h, ES/DS = CS)
; ------------------------------------------------------------------------------

; pm_cga_offset: Scanline AX (0..199) -> byte offset AX in B800h (clobbers DX)
pm_cga_offset:
    push    ax
    shr     ax, 1
    mov     dx, CGA_BYTES_PER_LINE
    mul     dx
    pop     dx
    test    dx, 1
    jz      .pco_done
    add     ax, CGA_ODD_OFFSET
.pco_done:
    ret

; pm_draw_box: Draws white window with black border at scanlines y=23..176, x_bytes=11..68
pm_draw_box:
    push    es
    mov     ax, CGA_VRAM_SEG
    mov     es, ax
    cld

    mov     bx, 23
.pdb_line:
    mov     ax, bx
    call    pm_cga_offset
    add     ax, 11
    mov     di, ax

    cmp     bx, 23
    je      .pdb_hborder
    cmp     bx, 176
    je      .pdb_hborder

    ; Interior row: left pixel border, 56 white bytes, right pixel border
    mov     al, 03h
    stosb
    xor     al, al
    mov     cx, 56
    rep     stosb
    mov     al, 0C0h
    stosb
    jmp     short .pdb_next

.pdb_hborder:
    mov     al, 03h
    stosb
    mov     al, 0FFh
    mov     cx, 56
    rep     stosb
    mov     al, 0C0h
    stosb

.pdb_next:
    inc     bx
    cmp     bx, 176
    jbe     .pdb_line
    pop     es
    ret

; pm_invert_row: Invert 8 scanlines of text row AL inside box (x_bytes=13..66)
pm_invert_row:
    push    ax
    push    bx
    push    cx
    push    dx
    push    di
    push    es

    mov     bx, CGA_VRAM_SEG
    mov     es, bx
    xor     ah, ah
    shl     ax, 3                   ; AL * 8 = start scanline
    mov     bx, ax
    mov     cx, 8
.pir_line:
    push    cx
    mov     ax, bx
    call    pm_cga_offset
    add     ax, 13
    mov     di, ax
    mov     cx, 54
.pir_byte:
    xor     byte [es:di], 0FFh
    inc     di
    loop    .pir_byte
    inc     bx
    pop     cx
    loop    .pir_line

    pop     es
    pop     di
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; pm_print_at: Print CS:SI ASCIIZ string at DH=row, DL=col using BIOS INT 10h
pm_print_at:
    push    ax
    push    bx
    push    dx
    push    si
    mov     ah, 02h
    xor     bh, bh
    int     10h
.ppa_loop:
    mov     al, [cs:si]
    inc     si
    test    al, al
    jz      .ppa_done
    mov     ah, 0Eh
    mov     bx, 0003h               ; Page 0, Color 3 (black on white interior)
    int     10h
    jmp     short .ppa_loop
.ppa_done:
    pop     si
    pop     dx
    pop     bx
    pop     ax
    ret

; pm_drain_keys: Empty pending BIOS keyboard buffer
pm_drain_keys:
    push    ax
.pdk_loop:
    mov     ah, 01h
    int     16h
    jz      .pdk_done
    xor     ah, ah
    int     16h
    jmp     short .pdk_loop
.pdk_done:
    pop     ax
    ret

; --- Data in CS ---
pm_sel:             db 0
opt_sel:            db 0
pm_status_ptr:      dw 0

str_pm_title:       db "GB200LX PAUSED", 0
str_pm_resume:      db "Resume Game", 0
str_pm_save:        db "Save State", 0
str_pm_load:        db "Load State", 0
str_pm_opts:        db "Options", 0
str_pm_quit:        db "Quit", 0
str_pm_hint:        db "Up/Dn:Sel Ent:OK ESC:Play", 0

str_msg_saved:      db "Saved GBSTATE0.SAV!", 0
str_msg_save_err:   db "Save failed!", 0
str_msg_no_state:   db "No valid GBSTATE0.SAV!", 0

pm_item_ptrs:
    dw str_pm_resume
    dw str_pm_save
    dw str_pm_load
    dw str_pm_opts
    dw str_pm_quit

str_opt_title:      db "OPTIONS MENU", 0
str_opt_hint:       db "L/R/Ent:Edit  ESC:Save", 0
str_val_on:         db "ON", 0
str_val_off:        db "OFF", 0
str_press_key:      db "Press key...", 0

str_opt_scale:      db "Scaling :", 0
str_opt_pal:        db "Palette :", 0
str_opt_vsync:      db "VSync   :", 0
str_opt_sound:      db "Sound   :", 0
str_opt_up:         db "D-Pad Up:", 0
str_opt_dn:         db "D-Pad Dn:", 0
str_opt_lt:         db "D-Pad Lt:", 0
str_opt_rt:         db "D-Pad Rt:", 0
str_opt_a:          db "Button A:", 0
str_opt_b:          db "Button B:", 0
str_opt_sel:        db "Select  :", 0
str_opt_start:      db "Start   :", 0
str_opt_menu:       db "Menu Key:", 0
str_opt_back:       db "< Save & Back >", 0

opt_table:
    db OPT_TYPE_SCALE
    dw str_opt_scale, cfg_scaling
    db OPT_TYPE_PAL
    dw str_opt_pal,   cfg_palette
    db OPT_TYPE_BOOL
    dw str_opt_vsync, cfg_vsync
    db OPT_TYPE_BOOL
    dw str_opt_sound, cfg_sound
    db OPT_TYPE_KEY
    dw str_opt_up,    cfg_key_up
    db OPT_TYPE_KEY
    dw str_opt_dn,    cfg_key_down
    db OPT_TYPE_KEY
    dw str_opt_lt,    cfg_key_left
    db OPT_TYPE_KEY
    dw str_opt_rt,    cfg_key_right
    db OPT_TYPE_KEY
    dw str_opt_a,     cfg_key_a
    db OPT_TYPE_KEY
    dw str_opt_b,     cfg_key_b
    db OPT_TYPE_KEY
    dw str_opt_sel,   cfg_key_select
    db OPT_TYPE_KEY
    dw str_opt_start, cfg_key_start
    db OPT_TYPE_KEY
    dw str_opt_menu,  cfg_key_menu
    db OPT_TYPE_BACK
    dw str_opt_back,  0
