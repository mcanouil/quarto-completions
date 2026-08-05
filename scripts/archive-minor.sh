#!/usr/bin/env bash
#
# Regenerates a Quarto minor's completions from that line's newest shipped
# patch.
#
#     scripts/archive-minor.sh <major.minor> [--out <dir>]
#
# For the lines no longer being generated from an installed binary. The
# release and pre-release minors are written by their own channel's run, with
# generate.ts --mirror; this covers the one line below release, which the
# Generate workflow refreshes weekly so a late patch such as 1.9.38 still
# reaches the site, and the one-off backfill of older minors.
# Idempotent: run again on a line with no new patch, it regenerates the same
# bytes, which the Generate workflow's git-status gate then sees as no change.
#
# The generator itself runs on the current Quarto, exactly as the dev channel
# already does in the Generate workflow: only the binary being introspected
# is old, so an old embedded Deno never has to run this repository's
# TypeScript.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="quarto-dev/quarto-cli"
OUT="docs/completions"

usage() {
  cat <<'EOF'
Usage: scripts/archive-minor.sh <major.minor> [--out <dir>]

Resolves the newest non-prerelease patch of the given Quarto minor,
downloads and verifies its Linux tarball, and regenerates that channel's
completions from it, using the Quarto already on PATH to run the generator.

Only the linux-amd64 tarball is fetched, so this needs a Linux x86_64
host, or a container of one on any other machine (e.g. `docker run
--platform linux/amd64 ...`).

Requires: gh (authenticated), curl, sha256sum or shasum, tar, quarto.
EOF
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

MINOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out)
      [ $# -ge 2 ] || fail "--out needs a value"
      OUT="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      [ -z "${MINOR}" ] || fail "unexpected argument '$1' (try --help)"
      MINOR="$1"
      shift
      ;;
  esac
done

[[ "${MINOR}" =~ ^[0-9]+\.[0-9]+$ ]] || fail "expected a Quarto minor such as '1.9', got '${MINOR:-none}' (try --help)"

# Only a linux-amd64 tarball is ever fetched below. Checked before anything
# is downloaded, or a mismatch here surfaces as the extracted binary failing
# to exec near the end of the run, which says nothing about the real cause.
[ "$(uname -s)" = "Linux" ] || fail "needs a Linux host (got '$(uname -s)'); run this inside a linux/amd64 container instead"
case "$(uname -m)" in
  x86_64 | amd64) ;;
  *) fail "needs an x86_64 host (got '$(uname -m)'); run this inside a linux/amd64 container instead" ;;
esac

command -v gh >/dev/null 2>&1 || fail "gh is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v quarto >/dev/null 2>&1 || fail "quarto is required to run the generator"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    fail "neither sha256sum nor shasum is available"
  fi
}

# The newest tag on the <minor> line that is not marked prerelease. Quarto
# marks in-development patches of even a released line as prereleases (e.g.
# v1.10.17 is a prerelease, v1.10.18 is not), so this is what picks a line's
# actual shipped patch rather than one still being tested.
echo "Resolving the newest ${MINOR}.x release..."
TAG="$(
  gh api "repos/${REPO}/releases" --paginate --jq \
    ".[] | select(.prerelease == false) | select(.tag_name | test(\"^v${MINOR}\\\\.\")) | .tag_name" |
    sort -V | tail -n 1
)"
[ -n "${TAG}" ] || fail "no shipped release found on the ${MINOR} line"
VERSION="${TAG#v}"
echo "Archiving Quarto ${VERSION} (${TAG})."

TEMPORARY="$(mktemp -d)"
cleanup() { rm -rf "${TEMPORARY}"; }
trap cleanup EXIT

BASE="https://github.com/${REPO}/releases/download/${TAG}"
TARBALL="quarto-${VERSION}-linux-amd64.tar.gz"
CHECKSUMS="quarto-${VERSION}-checksums.txt"

curl -fsSL "${BASE}/${CHECKSUMS}" -o "${TEMPORARY}/${CHECKSUMS}" ||
  fail "could not fetch ${CHECKSUMS}; refusing to install an unverified binary"
curl -fsSL "${BASE}/${TARBALL}" -o "${TEMPORARY}/${TARBALL}"

EXPECTED="$(grep -F "${TARBALL}" "${TEMPORARY}/${CHECKSUMS}" | cut -d' ' -f1 | head -n 1)"
[ -n "${EXPECTED}" ] || fail "no checksum for ${TARBALL} in ${CHECKSUMS}"
ACTUAL="$(sha256_of "${TEMPORARY}/${TARBALL}")"
[ "${EXPECTED}" = "${ACTUAL}" ] || fail "checksum mismatch for ${TARBALL}: expected ${EXPECTED}, got ${ACTUAL}"

mkdir -p "${TEMPORARY}/extracted"
tar -xzf "${TEMPORARY}/${TARBALL}" -C "${TEMPORARY}/extracted"

# The tarball's top-level directory name is not depended on: only that it
# contains a 'bin/quarto' somewhere, which is what every release layout has
# actually shipped.
QUARTO_BIN="$(find "${TEMPORARY}/extracted" -type f -path '*/bin/quarto' -print -quit)"
[ -n "${QUARTO_BIN}" ] || fail "no bin/quarto found inside ${TARBALL}"
chmod +x "${QUARTO_BIN}"

echo "Generating completions for channel '${MINOR}'..."
(cd "${ROOT}" && quarto run src/generate.ts --channel "${MINOR}" --quarto "${QUARTO_BIN}" --out "${OUT}")
