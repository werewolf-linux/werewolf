# Included by the root Makefile so ordinary FORM=example-go/rust builds,
# including make check, contain the application too. Each architecture has
# its own overlay; binaries are never written into the source forms.
EXAMPLE_LANGUAGE := $(patsubst example-%,%,$(filter example-go example-rust,$(FORM)))
RUSTC ?= rustup run stable rustc
ifneq ($(EXAMPLE_LANGUAGE),)
EXAMPLE_OVERLAY := $(OUT)/application
EXAMPLE_BINARY := $(EXAMPLE_OVERLAY)/usr/lib/app/server
OVERLAY_DIRS += $(EXAMPLE_OVERLAY)
$(OUT)/meta.stamp $(OUT)/overlay.tar: $(EXAMPLE_BINARY)

ifeq ($(EXAMPLE_LANGUAGE),go)
$(EXAMPLE_BINARY): examples/go/main.go examples/build.mk
	mkdir -p $(dir $@)
	CGO_ENABLED=0 GOOS=linux GOARCH=$(if $(filter aarch64,$(ARCH)),arm64,amd64) \
		go build -trimpath -buildvcs=false -ldflags='-s -w' -o $@ $<
else
$(EXAMPLE_BINARY): examples/rust/main.rs examples/build.mk
	mkdir -p $(dir $@)
	$(RUSTC) --edition=2021 --target $(ARCH)-unknown-linux-musl \
		-C linker=rust-lld -C target-feature=+crt-static -C opt-level=2 \
		-C strip=symbols -o $@ $<
endif
endif
