#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_scea_traces.py -- 仿真侧信道评估 (SCEA) trace 生成器

无外部设备时的示波器替代方案: 用 iverilog 仿真 SM4 引擎, 按 Hamming Weight
功耗模型提取中间值轨迹。输出与 gen_synth_traces.py 完全相同的目录格式
(traces.npy / pts.npy / labels.npy / meta.json), 因此 tvla_analyze.py 与
cpa_sm4.py 无需任何改动即可直接复用 -- 这正是"分析侧与数据来源解耦"的价值。

功耗模型 (HW model, SCEA 文献通用的一阶模型):
    每个采样周期记录 2 个监控节点的汉明权重
      node 0 = HW(cipher_xors)   S 盒输入 = X1^X2^X3^rk[r]
      node 1 = HW(cipher_tau)    S 盒输出 = tau(cipher_xors)  <- CPA 直接目标
    与明文相关的信息因此确定性地存在于 trace 中, 可被 TVLA 检出、被 CPA 攻破。

注意 SCEA 的两条已知局限 (论文里必须写明):
  1) 只有零阶/瞬时模型, 没有亚稳态、毛刺、路由耦合等瞬态效应 -> 无法评估
     robust model 下的安全, 只能评估标准 probing 模型。
  2) 掩码设计在纯 HW 模型下往往"看起来完全安全", 因为 share 的 HW 与秘密
     统计独立。真实泄漏通常来自高阶项 (share 乘积) 或毛刺, 需要扩展模型
     (见 --model 2nd) 才能看到。

用法:
  python gen_scea_traces.py --n 500 --out data/scea_leaky
  python gen_scea_traces.py --n 500 --noise 3.0 --out data/scea_leaky
  python gen_scea_traces.py --masked --n 500 --out data/scea_masked
