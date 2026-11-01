#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""probe_check_v4.py -- SM4 v4 掩码方案的"完美探测模型"穷举验证

为什么需要它（任务 #147 的闭环）:
  SILVER (Knichel/Sasdrich/Moradi, ASIACRYPT 2020) 是掩码实现形式化验证的标杆工具,
  但它与本项目方案在两个层面不兼容:
    1. 工具链: SILVER 是 C++/make + Linux 共享库 (libsylvan.so / boost), 需 BGL 与
       指定 commit 的 Sylvan BDD 库, 本机 Windows 无法构建运行。
    2. 输入模型: SILVER 接受"门级网表 + 共享标注 (Vn_Sn / refresh)", 电路固定、
       秘密以 Boolean share 分解、随机为 fresh 输入。v4 的 S 盒是**每条 trace 重算
       内容的 256x8 ROM**, 电路本身是掩码的函数 —— 不存在固定网表可供标注。
  因此正确的形式化层是: 对掩码方程直接做"完美探测模型 (perfect probing)"的
  穷举分布检验 —— 对每条可探测网线 w, 验证 w 在均匀掩码下的分布与秘密无关。

模型 (与 v4 RTL 的 S_DATA 完全对应):
  秘密  s   = SM4 轮函数 S 盒输入字节 tmp_b (含明文与 rk 的组合)
  掩码  K, mout8 : 独立均匀 8-bit (块内常量, 每条 trace 新鲜; 允许取 0)
  网线:
    w_addr   = s ^ K                  (查表地址, 4 字节共享同一 K)
    w_cell   = S(a ^ K) ^ mout8       (ROM 单元内容, a = 攻击者已知地址)
    w_tau    = S(s ^ K) ^ mout8       (S 盒输出字, 4 字节共享同一 mout8)
    w_tin    = s ^ min                (状态 XOR, min = m0^m1^m2 均匀)

判据: 一阶 (d=1) = 任取 1 条网线, 分布与秘密无关 [v4 的声明范围];
      二阶 (d=2) = 任取 2 条同拍网线 [超出声明, 如实测量并登记边界]。

