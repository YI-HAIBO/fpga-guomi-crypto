import os

fig_dir = 'fpga-guomi-crypto/docs/figures'

# Figure 1: System Architecture
fig1 = '''<svg viewBox="0 0 680 420" role="img" aria-label="一体化协处理器系统架构图">
  <title>一体化协处理器系统架构图</title>
  <desc>五个功能模块通过AXI-Lite控制总线和AXI-Stream数据总线互联的系统架构</desc>
  <defs>
    <marker id="arrow" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M2 1L8 5L2 9" fill="none" stroke="#5F5E5A" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    </marker>
  </defs>
  <rect x="20" y="20" width="640" height="380" rx="16" fill="#F1EFE8" stroke="#B4B2A9" stroke-width="0.5"/>
  <text x="340" y="44" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="500" fill="#444441">FPGA (xc7a200tsbg484-2)</text>
  <g>
    <rect x="40" y="60" width="130" height="70" rx="8" fill="#E6F1FB" stroke="#378ADD" stroke-width="0.5"/>
    <text x="105" y="80" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#0C447C">PCIe 前端</text>
    <text x="105" y="95" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#0C447C">DMA + MSI-X</text>
    <text x="105" y="110" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">x1 Gen2, 5 GT/s</text>
  </g>
  <g>
    <rect x="220" y="60" width="140" height="70" rx="8" fill="#EAF3DE" stroke="#639922" stroke-width="0.5"/>
    <text x="290" y="80" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#27500A">加密调度协调器</text>
    <text x="290" y="95" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#27500A">任务调度/掩码分发</text>
    <text x="290" y="110" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">16状态 FSM</text>
  </g>
  <g>
    <rect x="480" y="60" width="130" height="70" rx="8" fill="#FAEEDA" stroke="#BA7517" stroke-width="0.5"/>
    <text x="545" y="80" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#633806">RO-TRNG</text>
    <text x="545" y="95" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#633806">物理熵源</text>
    <text x="545" y="110" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">三路RO + 健康监测</text>
  </g>
  <g>
    <rect x="180" y="180" width="240" height="80" rx="8" fill="#EEEDFE" stroke="#534AB7" stroke-width="0.5"/>
    <text x="300" y="205" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="500" fill="#26215C">SM4 独立掩码引擎</text>
    <text x="300" y="223" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#3C3489">4层掩码流水线 · 49周期/块 · 4,522 LUT</text>
    <text x="300" y="241" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">逐字节独立输出掩码 · 二阶TI</text>
  </g>
  <g>
    <rect x="40" y="300" width="560" height="90" rx="8" fill="#FAECE7" stroke="#D85A30" stroke-width="0.5"/>
    <text x="320" y="325" text-anchor="middle" font-family="sans-serif" font-size="13" font-weight="500" fill="#712B13">物理层 (RO-TRNG + 频率注入)</text>
    <text x="320" y="345" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#993C1D">f_RO = 1/(2N·t_inv) → t_inv_eff = t_inv × (1 + A_inj × sin(2π·f_inj·t))</text>
    <text x="320" y="363" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">频率注入攻击面：改变RO有效延迟 → 降低采样熵</text>
  </g>
  <line x1="170" y1="95" x2="215" y2="95" stroke="#5F5E5A" stroke-width="0.5" stroke-dasharray="3,3" marker-end="url(#arrow)"/>
  <line x1="360" y1="95" x2="475" y2="95" stroke="#5F5E5A" stroke-width="0.5" stroke-dasharray="3,3" marker-end="url(#arrow)"/>
  <line x1="170" y1="130" x2="170" y2="175" stroke="#378ADD" stroke-width="1" marker-end="url(#arrow)"/>
  <line x1="360" y1="130" x2="360" y2="175" stroke="#378ADD" stroke-width="1" marker-end="url(#arrow)"/>
  <line x1="545" y1="130" x2="545" y2="175" stroke="#378ADD" stroke-width="1" marker-end="url(#arrow)"/>
  <line x1="300" y1="260" x2="300" y2="295" stroke="#378ADD" stroke-width="1" marker-end="url(#arrow)"/>
  <rect x="40" y="395" width="10" height="10" fill="#E6F1FB" stroke="#378ADD" stroke-width="0.5"/>
  <text x="55" y="404" font-family="sans-serif" font-size="10" fill="#5F5E5A">控制平面 (AXI-Lite)</text>
  <line x1="180" y1="400" x2="210" y2="400" stroke="#378ADD" stroke-width="1" marker-end="url(#arrow)"/>
  <text x="220" y="404" font-family="sans-serif" font-size="10" fill="#5F5E5A">数据平面 (AXI-Stream)</text>
</svg>'''

