; ==============================================================================
; overlay.asm - Dynamic Bank Paging Runtime (GAME.OVL + Variable Code/Data LRU)
; Included in Segment 0 when OVL_MODE is defined (ROMs > 64 KiB / > 4 banks).
; ==============================================================================

bits 16
cpu 186

%if (NUM_ROM_BANKS - 1) > 32
    %define MAX_DATA_SLOTS 32
%else
    %define MAX_DATA_SLOTS (NUM_ROM_BANKS - 1)
%endif

; ------------------------------------------------------------------------------
; ovl_init: Dynamically claim free DOS RAM above SS:0800h for SRAM, data slots,
; and variable-size code pool; open GAME.OVL and load Bank 0 + Bank 1.
; Expects gb_mem_seg, backbuffer_seg, psp_mem_top initialized in CS.
; ------------------------------------------------------------------------------
global ovl_init
ovl_init:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax

    ; Layout above hardware stack (SS + 0800h paras .. psp_mem_top):
    ;   sram_seg -> data_slot_segs[0..num_data_slots-1] -> [code_pool_start..code_pool_top)
    mov     ax, ss
    add     ax, 0800h
    mov     [sram_seg], ax
    add     ax, SRAM_PARAS_VAL
    mov     dx, ax                  ; DX = cache_base

    mov     bx, [psp_mem_top]
    sub     bx, dx
    jc      near ovl_oom
    cmp     bx, 01000h              ; Need >= 64 KiB total cache RAM
    jb      near ovl_oom

    ; Target ~50% of free RAM for code pool (at least 2*MAX_CODE_PARAS if room,
    ; capped at TOTAL_CODE_PARAS so extra space goes straight to 16 KiB data slots).
    mov     cx, bx
    shr     cx, 1
    mov     ax, MAX_CODE_PARAS
    shl     ax, 1
    cmp     cx, ax
    jae     .oi_min_ok
    mov     cx, ax
.oi_min_ok:
    cmp     cx, TOTAL_CODE_PARAS
    jbe     .oi_cap_ok
    mov     cx, TOTAL_CODE_PARAS
.oi_cap_ok:
    mov     ax, bx
    sub     ax, cx                  ; rem_for_data = avail - code_target
    jnc     .oi_dcalc
    xor     ax, ax
.oi_dcalc:
    shr     ax, 10                  ; // 0400h (16 KiB slots)
    cmp     ax, 2
    jae     .oi_dmin_ok
    mov     ax, 2
.oi_dmin_ok:
    cmp     ax, MAX_DATA_SLOTS
    jbe     .oi_dmax_ok
    mov     ax, MAX_DATA_SLOTS
.oi_dmax_ok:
    mov     [num_data_slots], ax

    ; Assign data_slot_segs[0..num_data_slots-1] from DX upward
    mov     cx, ax
    mov     ax, dx
    xor     bx, bx
.init_dslots:
    mov     [data_slot_segs + bx], ax
    add     ax, 0400h               ; 16 KiB per raw ROM data slot
    add     bx, 2
    loop    .init_dslots

    mov     [code_pool_start], ax
    mov     ax, [psp_mem_top]
    mov     [code_pool_top], ax
    mov     word [pool_cnt], 0

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

    ; Clear code pool tables & mark data slots empty (0FFh)
    xor     ax, ax
    mov     di, bank_code_seg
    mov     cx, NUM_ROM_BANKS
    cld
    rep     stosw
    mov     di, bank_code_age
    mov     cx, NUM_ROM_BANKS
    rep     stosw
    mov     di, bank_pin
    mov     cx, NUM_ROM_BANKS
    rep     stosb

    mov     di, data_slot_bank
    mov     al, 0FFh
    mov     cx, MAX_DATA_SLOTS
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
    jmp     short ovl_abort
ovl_oom:
    mov     dx, str_ovl_oom
ovl_abort:
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
    mov     cx, [num_data_slots]

    ; Check data_slot_bank[0..num_data_slots-1]
    xor     bx, bx
