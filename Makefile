APP_VERSION ?= 0.1.0
IDENTITY ?= -

export APP_VERSION IDENTITY

SYSINFO_BIN := build/helpers/notrecall-sysinfo

.DEFAULT_GOAL := help
.PHONY: help check build-sysinfo build-app package clean

help:
	@echo "NotRecall build targets:"
	@echo "  make check         Validate shell syntax, VDF manifests, and compat/run behavior"
	@echo "  make build-app     Build build/NotRecall.app (including notrecall-sysinfo)"
	@echo "  make package       Run checks and build build/NotRecall.app, .zip, and .dmg (+ .sha256)"
	@echo "  make clean         Remove build/ artifacts"

check:
	@sh tests/check.sh

$(SYSINFO_BIN): scripts/notrecall_sysinfo.m
	@mkdir -p build/helpers
	@echo "==> Compiling notrecall-sysinfo -> $@"
	@/usr/bin/clang -arch arm64 -mmacosx-version-min=14.0 -fobjc-arc -O2 \
		scripts/notrecall_sysinfo.m \
		-framework Foundation -framework CoreGraphics -framework CoreAudio \
		-framework IOKit -framework Metal \
		-o $@
	@/usr/bin/strip -S -x $@ 2>/dev/null || true
	@chmod 755 $@

build-sysinfo: $(SYSINFO_BIN)

build-app: $(SYSINFO_BIN)
	@sh scripts/package.sh --app-only

package: check $(SYSINFO_BIN)
	@sh scripts/package.sh --strict

clean:
	@rm -rf build/
