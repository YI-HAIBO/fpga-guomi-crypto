// =============================================================================
// tb_sm4_sbox_table_masked.v -- B-2 Testbench
// =============================================================================
// 版本: 1.2
// 日期: 2026-10-05
// 关联: sim/sm4/ref_sm4_sbox_table_masked.py (B-1 参考模型, ALL PASS)
//       rtl/sm4/sm4_sbox_table_masked.v (DUT)
//       rtl/sm4/sm4_sbox_raw.v (权威 S 盒参考)
// =============================================================================
//
// 【测试计划】
//   T1 : 掩码关闭透传（masked_en=0）—— y == S_BOX[x] 256/256
//   T2 : 掩码开启消码正确 —— y ^ r_table[x^c] == S_BOX[x] 256/256
//   T2b: 掩码表非退化断言 —— r_table 非零条目 >= 250/256  (v1.2 新增)
//   T3 : 掩码输出一致性 —— y == S_BOX[x] ^ r_table[x^c] 256/256
//   T4 : 边界值 —— x=0/255, c=0/255
//   T5 : 掩码切换 —— 同 x 不同 (c, r_table) 得到不同 y
//   T6 : 掩码关闭时不受 r_table/c 影响
//
// 【设计要点】
//   - 使用 sm4_sbox_raw 例化作 S 盒参考（不硬编码，避免错误）
//   - LFSR 生成 r_table（确定性，可复现；原多项式 x^16+x^14+x^13+x^11+1）
//   - 所有变量声明在 module level（iverilog -g2005 限制）
//   - 无 task output 参数、无 return
//
// 【变更历史】
//   v1.0: 初版（手写 256 项 S 盒 case 表，含非法 hex 字面量 → 弃用）
//   v1.1: 改为例化 sm4_sbox_raw 作 s_ref；y1/y2_snapshot 改 reg
//   v1.2: 修复两处真实缺陷（见下），新增 T2b 非退化断言
//         (a) `wire [7:0] y = 0;` → `wire [7:0] y;`
//             wire 初值等价于隐式 `assign y = 0`，与 DUT 输出构成双驱动，
//             强度解析结果为 X，导致 T1 全 FAIL (y=0xXX)。
//         (b) lfsr_step 步进式错误：原为右移且漏掉常数项，
//             任何 seed 在 7~14 步内衰减到 0x0000 并被永久吸收，
//             r_table 后段全 0。已改为左移（乘 x 模 p）+ 位掩码 16'h6801。
//             新增 T2b 因 T2/T3 两侧用同一 r_table 自洽、无法暴露该缺陷。
//         最终结果: 774/774 PASS, 18/18 ALL TESTS PASSED
// =============================================================================

