# FPGA SM4 Masked Crypto Coprocessor — Data & Code Repository

This repository contains the data and code supporting the paper:

**"Quantifying the RO-TRNG Entropy--Masking Security Chain: Frequency Injection, MRS Threshold Behavior, and Second-Order Leakage Elimination in an SM4 FPGA Coprocessor"**

## Repository Structure

```
rtl/              # Verilog RTL source (SM4 engine, TRNG, PCIe subsystem, etc.)
sca_harness/      # Side-channel analysis scripts and summary data
  data/           # Summary data (JSON, PNG) — large trace datasets excluded via .gitignore
  *.py           # Trace generation, TVLA, CPA, MRS sweep scripts
sim/              # Simulation logs (regression, formal verification)
constraints/      # XDC constraint files
docs/             # Paper and documentation (EXCLUDED from this repo)
```

## Key Data Files

| File | Description |
|------|-------------|
| `sca_harness/data/mrs_curve.json` | Coarse MRS sweep (α = 0.0 to 1.0, step 0.1) |
| `sca_harness/data/mrs_curve_fine.json` | Fine MRS sweep (α = 0.0 to 0.15, step 0.02) |
| `sca_harness/data/mrs_noise_comparison.json` | Noise robustness sweep (σ = 0.5, 1.0, 2.0) |
| `sim/regression_v4indep_*.log` | Full regression test log (8/8 PASS) |
| `sim/sbox_equiv/sbox_equiv_prove_*.log` | Yosys SAT formal verification log |

## Key Code Modules

| Module | Description |
|--------|-------------|
| `rtl/sm4/sm4_engine_masked_v4.v` | SM4 engine with shared-mask output re-masking (v4, integrated DUT) |
| `rtl/sm4/sm4_engine_masked_v4_indep.v` | SM4 engine with byte-wise independent output masking (v5, simulation evaluation) |
| `rtl/trng/trng_sm3_v3.v` | RO-TRNG v3 with physical entropy source (ring oscillators) |
| `sca_harness/run_mrs_sweep.py` | MRS curve sweep: trace generation → TVLA → CPA → MRS |
| `sca_harness/gen_mrs_traces.py` | Degraded trace generation with α-parameterized mask knowledge |

## Reproducibility

The paper's simulation-based results are reproducible using the scripts in this repository:

1. **MRS curves**: `cd sca_harness && python run_mrs_sweep.py`
2. **Regression tests**: Refer to `sim/regression_v4indep_*.log` for the 8/8 PASS results
3. **Formal verification**: `cd sim/sbox_equiv && python run_sbox_equiv_prove.py`

## Note on Large Trace Datasets

The raw trace datasets (.npy files) in `sca_harness/data/mrs_a*/` and similar directories
are excluded from this repository due to their size (~7.8 GB total). They can be regenerated
using the scripts in `sca_harness/`. Summary JSON data files are included.

## Paper

The manuscript is available in `docs/` (excluded from this repository per the data/code-only
sharing policy).