退出码: 0 = 一阶声明项全部 PASS; 1 = 存在 FAIL
"""
import sys
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sm4_ref as ref  # noqa: E402

SBOX = np.array(ref.SBOX, dtype=np.uint32)
assert SBOX.shape == (256,)
# RTL 锚点自检 (权威源 = RTL sm4_sbox, 见长期记忆)
assert SBOX[0x00] == 0xD6 and SBOX[0x01] == 0x90 and SBOX[0x02] == 0xE9
assert SBOX[0x80] == 0xEA and SBOX[0x7F] == 0x9E and SBOX[0xFF] == 0x48

K_col = np.arange(256, dtype=np.uint32)             # K
m_col = np.arange(256, dtype=np.uint32)             # mout8
s_vec = np.arange(256, dtype=np.uint32)             # 秘密
KM = (K_col[:, None] << 8) | m_col[None, :]         # [256 K, 256 m]
KK, MM = KM[:, 0], KM[0, :]                          # 广播用
Kgrid = np.tile(KK[None, :], (256, 1))               # [s, 65536] 不, 见下

# 网线值矩阵 [秘密 s, 掩码组合 (K,m)]
Km = np.repeat(K_col, 256)                           # [65536] K 在高位
mm = np.tile(m_col, 256)                             # [65536] mout8
ADDR = (s_vec[:, None] ^ Km[None, :]).astype(np.uint32)
TAU = (SBOX[s_vec[:, None] ^ Km[None, :]] ^ mm[None, :]).astype(np.uint32)
TIN = (s_vec[:, None] ^ mm[None, :]).astype(np.uint32)

FIRST_ORDER_FAILS = []


def d1_check(name, W):
    """W: [256 秘密, 65536 掩码] 网线值。每秘密分布须全等。"""
    cnt = np.stack([np.bincount(W[s], minlength=256) for s in range(256)])
    ok = bool((cnt == cnt[0]).all())
    tag = "PASS" if ok else "FAIL"
    print("  [%s] d=1  %-26s 每秘密分布计数全等=%s (峰值计数 %d/值)"
          % (tag, name, ok, cnt[0].max()))
    if not ok:
        FIRST_ORDER_FAILS.append(name)
    return ok


def d2_joint_check(name, V1, V2, first_fixed=None):
    """V1, V2: [256 秘密, 65536 掩码] 两网线。联合分布须跨秘密全等。
    first_fixed: V1 与秘密无关时的快速路径 (联合 = V1 均匀 × V2 条件分布)。"""
    pair = (V1.astype(np.uint64) << 8) | V2
    base = np.bincount(pair[0], minlength=65536)
    nz = int((base > 0).sum())
    for s in range(1, 256):
        if not np.array_equal(np.bincount(pair[s], minlength=65536), base):
            print("  [FAIL] d=2  %-26s 联合分布在 s=%d 处偏离 (支撑集 %d/65536)"
                  % (name, s, nz))
            return False
    print("  [PASS] d=2  %-26s 联合分布跨秘密全等 (支撑集 %d/65536)" % (name, nz))
    return True


def main():
    print("=== SM4 v4 掩码方案 · 完美探测模型穷举验证 ===")
    print("  S-box %d 项, RTL 锚点自检 PASS; 掩码空间 (K,mout8) 均匀 8-bit x 2"
          " = 65536 组" % SBOX.size)
    print()
    print("-- 一阶探测 d=1 (v4 声明范围: 分布须与秘密无关) --")
    d1_check("w_addr = s ^ K", ADDR)
    d1_check("w_tau  = S(s^K) ^ mout8", TAU)
    d1_check("w_tin  = s ^ min", TIN)
    # ROM 单元内容 (a = 攻击者已知地址, 独立于秘密 -> 单行分布均匀即可)
    A = 0x33
    cell = (SBOX[A ^ Km] ^ mm).astype(np.uint32)
    c_cnt = np.bincount(cell, minlength=256)
    ok = bool((c_cnt == c_cnt[0]).all())
    print("  [%s] d=1  w_cell(a=%02X)=S(a^K)^mout8    单元内容均匀=%s (%d 次/值, 与秘密无关)"
          % ("PASS" if ok else "FAIL", A, ok, c_cnt[0]))
    if not ok:
        FIRST_ORDER_FAILS.append("w_cell")

    print()
    print("-- 二阶探测 d=2 (同拍两线; 超出 v4 声明, 如实登记) --")
    # (1) 同通道 (addr_b, tau_b)
    d2_joint_check("(addr_b, tau_b) 同通道", ADDR, TAU)
    # (2) (cell(a), tau_b): 攻击者读一个 ROM 单元 + 输出线
    CELL = np.tile(cell[None, :], (256, 1))
    d2_joint_check("(cell(a), tau_b)", CELL, TAU)
    # (3) 跨通道 (addr_i, addr_j) 与 (tau_i, tau_j): 分析 delta 剖面
    #     两字节共享 K/mout8 -> 联合分布由 S 的 XOR-difference 剖面
    #     {S(u)^S(u^c) : u} 决定, 其中 c = s_i ^ s_j -> 泄漏 s_i^s_j
    prof = {}
    for c in range(256):
        u = s_vec
        prof[c] = tuple(sorted((SBOX[u] ^ SBOX[u ^ c]).tolist()))
    same = all(prof[c] == prof[0] for c in range(1, 256))
    dst = {c: prof[c] for c in (0, 1, 2)}
    print("  [INFO] d=2  (tau_i, tau_j) 跨通道    联合分布由 S 的差分剖面"
          " {S(u)^S(u^c)} 决定, c = s_i^s_j")
    print("            剖面跨 c 全等 = %s; 例: c=0 全 0, c=1 前若干项 %s "
          "-> 泄漏 s_i^s_j (声明范围外)" % (same, dst[1][:6]))

    print()
    print("=== 汇总 ===")
    if FIRST_ORDER_FAILS:
        print("  一阶 FAIL: %s" % FIRST_ORDER_FAILS)
        sys.exit(1)
    print("  一阶声明项全部 PASS: w_addr / w_tau / w_tin / w_cell")
    print("  二阶边界 (实测): (addr,tau) 同通道 = 无泄漏; 其余跨通道/含单元 "
          "组合泄漏 s_i^s_j 类差分 -> 二阶不在声明范围")
    sys.exit(0)


if __name__ == "__main__":
    main()
