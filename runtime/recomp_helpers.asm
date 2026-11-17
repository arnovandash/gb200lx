; ==============================================================================
; recomp_helpers.asm - Runtime Helpers for Static SM83 to 80186 Recompiler
; Provides MMIO handling, flag pack/unpack, OAM DMA, MBC bank switching,
; and CGA PPU tile/scanline rendering for HP 200LX.
; ==============================================================================

bits 16
cpu 186

%ifndef SRAM_PARAS_VAL
    %define SRAM_PARAS_VAL 0
%endif
%ifndef ROM_BANK_MASK_VAL
    %define ROM_BANK_MASK_VAL 03h
%endif
%ifndef MAPPER_TYPE_VAL
    %define MAPPER_TYPE_VAL 1
%endif

; ------------------------------------------------------------------------------
; PUSH AF: Pack x86 flags into SM83 format in AH, push AF onto GB stack [di]
; Game Boy F: [Z(7) N(6) H(5) C(4) 0 0 0 0]
; x86 FLAGS:  [SF(7) ZF(6) 0 AF(4) 0 PF(2) 1 CF(0)]
; ------------------------------------------------------------------------------
global helper_push_af
helper_push_af:
    pushf
    push    bp
    mov     bp, sp
    mov     bp, [bp+2]          ; BP = saved x86 flags from pushf
    xor     ah, ah
    test    bp, 0040h           ; x86 ZF (bit 6)
    jz      short .no_z
    or      ah, 80h             ; GB Z (bit 7)
.no_z:
    test    bp, 0010h           ; x86 AF (bit 4)
    jz      short .no_h
    or      ah, 20h             ; GB H (bit 5)
.no_h:
    test    bp, 0001h           ; x86 CF (bit 0)
    jz      short .no_c
    or      ah, 10h             ; GB C (bit 4)
.no_c:
    pop     bp

    ; Push onto GB stack: SP decrements by 2.
    ; Byte at [di-2] = F (AH), byte at [di-1] = A (AL)
    lea     di, [di - 2]
    mov     [di], ah
    mov     [di+1], al
    popf
    ret

; ------------------------------------------------------------------------------
; POP AF: Pop AF from GB stack [di], unpack AH into x86 flags
; ------------------------------------------------------------------------------
global helper_pop_af
helper_pop_af:
    mov     ah, [di]            ; F
    mov     al, [di+1]          ; A
    lea     di, [di + 2]
    and     ah, 0F0h            ; Keep only upper 4 flag bits

    push    bp
    xor     bp, bp
    test    ah, 80h             ; GB Z (bit 7)
    jz      short .pop_no_z
    or      bp, 0040h           ; x86 ZF (bit 6)
.pop_no_z:
    test    ah, 20h             ; GB H (bit 5)
    jz      short .pop_no_h
    or      bp, 0010h           ; x86 AF (bit 4)
.pop_no_h:
    test    ah, 10h             ; GB C (bit 4)
    jz      short .pop_no_c
    or      bp, 0001h           ; x86 CF (bit 0)
.pop_no_c:
    push    bp
    popf
    pop     bp
    ret

; ------------------------------------------------------------------------------
; helper_di_chk_gt / helper_di_chk_ne: Compact stack-unwind check after CALL.
; Entry stack: [guard_ret, saved_di, caller_ret].
; If DI unwound beyond saved_di+2, drops guard_ret+saved_di and returns to caller_ret;
; otherwise drops saved_di and returns to guard_ret. Preserves AX, BP, FLAGS.
; ------------------------------------------------------------------------------
global helper_di_chk_gt, helper_di_chk_ne
helper_di_chk_gt:
    pushf
    push    ax
    push    bp
    mov     bp, sp
    mov     ax, [bp + 8]
    add     ax, 2
    cmp     di, ax
    ja      short di_unwind_frame
di_keep_frame:
    mov     ax, [bp + 6]
    mov     [bp + 8], ax
    mov     ax, [bp + 4]
    mov     [bp + 6], ax
    mov     ax, [bp + 2]
    mov     [bp + 4], ax
    mov     ax, [bp + 0]
    mov     [bp + 2], ax
    add     sp, 2
    pop     bp
    pop     ax
    popf
    ret
helper_di_chk_ne:
    pushf
    push    ax
    push    bp
    mov     bp, sp
    mov     ax, [bp + 8]
    add     ax, 2
    cmp     di, ax
    je      short di_keep_frame
