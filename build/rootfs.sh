#!/bin/sh
# Alpine armv7 root filesystem -> out/rootfs.ext4
#
# Runs in an emulated linux/arm/v7 alpine container (see build.sh). Inputs:
#   rootfs/                     overlay, committed (network, fstab, init scripts)
#   out/modules.tar.gz          from `kernel`
#   out/firmware/               from `vendor` (touch firmware, cut from the backup)
#   out/authorized_keys         the Mac's public key(s); never committed
# Packages come from the pinned Alpine branch; the exact set that landed is
# written to out/rootfs.packages so two builds can be diffed.
set -eu
. /work/build/versions.env
out=/work/out
root=/tmp/rootfs
size_mb=${ROOTFS_MB:-1536}

[ -s $out/authorized_keys ] || { echo "out/authorized_keys missing (cp ~/.ssh/id_*.pub out/authorized_keys)"; exit 1; }

rm -rf $root && mkdir -p $root/etc/apk
cp -r /etc/apk/keys $root/etc/apk/
printf '%s\n' "$ALPINE_MIRROR/$ALPINE_BRANCH/main" "$ALPINE_MIRROR/$ALPINE_BRANCH/community" > $root/etc/apk/repositories

apk add -q --root $root --initdb --arch armv7 --no-cache \
  alpine-base openrc busybox-openrc busybox-extras \
  dropbear dropbear-openrc wpa_supplicant wpa_supplicant-openrc \
  chrony chrony-openrc iw linux-firmware-rtw88 wireless-regdb \
  e2fsprogs dosfstools eudev udev-init-scripts udev-init-scripts-openrc \
  cage seatd seatd-openrc wlr-randr mesa-dri-gallium mesa-egl mesa-gles \
  webkit2gtk-6.0 python3 py3-gobject3 py3-evdev font-dejavu

apk info --root $root -v 2>/dev/null | sort > $out/rootfs.packages

# overlay, then what the build produced
cp -a /work/rootfs/. $root/
tar -C $root -xzf $out/modules.tar.gz
cp -a $out/firmware/. $root/lib/firmware/
install -d $root/usr/lib/frame-shell
install -m 644 /work/shell/frame-shell.py /work/shell/bridge.js /work/shell/offline.html /work/shell/calibrate.html /work/shell/touchdebug.js $root/usr/lib/frame-shell/
install -m 755 /work/shell/start.sh $root/usr/lib/frame-shell/
install -d -m 700 $root/root/.ssh
install -m 600 $out/authorized_keys $root/root/.ssh/authorized_keys

# Wi-Fi credentials live on the FAT partition (written from the Mac, never in git)
mkdir -p $root/etc/wpa_supplicant $root/boot
ln -sf /boot/wpa_supplicant.conf $root/etc/wpa_supplicant/wpa_supplicant.conf

# root has no password at all: dropbear is key-only and the panel has no keyboard
sed -i 's|^root:[^:]*:|root:*:|' $root/etc/shadow

# every service's output in /var/log/rc.log, which frame-diag copies to the card
sed -i 's|^#\?rc_logger=.*|rc_logger="YES"|' $root/etc/rc.conf
grep -qx 'rc_logger="YES"' $root/etc/rc.conf

chroot $root /bin/sh -e <<'EOF'
# udev, not mdev: wlroots finds input devices through libinput, and libinput
# only through udev -- under mdev cage saw no touchscreen ("libinput
# initialization failed, no input devices") and wouldn't start. udev also does
# the module autoloading hwdrivers did, and real hotplug.
for s in devfs dmesg udev udev-trigger udev-settle; do rc-update -q add $s sysinit; done
for s in modules sysctl hostname localmount bootmisc syslog swclock seedrng frame-diag-early; do rc-update -q add $s boot; done
for s in udev-postmount frame-netwait networking wpa_supplicant dropbear chronyd usb-dhcpd seatd frame-shell frame-diag; do rc-update -q add $s default; done
for s in mount-ro killprocs savecache; do rc-update -q add $s shutdown; done
EOF

rm -f $out/rootfs.ext4
mkfs.ext4 -q -L frameroot -d $root $out/rootfs.ext4 ${size_mb}M 2>/dev/null ||
  { apk add -q e2fsprogs && mkfs.ext4 -q -L frameroot -d $root $out/rootfs.ext4 ${size_mb}M; }
du -sh $root
ls -l $out/rootfs.ext4
