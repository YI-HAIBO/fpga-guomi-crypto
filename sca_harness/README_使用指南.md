# SCA 采集与分析 Harness 使用指南

- 位置：`fpga-guomi-crypto/sca_harness/`
- 目标：对 Nexys A7 200T 上的掩码/未掩码 SM4 引擎做 **TVLA（Welch t-test）+ 一阶 CPA** 对照测量
- 状态：**分析链已通过合成数据端到端自验证；RTL 已通过 iverilog 功能仿真；实采待物理设备**
- 依赖：Python 3.10+（numpy / scipy / matplotlib / pandas 必需；pyserial 仅实采需要）
- Python：`C:\Users\Yi\.workbuddy\binaries\python\versions\3.13.12\python.exe`
- iverilog：`C:\iverilog\bin\iverilog.exe`（必须 `-g2005`）

---

## 1. 目录结构

```
sca_harness/
├── rtl/
│   ├── sm4_tvla_top.v        # TVLA 顶层：UART 送明文/密钥 → SM4 引擎 → 16B 密文回读 + trigger
│   └── tb_sm4_tvla.v         # 功能 TB（-DTVLA_MASKED 切换掩码引擎）
├── constraints/
│   └── nysa7_tvla.xdc        # Nexys A7 200T 引脚约束
├── acquire_traces.py         # 采集入口（硬件模式 / 合成模式）
├── gen_synth_traces.py       # 合成 trace 生成器（泄漏模型）
├── tvla_analyze.py           # Welch t-test + 泄漏判定 + 出图
├── cpa_sm4.py                # 一阶 CPA（对 rk0 逐字节）+ GE-vs-traces
├── sm4_ref.py                # SM4 纯软件参考模型（含 KAT 自验）
├── sim/                      # 已编译的 tb_*.vvp（构建产物）
├── data/                     # trace 数据集
└── debug_scratch/            # 调试用 TB 与 vvp（已归档，勿用于构建）
```

---

## 2. RTL：目标顶层的接口

```verilog
module sm4_tvla_top #(
    parameter USE_MASKED = 1'b0,   // 0 = sm4_engine.v      (未掩码)
                              // 1 = sm4_engine_masked_v3.v (掩码表重计算)
    parameter OV         = 6       // UART 过采样倍率
)(
    input  wire        clk,        // 100 MHz, 包 pin E3
    input  wire        uart_rxd,   // C4  (FPGA 收)
    output wire        uart_txd,   // D4  (FPGA 发)
    output wire        trigger,    // C17 (Pmod JA1) → 示波器 CH2
    output wire [7:0]  led         // N14/R18/V17/U17/U16/H17/W16/V15
);
```

**帧协议（8N1, 115200）**：主机发送 16 字节明文 → 引擎加密 → FPGA 回读 16 字节密文。
密钥在首次明文前预置（可用默认 KAT 密钥，见 §5）。`trigger` 在加密开始瞬间拉高一个脉冲，
**这是示波器采样的时间原点**——所有 trace 必须按此对齐，否则 CPA 泄漏点全部丢失。

### 2.1 功能验证（本地，无硬件）

```bash
PY=C:/Users/Yi/.workbuddy/binaries/python/versions/3.13.12/python.exe
IV=C:/iverilog/bin/iverilog.exe; VVP=C:/iverilog/bin/vvp.exe
BASE=C:/Users/Yi/WorkBuddy/2026-10-02-09-55-51/fpga-guomi-crypto/sca_harness
SM4=C:/Users/Yi/WorkBuddy/2026-10-02-09-55-51/fpga-guomi-crypto/rtl/sm4

SRC=("$BASE/rtl/sm4_tvla_top.v" "$BASE/rtl/tb_sm4_tvla.v" \
     "$SM4/sm4_engine.v" "$SM4/sm4_engine_masked_v3.v")

# 未掩码
$IV -g2005 -o "$BASE/sim/tb_UNMASKED.vvp" "${SRC[@]}" && $VVP "$BASE/sim/tb_UNMASKED.vvp"
# 掩码
$IV -g2005 -DTVLA_MASKED -o "$BASE/sim/tb_MASKED.vvp" "${SRC[@]}" && $VVP "$BASE/sim/tb_MASKED.vvp"
```

两种变体均应输出：`ct_n=16 errors=0 overlap=0 trig=1` 且密文与 KAT 一致。

> 本机 bash shim 的 `cd`/`ls`/`mkdir`/`head` 失效，请用上述绝对路径形式，
> 或包一层 `python -c` + `subprocess` 调用。

---

## 3. 数据格式（分析链的输入契约）

`data/<name>/` 下必须有以下文件：

| 文件 | 形状 / 内容 | 说明 |
|---|---|---|
| `traces.npy` | float64 `(N, S)` | 每条一条功耗曲线，**第 0 样本必须对齐 trigger** |
| `pts.npy` | uint8 `(N, 16)` | 每条对应的明文（大端，首字节为最高字节） |
| `labels.npy` | uint8 `(N,)` | 分组标签（合成模式：0=fixed, 1=random） |
| `meta.json` | dict | 至少含 `model`、`nsamples`、`key`、`leak_idxs` |

`meta.json` 关键字段：

| 字段 | 含义 |
|---|---|
| `model` | `leaky` 或 `masked` |
| `rk0` | 真实第 1 轮轮键（大写 hex），供 CPA 对答案 |
| `target_word_bytes` | 本轮泄漏的 rk0 字节位置 `[0,1,2,3]` |
| `leak_idxs` | 泄漏所在采样点索引（4 个字节各一个，泄漏模型用） |
| `n_fixed` / `n_random` | 合成模式的分组规模（TVLA 需要） |

---

## 4. 端到端流程

### 4.1 无硬件自检（随时可跑）

```bash
cd $BASE
PY=.../python.exe

# (1) SM4 参考模型自验（打印 rk0 与密文锚点）
$PY sm4_ref.py

# (2) 生成合成数据集
$PY acquire_traces.py --synthetic --variant leaky  --n 5000 --nsamples 2000 --out data/smoke_leaky
$PY acquire_traces.py --synthetic --variant masked --n 5000 --nsamples 2000 --out data/smoke_masked

# (3) TVLA
$PY tvla_analyze.py data/smoke_leaky
$PY tvla_analyze.py data/smoke_masked

# (4) CPA + GE 曲线
$PY cpa_sm4.py data/smoke_leaky  --ge
$PY cpa_sm4.py data/smoke_masked --ge
```

**期望结果**（判定逻辑正确的判据）：

| 数据集 | TVLA | CPA |
|---|---|---|
| leaky | `max\|t\|` ≫ 4.5 → **LEAK** | 完整恢复 `rk0=F12186F9` |
| masked | `max\|t\|` < 4.5 → **NO-LEAK** | 相关度 ≈ 0.05–0.15（噪声底） |

若漏码不触发或掩码被攻破，**先怀疑数据对齐，而不是分析代码**。

### 4.2 硬件模式（需要设备）

```bash
$PY acquire_traces.py --port COM3 --baud 115200 --iters 20 --settle 0.2 --meta run.json
```

主机负责：按 UART 协议送入明文帧 → 收 16 字节密文回读 → 校验与 `sm4_ref` 一致。
示波器负责：以 `trigger` 为原点采集功耗，落盘为 `traces.npy`。

> 实采脚本中的示波器部分为占位实现（`--synthetic` 走合成路径）。接入具体设备
> （示波器 SDK / ChipWhisperer API）时只需替换采集函数，输出仍须满足 §3 的格式。

---

## 5. 关键常数与锚点

| 项 | 值 |
|---|---|
| 默认密钥 | `0123456789ABCDEFFEDCBA9876543210` |
| 默认明文 | `0123456789ABCDEFFEDCBA9876543210` |
| **期望密文** | **`681EDF34D206965E86B3E94F536E4246`** |
| `rk0` | `F12186F9` |
| `X4`（第 1 轮输出锚点） | `27FAD345` |
| 引擎周期 | 34 clk / 块（密钥扩展 16 + 数据 32 + 输出） |
| UART | 8N1, 115200 |
| 时钟 | 100 MHz @ E3；片内二分频得 clk50 |

**CPA 方法学要点（勿改）**：SM4 第 1 轮 S-box 输入为 `X1^X2^X3^rk0`，
四个明文字**全部混合**进入同一 S-box 输入，没有 AES 式的预白化
（AES 可以按字节独立猜测单字节密钥，SM4 不能）。因此本 harness 的 CPA
**对 `rk0` 的 4 个字节逐一独立猜测**，4 个并联 S-box 各自可独立恢复，
所需泄漏模型为 4 个并行的 HW(SBox(·))。合成实验中 4/4 字节全部恢复，
正是这条设计成立的直接证据。

---

## 6. 引脚对照（`constraints/nysa7_tvla.xdc`）

| 信号 | Pin | 说明 |
|---|---|---|
| `clk` | E3 | 100 MHz，板载晶振 |
| `uart_rxd` | C4 | USB-UART → FPGA |
| `uart_txd` | D4 | FPGA → USB-UART |
| `trigger` | C17 | Pmod JA 首脚 → 示波器 CH2 |
| `led[0..7]` | N14 R18 V17 U17 U16 H17 W16 V15 | 复用 board15 已验证引脚 |

全部引脚与 `constraints/nysa7_board_v15.xdc`（v1.2，已通过时序签核）一致，
USB-UART 与 Pmod trigger 为新增，均取自 Digilent 官方 Master.xdc。

---

## 7. 已知限制

1. **未做物理采集**：`acquire_traces.py` 的硬件模式仅完成链路协议与数据格式，
   示波器采集中间件待接。`--synthetic` 模式完整可用。
2. **仅一阶**：`cpa_sm4.py` 是一阶 GE 分析。二阶需替换为二阶聚合，当前未实现。
3. **泄漏模型是 HW(SBox)**：真实芯片可能是 HD 或电荷模型，
   实采时若相关度偏低可切换 `cpa_sm4.py` 内的模型函数。
4. **`debug_scratch/`** 内是历史调试 TB 与 vvp，**不要**把它们加入构建源列表。
