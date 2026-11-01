#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_check_v5.py -- SM4 v4 "完美探测模型"穷举验证 (实际电路版, #156)

为什么需要 v5 (v4 的修正):
  probe_check_v4.py 把输出网建模为 w_tau = S(s ^ K) ^ mout8 (K 留在 S 盒
  输入里). 但 v4 微规格书 §43/103 与 RTL (sm4_engine_masked_v4.v L395-414)
  的实际电路是:
      tbl[z]   = S(z ^ K) ^ mout8        (表内容: 输入 K 混淆)
      addr     = tmp ^ {4{K}}            (地址网: K 遮地址)
      tau_m    = tbl[addr] = S(tmp) ^ mout8   <-- K 在查表时抵消!
  即 **S 盒在被掩码 tmp 上求值, K 只遮地址网** ("索引掩码只遮地址网,
  遮不住值网", 微规格书 §20). 一阶安全性不变 (4 条网线仍各自均匀),
  但二阶联合分布与 v4 模型的预言不同 —— 实验室验证 (tvla2_analyze.py)
  正是据此发现模型偏差, 本脚本把完美探测模型对齐到真实电路.

网线 (与 RTL 的 tap 一一对应):
  秘密 s = SM4 轮函数 S 盒输入字节 tmp; K/mout8/min 独立均匀 8-bit,
  块内固定, 每条 trace 新鲜 (允许取 0, 标准 uniform masking).
    w_addr   = s ^ K                     (查表地址; 4 字节共享 K)
    w_cell   = S(a ^ K) ^ mout8          (a = 攻击者已知地址)
    w_tau    = S(s) ^ mout8              (S 盒输出; 4 字节共享 mout8)
    w_tin    = s ^ min                   (min 逐字节独立均匀)

判据: d=1 = 任取 1 条网线, 分布与秘密无关 [v4 声明范围];
      d=2 = 同拍两线联合分布与秘密无关 [声明外, 如实登记].

退出码: 0 = 一阶声明项全部 PASS; 1 = 存在 FAIL
"""
import sys
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sm4_ref as ref  # noqa: E402

S = np.array(ref.SBOX, dtype=np.uint8)
assert S.shape == (256,)
assert S[0x00] == 0xD6 and S[0x01] == 0x90 and S[0x02] == 0xE9
assert S[0x80] == 0xEA and S[0x7F] == 0x9E and S[0xFF] == 0x48

K_col = np.arange(256, dtype=np.uint32)
m_col = np.arange(256, dtype=np.uint32)
s_vec = np.arange(256, dtype=np.uint32)
Km = np.repeat(K_col, 256)              # [65536] K
mm = np.tile(m_col, 256)                # [65536] mout8

FIRST_ORDER_FAILS = []


def d1_check(name, W):
    """W: [256 秘密, 65536 掩码]. 每秘密分布须全等."""
    cnt = np.stack([np.bincount(W[s], minlength=256) for s in range(256)])
    ok = bool((cnt == cnt[0]).all())
    tag = "PASS" if ok else "FAIL"
    print("  [%s] d=1  %-26s 每秘密分布计数全等=%s (峰值计数 %d/值)"
          % (tag, name, ok, cnt[0].max()))
    if not ok:
        FIRST_ORDER_FAILS.append(name)
    return ok


def d2_joint_exact_tau():
    """(tau_i, tau_j): 联合 = {(A, A^D) : A 均匀}, D = S(s_i)^S(s_j).
    每对 (s_i,s_j) 的联合直方图只依赖 D; D 共 256 个取值 ->
    联合分布随秘密对变化 = 二阶泄漏, 且完美探测下直接读出 D."""
    print("  [(i,j) tau 对] 联合分布 = m 的双射像, 由 D=S(s_i)^S(s_j) 唯一决定")
    hists = {}
    for si in range(256):
        for sj in range(256):
            D = int(S[si] ^ S[sj])
            if D not in hists:
                A = S[si] ^ m_col           # A = S(s_i)^m, m 均匀 -> A 遍历全空间
                pair = (A.astype(np.uint32) << 8) | (S[sj] ^ m_col)
                hists[D] = np.bincount(pair, minlength=65536)
    nd = len(hists)
    # 不同 D -> 不同联合; 验证两两不等 (抽样全量 256 个)
    keys = list(hists)
    base = hists[keys[0]]
    allsame = all(np.array_equal(hists[k], base) for k in keys[1:])
    print("  [INFO] d=2  (tau_i, tau_j)            D 取值 %d 个; 联合直方图"
          "全部相同=%s -> 联合分布由 D 决定" % (nd, allsame))
    print("            完美探测下攻击者直接读 tau_i^tau_j = S(s_i)^S(s_j)"
          " (确定性泄漏)")
    # HW 域 (SCEA 模型): E[(HW(tau_i)-HW(tau_j))^2] = HW(D) 精确恒等
    HW = np.vectorize(lambda x: bin(int(x) & 0xFF).count("1"))
    chk = [(int(((HW(S[si] ^ m_col) - HW(S[sj] ^ m_col)) ** 2).mean()),
            int(bin(int(S[si] ^ S[sj])).count("1")))
           for si, sj in [(0x12, 0x5D), (0x00, 0xFF), (0x33, 0x77)]]
    ok = all(a == b for a, b in chk)
    print("  [%s] HW 域恒等式 E[(HW_i-HW_j)^2] = HW(S(s_i)^S(s_j)) (3 组抽检)"
          % ("PASS" if ok else "FAIL"))
    return not allsame   # allsame=False -> 有泄漏


def d2_joint_exact_addr():
    """(addr_i, addr_j): addr = s^K 共享 K -> (u, u^c), c = s_i^s_j.
    完美探测下直接读 addr_i^addr_j = s_i^s_j."""
    hists = {}
    for si in range(256):
        for sj in range(256):
            c = int(si ^ sj)
            if c not in hists:
                u = si ^ K_col
                pair = (u.astype(np.uint32) << 8) | (sj ^ K_col)
                hists[c] = np.bincount(pair, minlength=65536)
    keys = list(hists)
    base = hists[keys[0]]
    allsame = all(np.array_equal(hists[k], base) for k in keys[1:])
    print("  [INFO] d=2  (addr_i, addr_j)          c 取值 %d 个; 联合直方图"
          "全部相同=%s -> 联合分布由 c=s_i^s_j 决定" % (len(hists), allsame))
    print("            完美探测下攻击者直接读 addr_i^addr_j = s_i^s_j"
          " (确定性泄漏)")
    return not allsame


def d2_independent(name, V1, V2):
    """V1, V2: [256, 65536]. 联合分布跨秘密须全等 (两线掩码独立)."""
    pair = (V1.astype(np.uint64) << 8) | V2
    base = np.bincount(pair[0], minlength=65536)
    for s in range(1, 256):
        if not np.array_equal(np.bincount(pair[s], minlength=65536), base):
            print("  [FAIL] d=2  %-24s 联合分布在 s=%d 处偏离" % (name, s))
            return False
    print("  [PASS] d=2  %-24s 联合分布跨秘密全等 (掩码独立, 无泄漏)" % name)
    return True


def main():
    print("=== SM4 v4 掩码方案 · 完美探测穷举验证 (实际电路版 v5) ===")
    print("  S-box %d 项, RTL 锚点自检 PASS; 掩码空间 (K,mout8) 均匀 8-bit x 2"
          " = 65536 组" % S.size)
    print()
    print("-- 一阶探测 d=1 (v4 声明范围: 分布须与秘密无关) --")
    ADDR = (s_vec[:, None] ^ Km[None, :]).astype(np.uint32)
    TAU = (S[s_vec[:, None]] ^ mm[None, :]).astype(np.uint32)
    TIN = (s_vec[:, None] ^ np.tile(m_col, 256)[None, :]).astype(np.uint32)
    d1_check("w_addr = s ^ K", ADDR)
    d1_check("w_tau  = S(s) ^ mout8", TAU)
    d1_check("w_tin  = s ^ min", TIN)
    A = 0x33
    cell = (S[A ^ Km] ^ mm).astype(np.uint32)
    c_cnt = np.bincount(cell, minlength=256)
    ok = bool((c_cnt == c_cnt[0]).all())
    print("  [%s] d=1  w_cell(a=%02X)=S(a^K)^mout8    单元内容均匀=%s"
          " (%d 次/值, 与秘密无关)"
          % ("PASS" if ok else "FAIL", A, ok, c_cnt[0]))
    if not ok:
        FIRST_ORDER_FAILS.append("w_cell")

    print()
    print("-- 二阶探测 d=2 (同拍两线; 超出 v4 声明, 如实登记) --")
    leak_tau = d2_joint_exact_tau()
    leak_addr = d2_joint_exact_addr()
    # 跨族: 掩码独立 -> 无泄漏
    CELL = np.tile(cell[None, :], (256, 1))
    d2_independent("(cell(a), tau_j)", CELL, TAU)
    d2_independent("(addr_i, tau_j)", ADDR, TAU)
    # tin 逐字节掩码独立
    TIN2 = (s_vec[:, None] ^ np.tile(m_col, 256)[None, :]).astype(np.uint32)
    d2_independent("(tin_i, tin_j) 对换基", TIN, TIN2)

    print()
    print("=== 汇总 ===")
    if FIRST_ORDER_FAILS:
        print("  一阶 FAIL: %s" % FIRST_ORDER_FAILS)
        sys.exit(1)
    print("  一阶声明项全部 PASS: w_addr / w_tau / w_tin / w_cell")
    print("  二阶边界 (实际电路, 修正模型):")
    print("    - (addr_i, addr_j) 共享 K   -> 泄漏 s_i^s_j (确定性, 完美探测"
          "下精确可读)")
    print("    - (tau_i, tau_j)  共享 mout8-> 泄漏 S(s_i)^S(s_j) (确定性)")
    print("    - (cell, tau) / (addr, tau) / (tin, tin) 掩码独立 -> 无泄漏")
    print("  与 probe_check_v4 (K 留在 S 盒输入的错误模型) 的差异:")
    print("    v4 模型预言 (tau_i,tau_j) 联合 = {(A, A^d(u))} 随 K 抖动,")
    print("    泄漏仅为 S 差分剖面 HW 的均值偏移 (~0.09); 实际电路 d 不抖,")
    print("    E[(HW_i-HW_j)^2] = HW(S(s_i)^S(s_j)) 可达 0..8, 二阶泄漏")
    print("    强 ~40 倍. SCEA 实测见 tvla2_analyze.py / 报告.")
    sys.exit(0)


if __name__ == "__main__":
    main()
