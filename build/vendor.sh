#!/bin/sh
# Vendor blobs, cut out of the eMMC backup (mounted read-only at /backup) at build
# time and never committed: out/firmware/silead/gsl1680-vphoto-modern10elite.fw
#
# debugfs reads system.img's ext4 without mounting it, so no loop device and no
# write path to the backup exists at all.
set -eu
tmp=/cache/obj/vendor
mkdir -p $tmp /work/out/firmware/silead
debugfs -R "dump /vendor/modules/gslX680new.ko $tmp/gslX680new.ko" /backup/system.img 2>/dev/null
python3 /work/tools/gsl-fw-extract.py $tmp/gslX680new.ko GSLX680_FW_Juhong101 \
  > /work/out/firmware/silead/gsl1680-vphoto-modern10elite.fw
# the cut that was checked against the live module pulled over adb on 2026-10-19
echo "b74d49605c8c3b3cf6f041bfcc5d99df  /work/out/firmware/silead/gsl1680-vphoto-modern10elite.fw" | md5sum -c -
