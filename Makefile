ODIN ?= odin
GLSLC ?= glslc
VERSION ?= $(shell cat VERSION)
SOURCES := $(wildcard *.odin updater_security/*.odin)
.PHONY: all run check clean appimage FORCE
all: build/terminal

shaders/%.spv: shaders/%
	$(GLSLC) $< -o $@

build/version: FORCE
	@mkdir -p build
	@if [ "$$(cat $@ 2>/dev/null)" != "$(VERSION)" ]; then printf '%s\n' "$(VERSION)" > $@; fi

FORCE:

build/terminal: build/version VERSION Makefile scripts/update-install.sh $(SOURCES) shaders/ui.vert.spv shaders/ui.frag.spv $(wildcard assets/*.ttf) assets/update-public-key.hex
	mkdir -p build
	$(ODIN) build . -out:$@.next -o:speed -vet -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536 -define:TERMINAL_PLUS_VERSION=$(VERSION)
	mv -f $@.next $@

run: all
	./build/terminal

check: all
	./build/terminal --self-check

appimage: all
	sh scripts/build-appimage.sh --version $(VERSION)

clean:
	rm -rf build
	rm -f shaders/*.spv
