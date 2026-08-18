#!/bin/bash
#
# Checks what a release depends on and a successful build does not prove: both architectures present,
# a deployment target that still names the floor the app claims, an archive laid out the way a package
# manager expects, and a signature that survived the archive.
#
# Called by `make dist`. Kept out of the Makefile because these are assertions with messages, not
# build steps, and because it can then be run against any tarball by hand.
#
# Usage: ./verify-dist.sh /path/to/Notchling.app /path/to/tarball.tar.gz
set -euo pipefail

BUNDLE="${1:?bundle path required}"
TARBALL="${2:?tarball path required}"

fail() { printf 'verify-dist: %s\n' "$1" >&2; exit 1; }

[ -f "$TARBALL" ]          || fail "no tarball at $TARBALL"
[ -f "$TARBALL.sha256" ]   || fail "no checksum beside $TARBALL"

# A release carrying one architecture runs everywhere it is tested and nowhere else. Note the `case`
# rather than a pipe into `grep -q`: grep exits on the first match, and the SIGPIPE that sends
# upstream fails the whole pipeline under `set -o pipefail`.
for binary in Notchling notchling-hook; do
  archs=$(lipo -info "$BUNDLE/Contents/MacOS/$binary")
  case "$archs" in *arm64*)  ;; *) fail "$binary is missing arm64: $archs" ;; esac
  case "$archs" in *x86_64*) ;; *) fail "$binary is missing x86_64: $archs" ;; esac
done

# Deployment target, not SDK. Built on a machine newer than the floor the app claims, LC_BUILD_VERSION
# must still say 14.0, or Sonoma gets a binary that refuses to launch.
for arch in arm64 x86_64; do
  for binary in Notchling notchling-hook; do
    load_command=$(otool -arch "$arch" -l "$BUNDLE/Contents/MacOS/$binary" | grep -A3 LC_BUILD_VERSION)
    case "$load_command" in
      *"minos 14.0"*) ;;
      *) fail "$binary ($arch) does not declare minos 14.0" ;;
    esac
  done
done

# A formula installs the bundle by name, so that is what the archive has to hold at its top level.
# awk rather than `head`, for the SIGPIPE reason above.
top=$(tar -tzf "$TARBALL" | awk 'NR == 1')
[ "$top" = "Notchling.app/" ] || fail "archive starts with '$top', expected 'Notchling.app/'"

# An ad-hoc signature that does not survive the archive is the one failure this distribution route
# cannot absorb: macOS kills an arm64 binary whose signature is missing or broken.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
tar -xzf "$TARBALL" -C "$scratch"
codesign --verify --deep --strict "$scratch/Notchling.app" \
  || fail "the signature did not survive the archive"

( cd "$(dirname "$TARBALL")" && shasum -a 256 -c "$(basename "$TARBALL").sha256" >/dev/null ) \
  || fail "the checksum does not match the tarball"

printf 'verify-dist: %s is universal, targets macOS 14, and unpacks to a valid signature\n' "$TARBALL"
