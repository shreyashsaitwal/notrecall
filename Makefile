APP_VERSION ?= 1.0.0
IDENTITY ?= -
JOBS ?= 4
RECALL_DIR ?=
GPTK_DIR ?=

export APP_VERSION IDENTITY JOBS RECALL_DIR GPTK_DIR

SYSINFO_BIN := build/helpers/notrecall-sysinfo
RUNTIME_ARCHIVE := build/runtime/runtime.tar.gz

.DEFAULT_GOAL := help
.PHONY: help check build-sysinfo build-runtime build-app package clean

help:
	@echo "NotRecall build targets:"
	@echo "  make check          Validate shell syntax, VDF manifests, and compat/run behavior"
	@echo "  make build-runtime  Bootstrap Recall (if needed) and bundle Wine + DXMT runtime + helpers"
	@echo "  make build-app      Build self-contained build/NotRecall.app (with bundled runtime + helpers)"
	@echo "  make package        Run checks and build build/NotRecall.app, .zip, and .dmg (+ .sha256)"
	@echo "  make clean          Remove build/ artifacts"
	@echo ""
	@echo "Optional variables: RECALL_DIR=<path> GPTK_DIR=<path> JOBS=4 APP_VERSION=1.0.0 IDENTITY=-"

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

build-runtime:
	@python3 scripts/bundle_runtime.py \
		--out build \
		--identity "$(IDENTITY)" \
		--jobs "$(JOBS)" \
		$(if $(RECALL_DIR),--recall-dir "$(RECALL_DIR)") \
		$(if $(GPTK_DIR),--gptk-dir "$(GPTK_DIR)")

build-app: $(SYSINFO_BIN) build-runtime
	@sh scripts/package.sh --app-only

package: check $(SYSINFO_BIN) build-runtime
	@sh scripts/package.sh --strict

clean:
	@rm -rf build/
