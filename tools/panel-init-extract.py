#!/usr/bin/env python3
"""Print the DSI init table of the vendor lcd.ko panel a00zp101b187_e40.

LCD_panel_init() walks LCM_080WX_setting, 72-byte rows {u32 cmd, u32 count,
u8 para[64]}: count 0xFE means "sleep para[0] ms", 0xBB ends the table, any
other row is dsi_dcs_wr(cmd, para, count). Printed as C rows ready for a
mainline drm_panel driver.

LCM_080WX_setting is a static name repeated in every panel .c file of lcd.ko
(the first one is a JD9365 table, E0 00 / E1 93 / E2 65 ...): the lookup is
scoped to a00zp101b187_e40.c on purpose -- the unscoped one printed the wrong
panel's sequence.

    python3 panel-init-extract.py lcd.ko
"""
import struct
import sys

from elfrel import Elf

e = Elf(sys.argv[1])
_, value, size, shndx = e.symbol("LCM_080WX_setting", "a00zp101b187_e40.c")
d = e.data(e.names[shndx])[value:value + size]
for i in range(0, size, 72):
    cmd, count = struct.unpack_from("<II", d, i)
    para = d[i + 8:i + 8 + 64]
    if count == 0xBB:
        break
    if count == 0xFE:
        print(f"\t/* msleep({para[0]}) */")
        continue
    print("\t{ " + ", ".join(f"0x{x:02x}" for x in bytes([cmd]) + para[:count]) + " },")
