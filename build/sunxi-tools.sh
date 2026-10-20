#!/bin/sh
# sunxi-fel (and fexc) for the container, plus fel-sdboot.sunxi for a card.
#
# Built inside Docker by the owner's decision: nothing from GitHub gets compiled on
# the Mac. The catch is that sunxi-fel talks USB, and Docker Desktop on macOS has
# no USB passthrough -- so this binary can't reach the frame in FEL mode from here.
# What we actually need from it for now is fel-sdboot.sunxi (a 512-byte-ish eGON
# image that BROM loads from a card and that drops straight into FEL); driving
# FEL itself, if it is ever needed, takes a Linux box/VM with the frame's USB.
set -eu
. /work/build/versions.env
src=/cache/src/sunxi-tools-$SUNXI_TOOLS_COMMIT
make -C "$src" -s tools
mkdir -p /work/out/sunxi-tools
cp "$src/sunxi-fel" "$src/sunxi-fexc" "$src/bin/fel-sdboot.sunxi" /work/out/sunxi-tools/
ls -l /work/out/sunxi-tools
