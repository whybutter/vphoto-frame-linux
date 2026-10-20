#!/usr/bin/env python3
"""Decode an Allwinner script.bin (sys_config.fex compiled) back to .fex text.

Written instead of building sunxi-tools' `bin2fex` because nothing more than
this was needed and it keeps the extraction reproducible from the repo alone.
Format (sunxi-tools script_bin.h): header {u32 sections, u32 size, u32 ver[2]},
then sections {char name[32], u32 count, u32 offset_in_words}, entries
{char name[32], u32 offset_in_words, u32 pattern = type<<16 | words}.

    python3 bin2fex.py script.bin > sys_config.fex
"""
import struct
import sys

PORTS = {0xFFFF: "power"}  # AXP-side pins: "port:power0" in fex


def gpio(words):
    port, num, mul, pull, drv, data = struct.unpack("<6i", words)
    name = PORTS.get(port & 0xFFFF, None)
    pin = f"port:{name}{num}" if name else f"port:P{chr(ord('A') + port - 1)}{num:02d}"
    def d(v):
        return "<default>" if v == -1 else f"<{v}>"
    return f"{pin}{d(mul)}{d(pull)}{d(drv)}{d(data)}"


def main(path):
    b = open(path, "rb").read()
    nsec = struct.unpack_from("<I", b, 0)[0]
    for i in range(nsec):
        name, count, off = struct.unpack_from("<32sII", b, 16 + i * 40)
        print(f"[{name.rstrip(b'\0').decode()}]")
        for j in range(count):
            ename, eoff, pat = struct.unpack_from("<32sII", b, off * 4 + j * 40)
            ename = ename.rstrip(b"\0").decode()
            typ, words = pat >> 16, pat & 0xFFFF
            raw = b[eoff * 4: eoff * 4 + words * 4]
            if typ == 1:
                v = struct.unpack("<i", raw)[0]
                val = hex(v) if v > 0xFFFF else str(v)
            elif typ == 2:
                val = '"' + raw.rstrip(b"\0").decode(errors="replace") + '"'
            elif typ == 4:
                val = gpio(raw)
            else:
                val = ""
            print(f"{ename} = {val}")
        print()


if __name__ == "__main__":
    main(sys.argv[1])
