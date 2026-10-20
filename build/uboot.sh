#!/bin/sh
# U-Boot for the card: out/u-boot-sunxi-with-spl.bin (goes at 8 KiB) + out/boot.scr.
set -eu
. /work/build/versions.env
src=/cache/src/u-boot-$UBOOT_VERSION
obj=/cache/obj/u-boot
mkdir -p $obj /work/out
cd $src
make -s O=$obj q8_a33_tablet_800x480_defconfig
scripts/kconfig/merge_config.sh -m -O $obj $obj/.config /work/uboot/frame.config >/dev/null
make -s O=$obj olddefconfig
# merge_config only warns when a symbol doesn't survive; for us that is an error
# (a DRAM setting silently dropped is a frame that doesn't boot).
sed -n 's/^# \(CONFIG_[A-Z0-9_]*\) is not set$/\1=n/p; /^CONFIG_/p' /work/uboot/frame.config |
while IFS= read -r want; do
  case "$want" in
    *=n) key=${want%=n}; ! grep -q "^$key=" $obj/.config || { echo "still set: $key"; exit 1; } ;;
    *) grep -qx "$want" $obj/.config || { echo "not applied: $want"; exit 1; } ;;
  esac
done
make -s O=$obj -j"$(nproc)"
cp $obj/u-boot-sunxi-with-spl.bin /work/out/
mkimage -q -A arm -T script -C none -d /work/uboot/boot.cmd /work/out/boot.scr
ls -l /work/out/u-boot-sunxi-with-spl.bin /work/out/boot.scr