di_unwind_frame:
    mov     ax, [bp + 4]
    mov     [bp + 8], ax
    mov     ax, [bp + 2]
    mov     [bp + 6], ax
    mov     ax, [bp + 0]
    mov     [bp + 4], ax
    add     sp, 4
    pop     bp
    pop     ax
    popf
    ret

; ------------------------------------------------------------------------------
; helper_write_hl: Range check for indirect write to [si]
; SI = target address, AL = byte to write. Preserves all CPU flags!
; ------------------------------------------------------------------------------
%macro MARK_TILE_DIRTY 1
    cmp     %1, 09800h
    jae     short %%not_tile
%ifdef SEG_IS_BANK0
    push    bx
    mov     bx, %1
    sub     bx, 08000h
    shr     bx, 4
    mov     byte [cs:tile_dirty + bx], 1
    pop     bx
%else
    push    bp
    mov     bp, %1
    call    helper_mark_tile_dirty
    pop     bp
%endif
%%not_tile:
%endmacro

global helper_write_hl
helper_write_hl:
    ; Fast path: 0xA000..0xFDFF is plain RAM (no VRAM/OAM/MMIO/MBC side effects).
    ; lahf/sahf keep ZF/CF/AF (AH is scratch in recompiled code).
    lahf
    mov     bp, si
    sub     bp, 0A000h
    cmp     bp, 05E00h
    jae     short .hl_checked
    sahf
    mov     [si], al
    ret
.hl_checked:
    sahf
    pushf
    cmp     si, 08000h
    jb      short .hl_mbc
    cmp     si, 0FE00h
    jae     short .hl_mmio
    mov     [si], al
    MARK_TILE_DIRTY si
    popf
    ret
.hl_mbc:
    mov     bp, si
    call    helper_write_mbc
    popf
    ret
.hl_mmio:
    mov     [si], al
    mov     bp, si
    call    helper_write_mmio
    popf
    ret

; ------------------------------------------------------------------------------
; helper_write_bc: Range check for indirect write to [bx]
; Preserves all CPU flags!
; ------------------------------------------------------------------------------
global helper_write_bc
helper_write_bc:
    ; Fast path: 0xA000..0xFDFF is plain RAM (no VRAM/OAM/MMIO/MBC side effects).
    ; lahf/sahf keep ZF/CF/AF (AH is scratch in recompiled code).
    lahf
    mov     bp, bx
    sub     bp, 0A000h
    cmp     bp, 05E00h
    jae     short .bc_checked
    sahf
    mov     [bx], al
    ret
.bc_checked:
    sahf
    pushf
    cmp     bx, 08000h
    jb      short .bc_mbc
    cmp     bx, 0FE00h
    jae     short .bc_mmio
    mov     [bx], al
    MARK_TILE_DIRTY bx
    popf
    ret
.bc_mbc:
    mov     bp, bx
    call    helper_write_mbc
    popf
    ret
.bc_mmio:
    mov     [bx], al
    mov     bp, bx
    call    helper_write_mmio
    popf
    ret

; ------------------------------------------------------------------------------
; helper_write_de: Range check for indirect write to [dx]
; Preserves all CPU flags!
; ------------------------------------------------------------------------------
global helper_write_de
helper_write_de:
    ; Fast path: 0xA000..0xFDFF is plain RAM (no VRAM/OAM/MMIO/MBC side effects).
    ; lahf/sahf keep ZF/CF/AF (AH is scratch in recompiled code).
    lahf
    mov     bp, dx
    sub     bp, 0A000h
    cmp     bp, 05E00h
    jae     short .de_checked
    sahf
    mov     bp, dx
    mov     [ds:bp], al
    ret
.de_checked:
    sahf
    pushf
    cmp     dx, 08000h
    jb      short .de_mbc
    cmp     dx, 0FE00h
    jae     short .de_mmio
    mov     bp, dx
    mov     [ds:bp], al
    MARK_TILE_DIRTY dx
    popf
    ret
.de_mbc:
    mov     bp, dx
    call    helper_write_mbc
    popf
    ret
.de_mmio:
    mov     bp, dx
    mov     [ds:bp], al
    call    helper_write_mmio
    popf
    ret

