# -*- coding: utf-8 -*-
"""Beautify all 5 paper figures as clean vector SVGs (real <text>, consistent with tables).
   Writes SVGs to docs/figures; caller converts to PDF via rsvg-convert."""
import os

FIG = r"C:\Users\Yi\WorkBuddy\2026-10-02-09-55-51\fpga-guomi-crypto\docs\figures"

# ---- shared palette / style ----
BG = "#FFFFFF"
AXIS = "#888780"
GRID = "#E8E7E2"
DARK = "#2A2926"
MID = "#5F5E5A"
LIGHT = "#F5F3EE"

def svg_header(w, h, title, subtitle=None):
    sub = (f'<text x="{w//2}" y="30" text-anchor="middle" font-family="sans-serif" '
           f'font-size="11" fill="{MID}">{subtitle}</text>') if subtitle else ""
    return (f'<svg viewBox="0 0 {w} {h}" xmlns="http://www.w3.org/2000/svg" '
            f'xmlns:xlink="http://www.w3.org/1999/xlink" role="img" aria-label="{title}">\n'
            f'<title>{title}</title>\n<desc>{title}</desc>\n'
            f'<rect x="0" y="0" width="{w}" height="{h}" fill="{BG}"/>\n'
            f'<text x="{w//2}" y="22" text-anchor="middle" font-family="sans-serif" '
            f'font-size="14" font-weight="600" fill="{DARK}">{title}</text>\n{sub}')

def close_svg():
    return '</svg>'

# =====================================================================
# Fig 1: System Architecture (improved)
# =====================================================================
def architecture():
    w, h = 700, 440
    s = svg_header(w, h, "Integrated Coprocessor System Architecture")
    s += f'''<rect x="20" y="40" width="{w-40}" height="{h-60}" rx="14" fill="{LIGHT}" stroke="#B4B2A9" stroke-width="0.5"/>
  <text x="{w//2}" y="62" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="600" fill="{DARK}">FPGA (xc7a200tsbg484-2) · 20,270 LUTs, 15.06%</text>
  <!-- PCIe frontend -->
  <g><rect x="40" y="80" width="120" height="64" rx="8" fill="#E6F1FB" stroke="#378ADD" stroke-width="0.5"/>
    <text x="100" y="104" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="600" fill="#0C447C">PCIe Frontend</text>
    <text x="100" y="120" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#0C447C">DMA + MSI-X</text>
    <text x="100" y="136" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">x1 Gen2, 5 GT/s</text></g>
  <!-- Coordinator -->
  <g><rect x="230" y="80" width="130" height="64" rx="8" fill="#EAF3DE" stroke="#639922" stroke-width="0.5"/>
    <text x="295" y="104" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="600" fill="#27500A">Encryption Coordinator</text>
    <text x="295" y="120" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#27500A">task scheduling / mask distribution</text>
    <text x="295" y="136" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">16-state FSM</text></g>
  <!-- RO-TRNG -->
  <g><rect x="470" y="80" width="120" height="64" rx="8" fill="#FAEEDA" stroke="#BA7517" stroke-width="0.5"/>
    <text x="530" y="104" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="600" fill="#633806">RO-TRNG</text>
    <text x="530" y="120" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#633806">physical entropy source</text>
    <text x="530" y="136" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">3 ROs + health monitor</text></g>
  <!-- SM4 engine -->
  <g><rect x="190" y="190" width="220" height="80" rx="8" fill="#EEEDFE" stroke="#534AB7" stroke-width="0.5"/>
    <text x="300" y="216" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="600" fill="#26215C">SM4 Independent Masking Engine</text>
    <text x="300" y="235" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#3C3489">4-stage masked pipeline · 49 cycles/block · 4,522 LUT</text>
    <text x="300" y="253" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">byte-wise independent output masking · 2nd-order TI</text></g>
  <!-- Physical layer -->
  <g><rect x="40" y="310" width="560" height="90" rx="8" fill="#FAECE7" stroke="#D85A30" stroke-width="0.5"/>
    <text x="320" y="336" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="600" fill="#712B13">Physical Layer (RO-TRNG + Frequency Injection)</text>
    <text x="320" y="356" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#993C1D">f_RO = 1/(2N·t_inv) → t_inv_eff = t_inv × (1 + A_inj × sin(2π·f_inj·t))</text>
    <text x="320" y="374" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">FI attack surface: altering RO effective delay degrades sampled entropy</text></g>
  <!-- arrows -->
  <line x1="160" y1="112" x2="225" y2="112" stroke="#5F5E5A" stroke-width="0.6" stroke-dasharray="3,3" marker-end="url(#a1)"/>
  <line x1="360" y1="112" x2="465" y2="112" stroke="#5F5E5A" stroke-width="0.6" stroke-dasharray="3,3" marker-end="url(#a1)"/>
  <line x1="100" y1="144" x2="100" y2="185" stroke="#378ADD" stroke-width="1" marker-end="url(#a1)"/>
  <line x1="295" y1="144" x2="295" y2="185" stroke="#378ADD" stroke-width="1" marker-end="url(#a1)"/>
  <line x1="530" y1="144" x2="530" y2="185" stroke="#378ADD" stroke-width="1" marker-end="url(#a1)"/>
  <line x1="300" y1="270" x2="300" y2="305" stroke="#378ADD" stroke-width="1" marker-end="url(#a1)"/>
  <!-- legend -->
  <rect x="40" y="405" width="10" height="10" fill="#E6F1FB" stroke="#378ADD" stroke-width="0.5"/>
  <text x="55" y="414" font-family="sans-serif" font-size="10" fill="{MID}">Control plane (AXI-Lite)</text>
  <line x1="180" y1="410" x2="210" y2="410" stroke="#378ADD" stroke-width="1" marker-end="url(#a1)"/>
  <text x="220" y="414" font-family="sans-serif" font-size="10" fill="{MID}">Data plane (AXI-Stream)</text>
  <defs><marker id="a1" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
    <path d="M2 1L8 5L2 9" fill="none" stroke="#5F5E5A" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></marker></defs>'''
    s += close_svg()
    return s

