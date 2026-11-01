#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""run_scea2_v5.py -- 二阶泄漏采集运行器 v5.0 (独立输出掩码引擎)

编译并运行 tb_scea2_masked_v5 (round-0 专用采集), 产出 dump 文件供
tvla2_analyze.py 做二阶组合 TVLA / 二阶 CPA. 与 v4.0 (run_scea2.py) 形成
A/B 对照: 同一分析器, 同一探针节点, 仅引擎不同 (v4 -> v5.0).

预期: v5.0 tau×tau 二阶通道关闭 (独立逐字节掩码 decorrelate 跨字节联合分布).

用法:  python run_scea2_v5.py [--n 20000] [--out sim/scea2_dump_v5.txt]
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RTL = os.path.join(HERE, "rtl")
SIM = os.path.join(HERE, "sim")
ENG = os.path.normpath(os.path.join(HERE, "..", "rtl", "sm4",
                                    "sm4_engine_masked_v4_indep.v"))

IV = os.environ.get("IVERILOG", r"C:\iverilog\bin\iverilog.exe")
VVP = os.environ.get("VVP", r"C:\iverilog\bin\vvp.exe")

KAT = "681EDF34D206965E86B3E94F536E4246"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=20261026)
    ap.add_argument("--out", default=os.path.join(SIM, "scea2_dump_v5.txt"))
    a = ap.parse_args()

    os.makedirs(SIM, exist_ok=True)
    vvp = os.path.join(SIM, "tb_scea2_v5.vvp")
    cmd = [IV, "-g2005", "-o", vvp,
           os.path.join(RTL, "tb_scea2_masked_v5.v"), ENG]
    print("[build]", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8",
                       errors="replace", timeout=600)
    if r.returncode != 0:
        print("[ERR] iverilog failed:\n" + (r.stderr or "") + (r.stdout or ""))
        return 1
    print("[build] OK ->", vvp)

    base = os.path.basename(os.path.abspath(a.out))
    cmd = [VVP, vvp,
           "+N_FIX=%d" % a.n, "+N_RND=%d" % a.n,
           "+SEED=%d" % a.seed,
           "+OUTF=" + base]
    print("[sim]", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8",
                       errors="replace", timeout=3600, cwd=SIM)
    print("    rc=%d" % r.returncode)
    for l in (r.stdout or "").splitlines():
        if l.strip():
            print("    |", l[:140])
    if r.returncode != 0:
        print("[ERR] simulation rc != 0")
        return 1

    produced = os.path.join(SIM, base)
    out = os.path.abspath(a.out)
    if produced != out:
        os.replace(produced, out)
    if not os.path.exists(out):
        print("[ERR] dump missing:", out)
        return 1
    with open(out, encoding="utf-8") as f:
        lines = [l for l in f.read().splitlines() if l.startswith("T ")]
    print("[dump] %d lines -> %s (%d bytes)" %
          (len(lines), out, os.path.getsize(out)))
    if len(lines) != 2 * a.n:
        print("[ERR] line count %d != %d" % (len(lines), 2 * a.n))
        return 1
    ok_kat = ("expect=" + KAT) in (r.stdout or "")
    print("[xcheck] SM4 KAT =", "PASS" if ok_kat else "MISSING (check log)")
    print("RESULT: ", "PASS" if ok_kat else "FAIL")
    return 0


if __name__ == "__main__":
    sys.exit(main())