; ------------------------------------------------------------------------------
; helper_write_c: Write AL to [0xFF00 + BL]. Preserves all CPU flags!
; ------------------------------------------------------------------------------
global helper_write_c
helper_write_c:
    pushf
    push    bx
    mov     bh, 0FFh
    mov     [bx], al
    mov     bp, bx
    pop     bx
    call    helper_write_mmio
    popf
    ret

; ------------------------------------------------------------------------------
; helper_read_c: Read from [0xFF00 + BL] into AL. Preserves all CPU flags!
; ------------------------------------------------------------------------------
global helper_read_c
helper_read_c:
    pushf
    push    bx
    mov     bh, 0FFh
    cmp     bx, 0FF00h
    je      short .rc_joyp
    cmp     bx, 0FF04h
    je      short .rc_div
    cmp     bx, 0FF41h
    je      short .rc_stat
    cmp     bx, 0FF44h
    je      short .rc_ly
    mov     al, [bx]
    pop     bx
    popf
    ret
.rc_stat:
    pop     bx
    call    helper_read_stat
    popf
    ret
.rc_joyp:
    pop     bx
    call    helper_read_joyp
    popf
    ret
.rc_div:
    pop     bx
    call    helper_read_div
    popf
    ret
.rc_ly:
    pop     bx
    call    helper_read_ly
    popf
    ret

%ifdef OVL_MODE
%macro LOAD_ROM_BANK_ES 0
%ifdef SEG_IS_BANK0
    mov     es, [cs:rom_bank_seg]
%else
    mov     es, [cs:0000h]
    mov     es, [es:002Ch]
%endif
%endmacro
%endif

; ------------------------------------------------------------------------------
; helper_read_hl: Read byte at [CX] into AL, routing 0x4000..0x7FFF ROM bank (OVL)
; and 0xFF00/FF04/FF41/FF44 MMIO. Fast path for RAM. Preserves CX, SI, FLAGS!
; ------------------------------------------------------------------------------
global helper_read_hl
helper_read_hl:
    mov     si, cx
    lahf
%ifdef OVL_MODE
    cmp     ch, 080h
    jae     short .rhl_chk_ff
    cmp     ch, 040h
    jb      short .rhl_ds
    LOAD_ROM_BANK_ES
    sahf
    mov     al, [es:si]
    ret
.rhl_chk_ff:
%endif
    cmp     ch, 0FFh
    je      short .rhl_ff
.rhl_ds:
    sahf
    mov     al, [si]
    ret
.rhl_ff:
    sahf
    pushf
    cmp     cl, 00h
    je      short .rhl_joyp
    cmp     cl, 04h
    je      short .rhl_div
    cmp     cl, 41h
    je      short .rhl_stat
    cmp     cl, 44h
    je      short .rhl_ly
    mov     al, [si]
    popf
    ret
.rhl_joyp:
    popf
    jmp     near helper_read_joyp
.rhl_div:
    popf
    jmp     near helper_read_div
.rhl_stat:
    popf
    jmp     near helper_read_stat
.rhl_ly:
    popf
    jmp     near helper_read_ly

%ifdef OVL_MODE
; ------------------------------------------------------------------------------
; helper_es_hl: Point ES:SI to GB address CX (rom_bank_seg if 0x4000..0x7FFF,
; otherwise DS). Preserves AX, BX, CX, DX, DI, BP, and CPU FLAGS!
; ------------------------------------------------------------------------------
global helper_es_hl
helper_es_hl:
    mov     si, cx
    lahf
    cmp     ch, 080h
    jae     short .ehl_ds
    cmp     ch, 040h
    jb      short .ehl_ds
    LOAD_ROM_BANK_ES
    sahf
    ret
.ehl_ds:
    push    ds
    pop     es
    sahf
    ret

; ------------------------------------------------------------------------------
; helper_read_bc / helper_read_de: Read [BX] or [DX] into AL, routing
; 0x4000..0x7FFF through rom_bank_seg. Preserves all GP regs (except AL) & FLAGS!
; ------------------------------------------------------------------------------
global helper_read_bc
helper_read_bc:
    lahf
    cmp     bh, 080h
    jae     short .rbc_ds
    cmp     bh, 040h
    jb      short .rbc_ds
    LOAD_ROM_BANK_ES
    sahf
    mov     al, [es:bx]
    ret
.rbc_ds:
    sahf
    mov     al, [bx]
    ret

