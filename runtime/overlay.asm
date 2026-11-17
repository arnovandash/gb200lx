; ==============================================================================
; overlay.asm - Dynamic Bank Paging Runtime (GAME.OVL + Code/Data LRU Cache)
; Included in Segment 0 when OVL_MODE is defined (ROMs > 64 KiB / > 4 banks).
; ==============================================================================

bits 16
cpu 186

; ------------------------------------------------------------------------------
; ovl_init: Allocate cache segments, open GAME.OVL, and load Bank 0 + Bank 1.
; Expects gb_mem_seg, backbuffer_seg already initialized in CS. Preserves nothing.
; ------------------------------------------------------------------------------
global ovl_init
ovl_init:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax

    ; Compute segment layout right above backbuffer_seg (8 KiB = 0200h paras):
    ;   sram_seg -> code_slot_segs[0..K-1] -> data_slot_segs[0..D-1]
    mov     ax, [backbuffer_seg]
    add     ax, 0200h
    mov     [sram_seg], ax
    add     ax, SRAM_PARAS_VAL

    xor     bx, bx
.init_cslots:
    mov     [code_slot_segs + bx], ax
    add     ax, CODE_SLOT_PARAS
    add     bx, 2
    cmp     bx, NUM_CODE_SLOTS * 2
    jb      .init_cslots

    xor     bx, bx
.init_dslots:
    mov     [data_slot_segs + bx], ax
    add     ax, 0400h               ; 16 KiB per raw ROM data slot
    add     bx, 2
    cmp     bx, NUM_DATA_SLOTS * 2
    jb      .init_dslots

    ; Zero-initialize SRAM segment if cart has > 8 KiB External RAM
%if SRAM_PARAS_VAL > 0
    mov     ax, [sram_seg]
    xor     bx, bx
.zero_sram_loop:
    push    ax
    mov     es, ax
    xor     di, di
    xor     ax, ax
    mov     cx, 4096                ; 8 KiB per 0x0200 para chunk
    cld
    rep     stosw
    pop     ax
    add     ax, 0200h
    inc     bx
    cmp     bx, (SRAM_PARAS_VAL / 0200h)
    jb      .zero_sram_loop
    mov     ax, cs
    mov     es, ax
%endif

    ; Mark all code & data slots empty (0FFh)
    mov     di, code_slot_bank
    mov     al, 0FFh
    mov     cx, NUM_CODE_SLOTS
    cld
    rep     stosb
    mov     di, data_slot_bank
    mov     cx, NUM_DATA_SLOTS
    rep     stosb

    ; Open GAME.OVL read-only
    mov     dx, fn_ovl
    mov     ax, 3D00h
    int     21h
    jc      .ovl_missing
    mov     [ovl_handle], ax

    ; Load Bank 0 (16 KiB at GAME.OVL offset 0) -> gb_mem_seg:0000..3FFF
    mov     bx, ax
    xor     cx, cx
    xor     dx, dx
    mov     ax, 4200h
    int     21h
    mov     ax, [cs:gb_mem_seg]
    mov     ds, ax
    xor     dx, dx
    mov     cx, 4000h
    mov     ah, 3Fh
    int     21h

    mov     ax, cs
    mov     ds, ax

    ; Load Bank 1 -> gb_mem_seg:4000..7FFF via data cache
    mov     al, 1
    call    ovl_load_rom_data
    ret

.ovl_missing:
    mov     dx, str_ovl_missing
    mov     ah, 09h
    int     21h
    mov     ax, 4C01h
    int     21h

; ------------------------------------------------------------------------------
; ovl_close: Close GAME.OVL file handle cleanly before exiting to DOS.
; ------------------------------------------------------------------------------
global ovl_close
ovl_close:
    push    ax
    push    bx
    mov     bx, [cs:ovl_handle]
    cmp     bx, 0FFFFh
    je      .oc_done
    mov     ah, 3Eh
    int     21h
    mov     word [cs:ovl_handle], 0FFFFh
.oc_done:
    pop     bx
    pop     ax
    ret

