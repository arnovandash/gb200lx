; ==============================================================================
; crt0_rom.asm - Standalone Game Boy Recompiler Executable Harness for HP 200LX
; Initializes 64 KiB Game Boy memory, CGA Mode 04h, embedded ROM banks,
; loads GB200LX.INI / interactive /SETUP, hooks INT 09h joypad, and runs the game.
; ==============================================================================

bits 16
cpu 186

%include "runtime/config_ini.inc"
%include "runtime/video_cga.inc"

%ifndef SEG1_PARAS_VAL
    %define SEG1_PARAS_VAL 01111h
    %define SEG2_PARAS_VAL 02222h
    %define SEG3_PARAS_VAL 03333h
%endif
%ifndef SEG_ROM_PARAS_VAL
    %define SEG_ROM_PARAS_VAL 04444h
%endif

; ------------------------------------------------------------------------------
; PROGRAM ENTRY POINT
; ------------------------------------------------------------------------------
entry:
    ; DOS MZ Loader initializes:
    ;   CS:IP = Code segment : 0000h
    ;   SS:SP = Code segment : stack_top
    ;   DS, ES = PSP segment
    mov     ax, cs
    mov     ds, ax                  ; DS = program segment (ES preserved as PSP!)
    mov     ax, [es:0002h]          ; Save PSP top-of-DOS-memory segment
    mov     [psp_mem_top], ax

    ; Check PSP command line (ES:80h) BEFORE any calls that might clobber ES
    mov     cl, [es:80h]            ; command line length
    xor     ch, ch
    jcxz    .no_cmd_params
    mov     si, 81h
.scan_param:
    mov     al, [es:si]
    cmp     al, 't'
    je      .enable_auto_exit
    cmp     al, 'T'
    je      .enable_auto_exit
    inc     si
    loop    .scan_param
    jmp     .no_cmd_params

.enable_auto_exit:
    mov     word [auto_exit_frames], 120 ; Run 120 frames (~2 sec) in test mode

.no_cmd_params:
    ; 1. Initialize Configuration from GB200LX.INI or interactive /SETUP
    ; Note: ES still points to PSP segment for cfg_check_setup_cmd!
    call    cfg_init
    mov     ax, cs
    mov     es, ax
    jnc     .cfg_ok
    ; User exited from /SETUP screen
    mov     ax, 4C00h
    int     21h

.cfg_ok:
    ; 2. Calculate segment bases
    mov     ax, cs
    mov     [seg_bank0], ax

%ifndef OVL_MODE
    mov     cx, ax
    add     cx, SEG1_PARAS_VAL
    mov     [seg_bank1], cx

    mov     cx, ax
    add     cx, SEG2_PARAS_VAL
    mov     [seg_bank2], cx

    mov     cx, ax
    add     cx, SEG3_PARAS_VAL
    mov     [seg_bank3], cx

    mov     cx, ax
    add     cx, SEG_ROM_PARAS_VAL
    mov     [seg_rom_data], cx

    ; 3. Allocate 64 KiB Game Boy memory segment directly above entire image
    mov     ax, [seg_rom_data]
    add     ax, 1000h               ; ax = paragraph base of 64 KiB Game Boy memory block
%else
    ; Overlay mode: 64 KiB GB memory starts right above seg0 (at CS + SEG_ROM_PARAS_VAL)
    add     ax, SEG_ROM_PARAS_VAL
%endif
    mov     [gb_mem_seg], ax        ; Save 64 KiB Game Boy memory segment
    add     ax, 1000h               ; ax = paragraph base of 8 KiB CGA backbuffer segment
    mov     [backbuffer_seg], ax

    ; 4. Zero-initialize the 64 KiB Game Boy memory block
    mov     es, [gb_mem_seg]
    xor     di, di
    xor     ax, ax
    mov     cx, 32768               ; 32768 words = 65,536 bytes
    cld
    rep     stosw

%ifndef OVL_MODE
    ; 5. Copy Bank 0 (16 KiB) from ROM data into DS:[0x0000..0x3FFF]
    mov     ax, [seg_rom_data]
    mov     ds, ax
    xor     si, si                  ; DS:SI = ROM Bank 0
    mov     es, [cs:gb_mem_seg]
    xor     di, di                  ; ES:DI = GB RAM 0x0000
    mov     cx, 8192                ; 8192 words = 16,384 bytes
    rep     movsw

    ; 6. Copy Bank 1 (16 KiB) from ROM data into DS:[0x4000..0x7FFF]
    mov     si, 4000h               ; DS:SI = ROM Bank 1
    mov     di, 4000h               ; ES:DI = GB RAM 0x4000
    mov     cx, 8192
    rep     movsw
%else
    ; Open GAME.OVL, allocate code/data cache slots, and load Bank 0 + Bank 1
    call    ovl_init
