#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tvla_analyze.py -- 非特定/固定-随机 TVLA (Welch's t-test)

读入一个数据集目录 (gen_synth_traces.py 产出, 或真实采集的相同格式):
    traces.npy  [N, nsamples] float
    labels.npy  [N]          0 = fixed set (明文固定), 1 = random set (明文随机)
    meta.json

对每个采样点计算两组间的 Welch t 值:
    t = (mean_A - mean_B) / sqrt(var_A/NA + var_B/NB)

判据 (ISO/IEC 17825 惯例): 任一样本点 |t| > THRESH 即判一阶泄漏。
默认 THRESH = 4.5。

用法:
  python tvla_analyze.py data/synth_leaky
  python tvla_analyze.py data/synth_leaky --thresh 4.5 --no-plot
输出: 控制台摘要 + (可选) tvalue.png / tvalue.npy
"""
import os
import json
import argparse
import numpy as np


def welch_t(traces, labels):
    """返回每采样点的 Welch t 值 (数组, 长度 nsamples)。"""
    A = traces[labels == 0]
    B = traces[labels == 1]
    na, nb = A.shape[0], B.shape[0]
    ma, mb = A.mean(axis=0), B.mean(axis=0)
    va, vb = A.var(axis=0, ddof=1), B.var(axis=0, ddof=1)
    denom = np.sqrt(va / na + vb / nb)
    # 避免 0/0: 两组都无方差时 t=0
    denom[denom == 0] = 1e-12
    return (ma - mb) / denom


def load(d):
    tr = np.load(os.path.join(d, "traces.npy"))
    lb = np.load(os.path.join(d, "labels.npy"))
    meta = {}
    mp = os.path.join(d, "meta.json")
    if os.path.exists(mp):
        meta = json.load(open(mp, encoding="utf-8"))
    return tr, lb, meta


def analyze(d, thresh=4.5, plot=True, save_prefix=None):
    tr, lb, meta = load(d)
    t = welch_t(tr, lb)
    at = np.abs(t)
    peak = int(np.argmax(at))
    nfail = int((at > thresh).sum())
    verdict = "LEAK (fail)" if nfail > 0 else "NO-LEAK (pass)"
    print("=== TVLA (Welch t-test) : %s ===" % d)
    print("  traces %s | fixed=%d random=%d" %
          (tr.shape, int((lb == 0).sum()), int((lb == 1).sum())))
    print("  threshold |t| > %.2f" % thresh)
    print("  max|t| = %.3f at sample %d" % (at[peak], peak))
    print("  samples exceeding threshold: %d / %d" % (nfail, tr.shape[1]))
    if "leak_idx" in meta:
        print("  (synthetic leak_idx = %s)" % meta.get("leak_idx"))
    print("  VERDICT:", verdict)

    if save_prefix is None:
        save_prefix = os.path.join(d, "tvalue")
    np.save(save_prefix + ".npy", t)
    if plot:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            fig, ax = plt.subplots(figsize=(9, 3.2))
            ax.plot(t, lw=0.6, color="#1f77b4")
            ax.axhline(thresh, color="r", ls="--", lw=0.8)
            ax.axhline(-thresh, color="r", ls="--", lw=0.8)
            ax.set_xlabel("sample")
            ax.set_ylabel("t value")
            ax.set_title("TVLA %s  max|t|=%.2f @%d  -> %s" %
                         (os.path.basename(d), at[peak], peak, verdict))
            ax.set_ylim(-8, 8)
            fig.tight_layout()
            fig.savefig(save_prefix + ".png", dpi=130)
            print("  saved", save_prefix + ".png")
        except Exception as e:
            print("  (plot skipped:", type(e).__name__, e, ")")
    return dict(max_abs_t=float(at[peak]), peak=peak, nfail=nfail,
                verdict=verdict)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("--thresh", type=float, default=4.5)
    ap.add_argument("--no-plot", action="store_true")
    a = ap.parse_args()
    analyze(a.data, thresh=a.thresh, plot=not a.no_plot)


if __name__ == "__main__":
    main()
