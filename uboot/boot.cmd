# frame-linux boot script (mkimage -T script -> boot.scr on the card's FAT partition).
#
# U-Boot can't light this DSI panel, and the console pins are elsewhere, so this
# script makes itself visible the only two ways it can:
#   1. the backlight blinks 3 times (PL4 = enable; PH0 = the PWM pin driven as a
#      plain GPIO -- whichever polarity the panel's driver wants, one of the two
#      phases is bright, so a blink is seen either way). The panel shows no image,
#      just a glowing or dark backlight.
#   2. with no kernel on the card it becomes a USB fastboot gadget on the OTG port,
#      which the Mac sees (`system_profiler SPUSBDataType`).

gpio set PL4
for i in 1 2 3; do
  gpio set PH0; sleep 1
  gpio clear PH0; sleep 1
done
gpio set PH0

# g_ether picks random MACs each boot, so the Mac made a new enX every time;
# fixed, locally administered ones keep it one interface.
setenv bootargs "console=ttyS0,115200 console=tty1 root=PARTUUID=f4a3e001-02 rootwait rw panic=10 loglevel=7 fbcon=rotate:1 g_ether.dev_addr=02:fa:a3:00:07:02 g_ether.host_addr=02:fa:a3:00:07:01"

# The FAT update hook: before /sbin/init, mount the card's FAT and run
# FRAMEBOOT/frame-fix.sh if it is there (it unpacks frame-overlay.tar.gz over
# the root), so a rootfs fix is a file copy from the Mac, not a dd.
# Everything after "--" is the shell's argv (the kernel hands it to init). The
# string must hold no "=" (the kernel would split it as param=value) and no "$"
# (U-Boot would expand it here); every step is "; "-chained so a missing FAT or
# script still ends in `exec /sbin/init`. The card is mmcblk0 or mmcblk1
# depending on probe order (it was mmcblk1 on the frame), so both are tried.
setenv bootargs "${bootargs} init=/bin/sh -- -c \"/bin/mount -t proc proc /proc; /bin/mount -t vfat /dev/mmcblk1p1 /boot || /bin/mount -t vfat /dev/mmcblk0p1 /boot; [ -f /boot/frame-fix.sh ] && /bin/sh /boot/frame-fix.sh; /bin/umount /boot; /bin/umount /proc; exec /sbin/init\""

if load mmc 0:1 ${kernel_addr_r} zImage; then
  load mmc 0:1 ${fdt_addr_r} sun8i-a33-vphoto-modern10elite.dtb
  bootz ${kernel_addr_r} - ${fdt_addr_r}
fi

echo "frame-linux: no kernel on the card, waiting as a fastboot gadget"
fastboot usb 0