%endif

    ; Restore DS to CS
    mov     ax, cs
    mov     ds, ax
    mov     es, ax

    ; 7. Hook INT 09h (Keyboard IRQ1) for joypad input and ESC exit
    call    hook_int09

    ; 7b. Hook INT 08h + reprogram PIT ch0 to the Game Boy frame rate (59.73 Hz)
    call    hook_int08

    ; 8. Switch to CGA Mode 04h (320x200 4-shade grayscale on HP 200LX)
    call    cga_init

    ; 9. Draw viewport border
    call    cga_draw_border

    ; 10. Initialize Game Boy hardware state
    mov     byte [cs:gb_ime], 0
    mov     byte [cs:current_rom_bank], 1
    mov     byte [cs:emulated_ly], 148 ; 0x94 (VBlank)

    ; Initialize BGP palette table (default 0xE4)
    mov     al, 0E4h
    mov     es, [cs:gb_mem_seg]
    mov     [es:0FF47h], al
    call    helper_update_bgp

    ; Set initial Game Boy CPU registers matching DMG bootrom completion:
    ; A = 0x01, F = 0xB0 (Z=1, N=0, H=1, C=1)
    ; BC = 0x0013, DE = 0x00D8, HL = 0x014D, SP = 0xFFFE
    mov     al, 01h
    mov     ah, 0B0h
    mov     bx, 0013h
    mov     dx, 00D8h
    mov     cx, 014Dh
    mov     di, 0FFFEh

    ; Set DS = 64 KiB Game Boy memory block for pinned memory addressing
    mov     ax, [cs:gb_mem_seg]
    mov     ds, ax

    ; 11. Call Game Boy entry point (0x0100 -> 0x0150)
    call    near loc_00_0100

; ------------------------------------------------------------------------------
; Main Runtime Event & Frame Loop
; ------------------------------------------------------------------------------
main_game_loop:
.frame_loop:
    cmp     byte [cs:exit_requested], 1
    je      .do_game_exit

    ; Wait for vertical retrace (CGA status port 03DAh, bit 3)
    mov     dx, 03DAh
    mov     bp, 30000
.wait_not_vr:
    in      al, dx
    test    al, 08h
    jz      .wait_vr_start
    dec     bp
    jnz     .wait_not_vr
.wait_vr_start:
    mov     bp, 30000
.wait_vr:
    in      al, dx
    test    al, 08h
    jnz     .vr_done
    dec     bp
    jnz     .wait_vr
.vr_done:

    ; Render Game Boy VRAM to CGA display
    call    cga_render_gb_frame

    ; Inject Game Boy VBlank interrupt (0x0040)
    or      byte [ds:0FF0Fh], 01h       ; Set IF bit 0 (VBlank)
    cmp     byte [cs:gb_ime], 1
    jne     .skip_vblank_isr
    test    byte [ds:0FFFFh], 01h       ; Check IE bit 0
    jz      .skip_vblank_isr

    ; Fire VBlank ISR
    mov     byte [cs:gb_ime], 0         ; Clear IME
    and     byte [ds:0FF0Fh], 0FEh      ; Clear IF bit 0
    sub     di, 2
    mov     word [di], 0000h            ; Return address 0
    call    near loc_00_0040            ; Invoke Game Boy VBlank ISR

.skip_vblank_isr:
    ; Handle auto-exit countdown in test mode (/t)
    cmp     word [cs:auto_exit_frames], 0
    je      .check_bios_key
    dec     word [cs:auto_exit_frames]
    jnz     .check_bios_key
    mov     byte [cs:exit_requested], 1
    jmp     short .frame_loop

.check_bios_key:
    mov     ah, 01h
    int     16h
    jz      .frame_loop
    mov     ah, 00h
    int     16h
    cmp     al, 1Bh                     ; ESC key
    jne     .frame_loop
    mov     byte [cs:menu_requested], 1
    jmp     short .frame_loop

.do_game_exit:
global game_clean_exit
game_clean_exit:
    ; Dump CGA VRAM for test verification
    call    dump_cga_vram

    ; Cleanly restore standard text mode 03h
    call    cga_restore_text

    ; Restore original INT 09h vector
    call    unhook_int09

    ; Silence PC speaker before returning to DOS
    call    spk_mute

    ; Restore PIT to 18.2 Hz and original INT 08h vector
    call    unhook_int08

%ifdef OVL_MODE
    call    ovl_close
%endif

    ; Print exit message and return to DOS
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     dx, msg_game_exit
    call    print_dos_string

    mov     ax, 4C00h
    int     21h

; ------------------------------------------------------------------------------
; INT 09h Keyboard ISR Hook with Keymapping
; ------------------------------------------------------------------------------
hook_int09:
    push    es
    mov     ax, 3509h
    int     21h
    mov     [old_int09_off], bx
    mov     [old_int09_seg], es

    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     dx, int09_handler
    mov     ax, 2509h
    int     21h
    pop     ds
    pop     es
    ret

