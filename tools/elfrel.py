#!/usr/bin/env python3
"""Tiny ELF32-LE relocatable reader: sections, symbols, and REL entries.

Shared by the vendor-module extractors here (gsl firmware table, panel init
tables). pyelftools would do, but this keeps the tools dependency-free.
"""
import struct


class Elf:
    def __init__(self, path):
        self.b = b = open(path, "rb").read()
        shoff, = struct.unpack_from("<I", b, 0x20)
        shentsize, shnum, shstrndx = struct.unpack_from("<HHH", b, 0x2E)
        self.sh = []
        for i in range(shnum):
            self.sh.append(struct.unpack_from("<10I", b, shoff + i * shentsize))
        strtab = self.sh[shstrndx]
        self.names = [self._str(strtab[4], s[0]) for s in self.sh]
        self.idx = {n: i for i, n in enumerate(self.names)}
        st = self.sh[self.idx[".symtab"]]
        ss = self.sh[st[6]]
        self.syms = []
        for o in range(st[4], st[4] + st[5], 16):
            name, value, size, info, other, shndx = struct.unpack_from("<IIIBBH", b, o)
            self.syms.append((self._str(ss[4], name), value, size, shndx))

    def _str(self, off, i):
        e = self.b.index(b"\0", off + i)
        return self.b[off + i:e].decode()

    def data(self, name):
        s = self.sh[self.idx[name]]
        return self.b[s[4]:s[4] + s[5]]

    def rels(self, name):
        """{offset_in_section: (symbol_name, symbol_value, symbol_section_name)}"""
        s = self.sh[self.idx[".rel" + name]]
        out = {}
        for o in range(s[4], s[4] + s[5], 8):
            off, info = struct.unpack_from("<II", self.b, o)
            sym = self.syms[info >> 8]
            sec = self.names[sym[3]] if sym[3] < len(self.names) else ""
            out[off] = (sym[0], sym[1], sec)
        return out

    def symbol(self, name, source=None):
        """First symbol called `name`; with `source`, only one defined after
        that STT_FILE entry (static names like LCM_080WX_setting repeat once
        per panel .c file inside lcd.ko)."""
        inside = source is None
        for s in self.syms:
            if source is not None and s[0].endswith(".c"):
                inside = s[0] == source
            elif inside and s[0] == name:
                return s
        return None
