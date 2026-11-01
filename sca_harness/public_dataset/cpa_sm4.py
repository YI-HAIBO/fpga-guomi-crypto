#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cpa_sm4.py -- SM4 第 1 轮 CPA (相关能量分析)

目标: SM4 第 1 轮 S-box 输入字 = X1^X2^X3^rk0 (4 个并联 S-box 各处理一个字节)。
由于无预白化, 无法像 AES 那样用 pt^key; 正确打法是对 **rk0 逐字节猜测**:
    byte_b(S-box输入) = byte_b(X1)^byte_b(X2)^byte_b(X3) ^ byte_b(rk0)
    假设 h = HW( SBOX[ byte_b(X1^X2^X3) ^ guess ] )
对每个 guess (0..255) 计算 h 与功耗trace 的相关, 取 |corr| 峰值。正确 guess 的
峰值显著高出 -> 逐字节恢复 rk0 (再反推主密钥, 属确定性步骤)。

泄漏模型用汉明权重 (HW), 是硬件最常用的一阶模型。

用法:
  python cpa_sm4.py data/synth_leaky            # 攻击全部 4 字节
  python cpa_sm4.py data/synth_leaky --ge       # 额外画 GE vs traces
输出: 恢复的 rk0 / 是否正确 / 各字节峰值; --ge 时存 ge_vs_traces.png
"""
import os
import json
import argparse
import numpy as np

import sm4_ref as ref

SBOX = np.array(ref.SBOX, dtype=np.uint32)

# 每采样周期内的监控节点数; SCEA 逐字节节点模式下 >1。
# 用于把 CPA 假设只对齐到目标字节自己的节点通道。
_NNODE = 1
_PLOT = True


def _hw_arr(x):
    x = np.asarray(x, dtype=np.uint32)
    c = np.zeros_like(x)
    for b in range(32):
        c += (x >> b) & 1
    return c.astype(np.float64)


def _std_rows(a):
    """按列(采样点)标准化 traces -> 零均值单位方差, 便于点积求相关。"""
    m = a.mean(axis=0, keepdims=True)
    s = a.std(axis=0, keepdims=True)
    s[s == 0] = 1.0
    return (a - m) / s


def sbox_in_known(pts):
    """每条 trace 的 byte_b(X1^X2^X3) (rk0 之前的已知部分), 返回 [N,4] uint32。"""
    n = pts.shape[0]
    out = np.zeros((n, 4), dtype=np.uint32)
    for i in range(n):
        pt = ref.bytes_to_int(pts[i])
        X = [(pt >> (32 * (3 - j))) & 0xFFFFFFFF for j in range(4)]
        w = X[1] ^ X[2] ^ X[3]
        for b in range(4):
            out[i, b] = (w >> (8 * (3 - b))) & 0xFF
    return out


def attack_byte(Zt, known_b, n_use, node=-1):
    """攻击 rk0 的一个字节。返回 peaks[256], best_guess。Zt 已标准化 [N,nsamp]。

    node: SCEA 逐字节节点索引 (0..7); <0 表示用全部采样点。用于把假设只
    对齐到"自己那一字节"的监控通道, 消除另外 3 个字节带来的无关波动。
    """
    sub = known_b[:n_use]
    Zsub = Zt[:n_use]
    if 0 <= node and _NNODE > 0 and Zsub.shape[1] % _NNODE == 0:
        # SCEA 逐周期采样: 每周期 NNODE 个节点, node 号 = 采样索引 % NNODE
        Zsub = Zsub[:, np.arange(Zsub.shape[1]) % _NNODE == node]
    peaks = np.zeros(256)
    for g in range(256):
        h = _hw_arr(SBOX[(sub ^ np.uint32(g)) & 0xFF])  # [n_use]
        hs = h.std()
        if hs == 0:
            peaks[g] = 0.0
            continue
        hz = (h - h.mean()) / hs
        corr = np.abs(hz @ Zsub) / n_use  # [nsamples]
        peaks[g] = corr.max()
    best = int(np.argmax(peaks))
    return peaks, best


def load(d):
    global _NNODE
    tr = np.load(os.path.join(d, "traces.npy")).astype(np.float64)
    pts = np.load(os.path.join(d, "pts.npy"))
    meta = json.load(open(os.path.join(d, "meta.json"), encoding="utf-8"))
    _NNODE = int(meta.get("nnode", 1))
    return tr, pts, meta


def run(d, do_ge=False, tau_node=True, shuffle=False, shuffle_seed=20261025):
    tr, pts, meta = load(d)
    if shuffle:
        # trace 顺序打乱: 相关值本身与顺序无关, 但 GE-vs-N 用的"前 N 条"子集
        # 会受顺序影响 —— 若固定组集中在前 500 条, 则 N<=500 时所有假设值在
        # 子集内为常数 -> 全部 peaks=0 -> true byte 被并列 rank 1 (伪 GE=1)。
        # 打乱后每个前 N 子集都混合 fixed/random, GE 曲线才有意义。
        rng = np.random.default_rng(shuffle_seed)
        perm = rng.permutation(tr.shape[0])
        tr = tr[perm]
        pts = pts[perm]
    key = ref.bytes_to_int(bytes.fromhex(meta["key"]))
    rk0 = ref.key_schedule(key)[0]
    true_bytes = [(rk0 >> (8 * (3 - b))) & 0xFF for b in range(4)]

    Zt = _std_rows(tr)
    known = sbox_in_known(pts)
    n = tr.shape[0]

    print("=== CPA on SM4 round-1 S-box : %s ===" % d)
    print("  traces %s | true rk0 = %08X | nodes/cycle=%d"
          % (tr.shape, rk0, _NNODE))
    recovered = []
    all_ok = True
    for b in range(4):
        # 逐字节节点模式: TB 采样顺序为
        #   node 0..3 = cipher_xors[31:24],[23:16],[15:8],[7:0]
        #   node 4..7 = cipher_tau [31:24],[23:16],[15:8],[7:0]
        # 而 known[:,b] = byte_b 于 (W >> 24) 方向, b=0 为最高字节。
        # 故字节 b 的 S-box 输出在 node 4+b。
        # 已两次验证: 固定组 HW 常量逐字节比对; resolve_node_map.py 对照
        # CPA (4+b -> 4/4 字节正确, 4+(3-b) -> 0/4)。不要改成 4+(3-b)。
        node = 4 + b if (tau_node and _NNODE > 1) else -1
        peaks, best = attack_byte(Zt, known[:, b], n, node=node)
        ok = (best == true_bytes[b])
        all_ok &= ok
        recovered.append(best)
        order = np.argsort(peaks)[::-1]
        gap = peaks[order[0]] - peaks[order[1]]
        print("  rk0 byte%d : recovered=%02X true=%02X %s  (peak=%.3f, 2nd=%.3f, gap=%.3f)"
              % (b, best, true_bytes[b], "OK" if ok else "WRONG",
                 peaks[order[0]], peaks[order[1]], gap))
    rec_rk0 = (recovered[0] << 24) | (recovered[1] << 16) | \
              (recovered[2] << 8) | recovered[3]
    print("  recovered rk0 = %08X  ->  %s" %
          (rec_rk0, "FULL KEY RECOVERED" if all_ok else "not fully recovered"))

    if do_ge:
        b = 0
        known_b = known[:, b]
        node = 4 + b if (tau_node and _NNODE > 1) else -1
        sched = [25, 50, 100, 200, 500, 1000, 2000, n]
        sched = sorted(set(min(s, n) for s in sched if s <= n))
        ges, xs = [], []
        for m in sched:
            peaks, best = attack_byte(Zt, known_b, m, node=node)
            rank = int((peaks > peaks[true_bytes[b]]).sum()) + 1
            ges.append(rank)
            xs.append(m)
        print("  GE vs traces (rk0 byte0):",
              ", ".join("N=%d:GE=%d" % (x, g) for x, g in zip(xs, ges)))
        if not _PLOT:
            print("  (plot skipped: --no-plot)")
            return all_ok
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            fig, ax = plt.subplots(figsize=(5, 3.2))
            ax.plot(xs, ges, "o-", color="#d62728")
            ax.set_xscale("log")
            ax.set_xlabel("traces (N)")
            ax.set_ylabel("guessing entropy (rank of true key)")
            ax.set_title("CPA GE vs traces  %s" % os.path.basename(d))
            ax.grid(True, ls=":", lw=0.5)
            fig.tight_layout()
            out = os.path.join(d, "ge_vs_traces.png")
            fig.savefig(out, dpi=130)
            print("  saved", out)
        except Exception as e:
            print("  (plot skipped:", type(e).__name__, e, ")")
    return all_ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("--ge", action="store_true")
    ap.add_argument("--no-plot", action="store_true",
                    help="跳过 matplotlib 绘图")
    ap.add_argument("--all-nodes", action="store_true",
                    help="忽略逐字节节点通道, 用全部采样点 (SCEA 旧格式)")
    ap.add_argument("--shuffle", action="store_true",
                    help="打乱 trace 顺序再攻击 (相关值不变, 但让 GE-vs-N 的"
                         "前 N 子集混合 fixed/random, 避免 N<=500 时全部假设"
                         "恒定造成的伪 GE=1)")
    a = ap.parse_args()
    if a.no_plot:
        global _PLOT
        _PLOT = False
    run(a.data, do_ge=a.ge, tau_node=not a.all_nodes, shuffle=a.shuffle)


if __name__ == "__main__":
    main()
