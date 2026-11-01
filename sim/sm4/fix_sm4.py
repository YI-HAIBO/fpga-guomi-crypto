#!/usr/bin/env python3
"""Fix SM4 engine bugs and verify.

Bugs:
  1. Line 55  : 32'hdc e3eaf1   -> 32'hdce3eaf1   (space inside hex literal)
  2. Line 132 : 8'hbfa          -> 8'hba           (typo: 3 hex digits in 8-bit field)
  3. Line 314 : round_keys[k_idx] <= K[k_idx+4]    -> round_keys[k_idx] <= key_next
                (non-blocking read of value being written same cycle)
  4. Line 345 : data_out <= {X[0],X[1],X[2],X[3]}  -> {X[3],X[2],X[1],X[0]}
                (SM4 output is reverse of last 4 rounds per GB/T 32907-2016)
"""
import io, sys

SRC = r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto\rtl\sm4\sm4_engine.v"

with io.open(SRC, "r", encoding="utf-8") as f:
    src = f.read()

# Stage 1: count occurrences of each old_string
edits = [
    # (name, old, new)
    ("hex space in CK[15]",
     "32'hdc e3eaf1",
     "32'hdce3eaf1"),
    ("S-box 0x47 typo",
     "8'h47: sm4_sbox = 8'hiba;",
     "8'h47: sm4_sbox = 8'hba;"),
    ("round_keys non-blocking timing",
     "                    round_keys[k_idx] <= K[k_idx + 4];",
     "                    round_keys[k_idx] <= key_next;"),
    ("SM4 output reverse order",
     "                        data_out  <= {X[0], X[1], X[2], X[3]};",
     "                        data_out  <= {X[3], X[2], X[1], X[0]};"),
]

print("=== Stage 1: count verification ===")
fail = False
for name, old, new in edits:
    c = src.count(old)
    mark = "OK" if c == 1 else "FAIL"
    print(f"  [{mark}] {name}: count={c} (expect 1)")
    if c != 1:
        fail = True

if fail:
    print("\nAborting - not all patterns matched exactly once.")
    sys.exit(1)

# Stage 2: apply
print("\n=== Stage 2: applying edits ===")
for name, old, new in edits:
    src = src.replace(old, new)
    print(f"  applied: {name}")

with io.open(SRC, "w", encoding="utf-8", newline="\n") as f:
    f.write(src)

# Stage 3: read back and verify
print("\n=== Stage 3: read-back verification ===")
with io.open(SRC, "r", encoding="utf-8") as f:
    src2 = f.read()

all_ok = True
for name, old, new in edits:
    old_c = src2.count(old)
    new_c = src2.count(new)
    mark = "OK" if (old_c == 0 and new_c == 1) else "FAIL"
    print(f"  [{mark}] {name}: old_remaining={old_c} (want 0), new_count={new_c} (want 1)")
    if old_c != 0 or new_c != 1:
        all_ok = False

if not all_ok:
    print("\nSome edits not applied as expected!")
    sys.exit(1)

print("\nAll 4 fixes applied and verified.")