; ------------------------------------------------------------------------------
; ovl_load_rom_data: Copy 16 KiB ROM Bank AL into gb_mem_seg:4000..7FFF using LRU cache.
; Input: AL = bank (1..NUM_ROM_BANKS-1). Clobbers AX, BX, CX, DX, SI, DI, DS, ES.
; ------------------------------------------------------------------------------
global ovl_load_rom_data
ovl_load_rom_data:
    mov     ah, al                  ; AH = target bank
    mov     bx, cs
    mov     ds, bx

    ; Check data_slot_bank[0..NUM_DATA_SLOTS-1]
    xor     bx, bx
.dl_search:
    cmp     [data_slot_bank + bx], ah
    je      .dl_hit
    inc     bx
    cmp     bx, NUM_DATA_SLOTS
    jb      .dl_search

    ; Cache miss: choose empty (0FFh) slot or oldest LRU slot
    xor     bx, bx                  ; BX = best slot
    mov     dx, 0FFFFh              ; DX = smallest age seen
    xor     si, si
.dl_pick:
    cmp     byte [data_slot_bank + si], 0FFh
    jne     .dl_chk_age
    mov     bx, si
    jmp     short .dl_load_slot
.dl_chk_age:
    mov     di, si
    shl     di, 1
    cmp     [data_slot_age + di], dx
    jae     .dl_next_pick
    mov     dx, [data_slot_age + di]
    mov     bx, si
.dl_next_pick:
    inc     si
    cmp     si, NUM_DATA_SLOTS
    jb      .dl_pick

.dl_load_slot:
    ; Seek GAME.OVL to bank * 16384: CX = bank >> 2, DX = (bank & 3) << 14
    push    bx                      ; Save chosen slot index
    push    ax                      ; Save AH = bank
    mov     al, ah
    mov     cl, al
    shr     cl, 2
    xor     ch, ch
    and     al, 03h
    shl     al, 6
    mov     dh, al
    xor     dl, dl
    mov     bx, [ovl_handle]
    mov     ax, 4200h
    int     21h

    ; Read 16,384 bytes into data_slot_segs[slot]:0000
    pop     ax                      ; AH = bank
    pop     bx                      ; BX = slot
    push    ax
    push    bx
    mov     di, bx
    shl     di, 1
    mov     ds, [data_slot_segs + di]
    mov     bx, [cs:ovl_handle]
    xor     dx, dx
    mov     cx, 4000h
    mov     ah, 3Fh
    int     21h
    pop     bx
    pop     ax

    mov     di, cs
    mov     ds, di
    mov     [data_slot_bank + bx], ah

.dl_hit:
    ; Update LRU age
    inc     word [ovl_data_tick]
    jnz     .dl_age_ok
    call    ovl_reset_data_ages
.dl_age_ok:
    mov     ax, [ovl_data_tick]
    mov     di, bx
    shl     di, 1
    mov     [data_slot_age + di], ax

    ; Copy 8192 words from data_slot_segs[bx]:0000 -> gb_mem_seg:4000h
    mov     es, [gb_mem_seg]
    mov     ds, [data_slot_segs + di]
    xor     si, si
    mov     di, 4000h
    mov     cx, 8192
    cld
    rep     movsw
    ret

ovl_reset_data_ages:
    push    cx
    push    di
    push    es
    mov     cx, cs
    mov     es, cx
    mov     di, data_slot_age
    xor     ax, ax
    mov     cx, NUM_DATA_SLOTS
    cld
    rep     stosw
    mov     word [cs:ovl_data_tick], 1
    pop     es
    pop     di
    pop     cx
    ret

; ------------------------------------------------------------------------------
; ovl_ensure_code_bank: Ensure recompiled bank AL is loaded in a code cache slot.
; Input:  AL = bank (1..NUM_ROM_BANKS-1).
; Output: SI = slot index (0..NUM_CODE_SLOTS-1), ES = code_slot_segs[SI].
; Clobbers AX, BX, CX, DX, DS. Preserves DI (GB SP)!
; ------------------------------------------------------------------------------
global ovl_ensure_code_bank
ovl_ensure_code_bank:
    push    di
    mov     ah, al                  ; AH = target bank
    mov     bx, cs
    mov     ds, bx

    xor     si, si
