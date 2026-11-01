// =============================================================================
// tb_board_diag.v -- 板级自测顶层逐拍诊断 (仅 debug, 不进回归)
// 目的: 复位释放后逐拍打印引擎实际收到的 key/plaintext/start/done/busy,
//       确定 bd21... 这个错结果到底是哪一组输入算出来的。
// =============================================================================

`timescale 1ns / 1ps

module tb_board_diag;

    reg         clk = 1'b0;
    wire [7:0]  led;

    integer     i;
    integer     cyc = 0;

    sm4_engine_masked_v2_board u_top (
        .clk (clk),
        .led (led)
    );

    always #5 clk = ~clk;   // 100 MHz

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cyc >= 4090 && cyc <= 4140) begin
            $display("DIAG cyc=%0d rst=%0b st=%0d blk=%0d start=%0b done=%0b busy=%0b res=%032h",
                     cyc, u_top.rst_n, u_top.st, u_top.blk_idx,
                     u_top.start_reg, u_top.done, u_top.busy, u_top.result);
        end
        if (cyc == 4133) begin
            $display("DIAG engine sees: key=%032h pt=%032h ct_in=%032h",
                     u_top.u_engine.key, u_top.u_engine.plaintext,
                     u_top.u_engine.ciphertext);
        end
        if (led === 8'hC3 || led === 8'hE1) begin
            $display("DIAG: finished led=%02x at cyc=%0d", led, cyc);
            $finish;
        end
    end

    initial begin
        #1;
        for (i = 0; i < 50000; i = i + 1) begin
            @(posedge clk);
            #1;
        end
        $display("DIAG TIMEOUT led=%02x", led);
        $finish;
    end

endmodule
