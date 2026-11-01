// =============================================================================
// 模块名称 : gm_crypto_board_v15
// 项目     : GM-CRYPTO-COORD-2026 - FPGA 国密多算法协调芯片
// 版本     : v1.1
// 日期     : 2026-10-25
// 视角     : fpga-fullflow-lead (齐流晶)
//
// 变更记录 :
//   v1.0 2026-10-19 首版 (clk50/POR/PRNG host/probe FSM/LED)
//   v1.1 2026-10-25 SM4 引擎切换为 sm4_engine_masked_v4 (USE_SM4_MASKED=2,
//                  S 盒输出域共享, 一阶 DPA 防护, SCEA 签核)。
//                  v4_indep 掩码种子由 crypto_coord_subsys 内 TRNG 真随机供给 (P0-6 方案2),
//                  本顶层无需新增端口/引脚; LED 判据与 probe FSM 不变。
//   v1.2 2026-10-27 P0-6 修复: 掩码种子初值不再写死公开常数
//                  (原 xorshift64 复位值 0x9E3779B97F4A7C15 为黄金分割常数,
//                  一旦写入 RTL 即公开 -> 掩码已知一阶 CPA 4/4 恢复 rk0)。
//                  新增 64-bit 自由运行计数器 seed_cnt, 在 POR 释放时刻
//                  (rst_n 上升沿) 捕获当前值作为 mask_seed_init。
//                  真实硬件上 POR 释放的上电抖动使捕获值不可预测 ->
//                  每设备保密, 攻击者无法从公开 bitstream 推算种子序列。
//                  仿真/det-seed TB 由测试台注入随机初值, 不依赖此捕获通路。
//                  兜底: init=0 由 crypto_coord_subsys 内部处理 (非零常数)。
//
// 用途     : Phase 5 板级顶层 (Nexys A7 200T, xc7a200tsbg484-2)。
//            完整 pcie_front_subsys (v1.5 命令模型) 内部化, 顶层仅暴露:
//              clk = 板载 100 MHz 有源晶振 (E3)
//              led = 8 位健康/状态灯 (N14 R18 V17 U17 U16 H17 W16 V15)
//            内部自动生成时钟/复位/主机激励/自测, 无需上位机即可目视判读。
//
// 设计决策:
//   D1: clk100 -> clk50 (/2 + BUFG) 单时钟域。50 MHz = Phase 4 wrap12 签核
//       目标频率 (20 ns), 约束与实际工况完全一致。
//   D2: DUT 整体 (* DONT_TOUCH *) -> 网表与 pcie_sys_wrap 可迁移, 已签核的
//       面积/时序数据可直接引用, 不引入新的时序收敛风险。
//   D3: PRNG 主机激励与 pcie_sys_wrap 同源 (32-bit LFSR), 保证 DUT 持续有
//       真实主机流量, 防止综合常数传播裁剪内部逻辑。
//   D4: probe FSM 与 PRNG 时分割 (probe 占 2/8 周期), 周期性完成寄存器级
//       自测 (CTRL_GLOBAL / CTRL_TRNG / STATUS / TRNG health / FEATURE_FLAGS)。
//   D5: LED sticky 锁存 -> 首次通过即点亮, 首次失败即点亮 fail_sticky。
//       板级目视判读, 无需上位机或 ILA。
//
// LED 编码 (bit7..bit0):
//   [7] fail_sticky : 任一自测项失败 (sticky, 最高位醒目)
//   [6] feat_ok     : FEATURE_FLAGS == 0x3FF (特性标志正确)
//   [5] entropy_ok  : TRNG_ENTROPY_CNT != 0 (熵累积器已积累)
//   [4] err_ok      : STATUS_ERR[0] == 0 (无错误标志)
//   [3] trng_ok     : STATUS_TRNG[7:1] == 0 (NIST T1-T7 全通过)
//   [2] global_en   : STATUS_GLOBAL[0] == 1 (CTRL_GLOBAL enable 生效)
//   [1] heartbeat   : ~1.49 Hz 心跳 (2^25 x 20 ns = 671 ms)
//   [0] all_ok      : 5 项自测全部通过 (sticky)
//
// 全绿判据 (板级健康): led = 0b11111110 (led[1] 心跳闪烁, led[7] 灭)
//
// probe 寄存器映射 (BAR0):
//   step 0  0x02C  CTRL_GLOBAL     write 0x00000001 (bit0=enable)
//   step 1  0x030  CTRL_TRNG       write 0x00000001 (bit0=start)
//   step 2  0x040  STATUS_GLOBAL   read  -> bit0 == 1
//   step 3  0x044  STATUS_TRNG     read  -> bits[7:1] == 0 (T1-T7)
//   step 4  0x054  STATUS_ERR      read  -> bit0 == 0
//   step 5  0x058  ENTROPY_CNT     read  -> != 0
//   step 6  0x010  FEATURE_FLAGS   read  -> == 0x3FF
//   step 7  0x800  SCRATCH[0]      write 0xDEADBEEF (数据面 MMIO 验证)
//
// 编译     : iverilog -g2005 / Vivado 2026.1 (Vivado 需 +define+FPGA)
// =============================================================================

