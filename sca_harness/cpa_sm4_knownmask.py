#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""cpa_sm4_knownmask.py -- 掩码已知 (known-mask) 一阶 CPA (#157)

对照 cpa_sm4.py 的"掩码盲"一阶 CPA。当 v4 的 mask_seed 不可预测 (真 TRNG)
时, tau_m = S(sbox_in) ^ mout8 中的 mout8 对攻击者未知, HW 模型被随机化,
一阶 CPA 不收敛 (#156 实测 0/4)。但当 mask_seed 确定性可算 (板级配置:
crypto_coord_subsys.v 复位常数 0x9E3779B97F4A7C15 + 公开 xs64 自由运行) 时,
攻击者可逐条 trace 算出 mout8 = mask_seed[55:48], 于是

    tau_m[b] = SBOX[ byte_b(X1^X2^X3) ^ rk0[b] ] ^ mout8        (S 盒输入/输出
                                                               的其余掩码在
                                                               addr 形成时
                                                               全部抵消, 见
                                                               引擎 S_DATA)

掩码已知模型:  h_g(i) = HW( SBOX[ known_b(i) ^ g ] ^ mout8(i) )
与未掩码 CPA 完全同构 -> 一阶 CPA 恢复 rk0。

两种证据强度:
  (A) --seeds 给出逐条真实种子 (掩码已知的上界, 用于定位泄漏周期)
  (B) --phase-scan 只假设"公开 RTL + 复位常数 + 相邻加密周期数 C", 对相位
      做穷举 (o = 0..2C), 每个 o 重算整条种子序列再跑 CPA —— 零秘密知识下
      的可实用攻击。

用法:
  python cpa_sm4_knownmask.py --dump sim/scea_det_dump.txt \
      --seeds sim/scea_det_dump.txt.seed.txt
  python cpa_sm4_knownmask.py --dump ... --seeds ... --phase-scan
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sm4_ref as ref  # noqa: E402

SBOX = np.array(ref.SBOX, dtype=np.uint32)
M64 = 0xFFFFFFFFFFFFFFFF
SEED0 = 0x9E3779B97F4A7C15          # crypto_coord_subsys.v 复位常数 (公开)

KAT = "681EDF34D206965E86B3E94F536E4246"


# ----------------------------------------------------------------------------
# xs64 (与 crypto_coord_subsys.v L204-212 / tb_scea_masked_v4_det.v 逐位一致)
# ----------------------------------------------------------------------------
def xs64(x):
    x &= M64
    t = x ^ ((x << 13) & M64)
    t ^= (t >> 7)
    t &= M64
    return (t ^ ((t << 17) & M64)) & M64


def xs64_pow(x, n):
    for _ in range(n):
        x = xs64(x)
    return x


def mout8_of(seed):
    """v4 引擎: mout8 = mask_seed[55:48] (S 盒输出唯一残留掩码)。"""
    return (seed >> 48) & 0xFF


# ----------------------------------------------------------------------------
# 解析
# ----------------------------------------------------------------------------
def parse_dump(path):
    """T <idx> <label> <pt_hex32> <v0>..<v575> -> traces[N,nsamp], pts[N,16]"""
    traces, pts, labels = [], [], []
    nsamp = None
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            p = line.split()
            if not p or p[0] != "T" or len(p) < 5:
                continue
            vals = [int(x) for x in p[4:]]
            if nsamp is None:
                nsamp = len(vals)
            elif len(vals) != nsamp:
                raise ValueError("inconsistent nsamp %d vs %d"
                                 % (len(vals), nsamp))
            traces.append(np.array(vals, dtype=np.float64))
            pts.append(bytes.fromhex(p[3]))
            labels.append(int(p[2]))
    if not traces:
        raise ValueError("no traces in %s" % path)
    return (np.array(traces, dtype=np.float64),
            np.array([list(b) for b in pts], dtype=np.uint8),
            np.array(labels, dtype=np.uint8), nsamp)


