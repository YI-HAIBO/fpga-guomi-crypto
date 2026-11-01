// =============================================================================
// tb_sm4_engine_masked_v2_board.v -- 板级自测顶层的功能仿真前置验证
// =============================================================================
// 目的: 在跑 Vivado 之前先用 iverilog 证明 sm4_engine_masked_v2_board 的
//       测试 FSM 能正确跑完 8 块 KAT, 否则上板 / 综合阶段 debug 成本极高。
// 判据: 结束时 led == 8'hC3 (全通过); 期间不得出现 8'hE1。
// =============================================================================

`timescale 1ns / 1ps

module tb_sm4_engine_masked_v2_board;

    reg         clk = 1'b0;
    wire [7:0]  led;

    integer     i;
    integer     pass_cnt = 0;
    integer     fail_cnt = 0;
    reg  [31:0] cyc = 0;
    reg         saw_fail_led = 1'b0;
    reg  [7:0]  led_q;

    sm4_engine_masked_v2_board u_top (
        .clk (clk),
        .led (led)
    );

    always #5 clk = ~clk;   // 100 MHz

    always @(posedge clk) begin
        cyc <= cyc + 32'd1;
        led_q <= led;
        if (led_q === 8'hE1) saw_fail_led <= 1'b1;
    end

    initial begin
        // 上电复位 4096 cycles 由内部计数器完成, 再给 8 块 * 2000 cycles
        #1;
        for (i = 0; i < 40000; i = i + 1) begin
            @(posedge clk);
            #1;
        end
        $write("cycles=%0d led=%02x fail_led_seen=%0d\n", cyc, led, saw_fail_led);
        if (led === 8'hC3 && !saw_fail_led) begin
            $display("PASS[#B0]: board selftest top finished with 8/8 KAT match");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("FAIL[#B0]: led=%02x (expect c3) saw_fail_led=%0d", led, saw_fail_led);
            fail_cnt = fail_cnt + 1;
        end
        $write("TB RESULT: PASS=%0d FAIL=%0d\n", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
