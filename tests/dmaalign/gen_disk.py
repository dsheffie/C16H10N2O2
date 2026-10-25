#!/usr/bin/env python3
# gen_disk.py <out>: 64 self-identifying sectors; sector N word W = 0x5E<N:16><W:8> (BE)
import struct, sys
with open(sys.argv[1], "wb") as f:
    for n in range(64):
        f.write(b"".join(struct.pack(">I", (0x5E << 24) | (n << 8) | w) for w in range(128)))