unhook_int09:
    push    ds
    mov     dx, [cs:old_int09_off]
    mov     ds, [cs:old_int09_seg]
    mov     ax, 2509h
    int     21h
    pop     ds
    ret

; ------------------------------------------------------------------------------
; INT 08h Timer ISR: 59.73 Hz Game Boy frame clock
; PIT ch0 runs at 1193182 / GB_PIT_DIVISOR Hz. Each IRQ adds one pending frame
; tick consumed by helper_halt. The original BIOS handler is chained at the
; average 18.2 Hz rate (accumulator overflow) so the DOS clock stays correct.
; ------------------------------------------------------------------------------
GB_PIT_DIVISOR  equ 19977               ; 1193182 / 59.7275 Hz

hook_int08:
    push    es
    mov     ax, 3508h
    int     21h
    mov     [old_int08_off], bx
    mov     [old_int08_seg], es
    pop     es
    mov     dx, int08_handler           ; DS = CS here
    mov     ax, 2508h
    int     21h
    cli
    mov     al, 36h                     ; ch0, lo/hi byte, mode 3
    out     43h, al
    mov     ax, GB_PIT_DIVISOR
    out     40h, al
    mov     al, ah
    out     40h, al
    sti
    ret

unhook_int08:
    cli
    mov     al, 36h
    out     43h, al
    xor     al, al                      ; divisor 0 = 65536 (18.2 Hz)
    out     40h, al
    out     40h, al
    sti
    push    ds
    mov     dx, [cs:old_int08_off]
    mov     ds, [cs:old_int08_seg]
    mov     ax, 2508h
    int     21h
    pop     ds
    ret

int08_handler:
    push    ax
    inc     word [cs:frame_ticks]
    mov     ax, [cs:pit_accum]
    add     ax, GB_PIT_DIVISOR
    mov     [cs:pit_accum], ax
    jc      .chain_bios                 ; 65536 PIT clocks elapsed -> BIOS tick
    mov     al, 20h
    out     20h, al
    pop     ax
    iret
.chain_bios:
    pop     ax
    jmp     far [cs:old_int08_off]

int09_handler:
    cmp     byte [cs:menu_active], 0
    je      short .game_key
    jmp     far [cs:old_int09_off]

.game_key:
    push    ax
    push    ds
    mov     ax, cs
    mov     ds, ax

    in      al, 60h                     ; Read keyboard controller scancode
    cmp     al, 0E0h                    ; Ignore extended scancode prefix cleanly
    je      .key_ack

    ; Check ESC / cfg_key_menu (Pause Menu) and Save State hotkeys (F5 = 3Fh, F9 = 43h)
    cmp     al, [cfg_key_menu]
    je      .handle_menu
    cmp     al, 01h                     ; Failsafe ESC
    je      .handle_menu
    cmp     al, 3Fh                     ; F5 -> Quick Save State
    je      .handle_save
    cmp     al, 43h                     ; F9 -> Quick Load State
    je      .handle_load

    ; Game Boy Key Mapping
    mov     ah, al
    and     ah, 7Fh                     ; AH = make scancode (bits 6..0)
    test    al, 80h                     ; Bit 7 = 1 on key release
    jnz     .key_released

.key_pressed:
    cmp     ah, [cfg_key_right]
    jne     .kp_left
    and     byte [cs:joypad_dir], ~01h
    and     byte [cs:joypad_dir_latch], ~01h
    jmp     .key_ack
.kp_left:
    cmp     ah, [cfg_key_left]
    jne     .kp_up
    and     byte [cs:joypad_dir], ~02h
    and     byte [cs:joypad_dir_latch], ~02h
    jmp     .key_ack
.kp_up:
    cmp     ah, [cfg_key_up]
    jne     .kp_down
    and     byte [cs:joypad_dir], ~04h
    and     byte [cs:joypad_dir_latch], ~04h
    jmp     .key_ack
.kp_down:
    cmp     ah, [cfg_key_down]
    jne     .kp_a
    and     byte [cs:joypad_dir], ~08h
    and     byte [cs:joypad_dir_latch], ~08h
    jmp     .key_ack
.kp_a:
    cmp     ah, [cfg_key_a]
    jne     .kp_b
    and     byte [cs:joypad_act], ~01h
    and     byte [cs:joypad_act_latch], ~01h
    jmp     .key_ack
.kp_b:
    cmp     ah, [cfg_key_b]
    jne     .kp_sel
    and     byte [cs:joypad_act], ~02h
    and     byte [cs:joypad_act_latch], ~02h
    jmp     .key_ack
.kp_sel:
    cmp     ah, [cfg_key_select]
    jne     .kp_start
    and     byte [cs:joypad_act], ~04h
    and     byte [cs:joypad_act_latch], ~04h
    jmp     .key_ack
