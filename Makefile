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
ENV ?= staging

.DEFAULT_GOAL := help

##@ Build Pipeline

prepare: guard-package pull-scripts ## Pull the upstream chart(s) into packages/<name>/charts and apply existing patches
	@$(BINARY) $@ --package="$(PACKAGE)"

# values files are layered in this order (later overrides earlier),
# each skipped if it doesn't exist in the prepared chart:
#   1. values.yaml        - the chart's own defaults (implicit, always applied by helm)
#   2. base.values.yaml   - local changes to values.yaml made here, values.yaml shouldn't be modified!
#   3. $(ENV).values.yaml - environment-specific overrides (test/staging/production)
template: guard-package ## Render a package's chart dir with values.yaml -> base.values.yaml -> [ENV].values.yaml layered (run 'make prepare' first; make template PACKAGE=name [ENV=staging])
	@chart="$$(./scripts/chart-dir.sh $(PACKAGE))"; \
	test -d "$$chart" || { echo "error: $$chart not found — run 'make prepare PACKAGE=$(PACKAGE)' first" >&2; exit 1; }; \
	values=(); \
	[[ -f "$$chart/values.yaml" ]] && values+=(-f "$$chart/values.yaml"); \
	[[ -f "$$chart/base.values.yaml" ]] && values+=(-f "$$chart/base.values.yaml"); \
	[[ -f "$$chart/ci.values.yaml" ]] && values+=(-f "$$chart/ci.values.yaml"); \
	[[ -f "$$chart/$(ENV).values.yaml" ]] && values+=(-f "$$chart/$(ENV).values.yaml"); \
	helm template "$$chart" "$${values[@]}"

patch: guard-package pull-scripts ## Diff local edits against upstream and (re)generate the patch files
	@$(BINARY) $@ --package="$(PACKAGE)"

charts: guard-package pull-scripts ## Archive the finalized chart(s) into assets/ and charts/, updating index.yaml
	@$(BINARY) $@ --package="$(PACKAGE)"

clean: guard-package pull-scripts ## Remove local working state so the repo is ready for a PR
	@$(BINARY) $@ --package="$(PACKAGE)"

##@ Testing

unittest: guard-package ## Run helm-unittest against a package's chart dir (requires the helm-unittest plugin; no-op if the chart has no tests/ dir)
	@chart="$$(./scripts/chart-dir.sh $(PACKAGE))"; \
	test -d "$$chart" || { echo "error: $$chart not found — run 'make prepare PACKAGE=$(PACKAGE)' first" >&2; exit 1; }; \
	if [[ -d "$$chart/tests" ]]; then \
		helm unittest "$$chart"; \
	else \
		echo "no tests/ dir in $$chart, skipping"; \
	fi

# helm-unittest (above) only checks the templating layer -- that a flag turns a resource on/off,
# that a value lands in the right field. It has no idea what a Kyverno CEL expression actually
# does. kyverno-test renders the chart and feeds the result to the `kyverno test` CLI against
# resource fixtures with known-good/known-bad results declared in kyverno-test.yaml, which
# actually evaluates each rule's CEL/logic -- see https://kyverno.io/docs/guides/testing-policies/
kyverno-test: guard-package ## Run `kyverno test` against a package's kyverno-test/ dir (renders the chart into it first; requires the kyverno CLI; no-op if the chart has no kyverno-test/ dir)
	@chart="$$(./scripts/chart-dir.sh $(PACKAGE))"; \
	test -d "$$chart" || { echo "error: $$chart not found — run 'make prepare PACKAGE=$(PACKAGE)' first" >&2; exit 1; }; \
	if [[ -d "$$chart/kyverno-test" ]]; then \
		$(MAKE) --no-print-directory template PACKAGE=$(PACKAGE) ENV=$(ENV) > "$$chart/kyverno-test/policies.rendered.yaml"; \
		bin/kyverno test "$$chart/kyverno-test"; \
	else \
		echo "no kyverno-test/ dir in $$chart, skipping"; \
	fi

##@ Tooling

pull-scripts: ## Download the pinned charts-build-scripts release into bin/ (skips if already current)
	@./scripts/pull-scripts.sh

guard-package:
	@test -n "$(PACKAGE)" || { echo "error: PACKAGE is required, e.g. make $(MAKECMDGOALS) PACKAGE=my-chart" >&2; exit 1; }

##@ Help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9][a-zA-Z0-9 _-]*:.*?##/ { split($$1, targets, " "); for (i in targets) { printf "  \033[36m%-15s\033[0m %s\n", targets[i], $$2 } } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: prepare template patch charts clean unittest kyverno-test pull-scripts guard-package help
