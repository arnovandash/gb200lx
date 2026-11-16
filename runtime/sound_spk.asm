; ==============================================================================
; sound_spk.asm - HP 200LX PC Speaker Game Boy APU Driver (PIT Channel 2)
; Translates Game Boy APU Channels 1, 2 (Square + Sweep/Envelope/Length) and
; Channel 3 (Wave) into crisp single-voice square waves on PIT Ch 2 (0x42/0x61).
; ==============================================================================

bits 16
cpu 186

; ------------------------------------------------------------------------------
; spk_mute: Silence the PC speaker cleanly (preserves upper bits of port 61h)
; Preserves all registers and CPU flags.
; ------------------------------------------------------------------------------
global spk_mute
spk_mute:
    pushf
    push    ax
    cli
    in      al, 61h
    and     al, 0FCh                ; Clear bits 0..1 (Timer 2 gate + speaker data)
    out     61h, al
    mov     word [cs:apu_cur_div], 0
    pop     ax
    popf
    ret

; ------------------------------------------------------------------------------
; spk_set_div: Program PIT Channel 2 with 16-bit divisor AX and enable speaker.
; Avoids resetting PIT mode 3 if divisor hasn't changed (prevents 60 Hz clicks).
; Input: AX = PIT divisor. Clobbers AX.
; ------------------------------------------------------------------------------
spk_set_div:
    cmp     ax, 36                  ; Clamp >= 36 (~33 kHz upper bound)
    jae     short .div_ok
    mov     ax, 36
.div_ok:
    cmp     ax, [cs:apu_cur_div]
    je      short .done
    pushf
    cli
    cmp     word [cs:apu_cur_div], 0
    mov     [cs:apu_cur_div], ax
    jne     short .reload_only
    push    ax
    mov     al, 0B6h                ; PIT Ch 2, lo/hi byte, mode 3 square wave
    out     43h, al
    pop     ax
.reload_only:
    out     42h, al
    mov     al, ah
    out     42h, al
    in      al, 61h
    or      al, 03h                 ; Enable Timer 2 gate (bit 0) + speaker data (bit 1)
    out     61h, al
    popf
.done:
    ret

; ------------------------------------------------------------------------------
; apu_write_reg: Handle writes to Game Boy APU registers 0xFF10..0xFF26.
; Inputs: DS = gb_mem_seg, BP = register address, AL = written value.
; Preserves all registers and CPU flags!
; ------------------------------------------------------------------------------
apu_write_reg:
    pushf
    push    ax
    push    bx

    cmp     bp, 0FF26h              ; NR52: Master sound control
    je      near .wr_nr52

    cmp     bp, 0FF11h
    jb      near .ret_ok
    cmp     bp, 0FF14h
    jbe     short .wr_ch1
    cmp     bp, 0FF16h
    jb      near .ret_ok
    cmp     bp, 0FF19h
    jbe     near .wr_ch2
    cmp     bp, 0FF1Ah
    jb      near .ret_ok
    cmp     bp, 0FF1Eh
    jbe     near .wr_ch3
    jmp     near .ret_ok

; --- Channel 1 (0xFF11..0xFF14) ---
.wr_ch1:
    cmp     bp, 0FF11h
    je      near .nr11
    cmp     bp, 0FF12h
    je      near .nr12
    cmp     bp, 0FF13h
    je      near .nr13
    ; NR14 (0xFF14): freq[10:8] + trigger
    mov     ah, al
    and     ah, 07h
    mov     [cs:apu_ch1_freq + 1], ah
    test    al, 80h
    jz      near .ret_ok
    test    byte [ds:0FF12h], 0F8h  ; DAC off?
    jz      near .ret_ok
    mov     byte [cs:apu_ch1_on], 1
    mov     byte [cs:apu_last_trig], 1
    cmp     byte [cs:apu_ch1_len], 0
    jne     short .nr14_len_ok
    mov     byte [cs:apu_ch1_len], 64
