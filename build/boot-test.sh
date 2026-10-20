#!/bin/sh
# Boots the card image for real, short of the A33: out/frame-linux-full.img
# (plus out/fat-update/ if present, copied onto FRAMEBOOT the way the owner
# would) in qemu's vexpress-a9, under U-Boot's own hush parser and a kernel
# with an mdev-only /dev. Only the zImage and dtb are swapped for vexpress ones,
# under the frame's file names. The card's own reports (FRAMEBOOT/diag) come
# back to out/qemu/diag.
#
# Why: rootfs-test runs OpenRC in a chroot on the host's /dev and had mounted
# /boot by hand, so it never ran fsck against the fstab -- and that is exactly
# where the first three card boots died. Here nothing is mounted for the image.
# Still not covered: the A33 itself (display, usb0, wlan0, SDIO, firmware).
#
# Runs in frame-linux-build; qemu (aarch64) is installed into out/qemu/root by
# build.sh, and the kernel/U-Boot build into out/qemu (the Docker VM disk is
# small; out/ is on the Mac). out/qemu/tmp is TMPDIR for the same reason.
set -eu
q=/work/out/qemu
mkdir -p $q/tmp && export TMPDIR=$q/tmp
src=/cache/src/linux-$(. /work/build/versions.env; echo $LINUX_VERSION)
ub=/cache/src/u-boot-$(. /work/build/versions.env; echo $UBOOT_VERSION)
if [ ! -f $q/obj/arch/arm/boot/zImage ]; then
	(cd $src && make -s O=$q/obj vexpress_defconfig &&
	 scripts/kconfig/merge_config.sh -m -O $q/obj $q/obj/.config /work/build/qemu/vexpress.config >/dev/null &&
	 make -s O=$q/obj olddefconfig && make -s O=$q/obj -j"$(nproc)" zImage dtbs) 2>&1 | grep -v "skew\|in the future" || true
fi
if [ ! -f $q/ubvex/u-boot ]; then
	(cd $ub && make -s O=$q/ubvex vexpress_ca9x4_defconfig && make -s O=$q/ubvex -j"$(nproc)")
fi

sd=$q/sd.img
cp /work/out/frame-linux-full.img $sd
truncate -s 2G $sd  # qemu wants a power-of-two SD card
fat="$sd@@1M"
if [ -d /work/out/fat-update ]; then
	for f in boot.scr frame-fix.sh frame-overlay.tar.gz; do mcopy -o -i "$fat" /work/out/fat-update/$f ::$f; done
fi
printf 'ctrl_interface=/var/run/wpa_supplicant\ncountry=MX\nnetwork={\n ssid="TESTNET"\n psk="notreal123"\n}\n' > $q/tmp/wpa.conf
mcopy -o -i "$fat" $q/tmp/wpa.conf ::wpa_supplicant.conf
mcopy -o -i "$fat" $q/obj/arch/arm/boot/zImage ::zImage
mcopy -o -i "$fat" $q/obj/arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb ::sun8i-a33-vphoto-modern10elite.dtb

# vexpress's distro boot can't load a script (no scriptaddr in its env), so
# interrupt autoboot and source boot.scr by hand: the script is what's tested.
# Two boots of the same card: the second must find the overlay already applied.
secs=${QEMU_SECS:-300}
r=$q/root
boot() {
	{ sleep 1; printf '\n\n'; sleep 3
	  printf 'setenv scriptaddr 0x68000000; load mmc 0:1 ${scriptaddr} boot.scr; source ${scriptaddr}\n'
	  sleep $secs; } |
	timeout $secs $r/lib/ld-musl-aarch64.so.1 --library-path $r/lib:$r/usr/lib \
	  $r/usr/bin/qemu-system-arm -L $r/usr/share/qemu -M vexpress-a9 -m 1G -smp 1 \
	  -kernel $q/ubvex/u-boot -drive if=sd,file=$sd,format=raw \
	  -display none -serial stdio -monitor none > $q/serial$1.log 2>&1 || true
}
boot 1
boot 2

rm -rf $q/diag && mkdir -p $q/diag
mcopy -n -i "$fat" '::/diag/*' $q/diag/ 2>/dev/null || true
rm -f $sd
fail=0
check() { if sh -c "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }
d=$q/diag
check "U-Boot sourced boot.scr"          "grep -q 'Executing script' $q/serial1.log && grep -q 'Executing script' $q/serial2.log"
check "frame-fix ran (diag/fix.txt)"     "[ -s $d/fix.txt ]"
check "overlay applied or current"       "grep -q 'overlay .* applied\|applied overlay\|no overlay' $d/fix.txt"
check "hook ran on both boots"           "[ \$(grep -c '^frame-fix ' $d/fix.txt) = 2 ]"
check "second boot: nothing re-applied"  "! [ -f /work/out/fat-update/frame-overlay.tar.gz ] || tail -1 $d/fix.txt | grep -q 'already applied'"
check "early report (boot runlevel)"     "[ -s $d/early.txt ]"
check "boot report (default runlevel)"   "[ -s $d/boot.txt ]"
check "fsck didn't abort"                "! grep -q 'rc: Aborting\|couldn.t be fixed' $d/boot.txt"
check "localmount started, /boot mounted" "grep -q 'localmount .*started' $d/boot.txt && grep -q ' on /boot type vfat' $d/boot.txt"
check "hostname set"                     "grep -q 'vphoto-modern10elite' $d/boot.txt"
check "networking, dropbear started"     "grep -q 'networking .*started' $d/boot.txt && grep -q 'dropbear .*started' $d/boot.txt"
check "init hook on the cmdline intact"  "grep -q 'exec /sbin/init\"' $d/boot.txt"
check "no ssid/psk in the reports"       "! grep -q 'TESTNET\|notreal123' $d/*.txt"
[ $fail = 0 ] && echo "boot-test: all passed" || echo "boot-test: FAILURES (out/qemu/serial[12].log, out/qemu/diag/)"
exit $fail