.dl_search:
    cmp     [data_slot_bank + bx], ah
    je      .dl_hit
    inc     bx
    cmp     bx, cx
    jb      .dl_search

    ; Cache miss: choose empty (0FFh) slot or oldest LRU slot
.dl_miss:
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
    cmp     si, cx
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

    ; Point rom_bank_seg so [es:4000..7FFF] reads data_slot_segs[bx]:0000..3FFF with zero copy
    mov     ax, [data_slot_segs + di]
    sub     ax, 0400h
    mov     [rom_bank_seg], ax
    ret

ovl_reset_data_ages:
    push    cx
    push    di
    push    es
    mov     cx, cs
    mov     es, cx
    mov     di, data_slot_age
    xor     ax, ax
    mov     cx, [cs:num_data_slots]
    cld
    rep     stosw
    mov     word [cs:ovl_data_tick], 1
    pop     es
    pop     di
    pop     cx
    ret

; ------------------------------------------------------------------------------
; ovl_ensure_code_bank: Ensure recompiled bank AL is loaded in the variable pool.
; Input:  AL = bank (1..NUM_ROM_BANKS-1).
; Output: SI = bank ID (1..NUM_ROM_BANKS-1), ES = segment base.
; Clobbers AX, BX, CX, DX, DS. Preserves DI (GB SP)!
; ------------------------------------------------------------------------------
global ovl_ensure_code_bank
ovl_ensure_code_bank:
    push    di
    mov     bl, al
    xor     bh, bh
    mov     dx, bx                  ; DX = bank ID
    shl     bx, 1
    mov     ax, [cs:bank_code_seg + bx]
    or      ax, ax
    jz      .cs_miss
    mov     si, dx                  ; O(1) hit: SI = bank ID
    jmp     near .cs_hit

.cs_miss:
    mov     ax, cs
    mov     ds, ax
    mov     es, ax
    mov     [miss_bank], dx

    ; Compute ovl_dir entry: offset = bank * 6 -> len_bytes, need_paras
    mov     bx, dx
    shl     bx, 1
    mov     di, bx
    add     di, di
    add     di, bx
    mov     ax, [ovl_dir + di + 4]  ; Code segment length in bytes
    mov     [miss_len_bytes], ax
    mov     dx, ax
    shr     ax, 4
    test    dx, 0Fh
    jz      .cm_paras_ok
    inc     ax
.cm_paras_ok:
    mov     [miss_need_paras], ax

.try_find_gap:
    mov     ax, [code_pool_start]   ; cur_seg
    xor     si, si                  ; insert_idx = 0
    mov     cx, [pool_cnt]
.scan_gaps:
    cmp     si, cx
    jae     .chk_tail_gap
    mov     bx, si
    shl     bx, 1
    mov     dx, [pool_seg + bx]
    sub     dx, ax
    cmp     dx, [miss_need_paras]
    jae     .found_gap
    mov     ax, [pool_end + bx]
    inc     si
    jmp     short .scan_gaps
.chk_tail_gap:
    mov     dx, [code_pool_top]
    sub     dx, ax
    cmp     dx, [miss_need_paras]
    jae     .found_gap

    ; No contiguous gap large enough -> evict oldest UNPINNED resident bank
    mov     di, 0FFFFh              ; best_idx = none
    xor     dx, dx                  ; best_age
    xor     si, si
.ev_pick:
    cmp     si, cx
    jae     .ev_commit
    mov     bl, [pool_bk + si]
    xor     bh, bh
    cmp     byte [bank_pin + bx], 0
    jne     .ev_next
    shl     bx, 1
    mov     ax, [bank_code_age + bx]
    cmp     di, 0FFFFh
    je      .ev_take
    cmp     ax, dx
    jae     .ev_next
.ev_take:
    mov     di, si
    mov     dx, ax
.ev_next:
    inc     si
    jmp     short .ev_pick