global helper_read_de
helper_read_de:
    mov     bp, dx
    lahf
    cmp     dh, 080h
    jae     short .rde_ds
    cmp     dh, 040h
    jb      short .rde_ds
    LOAD_ROM_BANK_ES
    sahf
    mov     al, [es:bp]
    ret
.rde_ds:
    sahf
    mov     al, [ds:bp]
    ret
%endif

; ------------------------------------------------------------------------------
; helper_dma_transfer: OAM DMA transfer from AL*0x100 to 0xFE00..0xFE9F
; Copies 160 bytes (80 words) within Game Boy memory. Preserves all flags & regs!
; ------------------------------------------------------------------------------
global helper_dma_transfer
helper_dma_transfer:
    pushf
    push    ax
    push    cx
    push    si
    push    di
    push    es
    push    ds

    ; Source = AL * 0x100
    mov     ah, al
    xor     al, al              ; AX = AL << 8
    mov     si, ax

    mov     ax, ds
    mov     es, ax              ; ES = Game Boy memory segment
%ifdef OVL_MODE
    cmp     si, 04000h
    jb      short .dma_ds_ok
    cmp     si, 08000h
    jae     short .dma_ds_ok
%ifdef SEG_IS_BANK0
    mov     ds, [cs:rom_bank_seg]
%else
    mov     ax, [cs:0000h]
    mov     ds, ax
    mov     ds, [ds:002Ch]
%endif
.dma_ds_ok:
%endif
    mov     di, 0FE00h          ; Destination = OAM

    mov     cx, 80              ; 80 words = 160 bytes
    cld
    rep     movsw

    pop     ds
    pop     es
    pop     di
    pop     si
    pop     cx
    pop     ax
    popf
    ret

%ifdef SEG_IS_BANK0
; ==============================================================================
; SEGMENT 0 (BANK 0) PRIMARY STATEFUL RUNTIME HELPERS
; ==============================================================================

; ------------------------------------------------------------------------------
; helper_write_mbc: Handle ROM write (0x0000..0x7FFF)
; BP = address written, AL = value written. Preserves all CPU flags!
; ------------------------------------------------------------------------------
global helper_write_mbc
helper_write_mbc:
    pushf
    cmp     bp, 02000h
    jb      near .mbc_done
    cmp     bp, 04000h
    jae     short .chk_upper_mbc

    ; --- 0x2000..0x3FFF: ROM Bank Select (Low 5 bits for MBC1, 4 bits+A8 for MBC2, 7 bits for MBC3) ---
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    ds
    push    es

    mov     bl, [cs:mapper_type]
    cmp     bl, 2                   ; MAPPER_MBC2: bit 8 (0100h) must be set to select ROM bank
    jne     short .not_mbc2
    test    bp, 0100h
    jz      near .bank_already_active
    and     al, 0Fh
    jmp     short .fix_zero_bank

.not_mbc2:
    cmp     bl, 3                   ; MAPPER_MBC3 / MBC5: 7-bit bank register
    jae     short .mbc3_select

    ; MAPPER_MBC1: bits 4..0 = low 5 bits; 0 -> 1 BEFORE combining upper 2 bits (6..5)
    and     al, 1Fh
    jnz     short .mbc1_nz
    mov     al, 01h
.mbc1_nz:
    cmp     byte [cs:mbc1_mode], 0
    jne     short .apply_mask
    mov     ah, [cs:mbc1_hi_bank]
    shl     ah, 5
    or      al, ah
    jmp     short .apply_mask

.mbc3_select:
    and     al, 7Fh
.fix_zero_bank:
    jnz     short .apply_mask
    mov     al, 01h
.apply_mask:
    and     al, [cs:rom_bank_mask]
    jnz     short .not_zero
    mov     al, 01h                 ; Bank 0 maps to bank 1 in 0x4000..0x7FFF
.not_zero:
    cmp     al, [cs:current_rom_bank]
    je      short .bank_already_active

    mov     [cs:current_rom_bank], al

%ifndef OVL_MODE
    ; Copy 16 KiB (8192 words) from seg_rom_data:al*0x4000 to DS:[0x4000]
    mov     es, [cs:gb_mem_seg]
    mov     di, 04000h
    xor     ah, ah
    mov     dx, 4000h
    mul     dx
    mov     si, ax
    mov     ax, [cs:seg_rom_data]
    mov     ds, ax
    mov     cx, 8192
    cld
    rep     movsw