# Figure 2: MRS Curve
fig2 = '''<svg viewBox="0 0 680 380" role="img" aria-label="MRS曲线与CPA恢复率随攻击者知识度alpha的变化">
  <title>MRS曲线与CPA恢复率</title>
  <desc>展示掩码残余强度MRS和CPA密钥恢复率随攻击者知识度alpha的阈值衰减行为</desc>
  <defs>
    <marker id="arrow2" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M2 1L8 5L2 9" fill="none" stroke="#5F5E5A" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    </marker>
  </defs>
  <line x1="60" y1="320" x2="640" y2="320" stroke="#888780" stroke-width="1"/>
  <line x1="60" y1="320" x2="60" y2="30" stroke="#888780" stroke-width="1"/>
  <text x="50" y="324" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.0</text>
  <text x="50" y="254" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.2</text>
  <text x="50" y="184" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.4</text>
  <text x="50" y="114" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.6</text>
  <text x="50" y="44" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.8</text>
  <text x="30" y="180" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#444441" transform="rotate(-90,30,180)">MRS / CPA恢复率</text>
  <text x="60" y="340" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.0</text>
  <text x="176" y="340" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.2</text>
  <text x="292" y="340" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.4</text>
  <text x="408" y="340" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.6</text>
  <text x="524" y="340" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.8</text>
  <text x="640" y="340" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">1.0</text>
  <text x="350" y="365" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#444441">攻击者掩码知识度 α</text>
  <line x1="60" y1="254" x2="640" y2="254" stroke="#D3D1C7" stroke-width="0.5" stroke-dasharray="2,4"/>
  <line x1="60" y1="184" x2="640" y2="184" stroke="#D3D1C7" stroke-width="0.5" stroke-dasharray="2,4"/>
  <line x1="60" y1="114" x2="640" y2="114" stroke="#D3D1C7" stroke-width="0.5" stroke-dasharray="2,4"/>
  <line x1="60" y1="44" x2="640" y2="44" stroke="#D3D1C7" stroke-width="0.5" stroke-dasharray="2,4"/>
  <polyline points="60,44 72,44 84,44 90,184 96,320 108,320 120,320 176,320 292,320 408,320 524,320 640,320" fill="none" stroke="#378ADD" stroke-width="2.5"/>
  <circle cx="60" cy="44" r="4" fill="#378ADD"/>
  <circle cx="72" cy="44" r="4" fill="#378ADD"/>
  <circle cx="84" cy="44" r="4" fill="#378ADD"/>
  <circle cx="90" cy="184" r="5" fill="#E24B4A"/>
  <circle cx="96" cy="320" r="4" fill="#378ADD"/>
  <circle cx="108" cy="320" r="4" fill="#378ADD"/>
  <circle cx="120" cy="320" r="4" fill="#378ADD"/>
  <line x1="90" y1="184" x2="90" y2="340" stroke="#E24B4A" stroke-width="0.5" stroke-dasharray="3,3"/>
  <text x="90" y="355" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="500" fill="#E24B4A">α_crit≈0.052</text>
  <polyline points="60,320 72,320 84,320 90,320 96,320 108,320 120,44 176,44 292,44 408,44 524,44 640,44" fill="none" stroke="#D85A30" stroke-width="2" stroke-dasharray="6,3"/>
  <circle cx="120" cy="44" r="4" fill="#D85A30"/>
  <circle cx="176" cy="44" r="4" fill="#D85A30"/>
  <rect x="420" y="50" width="14" height="3" fill="#378ADD"/>
  <text x="440" y="55" font-family="sans-serif" font-size="11" fill="#5F5E5A">MRS (掩码残余强度)</text>
  <line x1="420" y1="70" x2="434" y2="70" stroke="#D85A30" stroke-width="2" stroke-dasharray="6,3"/>
  <text x="440" y="75" font-family="sans-serif" font-size="11" fill="#5F5E5A">CPA恢复率 (4/4)</text>
  <rect x="84" y="44" width="24" height="276" fill="#E24B4A" fill-opacity="0.08"/>
  <text x="96" y="30" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#E24B4A">阈值区</text>
</svg>'''