.ev_commit:
    cmp     di, 0FFFFh
    je      near ovl_oom            ; Safety guard: all blocks pinned and out of pool
    mov     bl, [pool_bk + di]
    xor     bh, bh
    shl     bx, 1
    mov     word [bank_code_seg + bx], 0

    ; Shift pool arrays left by 1 over DI..pool_cnt-1
    mov     cx, [pool_cnt]
    dec     cx
    sub     cx, di                  ; count = (pool_cnt - 1) - di
    jcxz    .ev_sh_done
    push    cx
    mov     si, di
    inc     si
    shl     si, 1
    mov     bx, di
    shl     bx, 1
    push    bx
    push    si
    add     si, pool_seg
    push    di
    mov     di, bx
    add     di, pool_seg
    cld
    rep     movsw
    pop     di
    pop     si
    pop     bx
    pop     cx
    push    cx
    push    di
    add     si, pool_end
    mov     di, bx
    add     di, pool_end
    rep     movsw
    pop     di
    pop     cx
    mov     si, di
    inc     si
    add     si, pool_bk
    add     di, pool_bk
    rep     movsb
.ev_sh_done:
    dec     word [pool_cnt]
    jmp     .try_find_gap

.found_gap:
    ; Insert at SI with segment AX
    mov     [miss_target_seg], ax
    mov     [miss_ins_idx], si
    mov     cx, [pool_cnt]
    sub     cx, si
    jcxz    .ins_write
    ; Shift elements SI..pool_cnt-1 right by 1 using STD
    mov     bx, [pool_cnt]
    mov     ax, bx
    dec     ax
    shl     bx, 1                   ; dest word off = pool_cnt * 2
    shl     ax, 1                   ; src word off  = (pool_cnt - 1) * 2
    push    cx
    push    ax
    push    bx
    mov     si, ax
    add     si, pool_seg
    mov     di, bx
    add     di, pool_seg
    std
    rep     movsw
    pop     bx
    pop     ax
    pop     cx
    push    cx
    mov     si, ax
    add     si, pool_end
    mov     di, bx
    add     di, pool_end
    rep     movsw
    pop     cx
    mov     di, pool_bk
    add     di, [pool_cnt]
    mov     si, di
    dec     si
    rep     movsb
    cld
.ins_write:
    mov     si, [miss_ins_idx]
    mov     ax, [miss_bank]
    mov     [pool_bk + si], al
    shl     si, 1
    mov     ax, [miss_target_seg]
    mov     [pool_seg + si], ax
    add     ax, [miss_need_paras]
    mov     [pool_end + si], ax
    inc     word [pool_cnt]

    ; Seek GAME.OVL and read code bank into miss_target_seg:0000
    mov     bx, [miss_bank]
    shl     bx, 1
    mov     di, bx
    add     di, di
    add     di, bx
    mov     dx, [ovl_dir + di + 0]
    mov     cx, [ovl_dir + di + 2]
    mov     bx, [ovl_handle]
    mov     ax, 4200h
    int     21h

    mov     cx, [miss_len_bytes]
    mov     ds, [miss_target_seg]
    mov     bx, [cs:ovl_handle]
    xor     dx, dx
    mov     ah, 3Fh
    int     21h

    mov     ax, ds
    mov     es, ax
    mov     [es:0000h], cs          ; Stamp seg0 base at ES:0000h

    mov     ax, cs
    mov     ds, ax
    mov     si, [miss_bank]
    mov     bx, si
    shl     bx, 1
    mov     ax, [miss_target_seg]
    mov     [bank_code_seg + bx], ax

.cs_hit:
    mov     ax, cs
    mov     ds, ax
    inc     word [ovl_code_tick]
    jnz     .cs_age_ok
    call    ovl_reset_code_ages
.cs_age_ok:
    mov     ax, [ovl_code_tick]
    mov     di, si
    shl     di, 1
    mov     [bank_code_age + di], ax
    mov     es, [bank_code_seg + di]
    pop     di
    ret

