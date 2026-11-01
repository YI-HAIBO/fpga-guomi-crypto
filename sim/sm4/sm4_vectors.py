"""
SM4 测试向量生成脚本
参考: gmssl-3.2.2 (https://github.com/abatilo/gmssl.py)
官方测试向量 (GB/T 32907-2016):
  Key:      0123456789abcdeffedcba9876543210
  Plaintext: 0123456789abcdeffedcba9876543210
  Ciphertext: 681edf34d206965e86b3e94f536e4246
"""
import sys
sys.path.insert(0, 'C:/Users/Yi/AppData/Roaming/Python/Python313/site-packages')

from gmssl.sm4 import CryptSM4, SM4_ENCRYPT, SM4_DECRYPT, ZERO
from gmssl import sm3

print("=" * 70)
print("SM4 Test Vectors - GB/T 32907-2016")
print("Reference: gmssl-3.2.2")
print("=" * 70)

# Test 1: 官方标准测试向量
key1 = bytes.fromhex('0123456789abcdeffedcba9876543210')
pt1 = bytes.fromhex('0123456789abcdeffedcba9876543210')

crypt1 = CryptSM4()
crypt1.set_key(key1, SM4_ENCRYPT)
ct1 = bytes(crypt1.crypt_ecb(pt1))
print(f"\n[Test 1] Official standard vector")
print(f"  Key:       0x{key1.hex()}")
print(f"  Plaintext: 0x{pt1.hex()}")
print(f"  Ciphertext: 0x{ct1.hex()}")
print(f"  Expected:  0x681edf34d206965e86b3e94f536e4246")

# Test 2: 零密钥 + 零明文
key2 = bytes(16)  # 16 bytes zero
pt2 = bytes(16)   # 16 bytes zero

crypt2 = CryptSM4()
crypt2.set_key(key2, SM4_ENCRYPT)
ct2 = bytes(crypt2.crypt_ecb(pt2))
print(f"\n[Test 2] Zero key + zero plaintext")
print(f"  Key:       0x{key2.hex()}")
print(f"  Plaintext: 0x{pt2.hex()}")
print(f"  Ciphertext: 0x{ct2.hex()}")

# Test 3: 全 0xFF 密钥 + 全 0xFF 明文
key3 = bytes([0xFF] * 16)
pt3 = bytes([0xFF] * 16)

crypt3 = CryptSM4()
crypt3.set_key(key3, SM4_ENCRYPT)
ct3 = bytes(crypt3.crypt_ecb(pt3))
print(f"\n[Test 3] All-FF key + all-FF plaintext")
print(f"  Key:       0x{key3.hex()}")
print(f"  Plaintext: 0x{pt3.hex()}")
print(f"  Ciphertext: 0x{ct3.hex()}")

# Test 4: 解密验证 (用 Test 1 的密文解密)
crypt1d = CryptSM4()
crypt1d.set_key(key1, SM4_DECRYPT)
pt1_dec = bytes(crypt1d.crypt_ecb(ct1))
print(f"\n[Test 4] Decrypt Test 1 ciphertext")
print(f"  Key:       0x{key1.hex()}")
print(f"  Ciphertext: 0x{ct1.hex()}")
print(f"  Plaintext: 0x{pt1_dec.hex()}")
print(f"  Match orig? {pt1_dec == pt1}")

# 输出 Verilog 测试向量
print("\n" + "=" * 70)
print("Verilog Test Vectors:")
print("=" * 70)
print(f"// Test 1: Official standard")
print(f"key1      = 128'h{key1.hex()}")
print(f"plaintext1= 128'h{pt1.hex()}")
print(f"exp_ct1   = 128'h{ct1.hex()}")
print(f"// Test 2: Zero")
print(f"key2      = 128'h{key2.hex()}")
print(f"plaintext2= 128'h{pt2.hex()}")
print(f"exp_ct2   = 128'h{ct2.hex()}")
print(f"// Test 3: All-FF")
print(f"key3      = 128'h{key3.hex()}")
print(f"plaintext3= 128'h{pt3.hex()}")
print(f"exp_ct3   = 128'h{ct3.hex()}")
