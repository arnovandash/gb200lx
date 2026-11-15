# ==============================================================================
# GB200LX - Game Boy Static Recompiler for 16-Bit MS-DOS / HP 200LX (80186)
# ==============================================================================
# Bring-Your-Own-ROM Build System
# Usage:
#   make ROM="path/to/your_game.gb" [EXE=GAME.EXE]
#   make run ROM="path/to/your_game.gb"
#   make test ROM="path/to/your_game.gb"
#   make setup
# ==============================================================================

PYTHON ?= python3
NASM   ?= nasm
DOSBOX ?= dosbox-x

ROM    ?=
EXE    ?= GAME.EXE

.PHONY: all build test run setup clean help

all: build

help:
	@echo "GB200LX - Static Game Boy Recompiler for HP 200LX"
	@echo "================================================="
	@echo "Usage:"
	@echo "  make ROM=\"path/to/rom.gb\" [EXE=GAME.EXE]  - Recompile ROM into standalone DOS .EXE"
	@echo "  make test [ROM=\"path/to/rom.gb\"]          - Run automated 60-frame headless test in DOSBox-X"
	@echo "  make run [ROM=\"path/to/rom.gb\"]           - Run compiled game interactively in DOSBox-X"
	@echo "  make setup                                - Run /SETUP interactive configuration wizard"
	@echo "  make clean                                - Clean build directory"

build:
	@if [ -n "$(ROM)" ]; then \
		$(PYTHON) tools/build_rom.py "$(ROM)" -o "$(EXE)"; \
	elif [ ! -f "build/$(EXE)" ]; then \
		$(PYTHON) tools/build_rom.py -o "$(EXE)"; \
	fi

test: build
	@echo "Running automated verification test in DOSBox-X..."
	@export DYLD_LIBRARY_PATH=/opt/homebrew/lib && \
	$(DOSBOX) -conf dosbox-x.conf -set cycles=max -c "mount c build" -c "c:" -c "$(EXE) /t" -c "exit" -silent
	@if [ -f build/CGA_VRAM.BIN ]; then \
		$(PYTHON) tools/cga_to_png.py build/CGA_VRAM.BIN build/screen.png; \
		echo "Test complete: CGA screen dumped to build/screen.png"; \
	fi

run: build
	@export DYLD_LIBRARY_PATH=/opt/homebrew/lib && \
	$(DOSBOX) -conf dosbox-x.conf -set cycles=max -c "mount c build" -c "c:" -c "$(EXE)"

setup: build
	@export DYLD_LIBRARY_PATH=/opt/homebrew/lib && \
	$(DOSBOX) -conf dosbox-x.conf -c "mount c build" -c "c:" -c "$(EXE) /SETUP"

clean:
	rm -rf build/
