; ==============================================================================
; savestate.asm - Quick Save / Load State Support (F5 Save / F9 Load)
; Snapshots & restores 64 KiB Game Boy memory, active 80186 hardware stack,
; interrupt/timer/PPU state, and APU state to GBSTATE0.SAV via DOS INT 21h.
; ==============================================================================

bits 16
cpu 186

STATE_MAGIC_LEN     equ 8
STATE_HDR_SIZE      equ 64
STATE_STACK_MAX     equ 512
DOS_STACK_TOP       equ 8000h       ; mzpack stack_paras = 0800h -> SP_top = 8000h

; ------------------------------------------------------------------------------
; savestate_save: Called from helper_halt when save_requested == 1.
; Saves current machine state to GBSTATE0.SAV. Preserves SP and CPU state.
; ------------------------------------------------------------------------------
global halt_sp_base, save_ok
savestate_save:
    pushf
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    ds
    push    es

    mov     byte [cs:save_requested], 0
    call    spk_mute

    ; Hardware SP inside helper_halt (before our call + 9 pushes = SP + 20)
    mov     ax, sp
    add     ax, 20
.save_with_ax:
    mov     byte [cs:save_ok], 0
    cmp     ax, DOS_STACK_TOP
    jae     near .save_done
    mov     bx, DOS_STACK_TOP
    sub     bx, ax
    cmp     bx, STATE_STACK_MAX
    ja      near .save_done

    ; Build 64-byte header in CS:state_hdr
    push    ax                      ; Save halt_sp
    mov     ax, cs
    mov     ds, ax
    mov     es, ax

    ; Copy ROM header checksum (gb_mem_seg:014Eh) to guard cross-ROM loads
    mov     es, [gb_mem_seg]
    mov     ax, [es:014Eh]
    mov     [state_hdr_romchk], ax

    pop     ax                      ; AX = halt_sp
    mov     [state_hdr_sp], ax
    mov     [state_hdr_sslen], bx
    mov     [state_hdr_cs], cs

    mov     al, [gb_ime]
    mov     [state_hdr_ime], al
    mov     al, [current_rom_bank]
    mov     [state_hdr_bank], al
    mov     al, [emulated_ly]
    mov     [state_hdr_ly], al
    mov     al, [div_counter]
    mov     [state_hdr_div], al
    mov     al, [hud_scy]
    mov     [state_hdr_hscy], al
    mov     al, [hud_scx]
    mov     [state_hdr_hscx], al

    mov     ax, cs
    mov     es, ax
    mov     si, apu_state_start
    mov     di, state_hdr_apu
    mov     cx, (apu_state_end - apu_state_start)
    cld
    rep     movsb

    ; Copy active hardware stack SS:[halt_sp .. 8000h) into CS:state_stack_buf
    mov     ax, ss
    mov     ds, ax
    mov     si, [cs:state_hdr_sp]
    mov     di, state_stack_buf
    mov     cx, [cs:state_hdr_sslen]
    rep     movsb

    ; Create GBSTATE0.SAV (INT 21h AH=3Ch)
    mov     ax, cs
    mov     ds, ax
    mov     dx, fn_savestate
    xor     cx, cx
    mov     ah, 3Ch
    int     21h
    jc      short .save_done
    mov     bx, ax                  ; BX = DOS file handle

    ; 1. Write 64-byte header
    mov     dx, state_hdr
    mov     cx, STATE_HDR_SIZE
    mov     ah, 40h
    int     21h

    ; 2. Write active hardware stack slice
    mov     dx, state_stack_buf
    mov     cx, [state_hdr_sslen]
    mov     ah, 40h
    int     21h

    ; 3. Write 64 KiB Game Boy memory (two 32 KiB chunks)
    mov     ax, [cs:gb_mem_seg]
    mov     ds, ax
    xor     dx, dx
    mov     cx, 8000h
    mov     ah, 40h
    int     21h

    mov     dx, 8000h
    mov     cx, 8000h
    mov     ah, 40h
    int     21h

    ; Close file
    mov     ah, 3Eh
    int     21h
    mov     byte [cs:save_ok], 1

.save_done:
    cli
    mov     word [cs:frame_ticks], 1
    sti
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

; Entry point for Pause Menu "Save State": uses halt_sp_base captured in helper_halt
global savestate_save_from_pause
savestate_save_from_pause:
    pushf
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    ds
    push    es
    call    spk_mute
    mov     ax, [cs:halt_sp_base]
    jmp     savestate_save.save_with_ax

