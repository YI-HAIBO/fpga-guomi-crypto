#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run_mrs_sweep.py -- MRS 曲线扫描 (v2: 修正 CPA 掩码模型 + JSON 序列化)

对每个 alpha:
  1. 生成退化掩码 trace (gen_mrs_traces v2)
  2. 跑 TVLA (Welch t-test, fixed-vs-random)
  3. 跑 CPA (逐字节恢复 rk0, GE-vs-traces, 模型含 mout8_guess)
  4. 计算 MRS = 1 - P_CPA_success

CPA 模型 (v2 修正):
  trace[i] = HW(SBOX(sub[i] ^ rk0) ^ mout8_true[i])    ← 硬件真实
  predict[i,g] = HW(SBOX(sub[i] ^ g) ^ mout8_guess[i])  ← 攻击者模型
  当 alpha=1: mout8_guess = mout8_true -> 相关峰在 g=rk0 -> CPA 恢复
  当 alpha=0: mout8_guess 独立于 mout8_true -> 无相关 -> CPA 失败

产出:
  - data/mrs_aXX/ 每个 alpha 的 trace
  - data/mrs_curve.json 汇总
  - data/mrs_curve.png MRS 曲线图
"""
import os
import sys
import json
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'sca_harness'))

import gen_mrs_traces as gmr
import sm4_ref as ref

SBOX = np.array(ref.SBOX, dtype=np.uint32)


def hw_arr(x):
    x = np.asarray(x, dtype=np.uint32)
    c = np.zeros_like(x)
    for b in range(32):
        c += (x >> b) & 1
    return c.astype(np.float64)


def std_rows(a):
    m = a.mean(axis=0, keepdims=True)
    s = a.std(axis=0, keepdims=True)
    s[s == 0] = 1.0
    return (a - m) / s


def sbox_in_known(pts):
    """从明文计算 S-box 输入字节 (已知明文攻击)。"""
    n = pts.shape[0]
    out = np.zeros((n, 4), dtype=np.uint32)
    for i in range(n):
        pt = ref.bytes_to_int(pts[i])
        X = [(pt >> (32 * (3 - j))) & 0xFFFFFFFF for j in range(4)]
        w = X[1] ^ X[2] ^ X[3]
        for b in range(4):
            out[i, b] = (w >> (8 * (3 - b))) & 0xFF
    return out


def tvla_fixed_vs_random(traces, labels):
    """Welch t-test: fixed (label=0) vs random (label=1)。返回 max|t| 和泄漏点。"""
    fixed = traces[labels == 0]
    random = traces[labels == 1]
    n1, n2 = len(fixed), len(random)
    if n1 < 2 or n2 < 2:
        return 0.0, False, []

    max_t = 0.0
    leak_points = []
    for col in range(traces.shape[1]):
        a = fixed[:, col]
        b = random[:, col]
        va, vb = a.var(ddof=1), b.var(ddof=1)
        ma, mb = a.mean(), b.mean()
        se = np.sqrt(va / n1 + vb / n2)
        if se < 1e-12:
            continue
        t = abs(ma - mb) / se
        if t > max_t:
            max_t = t
        if t > 4.5:
            leak_points.append((col, float(t)))

    return max_t, max_t > 4.5, leak_points


def cpa_attack_masked(Zt, known, true_bytes, mout8_guess_arr, n_traces):
    """CPA 逐字节攻击 rk0 (掩码模型 v2)。

    攻击者模型: predict[i,g] = HW(SBOX(known[i,b] ^ g) ^ mout8_guess[i])
    trace[i] = HW(SBOX(known[i,b] ^ rk0) ^ mout8_true[i])

    当 mout8_guess 与 mout8_true 一致时, g=rk0 产生最大相关。
    """
    recovered = 0
    ge_dict = {}

    for b in range(4):
        sub = known[:n_traces, b]
        Zsub = Zt[:n_traces]
        mg = mout8_guess_arr[:n_traces, b].astype(np.uint32)
        peaks = np.zeros(256)
        for g in range(256):
            # 攻击者模型: HW(SBOX(sub ^ g) ^ mout8_guess)
            sbox_out = SBOX[(sub ^ np.uint32(g)) & 0xFF]
            h = hw_arr(sbox_out ^ mg)
            hs = h.std()
            if hs == 0:
                peaks[g] = 0.0
                continue
            hz = (h - h.mean()) / hs
            corr = np.abs(hz @ Zsub) / n_traces
            peaks[g] = corr.max()
        best = int(np.argmax(peaks))
        if best == true_bytes[b]:
            recovered += 1
        rank = int((peaks > peaks[true_bytes[b]]).sum()) + 1
        ge_dict[b] = rank

    return recovered, ge_dict


def run_single(alpha, n_per_set=5000, nsamples=2000, seed=42):
    """对单个 alpha 生成 trace → TVLA → CPA → MRS。"""
    out_dir = os.path.join(ROOT, 'sca_harness', 'data', 'mrs_a%02d' % int(alpha*100))
    os.makedirs(out_dir, exist_ok=True)

    # 1. 生成退化 trace
    d = gmr.gen_degraded(n_per_set, n_per_set, nsamples,
                         0x0123456789ABCDEFFEDCBA9876543210,
                         alpha=alpha, seed=seed)
    gmr.save(d, out_dir)

    tr = d['traces']
    pts = d['pts']
    labels = d['labels']
    meta = d['meta']

    # 2. TVLA
    max_t, leak_detected, leak_points = tvla_fixed_vs_random(tr, labels)

    # 3. CPA (掩码模型 v2)
    key = ref.bytes_to_int(bytes.fromhex(meta["key"]))
    rk0 = ref.key_schedule(key)[0]
    true_bytes = [(rk0 >> (8 * (3 - b))) & 0xFF for b in range(4)]

    Zt = std_rows(tr)
    known = sbox_in_known(pts)
    n = tr.shape[0]

    # 从 meta 构建 mout8_guess_arr (n x 4): 每个 S-box 用相同的 mout8_guess
    mout8_guess_1d = np.array(meta["mout8_guess"], dtype=np.uint8)
    mout8_guess_arr = np.tile(mout8_guess_1d.reshape(-1, 1), (1, 4))

    # GE vs traces (byte 0)
    sched = [25, 50, 100, 200, 500, 1000, 2000, n]
    sched = sorted(set(min(s, n) for s in sched if s <= n))
    ge_vs_n = {}
    for m in sched:
        rec, ge_dict = cpa_attack_masked(Zt, known, true_bytes, mout8_guess_arr, m)
        ge_vs_n[m] = ge_dict[0]

    # Full CPA
    rec_full, _ = cpa_attack_masked(Zt, known, true_bytes, mout8_guess_arr, n)

    # 4. MRS
    if rec_full >= 4:
        mrs = 0.0
    elif rec_full == 0:
        mrs = 1.0
    else:
        mrs = 1.0 - rec_full / 4.0

    result = dict(
        alpha=alpha,
        tvla_max_t=round(float(max_t), 4),
        tvla_leak=bool(leak_detected),       # ← numpy bool_ → Python bool
        tvla_leak_points=len(leak_points),
        cpa_recovered=int(rec_full),          # ← numpy int → Python int
        cpa_ge_byte0={str(k): int(v) for k, v in ge_vs_n.items()},
        mrs=round(float(mrs), 4),
    )

    print("  alpha=%.2f  TVLA max|t|=%.2f  leak=%s  CPA=%d/4  MRS=%.3f" % (
        alpha, result['tvla_max_t'], result['tvla_leak'],
        result['cpa_recovered'], result['mrs']))
    return result


def main():
    alphas = [round(x*0.1, 1) for x in range(11)]
    results = []

    print("=" * 70)
    print("MRS Curve Sweep v2: frequency injection -> mask degradation -> CPA")
    print("  (CPA model includes mout8_guess per trace)")
    print("=" * 70)

    for a in alphas:
        print("alpha=%.1f:" % a, end=" ")
        r = run_single(a)
        results.append(r)

    # 汇总
    summary = dict(
        description="Mask Residual Strength vs Injection Amplitude (simulation v2)",
        method=("alpha = attacker mask knowledge per trace; "
                "0=uniform random guess, 1=always correct"),
        alphas=[float(r['alpha']) for r in results],
        mrs=[float(r['mrs']) for r in results],
        tvla_max_t=[float(r['tvla_max_t']) for r in results],
        cpa_recovered=[int(r['cpa_recovered']) for r in results],
        details=results,
    )

    data_dir = os.path.join(ROOT, 'sca_harness', 'data')
    out_path = os.path.join(data_dir, 'mrs_curve.json')
    with open(out_path, 'w', encoding='utf-8') as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)

    print("\n" + "=" * 70)
    print("MRS Curve Summary:")
    print("-" * 60)
    print("  alpha   MRS     TVLA max|t|   CPA/4   GE@N=1000")
    print("  -----   -----   ------------   ------   ---------")
    for r in results:
        ge1000 = r['cpa_ge_byte0'].get('1000', 'N/A')
        print("  %.1f     %.3f   %11.2f   %d/4      %s" % (
            r['alpha'], r['mrs'], r['tvla_max_t'],
            r['cpa_recovered'], ge1000))
    print("-" * 60)
    print("Saved ->", out_path)

    # 临界 alpha
    mrs_arr = np.array(summary['mrs'])
    alphas_arr = np.array(summary['alphas'])
    crit_idx = np.where(mrs_arr < 0.5)[0]
    if len(crit_idx) > 0:
        crit_alpha = alphas_arr[crit_idx[0]]
        print("\nCritical alpha (MRS drops below 0.5): %.1f" % crit_alpha)
    else:
        print("\nCritical alpha: not reached")

    # 画图
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10, 4))

        # MRS curve
        ax1.plot(alphas_arr, mrs_arr, "o-", color="#d62728", linewidth=2)
        ax1.set_xlabel("Injection amplitude (alpha)")
        ax1.set_ylabel("Mask Residual Strength")
        ax1.set_title("MRS vs Frequency Injection")
        ax1.set_ylim(-0.05, 1.05)
        ax1.grid(True, ls=":", lw=0.5)
        ax1.axhline(0.5, color="gray", ls="--", lw=0.8)

        # TVLA max|t|
        tvla_arr = np.array(summary['tvla_max_t'])
        ax2.plot(alphas_arr, tvla_arr, "s-", color="#1f77b4", linewidth=2)
        ax2.set_xlabel("Injection amplitude (alpha)")
        ax2.set_ylabel("TVLA max |t|")
        ax2.set_title("Leakage Detection vs Injection")
        ax2.axhline(4.5, color="red", ls="--", lw=0.8, label="thresh=4.5")
        ax2.legend()
        ax2.grid(True, ls=":", lw=0.5)

        fig.tight_layout()
        out_fig = os.path.join(data_dir, 'mrs_curve.png')
        fig.savefig(out_fig, dpi=130)
        print("Saved ->", out_fig)
    except Exception as e:
        print("(plot skipped:", type(e).__name__, e, ")")


if __name__ == "__main__":
    main()