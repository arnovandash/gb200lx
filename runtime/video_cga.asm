; ==============================================================================
; video_cga.asm - HP 200LX CGA Mode 04h Video Driver
; Implements 320x200 4-shade grayscale graphics and 160x144 viewport rendering.
; ==============================================================================

bits 16
cpu 186

; ------------------------------------------------------------------------------
; cga_init: Switch video controller to CGA Mode 04h (320x200, 4 colors/shades)
; Input:  None
; Output: None
; Clobbers: AX, ES, DI, CX
; ------------------------------------------------------------------------------
cga_init:
    push    bp
    mov     bp, sp

    ; Set video mode 04h (320x200 4-color graphics)
    mov     ax, 0004h
    int     10h

    ; Apply configured CGA hardware palette & background color
    call    cga_sync_hw_palette

    ; Initialize precomputed scanline offset lookup table
    call    cga_blit_scanline_table_init

    ; Clear the entire 320x200 frame buffer
    call    cga_clear_screen

    pop     bp
    ret

; ------------------------------------------------------------------------------
; cga_sync_hw_palette: Program BIOS CGA palette (INT 10h AH=0Bh) for cfg_palette
; ------------------------------------------------------------------------------
global cga_sync_hw_palette
cga_sync_hw_palette:
    push    ax
    push    bx
    mov     ax, 0B00h
    mov     bx, 0101h               ; Palette 1 (Cyan/Magenta/White)
    xor     al, al                  ; Background/Border = Black (00h)
    cmp     byte [cs:cfg_palette], PAL_DMG
    jne     .set_pal
    mov     bl, 00h                 ; DMG: Palette 0 (Green/Red/Brown)
    mov     al, 02h                 ; DMG: Green background (02h)
.set_pal:
    push    ax
    mov     ah, 0Bh
    int     10h                     ; Set Palette ID (BH=01h, BL=0/1)
    pop     ax
    mov     bl, al
    xor     bh, bh
    mov     ah, 0Bh
    int     10h                     ; Set Background/Border color (BH=00h, BL=0/2)
    pop     bx
    pop     ax
    ret

; ------------------------------------------------------------------------------
; cga_restore_text: Cleanly restore standard 80x25 16-color text mode (Mode 03h)
; Input:  None
; Output: None
; Clobbers: AX
; ------------------------------------------------------------------------------
cga_restore_text:
    push    bp
    mov     bp, sp

    mov     ax, 0003h
    int     10h

    pop     bp
    ret

; ------------------------------------------------------------------------------
; cga_clear_screen: Clears both even and odd CGA VRAM fields to [cs:cfg_shade0]
; Input:  None
; Output: None
; Clobbers: AX, CX, ES, DI
; ------------------------------------------------------------------------------
cga_clear_screen:
    push    bp
    mov     bp, sp

    mov     ax, CGA_VRAM_SEG
    mov     es, ax

    ; Fill even scanline field (4000 words) with paper shade (00h or FFh in Dark mode)
    xor     di, di
    mov     al, [cs:cfg_shade0]
    mov     ah, al
    mov     cx, 4000
    cld
    rep     stosw

    ; Fill odd scanline field (starts at 2000h)
    mov     di, CGA_ODD_OFFSET
    mov     cx, 4000
    rep     stosw

    pop     bp
    ret

; ------------------------------------------------------------------------------
; cga_blit_scanline_table_init: Build lookup table of CGA VRAM scanline offsets
; Table maps Game Boy scanline y (0..143) directly to CGA VRAM offset.
; ------------------------------------------------------------------------------
cga_blit_scanline_table_init:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si

    ; We populate cga_scanline_offsets for lines 0..143
    ; Screen line = 28 + y.
    ; Even lines: ( (28+y)/2 ) * 80 + 20
    ; Odd lines:  2000h + ( (28+y-1)/2 ) * 80 + 20
    mov     si, cga_scanline_offsets
    xor     cx, cx                  ; cx = y (0..143)

.init_loop:
    mov     ax, cx
    add     ax, GB_OFFSET_Y_LINES   ; ax = screen line (28 + y)
    test    ax, 1
    jnz     .odd_line

.even_line:
    shr     ax, 1                   ; ax = screen_line / 2
    mov     dx, CGA_BYTES_PER_LINE
    mul     dx                      ; ax = (screen_line/2) * 80
    add     ax, GB_OFFSET_X_BYTES   ; + 20 bytes horizontal offset
    jmp     .store_offset

.odd_line:
    shr     ax, 1                   ; ax = (screen_line-1)/2
    mov     dx, CGA_BYTES_PER_LINE
    mul     dx                      ; ax = ((screen_line-1)/2) * 80
    add     ax, CGA_ODD_OFFSET + GB_OFFSET_X_BYTES ; + 2000h + 20 bytes

.store_offset:
    mov     [si], ax
    add     si, 2
    inc     cx
    cmp     cx, GB_SCREEN_HEIGHT
    jb      .init_loop

    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ------------------------------------------------------------------------------
; cga_draw_border: Draws a thin decorative border around the 160x144 viewport
; Margins: x = 79..240, y = 27..172
; ------------------------------------------------------------------------------
cga_draw_border:
    cmp     byte [cs:cfg_border], 0
    jne     .border_enabled
    ret
.border_enabled:
    push    ax
    push    bx
    push    cx
    push    dx
    push    di
    push    es

    mov     ax, CGA_VRAM_SEG
    mov     es, ax
    cld

    cmp     byte [cs:cfg_scaling], SCALE_WIDE
    je      .border_wide

    ; Centered 160x144 border: Top y=27 (40 bytes), Bottom y=172 (40 bytes)
    mov     di, CGA_ODD_OFFSET + (13 * CGA_BYTES_PER_LINE) + GB_OFFSET_X_BYTES
    mov     al, [cs:cfg_shade3]
    mov     cx, GB_BYTES_PER_LINE
    rep     stosb

    mov     di, (86 * CGA_BYTES_PER_LINE) + GB_OFFSET_X_BYTES
    mov     cx, GB_BYTES_PER_LINE
    rep     stosb

    ; Left & right vertical edges on scanlines 28..171 (preserve outer paper shade)
    mov     al, [cs:cfg_shade0]
    and     al, 11111100b
    mov     dl, [cs:cfg_shade3]
    and     dl, 00000011b
    or      al, dl                  ; Left edge byte

    mov     ah, [cs:cfg_shade0]
    and     ah, 00111111b
    mov     dl, [cs:cfg_shade3]
    and     dl, 11000000b
    or      ah, dl                  ; Right edge byte

    xor     cx, cx                  ; y = 0..143
