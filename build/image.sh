#!/bin/sh
# Assemble the TF-card image: out/frame-linux-<stage>.img
#
#   image.sh m1    U-Boot + boot.scr only (milestone 1: does the card boot at all?)
#   image.sh full  + zImage, our dtb on p1, the Alpine rootfs (out/rootfs.ext4) as p2
#
# Layout (sunxi BROM fixes the first two):
#   0       MBR
#   8 KiB   u-boot-sunxi-with-spl.bin (eGON header; BROM reads it from here)
#   1 MiB   p1 FAT32 "FRAMEBOOT" 63 MiB: boot.scr, zImage, *.dtb
#   64 MiB  p2 ext4 rootfs (full only)
# Built entirely in a file with sfdisk + mkfs + mtools: no loop devices, so it
# runs in an unprivileged container.
set -eu
stage=${1:?m1 or full}
out=/work/out
img=$out/frame-linux-$stage.img
boot=/cache/obj/boot.vfat

rm -f "$img" "$boot"
mkfs.vfat -C -n FRAMEBOOT -F 32 "$boot" $((63 * 1024)) >/dev/null
mcopy -i "$boot" $out/boot.scr ::boot.scr
if [ "$stage" = full ]; then
  mcopy -i "$boot" $out/zImage ::zImage
  mcopy -i "$boot" $out/sun8i-a33-vphoto-modern10elite.dtb ::
  rootsz=$(stat -c %s $out/rootfs.ext4)
else
  rootsz=0
fi

total=$((64 * 1024 * 1024 + rootsz))
truncate -s $total "$img"
if [ "$stage" = full ]; then
  printf 'label: dos\nstart=2048, size=129024, type=c\nstart=131072, type=83\n' | sfdisk -q "$img"
else
  printf 'label: dos\nstart=2048, size=129024, type=c\n' | sfdisk -q "$img"
fi
dd if=$out/u-boot-sunxi-with-spl.bin of="$img" bs=1024 seek=8 conv=notrunc status=none
dd if="$boot" of="$img" bs=1M seek=1 conv=notrunc status=none
[ "$stage" = full ] && dd if=$out/rootfs.ext4 of="$img" bs=1M seek=64 conv=notrunc status=none

# BROM only boots what carries this magic at 8 KiB + 4.
dd if="$img" bs=1 skip=$((8192 + 4)) count=8 status=none | grep -q eGON.BT0
sha256sum "$img" | tee "$img.sha256"
ls -l "$img"
