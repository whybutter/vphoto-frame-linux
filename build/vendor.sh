#!/bin/sh
# Vendor blobs, cut at build time out of YOUR frame's own files (mounted
# read-only at /backup) and never committed or redistributed:
#   out/firmware/silead/gsl1680-vphoto-modern10elite.fw
# /backup holds either the vendor touch module itself (gslX680new.ko, from the
# frame's /vendor/modules) or a dump of Android's system partition (system.img).
#
# debugfs reads system.img's ext4 without mounting it, so no loop device and no
# write path to the backup exists at all.
set -eu
tmp=/cache/obj/vendor
mkdir -p $tmp /work/out/firmware/silead
if [ -f /backup/gslX680new.ko ]; then
  cp /backup/gslX680new.ko $tmp/
elif [ -f /backup/system.img ]; then
  debugfs -R "dump /vendor/modules/gslX680new.ko $tmp/gslX680new.ko" /backup/system.img 2>/dev/null
else
  echo "no gslX680new.ko or system.img in the backup dir (README, \"The touch firmware\")"; exit 1
fi
python3 /work/tools/gsl-fw-extract.py $tmp/gslX680new.ko GSLX680_FW_Juhong101 \
  > /work/out/firmware/silead/gsl1680-vphoto-modern10elite.fw
# the cut that was checked against the live module pulled over adb on 2026-10-19
echo "b74d49605c8c3b3cf6f041bfcc5d99df  /work/out/firmware/silead/gsl1680-vphoto-modern10elite.fw" | md5sum -c -