# Figure 3: Second-order leakage comparison
fig3 = '''<svg viewBox="0 0 680 340" role="img" aria-label="共享掩码与独立掩码二阶泄漏对比">
  <title>二阶泄漏对比：共享掩码 vs 独立掩码</title>
  <desc>展示共享掩码方案中tau×tau通道产生确定性泄漏，独立掩码方案消除该通道</desc>
  <line x1="60" y1="280" x2="640" y2="280" stroke="#888780" stroke-width="1"/>
  <line x1="60" y1="280" x2="60" y2="30" stroke="#888780" stroke-width="1"/>
  <text x="50" y="284" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">0</text>
  <text x="50" y="194" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">25</text>
  <text x="50" y="104" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">50</text>
  <text x="30" y="160" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#444441" transform="rotate(-90,30,160)">|t| (TVLA)</text>
  <text x="60" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">共享掩码</text>
  <text x="350" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">独立掩码</text>
  <text x="640" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">阈值 4.5</text>

  <!-- Shared masking bar -->
  <rect x="100" y="100" width="120" height="180" fill="#E24B4A" fill-opacity="0.7" rx="4"/>
  <text x="160" y="90" text-anchor="middle" font-family="sans-serif" font-size="14" font-weight="500" fill="#A32D2D">49.84</text>
  <text x="160" y="315" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">tau×tau 二阶泄漏</text>
  <text x="160" y="330" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">CPA 6/6 恢复</text>

  <!-- Independent masking bar -->
  <rect x="320" y="250" width="120" height="30" fill="#0F6E56" fill-opacity="0.7" rx="4"/>
  <text x="380" y="240" text-anchor="middle" font-family="sans-serif" font-size="14" font-weight="500" fill="#085041">1.12</text>
  <text x="380" y="315" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">二阶通道消除</text>
  <text x="380" y="330" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">CPA 0/6 恢复</text>

  <!-- Threshold line -->
  <line x1="60" y1="262" x2="640" y2="262" stroke="#BA7517" stroke-width="1" stroke-dasharray="4,4"/>
  <text x="645" y="266" font-family="sans-serif" font-size="10" fill="#BA7517">4.5</text>

  <!-- Arrow between bars -->
  <line x1="220" y1="190" x2="320" y2="190" stroke="#5F5E5A" stroke-width="1" marker-end="url(#arrow2)"/>
  <text x="270" y="180" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">+12 LUT</text>
</svg>'''

