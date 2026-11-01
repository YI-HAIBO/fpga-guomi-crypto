"""
使用 gmssl 生成 SM3 测试向量 (权威参考)
"""
from gmssl import sm3

def sm3_hash(msg: bytes) -> str:
    return sm3.sm3_hash(list(msg))

if __name__ == "__main__":
    test_cases = [
        (b'', "empty (0 bytes)"),
        (b"abc", "'abc' (3 bytes)"),
        (b"\x00" * 32, "32 bytes zero"),
        (b"\x01" * 32, "32 bytes 0x01"),
        (b"a" * 61, "61 bytes 'a'"),
        (b"\x01" * 64, "64 bytes 0x01"),
        (b"\x01" * 128, "128 bytes 0x01"),
        (b"\x01" * 192, "192 bytes 0x01"),
        (b"abcdbcdecdefdefgfeghghighijhijkijkljklmklmnlmnomnopnopq", "NIST 448-bit"),
    ]
    
    print("SM3 Test Vectors (from pycryptodome, authoritative)")
    print("=" * 90)
    print(f"{'Case':35s} {'Length':>8s}   {'Hash (hex)':66s}")
    print("-" * 90)
    
    for msg, name in test_cases:
        h = sm3_hash(msg)
        print(f"{name:35s} {len(msg):>8d}   {h}")
    
    print("\n\nVerilog literals for use in testbench:")
    print("-" * 90)
    for msg, name in test_cases:
        h = sm3_hash(msg)
        print(f"{name:35s} -> 256'h{h}")
