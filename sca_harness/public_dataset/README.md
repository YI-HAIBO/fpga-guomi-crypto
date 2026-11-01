# Public Trace Dataset · SM4 Masked vs Unmasked (Synthetic)

- 发布日期：2026-10-30
- 项目：fpga-guomi-crypto（GM-CRYPTO-COORD-2026）
- 用途：可复现的侧信道分析基准数据集

---

## 数据集概览

| 数据集 | 模型 | 样本数 | 周期数 | 大小 | 用途 |
|---|---|---|---|---|---|
| `synth_leaky` | leaky（未掩码） | 10,000 | 2,000 | ~160 MB | TVLA 对照组（应检出泄漏） |
| `synth_masked` | masked（v4 掩码） | 10,000 | 2,000 | ~160 MB | TVLA 实验组（应无泄漏） |
| `smoke_leaky` | leaky（未掩码） | 1,200 | 1,200 | ~11 MB | 快速自检 |
| `smoke_masked` | masked（v4 掩码） | 1,200 | 1,200 | ~11 MB | 快速自检 |

---

## 文件格式

### `traces.npy` (float32, shape=[N, T, 8])
侧信道轨迹。N = 样本数，T = 采样周期数，8 = 并联 S-box 通道数。

通道映射（由 `resolve_node_map.py` 对照 CPA 验证）：
- 列 0–3：HW(xors[31:24]), HW(xors[23:16]), HW(xors[15:8]), HW(xors[7:0])
- 列 4–7：HW(tau[31:24]), HW(tau[23:16]), HW(tau[15:8]), HW(tau[7:0])

第 b 字节（b=0 为最高字节）的 S-box 输出通道 = 列 (4+b)，S-box 输入通道 = 列 b。

### `labels.npy` (uint8, shape=[N])
每个样本对应的密钥字节标签（用于 CPA 猜测）。

### `meta.json`
实验配置元数据（密钥、rk0、噪声参数、种子等）。

### `tvalue.npy` (float32, shape=[T])
Welch t-test 的 t 值序列（由 `tvla_analyze.py` 生成）。

### `ge_vs_traces.png`
GE（猜测熵）vs 所需曲线数的收敛图（由 `cpa_sm4.py` 生成）。

---

## 泄漏模型

| 模型 | 描述 | 适用场景 |
|---|---|---|
| `leaky` | 未掩码引擎，HW(S-box 输出) 直接泄漏 | TVLA/CPA 对照组 |
| `masked` | v4 输出再掩码引擎，泄漏模型 = HW(均匀随机 share) | TVLA/CPA 实验组 |

**重要限定**：本数据集为**合成泄漏模型**（零阶 Hamming Weight），不含亚稳态、毛刺、路由耦合等物理效应。不能替代真实板级测量，但可用于：
1. 验证分析链（TVLA/CPA 判定逻辑）的正确性
2. 作为真实数据采集的基线对照
3. 论文中的方法学可复现性证据

---

## 复现步骤

```bash
# 1. 安装依赖
pip install numpy scipy matplotlib

# 2. 快速自检（smoke 数据集，秒级）
python tvla_analyze.py --dir smoke_masked
python cpa_sm4.py --dir smoke_masked

# 3. 完整分析（synth 数据集，分钟级）
python tvla_analyze.py --dir synth_masked
python cpa_sm4.py --dir synth_masked

# 4. 重新生成合成数据
python gen_synth_traces.py --model masked --n-fixed 5000 --n-random 5000 \
    --n-cycles 2000 --seed 42 --out synth_masked
```

---

## 配套 RTL

| 文件 | 说明 |
|---|---|
| `sm4_engine.v` | 未掩码 SM4 引擎（baseline） |
| `sm4_engine_masked_v4.v` | v4 输出再掩码引擎 |
| `sm4_sbox_raw.v` | 原始 S 盒（组合逻辑） |
| `sm4_sbox_masked.v` | 掩码 S 盒（表重计算 + 输出再掩码） |

---

## 引用

如使用本数据集，请引用：
> Yi H. *Public SCA Trace Dataset for SM4 Masked vs Unmasked Engine.* fpga-guomi-crypto, 2026.
> https://github.com/[project-path]/sca_harness/public_dataset

---

## 更新日志

| 日期 | 变更 |
|---|---|
| 2026-10-30 | 初始发布：synth_leaky, synth_masked, smoke_leaky, smoke_masked + 分析脚本 + RTL |