.nr14_len_ok:
    mov     al, [ds:0FF12h]
    mov     ah, al
    shr     al, 4
    mov     [cs:apu_ch1_vol], al
    and     ah, 07h
    mov     [cs:apu_ch1_env_cnt], ah
    mov     bx, [cs:apu_ch1_freq]
    mov     [cs:apu_ch1_swp_shadow], bx
    mov     al, [ds:0FF10h]
    shr     al, 4
    and     al, 07h
    mov     [cs:apu_ch1_swp_cnt], al
    jmp     near .ret_ok

.nr11:
    and     al, 3Fh
    mov     ah, 64
    sub     ah, al
    mov     [cs:apu_ch1_len], ah
    jmp     near .ret_ok

.nr12:
    test    al, 0F8h
    jnz     short .nr12_chk0
    mov     byte [cs:apu_ch1_on], 0
    jmp     near .ret_ok
.nr12_chk0:
    cmp     al, 08h                 ; vol=0, no envelope -> silent
    jne     near .ret_ok
    mov     byte [cs:apu_ch1_vol], 0
    jmp     near .ret_ok

.nr13:
    mov     [cs:apu_ch1_freq], al
    jmp     near .ret_ok

; --- Channel 2 (0xFF16..0xFF19) ---
.wr_ch2:
    cmp     bp, 0FF16h
    je      short .nr21
    cmp     bp, 0FF17h
    je      short .nr22
    cmp     bp, 0FF18h
    je      short .nr23
    ; NR24 (0xFF19): freq[10:8] + trigger
    mov     ah, al
    and     ah, 07h
    mov     [cs:apu_ch2_freq + 1], ah
    test    al, 80h
    jz      near .ret_ok
    test    byte [ds:0FF17h], 0F8h  ; DAC off?
    jz      near .ret_ok
    mov     byte [cs:apu_ch2_on], 1
    mov     byte [cs:apu_last_trig], 2
    cmp     byte [cs:apu_ch2_len], 0
    jne     short .nr24_len_ok
    mov     byte [cs:apu_ch2_len], 64
.nr24_len_ok:
    mov     al, [ds:0FF17h]
    mov     ah, al
    shr     al, 4
    mov     [cs:apu_ch2_vol], al
    and     ah, 07h
    mov     [cs:apu_ch2_env_cnt], ah
    jmp     near .ret_ok

.nr21:
    and     al, 3Fh
    mov     ah, 64
    sub     ah, al
    mov     [cs:apu_ch2_len], ah
    jmp     near .ret_ok

.nr22:
    test    al, 0F8h
    jnz     short .nr22_chk0
    mov     byte [cs:apu_ch2_on], 0
    jmp     near .ret_ok
.nr22_chk0:
    cmp     al, 08h
    jne     near .ret_ok
    mov     byte [cs:apu_ch2_vol], 0
    jmp     near .ret_ok

.nr23:
    mov     [cs:apu_ch2_freq], al
    jmp     near .ret_ok

; --- Channel 3 (0xFF1A..0xFF1E) ---
.wr_ch3:
    cmp     bp, 0FF1Ah
    je      short .nr30
    cmp     bp, 0FF1Bh
    je      short .nr31
    cmp     bp, 0FF1Dh
    je      short .nr33
    cmp     bp, 0FF1Eh
    jne     short .ret_ok
    ; NR34 (0xFF1E): freq[10:8] + trigger
    mov     ah, al
    and     ah, 07h
    mov     [cs:apu_ch3_freq + 1], ah
    test    al, 80h
    jz      short .ret_ok
    test    byte [ds:0FF1Ah], 80h
    jz      short .ret_ok
    mov     byte [cs:apu_ch3_on], 1
    cmp     word [cs:apu_ch3_len], 0
    jne     short .ret_ok
    mov     word [cs:apu_ch3_len], 256
    jmp     short .ret_ok

.nr30:
    test    al, 80h
    jnz     short .ret_ok
    mov     byte [cs:apu_ch3_on], 0
    jmp     short .ret_ok

.nr31:
    xor     ah, ah
    mov     bx, 256
    sub     bx, ax
    mov     [cs:apu_ch3_len], bx
    jmp     short .ret_ok

.nr33:
    mov     [cs:apu_ch3_freq], al
    jmp     short .ret_ok

; --- NR52 (0xFF26) ---
.wr_nr52:
    test    al, 80h
    jnz     short .ret_ok
    mov     byte [cs:apu_ch1_on], 0
    mov     byte [cs:apu_ch2_on], 0
    mov     byte [cs:apu_ch3_on], 0
    call    spk_mute