# Figure 4: CPA convergence comparison
fig4 = '''<svg viewBox="0 0 680 340" role="img" aria-label="CPA收敛性对比">
  <title>CPA收敛性对比：共享掩码 vs 独立掩码</title>
  <desc>展示共享掩码方案CPA在N=50时GE降至1，独立掩码方案CPA全程不收敛</desc>
  <line x1="60" y1="280" x2="640" y2="280" stroke="#888780" stroke-width="1"/>
  <line x1="60" y1="280" x2="60" y2="30" stroke="#888780" stroke-width="1"/>
  <text x="50" y="284" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">0</text>
  <text x="50" y="194" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">0.5</text>
  <text x="50" y="104" text-anchor="end" font-family="sans-serif" font-size="11" fill="#5F5E5A">1.0</text>
  <text x="30" y="160" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#444441" transform="rotate(-90,30,160)">GE (猜测熵)</text>
  <text x="60" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">0</text>
  <text x="176" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">25</text>
  <text x="292" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">50</text>
  <text x="408" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">75</text>
  <text x="524" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A">100</text>
  <text x="640" y="300" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#5F5E5A"> traces (×10²)</text>
  <text x="350" y="330" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#444441">Trace 数 N</text>

  <!-- GE=1 threshold line -->
  <line x1="60" y1="104" x2="640" y2="104" stroke="#E24B4A" stroke-width="0.5" stroke-dasharray="3,3"/>
  <text x="645" y="108" font-family="sans-serif" font-size="10" fill="#E24B4A">GE=1</text>

  <!-- Shared masking GE curve (drops to 1 at N=50) -->
  <polyline points="60,280 120,280 176,280 200,280 230,280 260,280 292,104 350,104 408,104 524,104 640,104"
    fill="none" stroke="#E24B4A" stroke-width="2.5"/>
  <circle cx="292" cy="104" r="5" fill="#E24B4A"/>
  <text x="292" y="94" text-anchor="middle" font-family="sans-serif" font-size="11" font-weight="500" fill="#A32D2D">N=50, GE=1</text>

  <!-- Independent masking GE curve (stays high) -->
  <polyline points="60,280 120,280 176,280 230,280 292,280 350,280 408,280 470,280 524,280 640,280"
    fill="none" stroke="#0F6E56" stroke-width="2.5" stroke-dasharray="6,3"/>
  <text x="500" y="270" text-anchor="middle" font-family="sans-serif" font-size="11" fill="#085041">全程不收敛</text>

  <!-- Legend -->
  <rect x="420" y="40" width="14" height="3" fill="#E24B4A"/>
  <text x="440" y="45" font-family="sans-serif" font-size="11" fill="#5F5E5A">共享掩码 (CPA 6/6)</text>
  <line x1="420" y1="60" x2="434" y2="60" stroke="#0F6E56" stroke-width="2" stroke-dasharray="6,3"/>
  <text x="440" y="65" font-family="sans-serif" font-size="11" fill="#5F5E5A">独立掩码 (CPA 0/6)</text>
</svg>'''

