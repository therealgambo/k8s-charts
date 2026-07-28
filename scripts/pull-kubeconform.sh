#!/usr/bin/env bash
set -euo pipefail

# Downloads the pinned release binary of yannh/kubeconform into bin/,
# verifying it against the release's CHECKSUMS file. Skips the download if
# the correct version is already installed.
#
# Usage:
#   ./scripts/pull-kubeconform.sh
#   KUBECONFORM_VERSION=v0.8.0 ./scripts/pull-kubeconform.sh   # pin a different version

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
BINARY="${BIN_DIR}/kubeconform"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/version"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
asset="kubeconform-${os}-${arch}.tar.gz"

if [[ -x "${BINARY}" ]]; then
    current_version="$("${BINARY}" -v 2>/dev/null)"
    if [[ "${current_version}" == "${KUBECONFORM_VERSION}" ]]; then
        exit 0
    fi
fi

echo "Fetching kubeconform ${KUBECONFORM_VERSION} (${os}/${arch})..." >&2

release_url="${KUBECONFORM_REPO}/releases/download/${KUBECONFORM_VERSION}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

curl -sSfL "${release_url}/${asset}" -o "${tmp}/${asset}"
curl -sSfL "${release_url}/CHECKSUMS" -o "${tmp}/CHECKSUMS"

if command -v sha256sum >/dev/null 2>&1; then
    ( cd "${tmp}" && grep " ${asset}\$" CHECKSUMS | sha256sum -c - )
elif command -v shasum >/dev/null 2>&1; then
    ( cd "${tmp}" && grep " ${asset}\$" CHECKSUMS | shasum -a 256 -c - )
else
    echo "error: need either sha256sum or shasum to verify the download" >&2
    exit 1
fi

mkdir -p "${BIN_DIR}"
tar -xzf "${tmp}/${asset}" -C "${tmp}" kubeconform
install -m 0755 "${tmp}/kubeconform" "${BINARY}"
echo "Installed ${BINARY} (${KUBECONFORM_VERSION})" >&2