.vert_loop:
    mov     bx, cx
    shl     bx, 1
    mov     di, [cs:cga_scanline_offsets + bx]
    mov     [es:di - 1], al
    mov     [es:di + GB_BYTES_PER_LINE], ah
    inc     cx
    cmp     cx, GB_SCREEN_HEIGHT
    jb      .vert_loop
    jmp     short .border_done

.border_wide:
    ; Wide 320x144 border: Top y=27 (80 bytes), Bottom y=172 (80 bytes)
    mov     al, [cs:cfg_shade3]
    mov     di, CGA_ODD_OFFSET + (13 * CGA_BYTES_PER_LINE)
    mov     cx, CGA_BYTES_PER_LINE
    rep     stosb

    mov     di, 86 * CGA_BYTES_PER_LINE
    mov     cx, CGA_BYTES_PER_LINE
    rep     stosb

.border_done:
    pop     es
    pop     di
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; ------------------------------------------------------------------------------
; cga_draw_test_pattern: Fills 160x144 Game Boy viewport with a 4-shade test
; pattern demonstrating all 4 shades of the HP 200LX:
;   - Lines 0..35:   4 vertical bars: White (0), Lt Gray (1), Dk Gray (2), Black (3)
;   - Lines 36..71:  Horizontal gradient bars (16 scanlines each)
;   - Lines 72..107: 8x8 checkerboard pattern
;   - Lines 108..143: Diagonal dither pattern
; ------------------------------------------------------------------------------
cga_draw_test_pattern:
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    es

    call    cga_draw_border

    mov     ax, CGA_VRAM_SEG
    mov     es, ax

    ; Section 1: Lines 0..35 (4 Vertical bars, 40 pixels = 10 bytes each)
    ; Bar 0 (x=0..39, bytes 0..9):   White   (00h)
    ; Bar 1 (x=40..79, bytes 10..19): Lt Gray (55h)
    ; Bar 2 (x=80..119, bytes 20..29): Dk Gray (AAh)
    ; Bar 3 (x=120..159, bytes 30..39): Black  (FFh)
    xor     cx, cx
.sec1_loop:
    mov     bx, cx
    shl     bx, 1
    mov     di, [cga_scanline_offsets + bx]

    ; Bar 0: 10 bytes White (00h)
    mov     al, [cfg_shade0]
    push    cx
    mov     cx, 10
    rep     stosb

    ; Bar 1: 10 bytes Light Gray (55h)
    mov     al, [cfg_shade1]
    mov     cx, 10
    rep     stosb

    ; Bar 2: 10 bytes Dark Gray (AAh)
    mov     al, [cfg_shade2]
    mov     cx, 10
    rep     stosb

    ; Bar 3: 10 bytes Black (FFh)
    mov     al, [cfg_shade3]
    mov     cx, 10
    rep     stosb

    pop     cx
    inc     cx
    cmp     cx, 36
    jb      .sec1_loop

    ; Section 2: Lines 36..71 (4 horizontal shade blocks, 9 scanlines each)
.sec2_loop:
    mov     bx, cx
    shl     bx, 1
    mov     di, [cga_scanline_offsets + bx]

    cmp     cx, 45
    jb      .h_white
    cmp     cx, 54
    jb      .h_ltgray
    cmp     cx, 63
    jb      .h_dkgray
    ; Black
    mov     al, [cfg_shade3]
    jmp     .h_write
.h_white:
    mov     al, [cfg_shade0]
    jmp     .h_write
.h_ltgray:
    mov     al, [cfg_shade1]
    jmp     .h_write
.h_dkgray:
    mov     al, [cfg_shade2]

.h_write:
    push    cx
    mov     cx, GB_BYTES_PER_LINE
    rep     stosb
    pop     cx

    inc     cx
    cmp     cx, 72
    jb      .sec2_loop

    ; Section 3: Lines 72..107 (8x8 tile checkerboard pattern)
    ; Alternate 8x8 squares between Lt Gray and Dk Gray
.sec3_loop:
    mov     bx, cx
    shl     bx, 1
    mov     di, [cga_scanline_offsets + bx]

    ; Check if current 8-line band is even or odd
    mov     ax, cx
    sub     ax, 72
    shr     ax, 3                   ; ax = (y - 72) / 8
    test    al, 1
    jnz     .tile_band_odd

.tile_band_even:
    ; 8 pixels = 2 bytes per checker tile. 20 tiles across 40 bytes.
    push    cx
    mov     al, [cfg_shade1]
    mov     ah, [cfg_shade2]
    mov     cx, 10                  ; 10 pairs of tiles
.tbe_sub:
    mov     [es:di],   al
    mov     [es:di+1], al
    mov     [es:di+2], ah
    mov     [es:di+3], ah
    add     di, 4
    loop    .tbe_sub
    pop     cx
    jmp     .sec3_next

.tile_band_odd:
    push    cx
    mov     al, [cfg_shade2]
    mov     ah, [cfg_shade1]
    mov     cx, 10
.tbo_sub:
    mov     [es:di],   al
    mov     [es:di+1], al
    mov     [es:di+2], ah
    mov     [es:di+3], ah
    add     di, 4
    loop    .tbo_sub
    pop     cx

.sec3_next:
    inc     cx
    cmp     cx, 108
    jb      .sec3_loop

    ; Section 4: Lines 108..143 (Diagonal dither / gradient pattern)