; ------------------------------------------------------------------------------
; savestate_open_valid: Open GBSTATE0.SAV and validate header + ROM checksum.
; Output: CF = 0 -> BX = open DOS file handle, CX = state_hdr_sslen, DS = CS
;         CF = 1 -> invalid or missing (file already closed)
; ------------------------------------------------------------------------------
savestate_open_valid:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax

    mov     dx, fn_savestate
    mov     ax, 3D00h
    int     21h
    jc      short .ov_fail
    mov     bx, ax

    mov     dx, state_hdr
    mov     cx, STATE_HDR_SIZE
    mov     ah, 3Fh
    int     21h
    jc      short .ov_close_fail
    cmp     ax, STATE_HDR_SIZE
    jne     short .ov_close_fail

    mov     si, state_hdr
    mov     di, state_magic_ref
    mov     cx, STATE_MAGIC_LEN
    cld
    repe    cmpsb
    jne     short .ov_close_fail

    mov     es, [gb_mem_seg]
    mov     ax, [es:014Eh]
    cmp     ax, [state_hdr_romchk]
    jne     short .ov_close_fail

    mov     cx, [state_hdr_sslen]
    or      cx, cx
    jz      short .ov_close_fail
    cmp     cx, STATE_STACK_MAX
    ja      short .ov_close_fail
    mov     ax, [state_hdr_sp]
    add     ax, cx
    cmp     ax, DOS_STACK_TOP
    jne     short .ov_close_fail

    clc
    ret

.ov_close_fail:
    mov     ah, 3Eh
    int     21h
.ov_fail:
    stc
    ret

; ------------------------------------------------------------------------------
; savestate_validate: Check if a valid GBSTATE0.SAV exists for current ROM.
; Output: CF = 0 if valid, CF = 1 if missing/invalid. Clobbers AX, BX, CX, DX, SI, DI, DS, ES.
; ------------------------------------------------------------------------------
global savestate_validate
savestate_validate:
    call    savestate_open_valid
    jc      short .sv_done
    mov     ah, 3Eh
    int     21h
    clc
.sv_done:
    ret

; ------------------------------------------------------------------------------
; savestate_load: Tail-jumped from helper_halt when load_requested == 1.
; Validates GBSTATE0.SAV, reads into buffers, restores SS:SP + GB RAM atomically,
; and jumps directly to helper_halt.do_render (or returns to .pace_wait on error).
; ------------------------------------------------------------------------------
savestate_load:
    mov     byte [cs:load_requested], 0
    call    spk_mute

    call    savestate_open_valid
    jc      near .load_abort

    ; 2. Read saved hardware stack into temporary CS:state_stack_buf
    mov     dx, state_stack_buf
    mov     ah, 3Fh
    int     21h
    jc      near .load_close_abort
    cmp     ax, cx
    jne     near .load_close_abort

    ; 3. Read 64 KiB Game Boy memory directly into gb_mem_seg
    mov     ax, [cs:gb_mem_seg]
    mov     ds, ax
    xor     dx, dx
    mov     cx, 8000h
    mov     ah, 3Fh
    int     21h
    jc      near .load_close_abort
    cmp     ax, 8000h
    jne     near .load_close_abort

    mov     dx, 8000h
    mov     cx, 8000h
    mov     ah, 3Fh
    int     21h
    jc      near .load_close_abort
    cmp     ax, 8000h
    jne     near .load_close_abort

    mov     ah, 3Eh
    int     21h

    ; --- Atomic machine-state switch ---
    cli
    mov     ax, cs
    mov     ds, ax

    ; Relocate any segment words on the saved hardware stack if DOS loaded us
    ; at a different CS paragraph than when the state was saved.
    mov     dx, cs
    sub     dx, [state_hdr_cs]      ; DX = CS relocation delta
    jz      short .no_reloc

    mov     ax, [state_hdr_cs]
    mov     [reloc_old_segs + 0], ax
%ifndef OVL_MODE
    mov     cx, ax
    add     cx, SEG1_PARAS_VAL
    mov     [reloc_old_segs + 2], cx
    mov     cx, ax
    add     cx, SEG2_PARAS_VAL
    mov     [reloc_old_segs + 4], cx
    mov     cx, ax
    add     cx, SEG3_PARAS_VAL
    mov     [reloc_old_segs + 6], cx
    add     ax, SEG_ROM_PARAS_VAL
    add     ax, 1000h               ; old gb_mem_seg
    mov     [reloc_old_segs + 8], ax
    add     ax, 1000h               ; old backbuffer_seg
    mov     [reloc_old_segs + 10], ax
