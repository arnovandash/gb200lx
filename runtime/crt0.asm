; ==============================================================================
; crt0.asm - Standalone 16-Bit MS-DOS Executable Harness for HP 200LX
; Allocates 64 KiB Game Boy memory, sets up CGA Mode 04h, draws centered
; test pattern, hooks INT 09h for ESC exit, and cleanly restores text mode.
; Packed into MZ .EXE format via tools/mzpack.py.
; ==============================================================================

bits 16
cpu 186
org 0

%include "runtime/config_ini.inc"
%include "runtime/video_cga.inc"

; ------------------------------------------------------------------------------
; PROGRAM ENTRY POINT
; ------------------------------------------------------------------------------
entry:
    ; DOS MZ Loader initializes:
    ;   CS:IP = Code segment : 0000h
    ;   SS:SP = Code segment : stack_top
    ;   DS, ES = PSP segment
    mov     ax, cs
    mov     ds, ax                  ; DS = program data/code segment

    ; Initialize Configuration from GB200LX.INI or interactive /SETUP
    ; Note: ES currently points to PSP segment
    call    cfg_init
    jnc     .cfg_ok
    ; User exited from /SETUP screen
    mov     ax, 4C00h
    int     21h

.cfg_ok:
    ; Check PSP command line (ES:80h) for '/t' or '/T' (automated test flag)
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
    mov     word [auto_exit_frames], 60 ; Run 60 frames (~1 sec) then exit

.no_cmd_params:
    ; 1. Allocate 64 KiB Game Boy memory segment.
    ; DOS MZ header reserves 1000h paragraphs (64 KiB) directly above our image.
    mov     ax, cs
    mov     bx, image_end
    add     bx, 15
    shr     bx, 4                   ; bx = image size in paragraphs
    add     ax, bx
    mov     [gb_mem_seg], ax        ; Save 64 KiB Game Boy memory segment

    ; 2. Zero-initialize the 64 KiB Game Boy memory block
    mov     es, ax
    xor     di, di
    xor     ax, ax
    mov     cx, 32768               ; 32768 words = 65,536 bytes
    cld
    rep     stosw

    ; 3. Hook INT 09h (Keyboard IRQ1) to handle ESC key exit cleanly
    call    hook_int09

    ; 4. Switch to CGA Mode 04h (320x200, 4-shade grayscale on HP 200LX)
    call    cga_init

    ; 5. Draw the 160x144 4-shade test pattern centered in viewport
    call    cga_draw_test_pattern

    ; 6. Main event loop: wait for ESC key press or frame timeout
.main_loop:
    cmp     byte [exit_requested], 1
    jne     .wait_frame
    jmp     .do_exit

.wait_frame:
    ; Wait for vertical retrace (CGA status port 03DAh, bit 3) with safety counter
    mov     dx, 03DAh
    mov     cx, 30000
.wait_not_vr:
    in      al, dx
    test    al, 08h
    jz      .wait_vr_start
    loop    .wait_not_vr
.wait_vr_start:
    mov     cx, 30000
.wait_vr:
    in      al, dx
    test    al, 08h
    jnz     .vr_done
    loop    .wait_vr
.vr_done:

    ; If auto_exit_frames is active, count down
    cmp     word [auto_exit_frames], 0
    je      .check_bios_key
    dec     word [auto_exit_frames]
    jnz     .check_bios_key
    mov     byte [exit_requested], 1
    jmp     .main_loop

.check_bios_key:
    ; Also check BIOS keyboard buffer (INT 16h AH=01h) in case ESC arrived via BIOS
    mov     ah, 01h
    int     16h
    jz      .main_loop
    ; Key is available, read it
    mov     ah, 00h
    int     16h
    cmp     al, 1Bh                 ; 1Bh = ESC key ASCII
    jne     .main_loop
    mov     byte [exit_requested], 1
    jmp     .main_loop

.do_exit:
    ; Dump CGA VRAM to CGA_VRAM.BIN for visual verification before exiting
    call    dump_cga_vram

    ; 7. Restore standard 80x25 text mode (Mode 03h)
    call    cga_restore_text

    ; 8. Restore original INT 09h vector
    call    unhook_int09

    ; 9. Print banner and exit to DOS cleanly
    mov     ax, cs
    mov     ds, ax
    mov     dx, msg_success
    call    print_dos_string

    mov     ax, 4C00h               ; Exit with return code 0
    int     21h