%else
    call    ovl_load_rom_data
%endif

.bank_already_active:
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
.mbc_done:
    popf
    ret

.chk_upper_mbc:
    cmp     bp, 06000h
    jae     short .chk_mbc1_mode
    ; --- 0x4000..0x5FFF: Upper ROM bank / External RAM bank select ---
    cmp     byte [cs:mapper_type], 1
    jne     short .chk_mbc3_ram
    push    ax
    and     al, 03h
    mov     [cs:mbc1_hi_bank], al
%if SRAM_PARAS_VAL > 0
    cmp     byte [cs:mbc1_mode], 1
    jne     short .mbc1_hi_done
    and     al, [cs:sram_bank_mask]
    push    bx
    push    cx
    push    si
    push    di
    push    ds
    push    es
    call    ovl_switch_sram_bank
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     cx
    pop     bx
%endif
.mbc1_hi_done:
    pop     ax
    popf
    ret

.chk_mbc3_ram:
%if SRAM_PARAS_VAL > 0
    cmp     byte [cs:mapper_type], 3
    jne     short .mbc_done
    cmp     al, [cs:sram_bank_mask]
    ja      short .mbc_done
    push    ax
    push    bx
    push    cx
    push    si
    push    di
    push    ds
    push    es
    call    ovl_switch_sram_bank
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     cx
    pop     bx
    pop     ax
%endif
    popf
    ret

.chk_mbc1_mode:
    cmp     byte [cs:mapper_type], 1
    jne     short .mbc_done
    push    ax
    and     al, 01h
    mov     [cs:mbc1_mode], al
    pop     ax
    popf
    ret

; ------------------------------------------------------------------------------
; helper_write_mmio: Handle MMIO register side-effects
; BP = register address, AL = written value. Preserves all CPU flags!
; ------------------------------------------------------------------------------
global helper_write_mmio
helper_write_mmio:
    pushf
    cmp     bp, 0FF40h          ; LCDC
    je      short .mmio_lcdc
    cmp     bp, 0FF46h          ; OAM DMA
    je      short .mmio_dma
    cmp     bp, 0FF47h          ; BGP
    je      short .mmio_bgp
    cmp     bp, 0FF10h          ; Game Boy APU registers 0xFF10..0xFF26
    jb      short .mmio_none
    cmp     bp, 0FF26h
    jbe     short .mmio_apu
.mmio_none:
    popf
    ret
.mmio_apu:
    call    apu_write_reg
    popf
    ret
.mmio_lcdc:
    ; If LCD disabled, reset LY to 0
    test    al, 80h
    jnz     short .mmio_ret
    mov     byte [cs:emulated_ly], 0
.mmio_ret:
    popf
    ret
.mmio_dma:
    call    helper_dma_transfer
    popf
    ret
.mmio_bgp:
    call    helper_update_bgp
    popf
    ret

; ------------------------------------------------------------------------------
; helper_read_joyp: Read Game Boy joypad register [0xFF00]
; Preserves AH and all CPU flags!
; ------------------------------------------------------------------------------
global helper_read_joyp
helper_read_joyp:
    pushf
    push    bx
    mov     al, [0FF00h]        ; Read selection bits written by game
    mov     bl, 0CFh            ; Default: all released (active low)

    test    al, 10h             ; P14: Direction keys selected (bit 4 == 0)
    jnz     short .check_action
    ; Direction keys selected: merge live + latched joypad_dir (bits 3..0)
    mov     al, [cs:joypad_dir]
    and     al, [cs:joypad_dir_latch]
    and     bl, 0F0h
    or      bl, al
    jmp     short .joyp_done

.check_action:
    test    al, 20h             ; P15: Action buttons selected (bit 5 == 0)
    jnz     short .joyp_done
    ; Action buttons selected: merge live + latched joypad_act (bits 3..0)
    mov     al, [cs:joypad_act]
    and     al, [cs:joypad_act_latch]
    and     bl, 0F0h
    or      bl, al

.joyp_done:
    mov     al, bl
    pop     bx
    popf
    ret

; ------------------------------------------------------------------------------
; helper_read_div: Read hardware timer divider register [0xFF04]
; Preserves all CPU flags!
; ------------------------------------------------------------------------------
global helper_read_div
helper_read_div:
    pushf
    inc     byte [cs:div_counter]
    mov     al, [cs:div_counter]
    popf
    ret

