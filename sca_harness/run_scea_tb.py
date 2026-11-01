"""SCEA TB compile & run driver. Keeps paths in a script to avoid bash-shim
backslash mangling of inline python -c arguments."""
import os, subprocess, sys

B = r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto"
IV = r"C:\iverilog\bin\iverilog.exe"
VVP = r"C:\iverilog\bin\vvp.exe"
SIM = os.path.join(B, "sca_harness", "sim")
os.makedirs(SIM, exist_ok=True)

MODE = sys.argv[1] if len(sys.argv) > 1 else "unmasked"

RTL = os.path.join(B, "sca_harness", "rtl")
if MODE == "masked":
    eng = os.path.join(B, "rtl", "sm4", "sm4_engine_masked_v3.v")
    vvp = os.path.join(SIM, "tb_scea_masked.vvp")
    tb = os.path.join(RTL, "tb_scea_masked.v")
elif MODE == "masked_v4":
    eng = os.path.join(B, "rtl", "sm4", "sm4_engine_masked_v4.v")
    vvp = os.path.join(SIM, "tb_scea_masked_v4.vvp")
    tb = os.path.join(RTL, "tb_scea_masked_v4.v")
else:
    eng = os.path.join(B, "rtl", "sm4", "sm4_engine.v")
    vvp = os.path.join(SIM, "tb_scea.vvp")
    tb = os.path.join(RTL, "tb_scea.v")

cmd = [IV, "-g2005", "-o", vvp, tb, eng]
print("CMD:", " ".join(cmd))
r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                   errors="replace", timeout=300)
print("iverilog rc", r.returncode)
if r.stdout.strip():
    print("OUT:", r.stdout[-2000:])
if r.stderr.strip():
    print("ERR:", r.stderr[-3000:])
if r.returncode != 0:
    sys.exit(1)

if len(sys.argv) > 2 and sys.argv[2] == "compile_only":
    print("compiled:", vvp, os.path.getsize(vvp), "bytes")
    sys.exit(0)

# run
dump = os.path.join(SIM, "scea_dump_%s.txt" % MODE)
if os.path.exists(dump):
    os.remove(dump)
print("\n=== running vvp ===")
r2 = subprocess.run([VVP, vvp], capture_output=True, text=True, encoding="utf-8",
                    errors="replace", timeout=3600, cwd=SIM)
print("vvp rc", r2.returncode)
print(r2.stdout[-3000:])
if r2.stderr.strip():
    print("VVP ERR:", r2.stderr[-1500:])
