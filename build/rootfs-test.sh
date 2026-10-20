#!/bin/sh
# Boots out/rootfs.ext4's OpenRC boot + default runlevels in a chroot (emulated
# armv7, privileged for loop mounts and a dummy usb0) and checks the way in:
# usb0 at 192.168.7.2, udhcpd and dropbear listening, root by key and not by
# password, frame-diag's reports on a FAT /boot, and no Wi-Fi secret in them.
#
# Why: the second card test showed the gadget enumerating with no carrier and no
# console to ask why. Every card round-trip costs the owner a power-off and a
# swap, so whatever can fail without the hardware fails here first. What this
# can't show: sysinit (devfs/mdev/hwdrivers), the real usb0/wlan0, SDIO, firmware
# loads, the display -- frame-diag's report on the card covers those.
#
# Works on copies under out/check (the Docker VM's own disk is too small for a
# 1.5 GB rootfs copy) and removes them at the end.
set -u
fail=0
check() { if sh -c "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "FAIL  $1"; fail=1; fi; }

apk add -q openssh-client dosfstools >/dev/null
w=/work/out/check; mkdir -p $w /r
cp /work/out/rootfs.ext4 $w/r.ext4
mount -o loop $w/r.ext4 /r || exit 1
mount -t proc proc /r/proc; mount -t sysfs sys /r/sys; mount --bind /dev /r/dev; mount -t tmpfs tmpfs /r/run
dd if=/dev/zero of=$w/boot.vfat bs=1M count=16 2>/dev/null; mkfs.vfat -n FRAMEBOOT $w/boot.vfat >/dev/null
mount -o loop,fmask=0177,dmask=0077 $w/boot.vfat /r/boot
printf 'ctrl_interface=/var/run/wpa_supplicant\ncountry=MX\nnetwork={\n ssid="TESTNET"\n psk="notreal123"\n}\n' > /r/boot/wpa_supplicant.conf
ip link add usb0 type dummy
ssh-keygen -q -t ed25519 -N "" -f /tmp/k; cat /tmp/k.pub >> /r/root/.ssh/authorized_keys
sed -i 's|^PARTUUID|#PARTUUID|' /r/etc/fstab   # already mounted by hand

chroot /r /bin/sh -c 'openrc boot; openrc default' > $w/openrc.log 2>&1
sleep 3
ssh="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes"

check "usb0 has 192.168.7.2/24"        "chroot /r ip -4 addr show usb0 | grep -q 192.168.7.2/24"
# (netstat -p would name qemu-arm here, not the daemon)
check "udhcpd listening on :67"         "chroot /r netstat -uln | grep -q ':67 ' && chroot /r pgrep -f udhcpd"
check "dropbear listening on :22"       "chroot /r netstat -tln | grep -q ':22 ' && chroot /r pgrep -f dropbear"
check "root logs in with a key"         "$ssh -i /tmp/k root@192.168.7.2 id | grep -q uid=0"
check "password login refused"          "! $ssh -o PubkeyAuthentication=no root@192.168.7.2 true"
check "authorized_keys 600, dirs 700"   "[ \$(stat -c %a /r/root) = 700 ] && [ \$(stat -c %a /r/root/.ssh) = 700 ] && [ \$(stat -c %a /r/root/.ssh/authorized_keys) = 600 ]"
check "wpa conf link resolves"          "chroot /r test -f /etc/wpa_supplicant/wpa_supplicant.conf"
check "wpa_supplicant supervised"       "chroot /r rc-service wpa_supplicant status"
check "frame-shell off without flag"    "grep -q 'frame-shell off' $w/openrc.log"
check "diag early.txt + boot.txt"       "[ -s /r/boot/diag/early.txt ] && [ -s /r/boot/diag/boot.txt ]"
check "status block in /etc/issue"      "grep -q 'ssh root@192.168.7.2' /r/etc/issue"
check "no ssid/psk in diag or issue"    "! grep -rq 'TESTNET\|notreal123' /r/boot/diag /r/etc/issue"
check "rtw8723d firmware (zstd)"        "[ -s /r/lib/firmware/rtw88/rtw8723d_fw.bin.zst ]"
check "regulatory.db + signature"       "[ -s /r/lib/firmware/regulatory.db ] && [ -s /r/lib/firmware/regulatory.db.p7s ]"
check "touch firmware"                  "[ -s /r/lib/firmware/silead/gsl1680-vphoto-modern10elite.fw ]"
check "rc_logger on"                    "grep -qx 'rc_logger=\"YES\"' /r/etc/rc.conf"

cp /r/boot/diag/boot.txt $w/sample-boot.txt
cp /r/etc/issue $w/sample-issue.txt
# stop what the runlevels started (not `openrc shutdown`: killprocs would take
# this container with it), then unmount
for p in /proc/[0-9]*; do [ "$(readlink $p/root)" = /r ] && kill ${p#/proc/} 2>/dev/null; done
sleep 2
umount -l /r/boot /r/run /r/dev /r/sys /r/proc /r
rm -f $w/r.ext4 $w/boot.vfat
[ $fail = 0 ] && echo "rootfs-test: all passed" || echo "rootfs-test: FAILURES (openrc output in out/check/openrc.log)"
exit $fail
