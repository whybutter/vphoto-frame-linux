#!/usr/bin/env python3
"""Pull the Silead touch firmware out of the vendor's gslX680new.ko.

The vendor module carries eleven panels' firmwares; sys_config's ctp_name
("gslX680_juhong101") picks GSLX680_FW_Juhong101 through gslx680_fw_grp. Each
firmware is an array of {u32 offset, u32 val} -- byte-for-byte the format
mainline drivers/input/touchscreen/silead.c loads (struct silead_fw_data), so
no conversion is needed, only the cut.

What is NOT carried over: gsl_config_data_id_Juhong101, the tuning table for
the vendor's closed gsl_point_id filter library. Mainline has no equivalent;
if touches jitter or ghost, that is where to look.

    python3 gsl-fw-extract.py gslX680new.ko GSLX680_FW_Juhong101 > gsl1680-juhong101.fw
"""
import sys

from elfrel import Elf

e = Elf(sys.argv[1])
name, value, size, shndx = e.symbol(sys.argv[2])
blob = e.data(e.names[shndx])[value:value + size]
assert size % 8 == 0, "not an {offset,val} array"
sys.stdout.buffer.write(blob)
print(f"{sys.argv[2]}: {size // 8} words", file=sys.stderr)
