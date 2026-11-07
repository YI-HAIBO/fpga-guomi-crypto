`timescale 1ns / 1ps
// DRBG post-processed output capture for NIST SP 800-22 full 15-test suite
module tb_drbg_nist;

    localparam CLK_PERIOD = 2.5;
    localparam N_REQUESTS = 2048;  // 2048 * 128 = 262144 bits

    reg clk, rst_n;
    reg req_vld;
    wire req_rdy;
    reg [7:0] req_bytes;
    wire data_vld;
    reg data_rdy;
    wire [127:0] data_out;
    wire data_last, busy, done;
    wire [7:0] err_code;

    integer req_cnt;
    integer out_file;

    trng u_dut (
        .clk(clk), .rst_n(rst_n),
        .req_vld(req_vld), .req_rdy(req_rdy),
        .req_bytes(req_bytes),
        .data_vld(data_vld), .data_rdy(data_rdy),
        .data_out(data_out), .data_last(data_last),
        .busy(busy), .done(done), .err_code(err_code)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = !clk;
    end

    task do_reset;
        begin
            rst_n = 1'b0; req_vld = 1'b0; req_bytes = 8'd0; data_rdy = 1'b0;
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task do_request;
        integer wait_cnt;
        begin
            wait_cnt = 0;
            wait(req_rdy == 1'b1);
            @(posedge clk);
            req_vld = 1'b1; req_bytes = 8'd1;
            @(posedge clk);
            req_vld = 1'b0;
            while (data_vld != 1'b1) begin
                @(posedge clk);
                wait_cnt = wait_cnt + 1;
                if (wait_cnt > 100000) begin
                    $display("ERROR: timeout");
                    $finish;
                end
            end
            #1;
            // Write 128-bit output as 16 hex bytes
            $fdisplay(out_file, "%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
                data_out[127:120], data_out[119:112], data_out[111:104], data_out[103:96],
                data_out[95:88],   data_out[87:80],   data_out[79:72],   data_out[71:64],
                data_out[63:56],   data_out[55:48],   data_out[47:40],   data_out[39:32],
                data_out[31:24],   data_out[23:16],   data_out[15:8],    data_out[7:0]);
            while (busy == 1'b1) @(posedge clk);
        end
    endtask

    initial begin
        out_file = $fopen("drbg_nist_bits.txt", "w");
        if (out_file == 0) begin
            $display("ERROR: cannot open drbg_nist_bits.txt");
            $finish;
        end
        $display("DRBG NIST capture: %0d requests (%0d bits)", N_REQUESTS, N_REQUESTS*128);
        do_reset;
        for (req_cnt = 0; req_cnt < N_REQUESTS; req_cnt = req_cnt + 1) begin
            do_request;
        end
        $display("DONE: %0d requests captured", req_cnt);
        $fclose(out_file);
        $finish;
    end

endmodule