# =====================================================================
# Fig 2: MRS Curve (improved)
# =====================================================================
def mrs_curve():
    w, h = 680, 380
    s = svg_header(w, h, "MRS Curve and CPA Recovery Rate vs. Attacker Knowledge")
    L, R, T, B = 60, 640, 40, 320
    def X(a): return L + (R-L)*a
    def Y(v): return B - (B-T)*v
    # axes
    s += f'<line x1="{L}" y1="{B}" x2="{R}" y2="{B}" stroke="{AXIS}" stroke-width="1"/>\n'
    s += f'<line x1="{L}" y1="{B}" x2="{L}" y2="{T}" stroke="{AXIS}" stroke-width="1"/>\n'
    for v, lab in [(0.0,'0.0'),(0.2,'0.2'),(0.4,'0.4'),(0.6,'0.6'),(0.8,'0.8'),(1.0,'1.0')]:
        s += f'<text x="{X(v)}" y="{B+18}" text-anchor="middle" font-family="sans-serif" font-size="11" fill="{MID}">{lab}</text>\n'
        s += f'<text x="{L-8}" y="{Y(v)+4}" text-anchor="end" font-family="sans-serif" font-size="11" fill="{MID}">{lab}</text>\n'
        s += f'<line x1="{L}" y1="{Y(v)}" x2="{R}" y2="{Y(v)}" stroke="{GRID}" stroke-width="0.5" stroke-dasharray="2,4"/>\n'
    s += f'<text x="{L-30}" y="{T+150}" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="600" fill="{DARK}" transform="rotate(-90,{L-30},{T+150})">MRS / CPA recovery rate</text>\n'
    s += f'<text x="{(L+R)//2}" y="{h-10}" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="600" fill="{DARK}">Attacker mask knowledge α</text>\n'
    # threshold region
    s += f'<rect x="{X(0)}" y="{T}" width="{X(0.052)-X(0)}" height="{B-T}" fill="#E24B4A" fill-opacity="0.06"/>\n'
    s += f'<text x="{X(0.026)}" y="{T+16}" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#E24B4A">threshold region</text>\n'
    # MRS curve (blue): stays 1.0 until ~0.05 then drops
    mrs_pts = [(0,1.0),(0.02,1.0),(0.04,0.75),(0.05,0.5),(0.06,0.25),(0.08,0.0),(1.0,0.0)]
    s += '<polyline points="' + ' '.join(f'{X(a):.1f},{Y(v):.1f}' for a,v in mrs_pts) + '" fill="none" stroke="#378ADD" stroke-width="2.5"/>\n'
    for a,v in mrs_pts:
        s += f'<circle cx="{X(a):.1f}" cy="{Y(v):.1f}" r="3.5" fill="#378ADD"/>\n'
    # CPA recovery (red dashed): 0 until ~0.05 then jumps to 1.0
    cpa_pts = [(0,0.0),(0.04,0.0),(0.05,0.5),(0.06,1.0),(1.0,1.0)]
    s += '<polyline points="' + ' '.join(f'{X(a):.1f},{Y(v):.1f}' for a,v in cpa_pts) + '" fill="none" stroke="#D85A30" stroke-width="2" stroke-dasharray="6,3"/>\n'
    for a,v in cpa_pts:
        s += f'<circle cx="{X(a):.1f}" cy="{Y(v):.1f}" r="3.5" fill="#D85A30"/>\n'
    # alpha_crit annotation
    s += f'<line x1="{X(0.052)}" y1="{Y(0)}" x2="{X(0.052)}" y2="{Y(1.0)}" stroke="#E24B4A" stroke-width="0.6" stroke-dasharray="3,3"/>\n'
    s += f'<text x="{X(0.052)}" y="{B+34}" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="600" fill="#E24B4A">α_crit ≈ 0.052</text>\n'
    # legend
    s += f'<rect x="{R-150}" y="{T+8}" width="14" height="3" fill="#378ADD"/>\n'
    s += f'<text x="{R-130}" y="{T+13}" font-family="sans-serif" font-size="11" fill="{MID}">MRS (mask residual strength)</text>\n'
    s += f'<line x1="{R-150}" y1="{T+30}" x2="{R-136}" y2="{T+30}" stroke="#D85A30" stroke-width="2" stroke-dasharray="6,3"/>\n'
    s += f'<text x="{R-130}" y="{T+35}" font-family="sans-serif" font-size="11" fill="{MID}">CPA recovery rate (4/4)</text>\n'
    s += close_svg()
    return s

