#!/usr/bin/env python3
"""Generate clean 128-bit SM4 test vectors (no PKCS7 padding)."""
from gmssl.sm4 import SM4_BOXES_TABLE as SBOX

FK = [0xa3b1bac6, 0x56aa3350, 0x677d9197, 0xb27022dc]
CK = [
    0x00070e15, 0x1c232a31, 0x383f464d, 0x545b6269,
    0x70777e85, 0x8c939aa1, 0xa8afb6bd, 0xc4cbd2d9,
    0xe0e7eef5, 0xfc030a11, 0x181f262d, 0x343b4249,
    0x50575e65, 0x6c737a81, 0x888f969d, 0xa4abb2b9,
    0xc0c7ced5, 0xdce3eaf1, 0xf8ff060d, 0x141b2229,
    0x30373e45, 0x4c535a61, 0x686f767d, 0x848b9299,
    0xa0a7aeb5, 0xbcc3cad1, 0xd8dfe6ed, 0xf4fb0209,
    0x10171e25, 0x2c333a41, 0x484f565d, 0x646b7279,
]

def rotl(x, n):
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF

def tau(A):
    return (SBOX[(A >> 24) & 0xFF] << 24) | (SBOX[(A >> 16) & 0xFF] << 16) | \
           (SBOX[(A >> 8) & 0xFF] << 8) | (SBOX[A & 0xFF])

def L(B):
    return B ^ rotl(B, 2) ^ rotl(B, 10) ^ rotl(B, 18) ^ rotl(B, 24)

def Lp(B):
    return B ^ rotl(B, 13) ^ rotl(B, 23)

def T(A): return L(tau(A))
def Tp(A): return Lp(tau(A))

def sm4_encrypt(key_hex, pt_hex, decrypt=False):
    """Encrypt/decrypt 16 bytes. Returns 16-byte hex."""
    key = bytes.fromhex(key_hex)
    data = bytes.fromhex(pt_hex)
    
    MK = [int.from_bytes(key[i*4:(i+1)*4], 'big') for i in range(4)]
    K = [MK[0]^FK[0], MK[1]^FK[1], MK[2]^FK[2], MK[3]^FK[3]]
    rk = []
    for i in range(32):
        K.append(K[i] ^ Tp(K[i+1] ^ K[i+2] ^ K[i+3] ^ CK[i]))
        rk.append(K[i+4])
    
    if decrypt:
        rk = rk[::-1]  # Reverse round keys for decryption
    
    X = [int.from_bytes(data[i*4:(i+1)*4], 'big') for i in range(4)]
    for i in range(32):
        X.append(X[i] ^ T(X[i+1] ^ X[i+2] ^ X[i+3] ^ rk[i]))
    
    out = [X[35], X[34], X[33], X[32]]  # Reversed per SM4 spec
    return b''.join(x.to_bytes(4, 'big') for x in out).hex()

# Test 1: Official standard
key1 = '0123456789abcdeffedcba9876543210'
pt1 = '0123456789abcdeffedcba9876543210'
ct1 = sm4_encrypt(key1, pt1)
pt1_dec = sm4_encrypt(key1, ct1, decrypt=True)
print(f"[Test 1] Official standard")
print(f"  Key:       0x{key1}")
print(f"  Plaintext: 0x{pt1}")
print(f"  Ciphertext: 0x{ct1}")
print(f"  Decrypt:   0x{pt1_dec}")
print(f"  Roundtrip: {pt1_dec == pt1}")
print()

# Test 2: Zero
key2 = '00000000000000000000000000000000'
pt2 = '00000000000000000000000000000000'
ct2 = sm4_encrypt(key2, pt2)
pt2_dec = sm4_encrypt(key2, ct2, decrypt=True)
print(f"[Test 2] Zero key + zero plaintext")
print(f"  Key:       0x{key2}")
print(f"  Plaintext: 0x{pt2}")
print(f"  Ciphertext: 0x{ct2}")
print(f"  Decrypt:   0x{pt2_dec}")
print(f"  Roundtrip: {pt2_dec == pt2}")
print()

# Test 3: All FF
key3 = 'ffffffffffffffffffffffffffffffff'
pt3 = 'ffffffffffffffffffffffffffffffff'
ct3 = sm4_encrypt(key3, pt3)
pt3_dec = sm4_encrypt(key3, ct3, decrypt=True)
print(f"[Test 3] All-FF key + all-FF plaintext")
print(f"  Key:       0x{key3}")
print(f"  Plaintext: 0x{pt3}")
print(f"  Ciphertext: 0x{ct3}")
print(f"  Decrypt:   0x{pt3_dec}")
print(f"  Roundtrip: {pt3_dec == pt3}")
print()

# Test 4: Random-looking key
key4 = 'deadbeefcafebabe12345678abcdef00'
pt4 = 'a5f0b2c1d3e4f5a6b7c8d9e0f1a2b3c4'
ct4 = sm4_encrypt(key4, pt4)
pt4_dec = sm4_encrypt(key4, ct4, decrypt=True)
print(f"[Test 4] Random key + random plaintext")
print(f"  Key:       0x{key4}")
print(f"  Plaintext: 0x{pt4}")
print(f"  Ciphertext: 0x{ct4}")
print(f"  Decrypt:   0x{pt4_dec}")
print(f"  Roundtrip: {pt4_dec == pt4}")

print()
print("=" * 70)
print("Verilog-ready vectors:")
print("=" * 70)
print(f"// Test 1: Official")
print(f"key1      = 128'h{key1}")
print(f"plaintext1= 128'h{pt1}")
print(f"exp_ct1   = 128'h{ct1}")
print(f"// Test 2: Zero")
print(f"key2      = 128'h{key2}")
print(f"plaintext2= 128'h{pt2}")
print(f"exp_ct2   = 128'h{ct2}")
print(f"// Test 3: All-FF")
print(f"key3      = 128'h{key3}")
print(f"plaintext3= 128'h{pt3}")
print(f"exp_ct3   = 128'h{ct3}")
print(f"// Test 4: Random")
print(f"key4      = 128'h{key4}")
print(f"plaintext4= 128'h{pt4}")
print(f"exp_ct4   = 128'h{ct4}")