.sec4_loop:
    mov     bx, cx
    shl     bx, 1
    mov     di, [cga_scanline_offsets + bx]

    ; Create rolling dither pattern based on line number
    mov     al, cl
    and     al, 3
    cmp     al, 0
    je      .pat0
    cmp     al, 1
    je      .pat1
    cmp     al, 2
    je      .pat2
    mov     ah, 11011000b           ; Pat 3
    jmp     .sec4_write
.pat0:
    mov     ah, 00011011b
    jmp     .sec4_write
.pat1:
    mov     ah, 01101100b
    jmp     .sec4_write
.pat2:
    mov     ah, 10110001b

.sec4_write:
    push    cx
    mov     al, ah
    mov     cx, GB_BYTES_PER_LINE
    rep     stosb
    pop     cx

    inc     cx
    cmp     cx, GB_SCREEN_HEIGHT
    jb      .sec4_loop

    pop     es
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; Table of 144 precalculated CGA VRAM destination offsets
cga_scanline_offsets:
    times GB_SCREEN_HEIGHT dw 0

    align 16
global dmg_cga_nibble_table
dmg_cga_nibble_table:
    times 256 db 0

; ------------------------------------------------------------------------------
; helper_update_bgp: Update 256-byte DMG-to-CGA nibble lookup table
; AL = new BGP palette register value. Preserves all registers and CPU flags!
; ------------------------------------------------------------------------------
global helper_update_bgp
helper_update_bgp:
    pushf
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    es

    mov     bx, cs
    mov     es, bx
    mov     di, dmg_cga_nibble_table

    mov     dl, al              ; DL = palette byte

    xor     cx, cx              ; CX = index 0..255
.tab_loop:
    mov     bx, cx
    shr     bx, 4               ; BL = b1_nib (high bits of 4 pixels)
    mov     ah, cl
    and     ah, 0Fh             ; AH = b0_nib (low bits of 4 pixels)

    xor     dh, dh              ; DH will accumulate CGA byte (4 pixels * 2 bits)

    ; Pixel 0 (MSB, bit 3):
    xor     bh, bh
    test    bl, 08h
    jz      short .p0_b1_0
    or      bh, 02h
.p0_b1_0:
    test    ah, 08h
    jz      short .p0_b0_0
    or      bh, 01h
.p0_b0_0:
    push    cx
    mov     cl, bh
    shl     cl, 1
    mov     ch, dl
    shr     ch, cl
    and     ch, 03h
    push    bx
    mov     bl, ch
    xor     bh, bh
    mov     ch, [cs:cfg_shade0 + bx]
    pop     bx
    and     ch, 03h
    shl     ch, 6
    or      dh, ch
    pop     cx

    ; Pixel 1 (bit 2):
    xor     bh, bh
    test    bl, 04h
    jz      short .p1_b1_0
    or      bh, 02h
.p1_b1_0:
    test    ah, 04h
    jz      short .p1_b0_0
    or      bh, 01h
.p1_b0_0:
    push    cx
    mov     cl, bh
    shl     cl, 1
    mov     ch, dl
    shr     ch, cl
    and     ch, 03h
    push    bx
    mov     bl, ch
    xor     bh, bh
    mov     ch, [cs:cfg_shade0 + bx]
    pop     bx
    and     ch, 03h
    shl     ch, 4
    or      dh, ch
    pop     cx

    ; Pixel 2 (bit 1):
    xor     bh, bh
    test    bl, 02h
    jz      short .p2_b1_0
    or      bh, 02h
.p2_b1_0:
    test    ah, 02h
    jz      short .p2_b0_0
    or      bh, 01h
.p2_b0_0:
    push    cx
    mov     cl, bh
    shl     cl, 1
    mov     ch, dl
    shr     ch, cl
    and     ch, 03h
    push    bx
    mov     bl, ch
    xor     bh, bh
    mov     ch, [cs:cfg_shade0 + bx]
    pop     bx
    and     ch, 03h
    shl     ch, 2
    or      dh, ch
    pop     cx

    ; Pixel 3 (bit 0):
    xor     bh, bh
    test    bl, 01h
    jz      short .p3_b1_0
    or      bh, 02h
.p3_b1_0:
    test    ah, 01h
    jz      short .p3_b0_0
    or      bh, 01h
.p3_b0_0:
    push    cx
    mov     cl, bh
    shl     cl, 1
    mov     ch, dl
    shr     ch, cl
    and     ch, 03h
    push    bx
    mov     bl, ch
    xor     bh, bh
    mov     ch, [cs:cfg_shade0 + bx]
    pop     bx
    and     ch, 03h
    or      dh, ch
    pop     cx

    mov     [es:di], dh
    inc     di
    inc     cx
    cmp     cx, 256
    jb      near .tab_loop

    pop     es
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    popf
    ret

; ------------------------------------------------------------------------------
; cga_render_gb_frame: Render Game Boy VRAM (0x8000..0x9FFF) & OAM to CGA Mode 04h
; Uses LCDC (0xFF40), SCY (0xFF42), SCX (0xFF43), BGP (0xFF47), and OAM (0xFE00).
; ------------------------------------------------------------------------------
global cga_render_gb_frame
cga_render_gb_frame:
    pushf
    push    ax
    push    bx
    push    cx
    push    dx
    push    si
    push    di
    push    bp
    push    es

    ; Check LCDC register (0xFF40)
    mov     al, [ds:0FF40h]
    test    al, 80h             ; Bit 7: LCD enable
    jz      near .render_done   ; LCD disabled, skip

    ; Ensure BGP nibble table is up to date with [ds:0FF47h] (skip if unchanged)
    mov     al, [ds:0FF47h]
    cmp     al, [cs:last_bgp]
    je      .bgp_ok
    mov     [cs:last_bgp], al
    call    helper_update_bgp
    mov     bl, [ds:0FF47h]
    and     bx, 0003h
    mov     al, [cs:cfg_shade0 + bx]
    and     al, 03h
    mov     [cs:render_bg0_shade], al
    ; Mark all 384 VRAM tiles dirty on palette change
    push    di
    mov     ax, cs
    mov     es, ax
    mov     di, tile_dirty
    mov     ax, 0101h
    mov     cx, 192
    cld
    rep     stosw
    pop     di
