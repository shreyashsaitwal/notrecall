RUNTIME ?=
HELPERS ?=
RECALL_DIR ?= recall
APP_VERSION ?= 0.1.0

.PHONY: check build-runtime build-helpers build-app package install dry-run uninstall

check:
	@sh tests/check.sh

build-runtime:
	@RECALL_DIR="$(RECALL_DIR)" sh scripts/build_runtime.sh

build-helpers:
	@RECALL_DIR="$(RECALL_DIR)" sh scripts/build_helpers.sh

build-app: build-helpers
	@APP_VERSION="$(APP_VERSION)" sh scripts/package.sh --app-only

package: check build-helpers
	@APP_VERSION="$(APP_VERSION)" sh scripts/package.sh

install: check
	@sh scripts/install.sh $(if $(RUNTIME),--runtime "$(RUNTIME)") $(if $(HELPERS),--helpers "$(HELPERS)")

dry-run: check
	@sh scripts/install.sh --dry-run $(if $(RUNTIME),--runtime "$(RUNTIME)") $(if $(HELPERS),--helpers "$(HELPERS)")

uninstall:
	@sh scripts/uninstall.sh