`timescale 1ns / 1ps

module tb_sm4_sbox_table_masked;

    // =========================================================================
    // 参数
    // =========================================================================
    parameter CLK_PERIOD = 10;

    // =========================================================================
    // DUT 信号
    // =========================================================================
    reg         clk = 0;
    reg         rst_n = 0;
    reg         masked_en = 0;
    reg  [7:0]  x = 0;
    reg  [7:0]  c = 0;
    reg  [2047:0] r_table = 0;
    wire [7:0]  y;   // 禁止写 y = 0：wire 初值等价于隐式 assign，会与 DUT 输出形成双驱动 → X

    // =========================================================================
    // 参考 S 盒信号
    // =========================================================================
    wire [7:0] s_ref;

    // =========================================================================
    // 辅助寄存器（module level，避免 task output 限制）
    // =========================================================================
    wire [7:0] idx;
    wire [2047:0] r_shifted;
    wire [7:0] r_val;
    wire [7:0] expected_y;
    wire [7:0] recovered;
    reg  [7:0] y1_snapshot;
    reg  [7:0] y2_snapshot;

    // =========================================================================
    // DUT 实例
    // =========================================================================
    sm4_sbox_table_masked u_dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .masked_en (masked_en),
        .x       (x),
        .c       (c),
        .r_table (r_table),
        .y       (y)
    );

    // =========================================================================
    // 参考 S 盒实例（与 DUT 内部 sm4_sbox_raw 同源）
    // =========================================================================
    sm4_sbox_raw u_sbox_ref (.x(x), .y(s_ref));

    // =========================================================================
    // 组合逻辑（辅助计算）
    // =========================================================================
    assign idx = x ^ c;
    assign r_shifted = r_table >> (idx * 8);
    assign r_val = r_shifted[7:0];
    assign expected_y = s_ref ^ r_val;
    assign recovered = y ^ r_val;

    // =========================================================================
    // 时钟生成
    // =========================================================================
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // 统计
    // =========================================================================
    integer pass_count = 0;
    integer fail_count = 0;
    integer total_count = 0;
    integer i;
    integer seed;
    integer rnz_count = 0;   // T2b: r_table 非零条目计数（LFSR 退化检测）

    // =========================================================================
    // LFSR 生成 r_table（16-bit LFSR, x^16+x^14+x^13+x^11+1）
    // =========================================================================
    reg [15:0] lfsr_reg;
    reg        lfsr_fb;   // 反馈位（module level，避免 iverilog 无名 begin 块内声明）

    // =========================================================================
    // LFSR 步进 task
    //   多项式 p(x) = x^16 + x^14 + x^13 + x^11 + 1   (已验证为原多项式,
    //   周期 = 2^16-1 = 65535, 见 .workbuddy/tmp/verify_lfsr_b4.py)
    //
    //   实现 = 左移 (乘 x 模 p):
    //     carry = state[15]
    //     state = {state[14:0], carry} ^ (carry ? 16'h6800 : 0)
    //   其中 16'h6800 = x^14 + x^13 + x^11 的位掩码 (p 中除 x^16 与常数项
    //   x^0 之外的项), 即 {bit14, bit13, bit11}。常数项 x^0 由
    //   {s[14:0],carry} 的 bit0 (= carry) 承担, 不得再在掩码中重复。
    //
    //   【历史教训 v1.1】原实现为右移且漏掉常数项:
    //       lfsr_reg = {s[14]^s[13]^s[11], s[15:1]}  (8-bit 拼接, 高位清零)
    //   该式既丢掉了 "+1" 常数项, 又把多项式抽头错配到移位方向上,
    //   结果任何 seed 都在 ~7-14 步内衰减到 0x0000 并被永久吸收,
    //   导致 r_table 后段全 0 —— 直接违反路线 B "256 项独立随机" 前提,
    //   并让 T5 误判 y1==y2。T2/T3 无法捕获该缺陷, 因其左右两侧用同一
    //   r_table 自洽 (见新增的 T2b 非退化断言)。
    //
    //   【历史教训 v1.2 / B-4】v1.1 补常数项时误取掩码 16'h6801 (含 x^0)。
    //   因 {s[14:0],carry} 的 bit0 已等于 carry, 常数项被施加两次, bit0 恒 0,
    //   状态低字节恒 0, 高字节仅 12 个取值、周期 12。与 v1.1 不同, 本变体
    //   **不**衰减到 0x0000, 故 T2b "r_table 非零条目 >= 250" 完全无法暴露
    //   (r_table 条目由 S 盒双射性保证非零, 与 c 的多样性无关)。已改回
    //   16'h6800。教训: 掩码多样性必须直接对 c 本身做统计检验 (B-4 T4),
    //   不能以 r_table 的非零数作代理。
    // =========================================================================
    task lfsr_step;
        begin
            lfsr_fb  = lfsr_reg[15];
            lfsr_reg = {lfsr_reg[14:0], lfsr_fb} ^ (lfsr_fb ? 16'h6800 : 16'h0000);
        end
    endtask

    // =========================================================================
    // 主测试序列
    // =========================================================================
    initial begin
        $display("====================================================================");
        $display("B-2: sm4_sbox_table_masked Testbench");
        $display("====================================================================");

        // 复位
        rst_n = 0;
        #(CLK_PERIOD * 5);
        rst_n = 1;
        #(CLK_PERIOD * 2);

        // =========================================================================
        // T1: 掩码关闭透传（masked_en=0）—— 256/256
        // =========================================================================
        $display("\n[T1] masked_en=0: y == S_BOX[x] for all 256 x");
        masked_en = 0;
        c = 8'h00;
        r_table = 2048'h0;

        for (i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            #(CLK_PERIOD / 2);
            total_count = total_count + 1;
            if (y === s_ref) begin
                pass_count = pass_count + 1;
                if (i < 3 || i == 255)
                    $display("  [PASS] x=0x%02h: y=0x%02h == s_ref=0x%02h", i[7:0], y, s_ref);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] x=0x%02h: y=0x%02h != s_ref=0x%02h", i[7:0], y, s_ref);
            end
        end
        $display("[T1] %0d/%0d PASS", pass_count, total_count);

        // =========================================================================
        // T2: 掩码开启消码正确 —— 256/256
        // =========================================================================
        $display("\n[T2] masked_en=1: y ^ r_table[x^c] == S_BOX[x] for all 256 x");
        masked_en = 1;
        c = 8'hA3;

        // 生成 r_table (seed=12345)
        lfsr_reg = 16'h3039;  // "000" ASCII as seed
        r_table = 2048'h0;
        rnz_count = 0;
        for (i = 0; i < 256; i = i + 1) begin
            lfsr_step;
            r_table[i*8 +: 8] = lfsr_reg[15:8];
            if (lfsr_reg[15:8] !== 8'h00) rnz_count = rnz_count + 1;
            lfsr_step;
        end

        // T2b: 掩码表非退化断言（LFSR 退化 / 多项式错误检测）
        //   若 LFSR 非原多项式或步进式写错，状态会在少数步内衰减到 0x0000
        //   并被永久吸收，使 r_table 出现大片 0。T2/T3 两侧用同一 r_table
        //   自洽，无法暴露该缺陷 —— 必须显式检查非零条目数。
        total_count = total_count + 1;
        if (rnz_count >= 250) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T2b: r_table 非零条目 = %0d/256 (>= 250)", rnz_count);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T2b: r_table 非零条目 = %0d/256 (< 250, LFSR 退化!)", rnz_count);
        end

        for (i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            #(CLK_PERIOD / 2);
            total_count = total_count + 1;
            if (recovered === s_ref) begin
                pass_count = pass_count + 1;
                if (i < 3 || i == 255)
                    $display("  [PASS] x=0x%02h: recovered=0x%02h == s_ref=0x%02h", i[7:0], recovered, s_ref);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] x=0x%02h: recovered=0x%02h != s_ref=0x%02h", i[7:0], recovered, s_ref);
            end
        end
        $display("[T2] %0d/%0d PASS", pass_count, total_count);

        // =========================================================================
        // T3: 掩码输出一致性 —— y == S_BOX[x] ^ r_table[x^c]
        // =========================================================================
        $display("\n[T3] masked_en=1: y == S_BOX[x] ^ r_table[x^c] for all 256 x");
        masked_en = 1;
        c = 8'hFC;

        // 生成新的 r_table (seed=67890)
        lfsr_reg = 16'h0F42;
        for (i = 0; i < 256; i = i + 1) begin
            lfsr_step;
            r_table[i*8 +: 8] = lfsr_reg[15:8];
            lfsr_step;
        end

        for (i = 0; i < 256; i = i + 1) begin
            x = i[7:0];
            #(CLK_PERIOD / 2);
            total_count = total_count + 1;
            if (y === expected_y) begin
                pass_count = pass_count + 1;
                if (i < 3 || i == 255)
                    $display("  [PASS] x=0x%02h: y=0x%02h == expected=0x%02h", i[7:0], y, expected_y);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] x=0x%02h: y=0x%02h != expected=0x%02h", i[7:0], y, expected_y);
            end
        end
        $display("[T3] %0d/%0d PASS", pass_count, total_count);

        // =========================================================================
        // T4: 边界值
        // =========================================================================
        $display("\n[T4] Boundary values");
        masked_en = 1;

        // T4a: x=0, c=0
        x = 8'h00;
        c = 8'h00;
        lfsr_reg = 16'h0001;
        for (i = 0; i < 256; i = i + 1) begin
            lfsr_step;
            r_table[i*8 +: 8] = lfsr_reg[15:8];
            lfsr_step;
        end
        #(CLK_PERIOD / 2);
        total_count = total_count + 1;
        if (y === expected_y) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T4a x=0 c=0: y=0x%02h", y);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T4a x=0 c=0: y=0x%02h != expected=0x%02h", y, expected_y);
        end

        // T4b: x=255, c=255
        x = 8'hFF;
        c = 8'hFF;
        lfsr_reg = 16'h0002;
        for (i = 0; i < 256; i = i + 1) begin
            lfsr_step;
            r_table[i*8 +: 8] = lfsr_reg[15:8];
            lfsr_step;
        end
        #(CLK_PERIOD / 2);
        total_count = total_count + 1;
        if (y === expected_y) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T4b x=FF c=FF: y=0x%02h", y);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T4b x=FF c=FF: y=0x%02h != expected=0x%02h", y, expected_y);
        end

        // =========================================================================
        // T5: 掩码切换（同 x 不同 (c, r_table) 得到不同 y）
        // =========================================================================
        $display("\n[T5] Mask switching: same x, different masks -> different y");
        masked_en = 1;
        x = 8'h42;

        // First query
        c = 8'hA3;
        lfsr_reg = 16'h0064;
        for (i = 0; i < 256; i = i + 1) begin
            lfsr_step;
            r_table[i*8 +: 8] = lfsr_reg[15:8];
            lfsr_step;
        end
        #(CLK_PERIOD / 2);
        y1_snapshot = y;
        $display("  y1 = 0x%02h (x=0x42, c=0xA3, seed=0x0064)", y1_snapshot);

        // Second query
        c = 8'hFC;
        lfsr_reg = 16'h00C8;
        for (i = 0; i < 256; i = i + 1) begin
            lfsr_step;
            r_table[i*8 +: 8] = lfsr_reg[15:8];
            lfsr_step;
        end
        #(CLK_PERIOD / 2);
        y2_snapshot = y;
        $display("  y2 = 0x%02h (x=0x42, c=0xFC, seed=0x00C8)", y2_snapshot);

        total_count = total_count + 1;
        if (y1_snapshot !== y2_snapshot) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T5: y1 != y2 (different masks produce different outputs)");
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T5: y1 == y2 (same output with different masks!)");
        end

        // =========================================================================
        // T6: 掩码关闭时不受 r_table/c 影响
        // =========================================================================
        $display("\n[T6] masked_en=0: y independent of r_table and c");
        masked_en = 0;
        x = 8'h42;

        c = 8'hA3;
        lfsr_reg = 16'h01F4;
        for (i = 0; i < 256; i = i + 1) begin
            lfsr_step;
            r_table[i*8 +: 8] = lfsr_reg[15:8];
            lfsr_step;
        end
        #(CLK_PERIOD / 2);
        total_count = total_count + 1;
        if (y === s_ref) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T6a: masked_en=0, y=0x%02h == s_ref=0x%02h", y, s_ref);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T6a: masked_en=0, y=0x%02h != s_ref=0x%02h", y, s_ref);
        end

        c = 8'hFC;
        lfsr_reg = 16'h0258;
        for (i = 0; i < 256; i = i + 1) begin
            lfsr_step;
            r_table[i*8 +: 8] = lfsr_reg[15:8];
            lfsr_step;
        end
        #(CLK_PERIOD / 2);
        total_count = total_count + 1;
        if (y === s_ref) begin
            pass_count = pass_count + 1;
            $display("  [PASS] T6b: masked_en=0, y=0x%02h == s_ref=0x%02h", y, s_ref);
        end else begin
            fail_count = fail_count + 1;
            $display("  [FAIL] T6b: masked_en=0, y=0x%02h != s_ref=0x%02h", y, s_ref);
        end

        // =========================================================================
        // 总结
        // =========================================================================
        $display("\n====================================================================");
        $display("TEST SUMMARY: PASS=%0d FAIL=%0d TOTAL=%0d", pass_count, fail_count, total_count);
        if (fail_count == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $display("====================================================================");

        #(CLK_PERIOD * 5);
        $finish;
    end

    // =========================================================================
    // 超时保护
    // =========================================================================
    initial begin
        #(CLK_PERIOD * 500000);
        $display("[TIMEOUT] Testbench timeout");
        $finish;
    end

endmodule
