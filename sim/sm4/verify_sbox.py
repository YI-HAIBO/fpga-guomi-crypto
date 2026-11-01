#!/usr/bin/env python3
"""Verify SM4 S-box values against gmssl reference."""
import io, re, sys
from gmssl import sm4

# Load RTL S-box
SRC = r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto\rtl\sm4\sm4_engine.v"
with io.open(SRC, "r", encoding="utf-8") as f:
    src = f.read()

# Extract case entries: 8'hXX: sm4_sbox = 8'hYY;
pattern = re.compile(r"8'h([0-9a-fA-F]{2}):\s*sm4_sbox\s*=\s*8'h([0-9a-fA-F]{2})")
rtl_sbox = {}
for m in pattern.finditer(src):
    idx = int(m.group(1), 16)
    val = int(m.group(2), 16)
    rtl_sbox[idx] = val

print(f"Parsed {len(rtl_sbox)} RTL S-box entries")

# Reference: gmssl uses SM4_SBOX table
ref_sbox = list(sm4.SM4_BOXES_TABLE)
print(f"Reference gmssl SM4_SBOX has {len(ref_sbox)} entries")

# Compare
mismatch = []
missing = []
for i in range(256):
    rtl_v = rtl_sbox.get(i, None)
    ref_v = ref_sbox[i]
    if rtl_v is None:
        missing.append(i)
    elif rtl_v != ref_v:
        mismatch.append((i, rtl_v, ref_v))

if mismatch:
    print(f"\nMISMATCH ({len(mismatch)} entries):")
    for i, r, g in mismatch[:20]:
        print(f"  index 0x{i:02X}: RTL=0x{r:02X} gmssl=0x{g:02X}")
if missing:
    print(f"\nMISSING ({len(missing)} entries): {missing[:20]}")

if mismatch or missing:
    sys.exit(1)
else:
    print("\nALL 256 S-box entries match gmssl reference.")
