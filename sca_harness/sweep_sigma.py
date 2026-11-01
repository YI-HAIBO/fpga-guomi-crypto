"""sigma 扫描: 复用 tvla2_analyze 的函数, 只输出汇总行.

用法: python sweep_sigma.py [dump]
"""
import io, json, os, re, subprocess, sys

HAR = r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto\sca_harness"
PY = r"C:\Users\Yi\.workbuddy\binaries\python\versions\3.13.12\python.exe"
dump = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HAR, "sim", "scea2_dump.txt")


def run(sigma):
    out_json = os.path.join(HAR, "sim", "tvla2_r0_sigma%g.json" % sigma)
    cmd = [PY, os.path.join(HAR, "tvla2_analyze.py"), dump,
           "--sigma", "%.2f" % sigma, "--json", out_json]
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8",
                       errors="replace", timeout=1800)
    txt = r.stdout or ""
    res = dict(sigma=sigma, t2_tau=None, t2_tintau=None, cpa_hit=0, ge=None)
    m = re.search(r"tau x tau.*?max\|t\|\s*=\s*([\d.]+)", txt)
    if m: res["t2_tau"] = float(m.group(1))
    m = re.search(r"tin x tau.*?max\|t\|\s*=\s*([\d.]+)", txt)
    if m: res["t2_tintau"] = float(m.group(1))
    res["cpa_hit"] = txt.count("(HIT)")
    m = re.search(r"rank\(true\)=0\s+GE:\s*(.*)", txt)
    if m: res["ge"] = m.group(1).strip()
    res["t1_worst"] = None
    m = re.search(r"一阶: NO-LEAK \(worst \|t\| = ([\d.]+)\)", txt)
    if m: res["t1_worst"] = float(m.group(1))
    return res, txt


print(" sigma |  一阶 worst|t| |  二阶 tau x tau |t| |  tin x tau |t| | CPA命中 | GE(首对)")
print("-------+---------------+-------------------+--------------+--------+----------")
rows = []
for s in [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0]:
    res, txt = run(s)
    rows.append(res)
    print(" %5.1f |    %8.3f    |     %9.3f      |   %8.3f   |  %d/6  | %s" % (
        s, res["t1_worst"] if res["t1_worst"] is not None else -1,
        res["t2_tau"] if res["t2_tau"] is not None else -1,
        res["t2_tintau"] if res["t2_tintau"] is not None else -1,
        res["cpa_hit"], (res["ge"] or "")[:60]))

# 找 CPA 边界
last_hit = max([r["sigma"] for r in rows if r["cpa_hit"] >= 6], default=None)
first_miss = min([r["sigma"] for r in rows if r["cpa_hit"] < 6], default=None)
print()
print("CPA 6/6 全恢复最高 sigma: %s ; 首次失败 sigma: %s" % (last_hit, first_miss))
det = [r["sigma"] for r in rows if (r["t2_tau"] or 0) > 4.5]
print("tau x tau TVLA 检出(|t|>4.5) 的 sigma: %s" % det)
with open(os.path.join(HAR, "sim", "sweep_sigma_summary.json"), "w", encoding="utf-8") as f:
    json.dump(rows, f, ensure_ascii=False, indent=1)
print("[save] sweep_sigma_summary.json")