.cs_search:
    cmp     [code_slot_bank + si], ah
    je      .cs_hit
    inc     si
    cmp     si, NUM_CODE_SLOTS
    jb      .cs_search

    ; Cache miss: pick unpinned empty (0FFh) slot or oldest unpinned slot
    xor     bx, bx                  ; Best slot
    mov     dx, 0FFFFh
    xor     si, si
.cs_pick:
    cmp     byte [slot_pin + si], 0
    jne     .cs_next_pick
    cmp     byte [code_slot_bank + si], 0FFh
    jne     .cs_chk_age
    mov     bx, si
    jmp     short .cs_found_victim
.cs_chk_age:
    mov     di, si
    shl     di, 1
    cmp     [code_slot_age + di], dx
    jae     .cs_next_pick
    mov     dx, [code_slot_age + di]
    mov     bx, si
.cs_next_pick:
    inc     si
    cmp     si, NUM_CODE_SLOTS
    jb      .cs_pick

.cs_found_victim:
    mov     si, bx                  ; SI = victim slot
    push    si
    push    ax                      ; Save AH = bank

    ; Compute ovl_dir offset = bank * 6 (AH * 6)
    mov     bl, ah
    xor     bh, bh
    shl     bx, 1                   ; bank * 2
    mov     di, bx
    add     di, di                  ; bank * 4
    add     di, bx                  ; bank * 6

    mov     dx, [ovl_dir + di + 0]  ; File offset low
    mov     cx, [ovl_dir + di + 2]  ; File offset high
    mov     bx, [ovl_handle]
    mov     ax, 4200h
    int     21h

    mov     cx, [ovl_dir + di + 4]  ; Code segment length in bytes
    mov     bx, si
    shl     bx, 1
    mov     ds, [code_slot_segs + bx]
    mov     bx, [cs:ovl_handle]
    xor     dx, dx
    mov     ah, 3Fh
    int     21h

    ; Stamp Segment 0 CS base at ES:0000h so code bank helpers can reach seg0 cleanly
    mov     ax, ds
    mov     es, ax
    mov     [es:0000h], cs

    mov     ax, cs
    mov     ds, ax
    pop     ax                      ; AH = bank
    pop     si                      ; SI = slot
    mov     [code_slot_bank + si], ah

.cs_hit:
    inc     word [ovl_code_tick]
    jnz     .cs_age_ok
    call    ovl_reset_code_ages
.cs_age_ok:
    mov     ax, [ovl_code_tick]
    mov     di, si
    shl     di, 1
    mov     [code_slot_age + di], ax
    mov     es, [code_slot_segs + di]
    pop     di
    ret

ovl_reset_code_ages:
    push    cx
    push    di
    push    es
    mov     cx, cs
    mov     es, cx
    mov     di, code_slot_age
    xor     ax, ax
    mov     cx, NUM_CODE_SLOTS
    cld
    rep     stosw
    mov     word [cs:ovl_code_tick], 1
    pop     es
    pop     di
    pop     cx
    ret

; ------------------------------------------------------------------------------
; ovl_call_bp: Dynamic cross-bank call into [cs:current_rom_bank] @ GB addr BP.
; Input:  BP = target GB address (0x4000..0x7FFF).
; Preserves ALL SM83 registers (AL, BX, CX, DX, DI) and CPU FLAGS across call!
; ------------------------------------------------------------------------------
global ovl_call_bp
ovl_call_bp:
    sub     sp, 6                   ; Reserve [slot_idx, far_off, far_seg]
    pushf
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    ds
    push    es
    push    bp                      ; [bp+0] = target GB addr

    mov     bp, sp
    ; Stack frame offsets from BP:
    ;   +0  target_gb
    ;   +2  es, +4 ds, +6 si, +8 dx, +10 cx, +12 bx, +14 ax, +16 flags
    ;   +18 slot_idx, +20 far_off, +22 far_seg, +24 caller_ret_b0

    mov     al, [cs:current_rom_bank]
    cmp     al, NUM_ROM_BANKS
    jb      .ocb_bank_ok
    mov     al, 1
