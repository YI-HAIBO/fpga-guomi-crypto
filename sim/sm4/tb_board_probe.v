`timescale 1ns / 1ps

module tb_board_probe;

    reg        clk = 1'b0;
    wire [7:0] led;

    sm4_engine_masked_v2_board u_top (
        .clk (clk),
        .led (led)
    );

    // 层次探针
    wire        u_done     = u_top.u_engine.done;
    wire        u_busy     = u_top.u_engine.busy;
    wire        u_start    = u_top.u_engine.start;
    wire [3:0]  u_st       = u_top.st;
    wire [2:0]  u_blk      = u_top.blk_idx;
    wire        u_rst_n    = u_top.rst_n;
    wire [127:0] u_pt      = u_top.pt_cur;

    always #5 clk = ~clk;

    integer i;
    initial begin
        #1;
        for (i = 0; i < 3000; i = i + 1) begin
            @(posedge clk);
            #1;
            if (i % 100 == 0)
                $write("%0d st=%0d blk=%0d start=%0b done=%0b busy=%0b rst=%0b led=%02x pt=%h\n",
                        i, u_st, u_blk, u_start, u_done, u_busy, u_rst_n, led, u_pt);
        end
        $finish;
    end

endmodule
