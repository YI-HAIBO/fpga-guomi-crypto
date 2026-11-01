#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""diag_v4_leak.py -- 定位 v4 SCEA 残余泄漏的统计诊断

读 sim/scea_dump_masked_v4.txt (无噪声原始 HW), 对每个采样点算 Welch t,
打印 top-15 及其 fixed/random 均值, 并按节点号(cycle 内偏移)汇总。
"""
import sys
import numpy as np

def load(path):
    tr, lb = [], []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            p = line.split()
            if not p or p[0] != "T":
                continue
            tr.append([int(x) for x in p[4:]])
            lb.append(int(p[2]))
    return np.array(tr, dtype=np.float64), np.array(lb, dtype=np.uint8)

def welch_t(a, b):
    ma, mb = a.mean(), b.mean()
    va, vb = a.var(ddof=1), b.var(ddof=1)
    se = np.sqrt(va / len(a) + vb / len(b))
    return (ma - mb) / se if se > 0 else 0.0

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else \
        r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto\sca_harness\sim\scea_dump_masked_v4.txt"
    tr, lb = load(path)
    nsamp = tr.shape[1]
    nnode = 8
    print("traces=%s nsamp=%d  fixed=%d random=%d" % (
        tr.shape, nsamp, (lb == 0).sum(), (lb == 1).sum()))
    tvals = np.array([welch_t(tr[lb == 0][:, i], tr[lb == 1][:, i])
                      for i in range(nsamp)])
    order = np.argsort(-np.abs(tvals))
    print("\n-- top-15 |t| (无噪声原始 HW) --")
    for i in order[:15]:
        cyc, node = i // nnode, i % nnode
        print("  samp=%3d cyc=%2d node=%d  t=%+8.3f  fix_mean=%.3f rnd_mean=%.3f"
              % (i, cyc, node, tvals[i],
                 tr[lb == 0][:, i].mean(), tr[lb == 1][:, i].mean()))
    print("\n-- 按节点汇总: max|t| 与超过 4.5 的点数 --")
    for node in range(nnode):
        idx = np.arange(node, nsamp, nnode)
        tv = tvals[idx]
        print("  node %d (%s): max|t|=%.3f  #>4.5=%d" % (
            node, "t_in_b%d" % node if node < 4 else "tau_m_b%d" % (node - 4),
            np.abs(tv).max(), int((np.abs(tv) > 4.5).sum())))
    print("\n-- 全局: max|t|=%.3f  #>4.5=%d / %d" % (
        np.abs(tvals).max(), int((np.abs(tvals) > 4.5).sum()), nsamp))

if __name__ == "__main__":
    main()
