#!/bin/sh
# FRAMEBOOT/frame-fix.sh -- run by boot.scr's init= hook before /sbin/init,
# with / mounted rw by the kernel and the card's FAT mounted on /boot. Nothing
# else is up: no /dev beyond devtmpfs, no /sys, no network.
#
# Why it exists: the owner can write the FAT from the Mac but not the ext4
# root, and a full `dd` of the card needs them at a Terminal. This makes a
# rootfs fix a FAT copy: frame-overlay.tar.gz (built by build/fat-update.sh,
# files under their / paths, owned by root) is unpacked over / once per new
# version, and the result logged to /boot/diag/fix.txt.
#
# Physical access to the card already means root on this box; this adds no
# reach, only convenience. Delete frame-overlay.tar.gz to stop updates.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p /boot/diag
{
	echo "frame-fix $(date) uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
	tgz=/boot/frame-overlay.tar.gz
	if [ -f $tgz ]; then
		new=$(sha256sum $tgz | cut -d' ' -f1)
		old=$(cat /etc/frame-overlay.sha256 2>/dev/null)
		if [ "$new" = "$old" ]; then
			echo "overlay $new already applied"
		elif tar -xzf $tgz -C / ; then
			echo "$new" > /etc/frame-overlay.sha256
			echo "applied overlay $new:"
			tar -tzf $tgz
		else
			echo "overlay $new FAILED to unpack"
		fi
	else
		echo "no overlay on the card"
	fi
	sync
} >> /boot/diag/fix.txt 2>&1
exit 0
