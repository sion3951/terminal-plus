ODIN ?= odin
GLSLC ?= glslc
VERSION ?= $(shell cat VERSION)
UNAME_S := $(shell uname -s)
SOURCES := $(wildcard src/*.odin src/updater_security/*.odin)
ODIN_FLAGS := -o:speed -vet -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536 -define:TERMINAL_PLUS_VERSION=$(VERSION)
ifeq ($(UNAME_S),Darwin)
# macOS renders through Metal; only Linux builds compile the Vulkan shaders.
# Homebrew's keg-only SQLite precedes the SDK copy for FTS5 trigram support.
BREW_PREFIX ?= $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
MACOS_MINIMUM ?= 15.0
SHADERS :=
ODIN_FLAGS += -target:darwin_arm64 -minimum-os-version:$(MACOS_MINIMUM) \
	-extra-linker-flags:"-L$(BREW_PREFIX)/opt/sqlite/lib -L$(BREW_PREFIX)/lib -Wl,-headerpad_max_install_names"
else
SHADERS := src/shaders/ui.vert.spv src/shaders/ui.frag.spv
endif
.PHONY: all run check clean appimage macos-app dmg FORCE
all: build/terminal

src/shaders/%.spv: src/shaders/%
	$(GLSLC) $< -o $@

build/version: FORCE
	@mkdir -p build
	@if [ "$$(cat $@ 2>/dev/null)" != "$(VERSION)" ]; then printf '%s\n' "$(VERSION)" > $@; fi

FORCE:

build/terminal: build/version VERSION Makefile scripts/update-install.sh $(SOURCES) $(SHADERS) $(wildcard assets/*.ttf) assets/update-public-key.hex
	mkdir -p build
	$(ODIN) build src -out:$@.next $(ODIN_FLAGS)
	mv -f $@.next $@

run: all
	./build/terminal

check: all
	./build/terminal --self-check

appimage: all
	sh scripts/build-appimage.sh --version $(VERSION)

macos-app: all
	MACOS_MINIMUM=$(MACOS_MINIMUM) sh scripts/build-macos-app.sh --version $(VERSION)

dmg: all
	MACOS_MINIMUM=$(MACOS_MINIMUM) sh scripts/build-macos-app.sh --version $(VERSION) --dmg

clean:
	rm -rf build
	rm -f src/shaders/*.spv
