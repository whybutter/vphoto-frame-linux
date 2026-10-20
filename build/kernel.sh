#!/bin/sh
# Mainline kernel for the frame: out/zImage, out/<board>.dtb, out/modules.tar.gz
#
# Our two in-tree additions (the panel driver and the board .dts) are copied
# into the unpacked tree and hooked into its Kconfig/Makefiles here, idempotently
# -- no patch files to rebase when LINUX_VERSION moves.
set -eu
. /work/build/versions.env
src=/cache/src/linux-$LINUX_VERSION
obj=/cache/obj/linux
board=sun8i-a33-vphoto-modern10elite
mkdir -p $obj /work/out

cp /work/kernel/panel-vphoto-a00zp101b187.c $src/drivers/gpu/drm/panel/
grep -q PANEL_VPHOTO_A00ZP101B187 $src/drivers/gpu/drm/panel/Kconfig || cat >> $src/drivers/gpu/drm/panel/Kconfig <<'EOF'

config DRM_PANEL_VPHOTO_A00ZP101B187
	tristate "VPhoto Modern 10 Elite 800x1280 DSI panel"
	depends on OF && DRM_MIPI_DSI && BACKLIGHT_CLASS_DEVICE
EOF
grep -q panel-vphoto-a00zp101b187 $src/drivers/gpu/drm/panel/Makefile ||
  echo 'obj-$(CONFIG_DRM_PANEL_VPHOTO_A00ZP101B187) += panel-vphoto-a00zp101b187.o' >> $src/drivers/gpu/drm/panel/Makefile

cp /work/kernel/$board.dts $src/arch/arm/boot/dts/allwinner/
grep -q $board $src/arch/arm/boot/dts/allwinner/Makefile ||
  echo "dtb-\$(CONFIG_MACH_SUN8I) += $board.dtb" >> $src/arch/arm/boot/dts/allwinner/Makefile

cd $src
make -s O=$obj sunxi_defconfig
scripts/kconfig/merge_config.sh -m -O $obj $obj/.config /work/kernel/frame.config >/dev/null
make -s O=$obj olddefconfig
# a symbol that didn't survive the merge is a build that boots dark: fail here
sed -n 's/^# \(CONFIG_[A-Z0-9_]*\) is not set$/\1=n/p; /^CONFIG_/p' /work/kernel/frame.config |
while IFS= read -r want; do
  grep -qx "$want" $obj/.config || { echo "not applied: $want"; exit 1; }
done

make -s O=$obj -j"$(nproc)" zImage modules allwinner/$board.dtb
rm -rf /cache/obj/modroot
make -s O=$obj INSTALL_MOD_PATH=/cache/obj/modroot INSTALL_MOD_STRIP=1 modules_install
cp $obj/arch/arm/boot/zImage /work/out/
cp $obj/arch/arm/boot/dts/allwinner/$board.dtb /work/out/
tar -C /cache/obj/modroot -czf /work/out/modules.tar.gz lib
cat $obj/include/config/kernel.release > /work/out/kernel.release
ls -l /work/out/zImage /work/out/$board.dtb /work/out/modules.tar.gz
