#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""run_v4.py -- sm4_engine_masked_v4 功能回归运行器 (compile + run)"""
import os, subprocess, sys

B = r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto"
IV = r"C:\iverilog\bin\iverilog.exe"
VVP = r"C:\iverilog\bin\vvp.exe"
SIM = os.path.join(B, "sim", "sm4")

tb = os.path.join(SIM, "tb_sm4_engine_masked_v4.v")
eng = os.path.join(B, "rtl", "sm4", "sm4_engine_masked_v4.v")
vvp = os.path.join(SIM, "tb_sm4_engine_masked_v4.vvp")

r = subprocess.run([IV, "-g2005", "-o", vvp, tb, eng],
                   capture_output=True, text=True, encoding="utf-8",
                   errors="replace", timeout=300)
print("iverilog rc", r.returncode)
if r.stderr.strip():
    print("ERR:", r.stderr[-2000:])
if r.returncode != 0:
    sys.exit(1)

r2 = subprocess.run([VVP, vvp], capture_output=True, text=True,
                    encoding="utf-8", errors="replace", timeout=1800, cwd=SIM)
print("vvp rc", r2.returncode)
print(r2.stdout[-4000:])
if r2.stderr.strip():
    print("VVP ERR:", r2.stderr[-1500:])
sys.exit(0 if r2.returncode == 0 else 1)
