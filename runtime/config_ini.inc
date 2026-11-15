; ==============================================================================
; config_ini.inc - Configuration Definitions & Key Scancodes for HP 200LX
; ==============================================================================

; Scaling Modes
SCALE_CENTER            equ 0       ; 160x144 centered with border (recommended)
SCALE_WIDE              equ 1       ; 320x144 2x horizontal stretch (fills 640px screen)

; Palette Modes
PAL_POCKET              equ 0       ; Clean Pocket Grayscale: 00h, 55h, AAh, FFh
PAL_DMG                 equ 1       ; Classic DMG Pea-Soup/Green Tint
PAL_HIGH_CON            equ 2       ; High Contrast Black & White
PAL_DARK                equ 3       ; Inverted Dark Mode

; Scancodes for Special Keys
SCAN_ESC                equ 01h
SCAN_ENTER              equ 1Ch
SCAN_SPACE              equ 39h
SCAN_TAB                equ 0Fh
SCAN_BACKSPACE          equ 0Eh

SCAN_UP                 equ 48h
SCAN_DOWN               equ 50h
SCAN_LEFT               equ 4Bh
SCAN_RIGHT              equ 4Dh

SCAN_Z                  equ 2Ch
SCAN_X                  equ 2Dh
SCAN_C                  equ 2Eh
SCAN_A                  equ 1Eh
SCAN_S                  equ 1Fh
SCAN_D                  equ 20h
SCAN_W                  equ 11h
SCAN_J                  equ 24h
SCAN_K                  equ 25h
SCAN_L                  equ 26h

; Structure offsets in cfg_data
CFG_SCALING             equ 0       ; byte
CFG_PALETTE             equ 1       ; byte
CFG_BORDER              equ 2       ; byte
CFG_VSYNC               equ 3       ; byte
CFG_FRAMESKIP           equ 4       ; byte
CFG_SOUND               equ 5       ; byte

CFG_KEY_UP              equ 6       ; byte (scancode)
CFG_KEY_DOWN            equ 7       ; byte
CFG_KEY_LEFT            equ 8       ; byte
CFG_KEY_RIGHT           equ 9       ; byte
CFG_KEY_A               equ 10      ; byte
CFG_KEY_B               equ 11      ; byte
CFG_KEY_SELECT          equ 12      ; byte
CFG_KEY_START           equ 13      ; byte
CFG_KEY_MENU            equ 14      ; byte

CFG_SHADE0              equ 15      ; byte (CGA 2bpp bit pattern)
CFG_SHADE1              equ 16      ; byte
CFG_SHADE2              equ 17      ; byte
CFG_SHADE3              equ 18      ; byte

CFG_DATA_SIZE           equ 20