`timescale 1ns / 1ps

module gm_crypto_board_v15 (
    input  wire        clk,        // 板载 100 MHz 有源晶振
    output wire [7:0]  led         // 8 位状态/健康灯
);

    // =========================================================================
    // 1. 时钟分频: 100 MHz -> 50 MHz
    //    clk50_q 初值 0; 每次 clk 上升沿翻转 -> 上升沿与 clk 上升沿重合
    //    (零相对偏斜), 下降沿同理。BUFG_HOLD 保证时钟路径不被优化掉。
    // =========================================================================
    reg clk50_q = 1'b0;
    always @(posedge clk) clk50_q <= ~clk50_q;

    wire clk50;
`ifdef FPGA
    (* BUFG_HOLD = "TRUE" *) BUFG u_clkb ( .I(clk50_q), .O(clk50) );
`else
    assign clk50 = clk50_q;
`endif

    // =========================================================================
    // 2. 内部上电复位 (POR)
    //    por_cnt 计到 0xFFFE (65534 x 20 ns = 1.31 ms) 后 rst_n 拉高并保持。
    //    rst_n 为寄存器, 与 clk50 同域, 单调 0->1 无毛刺。
    //    释放后所有子模块同步出复位 (rst_n 为电平信号, 非脉冲)。
    // =========================================================================
    reg [19:0] por_cnt = 20'd0;
    reg        rst_n   = 1'b0;

    always @(posedge clk50) begin
        if (por_cnt < 20'hFFFE)
            por_cnt <= por_cnt + 20'd1;
        else
            rst_n   <= 1'b1;
    end

    // =========================================================================
    // 2b. v4 掩码种子捕获 (P0-6 修复, 每设备保密)
    //    seed_cnt: 64-bit 自由运行计数器, POR 释放后每拍 +1。
    //    在 rst_n 上升沿 (POR 释放) 捕获 seed_cnt 当前值 ->
    //    真实硬件上电抖动使捕获时刻不可预测, 种子每设备不同。
    //    仿真/det-seed TB 由测试台注入随机初值, 此通路仅用于板级。
    // =========================================================================
    reg  [63:0] seed_cnt = 64'd0;
    reg         prev_rst_n = 1'b0;
    reg  [63:0] mask_seed_init = 64'h9E3779B97F4A7C15;  // 兜底 (init=0 时由 coord 内部处理)

    always @(posedge clk50) begin
        if (!rst_n)
            seed_cnt <= 64'd0;
        else
            seed_cnt <= seed_cnt + 64'd1;
    end

    always @(posedge clk50) begin
        if (!rst_n) begin
            prev_rst_n      <= 1'b0;
            mask_seed_init  <= 64'h9E3779B97F4A7C15;
        end else begin
            prev_rst_n <= rst_n;
            // rst_n 上升沿 (POR 释放) -> 捕获 seed_cnt 当前值
            if (rst_n && !prev_rst_n)
                mask_seed_init <= seed_cnt;
        end
    end

    // =========================================================================
    // 3. PRNG 主机激励 (与 pcie_sys_wrap 同源 32-bit LFSR)
    //    多态信号防止综合器常数传播裁剪 DUT 内部逻辑。
    // =========================================================================
    reg [31:0] prng = 32'hCAFEBABE;

    always @(posedge clk50) begin
        if (!rst_n)
            prng <= 32'hCAFEBABE;
        else
            prng <= {prng[30:0], prng[31] ^ prng[21] ^ prng[1]};
    end

    wire [19:0] prng_addr    = prng[19:0];
    wire [31:0] prng_wr_data = prng;
    wire        prng_wr_en   = prng[0];
    wire        dma_wr_rdy   = prng[1];

    // =========================================================================
    // 4. 启动延时 + 时分割轮转
    //    boot_cnt: POR 释放后再等 4096 拍 (81.9 us), 让 DUT 内部 FSM/计数器
    //             完成自启动, 避免 probe 读到未初始化状态。
    //    cnt_rr  : 3-bit 轮转, probe 占 cnt_rr<2 的 2/8 周期, PRNG 占 6/8。
    //    probe 期间地址保持 2 拍: 第 1 拍 (cnt_rr=0) 呈送 addr + 写使能,
    //             第 2 拍 (cnt_rr=1) 取读回 (mmio_rd_data 为寄存输出, 1 拍延迟)。
    // =========================================================================
    reg [11:0] boot_cnt = 12'd0;
    wire       boot_done = (boot_cnt == 12'hFFF);

    always @(posedge clk50) begin
        if (!rst_n)
            boot_cnt <= 12'd0;
        else if (!boot_done)
            boot_cnt <= boot_cnt + 12'd1;
    end

    reg [2:0] cnt_rr = 3'd0;

    always @(posedge clk50) begin
        if (!rst_n)
            cnt_rr <= 3'd0;
        else
            cnt_rr <= cnt_rr + 3'd1;
    end

    wire probe_on = (cnt_rr < 3'd2);

    // =========================================================================
    // 5. probe FSM
    //    probe_step 在 cnt_rr==7 的沿推进 (即 7->0 沿), 保证在 cnt_rr=0,1
    //    两拍内 probe_step 恒定 -> p_addr 组合输出稳定 -> DUT 采样到正确地址。
    //    写使能仅在 cnt_rr==0 一拍有效, 避免同一步骤内重复写 (CTRL_TRNG.start
    //    重复触发会重置健康测试窗口, 导致 T1-T7 永远无法通过)。
    // =========================================================================
    reg [2:0] probe_step = 3'd0;

    always @(posedge clk50) begin
        if (!rst_n)
            probe_step <= 3'd0;
        else if (!boot_done)
            probe_step <= 3'd0;
        else if (cnt_rr == 3'd7)
            probe_step <= probe_step + 3'd1;
    end

    // ---- 组合地址表 (probe_step -> addr / data / wr) ----
    reg [19:0] p_addr;
    reg [31:0] p_data;
    reg        p_wr;

    always @(*) begin
        p_addr = 20'd0;
        p_data = 32'd0;
        p_wr   = 1'b0;
        case (probe_step)
            3'd0:  begin p_addr = 20'h0002C; p_data = 32'h00000001; p_wr = 1'b1; end
            3'd1:  begin p_addr = 20'h00030; p_data = 32'h00000001; p_wr = 1'b1; end
            3'd2:  begin p_addr = 20'h00040; p_wr = 1'b0; end
            3'd3:  begin p_addr = 20'h00044; p_wr = 1'b0; end
            3'd4:  begin p_addr = 20'h00054; p_wr = 1'b0; end
            3'd5:  begin p_addr = 20'h00058; p_wr = 1'b0; end
            3'd6:  begin p_addr = 20'h00010; p_wr = 1'b0; end
            default: begin p_addr = 20'h00800; p_data = 32'hDEADBEEF; p_wr = 1'b1; end
        endcase
    end

    // ---- MMIO 总线时分割 mux ----
    wire [19:0] mmio_addr;
    wire [31:0] mmio_wr_data;
    wire        mmio_wr_en;

    assign mmio_addr    = probe_on ? p_addr : prng_addr;
    assign mmio_wr_data = probe_on ? p_data : prng_wr_data;
    assign mmio_wr_en   = probe_on ? (p_wr & (cnt_rr == 3'd0)) : prng_wr_en;

    // =========================================================================
    // 6. 输出读回线 (keep 防综合裁剪)
    // =========================================================================
    (* keep = "true" *) wire [31:0]  s_mmio_rd_data;
    (* keep = "true" *) wire         s_mmio_rd_vld;
    (* keep = "true" *) wire         s_dma_wr_vld;
    (* keep = "true" *) wire [63:0]  s_dma_wr_desc;
    (* keep = "true" *) wire [511:0] s_dma_wr_data;
    (* keep = "true" *) wire [7:0]   s_dma_wr_rid;
    (* keep = "true" *) wire [7:0]   s_dma_wr_err;
    (* keep = "true" *) wire         s_dma_wr_ok;
    (* keep = "true" *) wire         s_msix_irq_vld;
    (* keep = "true" *) wire [31:0]  s_msix_irq_addr;
    (* keep = "true" *) wire [31:0]  s_msix_irq_data;
    (* keep = "true" *) wire [3:0]   s_msix_irq_vec;
    (* keep = "true" *) wire [15:0]  s_msix_pending;
    (* keep = "true" *) wire [15:0]  s_msix_masked;
    (* keep = "true" *) wire         s_msix_any_pending;
    (* keep = "true" *) wire [8:0]   s_cmd_ring_lvl;
    (* keep = "true" *) wire [8:0]   s_desc_ring_lvl;
    (* keep = "true" *) wire [4:0]   s_cmd_queue_lvl;
    (* keep = "true" *) wire [4:0]   s_done_queue_lvl;

    // =========================================================================
    // 7. DUT (整体保留, 不允许综合优化内部)
    //    USE_SM4_MASKED=2: SM4 引擎为 sm4_engine_masked_v4 (输出再掩码,
    //    二阶消除, TVLA |t| 1.12 / CPA 0-6 / GE 不收敛, 论文 v2 签核)。
    //    掩码种子由 crypto_coord_subsys 内 TRNG 真随机供给 (P0-6 方案2),
    //    每次 SM4 事务前置取 64-bit 真随机, 无需板级引脚或主机干预。
    // =========================================================================
    (* DONT_TOUCH = "true" *)
    pcie_front_subsys #(
        .USE_SM4_MASKED (2)
    ) u_dut (
        .clk              (clk50),
        .rst_n            (rst_n),
        .mask_seed_init   (mask_seed_init),  // v4_indep 掩码种子 (P0-6 修复+方案2, 每设备保密)

        // 主机 MMIO 接口
        .mmio_addr        (mmio_addr),
        .mmio_wr_data     (mmio_wr_data),
        .mmio_wr_en       (mmio_wr_en),
        .mmio_rd_data     (s_mmio_rd_data),
        .mmio_rd_vld      (s_mmio_rd_vld),

        // DMA 写回通道
        .dma_wr_vld       (s_dma_wr_vld),
        .dma_wr_rdy       (dma_wr_rdy),
        .dma_wr_desc      (s_dma_wr_desc),
        .dma_wr_data      (s_dma_wr_data),
        .dma_wr_rid       (s_dma_wr_rid),
        .dma_wr_err       (s_dma_wr_err),
        .dma_wr_ok        (s_dma_wr_ok),

        // MSI-X 中断输出
        .msix_irq_vld     (s_msix_irq_vld),
        .msix_irq_addr    (s_msix_irq_addr),
        .msix_irq_data    (s_msix_irq_data),
        .msix_irq_vec     (s_msix_irq_vec),
        .msix_pending     (s_msix_pending),
        .msix_masked      (s_msix_masked),
        .msix_any_pending (s_msix_any_pending),

        // 状态指示
        .cmd_ring_lvl     (s_cmd_ring_lvl),
        .desc_ring_lvl    (s_desc_ring_lvl),
        .cmd_queue_lvl    (s_cmd_queue_lvl),
        .done_queue_lvl   (s_done_queue_lvl)
    );

    // =========================================================================
    // 8. probe 判据采样 -> sticky 锁存
    //    sample_en 在 cnt_rr==1 的沿 (1->2 沿) 有效: 此时 s_mmio_rd_data
    //    已锁存 cnt_rr=0 呈送的地址的读回值, probe_step 在两拍内恒定。
    //    sticky: 首次通过即置 1 并保持; 首次失败置 fail_sticky 并保持。
    // =========================================================================
    wire sample_en = boot_done & probe_on & (cnt_rr == 3'd1);

    reg global_en_ok = 1'b0;
    reg trng_ok      = 1'b0;
    reg err_ok       = 1'b0;
    reg entropy_ok   = 1'b0;
    reg feat_ok      = 1'b0;
    reg fail_sticky  = 1'b0;

    always @(posedge clk50) begin
        if (!rst_n) begin
            global_en_ok <= 1'b0;
            trng_ok      <= 1'b0;
            err_ok       <= 1'b0;
            entropy_ok   <= 1'b0;
            feat_ok      <= 1'b0;
            fail_sticky  <= 1'b0;
        end else if (sample_en) begin
            case (probe_step)
                3'd2: begin
                    if (s_mmio_rd_data[0] == 1'b1) global_en_ok <= 1'b1;
                    else                             fail_sticky  <= 1'b1;
                end
                // step 3 读 0x044 STATUS_TRNG = {24'd0, ~T7,~T6,~T5,~T4,~T3,~T2,~T1, RUNNING}
                // WIN=1024 下 NIST 七检验单窗口理论假报警率 1-0.975^5*0.95 = 8.84%,
                // 实测 9.15% (entropy_ht_check.py / trng_monitor.v 文件头), 因此
                // [7:1] 只能表达"上一个窗口"瞬时状态, 不能当故障标志使用。
                // 判据改为单调语义: 读到"全通过 + running" 即置 trng_ok;
                // 只有"TRNG 从未启动 (running==0)"才判结构故障 -> fail_sticky。
                3'd3: begin
                    if (s_mmio_rd_data[0] == 1'b1 && s_mmio_rd_data[7:1] == 7'd0)
                        trng_ok      <= 1'b1;
                    else if (s_mmio_rd_data[0] == 1'b0)
                        fail_sticky  <= 1'b1;
                end
                3'd4: begin
                    if (s_mmio_rd_data[0] == 1'b0)  err_ok       <= 1'b1;
                    else                                fail_sticky <= 1'b1;
                end
                3'd5: begin
                    if (s_mmio_rd_data != 32'd0)   entropy_ok   <= 1'b1;
                    else                                fail_sticky <= 1'b1;
                end
                3'd6: begin
                    if (s_mmio_rd_data == 32'h000003FF) feat_ok  <= 1'b1;
                    else                                      fail_sticky <= 1'b1;
                end
                default: ;
            endcase
        end
    end

    wire all_ok = global_en_ok & trng_ok & err_ok & entropy_ok & feat_ok;

    // =========================================================================
    // 9. 心跳 + LED 编码
    //    2^25 x 20 ns = 671.08864 ms -> 1.49 Hz, 目视清晰可辨。
    // =========================================================================
    reg [25:0] hb_cnt = 26'd0;

    always @(posedge clk50) begin
        if (!rst_n)
            hb_cnt <= 26'd0;
        else
            hb_cnt <= hb_cnt + 26'd1;
    end

    wire heartbeat = hb_cnt[25];

    assign led[7:0] = { fail_sticky,
                        feat_ok,
                        entropy_ok,
                        err_ok,
                        trng_ok,
                        global_en_ok,
                        heartbeat,
                        all_ok };

endmodule
