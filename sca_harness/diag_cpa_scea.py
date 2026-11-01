#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
diag_cpa_scea.py -- 用解析后的 dump 做受控 CPA 对照实验。

目的: 判定"CPA 不恢复密钥"是方法学问题、样本量问题, 还是信噪比问题。
做法: 对同一份仿真 dump (确定性 HW 模型, 零测量噪声) 按不同噪声 sigma /
不同 trace 子集 / 不同 trace 分组做 CPA, 看 rk0 的真字节 rank 如何变化。

S-box 输入字 = X1^X2^X3^rk0, 每字节独立。cipher_tau 的字节节点:
    node 4 = cipher_tau[24:16] -> 目标字节 b=3 (最高)
    node 5 = cipher_tau[16:8]  -> b=2
    node 6 = cipher_tau[8:0]   -> b=1
    node 7 = cipher_tau[0]     -> b=0
采样索引 i 的节点号 = i % NNODE。
"""
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sm4_ref as ref

SBOX = np.array(ref.SBOX, dtype=np.uint32)
DUMP = (r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto"
        r"\sca_harness\sim\scea_dump.txt")
D = r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto\sca_harness"


def load_dump(path):
    rows, pts, lab = [], [], []
    for line in open(path, encoding="utf-8"):
        p = line.split()
        if not p or p[0] != "T" or len(p) < 5:
            continue
        rows.append([int(x) for x in p[4:]])
        pts.append(bytes.fromhex(p[3]))
        lab.append(int(p[2]))
    return (np.array(rows, float),
            np.array([list(b) for b in pts], np.uint8),
            np.array(lab, np.uint8))


def known_bytes(pts):
    """byte_b(X1^X2^X3), b=0 为最高字节 (w >> 24)。"""
    out = np.zeros((pts.shape[0], 4), np.uint32)
    for i in range(pts.shape[0]):
        p = ref.bytes_to_int(pts[i])
        X = [(p >> (32 * (3 - j))) & 0xFFFFFFFF for j in range(4)]
        w = X[1] ^ X[2] ^ X[3]
        for b in range(4):
            out[i, b] = (w >> (8 * (3 - b))) & 0xFF
    return out


def hw_byte(v):
    """v: [N] uint8 -> [N] float64 汉明权重。"""
    v = np.asarray(v, np.uint8).astype(np.uint32)
    c = np.zeros(v.shape, np.float64)
    for b in range(8):
        c += (v >> b) & 1
    return c


def cpa_byte(Z, known_b, n, node, nnode):
    """在 node 通道的全部周期上搜索峰值。返回 (peaks[256], best_guess)。"""
    cols = np.arange(Z.shape[1])
    Zi = Z[:n, cols % nnode == node]
    sub = known_b[:n].astype(np.uint8)
    # HW(SBOX[sub ^ g]) for all g: [N, 256]
    svals = SBOX[(sub[:, None] ^ np.arange(256, dtype=np.uint32)) & 0xFF]
    H = hw_byte(svals)                        # [N, 256]
    m = H.mean(0, keepdims=True)
    s = H.std(0, keepdims=True)
    peaks = np.zeros(256)
    valid = s[0] > 0
    Hn = np.zeros_like(H)
    Hn[:, valid] = (H[:, valid] - m[0, valid]) / s[0, valid]
    C = np.abs(Zi.T @ Hn) / n                 # [nsamp, 256]
    peaks = C.max(0)
    return peaks, int(np.argmax(peaks))


def main():
    tr, pts, lab = load_dump(DUMP)
    NNODE = 8
    NSAMP_C = 72
    key = ref.bytes_to_int(bytes.fromhex("0123456789ABCDEFFEDCBA9876543210"))
    rk0 = ref.key_schedule(key)[0]
    true_b = [(rk0 >> (8 * (3 - b))) & 0xFF for b in range(4)]
    known = known_bytes(pts)
    n_fix = int((lab == 0).sum())
    print("dump: traces=%s fix=%d rnd=%d | rk0=%08X bytes=%s"
          % (tr.shape, n_fix, lab.sum(), rk0,
             ["%02X" % x for x in true_b]))

    # 固定组的 S-box 输入是否真的常量? 这是 CPA 在固定组上可行的前提
    print("\n[1] 固定组 S-box 输入常量性 (第 1 轮, 全部固定 trace 同值):")
    for b in range(4):
        u = np.unique(known[:n_fix, b])
        print("    b%d: 唯一值 %d 个 -> %s"
              % (b, len(u), ["%02X" % x for x in u][:4]))
        if len(u) == 1:
            gw = u[0] ^ true_b[b]
            print("        对应 S-box 输入 = %02X -> HW(SBOX)=%d (常量)"
                  % (gw, bin(int(SBOX[gw])).count("1")))

    def std_rows(t):
        m = t.mean(0, keepdims=True)
        s = t.std(0, keepdims=True)
        s[s == 0] = 1.0
        return (t - m) / s

    rng = np.random.default_rng(20261025)
    idx_rnd = np.arange(n_fix, tr.shape[0])

    print("\n[2] 仅随机组 CPA (假设方差非零, CPA 的正确用法), 逐 sigma 扫描:")
    print("    sigma   %6s %6s %6s %6s | %s"
          % ("b0/F1", "b1/21", "b2/86", "b3/F9", "true rank"))
    for sigma in [0.0, 0.2, 0.5, 1.0, 2.0]:
        t = tr[idx_rnd] + rng.normal(0, sigma, tr[idx_rnd].shape)
        line = ["%6.1f" % sigma]
        for b in range(4):
            pk, best = cpa_byte(std_rows(t), known[idx_rnd, b],
                                t.shape[0], 4 + b, NNODE)
            line.append("%6X" % best)
        pk0, _ = cpa_byte(std_rows(t), known[idx_rnd, 0],
                          t.shape[0], 4, NNODE)
        r0 = int((pk0 > pk0[true_b[0]]).sum()) + 1
        print("    " + " ".join(line) + " | b0 rank=%d/256" % r0)

    print("\n[3] GE vs traces (仅随机组, sigma=0.5, b0/节点4):")
    t = tr[idx_rnd] + rng.normal(0, 0.5, tr[idx_rnd].shape)
    Z = std_rows(t)
    for n in [50, 100, 200, 400, 500]:
        pk, best = cpa_byte(Z, known[idx_rnd, 0], n, 4, NNODE)
        r = int((pk > pk[true_b[0]]).sum()) + 1
        print("    N=%-4d best=%02X true=%02X rank=%d"
              % (n, best, true_b[0], r))

    print("\n[4] 固定组 CPA 为何无意义 (S-box 输入常量 -> 假设方差为 0):")
    Zf = std_rows(tr[:n_fix])
    for b in range(4):
        pk, best = cpa_byte(Zf, known[:n_fix, b], n_fix, 4 + b, NNODE)
        print("    b%d: 有效假设数=%d/256 (peak 全 0 -> argmax 无意义)"
              % (b, int((pk > 0).sum())))



if __name__ == "__main__":
    main()