.ret_ok:
    pop     bx
    pop     ax
    popf
    ret

; ------------------------------------------------------------------------------
; apu_frame_tick: Advance APU length/envelope/sweep once per 59.73 Hz frame
; and update PIT Channel 2 speaker frequency.
; Inputs: DS = gb_mem_seg. Preserves all registers and CPU flags.
; ------------------------------------------------------------------------------
apu_frame_tick:
    pushf
    push    ax
    push    bx
    push    cx
    push    dx

    cmp     byte [cs:cfg_sound], 0
    je      near .mute_out
    test    byte [ds:0FF26h], 80h
    jz      near .mute_out

    ; 1. Length counters (256 Hz -> 4 ticks per 60 Hz frame)
    cmp     byte [cs:apu_ch1_on], 0
    je      short .len_ch2
    test    byte [ds:0FF14h], 40h
    jz      short .len_ch2
    mov     al, [cs:apu_ch1_len]
    sub     al, 4
    ja      short .len1_keep
    xor     al, al
    mov     byte [cs:apu_ch1_on], 0
.len1_keep:
    mov     [cs:apu_ch1_len], al

.len_ch2:
    cmp     byte [cs:apu_ch2_on], 0
    je      short .len_ch3
    test    byte [ds:0FF19h], 40h
    jz      short .len_ch3
    mov     al, [cs:apu_ch2_len]
    sub     al, 4
    ja      short .len2_keep
    xor     al, al
    mov     byte [cs:apu_ch2_on], 0
.len2_keep:
    mov     [cs:apu_ch2_len], al

.len_ch3:
    cmp     byte [cs:apu_ch3_on], 0
    je      short .env_ch1
    test    byte [ds:0FF1Eh], 40h
    jz      short .env_ch1
    mov     ax, [cs:apu_ch3_len]
    sub     ax, 4
    ja      short .len3_keep
    xor     ax, ax
    mov     byte [cs:apu_ch3_on], 0
.len3_keep:
    mov     [cs:apu_ch3_len], ax

    ; 2. Volume envelopes (64 Hz -> 1 tick per 60 Hz frame)
.env_ch1:
    cmp     byte [cs:apu_ch1_on], 0
    je      short .env_ch2
    mov     al, [ds:0FF12h]
    mov     bl, al
    and     bl, 07h
    jz      short .env_ch2
    dec     byte [cs:apu_ch1_env_cnt]
    jg      short .env_ch2
    mov     [cs:apu_ch1_env_cnt], bl
    test    al, 08h
    jz      short .env1_dn
    cmp     byte [cs:apu_ch1_vol], 15
    jae     short .env_ch2
    inc     byte [cs:apu_ch1_vol]
    jmp     short .env_ch2
.env1_dn:
    cmp     byte [cs:apu_ch1_vol], 0
    je      short .env_ch2
    dec     byte [cs:apu_ch1_vol]

.env_ch2:
    cmp     byte [cs:apu_ch2_on], 0
    je      short .swp_ch1
    mov     al, [ds:0FF17h]
    mov     bl, al
    and     bl, 07h
    jz      short .swp_ch1
    dec     byte [cs:apu_ch2_env_cnt]
    jg      short .swp_ch1
    mov     [cs:apu_ch2_env_cnt], bl
    test    al, 08h
    jz      short .env2_dn
    cmp     byte [cs:apu_ch2_vol], 15
    jae     short .swp_ch1
    inc     byte [cs:apu_ch2_vol]
    jmp     short .swp_ch1
.env2_dn:
    cmp     byte [cs:apu_ch2_vol], 0
    je      short .swp_ch1
    dec     byte [cs:apu_ch2_vol]

    ; 3. Channel 1 frequency sweep (128 Hz -> 2 ticks per 60 Hz frame)
.swp_ch1:
    cmp     byte [cs:apu_ch1_on], 0
    je      short .select_voice
    mov     al, [ds:0FF10h]
    mov     ah, al
    shr     ah, 4
    and     ah, 07h                 ; AH = sweep time
    jz      short .select_voice
    mov     cl, al
    and     cl, 07h                 ; CL = sweep shift
    mov     ch, 2                   ; 2 sweep ticks per frame
