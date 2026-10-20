#!/bin/sh
# Download into out/dl, unpack into /cache/src (the volume; see build.sh). Idempotent: a source
# already unpacked at its pinned version is left alone.
set -eu
. /work/build/versions.env
mkdir -p /work/out/dl /cache/src
cd /work/out/dl
src=/cache/src
get() { [ -f "$2" ] || { wget -q -O "$2.part" "$1" && mv "$2.part" "$2"; }; }

get "$UBOOT_URL" u-boot-$UBOOT_VERSION.tar.bz2
[ -d $src/u-boot-$UBOOT_VERSION ] || tar -C $src -xjf u-boot-$UBOOT_VERSION.tar.bz2

get "$LINUX_URL" linux-$LINUX_VERSION.tar.xz
[ -d $src/linux-$LINUX_VERSION ] || tar -C $src -xJf linux-$LINUX_VERSION.tar.xz

get "$SUNXI_TOOLS_URL" sunxi-tools-$SUNXI_TOOLS_COMMIT.tar.gz
[ -d $src/sunxi-tools-$SUNXI_TOOLS_COMMIT ] || tar -C $src -xzf sunxi-tools-$SUNXI_TOOLS_COMMIT.tar.gz

ls $src
