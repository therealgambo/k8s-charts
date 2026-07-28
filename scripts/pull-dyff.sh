#!/usr/bin/env bash
set -euo pipefail

# Downloads the pinned release binary of homeport/dyff into bin/, verifying
# it against the release's checksums.txt. Skips the download if the correct
# version is already installed.
#
# Usage:
#   ./scripts/pull-dyff.sh
#   DYFF_VERSION=v1.12.0 ./scripts/pull-dyff.sh   # pin a different version

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
BINARY="${BIN_DIR}/dyff"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/version"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')"
asset="dyff_${DYFF_VERSION#v}_${os}_${arch}.tar.gz"

if [[ -x "${BINARY}" ]]; then
    current_version="v$("${BINARY}" version 2>/dev/null | awk '{print $3}')"
    if [[ "${current_version}" == "${DYFF_VERSION}" ]]; then
        exit 0
    fi
fi

echo "Fetching dyff ${DYFF_VERSION} (${os}/${arch})..." >&2

release_url="${DYFF_REPO}/releases/download/${DYFF_VERSION}"
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
tar -xzf "${tmp}/${asset}" -C "${tmp}" dyff
install -m 0755 "${tmp}/dyff" "${BINARY}"
echo "Installed ${BINARY} (${DYFF_VERSION})" >&2
