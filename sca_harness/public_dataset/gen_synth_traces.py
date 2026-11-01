#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_synth_traces.py -- 合成功耗 trace 生成器 (用于验证 TVLA/CPA 分析脚本)

两种设备模型:
  leaky  : 未掩码设备。第 1 轮 S-box 输出字节 z=S(pt^k) 的汉明权重直接泄漏到
           功耗采样点: trace[leak_idx] += A*HW(z)。固定明文集 z 恒定, 随机明文集
           z 变化 -> TVLA 的 |t| 在 leak_idx 处爆表; CPA 可恢复密钥。
  masked : 一阶掩码设备。该采样点只泄漏 share 的汉明权重 (share 与 z 独立的均匀
           随机数) -> 固定/随机两组分布相同 -> |t|<4.5; CPA 相关度趋 0, 无法恢复。

真实采集的 trace 也用同一目录格式 (traces.npy/pts.npy/labels.npy/meta.json),
因此分析脚本对合成与真实数据一视同仁。

用法:
  python gen_synth_traces.py --model leaky  --n 5000 --out data/synth_leaky
  python gen_synth_traces.py --model masked --n 5000 --out data/synth_masked
"""
import os
import json
import argparse
import numpy as np

import sm4_ref as ref


def hw(x):
    """汉明权重 (numpy 向量化)。"""
    x = np.asarray(x, dtype=np.uint32)
    c = np.zeros_like(x)
    for b in range(32):
        c += (x >> b) & 1
    return c.astype(np.float64)


def gen(model, n_fixed, n_random, nsamples, key, leak_idx=None, amp=1.0,
        noise=1.0, seed=0):
    """生成一个数据集。返回 dict(traces, pts, labels, meta)。"""
    rng = np.random.default_rng(seed)
    n = n_fixed + n_random
    if leak_idx is None:
        leak_idx = nsamples // 2

    pts = np.zeros((n, 16), dtype=np.uint8)
    labels = np.zeros(n, dtype=np.uint8)  # 0 = fixed set, 1 = random set
    # 固定明文集用标准测试向量的一个变体 (常量), 随机集用随机明文
    fixed_pt = np.arange(16, dtype=np.uint8)
    pts[:n_fixed] = fixed_pt
    labels[:n_fixed] = 0
    pts[n_fixed:] = rng.integers(0, 256, size=(n_random, 16), dtype=np.uint8)
    labels[n_fixed:] = 1

    # 第 1 轮 S-box 输入 = X1^X2^X3^rk0 ; 输出过 tau。取 byte0 (最高字节) 为目标。
    rk = ref.key_schedule(key)
    rk0 = rk[0]
    key_bytes = [(key >> (8 * (15 - i))) & 0xFF for i in range(16)]  # pt 同序

    traces = rng.normal(0.0, noise, size=(n, nsamples)).astype(np.float64)
    # 叠加一点与明文无关的结构基线, 让波形看起来更真实 (对两组相同, 不影响 t)
    base = rng.normal(0.0, 0.5, size=nsamples)
    traces += base[None, :]

    meta = dict(model=model, n_fixed=n_fixed, n_random=n_random,
                nsamples=nsamples, leak_idx=leak_idx, amp=amp, noise=noise,
                key="%032X" % key, rk0="%08X" % rk[0],
                target_word_bytes=[0, 1, 2, 3], seed=seed)

    if model == "leaky":
        # SM4 第 1 轮 S-box 输入字 = X1^X2^X3^rk0, 4 个并联 S-box 各处理一个字节。
        # 未掩码设备: 4 个 S-box 输出字节的汉明权重分别泄漏到 4 个采样点。
        stride = max(1, nsamples // 16)
        idxs = [leak_idx + b * stride for b in range(4)]
        for i in range(n):
            pt_int = ref.bytes_to_int(pts[i])
            X = [(pt_int >> (32 * (3 - j))) & 0xFFFFFFFF for j in range(4)]
            z = ref._tau(X[1] ^ X[2] ^ X[3] ^ rk0)  # 32-bit S-box 输出
            for b in range(4):
                z_byte = (z >> (8 * (3 - b))) & 0xFF
                traces[i, idxs[b]] += amp * bin(z_byte).count("1")
        meta["leak_idxs"] = idxs
    elif model == "masked":
        # 一阶掩码: 4 个采样点各泄漏与密钥/明文独立的均匀随机 share 的汉明权重
        stride = max(1, nsamples // 16)
        idxs = [leak_idx + b * stride for b in range(4)]
        for b in range(4):
            share = rng.integers(0, 256, size=n, dtype=np.uint8)
            hws = np.array([bin(int(s)).count("1") for s in share],
                           dtype=np.float64)
            traces[:, idxs[b]] += amp * hws
        meta["leak_idxs"] = idxs
    else:
        raise ValueError("unknown model %r" % model)

    return dict(traces=traces, pts=pts, labels=labels, meta=meta)


def save(d, out):
    os.makedirs(out, exist_ok=True)
    np.save(os.path.join(out, "traces.npy"), d["traces"])
    np.save(os.path.join(out, "pts.npy"), d["pts"])
    np.save(os.path.join(out, "labels.npy"), d["labels"])
    with open(os.path.join(out, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(d["meta"], f, indent=2, ensure_ascii=False)
    print("saved dataset ->", out, "traces", d["traces"].shape)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=["leaky", "masked"], required=True)
    ap.add_argument("--n", type=int, default=5000, help="per set (fixed/random)")
    ap.add_argument("--nsamples", type=int, default=2000)
    ap.add_argument("--amp", type=float, default=1.0)
    ap.add_argument("--noise", type=float, default=1.0)
    ap.add_argument("--key", default="0123456789ABCDEFFEDCBA9876543210")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    key = ref.bytes_to_int(bytes.fromhex(a.key))
    d = gen(a.model, a.n, a.n, a.nsamples, key, amp=a.amp, noise=a.noise,
            seed=a.seed)
    save(d, a.out)


if __name__ == "__main__":
    main()
