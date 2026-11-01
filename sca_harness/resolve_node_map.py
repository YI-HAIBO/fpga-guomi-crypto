#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
resolve_node_map.py -- 一次性裁定"落盘列号 % 8 与明文字节"的正确对应关系。

背景: cpa_sm4.py / gen_scea_traces.py / diag_cpa_scea.py 三处曾出现 4+b 与
4+(3-b) 两种写法, 来源是 tb_scea.v 的 $fwrite 循环 si 从高到低走, 而每周期
8 个 HW 样本又打包在移位串里, 所以落盘列号并非 RTL tap 的原始顺序。
靠推导极易出错, 本脚本直接对每个字节在两种候选通道上各做一次 CPA, 看哪种
映射能同时恢复 4 个字节的真值, 以实验结论定案。

判据: 仅用随机明文组 (S-box 输入有方差, CPA 才有效), sigma=0.5 注入噪声,
全 500 条, 在候选通道的所有 72 个周期上搜索峰值。

用法:  python resolve_node_map.py
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sm4_ref as ref

HERE = os.path.dirname(os.path.abspath(__file__))
DUMP = os.path.join(HERE, "sim", "scea_dump.txt")
KEY_HEX = "0123456789ABCDEFFEDCBA9876543210"
NNODE = 8
SIGMA = 0.5
SEED = 20261025

SBOX = np.array(ref.SBOX, dtype=np.uint32)


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
    """byte_b(X1^X2^X3), b=0 为最高字节 (W >> 24)。"""
    out = np.zeros((pts.shape[0], 4), np.uint32)
    for i in range(pts.shape[0]):
        p = ref.bytes_to_int(pts[i])
        X = [(p >> (32 * (3 - j))) & 0xFFFFFFFF for j in range(4)]
        w = X[1] ^ X[2] ^ X[3]
        for b in range(4):
            out[i, b] = (w >> (8 * (3 - b))) & 0xFF
    return out


def hw_mat(mat):
    """mat: uint8/uint32 数组 -> 同形状 float64 汉明权重。"""
    v = np.asarray(mat, np.uint32)
    c = np.zeros(v.shape, np.float64)
    for i in range(8):
        c += (v >> i) & 1
    return c


def std_rows(t):
    m = t.mean(0, keepdims=True)
    s = t.std(0, keepdims=True)
    s[s == 0] = 1.0
    return (t - m) / s


def main():
    tr, pts, lab = load_dump(DUMP)
    n_fix = int((lab == 0).sum())
    idx = np.arange(n_fix, tr.shape[0])            # 仅随机组
    key = ref.bytes_to_int(bytes.fromhex(KEY_HEX))
    rk0 = ref.key_schedule(key)[0]
    true_b = [(rk0 >> (8 * (3 - b))) & 0xFF for b in range(4)]

    print("dump        : %s" % DUMP)
    print("traces      : %s (random subset n=%d)" % (tr.shape, len(idx)))
    print("rk0         : %08X  bytes b0..b3 = %s (b0 = 最高字节)"
          % (rk0, ["%02X" % x for x in true_b]))
    print("sigma       : %.1f   node candidates: 4+b  vs  4+(3-b)" % SIGMA)

    rng = np.random.default_rng(SEED)
    t = tr[idx] + rng.normal(0, SIGMA, tr[idx].shape)
    known = known_bytes(pts)

    cols = np.arange(t.shape[1])
    Z = std_rows(t)
    print("\n%-4s %-10s %-10s | %-10s %-10s"
          % ("byte", "node=4+b", "node=4+(3-b)", "true", "verdict"))
    ok_pos = ok_rev = 0
    for b in range(4):
        sub = known[idx, b]
        svals = SBOX[(sub[:, None] ^ np.arange(256, dtype=np.uint32)) & 0xFF]
        H = hw_mat(svals)
        hm = H.mean(0, keepdims=True)
        hs = H.std(0, keepdims=True)
        valid = hs[0] > 0
        Hn = np.zeros_like(H)
        Hn[:, valid] = (H[:, valid] - hm[0, valid]) / hs[0, valid]

        res = {}
        for tag, node in (("4+b", 4 + b), ("4+(3-b)", 4 + (3 - b))):
            Zi = Z[:, cols % NNODE == node]
            C = np.abs(Zi.T @ Hn) / len(idx)          # [nsamp, 256]
            peaks = C.max(0)
            res[tag] = int(np.argmax(peaks))
        good = [tag for tag in res if res[tag] == true_b[b]]
        if "4+b" in good and "4+(3-b)" in good:
            verdict = "TIE"
        elif "4+b" in good:
            verdict = "4+b"
            ok_pos += 1
        elif "4+(3-b)" in good:
            verdict = "4+(3-b)"
            ok_rev += 1
        else:
            verdict = "NEITHER"
        print("%-4d %-10d %-10d | %-10X %-10s"
              % (b, 4 + b, 4 + (3 - b), true_b[b], verdict))

    print("\n=> 4+b      : %d/4 bytes correct" % ok_pos)
    print("=> 4+(3-b)  : %d/4 bytes correct" % ok_rev)
    if ok_rev == 4 and ok_pos == 0:
        print("=> 结论: 落盘列 % 8 == 4+(3-b) 是正确映射 (b=0 最高字节 -> 列 4)")
    elif ok_pos == 4 and ok_rev == 0:
        print("=> 结论: 落盘列 % 8 == 4+b 是正确映射 (b=0 最高字节 -> 列 4)")
    else:
        print("=> 结论: 无法唯一裁定, 需检查 dump 列顺序与 tap 打包方式")


if __name__ == "__main__":
    main()