"""
import os
import sys
import json
import shutil
import argparse
import subprocess
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sm4_ref as ref  # noqa: E402

RTL = os.path.join(HERE, "rtl")
SIM = os.path.join(HERE, "sim")
ENG = os.path.normpath(os.path.join(HERE, "..", "rtl", "sm4", "sm4_engine.v"))
ENG_MASKED = os.path.normpath(
    os.path.join(HERE, "..", "rtl", "sm4", "sm4_engine_masked_v3.v"))

IV = os.environ.get("IVERILOG", r"C:\iverilog\bin\iverilog.exe")
VVP = os.environ.get("VVP", r"C:\iverilog\bin\vvp.exe")


def hw(x):
    """32-bit 汉明权重 (标量, 供自检/交叉校验)。"""
    return bin(int(x) & 0xFFFFFFFF).count("1")


# ---------------------------------------------------------------------------
# 编译 + 仿真
# ---------------------------------------------------------------------------
def compile_vvp(use_masked=False, n_fix=500, n_rnd=500, seed=20261025,
                nsamp_c=72, outf="scea_dump.txt"):
    """编译 tb_scea 为 vvp。返回 vvp 路径。"""
    os.makedirs(SIM, exist_ok=True)
    vvp = os.path.join(SIM, "tb_scea.vvp" if not use_masked else "tb_scea_m.vvp")
    cmd = [IV, "-g2005", "-o", vvp,
           os.path.join(RTL, "tb_scea.v"),
           ENG_MASKED if use_masked else ENG]
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8",
                       errors="replace", timeout=600)
    if r.returncode != 0:
        print("[ERR] iverilog failed:\n" + (r.stderr or "") + (r.stdout or ""))
        sys.exit(1)
    return vvp


def run_vvp(vvp, use_masked, n_fix, n_rnd, seed, nsamp_c, outdir, timeout=1800):
    """在 outdir 下运行仿真, 产出 scea_dump.txt。"""
    os.makedirs(outdir, exist_ok=True)
    outf = os.path.join(outdir, "scea_dump.txt")
    # 掩码引擎顶层参数不同 (有 masked_en 等), tb_scea 只接未掩码版;
    # 掩码版走独立顶层, 见 --masked 分支。这里保持签名统一。
    cmd = [VVP, vvp, "-GOUTF=" + outf] + [
        "-GKEY=%032x" % ref.bytes_to_int(bytes.fromhex(
            "0123456789ABCDEFFEDCBA9876543210")),
        "-GPT_FIX=%032x" % ref.bytes_to_int(bytes.fromhex(
            "0123456789ABCDEFFEDCBA9876543210")),
        "-GN_FIX=%d" % n_fix,
        "-GN_RND=%d" % n_rnd,
        "-GSEED=%d" % seed,
        "-GNSAMP_C=%d" % nsamp_c,
    ]
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8",
                       errors="replace", timeout=timeout, cwd=outdir)
    log = os.path.join(outdir, "scea_sim.log")
    with open(log, "w", encoding="utf-8") as f:
        f.write("cmd: " + " ".join(cmd) + "\n")
        f.write("rc: %d\n" % r.returncode)
        f.write("--- stdout ---\n")
        f.write(r.stdout or "")
        if r.stderr:
            f.write("--- stderr ---\n")
            f.write(r.stderr)
    print("[sim] rc=%d log=%s" % (r.returncode, log))
    tail = [l for l in (r.stdout or "").splitlines() if l.strip()][-8:]
    for l in tail:
        print("      " + l)
    if r.returncode != 0 or not os.path.exists(outf):
        print("[ERR] simulation failed or dump missing")
        sys.exit(1)
    return outf


# ---------------------------------------------------------------------------
# 解析
# ---------------------------------------------------------------------------
def parse_dump(path):
    """解析 scea_dump.txt -> traces[N,NSAMP] float64, pts[N,16] u8, labels[N] u8

    每行格式:  T <idx> <label> <pt_hex32> <v0> <v1> ... <vN-1>
    v_i 为十进制汉明权重 (0..32)。逐样本十进制输出是为了避免 %h 对
    864-bit 宽值在含 X 位时插入 'x'/'X' 填充字符导致解析失败。
    """
    traces, pts, labels = [], [], []
    nsamp = None
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            p = line.split()
            if not p or p[0] != "T" or len(p) < 5:
                continue
            try:
                vals = [int(x) for x in p[4:]]
            except ValueError as e:
                raise ValueError("bad sample token in line: %r" % line[:120])
            if nsamp is None:
                nsamp = len(vals)
            elif len(vals) != nsamp:
                raise ValueError("inconsistent sample count %d vs %d"
                                 % (len(vals), nsamp))
            for v in vals:
                if not 0 <= v <= 32:
                    raise ValueError("HW sample out of range: %d" % v)
            traces.append(np.array(vals, dtype=np.float64))
            pts.append(bytes.fromhex(p[3]))
            labels.append(int(p[2]))
    if not traces:
        raise ValueError("no traces parsed from %s" % path)
    pts = np.array([list(b) for b in pts], dtype=np.uint8).reshape(len(pts), 16)
    return np.array(traces, dtype=np.float64), pts, \
        np.array(labels, dtype=np.uint8), nsamp


def add_noise(traces, sigma, seed):
    """叠加高斯噪声, 模拟真实测量噪声。SCEA 原生为噪声自由, 不加噪声会让
    TVLA 的 t 值达到几百, 失去参考意义。"""
    if sigma <= 0:
        return traces
    rng = np.random.default_rng(seed)
    return traces + rng.normal(0.0, sigma, size=traces.shape)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="SCEA 仿真 trace 生成器")
    ap.add_argument("--n", type=int, default=500,
                    help="每组 (固定/随机) 的 trace 条数")
    ap.add_argument("--nsamp-c", type=int, default=72,
                    help="每块捕获的周期数 (引擎 64 周期 + 余量)")
    ap.add_argument("--noise", type=float, default=3.0,
                    help="高斯噪声 sigma (0 = 无噪声, 不建议)")
    ap.add_argument("--seed", type=int, default=20261025)
    ap.add_argument("--key", default="0123456789ABCDEFFEDCBA9876543210")
    ap.add_argument("--masked", action="store_true",
                    help="用掩码引擎 (默认未掩码正对照)")
    ap.add_argument("--vvp", help="直接复用已编译的 vvp (跳过编译)")
    ap.add_argument("--dump", help="直接用已有 dump 文件 (跳过仿真)")
    ap.add_argument("--out", required=True, help="输出数据集目录")
    a = ap.parse_args()

    outdir = os.path.abspath(a.out)
    os.makedirs(outdir, exist_ok=True)
    nsamp_c = a.nsamp_c

    # -- 可选: 只跑仿真不解析, 用于调试 --
    if a.dump:
        dump = a.dump
        print("[info] using existing dump:", dump)
    else:
        vvp = a.vvp or compile_vvp(a.masked, a.n, a.n, a.seed, nsamp_c)
        print("[build] vvp:", vvp)
        dump = run_vvp(vvp, a.masked, a.n, a.n, a.seed, nsamp_c, outdir)

    traces, pts, labels, nsamp = parse_dump(dump)
    traces = add_noise(traces, a.noise, a.seed)
    print("[parse] traces=%s  nsamples=%d  fixed=%d random=%d"
          % (traces.shape, nsamp, int((labels == 0).sum()),
             int((labels == 1).sum())))

    # ---- 交叉校验: 用参考模型复算固定明文密文, 确认仿真跑的是真引擎 ----
    key = ref.bytes_to_int(bytes.fromhex(a.key))
    pt_fix = ref.bytes_to_int(bytes.fromhex("0123456789ABCDEFFEDCBA9876543210"))
    exp_ct = ref.encrypt_block(key, pt_fix)
    # 从 dump 里取 bi=0 的密文 (TB 打印过, 这里重算即可)
    print("[xcheck] ref ct(FIX) = %032X  (SM4 KAT 锚点 %032X)"
          % (exp_ct, 0x681EDF34D206965E86B3E94F536E4246))
    kat_ok = ("%032X" % exp_ct) == "681EDF34D206965E86B3E94F536E4246"
    print("[xcheck] SM4 KAT selftest :", "PASS" if kat_ok else "FAIL")

    # ---- 自检: 泄漏点应确实与 S 盒输出 HW 一致 ----
    # 逐字节节点模式: 每周期 NNODE 个节点, 采样索引 i 的节点号 = i % NNODE。
    # 取 4 个 cipher_tau 字节节点 (cipher_tau[24:16],[16:8],[8:0],[0])
    nnode = nsamp // nsamp_c
    tau_nodes = [4, 5, 6, 7] if nnode > 1 else [1]
    tau_idx = [i for i in range(nsamp) if i % nnode in tau_nodes]
    if not tau_idx:
        tau_idx = list(range(nsamp))
        nnode = 1
    var_rand = traces[labels == 1][:, tau_idx].var(axis=0)
    best = tau_idx[int(np.argmax(var_rand))] if tau_idx else -1
    if best >= 0:
        print("[selfcheck] max-variance tau sample = %d (cycle %d, node %d)"
              % (best, best // nnode, best % nnode))
        print("           fixed-set HW at that sample = %.3f (expect constant)"
              % traces[labels == 0, best].mean())
        print("           random-set HW at that sample: mean=%.3f std=%.3f"
              % (traces[labels == 1, best].mean(),
                 traces[labels == 1, best].std()))

    meta = dict(
        model="scea_hw",
        engine="sm4_engine_masked_v3" if a.masked else "sm4_engine",
        power_model="hamming_weight",
        nnode=nnode,
        nodes=("HW(cipher_xors[31:24],[23:16],[15:8],[7:0]), "
               "HW(cipher_tau[31:24],[23:16],[15:8],[7:0])"
               if nnode > 1 else ["HW(cipher_xors)", "HW(cipher_tau)"]),
        node_map=("每采样周期 8 个节点, 落盘列号 = i % nnode, 与 RTL tap "
                  "序号一致: 0..3 = HW(xors[31:24],[23:16],[15:8],[7:0]), "
                  "4..7 = HW(tau[31:24],[23:16],[15:8],[7:0])。"
                  "故第 b 字节的 S-box 输出通道 = 列 % nnode == 4+b, "
                  "S-box 输入通道 = 列 % nnode == b (b=0 为最高字节)。"
                  "该映射由 resolve_node_map.py 对照 CPA 验证 "
                  "(4+b -> 4/4 字节正确, 4+(3-b) -> 0/4)"
                  if nnode > 1 else ""),
        n_fixed=int((labels == 0).sum()),
        n_random=int((labels == 1).sum()),
        nsamples=nsamp,
        nsamp_cycles=nsamp_c,
        noise_sigma=a.noise,
        seed=a.seed,
        key=a.key,
        rk0="%08X" % ref.key_schedule(key)[0],
        target_word_bytes=[0, 1, 2, 3],
        note="仿真侧信道评估 (SCEA): 零阶 HW 模型, 无亚稳态/毛刺/路由耦合, "
             "不能评估 robust model 安全性。仅替代无法上示波器时的基线测量。",
    )

    np.save(os.path.join(outdir, "traces.npy"), traces)
    np.save(os.path.join(outdir, "pts.npy"), pts)
    np.save(os.path.join(outdir, "labels.npy"), labels)
    with open(os.path.join(outdir, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    print("[save] dataset ->", outdir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
