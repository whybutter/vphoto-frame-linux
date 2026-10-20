#!/bin/sh
# A card update the owner can apply from the Mac by copying files onto
# FRAMEBOOT -- no dd, no ext4: out/fat-update/
#   boot.scr               from uboot/boot.cmd (carries the init= hook)
#   frame-fix.sh           boot/frame-fix.sh, run by that hook before /sbin/init
#   frame-overlay.tar.gz   the rootfs files listed below, unpacked over / once
#   SHA256SUMS
# The overlay lists only what changed since the image on the card; a full image
# build carries the same files in the rootfs itself.
set -eu
out=/work/out/fat-update
rm -rf $out && mkdir -p $out
# fixed timestamp: the same boot.cmd always gives the same bytes (and sha256)
SOURCE_DATE_EPOCH=0 mkimage -q -A arm -T script -C none -d /work/uboot/boot.cmd $out/boot.scr
cp /work/boot/frame-fix.sh $out/
# third card test: fstab by PARTUUID aborted the boot in fsck (rootfs/etc/fstab)
files="etc/fstab etc/conf.d/fsck"
tar -C /work/rootfs --owner=0 --group=0 --numeric-owner --mtime=@0 \
  -czf $out/frame-overlay.tar.gz $files
cd $out && sha256sum boot.scr frame-fix.sh frame-overlay.tar.gz > SHA256SUMS
cat SHA256SUMS; tar -tvzf frame-overlay.tar.gz
