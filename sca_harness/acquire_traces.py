#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""acquire_traces.py -- sm4_tvla_top 主机侧采集 / 校验驱动

用途
----
1) 硬件模式 (--port COMx): 通过 USB 串口向板卡注入密钥+明文, 读回 FPGA 计算的
   密文并与本机 sm4_ref 对拍, 确认链路无误后才值得采集功耗。
2) 合成模式 (--synthetic): 不需要硬件, 直接调用 gen_synth_traces 造一组 trace,
   用于在拿到示波器/逻辑分析仪数据前先把 TVLA + CPA 分析链路跑通。

为什么必须先做 (1) 再采集功耗
------------------------------
侧信道实验最大的坑是"主机发的明文"和"硬件实际算的明文"不一致(字节序、大小端、
UART 丢字)。如果这一步不对, 后面几十万条 trace 全部作废。本脚本把明文/密文
回读做成逐块校验, 通过后才允许进入采集循环。

依赖
----
硬件模式需要 pyserial:  pip install pyserial
其余 (numpy) 是本机已有的。

用法
----
  python acquire_traces.py --synthetic --variant leaky  --n 5000 --out data/synth_leaky
  python acquire_traces.py --synthetic --variant masked --n 5000 --out data/synth_masked
  python acquire_traces.py --port COM3 --baud 115200 --iters 20
  python acquire_traces.py --port COM3 --baud 115200 --plaintext 0123456789ABCDEFFEDCBA9876543210