def parse_seeds(path):
    """S <idx> <64hex> -> 按 idx 排序的种子数组 [N] uint64"""
    d = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            p = line.split()
            if len(p) == 3 and p[0] == "S":
                d[int(p[1])] = int(p[2], 16)
    if not d:
        raise ValueError("no seeds in %s" % path)
    return np.array([d[i] for i in sorted(d)], dtype=np.uint64)


def sbox_in_known(pts):
    """byte_b(X1^X2^X3), b=0 为最高字节 -> [N,4] uint32"""
    n = pts.shape[0]
    out = np.zeros((n, 4), dtype=np.uint32)
    for i in range(n):
        pt = ref.bytes_to_int(pts[i])
        X = [(pt >> (32 * (3 - j))) & 0xFFFFFFFF for j in range(4)]
        w = X[1] ^ X[2] ^ X[3]
        for b in range(4):
            out[i, b] = (w >> (8 * (3 - b))) & 0xFF
    return out


def hw_arr(x):
    x = np.asarray(x, dtype=np.uint32)
    c = np.zeros_like(x)
    for b in range(32):
        c += (x >> b) & 1
    return c.astype(np.float64)


def std_col(c):
    s = c.std()
    if s == 0:
        return np.zeros_like(c)
    return (c - c.mean()) / s


# ----------------------------------------------------------------------------
# 攻击
# ----------------------------------------------------------------------------
def attack_byte(zcol, known_b, mout8, n_use):
    """掩码已知一阶 CPA, 单字节。zcol 已标准化 [N]。
    model h_g(i) = HW(SBOX[known_b(i)^g] ^ mout8(i))。
    返回 peaks[256], best_guess。"""
    kb = known_b[:n_use].astype(np.uint32)
    mo = mout8[:n_use].astype(np.uint32)
    z = zcol[:n_use]
    peaks = np.zeros(256)
    for g in range(256):
        h = hw_arr(SBOX[(kb ^ np.uint32(g)) & 0xFF] ^ mo)
        hs = h.std()
        if hs == 0:
            peaks[g] = 0.0
            continue
        hz = (h - h.mean()) / hs
        # z 已标准化 -> |Pearson| = |hz·z| / n
        peaks[g] = float(np.abs(hz @ z) / n_use)
    return peaks, int(np.argmax(peaks))


def run_cpa(tr, known, mout8, cycle, n_use=None):
    """在指定泄漏周期 cycle 上攻击 4 个字节。
    采样布局: 每周期 8 个通道, tau_m 字节 b 在列 8*cycle+4+b (b=0 最高字节)。
    返回 per-byte (peaks, best) 与统计。"""
    n = tr.shape[0]
    if n_use is None:
        n_use = n
    res = []
    for b in range(4):
        col = std_col(tr[:, 8 * cycle + 4 + b])
        peaks, best = attack_byte(col, known[:, b], mout8, n_use)
        res.append((peaks, best))
    return res


def locate_cycle(tr, known, mout8, true_bytes, c_lo, c_hi):
    """用真密钥定位 round-0 泄漏周期 (标准校准做法): 每个候选周期算真猜测
    的 |Pearson|, 4 字节同时最大的周期即泄漏点。"""
    n = tr.shape[0]
    best_c, best_score, detail = -1, -1.0, {}
    for c in range(c_lo, c_hi):
        cols = [std_col(tr[:, 8 * c + 4 + b]) for b in range(4)]
        kb = [known[:, b].astype(np.uint32) for b in range(4)]
        mo = mout8.astype(np.uint32)
        corrs = []
        for b in range(4):
            h = hw_arr(SBOX[(kb[b] ^ np.uint32(true_bytes[b])) & 0xFF] ^ mo)
            hs = h.std()
            if hs == 0:
                corrs.append(0.0)
                continue
            hz = (h - h.mean()) / hs
            corrs.append(float(np.abs(hz @ cols[b]) / n))
        score = min(corrs)          # 要求 4 字节同时高
        detail[c] = corrs
        if score > best_score:
            best_score, best_c = score, c
    return best_c, best_score, detail


