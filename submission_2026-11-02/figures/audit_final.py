"""Final audit script for SM4 masked coprocessor paper v2.0"""
import os
import re

FILES = {
    'MD论文': 'fpga-guomi-crypto/docs/SM4掩码协处理器一体化安全设计与评估_论文_v2.md',
    'TEX论文': 'fpga-guomi-crypto/docs/SM4掩码协处理器_论文_v2.tex',
    'HTML预览': 'fpga-guomi-crypto/docs/SM4掩码协处理器_论文预览.html',
    '架构图': 'fpga-guomi-crypto/docs/figures/architecture.svg',
    'MRS图': 'fpga-guomi-crypto/docs/figures/mrs_curve.svg',
}

print("=== 交付物状态 ===")
for name, path in FILES.items():
    exists = os.path.exists(path)
    sz = os.path.getsize(path) if exists else 0
    print(f"  [{'OK' if exists else 'MISS'}] {name}: {sz:>10,} bytes")

# Read files
with open('fpga-guomi-crypto/docs/SM4掩码协处理器一体化安全设计与评估_论文_v2.md', 'r', encoding='utf-8') as f:
    md = f.read()

with open('fpga-guomi-crypto/docs/SM4掩码协处理器_论文_v2.tex', 'r', encoding='utf-8') as f:
    tex = f.read()

print(f"\nMD: {len(md):,} chars, {md.count(chr(10))+1} lines")
print(f"TEX: {len(tex):,} chars, {tex.count(chr(10))+1} lines")

# TEX environment balance
print("\nTEX 环境平衡:")
envs = ['document', 'table', 'tabular', 'lstlisting', 'thebibliography', 'abstract', 'IEEEkeywords', 'figure']
for env in envs:
    beg = len(re.findall(r'\\begin{' + env + r'}', tex))
    end = len(re.findall(r'\\end{' + env + r'}', tex))
    s = 'OK' if beg == end else 'FAIL'
    print(f"  [{s}] {env}: {beg}/{end}")

# AI phrasing
print("\nAI表述检查:")
ai_phrases = ['首次', '打通', '揭示了', '核心发现', '我们构建', '鲜有工作']
for phrase in ai_phrases:
    c_md = md.count(phrase)
    c_tex = tex.count(phrase)
    if c_md > 0 or c_tex > 0:
        print(f"  [WARN] '{phrase}': MD={c_md}, TEX={c_tex}")
    else:
        print(f"  [OK] '{phrase}': 0")

# Arrows in prose
lines = md.split(chr(10))
in_code = False
arrows = 0
for line in lines:
    s = line.strip()
    if s.startswith('```'):
        in_code = not in_code
        continue
    if in_code:
        continue
    if '\u2192' in line:  # →
        arrows += 1
print(f"\n\u2192 箭头 (MD正文): {arrows}")

# Image marks
img_tag = '!['
print(f"\n图片标记: {md.count(img_tag)}")
for i, line in enumerate(md.split(chr(10))):
    if img_tag in line:
        print(f"  L{i+1}: {line.strip()[:120]}")

# Abstract check
idx_abs = md.find('**摘要**')
idx_kw = md.find('**关键词**')
if idx_abs >= 0 and idx_kw > idx_abs:
    abstract = md[idx_abs:idx_kw]
    has_formula = bool(re.search(r'[\$\^\_]', abstract))
    has_arrow = '\u2192' in abstract
    print(f"\n摘要: 公式={has_formula}, 箭头={has_arrow}, 长度={len(abstract)}")

# Data consistency
print("\n数据一致性 (MD vs TEX):")
all_ok = True
data_vals = ['4,522', '49.84', '1.12', '6/6', '0/6', '约5%', '0.052', '82.5', '6.89', '57.8', '49', '+12', '261', '15/15', '12/12']
for val in data_vals:
    in_md = val in md
    in_tex = val in tex
    if not (in_md and in_tex):
        all_ok = False
        print(f"  [FAIL] '{val}': MD={in_md}, TEX={in_tex}")
if all_ok:
    print("  [OK] All 15 data points consistent")

# Version codes
print("\n代码清理:")
code_pats = [
    (r'\bv[345]\b', 'v3/v4/v5'),
    (r'P\d+-\d+', 'P0-x'),
    (r'\.v\b', 'verilog file'),
    (r'\.txt\b', 'txt file'),
    (r'\.py\b', 'py file'),
    (r'\.bit\b', 'bit file'),
    (r'\.dcp\b', 'dcp file'),
    (r'phase\d+', 'phase ref'),
    (r'wrap\d+', 'wrap ref'),
    (r'\.workbuddy', 'workbuddy path'),
    (r'fpga-guomi', 'project name'),
]
for pat, name in code_pats:
    md_m = re.findall(pat, md)
    tex_m = re.findall(pat, tex)
    if md_m or tex_m:
        if name == 'v3/v4/v5' and all(x in ['v3', 'v3.2'] for x in md_m + tex_m):
            pass  # OK - PCIe hardware spec
        else:
            all_ok = False
            print(f"  [WARN] {name}: MD={md_m}, TEX={tex_m}")

# HTML
with open('fpga-guomi-crypto/docs/SM4掩码协处理器_论文预览.html', 'r', encoding='utf-8') as f:
    html = f.read()
print(f"\nHTML: {len(html):,} chars, tables={html.count('<table>')}, imgs={html.count('<img>')}, figures={html.count('<figure>')}")

print(f"\n{'='*50}")
print(f"FINAL: {'ALL PASS' if all_ok else 'SOME FAILURES'}")
print(f"{'='*50}")