# =====================================================================
# Fig 3: RO-TRNG (improved)
# =====================================================================
def ro_trng():
    w, h = 680, 320
    s = svg_header(w, h, "RO-TRNG Physical Entropy Source Architecture")
    def box(x, y, wd, ht, fill, stroke, title, sub1, sub2=None):
        r = f'<g><rect x="{x}" y="{y}" width="{wd}" height="{ht}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="0.5"/>\n'
        r += f'<text x="{x+wd//2}" y="{y+22}" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="600" fill="{title}">{title}</text>\n'
        r += f'<text x="{x+wd//2}" y="{y+40}" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">{sub1}</text>\n'
        if sub2: r += f'<text x="{x+wd//2}" y="{y+54}" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">{sub2}</text>\n'
        r += '</g>\n'
        return r
    s += box(40, 40, 100, 60, "#FAEEDA", "#BA7517", "RO11", "11-stage inverter", "~10 MHz")
    s += box(180, 40, 100, 60, "#FAEEDA", "#BA7517", "RO9", "9-stage inverter", "~12 MHz")
    s += box(320, 40, 100, 60, "#FAEEDA", "#BA7517", "RO7", "7-stage inverter", "~15 MHz")
    s += box(460, 40, 100, 60, "#E6F1FB", "#378ADD", "D-FF", "100 MHz sampling", "1-bit jitter")
    s += box(200, 150, 160, 60, "#EEEDFE", "#534AB7", "xs64 Mixer", "xorshift 64-bit", "32-bit mask seed")
    s += box(420, 150, 140, 60, "#EAF3DE", "#639922", "Health Monitor", "T1-T7 SP 800-90B", "AXI-Lite report")
    s += box(40, 150, 140, 60, "#FCEBEB", "#E24B4A", "Frequency Injection", "A_inj, f_inj", "→ t_inv_eff")
    for x1, y1, x2, y2 in [(140,70,175,70),(280,70,315,70),(420,70,455,70),
                            (510,100,510,145),(110,100,110,145),(230,100,230,145),(370,100,370,145)]:
        s += f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="#5F5E5A" stroke-width="0.6" marker-end="url(#a2)"/>\n'
    s += f'<line x1="280" y1="210" x2="280" y2="250" stroke="#534AB7" stroke-width="1" marker-end="url(#a2)"/>\n'
    s += f'<text x="280" y="268" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">mask seed → SM4 engine</text>\n'
    s += '<defs><marker id="a2" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse"><path d="M2 1L8 5L2 9" fill="none" stroke="#5F5E5A" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></marker></defs>\n'
    s += close_svg()
    return s

