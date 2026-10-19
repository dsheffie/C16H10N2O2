#!/usr/bin/env python3
# Diff vdma_test.c's "exp" doublewords against henry_tb GIOLOG=1 "[giow]" writes to
# REX3 HOSTRW0 (offset 0x230).  Usage: check.py <henry_tb log>
import re, sys
exp, got = [], []
marks, ends = [], []           # HOSTRW0 writes seen before each CPU DRAWMODE1 store; cumulative per transfer
for l in open(sys.argv[1], errors='replace'):
    m = re.search(r'exp (\d+) ([0-9a-f]{8}) ([0-9a-f]{8})', l)
    if m:
        exp.append(int(m.group(2), 16) << 32 | int(m.group(3), 16))
    m = re.search(r'\[giow\] 0230 ([0-9a-f]{16}) 8', l)
    if m:
        got.append(int(m.group(1), 16))
    if re.search(r'\[giow\] 0000 ', l):
        marks.append(len(got))
    m = re.search(r'transfer (\d+) done \((\d+) doublewords', l)
    if m:
        ends.append(int(m.group(2)))
bad = sum(1 for a, b in zip(exp, got) if a != b)
print('expected %d, got %d, mismatches %d' % (len(exp), len(got), bad))
for i, (a, b) in enumerate(zip(exp, got)):
    if a != b:
        print('  #%d got %016x expected %016x' % (i, b, a))
        break
order_ok = (marks == ends) and len(ends) > 0
print('CPU store after its transfer: %s (HOSTRW0 writes before each store %s, transfer ends %s)' %
      ('ok' if order_ok else 'NO', marks, ends))
print('PASS' if (len(exp) == len(got) and len(exp) > 0 and bad == 0 and order_ok) else 'FAIL')
