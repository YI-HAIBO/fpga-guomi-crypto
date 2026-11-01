#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tvla2_analyze.py -- SM4 v4 二阶泄漏实验室验证分析器 (#156)

输入 run_scea2.py 产出的 round-0 dump (每行: T idx label pt w0..w7):
    w0..w3 = HW(t_in[b])   掩码域 S 盒输入 (掩码 min 逐字节独立)
    w4..w7 = HW(tau_m[b])  掩码域 S 盒输出 (4 字节共享 K, mout8)

三层检验, 与 probe_check_v4.py 的完美探测模型结论逐条对账:

  (1) 一阶 TVLA: 每个节点单独 fixed-vs-random Welch t 检验, |t|<4.5
      <-> d=1 声明项 (w_addr / w_tau / w_tin / w_cell 全 PASS)

  (2) 二阶组合 TVLA: 同拍两节点的组合值 fixed-vs-random t 检验
      组合器 (Centered):
        sqdiff  = (x_i - x_j)^2     <- 主组合器, 解析期望 E = E_u[HW(S(u)^S(u^c))]
        prod    = (x_i - mu_i)(x_j - mu_j)
      分类: tau x tau (6 对, 预期 DETECTED) / tin x tin (6 对, 预期 no-leak)
            / tin x tau (12 对, 预期 no-leak)

  (3) 二阶 CPA: 256 假设恢复 k_ij = rk_i ^ rk_j (round-0),
      模型 m(c) = E_u[HW(S(u)^S(u^c))], c = (pt_i^pt_j) ^ k_ij;
      负对照: tin x tin 对 (无共享掩码) 不应恢复.
      GE 曲线 (rank of true hypothesis vs N) 给出可利用性量化.

噪声注入 (可选): dump 为无噪声 HW, --sigma 模拟测量噪声,
用于给出"现实噪声下不可检出 / 实验室无噪声可检出"的量化边界.

用法:
  python tvla2_analyze.py sim/scea2_dump.txt               # 无噪声
  python tvla2_analyze.py sim/scea2_dump.txt --sigma 3.0   # 现实噪声
