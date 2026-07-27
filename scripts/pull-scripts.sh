#!/usr/bin/env bash
set -euo pipefail

# Downloads the pinned release binary of rancher/charts-build-scripts into
# bin/, verifying it against the release's checksums.txt. Skips the download
# if the correct version is already installed.
#
# Usage:
#   ./scripts/pull-scripts.sh
#   CHARTS_BUILD_SCRIPT_VERSION=v1.9.20 ./scripts/pull-scripts.sh   # pin a different version

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
BINARY="${BIN_DIR}/charts-build-scripts"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/version"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
asset="charts-build-scripts_${os}_${arch}"

if [[ -x "${BINARY}" ]]; then
    current_version="v$("${BINARY}" --version 2>/dev/null | awk '{print $3}')"
    if [[ "${current_version}" == "${CHARTS_BUILD_SCRIPT_VERSION}" ]]; then
        exit 0
    fi
fi

echo "Fetching charts-build-scripts ${CHARTS_BUILD_SCRIPT_VERSION} (${os}/${arch})..." >&2

release_url="${CHARTS_BUILD_SCRIPTS_REPO}/releases/download/${CHARTS_BUILD_SCRIPT_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

curl -sSfL "${release_url}/${asset}" -o "${tmp}/${asset}"
curl -sSfL "${release_url}/checksums.txt" -o "${tmp}/checksums.txt"

if command -v sha256sum >/dev/null 2>&1; then
    ( cd "${tmp}" && grep " ${asset}\$" checksums.txt | sha256sum -c - )
elif command -v shasum >/dev/null 2>&1; then
    ( cd "${tmp}" && grep " ${asset}\$" checksums.txt | shasum -a 256 -c - )
else
    echo "error: need either sha256sum or shasum to verify the download" >&2
    exit 1
fi

mkdir -p "${BIN_DIR}"
install -m 0755 "${tmp}/${asset}" "${BINARY}"
echo "Installed ${BINARY} (${CHARTS_BUILD_SCRIPT_VERSION})" >&2