# =====================================================================
# Fig 4: Resource Distribution (rebuilt, consistent with Table IV)
# =====================================================================
def resource_dist():
    w, h = 680, 360
    s = svg_header(w, h, "FPGA Resource Distribution by Functional Module")
    L, R, T, B = 80, 640, 40, 300
    def X(i, n): return L + (R-L)*(i+0.5)/n
    def Y(v, ymax): return B - (B-T)*v/ymax
    groups = ["SM4 Masking\nEngine", "Remaining\nPlatform"]
    lut = [4522, 20270-4522]
    ff  = [5840, 15273-5840]
    ymax = 22000
    s += f'<line x1="{L}" y1="{B}" x2="{R}" y2="{B}" stroke="{AXIS}" stroke-width="1"/>\n'
    s += f'<line x1="{L}" y1="{B}" x2="{L}" y2="{T}" stroke="{AXIS}" stroke-width="1"/>\n'
    for v in [0, 5000, 10000, 15000, 20000]:
        s += f'<text x="{L-8}" y="{Y(v,ymax)+4}" text-anchor="end" font-family="sans-serif" font-size="10" fill="{MID}">{v:,}</text>\n'
        s += f'<line x1="{L}" y1="{Y(v,ymax)}" x2="{R}" y2="{Y(v,ymax)}" stroke="{GRID}" stroke-width="0.5" stroke-dasharray="2,4"/>\n'
    s += f'<text x="{L-30}" y="{T+130}" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="600" fill="{DARK}" transform="rotate(-90,{L-30},{T+130})">Resource Count</text>\n'
    bw = 70; gap = 28
    for gi, g in enumerate(groups):
        cx = X(gi, 2)
        # LUT bar
        s += f'<rect x="{cx-bw-gap//2}" y="{Y(lut[gi],ymax)}" width="{bw}" height="{B-Y(lut[gi],ymax)}" fill="#378ADD" rx="3"/>\n'
        s += f'<text x="{cx-bw-gap//2+bw//2}" y="{Y(lut[gi],ymax)-6}" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="600" fill="#0C447C">{lut[gi]:,}</text>\n'
        # FF bar
        s += f'<rect x="{cx+gap//2}" y="{Y(ff[gi],ymax)}" width="{bw}" height="{B-Y(ff[gi],ymax)}" fill="#D85A30" rx="3"/>\n'
        s += f'<text x="{cx+gap//2+bw//2}" y="{Y(ff[gi],ymax)-6}" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="600" fill="#712B13">{ff[gi]:,}</text>\n'
        s += f'<text x="{cx}" y="{B+16}" text-anchor="middle" font-family="sans-serif" font-size="11" fill="{DARK}">{g}</text>\n'
    # utilization annotation
    s += f'<text x="{X(0,2)}" y="{T+14}" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#27500A">SM4 = 22.3% of platform LUTs, 38.2% of platform FFs</text>\n'
    s += f'<text x="{X(1,2)}" y="{T+14}" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">platform = 15.06% device LUTs</text>\n'
    # legend
    s += f'<rect x="{R-180}" y="{T+2}" width="12" height="12" fill="#378ADD" rx="2"/>\n'
    s += f'<text x="{R-164}" y="{T+12}" font-family="sans-serif" font-size="10" fill="{MID}">LUT</text>\n'
    s += f'<rect x="{R-120}" y="{T+2}" width="12" height="12" fill="#D85A30" rx="2"/>\n'
    s += f'<text x="{R-104}" y="{T+12}" font-family="sans-serif" font-size="10" fill="{MID}">FF</text>\n'
    s += close_svg()
    return s