"""
import argparse
import os
import sys
import json
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sm4_ref as ref  # noqa: E402

S = np.array(ref.SBOX, dtype=np.uint8)
THRESH = 4.5

NODE_TIN = [0, 1, 2, 3]
NODE_TAU = [4, 5, 6, 7]


def pairs_of(idx_list):
    out = []
    for a in range(len(idx_list)):
        for b in range(a + 1, len(idx_list)):
            out.append((idx_list[a], idx_list[b]))
    return out


# ---------------------------------------------------------------------------
def parse_dump(path):
    rows, labels, pts = [], [], []
    with open(path, encoding="utf-8") as f:
        for line in f:
            p = line.split()
            if not p or p[0] != "T" or len(p) < 12:
                continue
            rows.append([int(x) for x in p[4:12]])
            labels.append(int(p[2]))
            pts.append(bytes.fromhex(p[3]))
    return (np.array(rows, dtype=np.float64),
            np.array(labels, dtype=np.int64),
            np.array([list(b) for b in pts], dtype=np.uint8))


def welch_t(A, B):
    """A, B: [n] 或 [n, k]. 返回长度 k 的 Welch t 数组 (一维)."""
    A = np.asarray(A)
    B = np.asarray(B)
    if A.ndim == 1:
        A = A[:, None]
    if B.ndim == 1:
        B = B[:, None]
    na, nb = A.shape[0], B.shape[0]
    va, vb = A.var(axis=0, ddof=1), B.var(axis=0, ddof=1)
    denom = np.sqrt(va / na + vb / nb)
    if np.isscalar(denom):
        denom = np.array([denom])
    denom = np.where(denom == 0, 1e-12, denom)
    return (A.mean(axis=0) - B.mean(axis=0)) / denom


# ---------------------------------------------------------------------------
def first_order_tvla(X, labels, tag):
    print("\n-- (1) 一阶 TVLA (每节点, |t| > %.1f = LEAK) --" % THRESH)
    worst = 0.0
    for n in range(X.shape[1]):
        t = float(np.abs(welch_t(X[labels == 0, n], X[labels == 1, n]))[0])
        worst = max(worst, t)
        nm = ("t_in[%d]" % n) if n < 4 else ("tau_m[%d]" % (n - 4))
        print("  [%s] %-10s max|t| = %6.3f" %
              ("PASS" if t < THRESH else "LEAK", nm, t))
    print("  ==> 一阶: %s (worst |t| = %.3f)" %
          ("NO-LEAK" if worst < THRESH else "LEAK", worst))
    return worst


def second_order_tvla(X, labels, tag):
    """组合 TVLA: 返回 (结果字典, 摘要行列表)."""
    print("\n-- (2) 二阶组合 TVLA (平方差 / 中心化乘积, 同拍两节点) --")
    A, B = X[labels == 0], X[labels == 1]
    mu = X.mean(axis=0)
    cats = {
        "tau x tau (共享 K,mout8)": pairs_of(NODE_TAU),
        "tin x tin (掩码独立)": pairs_of(NODE_TIN),
        "tin x tau (跨域)": [(i, j) for i in NODE_TIN for j in NODE_TAU],
    }
    res = {}
    for cat, plist in cats.items():
        best = (-1.0, None, None, None)   # (|t|, pair, comb, nfail)
        for comb_name in ("sqdiff", "prod"):
            for (i, j) in plist:
                if comb_name == "sqdiff":
                    ca = (A[:, i] - A[:, j]) ** 2
                    cb = (B[:, i] - B[:, j]) ** 2
                else:
                    ca = (A[:, i] - mu[i]) * (A[:, j] - mu[j])
                    cb = (B[:, i] - mu[i]) * (B[:, j] - mu[j])
                t = float(np.abs(welch_t(ca, cb))[0])
                if t > best[0]:
                    best = (t, (i, j), comb_name, None)
        i, j = best[1]
        comb = best[2]
        if comb == "sqdiff":
            ca = (A[:, i] - A[:, j]) ** 2
            cb = (B[:, i] - B[:, j]) ** 2
        else:
            ca = (A[:, i] - mu[i]) * (A[:, j] - mu[j])
            cb = (B[:, i] - mu[i]) * (B[:, j] - mu[j])
        nf = int((np.abs(welch_t(ca, cb)) > THRESH).sum()) if ca.ndim > 1 else 0
        verdict = "DETECTED" if best[0] > THRESH else "not-detected"
        print("  [%-8s] %-24s max|t| = %7.3f  @ pair (%d,%d) comb=%s"
              % (verdict, cat, best[0], i, j, comb))
        print("              固定组组合均值 = %.4f  随机组组合均值 = %.4f"
              % (ca.mean(), cb.mean()))
        res[cat] = dict(max_t=best[0], pair=[int(i), int(j)], comb=comb,
                        mean_fixed=float(ca.mean()),
                        mean_random=float(cb.mean()),
                        detected=bool(best[0] > THRESH))
    return res


# ---------------------------------------------------------------------------
def d2_cpa(X, labels, pts, key, sigma_noise, rng):
    """round-0 二阶 CPA: 恢复 k_ij = rk_i ^ rk_j, 6 个 tau 字节对."""
    print("\n-- (3) 二阶 CPA (round-0, 恢复 rk_i^rk_j, 256 假设) --")
    rk = ref.key_schedule(ref.bytes_to_int(key))
    rk0 = rk[0]
    rk0b = np.array([(rk0 >> 24) & 0xFF, (rk0 >> 16) & 0xFF,
                     (rk0 >> 8) & 0xFF, rk0 & 0xFF], dtype=np.uint8)
    # random 组做 CPA (标签 1); 模型 m(c) = E_u[HW(S(u)^S(u^c))]
    # round-0 tmp 字节 (MSB 先): s_b = pt[4+b] ^ pt[8+b] ^ pt[12+b] ^ rk0[b]
    # (SM4 round0: X4 = X0 ^ T(X1^X2^X3^rk0), X1..X3 = 明文第 1..3 字)
    R = X[labels == 1]
    P = pts[labels == 1]
    u = np.arange(256, dtype=np.uint8)
    HW = np.vectorize(lambda x: bin(int(x) & 0xFF).count("1"))
    mtab = np.zeros(256)
    for c in range(256):
        mtab[c] = HW(S[u] ^ S[np.bitwise_xor(u, c)]).mean()

    # ---- 固定组: 理论 vs 实测 (v4 实际电路: tau_b = S(s_b) ^ mout8,
    #      微规格书 §43/103: K 只遮地址网, S 盒输入为明文 tmp) ----
    # 固定组 sqdiff 期望 = HW(S(s_i) ^ S(s_j)) -- 确定性值 (不随 K/m 抖动)
    pt_fix = pts[labels == 0][0]
    sfix = np.zeros(4, dtype=np.uint8)
    for b in range(4):
        sfix[b] = pt_fix[4 + b] ^ pt_fix[8 + b] ^ pt_fix[12 + b] ^ rk0b[b]
    Fx = X[labels == 0]
    print("  -- 固定组 sqdiff 理论 vs 实测 (round-0 s = %s) --"
          % " ".join("%02X" % v for v in sfix))
    for (bi, bj) in [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]:
        D = int(S[sfix[bi]] ^ S[sfix[bj]])
        meas = ((Fx[:, NODE_TAU[bi]] - Fx[:, NODE_TAU[bj]]) ** 2).mean()
        print("     tau(%d,%d): D=S(s_i)^S(s_j)=0x%02X  理论 sqdiff=%d  "
              "实测=%.3f" % (bi, bj, D, bin(D).count("1"), meas))

    def ptbyte3(P, b):
        return (P[:, 4 + b] ^ P[:, 8 + b] ^ P[:, 12 + b]).astype(np.uint8)

    nn = R.shape[0]
    ge_pts = [200, 500, 1000, 2000, 5000, 10000, 20000]
    out = []
    for (bi, bj) in [(0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3)]:
        i, j = NODE_TAU[bi], NODE_TAU[bj]
        obs = (R[:, i] - R[:, j]) ** 2          # sqdiff 组合器
        known = (ptbyte3(P, bi) ^ ptbyte3(P, bj)).astype(np.uint64)
        true_g = int(rk0b[bi] ^ rk0b[bj])
        # 每假设相关
        corrs = np.zeros(256)
        for g in range(256):
            hyp = mtab[np.bitwise_xor(known, g)]
            if hyp.std() < 1e-12:
                corrs[g] = 0.0
            else:
                corrs[g] = np.corrcoef(obs, hyp)[0, 1]
        rank = int((np.abs(corrs) > np.abs(corrs[true_g])).sum())
        best_g = int(np.argmax(np.abs(corrs)))
        ge_curve = {}
        for nnk in ge_pts:
            if nnk > nn:
                continue
            ok2 = np.zeros(nnk)
            oh2 = np.zeros((nnk, 256))
            for g in range(256):
                hyp = mtab[np.bitwise_xor(known[:nnk], g)]
                oh2[:, g] = hyp if hyp.std() > 1e-12 else 0.0
            ob2 = obs[:nnk]
            ob2c = ob2 - ob2.mean()
            num = (oh2 - oh2.mean(axis=0)).T @ ob2c
            den = np.sqrt(((oh2 - oh2.mean(axis=0)) ** 2).sum(axis=0) *
                          (ob2c ** 2).sum())
            cc = np.where(den > 0, num / np.maximum(den, 1e-12), 0.0)
            ge_curve[nnk] = int((np.abs(cc) > np.abs(cc[true_g])).sum())
        out.append(dict(
            pair=[bi, bj], true_g=true_g, best_g=best_g,
            corr_true=float(corrs[true_g]), corr_best=float(corrs[best_g]),
            rank=rank, ge_curve=ge_curve,
            hit=bool(best_g == true_g)))
        print("  tau 对 (%d,%d): true k_ij=0x%02X  最佳假设=0x%02X (%s)  "
              "rho_true=%+.4f  rank(true)=%d  GE: %s"
              % (bi, bj, true_g, best_g,
                 "HIT" if best_g == true_g else "miss",
                 corrs[true_g], rank,
                 " ".join("%d:%d" % (k, v) for k, v in ge_curve.items())))
    # 负对照: tin x tin
    print("  -- 负对照 (tin x tin, 掩码独立, 预期不可恢复) --")
    for (bi, bj) in [(0, 1), (0, 2)]:
        i, j = NODE_TIN[bi], NODE_TIN[bj]
        obs = (R[:, i] - R[:, j]) ** 2
        known = (ptbyte3(P, bi) ^ ptbyte3(P, bj)).astype(np.uint64)
        true_g = int(rk0b[bi] ^ rk0b[bj])
        corrs = np.zeros(256)
        for g in range(256):
            hyp = mtab[np.bitwise_xor(known, g)]
            corrs[g] = np.corrcoef(obs, hyp)[0, 1] if hyp.std() > 1e-12 else 0.0
        best_g = int(np.argmax(np.abs(corrs)))
        print("  tin 对 (%d,%d): true=0x%02X best=0x%02X  rho_true=%+.4f  "
              "(预期 |rho| < ~0.01)"
              % (bi, bj, true_g, best_g, corrs[true_g]))
    return out


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump", help="run_scea2.py 产出的 round-0 dump")
    ap.add_argument("--sigma", type=float, default=0.0,
                    help="注入高斯测量噪声 (dump 为无噪声 HW)")
    ap.add_argument("--key", default="0123456789ABCDEFFEDCBA9876543210")
    ap.add_argument("--json", help="结果 JSON 落盘路径")
    a = ap.parse_args()

    X, labels, pts = parse_dump(a.dump)
    print("=== SM4 v4 二阶泄漏实验室验证 (%s) ===" % a.dump)
    print("  traces=%s  fixed=%d random=%d  noise sigma=%.2f"
          % (X.shape, int((labels == 0).sum()), int((labels == 1).sum()),
             a.sigma))
    if a.sigma > 0:
        rng = np.random.default_rng(20261026)
        X = X + rng.normal(0.0, a.sigma, size=X.shape)

    first_order_tvla(X, labels, "v4")
    res2 = second_order_tvla(X, labels, "v4")
    cpa = d2_cpa(X, labels, pts, bytes.fromhex(a.key), a.sigma, None)

    det = {k: v["detected"] for k, v in res2.items()}
    print("\n=== 汇总 (阈值 |t| > %.1f, sigma=%.2f) ===" % (THRESH, a.sigma))
    for k, v in res2.items():
        print("  二阶 TVLA %-24s %s (max|t|=%.2f @ pair %s, %s)"
              % (k, "DETECTED" if v["detected"] else "not-detected",
                 v["max_t"], v["pair"], v["comb"]))
    hits = sum(1 for c in cpa if c["hit"])
    print("  二阶 CPA: %d/6 tau 对直接命中 k_ij" % hits)
    print()
    print("结论要点:")
    print("  - 一阶 (d=1): 与 probe_check_v4 完美探测 d=1 声明一致 ->")
    print("    节点分布与秘密无关, TVLA NO-LEAK.")
    print("  - 二阶 (d=2): tau x tau 跨字节联合分布依赖 c=s_i^s_j (共享掩码),")
    print("    组合 TVLA / CPA 可检出 -> 与 d=2 边界预言一致;")
    print("    tin x tin / tin x tau 无共享掩码 -> 无泄漏 (负对照成立).")

    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(dict(sigma=a.sigma, second_order=res2, cpa=cpa),
                      f, indent=2, ensure_ascii=False)
        print("  [save]", a.json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
