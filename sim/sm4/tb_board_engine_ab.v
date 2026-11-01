// =============================================================================
// tb_board_engine_ab.v -- masked_en 0/1 A/B 对照 (仅 debug)
// 目的: 确定 sm4_engine_masked_v2 在 masked_en=1 下, key/pt 为标准向量时
//       是否仍输出 681EDF34D206965E86B3E94F536E4246。
// =============================================================================

`timescale 1ns / 1ps

module tb_board_engine_ab;

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         start = 1'b0;
    reg [127:0] key;
    reg [127:0] plaintext;
    reg         decrypt = 1'b0;
    reg [127:0] ciphertext;
    wire [127:0] result;
    wire         done;
    wire         busy;

    sm4_engine_masked_v2 dut (
        .clk(clk), .rst_n(rst_n), .start(start), .key(key),
        .plaintext(plaintext), .decrypt(decrypt), .ciphertext(ciphertext),
        .result(result), .done(done), .busy(busy),
        .masked_en(masked_en),
        .sbox_mask_ext_en(1'b0),
        .sbox_mask_c_ext(8'h00),
        .sbox_mask_tbl_ext(2048'h0),
        .sbox_addr_tap(), .sbox_mask_c_tap(), .sbox_mask_valid()
    );

    reg masked_en = 1'b1;

    always #5 clk = ~clk;

    integer i;
    integer cyc;

    task run_one;
        begin
            @(negedge clk);
            key        = 128'h0123456789ABCDEFFEDCBA9876543210;
            plaintext  = 128'h0123456789ABCDEFFEDCBA9876543210;
            ciphertext = 128'h0123456789ABCDEFFEDCBA9876543210;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
            cyc = 0;
            @(posedge clk);
            while (!done && cyc < 500) begin
                @(posedge clk);
                cyc = cyc + 1;
            end
            $display("  masked_en=%0b cycles=%0d done=%0b result=%032h",
                     masked_en, cyc, done, result);
        end
    endtask

    initial begin
        // 复位
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        masked_en = 1'b1;
        run_one();
        masked_en = 1'b0;
        run_one();
        masked_en = 1'b1;
        run_one();
        masked_en = 1'b0;
        run_one();

        $display("TB END");
        $finish;
    end

endmodule
