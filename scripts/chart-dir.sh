#!/usr/bin/env bash
set -euo pipefail

# Prints the chart directory for a package, e.g. "packages/loki/charts" or
# "packages/network-policies/local-chart" -- sourced from that package's own
# package.yaml `workingDir` field, never assumed to be "charts".
#
# Every forked package (has a `url:`) omits workingDir and defaults to
# "charts", which charts-build-scripts pulls from upstream. A from-scratch
# package (no upstream `url:`, e.g. network-policies) sets workingDir
# explicitly to something else -- by convention "local-chart" -- since the
# repo's root .gitignore has a blanket `/packages/**/charts/` rule (correct
# for every forked package, where charts/ is regenerated build output) that
# would otherwise swallow a from-scratch chart's actual source with nothing
# to regenerate it from.
#
# Usage: ./scripts/chart-dir.sh <package-name>

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
name="${1:?usage: $(basename "$0") <package-name>}"
pkg_yaml="${REPO_ROOT}/packages/${name}/package.yaml"

test -f "${pkg_yaml}" || { echo "error: ${pkg_yaml} not found" >&2; exit 1; }

working_dir="$(awk -F': *' '/^workingDir:[[:space:]]*/ {print $2; exit}' "${pkg_yaml}")"
working_dir="${working_dir:-charts}"

echo "packages/${name}/${working_dir}"
