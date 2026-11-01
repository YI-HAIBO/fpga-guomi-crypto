#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_mrs_traces.py -- 频率注入→掩码退化→CPA 降效 仿真 trace 生成器 (Q1 核心贡献)

模型 (修正版 v2):
  硬件真实: trace = HW(SBOX(sub ^ rk0) ^ mout8_true)     ← 掩码始终生效
  攻击者模型: predict = HW(SBOX(sub ^ g) ^ mout8_guess)  ← 掩码知识随 alpha 变化

  alpha = 攻击者掩码知识度:
    alpha=0: mout8_guess 始终为均匀随机 (与 mout8_true 独立) -> CPA 不收敛 -> MRS=1.0
    alpha=1: mout8_guess = mout8_true (攻击者全知)         -> CPA 恢复   -> MRS=0.0
    中间值: 每条 trace 以 alpha 概率猜对掩码, (1-alpha) 概率猜错

  这个模型捕捉了频率注入攻击的核心:
    RO 被注入频率 -> 掩码可预测性上升 -> 攻击者掩码知识度 alpha 上升 -> CPA 降效

产出:
  对每个 alpha 生成 N 条 trace, 跑 TVLA + CPA, 产出 MRS 曲线数据。

用法:
  python gen_mrs_traces.py --alpha 0.0 --out data/mrs_a0
  python gen_mrs_traces.py --alpha 0.5 --out data/mrs_a05
  python run_mrs_sweep.py   # 扫全部 alpha
"""
import os
import json
import argparse
import numpy as np

import sm4_ref as ref

SBOX = np.array(ref.SBOX, dtype=np.uint32)


def hw_arr(x):
    x = np.asarray(x, dtype=np.uint32)
    c = np.zeros_like(x)
    for b in range(32):
        c += (x >> b) & 1
    return c.astype(np.float64)


def gen_degraded(n_fixed, n_random, nsamples, key, alpha, leak_idx=None,
                 amp=1.0, noise=1.0, seed=0):
    """生成掩码退化数据集。alpha = 攻击者掩码知识度 (0=零知识, 1=全知)。

    关键修正 (v2):
      - 硬件 trace 使用 mout8_true (真实掩码始终生效)
      - 攻击者 CPA 模型使用 mout8_guess (掩码知识随 alpha 变化)
      - 两者解耦 -> alpha 真正控制 CPA 可恢复性
    """
    rng = np.random.default_rng(seed)
    n = n_fixed + n_random
    if leak_idx is None:
        leak_idx = nsamples // 2

    # ---- 固定/随机明文分组 (TVLA 用) ----
    pts = np.zeros((n, 16), dtype=np.uint8)
    labels = np.zeros(n, dtype=np.uint8)
    fixed_pt = np.arange(16, dtype=np.uint8)
    pts[:n_fixed] = fixed_pt
    labels[:n_fixed] = 0
    pts[n_fixed:] = rng.integers(0, 256, size=(n_random, 16), dtype=np.uint8)
    labels[n_fixed:] = 1

    rk = ref.key_schedule(key)
    rk0 = rk[0]

    # ---- 噪声基底 ----
    traces = rng.normal(0.0, noise, size=(n, nsamples)).astype(np.float64)
    base = rng.normal(0.0, 0.5, size=nsamples)
    traces += base[None, :]

    # ---- 真实掩码 (硬件 always uses true mask) ----
    mout8_true = rng.integers(0, 256, size=n, dtype=np.uint8)

    # ---- 攻击者掩码猜测 (attacker knowledge, parameterized by alpha) ----
    # alpha=0: guess is always wrong (uniform random, independent of true)
    # alpha=1: guess is always correct (= true)
    correct_mask = rng.random(n) < alpha
    mout8_guess = np.where(correct_mask, mout8_true,
                            rng.integers(0, 256, size=n, dtype=np.uint8))

    # ---- 4 个并联 S-box: 硬件用 mout8_true, 攻击者用 mout8_guess ----
    stride = max(1, nsamples // 16)
    idxs = [leak_idx + b * stride for b in range(4)]

    for i in range(n):
        pt_int = ref.bytes_to_int(pts[i])
        X = [(pt_int >> (32 * (3 - j))) & 0xFFFFFFFF for j in range(4)]
        z = ref._tau(X[1] ^ X[2] ^ X[3] ^ rk0)  # 32-bit S-box 输出
        for b in range(4):
            z_byte = (z >> (8 * (3 - b))) & 0xFF
            # 硬件真实: 掩码用 mout8_true
            masked_z = z_byte ^ int(mout8_true[i])
            traces[i, idxs[b]] += amp * bin(masked_z).count("1")

    meta = dict(
        model="degraded_v2", alpha=alpha,
        n_fixed=n_fixed, n_random=n_random, nsamples=nsamples,
        leak_idx=leak_idx, amp=amp, noise=noise,
        key="%032X" % key, rk0="%08X" % rk[0],
        target_word_bytes=[0, 1, 2, 3], seed=seed,
        leak_idxs=idxs,
        mout8_true=mout8_true.tolist(),
        mout8_guess=mout8_guess.tolist(),
        attack_knowledge=float(alpha),
    )

    return dict(traces=traces, pts=pts, labels=labels, meta=meta)


def save(d, out):
    os.makedirs(out, exist_ok=True)
    np.save(os.path.join(out, "traces.npy"), d["traces"])
    np.save(os.path.join(out, "pts.npy"), d["pts"])
    np.save(os.path.join(out, "labels.npy"), d["labels"])
    with open(os.path.join(out, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(d["meta"], f, indent=2, ensure_ascii=False)
    print("saved ->", out, "traces", d["traces"].shape,
          "alpha=%.2f" % d["meta"]["alpha"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--alpha", type=float, required=True)
    ap.add_argument("--n", type=int, default=5000)
    ap.add_argument("--nsamples", type=int, default=2000)
    ap.add_argument("--amp", type=float, default=1.0)
    ap.add_argument("--noise", type=float, default=1.0)
    ap.add_argument("--key", default="0123456789ABCDEFFEDCBA9876543210")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    key = ref.bytes_to_int(bytes.fromhex(a.key))
    d = gen_degraded(a.n, a.n, a.nsamples, key, a.alpha,
                    amp=a.amp, noise=a.noise, seed=a.seed)
    save(d, a.out)


if __name__ == "__main__":
    main()