.kp_start:
    cmp     ah, [cfg_key_start]
    jne     .chain_old
    and     byte [cs:joypad_act], ~08h
    and     byte [cs:joypad_act_latch], ~08h
    jmp     .key_ack

.key_released:
    cmp     ah, [cfg_key_right]
    jne     .kr_left
    or      byte [cs:joypad_dir], 01h
    jmp     .key_ack
.kr_left:
    cmp     ah, [cfg_key_left]
    jne     .kr_up
    or      byte [cs:joypad_dir], 02h
    jmp     .key_ack
.kr_up:
    cmp     ah, [cfg_key_up]
    jne     .kr_down
    or      byte [cs:joypad_dir], 04h
    jmp     .key_ack
.kr_down:
    cmp     ah, [cfg_key_down]
    jne     .kr_a
    or      byte [cs:joypad_dir], 08h
    jmp     .key_ack
.kr_a:
    cmp     ah, [cfg_key_a]
    jne     .kr_b
    or      byte [cs:joypad_act], 01h
    jmp     .key_ack
.kr_b:
    cmp     ah, [cfg_key_b]
    jne     .kr_sel
    or      byte [cs:joypad_act], 02h
    jmp     .key_ack
.kr_sel:
    cmp     ah, [cfg_key_select]
    jne     .kr_start
    or      byte [cs:joypad_act], 04h
    jmp     .key_ack
.kr_start:
    cmp     ah, [cfg_key_start]
    jne     .chain_old
    or      byte [cs:joypad_act], 08h

.key_ack:
    in      al, 61h
    mov     ah, al
    or      al, 80h
    out     61h, al
    mov     al, ah
    out     61h, al

    mov     al, 20h
    out     20h, al
    pop     ds
    pop     ax
    iret

.handle_menu:
    mov     byte [cs:menu_requested], 1
    jmp     short .key_ack

.handle_save:
    mov     byte [cs:save_requested], 1
    jmp     short .key_ack

.handle_load:
    mov     byte [cs:load_requested], 1
    jmp     short .key_ack

.chain_old:
    pop     ds
    pop     ax
    jmp     far [cs:old_int09_off]

; ------------------------------------------------------------------------------
; Helper: Dump CGA VRAM (16,000 bytes) to CGA_VRAM.BIN
; ------------------------------------------------------------------------------
dump_cga_vram:
    push    ax
    push    bx
    push    cx
    push    dx
    push    ds

    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     dx, fn_vram_dump
    mov     ah, 3Ch
    xor     cx, cx
    int     21h
    jc      .dump_done
    mov     bx, ax

    mov     ax, CGA_VRAM_SEG
    mov     ds, ax
    xor     dx, dx
    mov     cx, 8000
    mov     ah, 40h
    int     21h

    mov     dx, CGA_ODD_OFFSET
    mov     cx, 8000
    mov     ah, 40h
    int     21h

    mov     ah, 3Eh
    int     21h

.dump_done:
    pop     ds
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

print_dos_string:
    push    ax
    mov     ah, 09h
    int     21h
    pop     ax
    ret

; ------------------------------------------------------------------------------
; Variables & Constants
; ------------------------------------------------------------------------------
fn_vram_dump:       db  "CGA_VRAM.BIN", 0
global gb_mem_seg, backbuffer_seg, psp_mem_top
gb_mem_seg:         dw  0
backbuffer_seg:     dw  0
psp_mem_top:        dw  0

global exit_requested, menu_requested, menu_active
exit_requested:     db  0
menu_requested:     db  0
menu_active:        db  0
global auto_exit_frames
auto_exit_frames:   dw  0

old_int09_off:      dw  0
old_int09_seg:      dw  0
old_int08_off:      dw  0
old_int08_seg:      dw  0
pit_accum:          dw  0
global frame_ticks
frame_ticks:        dw  0               ; Pending 59.73 Hz frame ticks (INT 08h)

global seg_bank0, seg_bank1, seg_bank2, seg_bank3, seg_rom_data
seg_bank0:          dw  0
seg_bank1:          dw  0
seg_bank2:          dw  0
seg_bank3:          dw  0
seg_rom_data:       dw  0

global seg1_paras, seg2_paras, seg3_paras, seg_rom_paras
seg1_paras:         dw  0
seg2_paras:         dw  0
seg3_paras:         dw  0
seg_rom_paras:      dw  0

msg_game_exit:
    db  0Dh, 0Ah
    db  "============================================================", 0Dh, 0Ah
    db  "GB200LX - Static Game Boy Recompiler for HP 200LX (80186)", 0Dh, 0Ah
    db  "Executed cleanly, restored text mode 03h.", 0Dh, 0Ah
    db  "============================================================", 0Dh, 0Ah, "$"