.swp_loop:
    dec     byte [cs:apu_ch1_swp_cnt]
    jg      short .swp_next
    mov     [cs:apu_ch1_swp_cnt], ah
    or      cl, cl
    jz      short .swp_next
    mov     bx, [cs:apu_ch1_swp_shadow]
    mov     dx, bx
    shr     dx, cl
    test    al, 08h                 ; Bit 3: 1 = subtract (down), 0 = add (up)
    jz      short .swp_up
    sub     bx, dx
    jnc     short .swp_store
    xor     bx, bx
    jmp     short .swp_store
.swp_up:
    add     bx, dx
    cmp     bx, 2047
    jbe     short .swp_store
    mov     byte [cs:apu_ch1_on], 0
    jmp     short .select_voice
.swp_store:
    mov     [cs:apu_ch1_swp_shadow], bx
    mov     [cs:apu_ch1_freq], bx
.swp_next:
    dec     ch
    jnz     short .swp_loop

    ; 4. Voice selection (BL = Ch1 eff_vol, BH = Ch2 eff_vol)
.select_voice:
    mov     dl, [ds:0FF25h]         ; NR51 panning
    xor     bx, bx

    cmp     byte [cs:apu_ch1_on], 0
    je      short .chk_ch2
    test    dl, 11h
    jz      short .chk_ch2
    cmp     word [cs:apu_ch1_freq], 2045
    jae     short .chk_ch2
    mov     bl, [cs:apu_ch1_vol]

.chk_ch2:
    cmp     byte [cs:apu_ch2_on], 0
    je      short .arbitrate
    test    dl, 22h
    jz      short .arbitrate
    cmp     word [cs:apu_ch2_freq], 2045
    jae     short .arbitrate
    mov     bh, [cs:apu_ch2_vol]

.arbitrate:
    mov     al, bl
    or      al, bh
    jz      short .try_ch3

    cmp     bl, bh
    ja      short .play_ch1
    jb      short .play_ch2
    cmp     byte [cs:apu_last_trig], 2
    je      short .play_ch2

.play_ch1:
    mov     ax, 2048
    sub     ax, [cs:apu_ch1_freq]
    jmp     short .calc_sq_div

.play_ch2:
    mov     ax, 2048
    sub     ax, [cs:apu_ch2_freq]

.calc_sq_div:
    ; divisor = ((2048 - F) * 2330) >> 8
    mov     bx, 2330
    mul     bx
    mov     al, ah
    mov     ah, dl
    call    spk_set_div
    jmp     short .tick_done

.try_ch3:
    cmp     byte [cs:apu_ch3_on], 0
    je      short .mute_out
    test    byte [ds:0FF1Ch], 60h   ; Wave output level != 00 (mute)
    jz      short .mute_out
    test    dl, 44h
    jz      short .mute_out
    cmp     word [cs:apu_ch3_freq], 2044
    jae     short .mute_out

    ; Wave channel plays at half square frequency -> double PIT divisor
    mov     ax, 2048
    sub     ax, [cs:apu_ch3_freq]
    mov     bx, 2330
    mul     bx
    mov     al, ah
    mov     ah, dl
    shl     ax, 1
    call    spk_set_div
    jmp     short .tick_done

.mute_out:
    call    spk_mute

.tick_done:
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    popf
    ret

;apu state in CS
global apu_cur_div, apu_state_start, apu_state_end
apu_cur_div:        dw 0
apu_state_start:
apu_ch1_freq:       dw 0
apu_ch1_swp_shadow: dw 0
apu_ch2_freq:       dw 0
apu_ch3_freq:       dw 0
apu_ch3_len:        dw 0
apu_ch1_len:        db 0
apu_ch2_len:        db 0
apu_ch1_vol:        db 0
apu_ch2_vol:        db 0
apu_ch1_env_cnt:    db 0
apu_ch2_env_cnt:    db 0
apu_ch1_swp_cnt:    db 0
apu_ch1_on:         db 0
apu_ch2_on:         db 0
apu_ch3_on:         db 0
apu_last_trig:      db 1
apu_state_end:
