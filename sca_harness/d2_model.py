#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SM4 v4 二阶泄漏: 解析模型 + 固定组 c_f 落点.

理论 (与 probe_check_v4.py 的完美探测 d=2 边界一致):
  tau_i = S(s_i ^ K) ^ mout8 ,  tau_j = S(s_j ^ K) ^ mout8   (K, mout8 块内共享)
  令 A = S(s_i^K) ^ mout8,  d = S(s_i^K) ^ S(s_j^K) = S(u) ^ S(u^c),  u = s_i^K 均匀
  组合模型 (HW 乘积):
      h(c) = E[ HW(A) * HW(A^d) ] = 4 - 0.5 * E_u[ HW(S(u) ^ S(u^c)) ]
  c = s_i ^ s_j  ->  二阶泄漏正是 h(c) 对 c 的依赖.
"""
import sys
import os
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sm4_ref as ref  # noqa: E402

S = np.array(ref.SBOX, dtype=np.uint8)
u = np.arange(256, dtype=np.uint8)
HW = np.vectorize(lambda x: bin(int(x) & 0xFF).count("1"))

Ehw = np.zeros(256)
h = np.zeros(256)
for c in range(256):
    d = S[u] ^ S[np.bitwise_xor(u, c)]
    Ehw[c] = HW(d).mean()
    h[c] = 4.0 - 0.5 * Ehw[c]

print("=== h(c) = E[HW(tau_i)*HW(tau_j)] 二阶乘积模型 ===")
print("  h(0)  = %.4f   (c=0: 两字节相同 -> HW(A)*HW(A) = E[HW^2] = 18/4.5?"
      " 实测 %.4f)" % (h[0], 4.0))
print("  h(c!=0): mean=%.4f std=%.4f min=%.4f@c=%d max=%.4f@c=%d"
      % (h[1:].mean(), h[1:].std(), h[1:].min(), int(h[1:].argmin()) + 1,
         h[1:].max(), int(h[1:].argmax()) + 1))
print("  E_u[HW(S(u)^S(u^c))]: c=0 -> 0.000 ; c!=0 mean=%.4f std=%.4f"
      % (Ehw[1:].mean(), Ehw[1:].std()))
print("  -> 二阶乘积信号: 固定 c_f 相对均匀 c 均值的偏离 = h(c_f) - %.4f"
      % h[1:].mean())
print()

# ---- 本 harness 固定明文 + rk0 的 6 个字节对 ----
pt = bytes.fromhex("0123456789ABCDEFFEDCBA9876543210")
key = bytes.fromhex("0123456789ABCDEFFEDCBA9876543210")
rk = ref.key_schedule(ref.bytes_to_int(key))
rk0 = rk[0]
X1 = int.from_bytes(pt[0:4], "big")
X2 = int.from_bytes(pt[4:8], "big")
X3 = int.from_bytes(pt[8:12], "big")
tmp = X1 ^ X2 ^ X3 ^ rk0
s = [(tmp >> 24) & 0xFF, (tmp >> 16) & 0xFF, (tmp >> 8) & 0xFF, tmp & 0xFF]
print("=== round-0 固定组 ===")
print("  rk0 = %08X" % rk0)
print("  s (tmp 字节, MSB 先) = %s" % " ".join("%02X" % v for v in s))
mean_h = h[1:].mean()
for i in range(4):
    for j in range(i + 1, 4):
        c = s[i] ^ s[j]
        print("  pair(%d,%d): c_f=0x%02X  h(c_f)=%.4f  delta=%+.4f"
              % (i, j, c, h[c], h[c] - mean_h))
print()
print("=== 探测性估算 (TVLA t 值, 无噪声) ===")
# sigma_P: HW(A)*HW(A^d) 的边缘标准差, 用 c 均匀混合近似
# 直接由 (A, d) 联合枚举做不到 (d 依赖 u), 用 c=0x33 的条件抽样近似:
rng = np.random.default_rng(0)
A = rng.integers(0, 256, 200000, dtype=np.uint8)
D = S[u] ^ S[np.bitwise_xor(u, 0x33)]
D = rng.choice(D, 200000)
prod = HW(A).astype(float) * HW(np.bitwise_xor(A, D)).astype(float)
print("  sigma_HW_product (近似) = %.3f" % prod.std())
print("  N=2000 : t ~ %.2f * sqrt(N)" % (0.0))
for N in (2000, 10000, 50000, 200000):
    for dname, dv in (("delta_typ(0.05)", 0.05), ("delta_max(0.15)", 0.15)):
        t = dv * np.sqrt(N) / prod.std()
        print("  N=%6d %-16s -> |t| ~ %.2f" % (N, dname, t))
