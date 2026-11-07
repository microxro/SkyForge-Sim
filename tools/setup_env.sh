#!/bin/sh
# SKYFORGE: ensure a Swift >= 6.2 toolchain is available on Linux sandboxes.
# Usage: . tools/setup_env.sh   (sourcing keeps the PATH change) or sh tools/setup_env.sh
SWIFT_VER="${SKYFORGE_SWIFT_VERSION:-6.3.3}"
PREFIX="${SKYFORGE_TOOLCHAIN_DIR:-$HOME/.skyforge-toolchain}"

swift_ok() {
  v=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -n 1)
  [ -n "$v" ] || return 1
  set -- $v
  [ "$1" -gt 6 ] || { [ "$1" -eq 6 ] && [ "$2" -ge 2 ]; }
}

[ -d "$PREFIX/usr/bin" ] && PATH="$PREFIX/usr/bin:$PATH" && export PATH
if swift_ok; then swift --version 2>/dev/null | head -n 1; return 0 2>/dev/null || exit 0; fi

[ "$(uname -s)" = "Linux" ] || { echo "setup_env: non-Linux host without Swift >= 6.2; install Xcode 26.6+"; return 1 2>/dev/null || exit 1; }
. /etc/os-release
arch=$(uname -m)
case "$ID$VERSION_ID" in
  ubuntu24.04) plat=ubuntu2404; label=ubuntu24.04 ;;
  ubuntu22.04) plat=ubuntu2204; label=ubuntu22.04 ;;
  *) echo "setup_env: unsupported distro $ID $VERSION_ID"; return 1 2>/dev/null || exit 1 ;;
esac
[ "$arch" = "aarch64" ] && { plat="${plat}-aarch64"; label="${label}-aarch64"; }
url="https://download.swift.org/swift-${SWIFT_VER}-release/${plat}/swift-${SWIFT_VER}-RELEASE/swift-${SWIFT_VER}-RELEASE-${label}.tar.gz"
echo "setup_env: downloading $url"
tmp=$(mktemp -d)
if ! curl -fsSL "$url" -o "$tmp/swift.tgz"; then
  echo "setup_env: download failed. Swift unavailable: author-only mode. Allow download.swift.org, swift.org, github.com."
  return 1 2>/dev/null || exit 1
fi
if command -v apt-get >/dev/null 2>&1 && [ "$(id -u)" = "0" ]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq binutils git gnupg2 libc6-dev libcurl4-openssl-dev \
    libedit2 libgcc-13-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev \
    libz3-dev pkg-config tzdata unzip zlib1g-dev >/dev/null 2>&1 || echo "setup_env: apt deps partially failed (continuing)"
fi
mkdir -p "$PREFIX"
tar -xzf "$tmp/swift.tgz" -C "$PREFIX" --strip-components=1
rm -rf "$tmp"
PATH="$PREFIX/usr/bin:$PATH"; export PATH
swift_ok && { swift --version 2>/dev/null | head -n 1; return 0 2>/dev/null || exit 0; }
echo "setup_env: installed toolchain does not report Swift >= 6.2"; return 1 2>/dev/null || exit 1