.bgp_ok:
    ; Decode any dirty tiles in 0x8000..0x97FF into cga_tile_cache
    call    update_cga_tile_cache
    mov     al, [ds:0FF40h]

    ; Setup ES = backbuffer_seg for rendering into offscreen backbuffer
    mov     bx, [cs:backbuffer_seg]
    mov     es, bx

    ; Determine BG tile map base: bit 3 of LCDC
    ; 0 = 0x9800, 1 = 0x9C00
    mov     word [cs:render_map_base], 09800h
    test    al, 08h
    jz      .map_base_ok
    mov     word [cs:render_map_base], 09C00h
.map_base_ok:

    ; Determine Tile Data addressing mode: bit 4 of LCDC
    ; 0 = signed (0x8800..0x97FF, base 0x9000)
    ; 1 = unsigned (0x8000..0x8FFF)
    mov     byte [cs:render_unsigned_tile], 0
    test    al, 10h
    jz      .tile_mode_ok
    mov     byte [cs:render_unsigned_tile], 1
.tile_mode_ok:

    ; Read initial SCY/SCX (updated per strip for LYC split)
    mov     al, [ds:0FF42h]
    mov     [cs:render_scy], al
    mov     al, [ds:0FF43h]
    mov     [cs:render_scx], al

    ; Precompute STAT LYC split limit: split applies for Y < split_limit (0 = disabled)
    mov     byte [cs:render_split_limit], 0
    test    byte [ds:0FFFFh], 02h
    jz      .split_done
    mov     al, [ds:0FF45h]
    cmp     al, 0
    je      .split_done
    cmp     al, GB_SCREEN_HEIGHT
    jae     .split_done
    inc     al
    mov     [cs:render_split_limit], al
.split_done:

    ; Render 144 BG scanlines in tile-row strips (up to 8 scanlines per strip)
    xor     cx, cx              ; CX = screen Y (0..143)
.bg_strip_loop:
    mov     [cs:render_y], cx
    cmp     cl, [cs:render_split_limit]
    jb      .use_hud_scroll
    mov     al, [ds:0FF42h]     ; Main SCY
    mov     ah, [ds:0FF43h]     ; Main SCX
    mov     dl, GB_SCREEN_HEIGHT
    jmp     short .scroll_ready
.use_hud_scroll:
    mov     al, [cs:hud_scy]
    mov     ah, [cs:hud_scx]
    mov     dl, [cs:render_split_limit]
.scroll_ready:
    mov     [cs:render_scy], al
    mov     [cs:render_scx], ah

    ; bg_y = (Y + SCY) & 0xFF
    mov     bl, cl
    add     bl, al              ; BL = bg_y
    mov     bh, bl
    and     bh, 07h             ; BH = fine_y (0..7)

    ; run_lines = min(8 - fine_y, region_end - Y)  (1..8)
    mov     dh, 8
    sub     dh, bh
    sub     dl, cl              ; region_end - Y (>= 1)
    cmp     dh, dl
    jbe     .bg_rl_ok
    mov     dh, dl
.bg_rl_ok:
    mov     [cs:render_run_lines], dh

    ; BP = cga_tile_cache (+ 1000h if signed) + fine_y * 2
    shl     bh, 1
    mov     al, bh
    xor     ah, ah
    cmp     byte [cs:render_unsigned_tile], 1
    je      .bg_bp_unsigned
    add     ax, cga_tile_cache + 1000h
    jmp     short .bg_bp_ok
.bg_bp_unsigned:
    add     ax, cga_tile_cache
.bg_bp_ok:
    mov     bp, ax

    ; SI = map row base = render_map_base + ((bg_y >> 3) * 32)
    shr     bl, 3
    mov     al, bl
    xor     ah, ah
    shl     ax, 5
    add     ax, [cs:render_map_base]
    mov     si, ax

    ; DI = backbuffer destination for scanline Y
    mov     bx, cx
    shl     bx, 1
    mov     di, [cs:backbuffer_scanline_offsets + bx]

    ; Check horizontal fine scroll (SCX & 7)
    mov     al, [cs:render_scx]
    mov     ah, al
    and     ah, 07h             ; AH = fine_x (0..7)
    shr     al, 3               ; AL = starting tile_col (0..31)
    or      ah, ah
    jnz     .bg_fine_scroll

    ; Aligned strip (fine_x == 0): render 20 tiles directly to backbuffer_seg
    mov     cl, al
    mov     ch, 20
    call    render_aligned_strip
    jmp     near .bg_strip_next

.bg_fine_scroll:
    ; Fine-scrolled strip: render 21 tiles x run_lines into CS:cga_strip_buf (stride 44)
    mov     [cs:render_fine_x], ah
    mov     [cs:render_dest_di], di
    push    es
    mov     bx, cs
    mov     es, bx
    mov     di, cga_strip_buf
    mov     cl, al
    mov     ch, 21
    xor     bh, bh
    mov     bl, [cs:render_run_lines]
    dec     bx
    shl     bx, 1
    cmp     byte [cs:render_unsigned_tile], 1
    je      .sc_go_u
    mov     dx, [cs:sc_s_tab + bx]
.sc_loop_s:
    xor     bh, bh
    mov     bl, cl
    inc     cl
    and     cl, 1Fh
    mov     al, [ds:si + bx]
    cbw
    shl     ax, 4
    add     ax, bp
    mov     bx, ax
    jmp     dx
.sc_s_8: mov ax, [cs:bx+14]
         mov [es:di+308], ax
.sc_s_7: mov ax, [cs:bx+12]
         mov [es:di+264], ax
.sc_s_6: mov ax, [cs:bx+10]
         mov [es:di+220], ax
.sc_s_5: mov ax, [cs:bx+8]
         mov [es:di+176], ax
.sc_s_4: mov ax, [cs:bx+6]
         mov [es:di+132], ax
