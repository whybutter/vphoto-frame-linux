#!/bin/sh
# Host entry point: builds the toolchain image, then runs one step inside it.
#
#   ./build.sh fetch        download + unpack the pinned sources into out/src
#   ./build.sh sunxi-tools  sunxi-fel, fel-sdboot.sunxi (built in Docker, never on the Mac)
#   ./build.sh uboot        out/u-boot-sunxi-with-spl.bin
#   ./build.sh kernel       out/zImage, out/*.dtb, out/modules.tar.gz
#   ./build.sh vendor       touch firmware cut from the eMMC backup (read-only mount)
#   ./build.sh rootfs       out/rootfs.ext4 (Alpine armv7, in an emulated armv7 container)
#   ./build.sh image m1|full  out/frame-linux-<stage>.img
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
[ -n "$step" ] || { sed -n '4,12p' "$0"; exit 1; }
shift
# The eMMC backup, read-only: the vendor step cuts blobs out of it.
backup=${FRAME_BACKUP:-./backup/partitions}
vols="-v $here:/work -v frame-linux-cache:/cache -v $backup:/backup:ro"
if [ "$step" = rootfs ]; then
  # apk's post-install scripts are armv7 binaries; Apple silicon can't run AArch32,
  # so this one step runs in Docker's emulated linux/arm/v7.
  . "$here/build/versions.env"
  exec docker run --rm --platform linux/arm/v7 $vols alpine:${ALPINE_BRANCH#v} sh /work/build/rootfs.sh "$@"
fi
if [ "$step" = shell ]; then
  exec docker run --rm -it $vols frame-linux-build bash
fi
exec docker run --rm $vols frame-linux-build sh "/work/build/$step.sh" "$@"
