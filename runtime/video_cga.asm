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

    ; Optional: select CGA palette 0 (0=Black/Green/Red/Brown) or palette 1 (Black/Cyan/Magenta/White)
    ; On the HP 200LX LCD, colors 0-3 map directly to 4 physical gray levels.
    mov     ah, 0Bh
    mov     bh, 01h     ; Subfunction 1: select palette
    mov     bl, 00h     ; Palette 0
    int     10h

    ; Initialize precomputed scanline offset lookup table
    call    cga_blit_scanline_table_init

    ; Clear the entire 320x200 frame buffer
    call    cga_clear_screen

    pop     bp
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
; cga_clear_screen: Clears both even and odd CGA VRAM fields to 0 (White/Blank)
; Input:  None
; Output: None
; Clobbers: AX, CX, ES, DI
; ------------------------------------------------------------------------------
cga_clear_screen:
    push    bp
    mov     bp, sp

    mov     ax, CGA_VRAM_SEG
    mov     es, ax

    ; Clear even scanline field (lines 0, 2, ..., 198: 100 lines * 80 bytes = 8000 bytes = 4000 words)
    xor     di, di
    xor     ax, ax
    mov     cx, 4000
    cld
    rep     stosw

    ; Clear odd scanline field (lines 1, 3, ..., 199: starts at 2000h)
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
    cmp     byte [cfg_border], 0
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

    ; Top border line: Screen line 27 (odd line, k=13)
    ; k = 13: 13 * 80 = 1040. 2000h + 1040 + 20 = 2430h
    mov     di, CGA_ODD_OFFSET + (13 * CGA_BYTES_PER_LINE) + GB_OFFSET_X_BYTES
    mov     al, [cfg_shade3]
    mov     cx, GB_BYTES_PER_LINE
    cld
    rep     stosb

    ; Bottom border line: Screen line 172 (even line, k=86)
    ; k = 86: 86 * 80 = 6880 = 1AE0h. 1AE0h + 20 = 1AF4h
    mov     di, (86 * CGA_BYTES_PER_LINE) + GB_OFFSET_X_BYTES
    mov     al, [cfg_shade3]
    mov     cx, GB_BYTES_PER_LINE
    rep     stosb

    ; Left and right vertical borders: lines 28 through 171
    xor     cx, cx                  ; y = 0..143
.vert_loop:
    mov     bx, cx
    shl     bx, 1
    mov     di, [cga_scanline_offsets + bx]
    ; Left pixel of viewport: write left edge byte
    ; In CGA 2bpp, pixel 0 is bits 7-6. Set bits 7-6 to black (11000000b) or full border byte
    mov     byte [es:di - 1], 00000011b   ; Pixel right next to viewport
    mov     byte [es:di + GB_BYTES_PER_LINE], 11000000b ; Pixel right after viewport
    inc     cx
    cmp     cx, GB_SCREEN_HEIGHT
    jb      .vert_loop

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
; AL = new BGP palette register value
; ------------------------------------------------------------------------------
global helper_update_bgp
helper_update_bgp:
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
    ret

; ------------------------------------------------------------------------------
; cga_render_gb_frame: Render Game Boy VRAM (0x8000..0x9FFF) to CGA Mode 04h VRAM
; Uses LCDC (0xFF40), SCY (0xFF42), SCX (0xFF43), and precomputed nibble table.
; ------------------------------------------------------------------------------
global cga_render_gb_frame
cga_render_gb_frame:
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

    ; Setup ES = CGA VRAM segment
    mov     bx, CGA_VRAM_SEG
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

    ; Read SCY and SCX
    mov     al, [ds:0FF42h]
    mov     [cs:render_scy], al
    mov     al, [ds:0FF43h]
    mov     [cs:render_scx], al

    ; Render 144 scanlines (Y = 0..143)
    xor     cx, cx              ; CX = screen line Y (0..143)