.sc_s_3: mov ax, [cs:bx+4]
         mov [es:di+88], ax
.sc_s_2: mov ax, [cs:bx+2]
         mov [es:di+44], ax
.sc_s_1: mov ax, [cs:bx]
         mov [es:di], ax
    add     di, 2
    dec     ch
    jnz     .sc_loop_s
    jmp     short .sc_filled

.sc_go_u:
    mov     dx, [cs:sc_u_tab + bx]
.sc_loop_u:
    xor     bh, bh
    mov     bl, cl
    inc     cl
    and     cl, 1Fh
    mov     al, [ds:si + bx]
    xor     ah, ah
    shl     ax, 4
    add     ax, bp
    mov     bx, ax
    jmp     dx
.sc_u_8: mov ax, [cs:bx+14]
         mov [es:di+308], ax
.sc_u_7: mov ax, [cs:bx+12]
         mov [es:di+264], ax
.sc_u_6: mov ax, [cs:bx+10]
         mov [es:di+220], ax
.sc_u_5: mov ax, [cs:bx+8]
         mov [es:di+176], ax
.sc_u_4: mov ax, [cs:bx+6]
         mov [es:di+132], ax
.sc_u_3: mov ax, [cs:bx+4]
         mov [es:di+88], ax
.sc_u_2: mov ax, [cs:bx+2]
         mov [es:di+44], ax
.sc_u_1: mov ax, [cs:bx]
         mov [es:di], ax
    add     di, 2
    dec     ch
    jnz     .sc_loop_u

.sc_filled:
    ; Blit/shift run_lines scanlines from CS:cga_strip_buf to backbuffer_seg:render_dest_di
    pop     es                  ; ES = backbuffer_seg
    push    ds                  ; Save gb_mem_seg
    mov     ax, cs
    mov     ds, ax              ; DS = CS for fast lodsb/lodsw
    mov     si, cga_strip_buf
    mov     di, [render_dest_di]
    mov     cl, [render_fine_x]
    cmp     cl, 4
    jb      .sb_shift_setup
    inc     si                  ; fine_x >= 4 skips 1 full byte (4 pixels)
    sub     cl, 4
    jnz     .sb_shift_setup

    ; fine_x == 4: byte-aligned 20-word rep movsw per scanline!
    mov     bl, [render_run_lines]
    cld
.sb4_loop:
    push    si
    push    di
    mov     cx, (GB_BYTES_PER_LINE / 2)
    rep     movsw
    pop     di
    pop     si
    add     si, 44
    add     di, GB_BYTES_PER_LINE
    dec     bl
    jnz     .sb4_loop
    jmp     short .sb_done

.sb_shift_setup:
    shl     cl, 1               ; CL = 2, 4, or 6 bits left shift
    mov     ch, 8
    sub     ch, cl              ; CH = 6, 4, or 2 bits right shift
    mov     al, [render_run_lines]
    mov     [render_row_cnt], al
    cld
.sb_line_loop:
    push    si
    push    di
    lodsb
    mov     bh, al              ; BH = b0
    mov     bp, (GB_BYTES_PER_LINE / 2)
