; ==============================================================================
; recomp_helpers.asm - Runtime Helpers for Static SM83 to 80186 Recompiler
; Provides MMIO handling, flag pack/unpack, OAM DMA, MBC bank switching,
; and CGA PPU tile/scanline rendering for HP 200LX.
; ==============================================================================

bits 16
cpu 186

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
    cmp     bx, 0FF44h
    je      short .rc_ly
    mov     al, [bx]
    pop     bx
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

    ; Source = AL * 0x100
    mov     ah, al
    xor     al, al              ; AX = AL << 8
    mov     si, ax

    mov     ax, ds
    mov     es, ax              ; ES = DS = Game Boy memory segment
    mov     di, 0FE00h          ; Destination = OAM

    mov     cx, 80              ; 80 words = 160 bytes
    cld
    rep     movsw

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
    jb      short .mbc_done
    cmp     bp, 04000h
    jae     short .mbc_done

    ; Bank select
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    ds
    push    es

    and     al, 1Fh             ; MBC1 5-bit bank select
    and     al, [cs:rom_bank_mask]
    jnz     short .not_zero
    mov     al, 01h             ; Bank 0 maps to bank 1 in 0x4000..0x7FFF
.not_zero:
    cmp     al, [cs:current_rom_bank]
    je      short .bank_already_active

    mov     [cs:current_rom_bank], al

    ; Copy 16 KiB (8192 words) from seg_rom_data:al*0x4000 to DS:[0x4000]
    mov     es, [cs:gb_mem_seg] ; ES = Game Boy memory segment
    mov     di, 04000h          ; Destination = 0x4000 in GB RAM

    ; Calculate source address in seg_rom_data
    xor     ah, ah
    mov     dx, 4000h
    mul     dx                  ; DX:AX = AL * 4000h
    mov     si, ax
    mov     ax, [cs:seg_rom_data]
    mov     ds, ax              ; DS = seg_rom_data (source of ROM data)

    mov     cx, 8192            ; 8192 words = 16,384 bytes
    cld
    rep     movsw

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
; helper_halt: Game Boy HALT instruction
; Yields execution, renders frame, checks keys, and fires VBlank/STAT/Timer ISRs
; ------------------------------------------------------------------------------
global helper_halt
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

    ; Check if ESC / exit was requested via INT 09h ISR
    cmp     byte [cs:exit_requested], 1
    je      .do_exit

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
    cmp     al, 1Bh                     ; ESC key
    je      game_clean_exit
    jmp     short .check_keys

.check_vblank:
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

%else
; ==============================================================================
; SEGMENTS 1..3 (BANKS 1..3) FAR-CALL BRIDGES TO SEGMENT 0
; Segment 0 fixed helper jump table offsets:
;   0004h: helper_write_mbc
;   0008h: helper_write_mmio
;   000Ch: helper_read_joyp
;   0010h: helper_read_div
;   0014h: helper_read_ly
;   0018h: helper_update_bgp
;   001Ch: helper_halt
; ==============================================================================

global helper_write_mbc
helper_write_mbc:
    pushf
    push    bx
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
    push    bx
    push    word 0004h
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret

global helper_write_mmio
helper_write_mmio:
    pushf
    push    bx
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
    push    bx
    push    word 0008h
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret

global helper_read_joyp
helper_read_joyp:
    pushf
    push    bx
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
    push    bx
    push    word 000Ch
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret

global helper_read_div
helper_read_div:
    pushf
    push    bx
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
    push    bx
    push    word 0010h
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret

global helper_read_ly
helper_read_ly:
    pushf
    push    bx
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
    push    bx
    push    word 0014h
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret

global helper_update_bgp
helper_update_bgp:
    pushf
    push    bx
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
    push    bx
    push    word 0018h
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret

global helper_halt
helper_halt:
    pushf
    push    bx
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
    push    bx
    push    word 001Ch
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret

global helper_mark_tile_dirty
helper_mark_tile_dirty:
    pushf
    push    bx
    mov     bx, cs
    sub     bx, SEG_PARAS_VAL
    push    bx
    push    word 0020h
    mov     bx, sp
    call    far [ss:bx]
    add     sp, 4
    pop     bx
    popf
    ret

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
current_rom_bank:   db  1       ; Currently selected 16 KiB ROM bank (1..3)
rom_bank_mask:      db  03h     ; ROM bank bitmask (default 03h for 4 banks)
emulated_ly:        db  148     ; Current emulated scanline (default 148 = 0x94 VBlank)
div_counter:        db  0       ; DIV register counter
skip_run:           db  0       ; Consecutive frames whose render was skipped
MAX_FRAME_SKIP      equ 3       ; Render at least every 4th frame (>= 15 fps)
MAX_FRAME_BACKLOG   equ 6       ; Drop pending ticks beyond this (avoid spiral)

global joypad_dir, joypad_act, joypad_dir_latch, joypad_act_latch
joypad_dir:         db  0Fh     ; Bits 3..0: Down, Up, Left, Right (1=released, 0=pressed)
joypad_act:         db  0Fh     ; Bits 3..0: Start, Select, B, A (1=released, 0=pressed)
joypad_dir_latch:   db  0FFh    ; Latched key-down events during frame render
joypad_act_latch:   db  0FFh    ; Latched action key-down events during frame render