def full_report(tr, known, mout8, true_bytes, cycle, tag, n_use=None):
    """在 cycle 上跑完整 4 字节 CPA, 打印恢复结果 + GE-vs-N。"""
    n = tr.shape[0]
    res = run_cpa(tr, known, mout8, cycle, n_use)
    print("  [%s] cycle=%d  N=%d" % (tag, cycle, n))
    all_ok = True
    rec = []
    for b in range(4):
        peaks, best = res[b]
        ok = (best == true_bytes[b])
        all_ok &= ok
        rec.append(best)
        order = np.argsort(peaks)[::-1]
        rank = int((peaks > peaks[true_bytes[b]]).sum()) + 1
        print("    rk0 byte%d : rec=%02X true=%02X %-7s peak=%.4f 2nd=%.4f "
              "rank(true)=%d" % (b, best, true_bytes[b],
                                 "OK" if ok else "WRONG",
                                 peaks[order[0]], peaks[order[1]], rank))
    rk0 = (rec[0] << 24) | (rec[1] << 16) | (rec[2] << 8) | rec[3]
    print("    -> recovered rk0 = %08X  true rk0 = %08X  %s"
          % (rk0, (true_bytes[0] << 24) | (true_bytes[1] << 16)
             | (true_bytes[2] << 8) | true_bytes[3],
             "4/4 RECOVERED" if all_ok else "FAILED"))
    # GE vs N (byte 0)
    b = 0
    ges, xs = [], []
    for m in sorted(set(min(s, n) for s in (50, 100, 200, 500, 1000, 2000, n)
                        if s <= n)):
        col = std_col(tr[:, 8 * cycle + 4 + b])
        peaks, _ = attack_byte(col, known[:, b], mout8, m)
        ges.append(int((peaks > peaks[true_bytes[b]]).sum()) + 1)
        xs.append(m)
    print("    GE vs N (byte0):",
          ", ".join("N=%d:GE=%d" % (x, g) for x, g in zip(xs, ges)))
    return all_ok, rk0