# =====================================================================
# Fig 5: Performance Comparison (rebuilt, consistent with perf table)
# =====================================================================
def perf_comparison():
    w, h = 680, 360
    s = svg_header(w, h, "Throughput Comparison: Shared Mask vs Independent Mask")
    L, R, T, B = 80, 640, 40, 300
    def X(i, n): return L + (R-L)*(i+0.5)/n
    def Y(v, ymax): return B - (B-T)*v/ymax
    schemes = ["Shared Mask", "Independent Mask\n(this work)"]
    vals = [261, 261]
    ymax = 300
    s += f'<line x1="{L}" y1="{B}" x2="{R}" y2="{B}" stroke="{AXIS}" stroke-width="1"/>\n'
    s += f'<line x1="{L}" y1="{B}" x2="{L}" y2="{T}" stroke="{AXIS}" stroke-width="1"/>\n'
    for v in [0, 50, 100, 150, 200, 250, 300]:
        s += f'<text x="{L-8}" y="{Y(v,ymax)+4}" text-anchor="end" font-family="sans-serif" font-size="10" fill="{MID}">{v}</text>\n'
        s += f'<line x1="{L}" y1="{Y(v,ymax)}" x2="{R}" y2="{Y(v,ymax)}" stroke="{GRID}" stroke-width="0.5" stroke-dasharray="2,4"/>\n'
    s += f'<text x="{L-30}" y="{T+130}" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="600" fill="{DARK}" transform="rotate(-90,{L-30},{T+130})">Throughput (Mbps)</text>\n'
    bw = 110
    for gi, g in enumerate(schemes):
        cx = X(gi, 2)
        col = "#B4B2A9" if gi == 0 else "#378ADD"
        s += f'<rect x="{cx-bw//2}" y="{Y(vals[gi],ymax)}" width="{bw}" height="{B-Y(vals[gi],ymax)}" fill="{col}" rx="4"/>\n'
        s += f'<text x="{cx}" y="{Y(vals[gi],ymax)-8}" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="700" fill="#0C447C">{vals[gi]} Mbps</text>\n'
        s += f'<text x="{cx}" y="{B+30}" text-anchor="middle" font-family="sans-serif" font-size="11" fill="{DARK}">{g}</text>\n'
    s += f'<text x="{X(0,2)}" y="{B+46}" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">4,510 LUTs</text>\n'
    s += f'<text x="{X(1,2)}" y="{B+46}" text-anchor="middle" font-family="sans-serif" font-size="10" fill="{MID}">4,522 LUTs (+12, +0.26%)</text>\n'
    s += f'<text x="{(L+R)//2}" y="{h-10}" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="600" fill="#27500A">throughput preserved: 261 Mbps, 49 cycles/block</text>\n'
    s += close_svg()
    return s

# ---- write all ----
for name, fn in [("architecture.svg", architecture), ("mrs_curve.svg", mrs_curve),
                 ("ro_trng.svg", ro_trng), ("resource_dist.svg", resource_dist),
                 ("perf_comparison.svg", perf_comparison)]:
    p = os.path.join(FIG, name)
    with open(p, "w", encoding="utf-8") as f:
        f.write(fn())
    print(f"Wrote {p} ({os.path.getsize(p)} bytes)")