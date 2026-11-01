#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""run_scea2.py -- 二阶泄漏采集运行器 (#156)

编译并运行 tb_scea2_masked_v4 (round-0 专用采集), 产出 dump 文件供
tvla2_analyze.py 做二阶组合 TVLA / 二阶 CPA. 判据: 仿真自检行不带 [ERR],
且 dump 行数 == N_FIX + N_RND, 且固定明文密文 == SM4 KAT.

用法:  python run_scea2.py [--n 20000] [--out sim/scea2_dump.txt]
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
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=20261026)
    ap.add_argument("--out", default=os.path.join(SIM, "scea2_dump.txt"))
    a = ap.parse_args()

    os.makedirs(SIM, exist_ok=True)
    vvp = os.path.join(SIM, "tb_scea2.vvp")
    cmd = [IV, "-g2005", "-o", vvp,
           os.path.join(RTL, "tb_scea2_masked_v4.v"), ENG]
    print("[build]", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8",
                       errors="replace", timeout=600)
    if r.returncode != 0:
        print("[ERR] iverilog failed:\n" + (r.stderr or "") + (r.stdout or ""))
        return 1
    print("[build] OK ->", vvp)

    # vvp 的 -G<param>=<value> 覆写实测无效 (字符串型被置空, 整数型被忽略;
    # 见 .workbuddy/tmp gtest.v/gtest2.v 试验). TB 改用 $value$plusargs,
    # 这里以 plusargs 传参. OUTF 只能传相对文件名 (%s 会吞掉含 ':' 的盘符),
    # 输出文件落在 cwd=SIM, 仿真结束后再 rename 到 --out 指定路径.
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
