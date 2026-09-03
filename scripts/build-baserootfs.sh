#!/bin/bash

set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")/.."

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "config/suites/${SUITE}.sh"

ROOTFS_BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${SUITE}/release/"
ROOTFS_BASE_NAME=$(curl -fsSL "${ROOTFS_BASE_URL}" | grep -oP 'ubuntu-base-[\d.]+-base-arm64\.tar\.gz' | sort -V | tail -n1)

if [ -z "${ROOTFS_BASE_NAME}" ]; then
    echo "Error: could not find an ubuntu-base tarball for suite \"${SUITE}\""
    exit 1
fi

mkdir -p build && cd build

if [ ! -e "${ROOTFS_BASE_NAME}" ]; then
    echo "Downloading ${ROOTFS_BASE_NAME}..."
    curl -fSL "${ROOTFS_BASE_URL}${ROOTFS_BASE_NAME}" -o "${ROOTFS_BASE_NAME}"
fi

OUTPUT_NAME="ubuntu-${RELASE_VERSION}-preinstalled-base-arm64.rootfs.tar.xz"

if [ -e "${OUTPUT_NAME}" ]; then
    echo "${OUTPUT_NAME} already exists, skipping conversion"
    exit 0
fi

echo "Converting ${ROOTFS_BASE_NAME} to ${OUTPUT_NAME}"
echo "(recompressing gzip -> xz; this produces no output for a few minutes, that's normal)"
gzip -dc "${ROOTFS_BASE_NAME}" | xz -T0 -c > "${OUTPUT_NAME}.tmp"
mv "${OUTPUT_NAME}.tmp" "${OUTPUT_NAME}"
echo "Done: ${OUTPUT_NAME}"

exit 0