.ocb_bank_ok:
    call    ovl_ensure_code_bank    ; SI = slot_idx, ES = slot_seg
    mov     [bp + 18], si
    mov     [bp + 22], es

    ; Binary search ES:0004.. for DX = target_gb (count at ES:0002)
    mov     cx, [es:0002h]
    jcxz    .ocb_miss
    xor     bx, bx                  ; lo = 0
    dec     cx                      ; hi = count - 1
    mov     dx, [bp + 0]
.ocb_bsearch:
    cmp     bx, cx
    ja      .ocb_miss
    mov     ax, bx
    add     ax, cx
    shr     ax, 1                   ; mid
    mov     si, ax
    shl     si, 1
    mov     si, [es:0004h + si]     ; table_gb[mid]
    cmp     si, dx
    je      .ocb_hit
    jb      .ocb_go_right
    or      ax, ax
    jz      .ocb_miss
    dec     ax
    mov     cx, ax
    jmp     short .ocb_bsearch
.ocb_go_right:
    inc     ax
    mov     bx, ax
    jmp     short .ocb_bsearch

.ocb_hit:
    ; Entry offset = 4 + count * 2 + mid * 4
    mov     si, [es:0002h]
    shl     si, 1
    add     si, 4
    shl     ax, 2
    add     ax, si
    mov     [bp + 20], ax

    mov     si, [bp + 18]
    inc     byte [cs:slot_pin + si]

    ; Restore SM83 registers & entry CPU flags, leaving [slot_idx, far_off, far_seg] on stack
    pop     bp
    pop     es
    pop     ds
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    popf

    mov     bp, sp
    call    far [ss:bp + 2]         ; Invoke Bank b entry point (far_off:far_seg)

    ; Unpin slot while preserving Bank b's returned SM83 registers & CPU FLAGS
    pushf
    push    si
    mov     bp, sp
    mov     si, [bp + 4]            ; slot_idx
    dec     byte [cs:slot_pin + si]
    pop     si
    popf
    pop     bp                      ; Discard slot_idx (POP preserves FLAGS)
    pop     bp                      ; Discard far_off
    pop     bp                      ; Discard far_seg
    ret

.ocb_miss:
    pop     bp
    pop     es
    pop     ds
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    popf
    pop     bp                      ; Discard slot_idx
    pop     bp                      ; Discard far_off
    pop     bp                      ; Discard far_seg
    lea     di, [di + 2]            ; Pop GB return addr like a clean stub
    ret

; ------------------------------------------------------------------------------
; helper_dispatch_any_bp: Unified dispatcher for runtime-computed GB addr BP.
; Handles Bank 0 (< 0x4000), current Bank b (0x4000..0x7FFF), or RAM (>= 0x8000).
; Preserves all SM83 registers & CPU flags.
; ------------------------------------------------------------------------------
global helper_dispatch_any_bp
helper_dispatch_any_bp:
    cmp     bp, 04000h
    jb      short .hda_b0
    cmp     bp, 08000h
    jb      near ovl_call_bp
    jmp     short helper_dispatch_ram_bp
.hda_b0:
    jmp     near ovl_dispatch_b0_bp

; ------------------------------------------------------------------------------
; helper_dispatch_ram_bp: Execute a Game Boy CALL/JP targeting RAM (0x8000..0xFFFE).
; Input:  BP = RAM/HRAM GB address. Preserves flags and SM83 registers across hops.
; ------------------------------------------------------------------------------
global helper_dispatch_ram_bp
helper_dispatch_ram_bp:
    push    ax
    mov     ah, 4                   ; Up to 4 chained RAM JP hops
.hdr_loop:
    mov     al, [ds:bp]
    cmp     al, 0C3h                ; JP imm16?
    je      .hdr_follow_jp
    cmp     al, 0C9h                ; RET?
    je      .hdr_ret
    cmp     al, 0D9h                ; RETI?
    je      .hdr_reti
    cmp     bp, 0FF80h
    jae     .hdr_hram_dma
    jmp     short .hdr_ret