%else
    add     ax, SEG_ROM_PARAS_VAL   ; old gb_mem_seg
    mov     [reloc_old_segs + 2], ax
    add     ax, 1000h               ; old backbuffer_seg
    mov     [reloc_old_segs + 4], ax
    mov     [reloc_old_segs + 6], ax
    mov     [reloc_old_segs + 8], ax
    mov     [reloc_old_segs + 10], ax
%endif

    mov     si, state_stack_buf
    mov     cx, [state_hdr_sslen]
    shr     cx, 1                   ; word count
.reloc_word:
    mov     ax, [si]
    mov     bx, 10
.reloc_chk:
    cmp     ax, [reloc_old_segs + bx]
    je      short .reloc_hit
    sub     bx, 2
    jns     short .reloc_chk
    jmp     short .reloc_next
.reloc_hit:
    add     ax, dx
    mov     [si], ax
.reloc_next:
    add     si, 2
    loop    .reloc_word

.no_reloc:
    ; Copy restored hardware stack to SS:state_hdr_sp and switch SP
    mov     ax, ss
    mov     es, ax
    mov     si, state_stack_buf
    mov     di, [state_hdr_sp]
    mov     sp, di
    mov     cx, [state_hdr_sslen]
    cld
    rep     movsb

    ; Restore runtime & APU state
    mov     al, [state_hdr_ime]
    mov     [gb_ime], al
    mov     al, [state_hdr_bank]
    mov     [current_rom_bank], al
    mov     al, [state_hdr_ly]
    mov     [emulated_ly], al
    mov     al, [state_hdr_div]
    mov     [div_counter], al
    mov     al, [state_hdr_hscy]
    mov     [hud_scy], al
    mov     al, [state_hdr_hscx]
    mov     [hud_scx], al

    mov     ax, cs
    mov     es, ax
    mov     si, state_hdr_apu
    mov     di, apu_state_start
    mov     cx, (apu_state_end - apu_state_start)
    rep     movsb
    mov     word [apu_cur_div], 0

    ; Invalidate BGP + tile cache so next render decodes restored VRAM completely
    mov     byte [last_bgp], 0FFh
    mov     di, tile_dirty
    mov     ax, 0101h
    mov     cx, 192
    rep     stosw

    ; Release any held keys and reset frame pacing
    mov     byte [joypad_dir], 0Fh
    mov     byte [joypad_act], 0Fh
    mov     byte [joypad_dir_latch], 0FFh
    mov     byte [joypad_act_latch], 0FFh
    mov     byte [skip_run], 0
    mov     word [frame_ticks], 1
    sti
    jmp     near helper_halt.do_render

.load_close_abort:
    mov     ah, 3Eh
    int     21h
.load_abort:
    cli
    mov     word [cs:frame_ticks], 1
    sti
    jmp     near helper_halt.pace_wait

; --- Save state data in CS ---
global save_requested, load_requested
save_requested:     db 0
load_requested:     db 0
halt_sp_base:       dw 0
save_ok:            db 0
fn_savestate:       db "GBSTATE0.SAV", 0
state_magic_ref:    db "GB200ST1"
reloc_old_segs:     times 6 dw 0

state_hdr:
    db "GB200ST1"                   ; +00: magic (8 bytes)
state_hdr_romchk:   dw 0            ; +08: ROM 0x014E..0x014F checksum
state_hdr_cs:       dw 0            ; +10: CS at save time
state_hdr_sp:       dw 0            ; +12: SP inside helper_halt
state_hdr_sslen:    dw 0            ; +14: stack byte count
state_hdr_ime:      db 0            ; +16
state_hdr_bank:     db 1            ; +17
state_hdr_ly:       db 148          ; +18
state_hdr_div:      db 0            ; +19
state_hdr_hscy:     db 0            ; +20
state_hdr_hscx:     db 0            ; +21
state_hdr_apu:      times (apu_state_end - apu_state_start) db 0 ; +22..38
                    times (STATE_HDR_SIZE - ($ - state_hdr)) db 0

state_stack_buf:    times STATE_STACK_MAX db 0
