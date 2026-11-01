#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""run_scea_det.py -- 板级确定性掩码种子采集运行器 (#157)

编译并运行 tb_scea_masked_v4_det (板级真实种子策略版), 产出
  <out>          : trace dump (格式同 tb_scea_masked_v4, 供 CPA 复用)
  <out>.seed.txt : 每行 "S <idx> <64-hex>" 的掩码种子旁录

判据: 仿真自检行不带 [ERR], dump 行数 == N_FIX+N_RND, 固定明文密文
命中 SM4 KAT 锚点 681EDF34D206965E86B3E94F536E4246.

用法:
  python run_scea_det.py --n 500 --out sim/scea_det_dump.txt
  python run_scea_det.py --n 50 --out sim/smoke.txt --seed 12345
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "rtl")
SIM = os.path.join(HERE, "sim")
ENG = os.path.normpath(os.path.join(HERE, "..", "rtl", "sm4",
                                    "sm4_engine_masked_v4.v"))

IV = os.environ.get("IVERILOG", r"C:\iverilog\bin\iverilog.exe")
VVP = os.environ.get("VVP", r"C:\iverilog\bin\vvp.exe")

KAT = "681EDF34D206965E86B3E94F536E4246"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=500,
                    help="每组 (固定/随机) 的 trace 条数")
    ap.add_argument("--seed", type=int, default=20261027)
    ap.add_argument("--out", default=os.path.join(SIM, "scea_det_dump.txt"))
    a = ap.parse_args()

    os.makedirs(SIM, exist_ok=True)
    vvp = os.path.join(SIM, "tb_scea_det.vvp")
    cmd = [IV, "-g2005", "-o", vvp,
           os.path.join(RTL, "tb_scea_masked_v4_det.v"), ENG]
    print("[build]", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8",
                       errors="replace", timeout=600)
    if r.returncode != 0:
        print("[ERR] iverilog failed:\n" + (r.stderr or "") + (r.stdout or ""))
        return 1
    print("[build] OK ->", vvp)

    # OUTF/SEEDF 只能传相对文件名 (%s 会吞含 ':' 的盘符), 落在 cwd=SIM,
    # 仿真结束后 rename 到 --out 指定路径.
    base = os.path.basename(os.path.abspath(a.out))
    seedf = base + ".seed.txt"
    cmd = [VVP, vvp,
           "+N_FIX=%d" % a.n, "+N_RND=%d" % a.n,
           "+SEED=%d" % a.seed,
           "+OUTF=" + base, "+SEEDF=" + seedf]
    print("[sim]", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8",
                       errors="replace", timeout=3600, cwd=SIM)
    print("    rc=%d" % r.returncode)
    for l in (r.stdout or "").splitlines():
        if l.strip():
            print("    |", l[:160])
    if r.returncode != 0:
        print("[ERR] simulation rc != 0")
        return 1

    out = os.path.abspath(a.out)
    for src_name, dst in ((base, out), (seedf, out + ".seed.txt")):
        src = os.path.join(SIM, src_name)
        if os.path.abspath(src) != os.path.abspath(dst):
            os.replace(src, dst)
        if not os.path.exists(dst):
            print("[ERR] missing:", dst)
            return 1

    with open(out, encoding="utf-8") as f:
        lines = [l for l in f.read().splitlines() if l.startswith("T ")]
    with open(out + ".seed.txt", encoding="utf-8") as f:
        seeds = [l for l in f.read().splitlines() if l.startswith("S ")]
    print("[dump] %d traces, %d seeds -> %s" % (len(lines), len(seeds), out))
    if len(lines) != 2 * a.n or len(seeds) != 2 * a.n:
        print("[ERR] count mismatch: %d/%d vs %d" %
              (len(lines), len(seeds), 2 * a.n))
        return 1
    ok_kat = ("expect=" + KAT) in (r.stdout or "")
    print("[xcheck] SM4 KAT =", "PASS" if ok_kat else "MISSING (check log)")
    print("RESULT: ", "PASS" if ok_kat else "FAIL")
    return 0


if __name__ == "__main__":
    sys.exit(main())
