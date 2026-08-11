#!/usr/bin/env bash
set -euo pipefail

# Renders <package>'s chart and confirms every container image it references actually exists in
# its registry.
#
# This exists because helm lint/kubeconform/helm-unittest all pass on a chart whose upstream cut
# a release tag without actually publishing that release's images -- the rendered YAML is
# perfectly well-formed, it just points at a tag that 404s. Confirmed directly against
# packages/onlineboutique: GoogleCloudPlatform/microservices-demo's v0.10.6 git tag and OCI chart
# both exist, but every one of that release's container images 404s on
# us-central1-docker.pkg.dev/google-samples/microservices-demo; v0.10.5's images are all published.
#
# Images are found by recursively grepping every "image:" key out of the rendered YAML (via
# yq -> jq), not by hardcoding each workload kind's shape -- this catches
# containers/initContainers at any nesting depth (including CronJob's
# jobTemplate.spec.template.spec.containers) for free. The `select(type == "string")` guard on
# that extraction matters: a CRD (e.g. keda's ScaledJob, which embeds a full PodTemplateSpec-
# shaped OpenAPI schema for Kubernetes' native OCI-volume feature) can have an "image" *property*
# whose value is itself an object describing that field's schema, not an image reference --
# without the guard, `jq -r` pretty-prints that nested object across several lines, and each line
# of it gets mistaken for a separate image.
#
# Each image is checked with `crane manifest` (no docker daemon needed, works against any
# anonymously-reachable OCI registry). A registry response of "doesn't exist" (MANIFEST_UNKNOWN /
# NAME_UNKNOWN) or "can't confirm without credentials" (UNAUTHORIZED / DENIED) both fail the
# check: if a chart's *default* values reference an image that can't be pulled anonymously, a
# plain `kubectl apply` with no imagePullSecrets configured would fail to pull it too, which is
# just as real a bug as the image not existing at all. The one response treated as transient
# rather than a verdict is TOOMANYREQUESTS (registries -- Docker Hub especially -- rate-limit
# anonymous pulls, and GitHub Actions' shared runner IPs are a well-known target for that): retried
# a couple of times with backoff before giving up and failing loud, same as everything else. A
# run that fails purely on rate-limiting rather than a real missing image is a known possible
# flake -- re-run the job.
#
# Usage: ./scripts/check-image-availability.sh <package> [env]
#
# Requires: yq, jq (both preinstalled on GitHub-hosted runners), the crane CLI
# (./scripts/pull-crane.sh), and <package>'s chart already prepared (`make prepare
# PACKAGE=<package>`).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

CRANE="${REPO_ROOT}/bin/crane"

command -v yq >/dev/null 2>&1 || { echo "error: yq not found on PATH" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found on PATH" >&2; exit 1; }
[[ -x "${CRANE}" ]] || { echo "error: ${CRANE} not found -- run './scripts/pull-crane.sh' first" >&2; exit 1; }

name="${1:?usage: $(basename "$0") <package> [env]}"
env="${2:-staging}"

target_chart="$(./scripts/chart-dir.sh "${name}")"
test -d "${target_chart}" || { echo "error: ${target_chart} not found -- run 'make prepare PACKAGE=${name}' first" >&2; exit 1; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# A file redirect, not a pipe into this script -- so a `make template` failure (e.g. a chart using
# `required` on a value with no default, like karpenter's settings.clusterName -- see the
# kubeconform job's own note on this known gap) aborts right here via `set -e`, instead of this
# script quietly seeing empty/truncated input and reporting "nothing to check" as if the chart
# were simply image-free.
make --no-print-directory template PACKAGE="${name}" ENV="${env}" > "${tmpdir}/rendered.yaml"

# eval-all + wrapping every doc in a `[.]` array first is what makes this survive a multi-document
# (`---`-separated) stream -- a plain `yq -o=json eval` would only emit the last document's JSON.
# Built with a read loop rather than `mapfile` -- macOS's system bash is 3.2, which lacks it.
images=()
while IFS= read -r image; do
    images+=("${image}")
done < <(
    yq -o=json eval-all '[.]' "${tmpdir}/rendered.yaml" \
        | jq -r '.. | .image? | select(type == "string")' \
        | sort -u
)

if [[ "${#images[@]}" -eq 0 ]]; then
    echo "no container images referenced, nothing to check"
    exit 0
fi

echo "Checking ${#images[@]} referenced image(s)..."
echo

max_attempts=3
failed=0

# Not run under `set -e` for this loop's body: a `crane manifest` failure is an expected,
# individually-handled outcome (that's the whole point of this script), not a script bug -- every
# image gets checked and reported even after an earlier one fails, so a PR sees every broken
# reference in one run instead of fixing them one CI run at a time.
set +e
for image in "${images[@]}"; do
    attempt=1
    while :; do
        error="$("${CRANE}" manifest "${image}" 2>&1 1>/dev/null)"
        status=$?

        if [[ "${status}" -eq 0 ]]; then
            echo "  ok    ${image}"
            break
        fi

        if [[ "${error}" == *TOOMANYREQUESTS* && "${attempt}" -lt "${max_attempts}" ]]; then
            backoff=$(( attempt * 5 ))
            echo "  retry ${image} (rate-limited, attempt ${attempt}/${max_attempts}, waiting ${backoff}s)"
            sleep "${backoff}"
            attempt=$(( attempt + 1 ))
            continue
        fi

        echo "  FAIL  ${image}"
        while IFS= read -r line; do
            echo "        ${line}"
        done <<<"${error}"
        failed=1
        break
    done
done
set -e

echo

if [[ "${failed}" -eq 1 ]]; then
    echo "error: one or more referenced images are not pullable -- see FAIL lines above" >&2
    exit 1
fi

echo "All referenced images exist."
