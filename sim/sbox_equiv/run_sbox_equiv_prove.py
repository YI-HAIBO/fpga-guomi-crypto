#!/usr/bin/env python3
# =============================================================================
# run_sbox_equiv_prove.py -- Reproducible formal proof of S-box unmask equivalence
# =============================================================================
# Proves (via yosys built-in SAT, exhaustive over the full 2^24 input space):
#
#     for ALL tmp, K, mout8 in [0,255]^3 :  tau_m ^ mout8 == S(tmp)
#
#   i.e. the masked SM4 S-box, after unmasking, equals the standard GB/T 32907
#   S-box. `bad` (the mismatch signal) is proven UNSAT => equivalence holds.
#
#   This is the VERIFIED replacement for the sby frontend (which cannot be
#   installed from PyPI as of 2026-11; see job_sbox_equiv.sby header).
#
# Usage:
#   python run_sbox_equiv_prove.py
#     -> writes sbox_equiv_prove_<timestamp>.log and prints PASS/FAIL
#
# Requires: yosys (auto-detected from PATH or C:/msys64/ucrt64/bin/yosys.exe)
# =============================================================================

import datetime
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# --- locate yosys ---
def find_yosys():
    cands = [
        shutil.which("yosys"),
        r"C:/msys64/ucrt64/bin/yosys.exe",
        r"C:/msys64/usr/bin/yosys.exe",
        r"C:/Program Files/yosys/yosys.exe",
    ]
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None

YOSYS = find_yosys()
if not YOSYS:
    print("FATAL: yosys not found. Install Yosys (MSYS2: `pacman -S yosys`) or set PATH.")
    sys.exit(2)

SRCS = [
    "sbox_equiv_masked.v",
    "sbox_equiv_ref.v",
    "sbox_equiv_miter.v",
]
for s in SRCS:
    if not os.path.isfile(os.path.join(HERE, s)):
        print(f"FATAL: missing source file {s} in {HERE}")
        sys.exit(2)

CMD = [
    YOSYS,
    "-p",
    "read_verilog sbox_equiv_masked.v "
    "sbox_equiv_ref.v "
    "sbox_equiv_miter.v; "
    "hierarchy -top sbox_equiv_miter; "
    "flatten; "
    "proc; "
    "memory_map; "
    "opt; "
    "sat -prove bad 0",
]

stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
logpath = os.path.join(HERE, f"sbox_equiv_prove_{stamp}.log")

print(f"[{datetime.datetime.now():%Y-%m-%d %H:%M:%S}] yosys = {YOSYS}")
print(f"[*] running formal proof (exhaustive SAT over 2^24 input space) ...")
res = subprocess.run(CMD, cwd=HERE, capture_output=True, text=True, timeout=600)
out = res.stdout + "\n" + res.stderr

with open(logpath, "w", encoding="utf-8", newline="\n") as fh:
    fh.write(f"# sbox_equiv formal proof log\n")
    fh.write(f"# generated: {datetime.datetime.now():%Y-%m-%d %H:%M:%S}\n")
    fh.write(f"# yosys: {YOSYS}\n")
    fh.write(f"# command: {' '.join(CMD)}\n")
    fh.write("# " + "=" * 72 + "\n\n")
    fh.write(out)

passed = ("SAT proof finished - no model found" in out) and ("SUCCESS" in out)
failed = ("ERROR" in out) or ("model found" in out and "no model found" not in out)

if passed:
    print("[PASS] Formal proof SUCCESS: tau_m ^ mout8 == S(tmp) holds for all inputs.")
    print(f"       (SAT solver exhaustively proved `bad` UNSAT over the full input space)")
    print(f"[*] log: {logpath}")
    sys.exit(0)
elif failed:
    print("[FAIL] Formal proof did NOT hold / yosys error. See log.")
    print(f"[*] log: {logpath}")
    sys.exit(1)
else:
    print(f"[?] Unexpected yosys output (exit {res.returncode}). See log.")
    print(f"[*] log: {logpath}")
    sys.exit(3)