.sb_word_loop:
    lodsw                       ; AL = b1, AH = b2
    mov     bl, ah              ; BL = b2 (next iter's b0)
    mov     ah, bh              ; AH = b0, AL = b1
    shl     ax, cl              ; AH = out0, AL = b1 << CL
    mov     dl, ah              ; DL = out0
    mov     ah, bl              ; AH = b2
    xchg    cl, ch
    shr     ah, cl              ; AH = b2 >> (8 - CL)
    xchg    cl, ch
    or      al, ah              ; AL = out1
    mov     ah, al
    mov     al, dl              ; AX = (out1 << 8) | out0
    stosw
    mov     bh, bl
    dec     bp
    jnz     .sb_word_loop
    pop     di
    pop     si
    add     si, 44
    add     di, GB_BYTES_PER_LINE
    dec     byte [render_row_cnt]
    jnz     .sb_line_loop

.sb_done:
    pop     ds                  ; Restore DS = gb_mem_seg

.bg_strip_next:
    mov     cx, [cs:render_y]
    xor     ah, ah
    mov     al, [cs:render_run_lines]
    add     cx, ax
    cmp     cx, GB_SCREEN_HEIGHT
    jb      near .bg_strip_loop

    ; --------------------------------------------------------------------------
    ; Render Game Boy Window Layer (if LCDC bit 5 is enabled) using cga_tile_cache
    ; --------------------------------------------------------------------------
    mov     al, [ds:0FF40h]
    test    al, 20h             ; Bit 5: Window enable
    jz      near .skip_window

    mov     word [cs:render_map_base], 09800h
    test    al, 40h             ; Bit 6: Window tile map (0=9800h, 1=9C00h)
    jz      .win_map_ok
    mov     word [cs:render_map_base], 09C00h
.win_map_ok:
    mov     al, [ds:0FF4Ah]     ; WY
    cmp     al, GB_SCREEN_HEIGHT
    jae     near .skip_window
    xor     ch, ch
    mov     cl, al              ; CX = start screen line Y = WY

    mov     al, [ds:0FF4Bh]     ; WX
    cmp     al, 167
    jae     near .skip_window
    cmp     al, 7
    jae     .wx_sub7
    mov     al, 7
.wx_sub7:
    sub     al, 7
    shr     al, 3
    mov     [cs:render_win_scol], al

    ; BP = cga_tile_cache (+ 1000h if signed), fine_y is always 0 for window strips
    mov     bp, cga_tile_cache
    cmp     byte [cs:render_unsigned_tile], 1
    je      .win_strip_loop
    add     bp, 1000h

.win_strip_loop:
    mov     [cs:render_y], cx
    mov     ax, GB_SCREEN_HEIGHT
    sub     ax, cx
    cmp     ax, 8
    jbe     .win_rl_ok
    mov     al, 8
.win_rl_ok:
    mov     [cs:render_run_lines], al

    ; win_row_base = win_map_base + ((Y - WY) >> 3) * 32
    mov     al, cl
    sub     al, [ds:0FF4Ah]
    shr     al, 3
    xor     ah, ah
    shl     ax, 5
    add     ax, [cs:render_map_base]
    mov     si, ax

    ; DI = backbuffer scanline Y + render_win_scol * 2
    mov     bx, cx
    shl     bx, 1
    mov     di, [cs:backbuffer_scanline_offsets + bx]
    xor     ax, ax
    mov     al, [cs:render_win_scol]
    shl     ax, 1
    add     di, ax

    mov     ch, 20
    sub     ch, [cs:render_win_scol]
    xor     cl, cl
    push    bp
    call    render_aligned_strip
    pop     bp

    mov     cx, [cs:render_y]
    xor     ah, ah
    mov     al, [cs:render_run_lines]
    add     cx, ax
    cmp     cx, GB_SCREEN_HEIGHT
    jb      near .win_strip_loop

.skip_window:
    ; --------------------------------------------------------------------------
    ; Render OAM Sprites (0xFE00..0xFE9F, 40 sprites) if LCDC bit 1 is enabled
    ; --------------------------------------------------------------------------
    mov     al, [ds:0FF40h]
    test    al, 02h
    jz      near .blit_backbuffer

    mov     byte [cs:render_spr_h], 8
    test    al, 04h             ; Bit 2: 8x16 sprites
    jz      .spr_h_ok
    mov     byte [cs:render_spr_h], 16
.spr_h_ok:

    mov     si, 0FE9Ch          ; Render from sprite 39 down to 0 so lower index has priority
    mov     cx, 40
.spr_loop:
    push    cx
    push    si

    mov     al, [ds:si]         ; Y + 16
    cmp     al, 0
    je      near .spr_next
    cmp     al, 160
    jae     near .spr_next
    sub     al, 16
    mov     [cs:render_spr_y], al

    mov     al, [ds:si+1]       ; X + 8
    cmp     al, 0
    je      near .spr_next
    cmp     al, 168
    jae     near .spr_next
    sub     al, 8
    mov     [cs:render_spr_x], al

    mov     al, [ds:si+2]       ; Tile index
    cmp     byte [cs:render_spr_h], 16
    jne     .spr_tile_ok
    and     al, 0FEh
.spr_tile_ok:
    mov     [cs:render_spr_tile], al

    mov     al, [ds:si+3]       ; Attributes
    mov     [cs:render_spr_attr], al

    ; Precompute CGA shades for sprite colors 1..3 once per visible sprite
    mov     dl, [ds:0FF48h]
    test    al, 10h
    jz      .spr_pal_ok
    mov     dl, [ds:0FF49h]
.spr_pal_ok:
    mov     bl, dl
    shr     bl, 2
    and     bx, 0003h
    mov     al, [cs:cfg_shade0 + bx]
    and     al, 03h
    mov     [cs:render_spr_pal_tab + 1], al

    mov     bl, dl
    shr     bl, 4
    and     bx, 0003h
    mov     al, [cs:cfg_shade0 + bx]
    and     al, 03h
    mov     [cs:render_spr_pal_tab + 2], al

    shr     dl, 6
    xor     bh, bh
    mov     bl, dl
    mov     al, [cs:cfg_shade0 + bx]
    and     al, 03h
    mov     [cs:render_spr_pal_tab + 3], al

    xor     cx, cx              ; CL = row 0 .. spr_h-1
.spr_row_loop:
    mov     al, [cs:render_spr_y]
    add     al, cl              ; screen_y = spr_y + row
    cmp     al, 144
    jae     near .spr_row_next  ; unsigned >= 144 also catches negative wrap!

    ; BP = backbuffer scanline pointer for screen_y
    xor     bx, bx
    mov     bl, al
    shl     bx, 1
    mov     bp, [cs:backbuffer_scanline_offsets + bx]

    ; Effective row (handle Y-flip bit 6)
    mov     al, cl
    test    byte [cs:render_spr_attr], 40h
    jz      .no_yflip
    mov     al, [cs:render_spr_h]
    dec     al
    sub     al, cl
.no_yflip:
    xor     ah, ah
    shl     ax, 1               ; eff_row * 2
    mov     bx, ax

    mov     al, [cs:render_spr_tile]
    xor     ah, ah
    shl     ax, 4               ; tile * 16
    add     ax, 08000h
    add     bx, ax              ; BX = GB VRAM tile row address

    mov     ax, [ds:bx]         ; AL = B0, AH = B1
    test    ax, ax              ; Skip completely transparent rows immediately!
    jz      near .spr_row_next

    mov     dl, [cs:render_spr_x]
    mov     ch, 8               ; 8 pixels in row
    test    byte [cs:render_spr_attr], 20h
    jnz     .spr_px_xflip

.spr_px_norm:
    xor     bx, bx
    shl     ah, 1
    adc     bl, bl
    shl     al, 1
    adc     bl, bl
    jz      .spr_norm_next      ; Color 0 is transparent
    cmp     dl, 160
    jae     .spr_norm_next
    call    spr_draw_pixel
.spr_norm_next:
    inc     dl
    dec     ch
    jnz     .spr_px_norm
    jmp     short .spr_row_next

.spr_px_xflip:
    xor     bx, bx
    shr     ah, 1
    adc     bl, bl
    shr     al, 1
    adc     bl, bl
    jz      .spr_xflip_next     ; Color 0 is transparent
    cmp     dl, 160
    jae     .spr_xflip_next
    call    spr_draw_pixel
.spr_xflip_next:
    inc     dl
    dec     ch
    jnz     .spr_px_xflip

.spr_row_next:
    inc     cl
    cmp     cl, [cs:render_spr_h]
    jb      near .spr_row_loop

.spr_next:
    pop     si
    pop     cx
    sub     si, 4
    dec     cx
    jnz     near .spr_loop

.blit_backbuffer:
    ; Optional CGA vertical retrace sync (cfg_vsync == 1) with bounded safety timeout
    cmp     byte [cs:cfg_vsync], 0
    je      .vsync_done
    mov     dx, CGA_STATUS_REG
    mov     cx, 4000
.vsync_wait:
    in      al, dx
    test    al, 08h
    jnz     .vsync_done
    loop    .vsync_wait
.vsync_done:

    ; Blit completed composited frame from backbuffer_seg to CGA VRAM (0xB800)
    push    ds
    mov     ax, CGA_VRAM_SEG
    mov     es, ax
    mov     ax, [cs:backbuffer_seg]
    mov     ds, ax

    xor     si, si
    cld
    cmp     byte [cs:cfg_scaling], SCALE_WIDE
    je      .blit_wide

    xor     bx, bx              ; BX = scanline index (0..143) * 2
.blit_line_loop:
    mov     di, [cs:cga_scanline_offsets + bx]
    mov     cx, (GB_BYTES_PER_LINE / 2) ; 20 words = 40 bytes
    rep     movsw
    add     bx, 2
    cmp     bx, GB_SCREEN_HEIGHT * 2
    jb      .blit_line_loop
    jmp     short .blit_done

.blit_wide:
    xor     dx, dx              ; DX = scanline index (0..143) * 2
.blit_wide_line:
    mov     bx, dx
    mov     di, [cs:cga_scanline_offsets + bx]
    sub     di, GB_OFFSET_X_BYTES ; Full-width column 0
    mov     cx, 10              ; 10 * 4 = 40 src bytes -> 80 dst bytes (320 px)
.blit_wide_quad:
%rep 4
    lodsb
    mov     bl, al
    xor     bh, bh
    add     bx, bx
    mov     ax, [cs:cga_wide_table + bx]
    stosw
%endrep
    dec     cx
    jnz     .blit_wide_quad
    add     dx, 2
    cmp     dx, GB_SCREEN_HEIGHT * 2
    jb      .blit_wide_line

.blit_done:
    pop     ds

.render_done:
    pop     es
    pop     bp
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    popf
    ret

; ------------------------------------------------------------------------------
; update_cga_tile_cache: Decode any dirty tiles (0..383) from DS:8000h..97FFh
; into CS:cga_tile_cache (16 bytes per tile, 8 rows * 2 CGA bytes).
; Preserves DS; clobbers AX, BX, CX, DX, SI, DI, ES.
; ------------------------------------------------------------------------------
update_cga_tile_cache:
    mov     ax, cs
    mov     es, ax
    mov     di, tile_dirty
    mov     cx, 384
    cld
.scan_dirty:
    xor     al, al
    repe    scasb
    jz      .cache_done
    ; Found dirty tile at index = (DI - 1) - tile_dirty
    mov     bx, di
    dec     bx
    mov     byte [cs:bx], 0
    sub     bx, tile_dirty
    shl     bx, 4               ; BX = byte offset (0..6128)
    push    cx
    push    di

    lea     si, [bx + 08000h]   ; DS:SI = GB VRAM tile
    lea     di, [bx + cga_tile_cache] ; ES:DI = CS tile cache slot
    mov     cx, 8               ; 8 rows per tile
.row_loop:
    mov     al, [ds:si]
    mov     ah, [ds:si+1]
    add     si, 2

    mov     bl, al
    shr     bl, 4
    mov     bh, ah
    and     bh, 0F0h
    or      bl, bh
    xor     bh, bh
    mov     dl, [cs:dmg_cga_nibble_table + bx]

    mov     bl, al
    and     bl, 0Fh
    mov     bh, ah
    shl     bh, 4
    or      bl, bh
    xor     bh, bh
    mov     dh, [cs:dmg_cga_nibble_table + bx]

    mov     [es:di], dx
    add     di, 2
    loop    .row_loop

    pop     di
    pop     cx
    or      cx, cx
    jnz     .scan_dirty
.cache_done:
    ret

; ------------------------------------------------------------------------------
; render_aligned_strip: Copy 1..8 scanlines of CH tile columns directly from
; cga_tile_cache into backbuffer_seg (ES:DI).
; Inputs: DS = gb_mem_seg, ES = backbuffer_seg, SI = map_row_base,
;         BP = tile_cache_base (+ fine_y*2), CL = start_col, CH = tile_count,
;         [cs:render_run_lines] = 1..8, [cs:render_unsigned_tile] = 0/1
; Clobbers: AX, BX, CX, DX, DI
; ------------------------------------------------------------------------------
render_aligned_strip:
    xor     bh, bh
    mov     bl, [cs:render_run_lines]
    dec     bx
    shl     bx, 1
    cmp     byte [cs:render_unsigned_tile], 1
    je      .go_u
    mov     dx, [cs:fu_s_tab + bx]
.loop_s:
    xor     bh, bh
    mov     bl, cl
    inc     cl
    and     cl, 1Fh
    mov     al, [ds:si + bx]
    cbw
    shl     ax, 4
    add     ax, bp
    mov     bx, ax
    jmp     dx
.fu_s_8: mov ax, [cs:bx+14]
         mov [es:di+280], ax
.fu_s_7: mov ax, [cs:bx+12]
         mov [es:di+240], ax
.fu_s_6: mov ax, [cs:bx+10]
         mov [es:di+200], ax
.fu_s_5: mov ax, [cs:bx+8]
         mov [es:di+160], ax
.fu_s_4: mov ax, [cs:bx+6]
         mov [es:di+120], ax
.fu_s_3: mov ax, [cs:bx+4]
         mov [es:di+80], ax
.fu_s_2: mov ax, [cs:bx+2]
         mov [es:di+40], ax
.fu_s_1: mov ax, [cs:bx]
         mov [es:di], ax
    add     di, 2
    dec     ch
    jnz     .loop_s
    ret

.go_u:
    mov     dx, [cs:fu_u_tab + bx]
.loop_u:
    xor     bh, bh
    mov     bl, cl
    inc     cl
    and     cl, 1Fh
    mov     al, [ds:si + bx]
    xor     ah, ah
    shl     ax, 4
    add     ax, bp
    mov     bx, ax
    jmp     dx
.fu_u_8: mov ax, [cs:bx+14]
         mov [es:di+280], ax
.fu_u_7: mov ax, [cs:bx+12]
         mov [es:di+240], ax
.fu_u_6: mov ax, [cs:bx+10]
         mov [es:di+200], ax
.fu_u_5: mov ax, [cs:bx+8]
         mov [es:di+160], ax
.fu_u_4: mov ax, [cs:bx+6]
         mov [es:di+120], ax
.fu_u_3: mov ax, [cs:bx+4]
         mov [es:di+80], ax
.fu_u_2: mov ax, [cs:bx+2]
         mov [es:di+40], ax
.fu_u_1: mov ax, [cs:bx]
         mov [es:di], ax
    add     di, 2
    dec     ch
    jnz     .loop_u
    ret

; ------------------------------------------------------------------------------
; spr_draw_pixel: Write one opaque sprite pixel at (screen_x=DL, row_base=ES:BP)
; Inputs: BL = GB color (1..3), BH = 0, DL = screen_x (0..159), ES:BP = backbuffer line
; Preserves: AX, CX, DX, BP, DS, ES
; ------------------------------------------------------------------------------
spr_draw_pixel:
    push    ax
    mov     al, [cs:render_spr_pal_tab + bx] ; AL = 2-bit CGA shade (0..3)
    mov     bl, dl
    shr     bl, 2               ; byte offset 0..39
    mov     di, bp
    add     di, bx              ; ES:DI = target CGA byte

    mov     bl, dl
    and     bl, 03h             ; BX = screen_x & 3 (0..3)

    test    byte [cs:render_spr_attr], 80h
    jz      short .draw_now

    ; Respect OAM attribute bit 7 (OBJ-to-BG Priority: 1 = behind BG colors 1..3)
    push    cx
    mov     cl, [cs:spr_shift_tab + bx]
    mov     ah, [es:di]
    shr     ah, cl
    pop     cx
    and     ah, 03h
    cmp     ah, [cs:render_bg0_shade]
    jne     short .skip_draw

.draw_now:
    shl     al, 2
    or      bl, al              ; BX = (shade << 2) | (x & 3)
    mov     ah, [cs:spr_or_tab + bx]
    and     bl, 03h
    mov     al, [cs:spr_and_tab + bx]
    and     [es:di], al
    or      [es:di], ah
.skip_draw:
    pop     ax
    ret

fu_u_tab:
    dw render_aligned_strip.fu_u_1, render_aligned_strip.fu_u_2
    dw render_aligned_strip.fu_u_3, render_aligned_strip.fu_u_4
    dw render_aligned_strip.fu_u_5, render_aligned_strip.fu_u_6
    dw render_aligned_strip.fu_u_7, render_aligned_strip.fu_u_8

fu_s_tab:
    dw render_aligned_strip.fu_s_1, render_aligned_strip.fu_s_2
    dw render_aligned_strip.fu_s_3, render_aligned_strip.fu_s_4
    dw render_aligned_strip.fu_s_5, render_aligned_strip.fu_s_6
    dw render_aligned_strip.fu_s_7, render_aligned_strip.fu_s_8

sc_u_tab:
    dw cga_render_gb_frame.sc_u_1, cga_render_gb_frame.sc_u_2
    dw cga_render_gb_frame.sc_u_3, cga_render_gb_frame.sc_u_4
    dw cga_render_gb_frame.sc_u_5, cga_render_gb_frame.sc_u_6
    dw cga_render_gb_frame.sc_u_7, cga_render_gb_frame.sc_u_8

sc_s_tab:
    dw cga_render_gb_frame.sc_s_1, cga_render_gb_frame.sc_s_2
    dw cga_render_gb_frame.sc_s_3, cga_render_gb_frame.sc_s_4
    dw cga_render_gb_frame.sc_s_5, cga_render_gb_frame.sc_s_6
    dw cga_render_gb_frame.sc_s_7, cga_render_gb_frame.sc_s_8

spr_shift_tab:
    db 6, 4, 2, 0

spr_and_tab:
    db 03Fh, 0CFh, 0F3h, 0FCh

spr_or_tab:
    db 000h, 000h, 000h, 000h
    db 040h, 010h, 004h, 001h
    db 080h, 020h, 008h, 002h
    db 0C0h, 030h, 00Ch, 003h

    align 16
global tile_dirty
tile_dirty:
    times 384 db 1

    align 16
cga_tile_cache:
    times (384 * 16) db 0

backbuffer_scanline_offsets:
%assign y 0
%rep GB_SCREEN_HEIGHT
    dw (y * GB_BYTES_PER_LINE)
%assign y y+1
%endrep

; Rendering scratch variables in CS
render_map_base:        dw 09800h
render_unsigned_tile:   db 1
render_scy:             db 0
render_scx:             db 0
global hud_scy
hud_scy:                db 0
global hud_scx
hud_scx:                db 0
render_spr_h:           db 8
render_spr_y:           db 0
render_spr_x:           db 0
render_spr_tile:        db 0
render_spr_attr:        db 0
render_spr_pal_tab:     db 0, 0, 0, 0
render_win_scol:        db 0
global last_bgp
last_bgp:               db 0FFh
render_bg0_shade:       db 0
render_fine_x:          db 0
render_split_limit:     db 0
render_run_lines:       db 0
render_row_cnt:         db 0
render_y:               dw 0
render_dest_di:         dw 0
    align 2
cga_wide_table:
%assign _wb 0
%rep 256
    %assign _p0 ((_wb >> 6) & 3)
    %assign _p1 ((_wb >> 4) & 3)
    %assign _p2 ((_wb >> 2) & 3)
    %assign _p3 (_wb & 3)
    %assign _lo ((_p0 * 0x50) | (_p1 * 0x05))
    %assign _hi ((_p2 * 0x50) | (_p3 * 0x05))
    dw ((_hi << 8) | _lo)
    %assign _wb _wb+1
%endrep

cga_strip_buf:          times (8 * 44) db 0