.hdr_follow_jp:
    mov     bp, [ds:bp + 1]
    cmp     bp, 04000h
    jb      .hdr_to_b0
    cmp     bp, 08000h
    jb      .hdr_to_bn
    dec     ah
    jnz     .hdr_loop
.hdr_ret:
    pop     ax
    lea     di, [di + 2]
    ret

.hdr_reti:
    mov     byte [cs:gb_ime], 1
    pop     ax
    lea     di, [di + 2]
    ret

.hdr_hram_dma:
    ; Check OAM DMA patterns:
    ;   1) `3E xx E0 46` (LD A, xx; LDH (46h), A)
    ;   2) `E0 46 ...`   (LDH (46h), A with page already in AL)
    cmp     byte [ds:bp], 0E0h
    jne     .hdr_chk_3e
    cmp     byte [ds:bp + 1], 46h
    jne     .hdr_ret
    pop     ax
    push    ax
    call    helper_dma_transfer
    pop     ax
    lea     di, [di + 2]
    ret
.hdr_chk_3e:
    cmp     byte [ds:bp], 3Eh
    jne     .hdr_ret
    cmp     byte [ds:bp + 2], 0E0h
    jne     .hdr_ret
    cmp     byte [ds:bp + 3], 46h
    jne     .hdr_ret
    pop     ax
    push    ax
    mov     al, [ds:bp + 1]
    call    helper_dma_transfer
    pop     ax
    lea     di, [di + 2]
    ret

.hdr_to_b0:
    pop     ax
    jmp     near ovl_dispatch_b0_bp

.hdr_to_bn:
    pop     ax
    jmp     near ovl_call_bp

%if SRAM_PARAS_VAL > 0
; ------------------------------------------------------------------------------
; ovl_switch_sram_bank: Swap 8 KiB External RAM (gb_mem_seg:A000..BFFF) <-> sram_seg.
; Input: AL = target SRAM bank (0..SRAM_BANKS-1). Clobbers AX, CX, SI, DI, DS, ES.
; ------------------------------------------------------------------------------
global ovl_switch_sram_bank
ovl_switch_sram_bank:
    cmp     al, [cs:current_sram_bank]
    je      .oss_done

    ; 1. Save active 8 KiB (gb_mem_seg:A000) -> sram_seg + cur * 0200h paras
    mov     bl, [cs:current_sram_bank]
    xor     bh, bh
    shl     bx, 9                   ; bank * 512 paras (8192 bytes)
    add     bx, [cs:sram_seg]
    mov     es, bx
    mov     ds, [cs:gb_mem_seg]
    mov     si, 0A000h
    xor     di, di
    mov     cx, 4096
    cld
    rep     movsw

    mov     [cs:current_sram_bank], al

    ; 2. Load new 8 KiB from sram_seg + new * 0200h paras -> gb_mem_seg:A000
    mov     bl, al
    xor     bh, bh
    shl     bx, 9
    add     bx, [cs:sram_seg]
    mov     ds, bx
    mov     es, [cs:gb_mem_seg]
    xor     si, si
    mov     di, 0A000h
    mov     cx, 4096
    rep     movsw
.oss_done:
    ret
%endif

; --- Overlay Manager State in CS ---
fn_ovl:             db "GAME.OVL", 0
str_ovl_missing:    db "Error: GAME.OVL not found!", 0Dh, 0Ah, "$"
ovl_handle:         dw 0FFFFh
global sram_seg, current_sram_bank, code_slot_segs, code_slot_bank
sram_seg:           dw 0
current_sram_bank:  db 0
ovl_code_tick:      dw 0
ovl_data_tick:      dw 0
code_slot_segs:     times NUM_CODE_SLOTS dw 0
code_slot_bank:     times NUM_CODE_SLOTS db 0FFh
slot_pin:           times NUM_CODE_SLOTS db 0
code_slot_age:      times NUM_CODE_SLOTS dw 0
data_slot_segs:     times NUM_DATA_SLOTS dw 0
data_slot_bank:     times NUM_DATA_SLOTS db 0FFh
data_slot_age:      times NUM_DATA_SLOTS dw 0
