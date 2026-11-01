#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sm4_ref.py -- SM4 参考模型 (用于侧信道功耗建模 + 合成 trace + 交叉校验)

S-box 直接从 RTL 的 sbox_rom.hex 加载, 保证与硬件逐字节一致 (权威源是 RTL,
非 GB/T 文档转录, 避免转录误差)。全加密用 KAT 锚点自验:
    key = pt = 0123456789ABCDEFFEDCBA9876543210
    ->  ct = 681EDF34D206965E86B3E94F536E4246

只依赖标准库 + 可选 numpy。可独立运行做自检:
    python sm4_ref.py
"""
import os

_HERE = os.path.dirname(os.path.abspath(__file__))
# sbox_rom.hex 相对本工程的 RTL 路径; 允许用环境变量覆盖
_SBOX_HEX_CANDIDATES = [
    os.path.join(_HERE, "..", "rtl", "sm4", "sbox_rom.hex"),
    os.path.join(_HERE, "rtl", "sm4", "sbox_rom.hex"),
]


def load_sbox(path=None):
    """加载 256 字节 S-box (每行一个 hex 字节)。"""
    if path is None:
        for c in _SBOX_HEX_CANDIDATES:
            if os.path.exists(c):
                path = c
                break
    if path is None or not os.path.exists(path):
        raise FileNotFoundError("sbox_rom.hex not found; set SBOX_HEX env var")
    vals = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            # 每行可能含一个或多个 hex 字节
            for tok in line.split():
                vals.append(int(tok, 16) & 0xFF)
    if len(vals) != 256:
        raise ValueError("expected 256 sbox bytes, got %d" % len(vals))
    return vals


SBOX = load_sbox()
# 预计算 FK / CK
FK = [0xA3B1BAC6, 0x56AA3350, 0x677D9197, 0xB27022DC]


def _ck(i):
    """CK_i 4 字节 = (7*(4i+j)) & 0xFF, j=0..3, 高字节在前。"""
    b = [(7 * (4 * i + j)) & 0xFF for j in range(4)]
    return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]


CK = [_ck(i) for i in range(32)]

MASK = 0xFFFFFFFF


def _rol(x, n):
    n &= 31
    return ((x << n) | (x >> (32 - n))) & MASK


def _tau(a):
    """非线性变换 tau: 4 字节各过 S-box。"""
    return ((SBOX[(a >> 24) & 0xFF] << 24) |
            (SBOX[(a >> 16) & 0xFF] << 16) |
            (SBOX[(a >> 8) & 0xFF] << 8) |
            (SBOX[a & 0xFF]))


def _L(a):
    return a ^ _rol(a, 2) ^ _rol(a, 10) ^ _rol(a, 18) ^ _rol(a, 24)


def _Lp(a):
    return a ^ _rol(a, 13) ^ _rol(a, 23)


def _T(a):
    return _L(_tau(a))


def _Tp(a):
    return _Lp(_tau(a))


def key_schedule(key):
    """key: 128-bit int -> rk[0..31]"""
    K = [(key >> (32 * (3 - i))) & MASK for i in range(4)]
    K = [K[i] ^ FK[i] for i in range(4)]
    rk = []
    X = list(K)
    for i in range(32):
        # SM4 密钥扩展: rk[i] = K[i+4] = K[i] ^ T'(K[i+1]^K[i+2]^K[i+3]^CK[i])
        # 注意状态量与轮键是同一个值 (都用 T'), 不可再用加密的 T (曾在此踩坑)
        r = (X[i] ^ _Tp(X[i + 1] ^ X[i + 2] ^ X[i + 3] ^ CK[i])) & MASK
        rk.append(r)
        X.append(r)
    return rk


def encrypt_block(key, pt):
    """加密单个 128-bit 块。key/pt: int -> ct: int"""
    rk = key_schedule(key)
    X = [(pt >> (32 * (3 - i))) & MASK for i in range(4)]
    Xl = list(X)
    for i in range(32):
        Xl.append((Xl[i] ^ _T(Xl[i + 1] ^ Xl[i + 2] ^ Xl[i + 3] ^ rk[i])) & MASK)
    # 密文 = (X35, X34, X33, X32), 最高位字是 X35 (SM4 输出为反序)
    ct = 0
    for j in range(4):
        ct = (ct << 32) | Xl[35 - j]
    return ct


def bytes_to_int(b):
    v = 0
    for x in b:
        v = (v << 8) | (int(x) & 0xFF)   # int(x): 避免 numpy uint8 移位溢出
    return v


def int_to_bytes(v, n=16):
    return bytes([(v >> (8 * (n - 1 - i))) & 0xFF for i in range(n)])


# ---- 第 1 轮 S-box 输入/输出 (CPA 功耗模型的目标中间值) ----
def round1_sbox_in(key, pt):
    """返回 4 个 32-bit 字的第 1 轮 tau 输入 (即 S-box 输入, 未过 S-box)。"""
    rk = key_schedule(key)
    X = [(pt >> (32 * (3 - i))) & MASK for i in range(4)]
    # round0: tmp = X1^X2^X3^rk0 -> tau(tmp) 是 S-box 作用对象
    return X[1] ^ X[2] ^ X[3] ^ rk[0]


def round1_sbox_out(key, pt):
    """第 1 轮 S-box 输出 (过 tau, 未过 L)。"""
    return _tau(round1_sbox_in(key, pt))


def _selftest():
    key = bytes_to_int(bytes.fromhex("0123456789ABCDEFFEDCBA9876543210"))
    pt = key
    ct = encrypt_block(key, pt)
    got = "%032X" % ct
    exp = "681EDF34D206965E86B3E94F536E4246"
    print("SBOX[0..3] =", [hex(x) for x in SBOX[:4]])
    print("rk0 = %08X (expect F12186F9)" % key_schedule(key)[0])
    print("ct  =", got)
    print("exp =", exp)
    ok = (got == exp)
    print("SELFTEST:", "PASS" if ok else "FAIL")
    return ok


if __name__ == "__main__":
    import sys
    sys.exit(0 if _selftest() else 1)
