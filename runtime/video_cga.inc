; ==============================================================================
; video_cga.inc - CGA Mode 04h Constants and Definitions for HP 200LX
; 320x200 4-shade Grayscale (4 Colors, 2 bits-per-pixel)
; ==============================================================================

CGA_VRAM_SEG        equ 0B800h      ; Video RAM segment for CGA mode 04h
CGA_ODD_OFFSET      equ 2000h       ; Offset to odd scanline bank in CGA VRAM
CGA_STATUS_REG      equ 03DAh       ; CGA CRT status register (bit 3 = VRetrace)

CGA_SCREEN_WIDTH    equ 320         ; Screen width in pixels
CGA_SCREEN_HEIGHT   equ 200         ; Screen height in scanlines
CGA_BYTES_PER_LINE  equ 80          ; 320 pixels / 4 pixels per byte = 80 bytes

; Game Boy Display Dimensions
GB_SCREEN_WIDTH     equ 160         ; Game Boy LCD width in pixels
GB_SCREEN_HEIGHT    equ 144         ; Game Boy LCD height in scanlines
GB_BYTES_PER_LINE   equ 40          ; 160 pixels / 4 pixels per byte = 40 bytes

; Centering offsets on 320x200 CGA screen
; X: (320 - 160) / 2 = 80 pixels -> 20 bytes from left margin (x = 80..239)
; Y: (200 - 144) / 2 = 28 scanlines margin top & bottom (y = 28..171)
GB_OFFSET_X_PIXELS  equ 80
GB_OFFSET_X_BYTES   equ 20          ; 80 / 4 = 20 bytes
GB_OFFSET_Y_LINES   equ 28          ; lines 28 through 171

; Starting CGA VRAM offsets for GB viewport (top scanline y = 28, even line 14)
; Even bank: 14 * 80 + 20 = 1140 = 0474h
; Odd bank:  2000h + 14 * 80 + 20 = 2474h
CGA_GB_EVEN_START   equ ( (GB_OFFSET_Y_LINES / 2) * CGA_BYTES_PER_LINE + GB_OFFSET_X_BYTES )
CGA_GB_ODD_START    equ ( CGA_ODD_OFFSET + (GB_OFFSET_Y_LINES / 2) * CGA_BYTES_PER_LINE + GB_OFFSET_X_BYTES )

; 4-shade 2bpp pixel bit patterns:
; Pixel format: 2 bits per pixel, big-endian pixel order (pix0: bits 7-6, pix1: bits 5-4, ...)
COLOR_00_WHITE      equ 00000000b   ; Shade 0: White (LCD lightest)
COLOR_01_LT_GRAY    equ 01010101b   ; Shade 1: Light Gray (55h)
COLOR_02_DK_GRAY    equ 10101010b   ; Shade 2: Dark Gray  (AAh)
COLOR_03_BLACK      equ 11111111b   ; Shade 3: Black      (FFh, LCD darkest)
