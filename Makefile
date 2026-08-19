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
BASE_REF ?= origin/main
EXTRA_VALUES ?=

.DEFAULT_GOAL := help

##@ Build Pipeline

prepare: guard-package pull-scripts ## Pull the upstream chart(s) into packages/<name>/charts and apply existing patches
	@$(BINARY) $@ --package="$(PACKAGE)"

# values files are layered in this order (later overrides earlier),
# each skipped if it doesn't exist in the prepared chart:
#   1. values.yaml        - the chart's own defaults (implicit, always applied by helm)
#   2. base.values.yaml   - local changes to values.yaml made here, values.yaml shouldn't be modified!
#   3. ci.values.yaml     - whatever's needed for `helm template` to succeed in CI (dummy secrets,
#                           required-value stand-ins, ...) -- never real config, see docs/values-layering.md
#   4. $(ENV).values.yaml - environment-specific overrides (test/staging/production)
# EXTRA_VALUES, if set, is layered last -- the authoritative way for a caller that needs one more
# -f on top of the stack above (e.g. a candidate values change under test, or a values file scoped
# to a specific consumer of this chart's render) to get it, instead of reimplementing this layering
# by hand. This is the one entry point every renderer of a chart in this repo should go through --
# see scripts/kyverno-policy-check.sh and .claude/skills/kyverno-policy-fix/verify.sh.
#
# Named and namespaced as $(PACKAGE) rather than helm's "release-name"/"default" fallbacks, so a
# package's rendered output is always the same, predictable identity instead of depending on
# whether the caller happened to pass one -- scripts/kyverno-policy-check.sh in particular relies
# on the namespace for this to write namespace-scoped kyverno.io/v2 PolicyException match blocks
# against a target package's rendered resources.
template: guard-package ## Render a package's chart dir with values.yaml -> base.values.yaml -> ci.values.yaml -> [ENV].values.yaml -> [EXTRA_VALUES] layered, as release/namespace $(PACKAGE) (run 'make prepare' first; make template PACKAGE=name [ENV=staging] [EXTRA_VALUES=path])
	@chart="$$(./scripts/chart-dir.sh $(PACKAGE))"; \
	test -d "$$chart" || { echo "error: $$chart not found — run 'make prepare PACKAGE=$(PACKAGE)' first" >&2; exit 1; }; \
	values=(); \
	[[ -f "$$chart/values.yaml" ]] && values+=(-f "$$chart/values.yaml"); \
	[[ -f "$$chart/base.values.yaml" ]] && values+=(-f "$$chart/base.values.yaml"); \
	[[ -f "$$chart/ci.values.yaml" ]] && values+=(-f "$$chart/ci.values.yaml"); \
	[[ -f "$$chart/$(ENV).values.yaml" ]] && values+=(-f "$$chart/$(ENV).values.yaml"); \
	[[ -n "$(EXTRA_VALUES)" ]] && values+=(-f "$(EXTRA_VALUES)"); \
	helm template $(PACKAGE) "$$chart" "$${values[@]}" --namespace $(PACKAGE)

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
		extra=(); \
		[[ -f "$$chart/kyverno-test/values.yaml" ]] && extra=(EXTRA_VALUES="$$chart/kyverno-test/values.yaml"); \
		$(MAKE) --no-print-directory template PACKAGE=$(PACKAGE) ENV=$(ENV) "$${extra[@]}" > "$$chart/kyverno-test/policies.rendered.yaml"; \
		bin/kyverno test "$$chart/kyverno-test"; \
	else \
		echo "no kyverno-test/ dir in $$chart, skipping"; \
	fi

# kyverno-test (above) proves a policies chart's OWN CEL rule logic is correct against curated
# fixtures. This runs the opposite direction: renders PACKAGE's chart and asserts the result
# against the (already-proven) kyverno-pod-policies + kyverno-cluster-policies rulesets layered
# together, to catch real violations in any chart before it merges. See
# scripts/kyverno-policy-check.sh for the Enforce(fails)/Audit(warns) split -- no allow-list, every
# package is held to the same bar.
kyverno-policy-check: guard-package ## Assert a package's rendered chart against the kyverno-pod-policies + kyverno-cluster-policies rulesets (requires the kyverno CLI; make kyverno-policy-check PACKAGE=name [ENV=staging])
	@chart="$$(./scripts/chart-dir.sh $(PACKAGE))"; \
	test -d "$$chart" || { echo "error: $$chart not found — run 'make prepare PACKAGE=$(PACKAGE)' first" >&2; exit 1; }; \
	./scripts/kyverno-policy-check.sh $(PACKAGE) $(ENV)

# Renders PACKAGE's chart and confirms every image it references is actually pullable -- catches
# an upstream release whose chart tag exists but whose images haven't been published (or never
# will be), which every other check here is blind to since the rendered YAML is well-formed
# either way. See scripts/check-image-availability.sh for the full reasoning.
check-images: guard-package ## Confirm every image PACKAGE's rendered chart references actually exists (requires the crane CLI; make check-images PACKAGE=name [ENV=staging])
	@./scripts/check-image-availability.sh $(PACKAGE) $(ENV)

# Verifies PACKAGE's packageVersion field was moved correctly relative to BASE_REF, per the
# convention in packages/README.md: reset to 01 when the upstream url/commit changed, otherwise
# strictly bumped whenever anything else under packages/PACKAGE/ changed -- including a
# from-scratch `url: local` package's local-chart/, which has no upstream to reset against but is
# still held to the same "every change gets its own version" bar. So two different patch sets
# never publish under the same chart version. With BASE_REF's default of origin/main, this
# compares against the working tree -- including uncommitted changes -- so it's usable before a
# commit even exists.
check-package-version: guard-package ## Verify PACKAGE's packageVersion was bumped/reset correctly relative to BASE_REF (default origin/main); make check-package-version PACKAGE=name [BASE_REF=origin/main]
	@./scripts/check-package-version-bump.sh "$(BASE_REF)" $(PACKAGE)

##@ Tooling

pull-scripts: ## Download the pinned charts-build-scripts release into bin/ (skips if already current)
	@./scripts/pull-scripts.sh

guard-package:
	@test -n "$(PACKAGE)" || { echo "error: PACKAGE is required, e.g. make $(MAKECMDGOALS) PACKAGE=my-chart" >&2; exit 1; }

##@ Help

help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9][a-zA-Z0-9 _-]*:.*?##/ { split($$1, targets, " "); for (i in targets) { printf "  \033[36m%-15s\033[0m %s\n", targets[i], $$2 } } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: prepare template patch charts clean unittest kyverno-test kyverno-policy-check check-images check-package-version pull-scripts guard-package help
