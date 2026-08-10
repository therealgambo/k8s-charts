#!/usr/bin/env bash
set -euo pipefail

# Downloads the pinned release binary of the kyverno CLI into bin/, verifying
# it against the release's checksums.txt. Skips the download if the correct
# version is already installed.
#
# Usage:
#   ./scripts/pull-kyverno.sh
#   KYVERNO_CLI_VERSION=v1.18.2 ./scripts/pull-kyverno.sh   # pin a different version

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${REPO_ROOT}/bin"
BINARY="${BIN_DIR}/kyverno"

# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/version"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
# kyverno's release assets label the Intel arch "x86_64" (not "amd64" like kubeconform/helm), and
# ARM as "arm64" -- only aarch64 (Linux's uname) needs translating.
arch="$(uname -m | sed 's/aarch64/arm64/')"
asset="kyverno-cli_${KYVERNO_CLI_VERSION}_${os}_${arch}.tar.gz"

if [[ -x "${BINARY}" ]]; then
    current_version="v$("${BINARY}" version 2>/dev/null | awk '/^Version:/ {print $2}')"
    if [[ "${current_version}" == "${KYVERNO_CLI_VERSION}" ]]; then
        exit 0
    fi
fi

echo "Fetching kyverno CLI ${KYVERNO_CLI_VERSION} (${os}/${arch})..." >&2

release_url="${KYVERNO_CLI_REPO}/releases/download/${KYVERNO_CLI_VERSION}"
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
tar -xzf "${tmp}/${asset}" -C "${tmp}" kyverno
install -m 0755 "${tmp}/kyverno" "${BINARY}"
echo "Installed ${BINARY} (${KYVERNO_CLI_VERSION})" >&2
