#!/bin/sh
# Host entry point: builds the toolchain image, then runs one step inside it.
#
#   ./build.sh fetch        download + unpack the pinned sources into out/src
#   ./build.sh sunxi-tools  sunxi-fel, fel-sdboot.sunxi (built in Docker, never on the Mac)
#   ./build.sh uboot        out/u-boot-sunxi-with-spl.bin
#   ./build.sh kernel       out/zImage, out/*.dtb, out/modules
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
[ -n "$step" ] || { sed -n '4,9p' "$0"; exit 1; }
shift
if [ "$step" = shell ]; then
  exec docker run --rm -it -v "$here:/work" -v frame-linux-cache:/cache frame-linux-build bash
fi
exec docker run --rm -v "$here:/work" -v frame-linux-cache:/cache frame-linux-build sh "/work/build/$step.sh" "$@"