.line_loop:
    push    cx

    ; Calculate VRAM destination pointer for line Y
    mov     bx, cx
    shl     bx, 1
    mov     di, [cs:cga_scanline_offsets + bx] ; ES:DI = CGA scanline destination

    ; bg_y = (Y + SCY) & 0xFF
    mov     al, cl
    add     al, [cs:render_scy] ; AL = bg_y

    ; tile_row = bg_y >> 3 (0..31)
    ; fine_y = (bg_y & 7) * 2
    mov     ah, al
    and     ah, 07h
    shl     ah, 1               ; AH = fine_y * 2
    mov     [cs:render_fine_y], ah

    shr     al, 3               ; AL = tile_row (0..31)
    xor     ah, ah
    shl     ax, 5               ; AX = tile_row * 32 (offset within 32x32 map)
    add     ax, [cs:render_map_base]
    mov     [cs:render_row_base], ax ; map row base pointer

    ; Render 20 horizontal tiles across this scanline
    xor     bp, bp              ; BP = tile column index (0..19)
.tile_loop:
    ; bg_x = (BP * 8 + SCX) & 0xFF
    mov     ax, bp
    shl     ax, 3               ; AX = BP * 8
    add     al, [cs:render_scx] ; AL = bg_x
    shr     al, 3               ; AL = tile_col (0..31)
    xor     ah, ah

    ; Read tile index from map: [render_row_base + tile_col]
    mov     si, [cs:render_row_base]
    add     si, ax
    mov     al, [ds:si]         ; AL = tile index (0..255)

    ; Calculate tile data address: tile_idx * 16 + fine_y
    cmp     byte [cs:render_unsigned_tile], 1
    je      .unsigned_tile

.signed_tile:
    cbw                         ; Sign-extend AL to AX (-128..127)
    shl     ax, 4               ; * 16
    add     ax, 09000h          ; Signed base = 0x9000
    jmp     short .tile_addr_done

.unsigned_tile:
    xor     ah, ah
    shl     ax, 4               ; * 16
    add     ax, 08000h          ; Unsigned base = 0x8000

.tile_addr_done:
    xor     bx, bx
    mov     bl, [cs:render_fine_y]
    mov     si, ax
    add     si, bx              ; SI = tile line address in GB RAM!

    ; Read 2 bytes of planar tile data
    mov     al, [ds:si]         ; Low bit plane (B0)
    mov     ah, [ds:si+1]       ; High bit plane (B1)

    ; Convert 8 pixels to 2 bytes of CGA via dmg_cga_nibble_table
    ; Left 4 pixels: (high nibble of B1 << 4) | (high nibble of B0)
    mov     bl, al
    shr     bl, 4               ; low plane high nibble
    mov     bh, ah
    and     bh, 0F0h            ; high plane high nibble
    or      bl, bh
    xor     bh, bh
    mov     dl, [cs:dmg_cga_nibble_table + bx]

    ; Right 4 pixels: (low nibble of B1 << 4) | (low nibble of B0)
    mov     bl, al
    and     bl, 0Fh             ; low plane low nibble
    mov     bh, ah
    shl     bh, 4               ; high plane low nibble
    or      bl, bh
    xor     bh, bh
    mov     dh, [cs:dmg_cga_nibble_table + bx]

    ; Write 2 bytes (1 word) to CGA VRAM
    mov     [es:di], dx
    add     di, 2

    inc     bp
    cmp     bp, 20
    jb      .tile_loop

    pop     cx
    inc     cx
    cmp     cx, GB_SCREEN_HEIGHT
    jb      .line_loop

.render_done:
    pop     es
    pop     bp
    pop     di
    pop     si
    pop     dx
    pop     cx
    pop     bx
    pop     ax
    ret

; Rendering scratch variables in CS
render_map_base:        dw 09800h
render_row_base:        dw 0
render_fine_y:          db 0
render_unsigned_tile:   db 1
render_scy:             db 0
render_scx:             db 0
