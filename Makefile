SHELL := /bin/bash
BINARY := bin/charts-build-scripts

# charts-build-scripts requires GNU diff; macOS ships BSD diff, which it
# rejects (https://github.com/rancher/charts-build-scripts/issues/130).
# Scope Homebrew's diffutils onto PATH for our own recipes only, without
# touching the default `diff` used anywhere else on this machine.
ifeq ($(shell uname -s),Darwin)
DIFFUTILS_PREFIX := $(shell brew --prefix diffutils 2>/dev/null)
ifneq ($(DIFFUTILS_PREFIX),)
export PATH := $(DIFFUTILS_PREFIX)/bin:$(PATH)
endif
endif

# Required by every Build Pipeline target, e.g.:
#   make prepare PACKAGE=my-chart
PACKAGE ?=

.DEFAULT_GOAL := help

##@ Build Pipeline

prepare: guard-package pull-scripts ## Pull the upstream chart(s) into packages/<name>/charts and apply existing patches
	@$(BINARY) $@ --package="$(PACKAGE)"

patch: guard-package pull-scripts ## Diff local edits against upstream and (re)generate the patch files
	@$(BINARY) $@ --package="$(PACKAGE)"

charts: guard-package pull-scripts ## Archive the finalized chart(s) into assets/ and charts/, updating index.yaml
	@$(BINARY) $@ --package="$(PACKAGE)"

clean: guard-package pull-scripts ## Remove local working state so the repo is ready for a PR
	@$(BINARY) $@ --package="$(PACKAGE)"

##@ Tooling

pull-scripts: ## Download the pinned charts-build-scripts release into bin/ (skips if already current)
	@./scripts/pull-scripts.sh

guard-package:
	@test -n "$(PACKAGE)" || { echo "error: PACKAGE is required, e.g. make $(MAKECMDGOALS) PACKAGE=my-chart" >&2; exit 1; }

##@ Help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9][a-zA-Z0-9 _-]*:.*?##/ { split($$1, targets, " "); for (i in targets) { printf "  \033[36m%-15s\033[0m %s\n", targets[i], $$2 } } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: prepare patch charts clean pull-scripts guard-package help
