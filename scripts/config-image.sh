#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/boards/${BOARD}.sh"

if [[ -z ${SUITE} ]]; then
    echo "Error: SUITE is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/suites/${SUITE}.sh"

if [[ -z ${FLAVOR} ]]; then
    echo "Error: FLAVOR is not set"
    exit 1
fi

# shellcheck source=/dev/null
source "../config/flavors/${FLAVOR}.sh"

if [[ ${LAUNCHPAD} != "Y" ]]; then
    uboot_package="$(basename "$(find u-boot-"${BOARD}"_*.deb | sort | tail -n1)")"
    if [ ! -e "$uboot_package" ]; then
        echo 'Error: could not find the u-boot package'
        exit 1
    fi

    linux_image_package="$(basename "$(find linux-image-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_image_package" ]; then
        echo "Error: could not find the linux image package"
        exit 1
    fi

    linux_headers_package="$(basename "$(find linux-headers-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_headers_package" ]; then
        echo "Error: could not find the linux headers package"
        exit 1
    fi

    linux_modules_package="$(basename "$(find linux-modules-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_modules_package" ]; then
        echo "Error: could not find the linux modules package"
        exit 1
    fi

    linux_buildinfo_package="$(basename "$(find linux-buildinfo-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_buildinfo_package" ]; then
        echo "Error: could not find the linux buildinfo package"
        exit 1
    fi

    linux_rockchip_headers_package="$(basename "$(find linux-rockchip-headers-*.deb | sort | tail -n1)")"
    if [ ! -e "$linux_rockchip_headers_package" ]; then
        echo "Error: could not find the linux rockchip headers package"
        exit 1
    fi
fi

setup_mountpoint() {
    local mountpoint="$1"

    if [ ! -c /dev/mem ]; then
        mknod -m 660 /dev/mem c 1 1
        chown root:kmem /dev/mem
    fi

    mount dev-live -t devtmpfs "$mountpoint/dev"
    mount devpts-live -t devpts -o nodev,nosuid "$mountpoint/dev/pts"
    mount proc-live -t proc "$mountpoint/proc"
    mount sysfs-live -t sysfs "$mountpoint/sys"
    mount securityfs -t securityfs "$mountpoint/sys/kernel/security"
    # Provide more up to date apparmor features, matching target kernel
    # cgroup2 mount for LP: 1944004
    mount -t cgroup2 none "$mountpoint/sys/fs/cgroup"
    mount -t tmpfs none "$mountpoint/tmp"
    mount -t tmpfs none "$mountpoint/var/lib/apt/lists"
    mount -t tmpfs none "$mountpoint/var/cache/apt"
    # The rootfs tarball may ship with no /etc/resolv.conf at all (e.g. if
    # it was stripped from the image after being used for its own chroot
    # package installs), so only back it up if it's actually there.
    rm -f resolv.conf.tmp
    if [ -e "$mountpoint/etc/resolv.conf" ] || [ -L "$mountpoint/etc/resolv.conf" ]; then
        mv "$mountpoint/etc/resolv.conf" resolv.conf.tmp
    fi
    # Prefer the host's real resolv.conf, but fall back to whatever we can
    # find if it's missing or a dangling symlink (e.g. systemd-resolved's
    # stub not currently up), so a temporary host DNS hiccup doesn't block
    # the whole build over a file only needed for the chroot's own apt calls.
    if [ -e /etc/resolv.conf ]; then
        cp /etc/resolv.conf "$mountpoint/etc/resolv.conf"
    elif [ -e /run/systemd/resolve/resolv.conf ]; then
        cp /run/systemd/resolve/resolv.conf "$mountpoint/etc/resolv.conf"
    else
        echo "Warning: no usable host /etc/resolv.conf found, falling back to public DNS" >&2
        printf 'nameserver %s\n' 1.1.1.1 8.8.8.8 > "$mountpoint/etc/resolv.conf"
    fi
    rm -f nsswitch.conf.tmp
    if [ -e "$mountpoint/etc/nsswitch.conf" ]; then
        mv "$mountpoint/etc/nsswitch.conf" nsswitch.conf.tmp
        sed 's/systemd//g' nsswitch.conf.tmp > "$mountpoint/etc/nsswitch.conf"
    fi
}

teardown_mountpoint() {
    # Reverse the operations from setup_mountpoint
    local mountpoint
    mountpoint=$(realpath "$1")

    # ensure we have exactly one trailing slash, and escape all slashes for awk
    mountpoint_match=$(echo "$mountpoint" | sed -e's,/$,,; s,/,\\/,g;')'\/'
    # sort -r ensures that deeper mountpoints are unmounted first
    awk </proc/self/mounts "\$2 ~ /$mountpoint_match/ { print \$2 }" | LC_ALL=C sort -r | while IFS= read -r submount; do
        mount --make-private "$submount"
        umount "$submount"
    done
    # Restore whatever was (or wasn't) there before setup_mountpoint ran.
    if [ -e resolv.conf.tmp ] || [ -L resolv.conf.tmp ]; then
        mv resolv.conf.tmp "$mountpoint/etc/resolv.conf"
    else
        rm -f "$mountpoint/etc/resolv.conf"
    fi
    if [ -e nsswitch.conf.tmp ]; then
        mv nsswitch.conf.tmp "$mountpoint/etc/nsswitch.conf"
    fi
}

# Prevent dpkg interactive dialogues
export DEBIAN_FRONTEND=noninteractive

# DEBIAN_FRONTEND alone only silences debconf questions; it does not stop
# dpkg's own conffile-merge prompt, e.g. when a board hook has already
# written a file (like /etc/default/u-boot) before the package that owns
# it gets installed. Force dpkg to always keep whatever's already on disk
# rather than risk the build hanging on an interactive terminal prompt.
apt_opts=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Override localisation settings to address a perl warning
export LC_ALL=C

# Debootstrap options
chroot_dir=rootfs
overlay_dir=../overlay

# Extract the compressed root filesystem
if [ -d ${chroot_dir} ]; then
    # A previous run may have aborted before teardown_mountpoint ran, leaving
    # dev/proc/sys/tmp/var/... (at any nesting depth, e.g. var/lib/apt/lists,
    # sys/kernel/security) still mounted here. `rm -rf` can never delete
    # files inside a mounted filesystem ("Device or resource busy" /
    # "Operation not permitted"), so unmount everything under this directory
    # first, reusing teardown_mountpoint's own mount-table walk rather than
    # guessing at nesting depth here.
    teardown_mountpoint ${chroot_dir}
fi
rm -rf ${chroot_dir} && mkdir -p ${chroot_dir}
tar -xpJf "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64.rootfs.tar.xz" -C ${chroot_dir}

# Mount the root filesystem
echo "==> Entering chroot at build/${chroot_dir} (this stays running until the end of this script)"
setup_mountpoint $chroot_dir

# Update packages
echo "==> [chroot] Updating package lists"
chroot $chroot_dir apt-get update
echo "==> [chroot] Upgrading installed packages"
chroot $chroot_dir apt-get -y "${apt_opts[@]}" upgrade

# Run config hook to handle board specific changes
if [[ $(type -t config_image_hook__"${BOARD}") == function ]]; then
    echo "==> [chroot] Running board-specific setup for ${BOARD}"
    config_image_hook__"${BOARD}" "${chroot_dir}" "${overlay_dir}" "${SUITE}"
fi

# Download and install U-Boot
echo "==> [chroot] Installing U-Boot"
if [[ ${LAUNCHPAD} == "Y" ]]; then
    chroot ${chroot_dir} apt-get -y "${apt_opts[@]}" install "u-boot-${BOARD}"
else
    cp "${uboot_package}" ${chroot_dir}/tmp/
    # apt-get install (rather than dpkg -i) resolves this .deb's dependencies
    # (e.g. mtd-utils) from the chroot's apt lists up front, in the same
    # transaction, instead of installing it broken/unconfigured and then
    # needing a separate `-f install` pass to repair it afterward.
    chroot ${chroot_dir} apt-get -y "${apt_opts[@]}" install "/tmp/${uboot_package}"
    chroot ${chroot_dir} apt-mark hold "$(echo "${uboot_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"

    echo "==> [chroot] Installing the kernel"
    cp "${linux_image_package}" "${linux_headers_package}" "${linux_modules_package}" "${linux_buildinfo_package}" "${linux_rockchip_headers_package}" ${chroot_dir}/tmp/
    chroot ${chroot_dir} /bin/bash -c "apt-get -y purge \$(dpkg --list | grep -Ei 'linux-image|linux-headers|linux-modules|linux-rockchip' | awk '{ print \$2 }')"
    chroot ${chroot_dir} /bin/bash -c "apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install /tmp/{${linux_image_package},${linux_modules_package},${linux_buildinfo_package},${linux_rockchip_headers_package}}"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_image_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_modules_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_buildinfo_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
    chroot ${chroot_dir} apt-mark hold "$(echo "${linux_rockchip_headers_package}" | sed -rn 's/(.*)_[[:digit:]].*/\1/p')"
fi

# The server/desktop rootfs tarballs already carry an init system,
# u-boot-menu, and e2fsprogs (installed during their own livecd-rootfs
# build), but the base flavor is just Canonical's bare ubuntu-base tarball
# -- deliberately minimal for use as a container base image, so it ships
# none of them. Without systemd-sysv there's no /sbin/init at all (boot
# drops to an initramfs shell: "run-init: can't execute '/sbin/init'").
# Without e2fsprogs there's no fsck.ext4 for the initramfs to run against
# root ("Warning: fsck not present, so skipping root file system"). This
# chroot (unlike the one build-image.sh runs in) actually has /dev, /proc,
# /sys and DNS set up to install any of this with.
if [ "${FLAVOR}" == "base" ]; then
    # Add Joshua Riek's rockchip PPA (the same one server/desktop images get
    # via livecd-rootfs's EXTRA_PPAS, but base's ubuntu-base tarball has no
    # such mechanism at all) for rockchip-firmware, which carries Bluetooth
    # firmware -- BCM4345C0.hcd -- that mainline linux-firmware doesn't
    # ship. Plain file writes for the key/source (host-side gpg --dearmor,
    # no need for the chroot to have gnupg installed), then an apt-get
    # update since the one earlier in this script ran before this source
    # existed.
    echo "==> [chroot] Adding jjriek/rockchip PPA"
    curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF02122ECF25FB4D7" \
        | gpg --dearmor -o "${chroot_dir}/etc/apt/trusted.gpg.d/jjriek-rockchip.gpg"
    echo "deb http://ppa.launchpad.net/jjriek/rockchip/ubuntu ${SUITE} main" > "${chroot_dir}/etc/apt/sources.list.d/jjriek-rockchip.list"
    chroot ${chroot_dir} apt-get update

    echo "==> [chroot] Installing init system, fsck, networking, growroot, and u-boot-menu"
    # The root partition is only as big as the image was at build time
    # (build-image.sh sizes it off the rootfs tarball, then `parted ...
    # 100%`), not the actual eMMC/SD card it ends up flashed onto. The
    # /etc/fstab x-systemd.growfs option only grows the *filesystem* to
    # fill whatever the *partition* already is -- it never touches the
    # partition table, so there's nothing for it to grow into on its own.
    # cloud-initramfs-growroot extends the GPT partition itself to use the
    # rest of the disk (then resizes the filesystem into it) automatically
    # on first boot via an initramfs hook, same as server/desktop rely on
    # from their own livecd-rootfs build.
    # linux-firmware is large (several hundred MB installed, bundling
    # firmware for a huge range of unrelated hardware), but it's what
    # ships brcmfmac43455-sdio.bin for this board's WiFi -- bare
    # ubuntu-base ships no firmware at all, unlike server/desktop's
    # livecd-rootfs build. There's no smaller Broadcom-only package on
    # noble anymore (firmware-brcm80211 was folded into linux-firmware
    # some releases back). Bluetooth needs a separate file
    # (BCM4345C0.hcd) that mainline linux-firmware doesn't carry at all;
    # rockchip-firmware (from the PPA just added above) is where the
    # other boards in this repo needing the same chip get it from.
    chroot ${chroot_dir} apt-get -y "${apt_opts[@]}" install systemd-sysv e2fsprogs sudo net-tools iputils-ping network-manager cloud-initramfs-growroot u-boot-menu ssh linux-firmware rockchip-firmware

    # rockchip-firmware installs the Bluetooth patch flat at
    # /lib/firmware/BCM4345C0.hcd, but the kernel's BCM UART driver only
    # ever searches under /lib/firmware/brcm/ (confirmed on real hardware:
    # "BCM: firmware Patch file not found, tried: 'brcm/BCM4345C0.hcd', ...").
    # Symlink it into the path the driver actually looks in.
    ln -sf /lib/firmware/BCM4345C0.hcd "${chroot_dir}/lib/firmware/brcm/BCM4345C0.hcd"

    # network-manager's own default (/usr/lib/NetworkManager/conf.d/...)
    # leaves devices unmanaged unless something -- normally netplan, with
    # renderer: NetworkManager -- explicitly hands them over. This image
    # has no netplan config at all, so without this override eth0 would
    # sit as "unmanaged" in `nmcli dev` and never get DHCP'd. Dropping a
    # file in /etc/NetworkManager/conf.d/ (rather than editing the
    # package's own file under /usr/lib/) takes precedence and survives
    # package upgrades.
    echo "==> [chroot] Letting NetworkManager manage all devices"
    mkdir -p "${chroot_dir}/etc/NetworkManager/conf.d"
    printf '[keyfile]\nunmanaged-devices=\n' > "${chroot_dir}/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"

    # systemd normally creates its standard system users/groups (netdev,
    # render, etc.) via systemd-sysusers as part of booting -- this chroot
    # never actually boots, so run it explicitly (that's exactly the
    # scenario systemd-sysusers exists for) rather than have useradd below
    # fail on a missing group.
    chroot ${chroot_dir} systemd-sysusers

    # The server/desktop images' ubuntu/ubuntu default login comes from
    # cloud-init processing NoCloud seed files that build-image.sh only
    # copies onto the server/desktop boot partition layout -- the base
    # flavor's single-partition layout never gets those, and bare
    # ubuntu-base ships no users at all (root is locked, not just
    # passwordless), so without this there is no way to log in at all.
    echo "==> [chroot] Creating default 'ubuntu' user"
    chroot ${chroot_dir} useradd -m -s /bin/bash -G sudo,adm,dialout,cdrom,audio,video,plugdev ubuntu
    echo 'ubuntu:ubuntu' | chroot ${chroot_dir} chpasswd
    chroot ${chroot_dir} passwd -e ubuntu

    # Canonical's ubuntu-base tarball leaves the hostname unset (defaults
    # to "localhost"/"localhost.localdomain"), which makes local hostname
    # lookups -- e.g. sudo's own, logged as "unable to resolve host" --
    # fail since nothing in /etc/hosts matches it. Plain file edits, so no
    # need to go through (qemu-emulated) chroot for these.
    echo "==> [chroot] Setting hostname to ubuntu-rockchip"
    echo "ubuntu-rockchip" > "${chroot_dir}/etc/hostname"
    touch "${chroot_dir}/etc/hosts"
    sed -i '/127\.0\.1\.1/d' "${chroot_dir}/etc/hosts"
    echo "127.0.1.1 ubuntu-rockchip" >> "${chroot_dir}/etc/hosts"

    # This image gets cloned to every device it's flashed onto, so anything
    # meant to be unique-per-machine baked in here would instead be shared
    # by all of them: the SSH host keys ssh's postinst just generated above,
    # and /etc/machine-id (systemd-assigned, used for journald/dbus/D-Bus
    # peer identification etc.). Strip both. machine-id is reset by
    # truncating rather than deleting -- systemd's own documented way to
    # mark it for regeneration on next boot.
    echo "==> [chroot] Clearing SSH host keys and machine-id (regenerated per-device on first boot)"
    rm -f ${chroot_dir}/etc/ssh/ssh_host_*
    truncate -s 0 "${chroot_dir}/etc/machine-id"
fi

# Update the initramfs (e2fsprogs, if just installed above, needs to already
# be present for fsck.ext4 to be picked up and bundled in here)
echo "==> [chroot] Rebuilding the initramfs"
chroot ${chroot_dir} apt-get -y "${apt_opts[@]}" install initramfs-tools
chroot ${chroot_dir} update-initramfs -u

# Trim the image down (it has to fit a 16GB eMMC). Docs/man-pages and
# unused packages are real installed content, so purge them here, inside
# the chroot, before it goes away.
echo "==> [chroot] Purging docs, man pages, and unused packages"
chroot ${chroot_dir} apt-get -y "${apt_opts[@]}" purge man-db manpages info doc-base
chroot ${chroot_dir} apt-get -y "${apt_opts[@]}" autoremove

# Umount the root filesystem
echo "==> Leaving chroot at build/${chroot_dir}"
teardown_mountpoint $chroot_dir

# /var/lib/apt/lists and /var/cache/apt are tmpfs-mounted for the whole
# chroot session above (see setup_mountpoint) specifically so the apt
# index/package downloads from all the apt-get calls above never land in
# the real rootfs -- they're discarded the moment that tmpfs is unmounted.
# So clearing them (and /var/log) has to happen here, after
# teardown_mountpoint, directly against the real underlying directories --
# doing it inside the chroot beforehand would only touch the ephemeral
# tmpfs copy and have no effect on the shipped image. This also catches
# anything the original rootfs tarball already shipped with. Plain
# deletions, so no need to go through (qemu-emulated) chroot for these.
echo "==> Clearing apt lists/cache and logs from the rootfs"
rm -rf ${chroot_dir}/var/lib/apt/lists/* ${chroot_dir}/var/cache/apt/archives/* ${chroot_dir}/var/log/*

# Compress the root filesystem and then build a disk image
cd ${chroot_dir} && tar -cpf "../ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar" . && cd .. && rm -rf ${chroot_dir}
../scripts/build-image.sh "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
rm -f "ubuntu-${RELASE_VERSION}-preinstalled-${FLAVOR}-arm64-${BOARD}.rootfs.tar"