# Figure 5: RO-TRNG structure
fig5 = '''<svg viewBox="0 0 680 300" role="img" aria-label="RO-TRNG物理熵源结构">
  <title>RO-TRNG物理熵源结构</title>
  <desc>三路环形振荡器经D触发器采样后由xs64混合器产生32-bit掩码种子</desc>
  <defs>
    <marker id="arrow3" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
      <path d="M2 1L8 5L2 9" fill="none" stroke="#5F5E5A" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/>
    </marker>
  </defs>

  <!-- RO11 -->
  <g>
    <rect x="40" y="40" width="100" height="60" rx="8" fill="#FAEEDA" stroke="#BA7517" stroke-width="0.5"/>
    <text x="90" y="60" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#633806">RO11</text>
    <text x="90" y="78" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">11级反相器</text>
    <text x="90" y="92" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">~10 MHz</text>
  </g>

  <!-- RO9 -->
  <g>
    <rect x="180" y="40" width="100" height="60" rx="8" fill="#FAEEDA" stroke="#BA7517" stroke-width="0.5"/>
    <text x="230" y="60" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#633806">RO9</text>
    <text x="230" y="78" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">9级反相器</text>
    <text x="230" y="92" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">~12 MHz</text>
  </g>

  <!-- RO7 -->
  <g>
    <rect x="320" y="40" width="100" height="60" rx="8" fill="#FAEEDA" stroke="#BA7517" stroke-width="0.5"/>
    <text x="370" y="60" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#633806">RO7</text>
    <text x="370" y="78" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">7级反相器</text>
    <text x="370" y="92" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">~15 MHz</text>
  </g>

  <!-- DFF sampling -->
  <g>
    <rect x="460" y="40" width="100" height="60" rx="8" fill="#E6F1FB" stroke="#378ADD" stroke-width="0.5"/>
    <text x="510" y="60" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#0C447C">D触发器</text>
    <text x="510" y="78" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">100 MHz 采样</text>
    <text x="510" y="92" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">1-bit 抖动</text>
  </g>

  <!-- xs64 mixer -->
  <g>
    <rect x="200" y="160" width="160" height="60" rx="8" fill="#EEEDFE" stroke="#534AB7" stroke-width="0.5"/>
    <text x="280" y="180" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#26215C">xs64 混合器</text>
    <text x="280" y="198" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#3C3489">xorshift 64-bit</text>
    <text x="280" y="212" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">32-bit 掩码种子</text>
  </g>

  <!-- Health monitor -->
  <g>
    <rect x="420" y="160" width="140" height="60" rx="8" fill="#EAF3DE" stroke="#639922" stroke-width="0.5"/>
    <text x="490" y="180" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#27500A">健康监测</text>
    <text x="490" y="198" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">T1-T7 SP 800-90B</text>
    <text x="490" y="212" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">AXI-Lite 上报</text>
  </g>

  <!-- Frequency injection attack -->
  <g>
    <rect x="40" y="160" width="140" height="60" rx="8" fill="#FCEBEB" stroke="#E24B4A" stroke-width="0.5"/>
    <text x="110" y="180" text-anchor="middle" font-family="sans-serif" font-size="12" font-weight="500" fill="#A32D2D">频率注入</text>
    <text x="110" y="198" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">A_inj, f_inj</text>
    <text x="110" y="212" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">→ t_inv_eff</text>
  </g>

  <!-- Arrows -->
  <line x1="140" y1="70" x2="175" y2="70" stroke="#5F5E5A" stroke-width="0.5" marker-end="url(#arrow3)"/>
  <line x1="280" y1="70" x2="315" y2="70" stroke="#5F5E5A" stroke-width="0.5" marker-end="url(#arrow3)"/>
  <line x1="420" y1="70" x2="455" y2="70" stroke="#5F5E5A" stroke-width="0.5" marker-end="url(#arrow3)"/>
  <line x1="510" y1="100" x2="510" y2="155" stroke="#378ADD" stroke-width="1" marker-end="url(#arrow3)"/>
  <line x1="110" y1="100" x2="110" y2="155" stroke="#D85A30" stroke-width="1" marker-end="url(#arrow3)"/>
  <line x1="230" y1="100" x2="230" y2="155" stroke="#378ADD" stroke-width="1" marker-end="url(#arrow3)"/>
  <line x1="370" y1="100" x2="370" y2="155" stroke="#378ADD" stroke-width="1" marker-end="url(#arrow3)"/>
  <line x1="280" y1="220" x2="280" y2="260" stroke="#534AB7" stroke-width="1" marker-end="url(#arrow3)"/>
  <text x="280" y="275" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#5F5E5A">掩码种子 → SM4引擎</text>
</svg>'''

# Save all figures
for name, content in [('architecture.svg', fig1), ('mrs_curve.svg', fig2),
                        ('second_order_leakage.svg', fig3), ('cpa_convergence.svg', fig4),
                        ('ro_trng.svg', fig5)]:
    path = os.path.join(fig_dir, name)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f'Saved: {path} ({len(content)} chars)')