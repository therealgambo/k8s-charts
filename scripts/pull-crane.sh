#!/usr/bin/env bash
set -euo pipefail

# Downloads the pinned release binary of google/go-containerregistry's `crane` into bin/,
# verifying it against the release's checksums.txt. Skips the download if the correct version is
# already installed.
#
# Usage:
#   ./scripts/pull-crane.sh
#   CRANE_VERSION=v0.21.9 ./scripts/pull-crane.sh   # pin a different version

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
BINARY="${BIN_DIR}/crane"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/version"

# go-containerregistry's release assets label the OS capitalized ("Linux"/"Darwin", which is
# already what uname -s returns -- no translating needed) and the Intel arch "x86_64" (also
# already what uname -m returns); only aarch64 (Linux's uname) needs translating to "arm64".
os="$(uname -s)"
arch="$(uname -m | sed 's/aarch64/arm64/')"
asset="go-containerregistry_${os}_${arch}.tar.gz"

if [[ -x "${BINARY}" ]]; then
    current_version="v$("${BINARY}" version 2>/dev/null)"
    if [[ "${current_version}" == "${CRANE_VERSION}" ]]; then
        exit 0
    fi
fi

echo "Fetching crane ${CRANE_VERSION} (${os}/${arch})..." >&2

release_url="${CRANE_REPO}/releases/download/${CRANE_VERSION}"
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
tar -xzf "${tmp}/${asset}" -C "${tmp}" crane
install -m 0755 "${tmp}/crane" "${BINARY}"
echo "Installed ${BINARY} (${CRANE_VERSION})" >&2