"""
import argparse
import json
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sm4_ref  # noqa: E402

# 协议: 首字节 0xA5 = 明文帧头, 其后 16 字节为明文 (big-endian, 与 TB 一致)。
#       回读 16 字节 = 密文 (big-endian)。
FRAME_HEAD = 0xA5


def build_frame(pt_hex):
    """构造一帧明文 (17 字节)。"""
    pt = bytes.fromhex(pt_hex)
    assert len(pt) == 16, "plaintext must be 16 bytes"
    return bytes([FRAME_HEAD]) + pt


def check_link(key_hex, pt_hex):
    """用本机参考模型算密文, 作为硬件回读的对拍基准。"""
    key = bytes.fromhex(key_hex)
    pt = bytes.fromhex(pt_hex)
    exp_ct = sm4_ref.encrypt(key, pt)
    return exp_ct.hex().upper()


# ----------------------------------------------------------------------------
# 硬件模式
# ----------------------------------------------------------------------------
def run_hardware(args):
    try:
        import serial  # 延迟导入: 本机未装 pyserial 时不影响合成模式
    except ImportError:
        print("[FAIL] 缺少 pyserial。安装: pip install pyserial")
        print("[INFO] 可先用 --synthetic 在无硬件情况下验证分析链路。")
        return 2

    exp_ct = check_link(args.key, args.plaintext)
    print("[1] 参考模型密文 : %s" % exp_ct)
    print("[2] 打开串口     : %s @ %d baud" % (args.port, args.baud))

    with serial.Serial(args.port, args.baud, timeout=0.2) as ser:
        # 等板上 POR 释放 + echo 路径稳定
        time.sleep(args.settle)
        ok = 0
        bad = 0
        log = []
        t0 = time.time()
        for i in range(args.iters):
            ser.reset_input_buffer()
            frame = build_frame(args.plaintext)
            ser.write(frame)
            ser.flush()
            # 一帧往返: 明文 17B + 密文 16B, 115200 下约 3.2 ms, 留 4x 裕量
            raw = b""
            deadline = time.time() + 0.5
            while len(raw) < 16 and time.time() < deadline:
                chunk = ser.read(16 - len(raw))
                if chunk:
                    raw += chunk
                else:
                    time.sleep(0.0005)
            if len(raw) == 16 and raw.hex().upper() == exp_ct:
                ok += 1
            else:
                bad += 1
                if bad <= 3:
                    got = raw.hex().upper() if raw else "<empty>"
                    print("    iter %4d MISMATCH got=%s exp=%s" % (i, got, exp_ct))
            log.append((i, len(raw), raw.hex().upper() if raw else ""))

        dt = time.time() - t0
        rate = (ok + bad) / dt if dt > 0 else 0.0
        print("[3] 结果       : %d/%d 匹配 (%.2f%%), 吞吐 %.1f 块/s"
              % (ok, ok + bad, 100.0 * ok / max(1, ok + bad), rate))

        meta = {
            "mode": "hardware",
            "port": args.port,
            "baud": args.baud,
            "ov": 54 if args.baud == 115200 else None,
            "key": args.key,
            "plaintext": args.plaintext,
            "expected_ciphertext": exp_ct,
            "iters": args.iters,
            "matched": ok,
            "mismatched": bad,
            "throughput_blocks_per_sec": round(rate, 3),
            "note": "本脚本只校验数据链路。功耗采集需示波器以 trigger 为外触发, "
                    "每帧一通道, 帧与 trace 由 trigger 脉冲对齐。",
        }
        outp = os.path.abspath(args.meta or os.path.join(HERE, "data", "link_check.json"))
        os.makedirs(os.path.dirname(outp), exist_ok=True)
        with open(outp, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2, ensure_ascii=False)
        print("[4] 链路报告    -> %s" % outp)

    return 0 if ok > 0 and bad == 0 else 1


# ----------------------------------------------------------------------------
# 合成模式
# ----------------------------------------------------------------------------
def run_synthetic(args):
    import gen_synth_traces as g

    variant = "leaky" if args.variant == "leaky" else "masked"
    outdir = os.path.abspath(args.out)
    os.makedirs(outdir, exist_ok=True)

    # --n 是"每组"样本数 (fixed/random 各 --n 条), 与 gen_synth_traces 一致
    key = sm4_ref.bytes_to_int(bytes.fromhex(args.key))
    ds = g.gen(
        variant,
        n_fixed=args.n,
        n_random=args.n,
        nsamples=args.nsamples,
        key=key,
        amp=args.leak,
        noise=args.noise,
        seed=args.seed,
    )
    g.save(ds, outdir)
    print("[synthetic] variant=%s n/group=%d seed=%d amp=%s noise=%s"
          % (variant, args.n, args.seed, args.leak, args.noise))
    print("[synthetic] -> %s" % outdir)
    print("[synthetic] traces  = %s" % os.path.join(outdir, "traces.npy"))
    print("[synthetic] pts     = %s" % os.path.join(outdir, "pts.npy"))
    print("[synthetic] labels  = %s" % os.path.join(outdir, "labels.npy"))
    print("[synthetic] meta    = %s" % os.path.join(outdir, "meta.json"))
    return 0


# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="sm4_tvla_top 采集/校验驱动")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--synthetic", action="store_true",
                      help="无硬件: 生成合成 trace 验证分析链路")
    mode.add_argument("--port", help="串口设备名, 如 COM3 / /dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--key", default="0123456789ABCDEFFEDCBA9876543210")
    ap.add_argument("--plaintext",
                    default="0123456789ABCDEFFEDCBA9876543210",
                    help="16 字节明文 (32 个 hex 字符)")
    ap.add_argument("--iters", type=int, default=20, help="硬件模式往返次数")
    ap.add_argument("--settle", type=float, default=0.2, help="上电后等待秒数")
    ap.add_argument("--variant", choices=["leaky", "masked"], default="leaky")
    ap.add_argument("--n", type=int, default=5000, help="合成模式每组样本数")
    ap.add_argument("--nsamples", type=int, default=2000, help="合成模式每条采样点数")
    ap.add_argument("--seed", type=int, default=20261025)
    ap.add_argument("--leak", type=float, default=1.0, help="合成泄漏强度")
    ap.add_argument("--noise", type=float, default=1.0, help="合成噪声幅度")
    ap.add_argument("--out", help="合成模式输出目录")
    ap.add_argument("--meta", help="硬件模式链路报告 JSON 路径")
    a = ap.parse_args()

    if a.synthetic or a.port is None:
        if a.out is None:
            a.out = os.path.join(HERE, "data", "synth_%s" % a.variant)
        return run_synthetic(a)
    return run_hardware(a)


if __name__ == "__main__":
    sys.exit(main())
