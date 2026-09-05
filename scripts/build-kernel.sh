#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

# Clone the kernel repo
if [ ! -d linux-rockchip ]; then
    git clone --progress -b "${KERNEL_BRANCH}" "${KERNEL_REPO}" linux-rockchip --depth=2
fi

cd linux-rockchip

# Always reset to a clean checkout of the branch tip and discard any state
# left behind by a previous (possibly failed, possibly patched) build, so
# board-specific patches below always apply against a pristine tree.
git fetch --depth=2 origin "${KERNEL_BRANCH}"
git checkout -f FETCH_HEAD
git clean -fdx

# Apply any board-specific kernel patches (e.g. device trees not yet part
# of this branch). These are purely additive per-board changes, so it is
# safe to skip this entirely when BOARD is unset (kernel-only builds).
if [[ -n ${BOARD} ]] && [[ -f ../../packages/linux-rockchip/patches/${BOARD}/series ]]; then
    while IFS= read -r patch_name; do
        [[ -z ${patch_name} ]] && continue
        echo "Applying kernel patch: ${patch_name}"
        patch -p1 < "../../packages/linux-rockchip/patches/${BOARD}/${patch_name}"
    done < "../../packages/linux-rockchip/patches/${BOARD}/series"
fi

# shellcheck disable=SC2046
export $(dpkg-architecture -aarm64)
export CROSS_COMPILE=aarch64-linux-gnu-
export CC=aarch64-linux-gnu-gcc
export LANG=C

# Compile the kernel into a deb package
fakeroot debian/rules clean binary-headers binary-rockchip do_mainline_build=true

# build.sh's caching check only looks for *any* linux-image-*.deb in build/,
# regardless of which suite/board it was actually built for. Record what
# this one was built for so that check can tell a stale kernel from a
# previous suite/board apart from a genuinely reusable one, instead of
# silently reusing (e.g.) an oracular-suite kernel forever after switching
# to noble.
echo "${SUITE}:${BOARD}" > ../.kernel-build-marker