def phase_scan(tr, known, true_bytes, cycle, cyc_per_enc, n_scan=None):
    """零秘密知识攻击: 只用公开复位常数 + 公开 xs64 + 相邻加密周期数 C,
    对相位偏移 o 穷举, seed_k(o) = xs64^{o + k*C}(SEED0)。报告哪个 o 恢复
    密钥 + 峰值。

    效率: 先线性预推 base 序列 b[m] = xs64^m(SEED0) (m = 0..2C+(N-1)C), 每个
    o 的种子序列即 b 的等跨度切片 b[o : o+N*C : C], 无需逐条重推。"""
    n = tr.shape[0] if n_scan is None else min(n_scan, tr.shape[0])
    print("  [phase-scan] C=%d  N=%d  o in [0, %d]"
          % (cyc_per_enc, n, 2 * cyc_per_enc))
    m_max = 2 * cyc_per_enc + (n - 1) * cyc_per_enc
    bseq = np.empty(m_max + 1, dtype=np.uint64)
    bseq[0] = SEED0
    for m in range(1, m_max + 1):
        bseq[m] = xs64(int(bseq[m - 1]))
    hit = []
    for o in range(0, 2 * cyc_per_enc + 1):
        seeds = bseq[o: o + (n - 1) * cyc_per_enc + 1: cyc_per_enc]
        mo = np.array([mout8_of(int(s)) for s in seeds], dtype=np.uint32)
        # 4 字节同时判: 只要 4/4 即命中, 记录 margin
        ok_cnt, margins = 0, []
        for b in range(4):
            col = std_col(tr[:n, 8 * cycle + 4 + b])
            peaks, best = attack_byte(col, known[:n, b], mo, n)
            order = np.argsort(peaks)[::-1]
            margins.append(peaks[order[0]] - peaks[order[1]])
            if best == true_bytes[b]:
                ok_cnt += 1
        if ok_cnt == 4:
            hit.append((o, float(min(margins)), float(np.mean(margins))))
            print("    o=%3d : 4/4 RECOVERED  min-margin=%.4f mean=%.4f"
                  % (o, min(margins), float(np.mean(margins))))
    if not hit:
        print("    no phase offset recovered the key")
    else:
        best_o = max(hit, key=lambda t: t[1])[0]
        print("    -> phase o=%d (of %d candidates) fully recovers rk0; "
              "%d/%d offsets hit" % (best_o, 2 * cyc_per_enc + 1,
                                     len(hit), 2 * cyc_per_enc + 1))
    return hit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", required=True)
    ap.add_argument("--seeds", help="逐条种子旁录 (证据强度 A)")
    ap.add_argument("--phase-scan", action="store_true",
                    help="零秘密知识相位穷举 (证据强度 B)")
    ap.add_argument("--cyc", type=int, default=76,
                    help="相邻两次加密的时钟周期数 C (板级驱动间隔)")
    ap.add_argument("--c-range", type=int, nargs=2, default=[12, 26],
                    help="泄漏周期搜索窗口")
    ap.add_argument("--out-json", help="结果落盘 JSON")
    a = ap.parse_args()

    tr, pts, labels, nsamp = parse_dump(a.dump)
    nnode = nsamp // 72 if (nsamp % 72) == 0 else 8
    print("=== known-mask first-order CPA : %s ===" % a.dump)
    print("  traces=%s nsamp=%d (nodes/cycle=%d) fixed=%d random=%d"
          % (tr.shape, nsamp, nnode, int((labels == 0).sum()),
             int((labels == 1).sum())))

    key = ref.bytes_to_int(bytes.fromhex(
        "0123456789ABCDEFFEDCBA9876543210"))
    rk0 = ref.key_schedule(key)[0]
    true_bytes = [(rk0 >> (8 * (3 - b))) & 0xFF for b in range(4)]
    print("  true rk0 = %08X  (bytes %s)" % (rk0,
          ["%02X" % b for b in true_bytes]))
    exp_ct = ref.encrypt_block(key, ref.bytes_to_int(bytes.fromhex(
        "0123456789ABCDEFFEDCBA9876543210")))
    print("  [xcheck] SM4 KAT selftest :",
          "PASS" if ("%032X" % exp_ct) == KAT else "FAIL")

    known = sbox_in_known(pts)

    result = {"dump": a.dump, "n": int(tr.shape[0]), "true_rk0": "%08X" % rk0}

    if a.seeds:
        seeds = parse_seeds(a.seeds)
        if seeds.shape[0] != tr.shape[0]:
            print("[ERR] seed count %d != traces %d"
                  % (seeds.shape[0], tr.shape[0]))
            return 1
        # 自检: 种子序列是否与公开模型一致 (SEED0 + 每条推进 C)
        model_ok = all(
            int(seeds[k]) == xs64_pow(SEED0, (k + 1) * a.cyc)
            for k in range(tr.shape[0]))
        print("  [xcheck] seed == xs64^{(k+1)*C}(SEED0) :",
              "PASS" if model_ok else "MISMATCH (phase shifted, still det.)")
        mo = np.array([mout8_of(int(s)) for s in seeds], dtype=np.uint32)

        c_lo, c_hi = a.c_range
        cyc, score, _ = locate_cycle(tr, known, mo, true_bytes, c_lo, c_hi)
        print("  [locate] round-0 leakage cycle = %d (min-over-bytes "
              "|Pearson| = %.4f)" % (cyc, score))
        ok_a, rk0_a = full_report(tr, known, mo, true_bytes, cyc, "known-seed")
        result["known_seed"] = {"cycle": cyc, "rk0": "%08X" % rk0_a,
                                "recovered": bool(ok_a)}

    if a.phase_scan:
        if not a.seeds:
            c_lo, c_hi = a.c_range
            # 无种子旁录时用真密钥在零假设模型下定位 (相位扫描自带相位)
            cyc = (c_lo + c_hi) // 2
        else:
            cyc = result.get("known_seed", {}).get("cycle", 20)
        hits = phase_scan(tr, known, true_bytes, cyc, a.cyc)
        result["phase_scan"] = {"cycle": cyc, "hits": len(hits)}

    if a.out_json:
        with open(a.out_json, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
        print("  [save]", a.out_json)
    return 0


if __name__ == "__main__":
    sys.exit(main())
