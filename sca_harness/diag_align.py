#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""诊断 scea2 dump: 对齐/掩码结构自检 (不修改数据)."""
import sys
import numpy as np

dump = sys.argv[1] if len(sys.argv) > 1 else \
    r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto\sca_harness\sim\scea2_dump.txt"

rows, labels, pts = [], [], []
for line in open(dump, encoding="utf-8"):
    p = line.split()
    if p and p[0] == "T":
        rows.append([int(x) for x in p[4:12]])
        labels.append(int(p[2]))
        pts.append(p[3])
X = np.array(rows, dtype=float)
lb = np.array(labels)
F, R = X[lb == 0], X[lb == 1]

print("traces F=%d R=%d" % (len(F), len(R)))
print("\n-- 逐节点均值/方差 --")
for n in range(8):
    nm = ("t_in[%d]" % n) if n < 4 else ("tau[%d]" % (n - 4))
    print("  %-9s F: mean=%.3f std=%.3f | R: mean=%.3f std=%.3f"
          % (nm, F[:, n].mean(), F[:, n].std(), R[:, n].mean(), R[:, n].std()))

print("\n-- tau x tau 二阶统计 (E[xi*xj], E[xi]*E[xj], cov) --")
for (i, j) in [(4, 5), (4, 6), (6, 7)]:
    for tag, D in (("F", F), ("R", R)):
        eij = (D[:, i] * D[:, j]).mean()
        ei, ej = D[:, i].mean(), D[:, j].mean()
        cov = (D[:, i] * D[:, j]).mean() - ei * ej
        print("  (%d,%d) %s: E[xi xj]=%.3f  E[xi]E[xj]=%.3f  cov=%+.4f  corr=%+.4f"
              % (i, j, tag, eij, ei * ej, cov,
                 cov / (D[:, i].std() * D[:, j].std())))

print("\n-- tin x tin 二阶统计 --")
for (i, j) in [(0, 1), (0, 2)]:
    for tag, D in (("F", F), ("R", R)):
        eij = (D[:, i] * D[:, j]).mean()
        ei, ej = D[:, i].mean(), D[:, j].mean()
        cov = eij - ei * ej
        print("  (%d,%d) %s: E[xi xj]=%.3f  cov=%+.4f  corr=%+.4f"
              % (i, j, tag, eij, cov, cov / (D[:, i].std() * D[:, j].std())))

print("\n-- 跨 trace 检查: trace i 的节点 vs trace i-1 的明文是否相关 (stale 采样特征) --")
# 固定组里连续 trace 的 tau 相关性 (若采样到上一 trace 的值, 与本 trace 独立)
FF = F[:, 4:8]
print("  F 内相邻 trace tau[0] 相关: %+.4f"
      % np.corrcoef(FF[:-1, 0], FF[1:, 0])[0, 1])
# 若 tau 采样的是本 trace round0, 则 tau 与本 trace pt 一阶无关 (但二阶相关)
# 检查 stale: tau[0] HW 与 pt 第一字节 HW 的相关
hwpt = np.array([[bin(int(b, 16)).count("1") for b in p[0:8:2]] for p in pts])
print("  hw(pt[0]) 与 tau[0] 相关 (F): %+.4f"
      % np.corrcoef(hwpt[lb == 0, 0], F[:, 4])[0, 1])