; ------------------------------------------------------------------------------
; helper_read_ly: Read current LCD scanline [0xFF44]
; Preserves all CPU flags!
; ------------------------------------------------------------------------------
global helper_read_ly
helper_read_ly:
    pushf
    cmp     word [cs:wdog_ticks], 360
    jb      short .ly_no_wdog
    popf
    jmp     near wdog_abort
.ly_no_wdog:
    ; Cycle LY through 0..153 to satisfy busy-wait loops
    inc     byte [cs:emulated_ly]
    cmp     byte [cs:emulated_ly], 154
    jb      short .ly_ok
    mov     byte [cs:emulated_ly], 0
.ly_ok:
    mov     al, [cs:emulated_ly]
    popf
    ret

; ------------------------------------------------------------------------------
; helper_read_stat: Read LCDC status register [0xFF41]
; Cycles mode bits 1..0 through [2, 3, 0, 1] so STAT polling loops (OAM/VRAM/
; HBlank/VBlank waits) never spin indefinitely, sets bit 2 on LY==LYC, and
; preserves bits 7..3 of [ds:0FF41h] plus all CPU flags.
; ------------------------------------------------------------------------------
global helper_read_stat
helper_read_stat:
    pushf
    push    bx
    mov     bl, [cs:stat_phase]
    inc     byte [cs:stat_phase]
    and     bx, 03h
    mov     al, [cs:stat_mode_lut + bx]
    mov     bl, [cs:emulated_ly]
    cmp     bl, [ds:0FF45h]
    jne     short .stat_no_lyc
    or      al, 04h
.stat_no_lyc:
    mov     bl, [ds:0FF41h]
    and     bl, 0F8h
    or      al, bl
    pop     bx
    popf
    ret

; ------------------------------------------------------------------------------
; helper_halt: Game Boy HALT instruction
; Yields execution, renders frame, checks keys, and fires VBlank/STAT/Timer ISRs
; ------------------------------------------------------------------------------
global helper_halt, in_halt_isr
in_halt_isr:        db 0
helper_halt:
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
    mov     word [cs:wdog_ticks], 0
    mov     [cs:last_halt_di], di

    ; Check if ESC / exit was requested
    cmp     byte [cs:exit_requested], 1
    je      .do_exit

    ; Pause Menu hotkey (ESC / cfg_key_menu)
    cmp     byte [cs:menu_requested], 1
    jne     short .no_menu
    mov     [cs:halt_sp_base], sp
    call    pause_menu_run
    cmp     byte [cs:exit_requested], 1
    je      .do_exit
.no_menu:

    ; Save / Load State hotkeys (F5 / F9)
    cmp     byte [cs:load_requested], 1
    je      near savestate_load
    cmp     byte [cs:save_requested], 1
    jne     short .no_savestate
    call    savestate_save
.no_savestate:

    ; --- Fixed 59.73 Hz frame pacing (INT 08h ticks) with adaptive frameskip ---
    ; Game logic always advances exactly one GB frame per tick, so game speed
    ; and input timing stay constant; rendering is skipped when we fall behind.
.pace_wait:
    cmp     word [cs:frame_ticks], 0
    jne     .pace_have_tick
    sti
    hlt                                 ; Sleep until next timer IRQ
    jmp     short .pace_wait
.pace_have_tick:
    cli
    mov     ax, [cs:frame_ticks]
    dec     ax
    cmp     ax, MAX_FRAME_BACKLOG       ; Hopelessly behind: drop backlog
    jbe     .pace_store
    xor     ax, ax
.pace_store:
    mov     [cs:frame_ticks], ax
    sti

    ; Clear per-frame press latches so any tap until the next HALT is caught
    mov     byte [cs:joypad_dir_latch], 0FFh
    mov     byte [cs:joypad_act_latch], 0FFh

    test    ax, ax                      ; Still behind schedule?
    jz      .do_render
    cmp     byte [cs:skip_run], MAX_FRAME_SKIP
    jae     .do_render
    inc     byte [cs:skip_run]
    jmp     short .after_render
.do_render:
    mov     byte [cs:skip_run], 0
    ; Render CGA frame (needs DS = gb_mem_seg)
    mov     ax, [cs:gb_mem_seg]
    mov     ds, ax
    call    cga_render_gb_frame