; ------------------------------------------------------------------------------
; INT 09h Keyboard ISR Hook
; ------------------------------------------------------------------------------
hook_int09:
    push    es
    ; Get current INT 09h vector
    mov     ax, 3509h
    int     21h
    mov     [old_int09_off], bx
    mov     [old_int09_seg], es

    ; Set our INT 09h vector
    push    ds
    mov     ax, cs
    mov     ds, ax
    mov     dx, int09_handler
    mov     ax, 2509h
    int     21h
    pop     ds
    pop     es
    ret

unhook_int09:
    push    ds
    ; Restore original INT 09h vector
    mov     dx, [old_int09_off]
    mov     ds, [old_int09_seg]
    mov     ax, 2509h
    int     21h
    pop     ds
    ret

int09_handler:
    push    ax
    push    ds

    mov     ax, cs
    mov     ds, ax

    ; Read scan code from keyboard controller port 60h
    in      al, 60h

    ; Check configured exit key (default: ESC / SCAN_ESC)
    cmp     al, [cfg_key_menu]
    je      .handle_exit

    ; Also accept ESC (01h) unconditionally as failsafe exit
    cmp     al, 01h
    je      .handle_exit

    jmp     .chain_old

.handle_exit:
    ; Exit requested
    mov     byte [exit_requested], 1

    ; Acknowledge keyboard to 8255 / keyboard controller
    in      al, 61h
    mov     ah, al
    or      al, 80h                 ; Disable keyboard
    out     61h, al
    mov     al, ah                  ; Re-enable keyboard
    out     61h, al

    ; Send End Of Interrupt (EOI) to 8259 PIC
    mov     al, 20h
    out     20h, al

    pop     ds
    pop     ax
    iret

.chain_old:
    pop     ds
    pop     ax
    ; Jump far to previous INT 09h handler
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
    mov     dx, fn_vram_dump
    mov     ah, 3Ch                 ; Create file
    xor     cx, cx
    int     21h
    jc      .dump_done
    mov     bx, ax                  ; BX = file handle

    ; Write even bank (8000 bytes at B800:0000)
    mov     ax, CGA_VRAM_SEG
    mov     ds, ax
    xor     dx, dx
    mov     cx, 8000
    mov     ah, 40h
    int     21h

    ; Write odd bank (8000 bytes at B800:2000)
    mov     dx, CGA_ODD_OFFSET
    mov     cx, 8000
    mov     ah, 40h
    int     21h

    ; Close file
    mov     ah, 3Eh
    int     21h

.dump_done:
    pop     ds
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ------------------------------------------------------------------------------
; Helper: Print DOS $-terminated string at DS:DX
; ------------------------------------------------------------------------------
print_dos_string:
    push    ax
    mov     ah, 09h
    int     21h
    pop     ax
    ret

; ------------------------------------------------------------------------------
; DATA
; ------------------------------------------------------------------------------
fn_vram_dump:       db  "CGA_VRAM.BIN", 0
global gb_mem_seg
gb_mem_seg:         dw  0           ; Paragraph segment for 64 KiB Game Boy RAM
exit_requested:     db  0           ; Set to 1 when ESC pressed
auto_exit_frames:   dw  0           ; Frame count for auto-exit in test mode

old_int09_off:      dw  0           ; Saved INT 09h offset
old_int09_seg:      dw  0           ; Saved INT 09h segment

msg_success:
    db  0Dh, 0Ah
    db  "============================================================", 0Dh, 0Ah
    db  "HP 200LX Static GB Recompiler - CGA Bring-Up Harness", 0Dh, 0Ah
    db  "Allocated 64 KiB GB memory segment, ran CGA 04h test pattern.", 0Dh, 0Ah
    db  "Cleanly restored text mode 03h. Test complete!", 0Dh, 0Ah
    db  "============================================================", 0Dh, 0Ah, "$"

; Include video driver code directly into image
%include "runtime/video_cga.asm"
%include "runtime/config_ini.asm"

; ------------------------------------------------------------------------------
; STACK
; ------------------------------------------------------------------------------
    align 16
stack_bottom:
    times 512 dw 0                  ; 1024-byte stack
stack_top:

image_end:
