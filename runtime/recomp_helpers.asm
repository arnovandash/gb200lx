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
    push    bp
    pushf
    pop     bp                  ; BP = x86 flags
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
    sub     di, 2
    mov     [di], ah
    mov     [di+1], al
    ret

; ------------------------------------------------------------------------------
; POP AF: Pop AF from GB stack [di], unpack AH into x86 flags
; ------------------------------------------------------------------------------
global helper_pop_af
helper_pop_af:
    mov     ah, [di]            ; F
    mov     al, [di+1]          ; A
    add     di, 2
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
; SI = target address, AL = byte to write
; ------------------------------------------------------------------------------
global helper_write_hl
helper_write_hl:
    cmp     si, 08000h
    jb      short .hl_mbc
    cmp     si, 0FE00h
    jae     short .hl_mmio
    mov     [si], al
    ret
.hl_mbc:
    mov     bp, si
    jmp     helper_write_mbc
.hl_mmio:
    mov     [si], al
    mov     bp, si
    jmp     helper_write_mmio

; ------------------------------------------------------------------------------
; helper_write_bc: Range check for indirect write to [bx]
; ------------------------------------------------------------------------------
global helper_write_bc
helper_write_bc:
    cmp     bx, 08000h
    jb      short .bc_mbc
    cmp     bx, 0FE00h
    jae     short .bc_mmio
    mov     [bx], al
    ret
.bc_mbc:
    mov     bp, bx
    jmp     helper_write_mbc
.bc_mmio:
    mov     [bx], al
    mov     bp, bx
    jmp     helper_write_mmio

; ------------------------------------------------------------------------------
; helper_write_de: Range check for indirect write to [dx]
; ------------------------------------------------------------------------------
global helper_write_de
helper_write_de:
    cmp     dx, 08000h
    jb      short .de_mbc
    cmp     dx, 0FE00h
    jae     short .de_mmio
    mov     bp, dx
    mov     [bp], al
    ret
.de_mbc:
    mov     bp, dx
    jmp     helper_write_mbc
.de_mmio:
    mov     bp, dx
    mov     [bp], al
    jmp     helper_write_mmio

; ------------------------------------------------------------------------------
; helper_write_c: Write AL to [0xFF00 + BL]
; ------------------------------------------------------------------------------
global helper_write_c
helper_write_c:
    push    bx
    mov     bh, 0FFh
    mov     [bx], al
    mov     bp, bx
    pop     bx
    jmp     helper_write_mmio

; ------------------------------------------------------------------------------
; helper_read_c: Read from [0xFF00 + BL] into AL
; ------------------------------------------------------------------------------
global helper_read_c
helper_read_c:
    push    bx
    mov     bh, 0FFh
    mov     al, [bx]
    pop     bx
    ret

; ------------------------------------------------------------------------------
; helper_write_mbc: Handle ROM write (0x0000..0x7FFF)
; BP = address written, AL = value written
; In Super Mario Land (MBC1, 4 banks):
; 0x2000..0x3FFF: ROM Bank Select (bits 1..0, value 0 maps to bank 1)
; ------------------------------------------------------------------------------
global helper_write_mbc
helper_write_mbc:
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

    and     al, 03h             ; 4 banks total (0..3)
    jnz     short .not_zero
    mov     al, 01h             ; Bank 0 cannot be selected in 0x4000..0x7FFF; maps to bank 1
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
    ret

; ------------------------------------------------------------------------------
; helper_dma_transfer: OAM DMA transfer from AL*0x100 to 0xFE00..0xFE9F
; Copies 160 bytes (80 words) within Game Boy memory
; ------------------------------------------------------------------------------
global helper_dma_transfer
helper_dma_transfer:
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
    ret

; ------------------------------------------------------------------------------
; helper_write_mmio: Handle MMIO register side-effects
; BP = register address, AL = written value
; ------------------------------------------------------------------------------
global helper_write_mmio
helper_write_mmio:
    cmp     bp, 0FF40h          ; LCDC
    jne     short .mmio_ret
    ; If LCD disabled, reset LY to 0
    test    al, 80h
    jnz     short .mmio_ret
    mov     byte [cs:emulated_ly], 0
.mmio_ret:
    ret

; ------------------------------------------------------------------------------
; helper_read_joyp: Read Game Boy joypad register [0xFF00]
; ------------------------------------------------------------------------------
global helper_read_joyp
helper_read_joyp:
    mov     al, [0FF00h]        ; Read selection bits written by game
    mov     ah, 0CFh            ; Default: all released (active low)

    test    al, 10h             ; P14: Direction keys selected (bit 4 == 0)
    jnz     short .check_action
    ; Direction keys selected: merge joypad_dir (bits 3..0)
    and     ah, 0F0h
    or      ah, [cs:joypad_dir]
    jmp     short .joyp_done

.check_action:
    test    al, 20h             ; P15: Action buttons selected (bit 5 == 0)
    jnz     short .joyp_done
    ; Action buttons selected: merge joypad_act (bits 3..0)
    and     ah, 0F0h
    or      ah, [cs:joypad_act]

.joyp_done:
    mov     al, ah
    ret

; ------------------------------------------------------------------------------
; helper_read_div: Read hardware timer divider register [0xFF04]
; ------------------------------------------------------------------------------
global helper_read_div
helper_read_div:
    inc     byte [cs:div_counter]
    mov     al, [cs:div_counter]
    ret

; ------------------------------------------------------------------------------
; helper_read_ly: Read current LCD scanline [0xFF44]
; ------------------------------------------------------------------------------
global helper_read_ly
helper_read_ly:
    ; Cycle LY through 0..153 to satisfy busy-wait loops
    inc     byte [cs:emulated_ly]
    cmp     byte [cs:emulated_ly], 154
    jb      short .ly_ok
    mov     byte [cs:emulated_ly], 0
.ly_ok:
    mov     al, [cs:emulated_ly]
    ret

; ------------------------------------------------------------------------------
; helper_dispatch_jp_hl: Indirect jump JP (HL)
; Target is in CX (and SI)
; ------------------------------------------------------------------------------
global helper_dispatch_jp_hl
helper_dispatch_jp_hl:
    ; Target address is in CX
    ; In our direct recompilation, we jump to the target address
    ; For common SML jump targets, dispatch directly:
    jmp     cx

; ------------------------------------------------------------------------------
; helper_halt: Game Boy HALT instruction
; Yields execution, waits for next frame / interrupt
; ------------------------------------------------------------------------------
global helper_halt
helper_halt:
%ifdef SEG_IS_BANK0
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    ds
    push    es
    push    bp

    ; Render CGA frame (needs DS = gb_mem_seg)
    mov     ax, [cs:gb_mem_seg]
    mov     ds, ax
    call    cga_render_gb_frame

    ; Auto-exit test counter check (/t)
    cmp     word [cs:auto_exit_frames], 0
    je      .check_keys
    dec     word [cs:auto_exit_frames]
    jnz     .check_keys
    jmp     game_clean_exit

.check_keys:
    ; Check BIOS keyboard for ESC
    mov     ah, 01h
    int     16h
    jz      .check_vblank
    mov     ah, 00h
    int     16h
    cmp     al, 1Bh                     ; ESC key
    je      game_clean_exit

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

    ; Check if Game Boy VBlank interrupt is enabled
    cmp     byte [cs:gb_ime], 0
    je      .done
    test    byte [ds:0FFFFh], 01h       ; IE bit 0
    jz      .done

    ; Fire Game Boy VBlank ISR (loc_00_0040)
    mov     byte [cs:gb_ime], 0         ; Disable IME
    and     byte [ds:0FF0Fh], 0FEh      ; Clear IF bit 0
    sub     di, 2
    mov     word [di], 0000h            ; Dummy return address on GB stack
    call    near loc_00_0040
.done:
    ret
%else
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
global gb_ime, current_rom_bank, emulated_ly
gb_ime:             db  0       ; Game Boy Interrupt Master Enable (0=off, 1=on)
current_rom_bank:   db  1       ; Currently selected 16 KiB ROM bank (1..3)
emulated_ly:        db  148     ; Current emulated scanline (default 148 = 0x94 VBlank)
div_counter:        db  0       ; DIV register counter

global joypad_dir, joypad_act
joypad_dir:         db  0Fh     ; Bits 3..0: Down, Up, Left, Right (1=released, 0=pressed)
joypad_act:         db  0Fh     ; Bits 3..0: Start, Select, B, A (1=released, 0=pressed)
