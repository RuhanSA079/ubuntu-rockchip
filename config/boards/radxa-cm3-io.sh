# shellcheck shell=bash

export BOARD_NAME="Radxa CM3 IO"
export BOARD_MAKER="Radxa"
export BOARD_SOC="Rockchip RK3566"
export BOARD_CPU="ARM Cortex A55"
export UBOOT_PACKAGE="u-boot-turing-rk3588"
export UBOOT_RULES_TARGET="radxa-cm3-io-rk3566"
export COMPATIBLE_SUITES=("noble")
export COMPATIBLE_FLAVORS=("server" "desktop" "base")

function config_image_hook__radxa-cm3-io() {
    local rootfs="$1"
    local overlay="$2"
    local suite="$3"

    mkdir -p "${rootfs}/etc/default"
    if [ -f "${rootfs}/etc/default/u-boot" ]; then
        sed -i '/^U_BOOT_PARAMETERS=/d' "${rootfs}/etc/default/u-boot"
    fi
    echo 'U_BOOT_PARAMETERS="earlycon=uart8250,mmio32,0xfe660000 console=ttyS2,115200 net.ifnames=0"' >> "${rootfs}/etc/default/u-boot"

    return 0
}