ovl_reset_code_ages:
    push    cx
    push    di
    push    es
    mov     cx, cs
    mov     es, cx
    mov     di, bank_code_age
    xor     ax, ax
    mov     cx, NUM_ROM_BANKS
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
    sub     sp, 6                   ; Reserve [bank_id, far_off, far_seg]
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
    ;   +18 bank_id, +20 far_off, +22 far_seg, +24 caller_ret_b0

    mov     al, [cs:current_rom_bank]
    cmp     al, NUM_ROM_BANKS
    jb      .ocb_bank_ok
    mov     al, 1
.ocb_bank_ok:
    mov     [cs:last_ovl_bk], al
    mov     dx, [bp + 0]
    mov     [cs:last_ovl_bp], dx
    cmp     word [cs:auto_exit_frames], 100
    ja      short .ocb_no_tr
    cmp     al, 3
    jne     short .ocb_do_tr
    cmp     dx, 04000h
    je      short .ocb_no_tr
.ocb_do_tr:
    push    bx
    mov     bx, [cs:trace_cnt]
    and     bx, 31
    shl     bx, 2
    mov     [cs:trace_ring + bx], ax
    mov     [cs:trace_ring + bx + 2], dx
    inc     word [cs:trace_cnt]
    pop     bx
    call    trace_log_call
.ocb_no_tr:
    cmp     word [cs:wdog_ticks], 360
    jb      short .ocb_no_wdog
    jmp     near wdog_abort
.ocb_no_wdog:
    call    ovl_ensure_code_bank    ; SI = bank ID, ES = slot_seg
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
    inc     byte [cs:bank_pin + si]

    ; Restore SM83 registers & entry CPU flags, leaving [bank_id, far_off, far_seg] on stack
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

    ; Unpin bank while preserving Bank b's returned SM83 registers & CPU FLAGS
    pushf
    push    si
    mov     bp, sp
    mov     si, [bp + 4]            ; bank_id
    dec     byte [cs:bank_pin + si]
    pop     si
    popf
    pop     bp                      ; Discard bank_id (POP preserves FLAGS)
    pop     bp                      ; Discard far_off
    pop     bp                      ; Discard far_seg
    ret

.ocb_miss:
    push    ax
    push    bx
    push    dx
    mov     al, [cs:current_rom_bank]
    mov     ah, 01h                 ; tag 01 = ocb_miss
    mov     bx, [bp + 0]
    mov     dx, [bp + 24]
    call    log_miss
    pop     dx
    pop     bx
    pop     ax
    pop     bp
    pop     es
    pop     ds
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    popf
    pop     bp                      ; Discard bank_id
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
str_ovl_oom:        db "Error: Out of DOS memory for caches!", 0Dh, 0Ah, "$"
ovl_handle:         dw 0FFFFh
global sram_seg, current_sram_bank, bank_code_seg
sram_seg:           dw 0
current_sram_bank:  db 0
num_data_slots:     dw 0
code_pool_start:    dw 0
code_pool_top:      dw 0
pool_cnt:           dw 0
ovl_code_tick:      dw 0
ovl_data_tick:      dw 0
miss_bank:          dw 0
miss_len_bytes:     dw 0
miss_need_paras:    dw 0
miss_target_seg:    dw 0
miss_ins_idx:       dw 0
bank_code_seg:      times NUM_ROM_BANKS dw 0
bank_code_age:      times NUM_ROM_BANKS dw 0
bank_pin:           times NUM_ROM_BANKS db 0
pool_seg:           times NUM_ROM_BANKS dw 0
pool_end:           times NUM_ROM_BANKS dw 0
pool_bk:            times NUM_ROM_BANKS db 0
data_slot_segs:     times MAX_DATA_SLOTS dw 0
data_slot_bank:     times MAX_DATA_SLOTS db 0FFh
data_slot_age:      times MAX_DATA_SLOTS dw 0
