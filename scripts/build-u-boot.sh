#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${UBOOT_PACKAGE} ]]; then
    echo "Error: UBOOT_PACKAGE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source ../packages/"${UBOOT_PACKAGE}"/debian/upstream

if [ ! -d "${UBOOT_PACKAGE}" ]; then
    git clone --single-branch --progress -b "${BRANCH}" "${GIT}" "${UBOOT_PACKAGE}"
fi

# Always reset to a clean checkout of the pinned commit and resync the
# debian packaging from packages/${UBOOT_PACKAGE}. Without this, a cached
# checkout from a previous (possibly failed, possibly patched-and-never-
# unpatched) build would keep being reused as-is, silently ignoring any
# changes made to the packaging (patches, rules, targets.mk, ...) since.
git -C "${UBOOT_PACKAGE}" checkout -f "${COMMIT}"
git -C "${UBOOT_PACKAGE}" clean -fdx
rm -rf "${UBOOT_PACKAGE}/debian"
cp -r ../packages/"${UBOOT_PACKAGE}"/debian "${UBOOT_PACKAGE}"

cd "${UBOOT_PACKAGE}"

# Target package to build
rules=${UBOOT_RULES_TARGET},package-${UBOOT_RULES_TARGET}
if [[ -n ${UBOOT_RULES_TARGET_EXTRA} ]]; then
    rules=${UBOOT_RULES_TARGET_EXTRA},${rules}
fi

# Compile u-boot into a deb package
dpkg-source --before-build .
dpkg-buildpackage -a "$(cat debian/arch)" -d -b -nc -uc --rules-target="${rules}"
dpkg-source --after-build .

rm -f ../*.buildinfo ../*.changes