.after_render:
    ; Auto-exit test counter check (/t)
    cmp     word [cs:auto_exit_frames], 0
    je      .check_keys
    dec     word [cs:auto_exit_frames]
    jnz     .check_keys
.do_exit:
    jmp     game_clean_exit

.check_keys:
    ; Drain BIOS keyboard buffer if any unmapped key or ESC arrived
    mov     ah, 01h
    int     16h
    jz      .check_vblank
    mov     ah, 00h
    int     16h
    cmp     al, 1Bh                     ; ESC key -> Pause Menu
    jne     short .check_keys
    mov     byte [cs:menu_requested], 1
    jmp     short .check_keys

.check_vblank:
    cmp     byte [cs:in_halt_isr], 0
    jne     .done
    mov     byte [cs:in_halt_isr], 1
    mov     ax, [cs:gb_mem_seg]
    mov     ds, ax

    pop     bp
    pop     es
    pop     ds
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax

    ; Set VBlank IF flag (bit 0)
    or      byte [ds:0FF0Fh], 01h

    ; Enter VBlank at scanline 144 so VBlank ISRs checking LY see >= 144
    cmp     byte [cs:emulated_ly], 144
    jae     short .ly_vblank_ok
    mov     byte [cs:emulated_ly], 144
.ly_vblank_ok:

    ; Check if Game Boy interrupts are enabled (IME == 1)
    cmp     byte [cs:gb_ime], 0
    je      .done

    ; 1. VBlank Interrupt (0x0040, IE bit 0)
    test    byte [ds:0FFFFh], 01h
    jz      .check_stat
    mov     byte [cs:gb_ime], 0         ; Disable IME
    and     byte [ds:0FF0Fh], 0FEh      ; Clear IF bit 0
    sub     di, 2
    mov     word [di], 0000h
    call    near loc_00_0040

    ; Capture post-VBlank SCX/SCY (used for top status bar scanlines 0..LYC)
    push    ax
    mov     al, [ds:0FF43h]
    mov     [cs:hud_scx], al
    mov     al, [ds:0FF42h]
    mov     [cs:hud_scy], al
    pop     ax

.check_stat:
    ; 2. LCD STAT Interrupt (0x0048, IE bit 1)
    cmp     byte [cs:gb_ime], 0
    je      .check_timer
    test    byte [ds:0FFFFh], 02h
    jz      .check_timer
    mov     byte [cs:gb_ime], 0
    and     byte [ds:0FF0Fh], 0FDh      ; Clear IF bit 1
    sub     di, 2
    mov     word [di], 0000h
    call    near loc_00_0048

.check_timer:
    ; 3. Timer Interrupt (0x0050, IE bit 2)
    cmp     byte [cs:gb_ime], 0
    je      .done
    test    byte [ds:0FFFFh], 04h
    jz      .done
    mov     byte [cs:gb_ime], 0
    and     byte [ds:0FF0Fh], 0FBh      ; Clear IF bit 2
    sub     di, 2
    mov     word [di], 0000h
    call    near loc_00_0050

.done:
    mov     byte [cs:in_halt_isr], 0
    ; Reset LY to active frame start (0) when returning from VBlank frame tick
    mov     byte [cs:emulated_ly], 0
    call    apu_frame_tick
    popf
    ret

; ------------------------------------------------------------------------------
; helper_yield_if_ticks: Yield via helper_halt only if >= 2 INT 08h ticks
; (~33 ms) have elapsed without HALT (catches interrupt-driven polling loops
; that lack HALT while keeping normal fast loops zero-overhead).
; Preserves all registers and CPU flags!
; ------------------------------------------------------------------------------
global helper_yield_if_ticks
helper_yield_if_ticks:
    sti
    pushf
    cmp     word [cs:frame_ticks], 2
    jb      short .hy_no
    cmp     byte [cs:in_halt_isr], 0
    jne     short .hy_no
    popf
    jmp     near helper_halt
.hy_no:
    popf
    ret

global helper_mark_tile_dirty
helper_mark_tile_dirty:
    push    bx
    mov     bx, bp
    sub     bx, 08000h
    shr     bx, 4
    mov     byte [cs:tile_dirty + bx], 1
    pop     bx
    ret

