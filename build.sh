#!/bin/sh
# Host entry point: builds the toolchain image, then runs one step inside it.
#
#   ./build.sh fetch        download + unpack the pinned sources into out/src
#   ./build.sh sunxi-tools  sunxi-fel, fel-sdboot.sunxi (built in Docker, never on the Mac)
#   ./build.sh uboot        out/u-boot-sunxi-with-spl.bin
#   ./build.sh kernel       out/zImage, out/*.dtb, out/modules.tar.gz
#   ./build.sh vendor       touch firmware cut from the eMMC backup (read-only mount)
#   ./build.sh rootfs       out/rootfs.ext4 (Alpine armv7, in an emulated armv7 container)
#   ./build.sh rootfs-test  boots its OpenRC runlevels in a chroot and checks the way in
#   ./build.sh image m1|full  out/frame-linux-<stage>.img
#   ./build.sh fat-update   out/fat-update/: boot.scr + rootfs fixes as files to copy onto FRAMEBOOT
#   ./build.sh boot-test    boots the card image (+ fat-update) in qemu vexpress-a9, checks its reports
#   ./build.sh shell        a shell in the build container
#
# Outputs land in out/ (gitignored). Inputs are build/versions.env plus the files
# in this directory; nothing is downloaded outside `fetch`.
#
# Sources and object trees live in the Docker volume `frame-linux-cache`, mounted
# at /cache, NOT in out/: the first try unpacked the kernel onto the bind mount and
# macOS's case-insensitive filesystem broke it (include/uapi has headers whose
# names differ only by case, xt_TCPMSS.h / xt_tcpmss.h). Downloads stay in out/dl.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
docker build -q -t frame-linux-build "$here/build" >/dev/null
step=${1:-}
[ -n "$step" ] || { sed -n '4,15p' "$0"; exit 1; }
shift
# Your own frame's files, read-only: the vendor step cuts the touch firmware out
# of them (README, "The touch firmware"). ./backup unless FRAME_BACKUP says
# otherwise; it holds gslX680new.ko, or the whole Android system.img.
backup=${FRAME_BACKUP:-$here/backup}
mkdir -p "$backup"
# The SSH key(s) the image will let in as root: FRAME_SSH_KEYS=<file> (an
# authorized_keys-style file, e.g. ~/.ssh/id_ed25519.pub), copied to
# out/authorized_keys for the rootfs step. Never committed.
if [ -n "${FRAME_SSH_KEYS:-}" ]; then
  mkdir -p "$here/out" && cp "$FRAME_SSH_KEYS" "$here/out/authorized_keys"
fi
vols="-v $here:/work -v frame-linux-cache:/cache -v $backup:/backup:ro"
if [ "$step" = rootfs ]; then
  # apk's post-install scripts are armv7 binaries; Apple silicon can't run AArch32,
  # so this one step runs in Docker's emulated linux/arm/v7.
  . "$here/build/versions.env"
  exec docker run --rm --platform linux/arm/v7 $vols alpine:${ALPINE_BRANCH#v} sh /work/build/rootfs.sh "$@"
fi
if [ "$step" = rootfs-test ]; then
  # same emulation, privileged for loop mounts and a dummy usb0
  . "$here/build/versions.env"
  exec docker run --rm --privileged --platform linux/arm/v7 $vols alpine:${ALPINE_BRANCH#v} sh /work/build/rootfs-test.sh "$@"
fi
if [ "$step" = boot-test ]; then
  # qemu-system-arm for this host, into out/qemu/root (the VM disk is too small
  # for an install in a container layer)
  [ -x "$here/out/qemu/root/usr/bin/qemu-system-arm" ] ||
    # --arch, not --platform: the local alpine tag may be the arm/v7 one the
    # rootfs step pulled, and docker runs a local tag whatever the platform says
    docker run --rm -v "$here:/work" alpine:3.22 sh -c '
      r=/work/out/qemu/root; mkdir -p $r/etc/apk/keys &&
      cp /usr/share/apk/keys/aarch64/* $r/etc/apk/keys/ &&
      cp /etc/apk/repositories $r/etc/apk/ &&
      apk add -q --root $r --arch aarch64 --initdb --no-cache --no-scripts qemu-system-arm'
fi
if [ "$step" = shell ]; then
  exec docker run --rm -it $vols frame-linux-build bash
fi
exec docker run --rm $vols frame-linux-build sh "/work/build/$step.sh" "$@"