%include "runtime/sound_spk.asm"
%include "runtime/savestate.asm"
%include "runtime/pause_menu.asm"
%ifdef OVL_MODE
%include "runtime/overlay.asm"
%endif

%else
; ==============================================================================
; SEGMENTS 1..N (BANKS 1..N) FAR-CALL BRIDGES TO SEGMENT 0
; Segment 0 fixed helper jump table offsets:
;   0004h: helper_write_mbc
;   0008h: helper_write_mmio
;   000Ch: helper_read_joyp
;   0010h: helper_read_div
;   0014h: helper_read_ly
;   0018h: helper_update_bgp
;   001Ch: helper_halt
;   0020h: helper_mark_tile_dirty
;   0024h: helper_read_stat
;   0028h: helper_dispatch_any_bp (OVL_MODE)
; ==============================================================================
%macro SEG0_BRIDGE 2
global %1
%1:
    pushf
    push    bx
%ifdef OVL_MODE
    mov     bx, [cs:0000h]
%else
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
%endif
    push    bx
    push    word %2
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret
%endmacro

SEG0_BRIDGE helper_write_mbc, 0004h
SEG0_BRIDGE helper_write_mmio, 0008h
SEG0_BRIDGE helper_read_joyp, 000Ch
SEG0_BRIDGE helper_read_div, 0010h
SEG0_BRIDGE helper_read_ly, 0014h
SEG0_BRIDGE helper_update_bgp, 0018h
SEG0_BRIDGE helper_halt, 001Ch
SEG0_BRIDGE helper_mark_tile_dirty, 0020h
SEG0_BRIDGE helper_read_stat, 0024h
%ifdef OVL_MODE
SEG0_BRIDGE helper_yield_if_ticks, 002Eh
%else
SEG0_BRIDGE helper_yield_if_ticks, 0028h
%endif

%ifdef OVL_MODE
global helper_dispatch_any_bp
helper_dispatch_any_bp:
    push    word [cs:0000h]
    push    word 0028h
    mov     si, sp
    call    far [ss:si]
    pop     si
    pop     si
    ret
%endif

%endif

; ------------------------------------------------------------------------------
; helper_stop: Game Boy STOP instruction
; ------------------------------------------------------------------------------
global helper_stop
helper_stop:
    ret

; ------------------------------------------------------------------------------
; DATA & STATE
; ------------------------------------------------------------------------------
global gb_ime, current_rom_bank, rom_bank_mask, emulated_ly
gb_ime:             db  0       ; Game Boy Interrupt Master Enable (0=off, 1=on)
current_rom_bank:   db  1       ; Currently selected 16 KiB ROM bank (1..N-1)
rom_bank_mask:      db  ROM_BANK_MASK_VAL ; ROM bank bitmask
mapper_type:        db  MAPPER_TYPE_VAL   ; 0=None, 1=MBC1, 2=MBC2, 3=MBC3
sram_bank_mask:     db  03h     ; SRAM 8 KiB bank mask (for >8 KiB SRAM)
mbc1_hi_bank:       db  0       ; MBC1 upper 2-bit bank / SRAM bank register
mbc1_mode:          db  0       ; MBC1 0=ROM banking mode, 1=RAM banking mode
emulated_ly:        db  148     ; Current emulated scanline (default 148 = 0x94 VBlank)
stat_phase:         db  0       ; STAT polling phase (0..3)
stat_mode_lut:      db  2, 3, 0, 1 ; Mode cycle: OAM(2)->VRAM(3)->HBlank(0)->VBlank(1)
div_counter:        db  0       ; DIV register counter
skip_run:           db  0       ; Consecutive frames whose render was skipped
MAX_FRAME_SKIP      equ 3       ; Render at least every 4th frame (>= 15 fps)
MAX_FRAME_BACKLOG   equ 6       ; Drop pending ticks beyond this (avoid spiral)

global joypad_dir, joypad_act, joypad_dir_latch, joypad_act_latch
joypad_dir:         db  0Fh     ; Bits 3..0: Down, Up, Left, Right (1=released, 0=pressed)
joypad_act:         db  0Fh     ; Bits 3..0: Start, Select, B, A (1=released, 0=pressed)
joypad_dir_latch:   db  0FFh    ; Latched key-down events during frame render
joypad_act_latch:   db  0FFh    ; Latched action key-down events during frame render
